import CoreMedia
import Foundation

enum NativeFragmentedMP4 {
  struct Configuration: Equatable, Sendable {
    let avc: Data
    let width: Int
    let height: Int
    let audioConfig: Data
    let audioRate: Int
    let audioChannels: Int

    init(sps: Data, pps: Data, audioConfig: Data, audioRate: Int, audioChannels: Int) throws {
      guard !sps.isEmpty, !pps.isEmpty, audioConfig.count == 2,
        (1...65_535).contains(audioRate), (1...8).contains(audioChannels) else {
        throw NativeHLSError.transportCodec
      }
      var description: CMFormatDescription?
      let status = sps.withUnsafeBytes { spsBytes in
        pps.withUnsafeBytes { ppsBytes in
          guard let a = spsBytes.bindMemory(to: UInt8.self).baseAddress,
            let b = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
          return CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: 2,
            parameterSetPointers: [a, b], parameterSetSizes: [sps.count, pps.count],
            nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
      }
      guard status == noErr, let description,
        let atoms = CMFormatDescriptionGetExtension(description,
          extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data],
        let avc = atoms["avcC"] else { throw NativeHLSError.transportCodec }
      let dimensions = CMVideoFormatDescriptionGetDimensions(description)
      guard dimensions.width > 0, dimensions.height > 0,
        dimensions.width <= 65_535, dimensions.height <= 65_535 else {
        throw NativeHLSError.transportCodec
      }
      self.avc = avc
      width = Int(dimensions.width)
      height = Int(dimensions.height)
      self.audioConfig = audioConfig
      self.audioRate = audioRate
      self.audioChannels = audioChannels
    }
  }

  struct Sample: Equatable, Sendable {
    let decodeTime: UInt64
    let duration: UInt32
    let compositionOffset: Int32
    let independent: Bool
    let bytes: Data
  }

  static func initialization(_ config: Configuration) -> Data {
    let ftyp = box("ftyp", joined([text("iso6"), u32(1), text("iso6isommp41avc1cmfc")]))
    let matrix = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000].reduce(into: Data()) {
      $0.append(u32(UInt32($1)))
    }
    let mvhd = full("mvhd", joined([u32(0), u32(0), u32(90_000), u32(0),
      u32(0x00010000), u16(0x0100), zeros(10), matrix, zeros(24), u32(3)]))
    func track(id: UInt32, audio: Bool) -> Data {
      let tkhd = full("tkhd", joined([u32(0), u32(0), u32(id), u32(0), u32(0), zeros(8),
        u16(0), u16(0), u16(audio ? 0x0100 : 0), u16(0), matrix,
        u32(audio ? 0 : UInt32(config.width) << 16),
        u32(audio ? 0 : UInt32(config.height) << 16)]), flags: 7)
      let mdhd = full("mdhd", u32(0) + u32(0) + u32(audio ? UInt32(config.audioRate) : 90_000)
        + u32(0) + u16(0x55C4) + u16(0))
      let hdlr = full("hdlr", u32(0) + text(audio ? "soun" : "vide") + zeros(12)
        + text(audio ? "Audio\0" : "Video\0"))
      let sampleEntry: Data
      if audio {
        let specific = descriptor(5, config.audioConfig)
        let decoder = descriptor(4, joined([Data([0x40, 0x15, 0, 0, 0]), u32(0), u32(0), specific]))
        let esds = full("esds", descriptor(3, joined([u16(2), Data([0]), decoder, descriptor(6, Data([2]))])))
        sampleEntry = box("mp4a", joined([zeros(6), u16(1), zeros(8), u16(UInt16(config.audioChannels)),
          u16(16), u16(0), u16(0), u32(UInt32(config.audioRate) << 16), esds]))
      } else {
        sampleEntry = box("avc1", joined([zeros(6), u16(1), zeros(16),
          u16(UInt16(config.width)), u16(UInt16(config.height)),
          u32(0x00480000), u32(0x00480000), u32(0), u16(1),
          zeros(32), u16(0x0018), u16(0xFFFF), box("avcC", config.avc)]))
      }
      let stbl = box("stbl", joined([full("stsd", u32(1) + sampleEntry),
        full("stts", u32(0)), full("stsc", u32(0)),
        full("stsz", u32(0) + u32(0)), full("stco", u32(0))]))
      let dinf = box("dinf", full("dref", u32(1) + full("url ", Data(), flags: 1)))
      let header = audio ? full("smhd", u16(0) + u16(0))
        : full("vmhd", zeros(8), flags: 1)
      return box("trak", tkhd + box("mdia", mdhd + hdlr + box("minf", header + dinf + stbl)))
    }
    let trex = [UInt32(1), 2].reduce(into: Data()) {
      $0.append(full("trex", joined([u32($1), u32(1), u32(0), u32(0), u32(0)])))
    }
    return ftyp + box("moov", joined([mvhd, track(id: 1, audio: false), track(id: 2, audio: true),
      box("mvex", trex)]))
  }

  static func fragment(sequence: UInt32, video: [Sample], audio: [Sample],
                       videoDescriptionIndex: UInt32 = 1) throws -> Data {
    guard !video.isEmpty, video.count <= 10_000, audio.count <= 10_000,
      (1...16).contains(videoDescriptionIndex) else {
      throw NativeHLSError.invalidMedia
    }
    for samples in [video, audio] {
      for sample in samples {
        guard sample.duration > 0, !sample.bytes.isEmpty, sample.bytes.count <= 32 * 1024 * 1024 else {
          throw NativeHLSError.invalidMedia
        }
      }
      for (before, after) in zip(samples, samples.dropFirst()) {
        guard before.decodeTime <= UInt64.max - UInt64(before.duration),
          before.decodeTime + UInt64(before.duration) == after.decodeTime else {
          throw NativeHLSError.transition
        }
      }
    }
    let videoBytes = video.reduce(into: Data()) { $0.append($1.bytes) }
    let audioBytes = audio.reduce(into: Data()) { $0.append($1.bytes) }
    guard videoBytes.count + audioBytes.count < 32 * 1024 * 1024 else {
      throw NativeHLSError.invalidMedia
    }
    func traf(_ id: UInt32, samples: [Sample], offset: Int, isVideo: Bool) -> Data {
      let tfhd = full("tfhd", u32(id) + (isVideo ? u32(videoDescriptionIndex) : Data()),
        flags: isVideo ? 0x020002 : 0x020000)
      let tfdt = full("tfdt", u64(samples[0].decodeTime), version: 1)
      var entries = u32(UInt32(samples.count)) + u32(UInt32(offset))
      for sample in samples {
        entries += u32(sample.duration) + u32(UInt32(sample.bytes.count))
          + u32(sample.independent ? 0x02000000 : 0x01010000)
        if isVideo { entries += u32(UInt32(bitPattern: sample.compositionOffset)) }
      }
      let trun = full("trun", entries, version: isVideo ? 1 : 0, flags: isVideo ? 0x000F01 : 0x000701)
      return box("traf", tfhd + tfdt + trun)
    }
    let mfhd = full("mfhd", u32(sequence))
    func moof(videoOffset: Int, audioOffset: Int) -> Data {
      box("moof", mfhd + traf(1, samples: video, offset: videoOffset, isVideo: true)
        + (audio.isEmpty ? Data() : traf(2, samples: audio, offset: audioOffset, isVideo: false)))
    }
    let size = moof(videoOffset: 0, audioOffset: 0).count
    return moof(videoOffset: size + 8, audioOffset: size + 8 + videoBytes.count)
      + box("mdat", videoBytes + audioBytes)
  }

  static func switchingInitialization(_ initializations: [Data], maximumResolutionIndex: Int) throws -> Data {
    guard initializations.indices.contains(maximumResolutionIndex), initializations.count <= 16 else {
      throw NativeHLSError.invalidMedia
    }
    func track(_ initialization: Data, handler: String) throws -> NativeCMAF.Box {
      let tracks = try NativeCMAF.boxes(NativeCMAF.child(initialization, "moov")).filter { box in
        guard box.type == "trak" else { return false }
        let hdlr = try NativeCMAF.child(NativeCMAF.child(box.payload, "mdia"), "hdlr")
        return String(decoding: hdlr.dropFirst(8).prefix(4), as: UTF8.self) == handler
      }
      guard tracks.count == 1 else { throw NativeHLSError.invalidMedia }
      return tracks[0]
    }
    let audio = try track(initializations[0], handler: "soun")
    var descriptions = Data()
    for initialization in initializations {
      guard try track(initialization, handler: "soun").payload == audio.payload else {
        throw NativeHLSError.transportCodec
      }
      let video = try track(initialization, handler: "vide")
      let stbl = try NativeCMAF.child(NativeCMAF.child(video.payload, "mdia"), "minf")
      let stsd = try NativeCMAF.child(NativeCMAF.child(stbl, "stbl"), "stsd")
      guard try NativeCMAF.integer(stsd, 4) == 1 else { throw NativeHLSError.invalidMedia }
      descriptions.append(stsd.dropFirst(8))
    }
    let base = initializations[maximumResolutionIndex]
    let video = try track(base, handler: "vide")
    let replacement = full("stsd", u32(UInt32(initializations.count)) + descriptions)
    let payload = try replacing(video.payload, path: ["mdia", "minf", "stbl", "stsd"], with: replacement)
    var movie = Data()
    for child in try NativeCMAF.boxes(NativeCMAF.child(base, "moov")) {
      movie.append(box(child.type, child.type == "trak" && child.payload == video.payload ? payload : child.payload))
    }
    return box("ftyp", try NativeCMAF.child(base, "ftyp")) + box("moov", movie)
  }

  /// Keep presentation clocks and compressed payloads unchanged while giving a
  /// keyframe-switched movie one continuous decode timeline and known formats.
  static func switchingFragment(_ data: Data, videoDescriptionIndex: UInt32,
                                decodeStart: UInt64) throws -> Data {
    guard videoDescriptionIndex > 0, videoDescriptionIndex <= 16,
      let target = Int64(exactly: decodeStart) else { throw NativeHLSError.invalidMedia }
    let boxes = try NativeCMAF.boxes(data)
    guard !boxes.isEmpty, boxes.count.isMultiple(of: 2),
      boxes.enumerated().allSatisfy({ $0.element.type == ($0.offset.isMultiple(of: 2) ? "moof" : "mdat") }) else {
      throw NativeHLSError.invalidMedia
    }
    var delta: Int64?
    var output = Data()
    for child in boxes {
      guard child.type == "moof" else {
        guard child.type == "mdat" else { throw NativeHLSError.invalidMedia }
        output.append(box(child.type, child.payload))
        continue
      }
      let children = try NativeCMAF.boxes(child.payload)
      let video = try children.first { traf in
        guard traf.type == "traf" else { return false }
        return try NativeCMAF.integer(NativeCMAF.child(traf.payload, "tfhd"), 4) == 1
      }
      guard let video else { throw NativeHLSError.invalidMedia }
      let header = try NativeCMAF.child(video.payload, "tfhd")
      let flags = try NativeCMAF.integer(header, 0) & 0xFFFFFF
      guard flags & 1 == 0 else { throw NativeHLSError.unsupported }
      let growth = flags & 2 == 0 ? 4 : 0
      let clock = try NativeCMAF.child(video.payload, "tfdt")
      guard clock.first == 1 else { throw NativeHLSError.unsupported }
      let originalClock = try NativeCMAF.integer(clock, 4, 8)
      guard let signedClock = Int64(exactly: originalClock) else { throw NativeHLSError.invalidMedia }
      if delta == nil { delta = target - signedClock }
      guard let delta else { throw NativeHLSError.invalidMedia }
      let mappedClock = signedClock.addingReportingOverflow(delta)
      guard !mappedClock.overflow, mappedClock.partialValue >= 0 else { throw NativeHLSError.invalidMedia }
      var payload = Data()
      for component in children {
        guard component.type == "traf" else {
          payload.append(box(component.type, component.payload))
          continue
        }
        let tfhd = try NativeCMAF.child(component.payload, "tfhd")
        let isVideo = try NativeCMAF.integer(tfhd, 4) == 1
        var traf = Data()
        for item in try NativeCMAF.boxes(component.payload) {
          var value = item.payload
          if item.type == "tfhd", isVideo {
            let flags = UInt32(try NativeCMAF.integer(value, 0)) | 2
            value = u32(flags) + Data(value[4..<8]) + u32(videoDescriptionIndex)
              + Data(value.dropFirst(growth == 4 ? 8 : 12))
          } else if item.type == "tfdt", isVideo {
            value = Data(value.prefix(4)) + u64(UInt64(mappedClock.partialValue))
          } else if item.type == "trun" {
            let flags = try NativeCMAF.integer(value, 0) & 0xFFFFFF
            guard flags & 1 != 0 else { throw NativeHLSError.unsupported }
            let offset = try NativeCMAF.integer(value, 8)
            guard offset + UInt64(growth) <= UInt64(Int32.max) else { throw NativeHLSError.invalidMedia }
            value.replaceSubrange(8..<12, with: u32(UInt32(offset + UInt64(growth))))
            if isVideo {
              guard flags & 0x800 != 0 else { throw NativeHLSError.unsupported }
              let version = value[0]
              value[0] = 1
              let count = Int(try NativeCMAF.integer(value, 4))
              guard count <= 10_000 else { throw NativeHLSError.invalidMedia }
              var position = 12 + (flags & 4 != 0 ? 4 : 0)
              for _ in 0..<count {
                position += (flags & 0x100 != 0 ? 4 : 0) + (flags & 0x200 != 0 ? 4 : 0)
                  + (flags & 0x400 != 0 ? 4 : 0)
                let raw = UInt32(try NativeCMAF.integer(value, position))
                let original = version == 1 ? Int64(Int32(bitPattern: raw)) : Int64(raw)
                let shiftedClock = original.subtractingReportingOverflow(delta)
                guard !shiftedClock.overflow, let shifted = Int32(exactly: shiftedClock.partialValue) else {
                  throw NativeHLSError.invalidMedia
                }
                value.replaceSubrange(position..<(position + 4), with: u32(UInt32(bitPattern: shifted)))
                position += 4
              }
            }
          }
          traf.append(box(item.type, value))
        }
        payload.append(box("traf", traf))
      }
      output.append(box("moof", payload))
    }
    return output
  }

  private static func replacing(_ data: Data, path: [String], with replacement: Data) throws -> Data {
    guard let first = path.first else { throw NativeHLSError.invalidMedia }
    var count = 0
    var result = Data()
    for item in try NativeCMAF.boxes(data) {
      if item.type == first {
        count += 1
        if path.count == 1 { result.append(replacement) }
        else { result.append(box(item.type, try replacing(item.payload, path: Array(path.dropFirst()), with: replacement))) }
      } else { result.append(box(item.type, item.payload)) }
    }
    guard count == 1 else { throw NativeHLSError.invalidMedia }
    return result
  }

  private static func descriptor(_ tag: UInt8, _ payload: Data) -> Data {
    precondition(payload.count < 128)
    return Data([tag, UInt8(payload.count)]) + payload
  }

  private static func joined(_ parts: [Data]) -> Data {
    parts.reduce(into: Data()) { $0.append($1) }
  }

  private static func box(_ type: String, _ payload: Data) -> Data {
    u32(UInt32(payload.count + 8)) + text(type) + payload
  }

  private static func full(_ type: String, _ payload: Data, version: UInt8 = 0, flags: UInt32 = 0) -> Data {
    box(type, Data([version, UInt8((flags >> 16) & 255), UInt8((flags >> 8) & 255), UInt8(flags & 255)]) + payload)
  }

  private static func text(_ string: String) -> Data { Data(string.utf8) }
  private static func zeros(_ count: Int) -> Data { Data(repeating: 0, count: count) }
  private static func u16(_ value: UInt16) -> Data {
    Data([UInt8(value >> 8), UInt8(value & 255)])
  }
  private static func u32(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
  }
  private static func u64(_ value: UInt64) -> Data { u32(UInt32(value >> 32)) + u32(UInt32(value & 0xFFFFFFFF)) }
}

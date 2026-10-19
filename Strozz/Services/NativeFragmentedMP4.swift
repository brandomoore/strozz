import CoreMedia
import Foundation

enum NativeFragmentedMP4 {
  struct Configuration: Equatable, Sendable {
    let avc: Data
    let width: Int
    let height: Int
    let videoTimescale: Int
    let audioConfig: Data
    let audioRate: Int
    let audioChannels: Int

    init(sps: Data, pps: Data, audioConfig: Data, audioRate: Int, audioChannels: Int,
         videoTimescale: Int = 90_000) throws {
      guard !sps.isEmpty, !pps.isEmpty, audioConfig.count == 2,
        (1...65_535).contains(audioRate), (1...8).contains(audioChannels),
        (1...1_000_000).contains(videoTimescale) else {
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
      self.videoTimescale = videoTimescale
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
    let mvhd = full("mvhd", joined([u32(0), u32(0), u32(UInt32(config.videoTimescale)), u32(0),
      u32(0x00010000), u16(0x0100), zeros(10), matrix, zeros(24), u32(3)]))
    func track(id: UInt32, audio: Bool) -> Data {
      let tkhd = full("tkhd", joined([u32(0), u32(0), u32(id), u32(0), u32(0), zeros(8),
        u16(0), u16(0), u16(audio ? 0x0100 : 0), u16(0), matrix,
        u32(audio ? 0 : UInt32(config.width) << 16),
        u32(audio ? 0 : UInt32(config.height) << 16)]), flags: 7)
      let mdhd = full("mdhd", u32(0) + u32(0) + u32(audio ? UInt32(config.audioRate) : UInt32(config.videoTimescale))
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
    let firstFormat = try NativeCMAFRemuxer.Format(initializations[0])
    var descriptions = Data()
    for initialization in initializations {
      let format = try NativeCMAFRemuxer.Format(initialization)
      guard format.video.id == firstFormat.video.id, format.video.scale == firstFormat.video.scale,
        format.audio.id == firstFormat.audio.id, format.audio.scale == firstFormat.audio.scale,
        format.configuration.audioConfig == firstFormat.configuration.audioConfig,
        format.configuration.audioChannels == firstFormat.configuration.audioChannels else {
        throw NativeHLSError.unsupported
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

  static func controlledFragment(_ data: Data, video: NativeCMAF.Track, audio: NativeCMAF.Track,
                                 videoDescriptionIndex: UInt32, videoDecodeTime: UInt64,
                                 compositionShift: Int64, audioDecodeTime: UInt64,
                                 sequence: UInt32) throws -> Data {
    let boxes = try NativeCMAF.boxes(data)
    guard boxes.count == 2, boxes[0].type == "moof", boxes[1].type == "mdat",
      video.id != audio.id, (1...16).contains(videoDescriptionIndex) else { throw NativeHLSError.invalidMedia }
    let originalHeader = try NativeCMAF.integer(data, 0) == 1 ? 16 : 8
    let originalLength = boxes[0].payload.count + originalHeader
    let mediaHeader = try NativeCMAF.integer(data, originalLength) == 1 ? 16 : 8
    var seen = Set<UInt64>()
    var components: [(String, Data)] = []
    var media = Data()
    for item in try NativeCMAF.boxes(boxes[0].payload) {
      if item.type == "mfhd" {
        guard item.payload.count == 8 else { throw NativeHLSError.invalidMedia }
        components.append(("mfhd", Data(item.payload.prefix(4)) + u32(sequence)))
        continue
      }
      guard item.type == "traf" else { throw NativeHLSError.unsupported }
      let header = try NativeCMAF.child(item.payload, "tfhd")
      _ = try NativeCMAF.child(item.payload, "tfdt")
      let id = try NativeCMAF.integer(header, 4)
      guard (id == video.id || id == audio.id), seen.insert(id).inserted else { throw NativeHLSError.invalidMedia }
      let isVideo = id == video.id
      let track = isVideo ? video : audio
      let flags = try NativeCMAF.integer(header, 0) & 0xFFFFFF
      guard flags & 1 == 0, flags & 0x020000 != 0 else { throw NativeHLSError.unsupported }
      if flags & 2 != 0 {
        guard try NativeCMAF.integer(header, 8) == 1 else { throw NativeHLSError.invalidMedia }
      }
      var position = 8 + (flags & 2 != 0 ? 4 : 0)
      let duration = flags & 8 != 0 ? try NativeCMAF.integer(header, position) : track.duration
      if flags & 8 != 0 { position += 4 }
      let size = flags & 16 != 0 ? try NativeCMAF.integer(header, position) : track.size
      if flags & 16 != 0 { position += 4 }
      let sampleFlags = flags & 32 != 0 ? try NativeCMAF.integer(header, position) : track.flags
      var replacement = Data()
      for child in try NativeCMAF.boxes(item.payload) {
        switch child.type {
        case "tfhd":
          replacement.append(full("tfhd", u32(UInt32(id)) + (isVideo ? u32(videoDescriptionIndex) : u32(1)),
            flags: 0x020002))
        case "tfdt":
          replacement.append(full("tfdt", u64(isVideo ? videoDecodeTime : audioDecodeTime), version: 1))
        case "trun":
          let sourceFlags = try NativeCMAF.integer(child.payload, 0) & 0xFFFFFF
          let count = try NativeCMAF.integer(child.payload, 4)
          guard count > 0, count <= 10_000, sourceFlags & 1 != 0, sourceFlags & ~0x000F05 == 0,
            child.payload.first == 0 || child.payload.first == 1 else { throw NativeHLSError.invalidMedia }
          let rawOffset = UInt32(try NativeCMAF.integer(child.payload, 8))
          let offset = Int(Int32(bitPattern: rawOffset))
          guard offset >= originalLength + mediaHeader, offset < data.count else { throw NativeHLSError.invalidMedia }
          var p = 12
          let firstFlags = sourceFlags & 4 != 0 ? try NativeCMAF.integer(child.payload, p) : sampleFlags
          if sourceFlags & 4 != 0 { p += 4 }
          var entries = u32(UInt32(count)) + u32(UInt32(media.count))
          var byteCount: UInt64 = 0
          for index in 0..<count {
            let d = sourceFlags & 0x100 != 0 ? try NativeCMAF.integer(child.payload, p) : duration
            if sourceFlags & 0x100 != 0 { p += 4 }
            let s = sourceFlags & 0x200 != 0 ? try NativeCMAF.integer(child.payload, p) : size
            if sourceFlags & 0x200 != 0 { p += 4 }
            let f = sourceFlags & 0x400 != 0 ? try NativeCMAF.integer(child.payload, p)
              : (index == 0 ? firstFlags : sampleFlags)
            if sourceFlags & 0x400 != 0 { p += 4 }
            var composition: Int64 = 0
            if sourceFlags & 0x800 != 0 {
              let raw = UInt32(try NativeCMAF.integer(child.payload, p))
              composition = child.payload.first == 1 ? Int64(Int32(bitPattern: raw)) : Int64(raw)
              p += 4
            }
            guard d > 0, s > 0, p <= child.payload.count else { throw NativeHLSError.invalidMedia }
            byteCount += s
            guard byteCount <= data.count - offset else { throw NativeHLSError.invalidMedia }
            let start = offset + Int(byteCount - s)
            let sample = data.subdata(in: start..<(start + Int(s)))
            let payload = isVideo ? try removingRemappedTimingAVC(sample) : sample
            media.append(payload)
            entries += u32(UInt32(d)) + u32(UInt32(payload.count)) + u32(UInt32(f))
            if isVideo {
              let shifted = composition.addingReportingOverflow(compositionShift)
              guard !shifted.overflow, let c = Int32(exactly: shifted.partialValue) else {
                throw NativeHLSError.invalidMedia
              }
              entries += u32(UInt32(bitPattern: c))
            } else if composition != 0 { throw NativeHLSError.unsupported }
          }
          guard p == child.payload.count else { throw NativeHLSError.invalidMedia }
          replacement.append(full("trun", entries, version: isVideo ? 1 : 0,
            flags: isVideo ? 0x000F01 : 0x000701))
        case "sdtp", "sgpd", "sbgp":
          replacement.append(box(child.type, child.payload))
        default: throw NativeHLSError.unsupported
        }
      }
      components.append(("traf", replacement))
    }
    guard seen == Set([video.id, audio.id]), components.filter({ $0.0 == "mfhd" }).count == 1 else {
      throw NativeHLSError.invalidMedia
    }
    let newLength = components.reduce(8) { $0 + $1.1.count + 8 }
    var movie = Data()
    for (type, payload) in components {
      guard type == "traf" else { movie.append(box(type, payload)); continue }
      var traf = Data()
      for child in try NativeCMAF.boxes(payload) {
        var value = child.payload
        if child.type == "trun" {
          let offset = Int64(try NativeCMAF.integer(value, 8)) + Int64(newLength + 8)
          guard let checked = Int32(exactly: offset), checked > 0 else { throw NativeHLSError.invalidMedia }
          value.replaceSubrange(8..<12, with: u32(UInt32(bitPattern: checked)))
        }
        traf.append(box(child.type, value))
      }
      movie.append(box(type, traf))
    }
    return box("moof", movie) + box("mdat", media)
  }

  static func removingRemappedTimingAVC(_ sample: Data) throws -> Data {
    var position = 0
    var result: Data?
    while position < sample.count {
      let size = Int(try NativeCMAF.integer(sample, position))
      guard size > 0, position + 4 <= sample.count - size else { throw NativeHLSError.invalidMedia }
      let start = position + 4
      let end = start + size
      if sample[start] & 31 == 6 {
        let original = sample.subdata(in: start..<end)
        let filtered = try NativeTransportDemuxer.removingTransportTimingSEI(original)
        if filtered != original {
          if result == nil { result = Data(sample.prefix(position)) }
          if let filtered { result?.append(u32(UInt32(filtered.count)) + filtered) }
        } else { result?.append(sample.subdata(in: position..<end)) }
      } else { result?.append(sample.subdata(in: position..<end)) }
      position = end
    }
    guard result?.isEmpty != true else { throw NativeHLSError.invalidMedia }
    return result ?? sample
  }

  /// Split an already-normalized fragment at sample boundaries, retaining
  /// compressed sample bytes, flags, clocks and sample descriptions.
  static func splitControlledFragment(_ data: Data, video: NativeCMAF.Track, audio: NativeCMAF.Track,
                                      maximumDuration: Double, sequence: UInt32) throws -> (Data, Data) {
    struct Run {
      let header: Data
      let video: Bool
      let clock: UInt64
      let entries: [Data]
      let durations: [UInt64]
      let samples: [Data]
      let dependencies: Data?
    }
    guard maximumDuration.isFinite, maximumDuration > 0 else { throw NativeHLSError.partDuration }
    let top = try NativeCMAF.boxes(data)
    guard top.count == 2, top[0].type == "moof", top[1].type == "mdat" else {
      throw NativeHLSError.invalidMedia
    }
    let movieSize = top[0].payload.count + 8
    var runs: [Run] = []
    for child in try NativeCMAF.boxes(top[0].payload) where child.type != "mfhd" {
      guard child.type == "traf" else { throw NativeHLSError.unsupported }
      let header = try NativeCMAF.child(child.payload, "tfhd")
      let id = try NativeCMAF.integer(header, 4)
      guard id == video.id || id == audio.id,
        try NativeCMAF.integer(header, 0) & 0xFFFFFF == 0x020002 else { throw NativeHLSError.invalidMedia }
      let isVideo = id == video.id
      let clock = try NativeCMAF.child(child.payload, "tfdt")
      guard clock.first == 1 else { throw NativeHLSError.invalidMedia }
      var entries: [Data] = []
      var durations: [UInt64] = []
      var samples: [Data] = []
      var dependencies: Data?
      for item in try NativeCMAF.boxes(child.payload) {
        if item.type == "tfhd" || item.type == "tfdt" { continue }
        if item.type == "sdtp" { dependencies = item.payload; continue }
        guard item.type == "trun" else { throw NativeHLSError.unsupported }
        let flags = try NativeCMAF.integer(item.payload, 0) & 0xFFFFFF
        guard flags == (isVideo ? 0xF01 : 0x701) else { throw NativeHLSError.invalidMedia }
        let count = Int(try NativeCMAF.integer(item.payload, 4))
        let stride = isVideo ? 16 : 12
        guard count > 0, count <= 10_000, item.payload.count == 12 + count * stride else {
          throw NativeHLSError.invalidMedia
        }
        var offset = Int(try NativeCMAF.integer(item.payload, 8))
        for index in 0..<count {
          let start = 12 + index * stride
          let duration = try NativeCMAF.integer(item.payload, start)
          let size = Int(try NativeCMAF.integer(item.payload, start + 4))
          guard duration > 0, size > 0, offset >= movieSize + 8, offset <= data.count - size else {
            throw NativeHLSError.invalidMedia
          }
          entries.append(item.payload.subdata(in: start..<(start + stride)))
          durations.append(duration)
          samples.append(data.subdata(in: offset..<(offset + size)))
          offset += size
        }
      }
      if let dependencies {
        guard dependencies.count == entries.count + 4 else { throw NativeHLSError.invalidMedia }
      }
      runs.append(Run(header: header, video: isVideo,
        clock: try NativeCMAF.integer(clock, 4, 8), entries: entries, durations: durations,
        samples: samples, dependencies: dependencies))
    }
    guard runs.count == 2, let image = runs.first(where: \.video),
      let sound = runs.first(where: { !$0.video }) else { throw NativeHLSError.invalidMedia }
    var elapsed: UInt64 = 0
    var cut: (video: Int, audio: Int)?
    for index in image.durations.indices.dropLast() {
      elapsed += image.durations[index]
      guard Double(elapsed) / Double(video.scale) <= maximumDuration else { break }
      let boundary = Double(image.clock + elapsed) / Double(video.scale)
      var audioClock = sound.clock
      var count = 0
      for duration in sound.durations {
        if Double(audioClock) / Double(audio.scale) >= boundary { break }
        count += 1
        audioClock += duration
      }
      if count > 0, count < sound.entries.count { cut = (index + 1, count) }
    }
    guard let cut, sequence < UInt32.max else { throw NativeHLSError.partDuration }
    func fragment(first: Bool) throws -> Data {
      var components: [(Data, Data)] = []
      for run in runs {
        let count = run.video ? cut.video : cut.audio
        let range = first ? 0..<count : count..<run.entries.count
        let clock = run.clock + (first ? 0 : run.durations.prefix(count).reduce(0, +))
        var payload = run.header
        payload = box("tfhd", payload) + full("tfdt", u64(clock), version: 1)
        let entries = range.reduce(into: Data()) { $0.append(run.entries[$1]) }
        payload += full("trun", u32(UInt32(range.count)) + u32(0) + entries,
          version: run.video ? 1 : 0, flags: run.video ? 0xF01 : 0x701)
        if let dependencies = run.dependencies {
          payload += box("sdtp", Data(dependencies.prefix(4))
            + dependencies.subdata(in: (4 + range.lowerBound)..<(4 + range.upperBound)))
        }
        let media = range.reduce(into: Data()) { $0.append(run.samples[$1]) }
        components.append((payload, media))
      }
      let mfhd = full("mfhd", u32(first ? sequence : sequence + 1))
      let size = components.reduce(8 + mfhd.count) { $0 + $1.0.count + 8 }
      var offset = size + 8
      var movie = mfhd
      var media = Data()
      for (payload, bytes) in components {
        var track = Data()
        for item in try NativeCMAF.boxes(payload) {
          var value = item.payload
          if item.type == "trun" {
            guard offset <= Int(Int32.max) else { throw NativeHLSError.invalidMedia }
            value.replaceSubrange(8..<12, with: u32(UInt32(offset)))
          }
          track += box(item.type, value)
        }
        movie += box("traf", track)
        media += bytes
        offset += bytes.count
      }
      return box("moof", movie) + box("mdat", media)
    }
    return try (fragment(first: true), fragment(first: false))
  }

  static func resequencedFragment(_ data: Data, sequence: UInt32) throws -> Data {
    let moof = try NativeCMAF.child(data, "moof")
    if try NativeCMAF.integer(NativeCMAF.child(moof, "mfhd"), 4) == UInt64(sequence) { return data }
    var movie = Data()
    for item in try NativeCMAF.boxes(moof) {
      movie += box(item.type, item.type == "mfhd" ? Data(item.payload.prefix(4)) + u32(sequence) : item.payload)
    }
    return box("moof", movie) + box("mdat", try NativeCMAF.child(data, "mdat"))
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

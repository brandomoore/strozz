import Foundation

enum NativeCMAFClock {
  static let epochSeconds: UInt64 = 100_000

  static func rescale(_ value: UInt64, from: UInt64, to: UInt64) throws -> UInt64 {
    guard from > 0, to > 0 else { throw NativeHLSError.invalidMedia }
    let scaled = Double(value) * Double(to) / Double(from)
    guard scaled.isFinite, scaled >= 0, scaled <= Double(NativeMediaClock.maximum) else {
      throw NativeHLSError.transition
    }
    return UInt64(scaled.rounded())
  }

  static func unwrap(_ raw: UInt64, version: UInt8, scale: UInt64, near reference: UInt64?) throws -> UInt64 {
    guard version <= 1, (1...1_000_000).contains(scale),
      raw <= NativeMediaClock.maximum else { throw NativeHLSError.invalidMedia }
    let base = raw + epochSeconds * scale
    guard base <= NativeMediaClock.maximum else { throw NativeHLSError.invalidMedia }
    guard version == 0 else { return base }
    guard raw <= UInt32.max else { throw NativeHLSError.invalidMedia }
    guard let reference else { return base }
    guard reference <= NativeMediaClock.maximum else { throw NativeHLSError.invalidMedia }
    let cycle: Int64 = 1 << 32
    let difference = Int64(reference) - Int64(base)
    let cycles = difference >= 0 ? (difference + cycle / 2) / cycle : -((-difference + cycle / 2) / cycle)
    let value = Int64(base) + cycles * cycle
    guard value >= 0, value <= NativeMediaClock.maximum else { throw NativeHLSError.transition }
    return UInt64(value)
  }

  static func initial(video: NativeCMAF.FragmentTiming, audio: NativeCMAF.FragmentTiming,
                      videoScale: UInt64, audioScale: UInt64, reference: UInt64?) throws -> (UInt64, UInt64) {
    guard video.version <= 1, audio.version <= 1, (1...1_000_000).contains(videoScale),
      (1...1_000_000).contains(audioScale) else { throw NativeHLSError.invalidMedia }
    if let reference {
      let v = try unwrap(video.decodeTime, version: video.version, scale: videoScale, near: reference)
      let a = try unwrap(audio.decodeTime, version: audio.version, scale: audioScale,
        near: rescale(v, from: videoScale, to: audioScale))
      return (v, a)
    }
    if video.version == 1 {
      let v = try unwrap(video.decodeTime, version: 1, scale: videoScale, near: nil)
      return (v, try unwrap(audio.decodeTime, version: audio.version, scale: audioScale,
        near: rescale(v, from: videoScale, to: audioScale)))
    }
    if audio.version == 1 {
      let a = try unwrap(audio.decodeTime, version: 1, scale: audioScale, near: nil)
      return (try unwrap(video.decodeTime, version: 0, scale: videoScale,
        near: rescale(a, from: audioScale, to: videoScale)), a)
    }
    var x = videoScale
    var y = audioScale
    while y != 0 { (x, y) = (y, x % y) }
    let phases = audioScale / x
    guard phases <= 4096 else { throw NativeHLSError.unsupported }
    // The two v0 clocks wrap at different wall times. Recover their common
    // phase before anchoring the period; assuming both are in epoch zero loses A/V sync.
    for phase in 0..<phases {
      let a = audio.decodeTime + epochSeconds * audioScale + phase * (1 << 32)
      let v = try unwrap(video.decodeTime, version: 0, scale: videoScale,
        near: rescale(a, from: audioScale, to: videoScale))
      if abs((Double(v) + Double(video.firstComposition)) / Double(videoScale)
        - Double(a) / Double(audioScale)) <= 0.25 { return (v, a) }
    }
    throw NativeHLSError.transition
  }
}

struct NativeCMAFRemuxer {
  struct Format: Sendable {
    let initialization: Data
    let configuration: NativeFragmentedMP4.Configuration
    let video: NativeCMAF.Track
    let audio: NativeCMAF.Track
    let videoDescription: Data
    let audioDescription: Data
    let videoCodec: String

    init(_ initialization: Data) throws {
      self.initialization = initialization
      video = try NativeCMAF.track(initialization, handler: "vide")
      audio = try NativeCMAF.track(initialization, handler: "soun")
      guard video.id != audio.id, video.id > 0, audio.id > 0,
        (1...1_000_000).contains(video.scale), audio.scale <= 65_535 else {
        throw NativeHLSError.unsupported
      }
      let movie = try NativeCMAF.child(initialization, "moov")
      func entry(_ handler: String) throws -> NativeCMAF.Box {
        let tracks = try NativeCMAF.boxes(movie).filter { box in
          guard box.type == "trak" else { return false }
          let mdia = try NativeCMAF.child(box.payload, "mdia")
          return String(decoding: try NativeCMAF.child(mdia, "hdlr").dropFirst(8).prefix(4), as: UTF8.self) == handler
        }
        guard tracks.count == 1 else { throw NativeHLSError.unsupported }
        guard try !NativeCMAF.boxes(tracks[0].payload).contains(where: { $0.type == "edts" }) else {
          throw NativeHLSError.unsupported
        }
        let mdia = try NativeCMAF.child(tracks[0].payload, "mdia")
        let stbl = try NativeCMAF.child(NativeCMAF.child(mdia, "minf"), "stbl")
        let stsd = try NativeCMAF.child(stbl, "stsd")
        guard try NativeCMAF.integer(stsd, 4) == 1 else { throw NativeHLSError.unsupported }
        let values = try NativeCMAF.boxes(Data(stsd.dropFirst(8)))
        guard values.count == 1 else { throw NativeHLSError.invalidMedia }
        return values[0]
      }
      let image = try entry("vide")
      let sound = try entry("soun")
      videoDescription = image.payload
      audioDescription = sound.payload
      videoCodec = image.type
      guard ["avc1", "avc3"].contains(image.type), image.payload.count >= 78,
        sound.type == "mp4a", sound.payload.count >= 28,
        try NativeCMAF.integer(sound.payload, 8, 2) == 0 else { throw NativeHLSError.unsupported }
      let avc = try NativeCMAF.child(Data(image.payload.dropFirst(78)), "avcC")
      guard avc.count >= 7, avc[0] == 1, avc[4] & 3 == 3, avc[5] & 31 == 1 else {
        throw NativeHLSError.unsupported
      }
      let spsCount = Int(try NativeCMAF.integer(avc, 6, 2))
      guard spsCount > 0, 8 + spsCount + 3 <= avc.count else { throw NativeHLSError.invalidMedia }
      let sps = avc.subdata(in: 8..<(8 + spsCount))
      let p = 8 + spsCount
      guard avc[p] == 1 else { throw NativeHLSError.unsupported }
      let ppsCount = Int(try NativeCMAF.integer(avc, p + 1, 2))
      guard ppsCount > 0, p + 3 + ppsCount <= avc.count else { throw NativeHLSError.invalidMedia }
      let pps = avc.subdata(in: (p + 3)..<(p + 3 + ppsCount))
      let esds = try NativeCMAF.child(Data(sound.payload.dropFirst(28)), "esds")
      let asc = try Self.audioSpecificConfiguration(Data(esds.dropFirst(4)))
      let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
      guard asc.count == 2, asc[0] >> 3 == 2, asc[1] & 7 == 0 else { throw NativeHLSError.unsupported }
      let rateIndex = Int((asc[0] & 7) << 1 | asc[1] >> 7)
      let channelIndex = Int((asc[1] >> 3) & 15)
      let channels = [0, 1, 2, 3, 4, 5, 6, 8]
      guard rates.indices.contains(rateIndex), channels.indices.contains(channelIndex),
        channels[channelIndex] > 0, rates[rateIndex] == audio.scale,
        try NativeCMAF.integer(sound.payload, 16, 2) == channels[channelIndex],
        try NativeCMAF.integer(sound.payload, 24) == audio.scale << 16 else { throw NativeHLSError.unsupported }
      do {
        configuration = try .init(sps: sps, pps: pps, audioConfig: asc,
          audioRate: Int(audio.scale), audioChannels: channels[channelIndex], videoTimescale: Int(video.scale))
      } catch NativeHLSError.transportCodec { throw NativeHLSError.unsupported }
      guard configuration.width == (try NativeCMAF.integer(image.payload, 24, 2)),
        configuration.height == (try NativeCMAF.integer(image.payload, 26, 2)) else {
        throw NativeHLSError.invalidMedia
      }
    }

    private static func audioSpecificConfiguration(_ data: Data) throws -> Data {
      func descriptor(_ bytes: Data, tag: UInt8) throws -> Data {
        guard bytes.first == tag else { throw NativeHLSError.unsupported }
        var position = 1
        var size = 0
        for index in 0..<4 {
          guard position < bytes.count else { throw NativeHLSError.invalidMedia }
          let value = bytes[position]
          position += 1
          size = (size << 7) | Int(value & 0x7F)
          if value & 0x80 == 0 {
            guard size <= bytes.count - position else { throw NativeHLSError.invalidMedia }
            return bytes.subdata(in: position..<(position + size))
          }
          if index == 3 { throw NativeHLSError.invalidMedia }
        }
        throw NativeHLSError.invalidMedia
      }
      let stream = try descriptor(data, tag: 3)
      guard stream.count >= 3 else { throw NativeHLSError.invalidMedia }
      var position = 3
      if stream[2] & 0x80 != 0 { position += 2 }
      if stream[2] & 0x40 != 0 {
        guard position < stream.count else { throw NativeHLSError.invalidMedia }
        position += 1 + Int(stream[position])
      }
      if stream[2] & 0x20 != 0 { position += 2 }
      guard position <= stream.count else { throw NativeHLSError.invalidMedia }
      let decoder = try descriptor(Data(stream.dropFirst(position)), tag: 4)
      guard decoder.count >= 13, decoder[0] == 0x40, decoder[1] >> 2 == 5 else {
        throw NativeHLSError.unsupported
      }
      return try descriptor(Data(decoder.dropFirst(13)), tag: 5)
    }
  }

  let format: Format
  private let descriptionIndex: UInt32
  private let reference: UInt64?
  private var buffer = Data()
  private var pendingMovie: Data?
  private var bytesRead = 0
  private var videoEnd: UInt64?
  private var audioEnd: UInt64?
  private var compositionShift: Int64?
  private var pending = Data()
  private var partDuration = 0.0
  private var totalVideoTicks: UInt64 = 0
  private var totalDuration: Double { Double(totalVideoTicks) / Double(format.video.scale) }
  private var partVideoStart: UInt64 = 0
  private var partPresentationStart: Int64 = 0
  private var partAudioStart: UInt64 = 0
  private var partIndependent = false
  private var videoSamples = 0
  private var audioSamples = 0
  private var finished = false
  private(set) var nextSequence: UInt32

  init(format: Format, videoDescriptionIndex: UInt32, firstSequence: UInt32,
       presentationReference: UInt64?) throws {
    guard (1...16).contains(videoDescriptionIndex) else { throw NativeHLSError.invalidMedia }
    self.format = format
    descriptionIndex = videoDescriptionIndex
    nextSequence = firstSequence
    reference = presentationReference
  }

  mutating func append(_ data: Data) throws -> [NativeTransportRemuxer.Part] {
    guard !finished, bytesRead <= 32 * 1024 * 1024 - data.count else { throw NativeHLSError.invalidMedia }
    bytesRead += data.count
    buffer.append(data)
    var output: [NativeTransportRemuxer.Part] = []
    while buffer.count >= 8 {
      let length = try NativeCMAF.integer(buffer, 0)
      if length == 1, buffer.count < 16 { break }
      let header = length == 1 ? 16 : 8
      let size = length == 1 ? try NativeCMAF.integer(buffer, 8, 8) : length
      guard size >= header, size <= 32 * 1024 * 1024 else { throw NativeHLSError.invalidMedia }
      guard buffer.count >= size else { break }
      let bytes = Data(buffer.prefix(Int(size)))
      buffer.removeFirst(Int(size))
      let box = try NativeCMAF.boxes(bytes)[0]
      switch box.type {
      case "moof":
        guard pendingMovie == nil else { throw NativeHLSError.invalidMedia }
        pendingMovie = bytes
      case "mdat":
        guard let movie = pendingMovie else { throw NativeHLSError.invalidMedia }
        output += try consume(movie + bytes)
        pendingMovie = nil
      case "emsg", "styp", "sidx", "free", "prft":
        guard pendingMovie == nil else { throw NativeHLSError.unsupported }
      default:
        throw NativeHLSFailureDetail.isoBox(type: try NativeCMAF.integer(bytes, 4), bytes: size)
      }
    }
    return output
  }

  mutating func finish(expectedDuration: Double?) throws -> [NativeTransportRemuxer.Part] {
    guard !finished, buffer.isEmpty, pendingMovie == nil, totalDuration > 0 else {
      throw NativeHLSError.invalidMedia
    }
    if let expectedDuration {
      guard expectedDuration.isFinite, expectedDuration > 0, expectedDuration <= 10,
        abs(totalDuration - expectedDuration) <= 0.15 else {
        throw NativeHLSError.transition
      }
    }
    finished = true
    return partDuration > 0 ? [flush()] : []
  }

  private mutating func consume(_ data: Data) throws -> [NativeTransportRemuxer.Part] {
    let moof = try NativeCMAF.child(data, "moof")
    let video = try NativeCMAF.fragmentTiming(moof, track: format.video)
    let audio = try NativeCMAF.fragmentTiming(moof, track: format.audio)
    let clocks: (UInt64, UInt64)
    if let videoEnd, let audioEnd {
      clocks = (try NativeCMAFClock.unwrap(video.decodeTime, version: video.version,
        scale: format.video.scale, near: videoEnd),
        try NativeCMAFClock.unwrap(audio.decodeTime, version: audio.version,
          scale: format.audio.scale, near: audioEnd))
      guard abs(Double(clocks.0) - Double(videoEnd)) <= 1,
        abs(Double(clocks.1) - Double(audioEnd)) <= 1 else { throw NativeHLSError.transition }
    } else {
      clocks = try NativeCMAFClock.initial(video: video, audio: audio, videoScale: format.video.scale,
        audioScale: format.audio.scale, reference: reference)
      guard video.independent else { throw NativeHLSError.transportKeyframe }
      guard abs((Double(clocks.0) + Double(video.firstComposition)) / Double(format.video.scale)
        - Double(clocks.1) / Double(format.audio.scale)) <= 0.25 else { throw NativeHLSError.transition }
      compositionShift = -video.firstComposition
    }
    guard video.duration <= NativeMediaClock.maximum, audio.duration <= NativeMediaClock.maximum,
      clocks.0 <= NativeMediaClock.maximum - video.duration,
      clocks.1 <= NativeMediaClock.maximum - audio.duration,
      let compositionShift else { throw NativeHLSError.invalidMedia }
    videoEnd = clocks.0 + video.duration
    audioEnd = clocks.1 + audio.duration
    guard abs((Double(clocks.0 + video.duration) - Double(compositionShift)) / Double(format.video.scale)
      - Double(clocks.1 + audio.duration) / Double(format.audio.scale)) <= 0.15 else {
      throw NativeHLSError.transition
    }
    let mapped = Int64(clocks.0) - compositionShift
    guard mapped >= 0, mapped <= NativeMediaClock.maximum, nextSequence < UInt32.max else {
      throw NativeHLSError.invalidMedia
    }
    let maximumTicks = format.video.scale * 10
    guard video.duration <= maximumTicks, totalVideoTicks <= maximumTicks - video.duration else {
      throw NativeHLSError.invalidMedia
    }
    totalVideoTicks += video.duration
    let normalized = try NativeFragmentedMP4.controlledFragment(data, video: format.video, audio: format.audio,
      videoDescriptionIndex: descriptionIndex, videoDecodeTime: UInt64(mapped),
      compositionShift: compositionShift, audioDecodeTime: clocks.1, sequence: nextSequence)
    return try appendNormalized(normalized)
  }

  private mutating func appendNormalized(_ data: Data) throws -> [NativeTransportRemuxer.Part] {
    let moof = try NativeCMAF.child(data, "moof")
    let video = try NativeCMAF.fragmentTiming(moof, track: format.video)
    let audio = try NativeCMAF.fragmentTiming(moof, track: format.audio)
    let duration = Double(video.duration) / Double(format.video.scale)
    var output: [NativeTransportRemuxer.Part] = []
    if partDuration + duration > 0.45 {
      if partDuration >= 0.3825 {
        output.append(flush())
        output += try appendNormalized(data)
        return output
      } else {
        let pieces = try NativeFragmentedMP4.splitControlledFragment(data,
          video: format.video, audio: format.audio, maximumDuration: 0.45 - partDuration,
          sequence: nextSequence)
        output += try appendNormalized(pieces.0)
        output += try appendNormalized(pieces.1)
        return output
      }
    }
    if partDuration == 0 {
      partVideoStart = video.decodeTime
      partPresentationStart = Int64(video.decodeTime) + video.firstComposition
      partAudioStart = audio.decodeTime
      partIndependent = video.independent
    }
    guard nextSequence < UInt32.max else { throw NativeHLSError.invalidMedia }
    pending += try NativeFragmentedMP4.resequencedFragment(data, sequence: nextSequence)
    nextSequence += 1
    partDuration += duration
    videoSamples += video.samples
    audioSamples += audio.samples
    if partDuration >= 0.3825 { output.append(flush()) }
    return output
  }

  private mutating func flush() -> NativeTransportRemuxer.Part {
    let result = NativeTransportRemuxer.Part(bytes: pending, duration: partDuration,
      independent: partIndependent, decodeTime: partVideoStart, presentationTime: partPresentationStart,
      audioDecodeTime: partAudioStart, videoSamples: videoSamples, audioSamples: audioSamples)
    pending = Data()
    partDuration = 0
    videoSamples = 0
    audioSamples = 0
    return result
  }
}

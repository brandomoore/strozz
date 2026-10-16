import Foundation

struct NativeTransportRemuxer {
  struct Part: Sendable {
    let bytes: Data
    let duration: Double
    let independent: Bool
    let decodeTime: UInt64
    let presentationTime: Int64
    let audioDecodeTime: UInt64?
    let videoSamples: Int
    let audioSamples: Int
  }

  private let expectedConfiguration: NativeFragmentedMP4.Configuration?
  private let videoDescriptionIndex: UInt32
  private var presentationEpoch: UInt64
  private let presentationReference: UInt64?
  private var transport = NativeTransportStream()
  private var demuxer = NativeTransportDemuxer()
  private var previousVideo: NativeTransportDemuxer.Video?
  private var firstVideoDTS: UInt64?
  private var videoStart: UInt64?
  private var lastVideoInterval: UInt32?
  private var video: [NativeFragmentedMP4.Sample] = []
  private var videoDuration: UInt64 = 0
  private var queuedVideo: [[NativeFragmentedMP4.Sample]] = []
  private var rawAudio: [NativeTransportDemuxer.Audio] = []
  private var audio: [NativeFragmentedMP4.Sample] = []
  private var lastAudioEnd: UInt64?
  private(set) var configuration: NativeFragmentedMP4.Configuration?
  private(set) var nextSequence: UInt32
  private(set) var completed = false
  private static let wrap: UInt64 = 1 << 33

  init(configuration: NativeFragmentedMP4.Configuration? = nil, videoDescriptionIndex: UInt32 = 1,
       firstSequence: UInt32 = 1, presentationEpoch: UInt64 = 0,
       presentationReference: UInt64? = nil) throws {
    guard (1...16).contains(videoDescriptionIndex), presentationEpoch.isMultiple(of: Self.wrap),
      presentationEpoch <= NativeMediaClock.maximum,
      presentationReference.map({ $0 <= NativeMediaClock.maximum }) ?? true else {
      throw NativeHLSError.invalidMedia
    }
    expectedConfiguration = configuration
    self.videoDescriptionIndex = videoDescriptionIndex
    self.presentationEpoch = presentationEpoch
    self.presentationReference = presentationReference
    nextSequence = firstSequence
  }

  mutating func append(_ packet: Data) throws -> [Part] {
    guard !completed, transport.byteCount < 32 * 1024 * 1024 else { throw NativeHLSError.invalidMedia }
    _ = try transport.append(packet)
    if let pids = transport.mediaPIDs {
      try observe(demuxer.append(packet, videoPID: pids.video, audioPID: pids.audio))
    }
    return try publish(final: false)
  }

  mutating func finish(expectedDuration: Double?) throws -> [Part] {
    guard !completed else { throw NativeHLSError.invalidMedia }
    _ = try transport.finish(expectedDuration: expectedDuration)
    try observe(demuxer.finishSegment())
    guard let previousVideo, let lastVideoInterval else { throw NativeHLSError.invalidMedia }
    try appendVideo(previousVideo, duration: lastVideoInterval)
    self.previousVideo = nil
    if !video.isEmpty {
      queuedVideo.append(video)
      video = []
      videoDuration = 0
    }
    let output = try publish(final: true)
    guard queuedVideo.isEmpty, audio.isEmpty, rawAudio.isEmpty else { throw NativeHLSError.invalidMedia }
    completed = true
    return output
  }

  private mutating func observe(_ units: [NativeTransportDemuxer.Unit]) throws {
    for unit in units {
      switch unit {
      case .video(let value):
        if firstVideoDTS == nil {
          firstVideoDTS = value.decodeTime
          if let presentationReference {
            let unwrapped = try NativeMediaClock.unwrap(value.presentationTime, near: presentationReference)
            presentationEpoch = unwrapped - value.presentationTime
          }
          videoStart = presentationEpoch + value.presentationTime
        }
        if let previousVideo {
          let interval = (value.decodeTime + Self.wrap - previousVideo.decodeTime) % Self.wrap
          guard interval > 0, interval <= 9000 else { throw NativeHLSError.transition }
          lastVideoInterval = UInt32(interval)
          try appendVideo(previousVideo, duration: UInt32(interval))
        }
        previousVideo = value
      case .audio(let value): rawAudio.append(value)
      }
    }
    if configuration == nil, let sps = demuxer.sps, let pps = demuxer.pps,
      let audio = demuxer.audioConfiguration {
      let value = try NativeFragmentedMP4.Configuration(sps: sps, pps: pps,
        audioConfig: audio.bytes, audioRate: audio.rate, audioChannels: audio.channels)
      if let expectedConfiguration, expectedConfiguration != value { throw NativeHLSError.transition }
      configuration = value
    }
    if let configuration, let videoStart {
      let rate = UInt64(configuration.audioRate)
      let cycle = (Self.wrap * rate + 45_000) / 90_000
      let expected = (videoStart * rate + 45_000) / 90_000
      for raw in rawAudio {
        var clock = raw.decodeTime + (presentationEpoch * rate + 45_000) / 90_000
        while clock > expected, clock - expected > cycle / 2 {
          guard clock >= cycle else { throw NativeHLSError.transition }
          clock -= cycle
        }
        while expected > clock, expected - clock > cycle / 2 { clock += cycle }
        if let lastAudioEnd {
          let distance = clock > lastAudioEnd ? clock - lastAudioEnd : lastAudioEnd - clock
          if distance <= 1 { clock = lastAudioEnd }
          else if clock < lastAudioEnd { throw NativeHLSError.transition }
        }
        audio.append(.init(decodeTime: clock, duration: raw.duration,
          compositionOffset: 0, independent: true, bytes: raw.bytes))
        lastAudioEnd = clock + UInt64(raw.duration)
      }
      rawAudio.removeAll(keepingCapacity: true)
    }
  }

  private mutating func appendVideo(_ frame: NativeTransportDemuxer.Video, duration: UInt32) throws {
    guard let firstVideoDTS, let videoStart else { throw NativeHLSError.invalidMedia }
    let time = videoStart + (frame.decodeTime + Self.wrap - firstVideoDTS) % Self.wrap
    var relativePTS = Int64((frame.presentationTime + Self.wrap - (videoStart % Self.wrap)) % Self.wrap)
    if relativePTS > Int64(Self.wrap / 2) { relativePTS -= Int64(Self.wrap) }
    guard let signedStart = Int64(exactly: videoStart), let signedTime = Int64(exactly: time),
      let composition = Int32(exactly: signedStart + relativePTS - signedTime) else {
      throw NativeHLSError.invalidMedia
    }
    video.append(.init(decodeTime: time, duration: duration, compositionOffset: composition,
      independent: frame.independent, bytes: frame.bytes))
    videoDuration += UInt64(duration)
    guard videoDuration <= 40_500 else { throw NativeHLSError.partDuration }
    if videoDuration >= 34_425 {
      queuedVideo.append(video)
      video = []
      videoDuration = 0
    }
  }

  private mutating func publish(final: Bool) throws -> [Part] {
    guard let configuration else {
      if final { throw NativeHLSError.transportCodec }
      return []
    }
    let rate = UInt64(configuration.audioRate)
    var output: [Part] = []
    while let first = queuedVideo.first, let beginning = first.first, let last = first.last {
      let end = last.decodeTime + UInt64(last.duration)
      let audioEnd = lastAudioEnd.map { Double($0) / Double(rate) }
      guard audioEnd.map({ $0 >= Double(end) / 90_000 }) == true || final else { break }
      if final {
        guard let audioEnd, audioEnd >= Double(end) / 90_000 - 0.1 else {
          throw NativeHLSError.transition
        }
      }
      let lastPart = final && queuedVideo.count == 1
      let count = lastPart ? audio.count : audio.prefix { $0.decodeTime * 90_000 < end * rate }.count
      let audioPart = Array(audio.prefix(count))
      guard !audioPart.isEmpty else { throw NativeHLSError.transition }
      let bytes = try NativeFragmentedMP4.fragment(sequence: nextSequence, video: first, audio: audioPart,
        videoDescriptionIndex: videoDescriptionIndex)
      guard nextSequence < UInt32.max else { throw NativeHLSError.invalidMedia }
      nextSequence += 1
      output.append(.init(bytes: bytes, duration: Double(end - beginning.decodeTime) / 90_000,
        independent: beginning.independent, decodeTime: beginning.decodeTime,
        presentationTime: Int64(beginning.decodeTime) + Int64(beginning.compositionOffset),
        audioDecodeTime: audioPart.first?.decodeTime, videoSamples: first.count, audioSamples: audioPart.count))
      audio.removeFirst(count)
      queuedVideo.removeFirst()
    }
    return output
  }
}

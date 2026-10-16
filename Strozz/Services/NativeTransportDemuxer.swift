import Foundation

struct NativeTransportDemuxer {
  struct Video: Sendable {
    let decodeTime: UInt64
    let presentationTime: UInt64
    let independent: Bool
    let bytes: Data
  }

  struct AudioConfiguration: Equatable, Sendable {
    let bytes: Data
    let rate: Int
    let channels: Int
  }

  struct Audio: Sendable {
    let decodeTime: UInt64
    let duration: UInt32
    let bytes: Data
  }

  enum Unit: Sendable {
    case video(Video)
    case audio(Audio)
  }

  private struct PES {
    let audio: Bool
    var bytes = Data()
    var length: Int?
  }

  private struct VideoClock: Equatable {
    let pts: UInt64
    let dts: UInt64
  }

  private var videoPending = Data()
  private var videoOffset = 0
  private var videoAnchors: [(offset: Int, clock: VideoClock)] = []
  private var currentVideoClock: VideoClock?
  private var currentVideoBytes = Data()
  private var currentVideoHasSlice = false
  private var currentVideoIndependent = false
  private var pending: [Int: PES] = [:]
  private var mediaPIDs: (video: Int, audio: Int)?
  private var continuity: [Int: (counter: Int, packet: Data)] = [:]
  private(set) var sps: Data?
  private(set) var pps: Data?
  private(set) var audioConfiguration: AudioConfiguration?

  mutating func beginSegment() throws {
    guard pending.isEmpty, videoPending.isEmpty, currentVideoClock == nil else {
      throw NativeHLSError.invalidMedia
    }
    continuity.removeAll(keepingCapacity: true)
    mediaPIDs = nil
  }

  mutating func append(_ packet: Data, videoPID: Int, audioPID: Int) throws -> [Unit] {
    guard videoPID != audioPID else { throw NativeHLSError.transportCodec }
    if let mediaPIDs, mediaPIDs.video != videoPID || mediaPIDs.audio != audioPID {
      throw NativeHLSError.transition
    }
    mediaPIDs = (videoPID, audioPID)
    let bytes = Array(packet)
    guard bytes.count == 188, bytes[0] == 0x47 else { throw NativeHLSError.invalidMedia }
    let pid = Int(bytes[1] & 31) << 8 | Int(bytes[2])
    guard pid == videoPID || pid == audioPID else { return [] }
    let adaptation = (bytes[3] >> 4) & 3
    var offset = 4
    if adaptation & 2 != 0 { offset += 1 + Int(bytes[4]) }
    guard offset <= 188 else { throw NativeHLSError.invalidMedia }
    guard adaptation & 1 != 0, offset < 188 else { return [] }
    let counter = Int(bytes[3] & 15)
    if let old = continuity[pid], counter != (old.counter + 1) % 16 {
      if counter == old.counter, old.packet == packet { return [] }
      throw NativeHLSFailureDetail.transportContinuity
    }
    continuity[pid] = (counter, packet)
    var result: [Unit] = []
    if bytes[1] & 0x40 != 0 {
      if let old = pending.removeValue(forKey: pid) {
        guard old.length == nil || old.bytes.count == old.length else { throw NativeHLSError.invalidMedia }
        result += try decode(old)
      }
      pending[pid] = PES(audio: pid == audioPID)
    }
    guard var value = pending[pid] else { return result }
    value.bytes.append(contentsOf: bytes[offset...])
    guard value.bytes.count <= 4 * 1024 * 1024 else { throw NativeHLSError.invalidMedia }
    if value.length == nil, value.bytes.count >= 6 {
      guard value.bytes.prefix(3) == Data([0, 0, 1]) else { throw NativeHLSError.invalidMedia }
      let length = Int(value.bytes[4]) << 8 | Int(value.bytes[5])
      if length > 0 { value.length = length + 6 }
      else if value.audio { throw NativeHLSError.transportCodec }
    }
    if let length = value.length, value.bytes.count >= length {
      value.bytes = Data(value.bytes.prefix(length))
      pending.removeValue(forKey: pid)
      result += try decode(value)
    } else {
      pending[pid] = value
    }
    return result
  }

  mutating func finishSegment() throws -> [Unit] {
    let values = pending.sorted { $0.key < $1.key }.map(\.value)
    pending.removeAll(keepingCapacity: true)
    var result: [Unit] = []
    for value in values {
      guard value.length == nil || value.bytes.count == value.length else { throw NativeHLSError.invalidMedia }
      result += try decode(value)
    }
    result += try drainVideo(final: true)
    if currentVideoHasSlice { result.append(try finishVideo()) }
    videoOffset = 0
    videoAnchors.removeAll(keepingCapacity: true)
    return result
  }

  private mutating func decode(_ value: PES) throws -> [Unit] {
    let bytes = value.bytes
    guard bytes.count >= 14, bytes.prefix(3) == Data([0, 0, 1]),
      bytes[6] & 0xC0 == 0x80 else { throw NativeHLSError.invalidMedia }
    let flags = bytes[7] >> 6
    guard flags == 2 || flags == 3 else { throw NativeHLSError.invalidMedia }
    let header = 9 + Int(bytes[8])
    guard header <= bytes.count else { throw NativeHLSError.invalidMedia }
    let pts = try NativeTransportStream.timestamp(bytes, at: 9)
    let dts = flags == 3 ? try NativeTransportStream.timestamp(bytes, at: 14) : pts
    let payload = Data(bytes.dropFirst(header))
    guard !payload.isEmpty else { throw NativeHLSError.invalidMedia }
    if value.audio { return try audio(payload, presentationTime: pts) }
    videoAnchors.append((videoOffset + videoPending.count, VideoClock(pts: pts, dts: dts)))
    videoPending.append(payload)
    guard videoPending.count <= 4 * 1024 * 1024, videoAnchors.count <= 512 else {
      throw NativeHLSError.invalidMedia
    }
    return try drainVideo(final: false)
  }

  private mutating func finishVideo() throws -> Unit {
    guard currentVideoHasSlice, let clock = currentVideoClock, sps != nil, pps != nil else {
      throw NativeHLSError.transportCodec
    }
    let video = Video(decodeTime: clock.dts, presentationTime: clock.pts,
      independent: currentVideoIndependent, bytes: currentVideoBytes)
    currentVideoClock = nil
    currentVideoBytes = Data()
    currentVideoHasSlice = false
    currentVideoIndependent = false
    return .video(video)
  }

  private mutating func videoNAL(_ nal: Data, at position: Int) throws -> [Unit] {
    guard let first = nal.first, let anchor = videoAnchors.last(where: { $0.offset <= position }) else {
      throw NativeHLSError.invalidMedia
    }
    let type = first & 31
    var result: [Unit] = []
    // A PES can start with the tail of the previous NAL. Its timestamp belongs
    // to the access unit beginning inside it, not to that leading continuation.
    let prefix = type == 6 || type == 7 || type == 8 || (14...18).contains(type)
    let firstSlice = (type == 1 || type == 2 || type == 5) ? try Self.firstMacroblock(nal) == 0 : false
    if currentVideoHasSlice, type == 9 || prefix || firstSlice {
      result.append(try finishVideo())
    }
    if currentVideoClock == nil { currentVideoClock = anchor.clock }
    if type == 7 {
      if let sps, sps != nal { throw NativeHLSError.transition }
      sps = nal
    } else if type == 8 {
      if let pps, pps != nal { throw NativeHLSError.transition }
      pps = nal
    } else {
      currentVideoHasSlice = currentVideoHasSlice || (1...5).contains(type)
      currentVideoIndependent = currentVideoIndependent || type == 5
      let count = UInt32(nal.count)
      currentVideoBytes.append(contentsOf: [
        UInt8(count >> 24), UInt8((count >> 16) & 255),
        UInt8((count >> 8) & 255), UInt8(count & 255),
      ])
      currentVideoBytes.append(nal)
      guard currentVideoBytes.count <= 4 * 1024 * 1024 else { throw NativeHLSError.invalidMedia }
    }
    return result
  }

  private mutating func drainVideo(final: Bool) throws -> [Unit] {
    guard !videoPending.isEmpty else { return [] }
    let bytes = Array(videoPending)
    let starts = Self.nalStarts(bytes)
    guard let first = starts.first else {
      if final { throw NativeHLSError.invalidMedia }
      return []
    }
    guard bytes[..<first.marker].allSatisfy({ $0 == 0 }) else { throw NativeHLSError.invalidMedia }
    let count = final ? starts.count : starts.count - 1
    var result: [Unit] = []
    for number in 0..<count {
      let start = starts[number]
      let end = number + 1 < starts.count ? starts[number + 1].marker : bytes.count
      guard end > start.payload else { throw NativeHLSError.invalidMedia }
      result += try videoNAL(Data(bytes[start.payload..<end]), at: videoOffset + start.payload)
    }
    let consumed = final ? bytes.count : starts[starts.count - 1].marker
    videoPending.removeFirst(consumed)
    videoOffset += consumed
    if let keep = videoAnchors.lastIndex(where: { $0.offset <= videoOffset }), keep > 0 {
      videoAnchors.removeFirst(keep)
    }
    return result
  }

  private mutating func audio(_ data: Data, presentationTime: UInt64) throws -> [Unit] {
    let bytes = Array(data)
    let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
                 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
    var offset = 0
    var samples: UInt64 = 0
    var output: [Unit] = []
    while offset < bytes.count {
      guard bytes.count - offset >= 7, bytes[offset] == 0xFF, bytes[offset + 1] & 0xF6 == 0xF0 else {
        throw NativeHLSError.transportCodec
      }
      let objectType = Int(bytes[offset + 2] >> 6) + 1
      let rateIndex = Int((bytes[offset + 2] >> 2) & 15)
      let channelCode = Int(bytes[offset + 2] & 1) << 2 | Int(bytes[offset + 3] >> 6)
      guard objectType == 2, rates.indices.contains(rateIndex), (1...7).contains(channelCode) else {
        throw NativeHLSError.transportCodec
      }
      let config = AudioConfiguration(bytes: Data([
        UInt8(objectType << 3 | rateIndex >> 1),
        UInt8((rateIndex & 1) << 7 | channelCode << 3),
      ]), rate: rates[rateIndex], channels: channelCode == 7 ? 8 : channelCode)
      if let audioConfiguration, audioConfiguration != config { throw NativeHLSError.transition }
      audioConfiguration = config
      let header = bytes[offset + 1] & 1 != 0 ? 7 : 9
      let length = Int(bytes[offset + 3] & 3) << 11
        | Int(bytes[offset + 4]) << 3 | Int(bytes[offset + 5] >> 5)
      guard length > header, length <= bytes.count - offset else { throw NativeHLSError.invalidMedia }
      guard bytes[offset + 6] & 3 == 0 else { throw NativeHLSError.transportCodec }
      let duration: UInt32 = 1024
      let clock = (presentationTime * UInt64(config.rate) + 45_000) / 90_000 + samples
      output.append(.audio(Audio(decodeTime: clock, duration: duration,
        bytes: Data(bytes[(offset + header)..<(offset + length)]))))
      samples += UInt64(duration)
      offset += length
    }
    return output
  }

  private static func nalStarts(_ bytes: [UInt8]) -> [(marker: Int, payload: Int)] {
    var starts: [(marker: Int, payload: Int)] = []
    var index = 0
    while index + 3 <= bytes.count {
      if bytes[index] == 0, bytes[index + 1] == 0 {
        if bytes[index + 2] == 1 {
          starts.append((index, index + 3))
          index += 3
          continue
        }
        if index + 4 <= bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
          starts.append((index, index + 4))
          index += 4
          continue
        }
      }
      index += 1
    }
    return starts
  }

  private static func firstMacroblock(_ nal: Data) throws -> UInt32 {
    var rbsp: [UInt8] = []
    var zeros = 0
    for byte in nal.dropFirst().prefix(16) {
      if zeros >= 2, byte == 3 { zeros = 0; continue }
      rbsp.append(byte)
      zeros = byte == 0 ? zeros + 1 : 0
    }
    var position = 0
    func bit() throws -> UInt32 {
      guard position < rbsp.count * 8 else { throw NativeHLSError.invalidMedia }
      defer { position += 1 }
      return UInt32((rbsp[position / 8] >> (7 - position % 8)) & 1)
    }
    var count = 0
    while try bit() == 0 {
      count += 1
      guard count <= 31 else { throw NativeHLSError.invalidMedia }
    }
    var suffix: UInt32 = 0
    for _ in 0..<count { suffix = suffix << 1 | (try bit()) }
    return (UInt32(1) << count) - 1 + suffix
  }
}

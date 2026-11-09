import Foundation

/// Indexes original H.264 transport-stream packets without changing their bytes.
/// Cuts at video PES boundaries; startup requires an IDR or a verified predecessor.
struct NativeTransportStream {
  struct Continuation: Sendable {
    fileprivate let clock: UInt64
    fileprivate let videoPID: Int
    fileprivate let audioPID: Int
  }
  struct Range: Equatable {
    let offset: Int
    let length: Int
    let duration: Double
    let independent: Bool
    var timeline: [String: Double] = [:]
  }

  private(set) var byteCount = 0
  private(set) var duration = 0.0
  private(set) var initializationLength = 0
  private var pmtPID: Int?
  private var videoPID: Int?
  private var audioPID: Int?
  private var firstClock: UInt64?
  private var previousClock: UInt64?
  private var lastInterval: UInt64?
  private var partClock: UInt64?
  private var partOffset = 0
  private var partNumber = 0
  private var lastContinuity: Int?
  private var lastVideoPacket: Data?
  private var hasInitialIDR = false
  private var verifiedStart = false
  private let predecessor: Continuation?
  private var initialVideo = Data()
  private let capturesDiagnostics: Bool
  private var partPresentationClock: UInt64?
  private var firstAudioClock: UInt64?
  private var diagnosticTimestampErrors = 0
  private var videoProfile: UInt8?
  private var videoLevel: UInt8?

  private static let wrap: UInt64 = 1 << 33

  init(capturesDiagnostics: Bool = false, continuing predecessor: Continuation? = nil) {
    self.capturesDiagnostics = capturesDiagnostics
    self.predecessor = predecessor
  }

  private(set) var continuation: Continuation?

  static func randomAccessSegment(_ data: Data) throws -> (bytes: Data, skippedDuration: Double) {
    guard !data.isEmpty, data.count <= 32 * 1024 * 1024, data.count.isMultiple(of: 188) else {
      throw NativeHLSError.invalidMedia
    }
    var header = NativeTransportStream()
    var tables = Data()
    var first: UInt64?
    var videoPID: Int?
    for offset in stride(from: 0, to: data.count, by: 188) {
      let packet = data.subdata(in: offset..<offset + 188)
      let pid = Int(packet[1] & 31) << 8 | Int(packet[2])
      if first == nil {
        do { _ = try header.append(packet) }
        catch NativeHLSError.transportKeyframe { /* Search later access units at startup only. */ }
        if pid == 0 || pid == header.pmtPID { tables.append(packet) }
        first = header.firstClock
        videoPID = header.videoPID
      }
      guard let first, pid == videoPID, packet[1] & 0x40 != 0 else { continue }
      var candidate = NativeTransportStream()
      for tableOffset in stride(from: 0, to: tables.count, by: 188) {
        _ = try candidate.append(tables.subdata(in: tableOffset..<tableOffset + 188))
      }
      do {
        for position in stride(from: offset, to: data.count, by: 188) {
          _ = try candidate.append(data.subdata(in: position..<position + 188))
          if candidate.hasInitialIDR {
            guard let clock = candidate.firstClock else { throw NativeHLSError.invalidMedia }
            return (tables + data.suffix(from: offset),
              Double(candidate.distance(clock, first)) / 90_000)
          }
        }
      } catch NativeHLSError.transportKeyframe {
        continue
      }
    }
    throw NativeHLSError.transportKeyframe
  }

  var mediaPIDs: (video: Int, audio: Int)? {
    guard let videoPID, let audioPID else { return nil }
    return (videoPID, audioPID)
  }

  private mutating func diagnosticTimestamp(_ data: Data, at offset: Int) -> UInt64? {
    let value = try? Self.timestamp(data, at: offset)
    if value == nil { diagnosticTimestampErrors += 1 }
    return value
  }

  private func timeline(start: UInt64) -> [String: Double] {
    guard capturesDiagnostics else { return [:] }
    var values = ["video_decode_start_seconds": Double(start) / 90_000,
      "diagnostic_timestamp_errors": Double(diagnosticTimestampErrors)]
    values["video_presentation_start_seconds"] = partPresentationClock.map { Double($0) / 90_000 }
    values["audio_first_presentation_seconds"] = firstAudioClock.map { Double($0) / 90_000 }
    values["transport_first_decode_seconds"] = firstClock.map { Double($0) / 90_000 }
    values["video_pid"] = videoPID.map(Double.init)
    values["audio_pid"] = audioPID.map(Double.init)
    values["avc_profile_idc"] = videoProfile.map(Double.init)
    values["avc_level_idc"] = videoLevel.map(Double.init)
    return values
  }

  static func timestamp(_ data: Data, at offset: Int) throws -> UInt64 {
    guard offset >= 0, data.count - offset >= 5 else { throw NativeHLSError.invalidMedia }
    let b = Array(data.dropFirst(offset).prefix(5))
    guard b[0] & 1 == 1, b[2] & 1 == 1, b[4] & 1 == 1 else { throw NativeHLSError.invalidMedia }
    return UInt64(b[0] & 14) << 29 | UInt64(b[1]) << 22 | UInt64(b[2] & 254) << 14
      | UInt64(b[3]) << 7 | UInt64(b[4] >> 1)
  }

  private func distance(_ later: UInt64, _ earlier: UInt64) -> UInt64 {
    (later &+ Self.wrap &- earlier) % Self.wrap
  }

  mutating func append(_ packet: Data) throws -> Range? {
    guard packet.count == 188 else { throw NativeHLSError.invalidMedia }
    return try packet.withUnsafeBytes { bytes in
      try append(packet, bytes: bytes.bindMemory(to: UInt8.self))
    }
  }

  private mutating func append(_ packet: Data, bytes b: UnsafeBufferPointer<UInt8>) throws -> Range? {
    guard b[0] == 0x47, b[1] & 0x80 == 0, b[3] & 0xC0 == 0 else { throw NativeHLSError.invalidMedia }
    let pid = Int(b[1] & 31) << 8 | Int(b[2])
    let start = b[1] & 0x40 != 0
    let adaptation = (b[3] >> 4) & 3
    guard adaptation != 0 else { throw NativeHLSError.invalidMedia }
    var position = 4
    if adaptation & 2 != 0 {
      position += 1 + Int(b[4])
      guard position <= 188 else { throw NativeHLSError.invalidMedia }
      if b[4] > 0, b[5] & 0x80 != 0, pid == videoPID {
        guard firstClock == nil, predecessor == nil else { throw NativeHLSError.transition }
        lastContinuity = nil
      }
    }
    let offset = byteCount
    byteCount += 188
    guard adaptation & 1 != 0, position < 188 else { return nil }
    if start, pid == 0 || pid == pmtPID {
      try readTable(Data(b[position...]), pid: pid)
      if pid == pmtPID, firstClock == nil { initializationLength = byteCount }
      return nil
    }
    if capturesDiagnostics, pid == audioPID, start, firstAudioClock == nil {
      let payload = Data(b[position...])
      if payload.count >= 14, payload.prefix(3) == Data([0, 0, 1]),
        payload[7] >> 6 == 2 || payload[7] >> 6 == 3 {
        firstAudioClock = diagnosticTimestamp(payload, at: 9)
      } else {
        diagnosticTimestampErrors += 1
      }
    }
    guard pid == videoPID else { return nil }
    let continuity = Int(b[3] & 15)
    if let lastContinuity, continuity != (lastContinuity + 1) % 16 {
      if continuity == lastContinuity, lastVideoPacket == packet { return nil }
      throw NativeHLSFailureDetail.transportContinuity
    }
    lastContinuity = continuity
    lastVideoPacket = packet
    // Once the starting access unit is verified, continuation payloads do not affect the index.
    // Keep validating their headers and continuity without allocating payload copies.
    guard start || !verifiedStart else { return nil }
    let payload = Data(b[position...])
    var result: Range?
    var videoOffset = 0
    if start {
      guard payload.count >= 14, payload.prefix(3) == Data([0, 0, 1]),
        payload[3] >= 0xE0, payload[3] <= 0xEF,
        payload[6] & 0xC0 == 0x80 else { throw NativeHLSError.unsupported }
      let flags = payload[7] >> 6
      guard flags == 2 || flags == 3 else { throw NativeHLSError.invalidMedia }
      videoOffset = 9 + Int(payload[8])
      guard videoOffset <= payload.count else { throw NativeHLSError.invalidMedia }
      let clock = try Self.timestamp(payload, at: flags == 3 ? 14 : 9)
      let startsPart = firstClock == nil || partClock.map { distance(clock, $0) >= 34_425 } == true
      let presentation = capturesDiagnostics && startsPart ? diagnosticTimestamp(payload, at: 9) : nil
      if let previousClock {
        let interval = distance(clock, previousClock)
        guard interval > 0, interval <= 9000 else { throw NativeHLSFailureDetail.timestampInterval(interval) }
        lastInterval = interval
      }
      previousClock = clock
      if firstClock == nil {
        guard audioPID != nil else { throw NativeHLSError.transportCodec }
        if let predecessor {
          guard predecessor.videoPID == videoPID, predecessor.audioPID == audioPID,
            distance(clock, predecessor.clock) > 0, distance(clock, predecessor.clock) <= 9000 else {
            throw NativeHLSError.transition
          }
        }
        firstClock = clock
        partClock = clock
        partPresentationClock = presentation
      }
      // LL-HLS requires non-terminal parts to reach 85% of the 0.45s target.
      if let partClock, distance(clock, partClock) >= 34_425 {
        guard verifiedStart else { throw NativeHLSError.transportKeyframe }
        let seconds = Double(distance(clock, partClock)) / 90_000
        guard seconds <= 0.45 else { throw NativeHLSError.partDuration }
        result = Range(offset: partOffset, length: offset - partOffset, duration: seconds,
                       independent: partNumber == 0 && hasInitialIDR, timeline: timeline(start: partClock))
        partNumber += 1
        partOffset = offset
        self.partClock = clock
        partPresentationClock = presentation
        duration += seconds
      }
    }
    if !verifiedStart {
      initialVideo.append(payload.dropFirst(videoOffset))
      guard initialVideo.count <= 64 * 1024 else { throw NativeHLSError.transportKeyframe }
      let bytes = Array(initialVideo)
      if bytes.count >= 4 {
        for i in 0..<(bytes.count - 3) {
          if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
            let type = bytes[i + 3] & 31
            if capturesDiagnostics, type == 7, bytes.count > i + 6 {
              videoProfile = bytes[i + 4]
              videoLevel = bytes[i + 6]
            }
            if (1...4).contains(type), predecessor == nil { throw NativeHLSError.transportKeyframe }
            if (1...5).contains(type) {
              hasInitialIDR = type == 5
              verifiedStart = true
              initialVideo.removeAll()
              break
            }
          }
        }
      }
    }
    return result
  }

  mutating func finish(expectedDuration: Double?) throws -> Range {
    guard verifiedStart, let firstClock, let previousClock, let lastInterval, let partClock,
      let videoPID, let audioPID, byteCount > partOffset else { throw NativeHLSError.invalidMedia }
    let fullDuration = Double(distance(previousClock, firstClock) + lastInterval) / 90_000
    if let expectedDuration, abs(fullDuration - expectedDuration) > 0.05 {
      throw NativeHLSFailureDetail.transportDuration(actual: fullDuration, expected: expectedDuration)
    }
    let tail = Double(distance(previousClock, partClock) + lastInterval) / 90_000
    guard tail > 0, tail <= 0.45, fullDuration <= 10 else { throw NativeHLSError.invalidMedia }
    duration = fullDuration
    continuation = Continuation(clock: previousClock, videoPID: videoPID, audioPID: audioPID)
    return Range(offset: partOffset, length: byteCount - partOffset, duration: tail,
                 independent: partNumber == 0 && hasInitialIDR, timeline: timeline(start: partClock))
  }

  private mutating func readTable(_ payload: Data, pid: Int) throws {
    guard let pointer = payload.first else { throw NativeHLSError.invalidMedia }
    let start = 1 + Int(pointer)
    guard payload.count >= start + 3 else { throw NativeHLSError.transportTable }
    let b = Array(payload.dropFirst(start))
    let size = 3 + (Int(b[1] & 15) << 8 | Int(b[2]))
    guard size <= b.count, size >= 12 else { throw NativeHLSError.transportTable }
    if pid == 0 {
      guard b[0] == 0 else { throw NativeHLSError.invalidMedia }
      var programs: [Int] = []
      for i in stride(from: 8, to: size - 4, by: 4) {
        guard i + 3 < size - 4 else { throw NativeHLSError.invalidMedia }
        if b[i] != 0 || b[i + 1] != 0 { programs.append(Int(b[i + 2] & 31) << 8 | Int(b[i + 3])) }
      }
      guard programs.count == 1 else { throw NativeHLSError.transportTable }
      pmtPID = programs[0]
    } else {
      guard b[0] == 2, size >= 16 else { throw NativeHLSError.invalidMedia }
      var i = 12 + (Int(b[10] & 15) << 8 | Int(b[11]))
      while i < size - 4 {
        guard i + 5 <= size - 4 else { throw NativeHLSError.invalidMedia }
        let elementaryPID = Int(b[i + 1] & 31) << 8 | Int(b[i + 2])
        if b[i] == 0x1B { videoPID = elementaryPID }
        if b[i] == 0x0F { audioPID = elementaryPID }
        i += 5 + (Int(b[i + 3] & 15) << 8 | Int(b[i + 4]))
      }
      guard i == size - 4, videoPID != nil, audioPID != nil else { throw NativeHLSError.transportCodec }
    }
  }
}

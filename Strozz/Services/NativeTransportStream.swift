import Foundation

/// Indexes original H.264 transport-stream packets without changing their bytes.
/// Cuts at video PES boundaries; the first range retains PAT/PMT and the IDR.
struct NativeTransportStream {
  struct Range: Equatable {
    let offset: Int
    let length: Int
    let duration: Double
    let independent: Bool
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
  private var initialVideo = Data()

  private static let wrap: UInt64 = 1 << 33

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
    let b = Array(packet)
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
        guard firstClock == nil else { throw NativeHLSError.transition }
        lastContinuity = nil
      }
    }
    let offset = byteCount
    byteCount += 188
    guard adaptation & 1 != 0, position < 188 else { return nil }
    let payload = Data(b[position...])
    if start, pid == 0 || pid == pmtPID {
      try readTable(payload, pid: pid)
      if pid == pmtPID, firstClock == nil { initializationLength = byteCount }
      return nil
    }
    guard pid == videoPID else { return nil }
    let continuity = Int(b[3] & 15)
    if let lastContinuity, continuity != (lastContinuity + 1) % 16 {
      if continuity == lastContinuity, lastVideoPacket == packet { return nil }
      throw NativeHLSError.transition
    }
    lastContinuity = continuity
    lastVideoPacket = packet
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
      if let previousClock {
        let interval = distance(clock, previousClock)
        guard interval > 0, interval <= 9000 else { throw NativeHLSError.transition }
        lastInterval = interval
      }
      previousClock = clock
      if firstClock == nil {
        guard audioPID != nil else { throw NativeHLSError.transportCodec }
        firstClock = clock
        partClock = clock
      }
      if let partClock, distance(clock, partClock) >= 34_200 {
        guard hasInitialIDR else { throw NativeHLSError.transportKeyframe }
        let seconds = Double(distance(clock, partClock)) / 90_000
        guard seconds <= 0.45 else { throw NativeHLSError.partDuration }
        result = Range(offset: partOffset, length: offset - partOffset, duration: seconds,
                       independent: partNumber == 0)
        partNumber += 1
        partOffset = offset
        self.partClock = clock
        duration += seconds
      }
    }
    if !hasInitialIDR {
      initialVideo.append(payload.dropFirst(videoOffset))
      guard initialVideo.count <= 64 * 1024 else { throw NativeHLSError.transportKeyframe }
      let bytes = Array(initialVideo)
      if bytes.count >= 4 {
        for i in 0..<(bytes.count - 3) {
          if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1, bytes[i + 3] & 31 == 5 {
            hasInitialIDR = true
            initialVideo.removeAll()
            break
          }
        }
      }
    }
    return result
  }

  mutating func finish(expectedDuration: Double?) throws -> Range {
    guard hasInitialIDR, let firstClock, let previousClock, let lastInterval, let partClock,
      byteCount > partOffset else { throw NativeHLSError.invalidMedia }
    let fullDuration = Double(distance(previousClock, firstClock) + lastInterval) / 90_000
    if let expectedDuration, abs(fullDuration - expectedDuration) > 0.05 { throw NativeHLSError.transition }
    let tail = Double(distance(previousClock, partClock) + lastInterval) / 90_000
    guard tail > 0, tail <= 0.45, fullDuration <= 10 else { throw NativeHLSError.invalidMedia }
    duration = fullDuration
    return Range(offset: partOffset, length: byteCount - partOffset, duration: tail,
                 independent: partNumber == 0)
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

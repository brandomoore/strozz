import Foundation

struct NativeMediaClock: Sendable {
  static let wrap: UInt64 = 1 << 33
  static let maximum = UInt64.max / 96_000 - 2 * wrap
  private struct Anchor: Sendable { let date: Date; let time: UInt64; let scale: UInt64 }
  private var anchors: [Int: Anchor] = [:]

  mutating func observe(period: Int, date: Date, presentationTime: UInt64, scale: UInt64 = 90_000) throws {
    guard period >= 0, date.timeIntervalSince1970.isFinite, presentationTime <= Self.maximum,
      (1...1_000_000).contains(scale) else {
      throw NativeHLSError.invalidMedia
    }
    if anchors[period] == nil { anchors[period] = Anchor(date: date, time: presentationTime, scale: scale) }
  }

  func reference(period: Int, date: Date, scale: UInt64 = 90_000) throws -> UInt64? {
    guard period >= 0, date.timeIntervalSince1970.isFinite, (1...1_000_000).contains(scale) else {
      throw NativeHLSError.invalidMedia
    }
    guard let anchor = anchors[period] else { return nil }
    let expected = Double(anchor.time) * Double(scale) / Double(anchor.scale)
      + date.timeIntervalSince(anchor.date) * Double(scale)
    guard expected.isFinite, expected >= 0, expected <= Double(Self.maximum) else {
      throw NativeHLSError.transition
    }
    return UInt64(expected.rounded())
  }

  static func unwrap(_ raw: UInt64, near reference: UInt64) throws -> UInt64 {
    guard raw < wrap, reference <= maximum else { throw NativeHLSError.invalidMedia }
    var candidate = reference / wrap * wrap + raw
    if candidate > reference, candidate - reference > wrap / 2 {
      guard candidate >= wrap else { throw NativeHLSError.transition }
      candidate -= wrap
    } else if reference > candidate, reference - candidate > wrap / 2 {
      candidate += wrap
    }
    guard candidate <= maximum else { throw NativeHLSError.invalidMedia }
    return candidate
  }
}

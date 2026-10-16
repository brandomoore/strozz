import Foundation

struct NativeMediaClock: Sendable {
  static let wrap: UInt64 = 1 << 33
  static let maximum = UInt64.max / 96_000 - 2 * wrap
  private struct Anchor: Sendable { let date: Date; let time: UInt64 }
  private var anchors: [Int: Anchor] = [:]

  mutating func observe(period: Int, date: Date, presentationTime: UInt64) throws {
    guard period >= 0, date.timeIntervalSince1970.isFinite, presentationTime <= Self.maximum else {
      throw NativeHLSError.invalidMedia
    }
    if anchors[period] == nil { anchors[period] = Anchor(date: date, time: presentationTime) }
  }

  func reference(period: Int, date: Date) throws -> UInt64? {
    guard period >= 0, date.timeIntervalSince1970.isFinite else { throw NativeHLSError.invalidMedia }
    guard let anchor = anchors[period] else { return nil }
    let expected = Double(anchor.time) + date.timeIntervalSince(anchor.date) * 90_000
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

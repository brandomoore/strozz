import XCTest
@testable import Strozz

final class NativeTransportStreamTests: XCTestCase {
  private func packet(pid: Int, counter: Int, payload: [UInt8]) -> Data {
    var bytes: [UInt8] = [0x47, UInt8(0x40 | (pid >> 8)), UInt8(pid & 255), UInt8(0x10 | (counter & 15))]
    bytes += payload
    bytes += Array(repeating: 0xFF, count: 188 - bytes.count)
    return Data(bytes)
  }

  private func timestamp(_ value: UInt64) -> [UInt8] {
    let v = value % (1 << 33)
    return [0x21 | UInt8((v >> 29) & 14), UInt8((v >> 22) & 255),
            UInt8((v >> 14) & 254) | 1, UInt8((v >> 7) & 255), UInt8((v << 1) & 254) | 1]
  }

  private func video(frame: Int, clock: UInt64, idr: Bool = false) -> Data {
    packet(pid: 257, counter: frame, payload:
      [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 5] + timestamp(clock)
      + [0, 0, 1, idr ? 0x65 : 0x41, 0x80])
  }

  private func parser() throws -> NativeTransportStream {
    var value = NativeTransportStream()
    _ = try value.append(packet(pid: 0, counter: 0, payload:
      [0, 0, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xF0, 0, 0, 0, 0, 0]))
    _ = try value.append(packet(pid: 4096, counter: 0, payload:
      [0, 2, 0xB0, 23, 0, 1, 0xC1, 0, 0, 0xE1, 1, 0xF0, 0,
       0x1B, 0xE1, 1, 0xF0, 0, 0x0F, 0xE1, 0, 0xF0, 0, 0, 0, 0, 0]))
    return value
  }

  func testRangesCoverUnmodifiedPacketsAndRetainInitialTables() throws {
    var value = try parser()
    var ranges: [NativeTransportStream.Range] = []
    for frame in 0..<120 {
      if let range = try value.append(video(frame: frame, clock: UInt64(frame * 1500), idr: frame == 0)) {
        ranges.append(range)
      }
    }
    ranges.append(try value.finish(expectedDuration: 2))
    XCTAssertEqual(ranges.first?.offset, 0)
    XCTAssertTrue(ranges[0].independent)
    XCTAssertTrue(ranges.dropFirst().allSatisfy { !$0.independent })
    XCTAssertTrue(ranges.allSatisfy { $0.offset % 188 == 0 && $0.length % 188 == 0 && $0.duration <= 0.45 })
    XCTAssertEqual(ranges.reduce(0) { $0 + $1.duration }, 2, accuracy: 0.00001)
    XCTAssertEqual(ranges.reduce(0) { $0 + $1.length }, 122 * 188)
    for index in 1..<ranges.count {
      XCTAssertEqual(ranges[index].offset, ranges[index - 1].offset + ranges[index - 1].length)
    }
  }

  func testClockWrapIsHandledWithoutAFalseDiscontinuity() throws {
    var value = try parser()
    let base = (UInt64(1) << 33) - 3000
    for frame in 0..<120 {
      _ = try value.append(video(frame: frame, clock: base + UInt64(frame * 1500), idr: frame == 0))
    }
    _ = try value.finish(expectedDuration: 2)
    XCTAssertEqual(value.duration, 2, accuracy: 0.00001)
  }

  func testMissingPacketsAreNotPublishedAsContinuousMedia() throws {
    var value = try parser()
    _ = try value.append(video(frame: 0, clock: 0, idr: true))
    XCTAssertThrowsError(try value.append(video(frame: 2, clock: 3000)))
  }

  func testIdenticalRetransmittedPacketDoesNotBreakContinuity() throws {
    var value = try parser()
    let first = video(frame: 0, clock: 0, idr: true)
    _ = try value.append(first)
    XCTAssertNil(try value.append(first))
    XCTAssertNoThrow(try value.append(video(frame: 1, clock: 1500)))
  }

  func testInvalidTimingAndNonRandomAccessStartFailExplicitly() throws {
    XCTAssertThrowsError(try NativeTransportStream.timestamp(Data(repeating: 0, count: 5), at: 0))
    var value = try parser()
    XCTAssertThrowsError(try value.append(Data(repeating: 0, count: 188)))
    value = try parser()
    XCTAssertThrowsError(try {
      for frame in 0..<30 { _ = try value.append(video(frame: frame, clock: UInt64(frame * 1500))) }
    }())
  }

  func testParentDurationMustAgreeWithSourceManifest() throws {
    var value = try parser()
    for frame in 0..<60 {
      _ = try value.append(video(frame: frame, clock: UInt64(frame * 1500), idr: frame == 0))
    }
    XCTAssertThrowsError(try value.finish(expectedDuration: 2))
  }

  func testFiftyFPSNonterminalPartsMeetAdvertisedMinimumDuration() throws {
    var value = try parser()
    var ranges: [NativeTransportStream.Range] = []
    for frame in 0..<100 {
      if let range = try value.append(video(frame: frame, clock: UInt64(frame * 1800), idr: frame == 0)) {
        ranges.append(range)
      }
    }
    ranges.append(try value.finish(expectedDuration: 2))
    XCTAssertEqual(ranges.reduce(0) { $0 + $1.length }, value.byteCount)
    XCTAssertEqual(ranges.reduce(0) { $0 + $1.duration }, 2, accuracy: 0.00001)
    for range in ranges.dropFirst().dropLast() {
      XCTAssertGreaterThanOrEqual(range.duration, 0.85 * 0.45,
        "AVPlayer rejects non-independent, non-terminal parts shorter than 85% of PART-TARGET")
    }
    XCTAssertTrue(ranges.allSatisfy { $0.duration <= 0.45 })
  }
}

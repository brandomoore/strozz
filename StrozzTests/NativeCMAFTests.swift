import XCTest
@testable import Strozz

final class NativeCMAFTests: XCTestCase {
  private func words(_ values: UInt32...) -> Data {
    values.reduce(into: Data()) { result, value in
      result.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255),
                                UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
  }
  private func box(_ type: String, _ data: Data) -> Data {
    words(UInt32(data.count + 8)) + Data(type.utf8) + data
  }

  func testBoxBoundsAreChecked() throws {
    XCTAssertEqual(try NativeCMAF.boxes(box("free", Data([1, 2]))).first?.payload, Data([1, 2]))
    for data in [Data([1]), words(7) + Data("moof".utf8), words(100) + Data("mdat".utf8)] {
      XCTAssertThrowsError(try NativeCMAF.boxes(data))
    }
  }

  func testSampleDurationsAndKeyframeFlags() throws {
    let track = NativeCMAF.Track(id: 1, scale: 90000, duration: 3000, flags: 0x10000)
    let traf = box("tfhd", words(0x28, 1, 3000, 0x10000))
      + box("tfdt", words(0x01000000, 0, 90000))
      + box("trun", words(0x104, 3, 0, 3000, 6000, 3000))
    let timing = try NativeCMAF.timing(box("traf", traf), track: track)
    XCTAssertEqual(timing.start, 1)
    XCTAssertEqual(timing.duration, 12000.0 / 90000, accuracy: 0.000001)
    XCTAssertTrue(timing.independent)
    let bad = box("traf", box("tfhd", words(1, 1, 0, 500)))
    XCTAssertThrowsError(try NativeCMAF.timing(bad, track: track))
  }

  private var playlist: String {
    """
    #EXTM3U
    #EXT-X-MEDIA-SEQUENCE:42
    #EXT-X-MAP:URI="init.mp4"
    #EXT-X-PROGRAM-DATE-TIME:2026-10-04T10:00:00.000Z
    #EXTINF:2.0,
    42.mp4
    #EXT-X-TWITCH-PREFETCH:43.mp4
    """
  }

  func testPlaylistPreservesSourceIdentityAndTime() throws {
    let parsed = try NativeCMAF.manifest(playlist, url: URL(string: "https://example.test/live.m3u8")!)
    XCTAssertEqual(parsed.initialization.absoluteString, "https://example.test/init.mp4")
    XCTAssertEqual(parsed.entries.map(\.sequence), [42, 43])
    XCTAssertEqual(parsed.entries[0].duration, 2)
    XCTAssertNotNil(parsed.entries[0].date)
    XCTAssertNil(parsed.entries[1].date)
    XCTAssertNil(parsed.entries[1].duration)
  }

  func testUnsupportedStreamsAndAdsFailRatherThanDisappear() {
    let url = URL(string: "https://example.test/live.m3u8")!
    for changed in [
      playlist.replacingOccurrences(of: "#EXT-X-MAP:URI=\"init.mp4\"", with: ""),
      playlist.replacingOccurrences(of: "#EXT-X-TWITCH-PREFETCH:43.mp4", with: ""),
      playlist + "\n#EXT-X-DISCONTINUITY",
      playlist + "\n#EXT-X-KEY:METHOD=AES-128",
      playlist + "\n#EXT-X-DATERANGE:ID=\"ad\",CLASS=\"twitch-stitched-ad\"",
      playlist + "\n#EXT-X-ENDLIST",
      playlist.replacingOccurrences(of: "#EXTINF:2.0,", with: "#EXTINF:"),
    ] {
      XCTAssertThrowsError(try NativeCMAF.manifest(changed, url: url))
    }
  }

  func testAttributeParserRetainsCommasInsideQuotes() {
    XCTAssertEqual(NativeCMAF.attributes("CODECS=\"avc1,mp4a\",BANDWIDTH=123")["CODECS"], "avc1,mp4a")
  }

  func testStoppedOriginNeverResurrectsNetworking() async {
    let origin = NativeHLSOrigin(root: URL(string: "https://invalid.example/master.m3u8")!,
      headers: [:], history: 30) { _ in XCTFail("Stopping must not trigger fallback") }
    await origin.stop()
    do {
      _ = try await origin.response(URL(string: "strozz-native-ll://test/root.m3u8")!)
      XCTFail("Stopped origin served a request")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }
}

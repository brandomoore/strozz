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
    XCTAssertEqual(parsed.initialization?.absoluteString, "https://example.test/init.mp4")
    XCTAssertEqual(parsed.entries.map(\.sequence), [42, 43])
    XCTAssertEqual(parsed.entries[0].duration, 2)
    XCTAssertNotNil(parsed.entries[0].date)
    XCTAssertNil(parsed.entries[1].date)
    XCTAssertNil(parsed.entries[1].duration)
  }

  func testUnsupportedEncryptionAndMalformedMediaFailRatherThanDisappear() {
    let url = URL(string: "https://example.test/live.m3u8")!
    for changed in [
      playlist + "\n#EXT-X-KEY:METHOD=AES-128",
      playlist.replacingOccurrences(of: "#EXTINF:2.0,", with: "#EXTINF:"),
    ] {
      XCTAssertThrowsError(try NativeCMAF.manifest(changed, url: url))
    }

    func testDiscontinuityAndAdMetadataStayAttachedToTheirOwnSegments() throws {
      let text = """
      #EXTM3U
      #EXT-X-TARGETDURATION:6
      #EXT-X-MEDIA-SEQUENCE:90
      #EXT-X-DISCONTINUITY-SEQUENCE:4
      #EXT-X-MAP:URI="first.mp4"
      #EXT-X-PROGRAM-DATE-TIME:2026-10-04T10:00:00.000Z
      #EXTINF:2.0,
      90.mp4
      #EXT-X-DISCONTINUITY
      #EXT-X-MAP:URI="ad-init.mp4"
      #EXT-X-DATERANGE:ID="ad",CLASS="twitch-stitched-ad"
      #EXT-X-PROGRAM-DATE-TIME:2026-10-04T10:00:02.000Z
      #EXTINF:2.0,
      91.mp4
      #EXT-X-DISCONTINUITY
      #EXT-X-MAP:URI="first.mp4"
      #EXT-X-PROGRAM-DATE-TIME:2026-10-04T10:00:04.000Z
      #EXTINF:2.0,
      92.mp4
      #EXT-X-TWITCH-PREFETCH:93.mp4
      """
      let parsed = try NativeCMAF.manifest(text, url: URL(string: "https://example.test/live.m3u8")!)
      XCTAssertEqual(parsed.entries.map(\.discontinuity), [4, 5, 6, 6])
      XCTAssertEqual(parsed.entries.map { $0.initialization?.lastPathComponent }, ["first.mp4", "ad-init.mp4", "first.mp4", "first.mp4"])
      XCTAssertEqual(parsed.entries[1].tags, ["#EXT-X-DATERANGE:ID=\"ad\",CLASS=\"twitch-stitched-ad\""])
      XCTAssertEqual(parsed.entries.map(\.url.lastPathComponent), ["90.mp4", "91.mp4", "92.mp4", "93.mp4"])
    }

    func testWholeSegmentAdPlaylistAndEndListAreNotFatalTransitions() throws {
      let text = playlist.replacingOccurrences(of: "#EXT-X-TWITCH-PREFETCH:43.mp4", with: "")
        + "\n#EXT-X-ENDLIST"
      let parsed = try NativeCMAF.manifest(text, url: URL(string: "https://example.test/live.m3u8")!)
      XCTAssertTrue(parsed.ended)
      XCTAssertFalse(parsed.hasPrefetch)
      XCTAssertEqual(parsed.entries.count, 1)
    }

    func testRenderedDiscontinuitiesMapsAndAdTagsRemainInOrder() async throws {
      let base = URL(string: "https://example.test/")!
      let date = Date(timeIntervalSince1970: 1000)
      let origin = NativeHLSOrigin(root: base, headers: [:], history: 30) { _ in }
      defer { Task { await origin.stop() } }
      let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 2, independent: true)
      let segments = [
        NativeHLSOrigin.Segment(sequence: 10, url: base.appendingPathComponent("10.mp4"), date: date,
          initialization: base.appendingPathComponent("main-init.mp4"), discontinuity: 4, tags: [], parts: [part], complete: true),
        NativeHLSOrigin.Segment(sequence: 11, url: base.appendingPathComponent("ad.mp4"), date: date.addingTimeInterval(2),
          initialization: base.appendingPathComponent("ad-init.mp4"), discontinuity: 5,
          tags: ["#EXT-X-DATERANGE:ID=\"ad\",CLASS=\"twitch-stitched-ad\""], parts: [part], complete: true),
        NativeHLSOrigin.Segment(sequence: 12, url: base.appendingPathComponent("12.mp4"), date: date.addingTimeInterval(4),
          initialization: base.appendingPathComponent("main-init.mp4"), discontinuity: 6, tags: [], parts: [part], complete: true),
      ]
      let text = try await origin.renderForTesting(segments, ended: true)
      XCTAssertTrue(text.contains("#EXT-X-DISCONTINUITY-SEQUENCE:4"))
      XCTAssertEqual(text.components(separatedBy: "\n#EXT-X-DISCONTINUITY\n").count - 1, 2)
      XCTAssertTrue(text.contains("#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"https://example.test/ad-init.mp4\""))
      XCTAssertTrue(text.contains("#EXT-X-DATERANGE:ID=\"ad\",CLASS=\"twitch-stitched-ad\""))
      XCTAssertTrue(text.contains("https://example.test/ad.mp4"))
      XCTAssertTrue(text.contains("#EXT-X-ENDLIST"))
      XCTAssertFalse(text.contains("#EXT-X-PRELOAD-HINT"))
    }
  }

  func testAttributeParserRetainsCommasInsideQuotes() {
    XCTAssertEqual(NativeCMAF.attributes("CODECS=\"avc1,mp4a\",BANDWIDTH=123")["CODECS"], "avc1,mp4a")
  }

  func testModernAudioOnlyVariantCannotEnterTheVideoIndexer() {
    XCTAssertTrue(NativeCMAF.isAudioOnlyVariant(
      "#EXT-X-STREAM-INF:BANDWIDTH=159999,CODECS=\"mp4a.40.2\",STABLE-VARIANT-ID=\"audio_only\""))
    XCTAssertTrue(NativeCMAF.isAudioOnlyVariant("#EXT-X-STREAM-INF:BANDWIDTH=159999,VIDEO=\"audio_only\""))
    XCTAssertFalse(NativeCMAF.isAudioOnlyVariant(
      "#EXT-X-STREAM-INF:BANDWIDTH=3422999,RESOLUTION=1280x720,CODECS=\"avc1.4D401F,mp4a.40.2\""))
  }

  func testTransportStreamPlaylistDoesNotRequireCMAFMap() throws {
    let parsed = try NativeCMAF.manifest(
      playlist.replacingOccurrences(of: "#EXT-X-MAP:URI=\"init.mp4\"", with: ""),
      url: URL(string: "https://example.test/live.m3u8")!)
    XCTAssertNil(parsed.initialization)
    XCTAssertEqual(parsed.targetDuration, 6)
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

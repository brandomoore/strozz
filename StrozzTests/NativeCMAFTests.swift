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

  func testAttributeParserRetainsCommasInsideQuotes() {
    XCTAssertEqual(NativeCMAF.attributes("CODECS=\"avc1,mp4a\",BANDWIDTH=123")["CODECS"], "avc1,mp4a")
  }

  func testPartGroupingFlushesBeforeValidFragmentsOverflowTheTarget() throws {
    XCTAssertTrue(try NativeCMAF.shouldFlushPart(accumulated: 0.25, next: 0.25))
    XCTAssertFalse(try NativeCMAF.shouldFlushPart(accumulated: 0, next: 0.25))
    XCTAssertFalse(try NativeCMAF.shouldFlushPart(accumulated: 0.2, next: 0.2))
    XCTAssertThrowsError(try NativeCMAF.shouldFlushPart(accumulated: 0, next: 0.6))
    XCTAssertThrowsError(try NativeCMAF.shouldFlushPart(accumulated: 0.2, next: .nan))
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

  func testWholeSegmentHoldBackUsesPublicationCadenceNotAdvertisedMaximum() async throws {
    let url = URL(string: "https://example.test/live.m3u8")!
    let date = Date(timeIntervalSince1970: 100)
    var segments = (0..<12).map { index in
      NativeHLSOrigin.Segment(
        sequence: index, url: url, date: date.addingTimeInterval(Double(index * 2)),
        discontinuity: 0, tags: [], complete: true, declaredDuration: 2)
    }
    segments[11].parts = (0..<5).map { number in
      NativeHLSOrigin.Part(offset: number * 188, length: 188, duration: 0.4,
        independent: number == 0, media: Data(repeating: 0, count: 188))
    }
    let origin = NativeHLSOrigin(root: url, headers: [:], history: 30) { _ in }
    defer { Task { await origin.stop() } }
    let rendered = try await origin.renderForTesting(segments, hasPrefetch: false, target: 6)
    XCTAssertTrue(rendered.contains("PART-HOLD-BACK=3.5"))
    XCTAssertTrue(rendered.contains("#EXT-X-PART-INF:PART-TARGET=0.45"))
    XCTAssertTrue(rendered.contains("#EXT-X-TARGETDURATION:6"))
    XCTAssertTrue(rendered.contains("#EXT-X-PART:DURATION=0.400000"))
    let source = NativeHLSOrigin.Rendition(
      url: url, segments: segments, target: 6,
      reachedLiveEdge: true, hasPrefetch: false, publicationDuration: 2)
    XCTAssertEqual(
      NativeHLSOrigin.liveTargetDate(in: [0: source], active: 0),
      date.addingTimeInterval(24 - 0.4 - 3.5))
  }

  func testWholeSegmentCushionRetainsRoomForLongerPublications() {
    let url = URL(string: "https://example.test/live.m3u8")!
    var source = NativeHLSOrigin.Rendition(url: url, target: 6, hasPrefetch: false)
    XCTAssertEqual(source.liveHoldBack, 7.5)
    source.publicationDuration = 2
    XCTAssertEqual(source.liveHoldBack, 3.5)
    XCTAssertEqual(source.forwardBuffer, 3.5)
    source.publicationDuration = 6
    XCTAssertEqual(source.liveHoldBack, 7.5)
    source.hasPrefetch = true
    XCTAssertEqual(source.liveHoldBack, 1.5)
    XCTAssertEqual(source.forwardBuffer, 3)
  }

  func testWholeSegmentPublicationKeepsTheHintCachedAndNeverWithdrawsReleasedParts() {
    let url = URL(string: "https://example.test/segment.ts")!
    let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 0.4,
      independent: true, media: Data(repeating: 0x47, count: 188))
    let first = NativeHLSOrigin.Segment(sequence: 10, url: url, date: Date(timeIntervalSince1970: 100),
      discontinuity: 0, tags: [], parts: [part, part], complete: true)
    var source = NativeHLSOrigin.Rendition(url: url, segments: [first], hasPrefetch: false)
    XCTAssertEqual(source.publishedSegments[0].parts.count, 1)
    XCTAssertFalse(source.publishedSegments[0].complete)
    XCTAssertNotNil(source.segments[0].parts[1].media)
    source.hasPrefetch = true
    XCTAssertEqual(source.publishedSegments[0].parts.count, 1, "Capability refresh cannot republish a segment differently")
    let next = NativeHLSOrigin.Segment(sequence: 11, url: url, date: Date(timeIntervalSince1970: 100.8),
      discontinuity: 0, tags: [], parts: [part], complete: true)
    source.segments.append(next)
    XCTAssertEqual(source.publishedSegments[0].parts.count, 2)
    XCTAssertTrue(source.publishedSegments[0].complete)
    XCTAssertEqual(source.publishedSegments[1].parts.count, 0)
    source.ended = true
    XCTAssertEqual(source.publishedSegments[1].parts.count, 1, "End-of-stream releases the held tail")
    XCTAssertTrue(source.publishedSegments[1].complete)
  }

  func testRenditionReportsUseVerifiedSequencesAndRelativeURIs() async throws {
    let url = URL(string: "https://example.test/live.m3u8")!
    let segment = NativeHLSOrigin.Segment(sequence: 90, url: url, date: Date(),
      discontinuity: 0, tags: [], complete: true, declaredDuration: 2)
    let origin = NativeHLSOrigin(root: url, headers: [:], history: 30) { _ in }
    defer { Task { await origin.stop() } }
    let text = try await origin.renderForTesting([segment], otherRenditions: [
      1: .init(url: url, reportedCompleteSequence: 87),
      2: .init(url: url)
    ])
    XCTAssertTrue(text.contains("#EXT-X-RENDITION-REPORT:URI=\"1.m3u8\",LAST-MSN=87,LAST-PART=0"))
    XCTAssertFalse(text.contains("URI=\"2.m3u8\""), "An unknown rendition must not invent a sequence")
  }

  func testColdRenditionIndexesTheRequestedSequenceInsteadOfSkippingItsParts() throws {
    let text = playlist.replacingOccurrences(of: "#EXT-X-TWITCH-PREFETCH:43.mp4",
      with: "#EXTINF:2.0,\n43.mp4\n#EXTINF:2.0,\n44.mp4\n#EXT-X-TWITCH-PREFETCH:45.mp4")
    let entries = try NativeCMAF.manifest(text, url: URL(string: "https://example.test/live.m3u8")!).entries
    XCTAssertEqual(NativeHLSOrigin.initialEntry(in: entries, requestedSequence: 43)?.sequence, 43)
    XCTAssertEqual(NativeHLSOrigin.initialEntry(in: entries, requestedSequence: nil)?.sequence, 44)
    XCTAssertEqual(NativeHLSOrigin.initialEntry(in: entries, requestedSequence: 45)?.sequence, 44)
  }

  func testStoppingConcurrentManifestRequestsDoesNotRaceSessionInvalidation() async {
    for _ in 0..<32 {
      let origin = NativeHLSOrigin(root: URL(string: "https://127.0.0.1:1/master.m3u8")!,
        headers: [:], history: 30) { _ in }
      let request = Task {
        try await origin.response(URL(string: "strozz-native-ll://test/root.m3u8")!)
      }
      await Task.yield()
      request.cancel()
      await origin.stop()
      do {
        _ = try await request.value
        XCTFail("A stopped loopback request must not produce a playlist")
      } catch {
        XCTAssertTrue(error is CancellationError || error is URLError)
      }
    }
  }
}

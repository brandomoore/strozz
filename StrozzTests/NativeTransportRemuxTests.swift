import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeTransportRemuxTests: XCTestCase {
  func testTransportTimingRemovalPreservesCaptionAndUserSEIWithEmulationPrevention() throws {
    let original = Data([6, 0, 1, 0x11, 1, 1, 0x22, 4, 4, 0xB5, 0, 0, 3, 1, 5, 1, 0x55, 0x80])
    let expected = Data([6, 4, 4, 0xB5, 0, 0, 3, 1, 5, 1, 0x55, 0x80])
    XCTAssertEqual(try NativeTransportDemuxer.removingTransportTimingSEI(original), expected)
    XCTAssertNil(try NativeTransportDemuxer.removingTransportTimingSEI(
      Data([6, 0, 1, 0x11, 1, 1, 0x22, 0x80])))
    XCTAssertEqual(try NativeTransportDemuxer.removingTransportTimingSEI(expected), expected)
  }

  func testTransportTimingRemovalRetainsExtendedSEIFieldsAndRejectsTruncation() throws {
    let retained = Data([255, 45, 255, 5]) + Data(repeating: 1, count: 260)
    XCTAssertEqual(try NativeTransportDemuxer.removingTransportTimingSEI(
      Data([6, 0, 1, 0x11]) + retained + Data([0x80])),
      Data([6]) + retained + Data([0x80]))
    for malformed in [Data([6, 4, 5, 1, 0x80]), Data([6, 4, 1, 1]), Data([6, 4, 3, 0, 0, 3])] {
      XCTAssertThrowsError(try NativeTransportDemuxer.removingTransportTimingSEI(malformed))
    }
  }

  func testRemovingTransportTimingKeepsAccessUnitClocksAndEncodedSlices() throws {
    var demuxer = NativeTransportDemuxer()
    var counter = 0
    let aud = Data([9, 0xF0])
    let timing = Data([6, 1, 1, 0x11, 0x80])
    let caption = Data([6, 4, 1, 0x55, 0x80])
    let idr = Data([0x65, 0x80, 0x88])
    let predicted = Data([0x41, 0x80, 0x99])
    var units: [NativeTransportDemuxer.Unit] = []
    for (payload, clock) in [
      (nal(aud) + nal(sps) + nal(pps) + nal(timing) + nal(caption) + nal(idr), UInt64(90_000)),
      (nal(aud) + nal(timing) + nal(predicted), 93_000),
    ] {
      for packet in packets(pes(payload, pts: clock), pid: 257, counter: &counter) {
        units += try demuxer.append(packet, videoPID: 257, audioPID: 256)
      }
    }
    units += try demuxer.finishSegment()
    let video = videoUnits(units)
    XCTAssertEqual(video.map(\.decodeTime), [90_000, 93_000])
    XCTAssertEqual(try avcNALs(video[0].bytes), [aud, caption, idr])
    XCTAssertEqual(try avcNALs(video[1].bytes), [aud, predicted])
  }

  private let sps = Data([0x67, 0x4D, 0x40, 0x0A, 0xEC, 0xA2, 0x13, 0x60, 0x22, 0,
                          0, 3, 0, 2, 0, 0, 3, 0, 0x78, 0x1E, 0x24, 0x4B, 0x2C])
  private let pps = Data([0x68, 0xEB, 0xE3, 0xCB, 0x20])

  private func timestamp(_ clock: UInt64, prefix: UInt8 = 0x20) -> Data {
    let v = clock % (1 << 33)
    return Data([prefix | UInt8((v >> 29) & 14) | 1, UInt8((v >> 22) & 255),
      UInt8((v >> 14) & 254) | 1, UInt8((v >> 7) & 255), UInt8((v << 1) & 254) | 1])
  }

  private func pes(_ payload: Data, audio: Bool = false, pts: UInt64, dts: UInt64? = nil) -> Data {
    let stamps = dts.map { timestamp(pts, prefix: 0x30) + timestamp($0, prefix: 0x10) } ?? timestamp(pts)
    let length = audio ? UInt16(3 + stamps.count + payload.count) : 0
    return Data([0, 0, 1, audio ? 0xC0 : 0xE0, UInt8(length >> 8), UInt8(length & 255),
      0x80, dts == nil ? 0x80 : 0xC0, UInt8(stamps.count)]) + stamps + payload
  }

  private func packets(_ pes: Data, pid: Int, counter: inout Int) -> [Data] {
    var result: [Data] = []
    var offset = 0
    while offset < pes.count {
      let length = min(184, pes.count - offset)
      var packet = Data([0x47, UInt8((offset == 0 ? 0x40 : 0) | (pid >> 8)),
        UInt8(pid & 255), UInt8((length == 184 ? 0x10 : 0x30) | (counter & 15))])
      if length < 184 {
        let adaptation = 183 - length
        packet.append(UInt8(adaptation))
        if adaptation > 0 {
          packet.append(0)
          packet.append(Data(repeating: 0xFF, count: adaptation - 1))
        }
      }
      packet.append(pes.subdata(in: offset..<(offset + length)))
      result.append(packet)
      offset += length
      counter += 1
    }
    return result
  }

  private func nal(_ bytes: Data) -> Data { Data([0, 0, 0, 1]) + bytes }

  private func videoUnits(_ units: [NativeTransportDemuxer.Unit]) -> [NativeTransportDemuxer.Video] {
    units.compactMap { if case .video(let video) = $0 { video } else { nil } }
  }

  private func avcNALs(_ data: Data) throws -> [Data] {
    var offset = 0
    var values: [Data] = []
    while offset < data.count {
      let length = Int(try NativeCMAF.integer(data, offset))
      offset += 4
      values.append(data.subdata(in: offset..<(offset + length)))
      offset += length
    }
    return values
  }

  func testAccessUnitCanBeginAfterContinuationBytesInsideTheNextPES() throws {
    var demuxer = NativeTransportDemuxer()
    var counter = 0
    let aud = Data([9, 0xF0])
    let idr = Data([0x65]) + Data(repeating: 0x88, count: 400)
    let predicted = Data([0x41]) + Data(repeating: 0x99, count: 80)
    let first = nal(aud) + nal(sps) + nal(pps) + nal(Data(idr.prefix(130)))
    let second = Data(idr.dropFirst(130)) + nal(aud) + nal(predicted)
    var units: [NativeTransportDemuxer.Unit] = []
    for (data, pts, dts) in [(first, UInt64(93_000), UInt64(90_000)), (second, 99_000, 93_000)] {
      for packet in packets(pes(data, pts: pts, dts: dts), pid: 257, counter: &counter) {
        units += try demuxer.append(packet, videoPID: 257, audioPID: 256)
      }
    }
    units += try demuxer.finishSegment()
    let videos = videoUnits(units)
    XCTAssertEqual(videos.count, 2)
    XCTAssertEqual(videos.map(\.decodeTime), [90_000, 93_000])
    XCTAssertEqual(videos.map(\.presentationTime), [93_000, 99_000])
    XCTAssertEqual(try avcNALs(videos[0].bytes), [aud, idr])
    XCTAssertEqual(try avcNALs(videos[1].bytes), [aud, predicted])
    XCTAssertTrue(videos[0].independent)
    XCTAssertFalse(videos[1].independent)
    XCTAssertEqual(demuxer.sps, sps)
    XCTAssertEqual(demuxer.pps, pps)
  }

  func testStartCodeCanStraddlePESWithoutTakingThePreviousTimestamp() throws {
    var demuxer = NativeTransportDemuxer()
    var counter = 0
    let aud = Data([9, 0xF0])
    let first = nal(aud) + nal(sps) + nal(pps) + nal(Data([0x65, 0x88])) + Data([0, 0])
    let second = Data([0, 1]) + aud + nal(Data([0x41, 0x99]))
    var units: [NativeTransportDemuxer.Unit] = []
    for (data, pts) in [(first, UInt64(90_000)), (second, 93_000)] {
      for packet in packets(pes(data, pts: pts), pid: 257, counter: &counter) {
        units += try demuxer.append(packet, videoPID: 257, audioPID: 256)
      }
    }
    units += try demuxer.finishSegment()
    XCTAssertEqual(videoUnits(units).map(\.decodeTime), [90_000, 93_000])
  }

  func testContinuationSliceInNextPESDoesNotCreateAPhantomAccessUnit() throws {
    var demuxer = NativeTransportDemuxer()
    var counter = 0
    let aud = Data([9, 0xF0])
    let firstSlice = Data([0x65, 0x80, 0x88])
    let continuation = Data([0x41, 0x40, 0x88])
    let nextPicture = Data([0x41, 0x80, 0x99])
    let first = nal(aud) + nal(sps) + nal(pps) + nal(firstSlice)
    let second = nal(continuation) + nal(aud) + nal(nextPicture)
    var units: [NativeTransportDemuxer.Unit] = []
    for (data, pts) in [(first, UInt64(90_000)), (second, 93_000)] {
      for packet in packets(pes(data, pts: pts), pid: 257, counter: &counter) {
        units += try demuxer.append(packet, videoPID: 257, audioPID: 256)
      }
    }
    units += try demuxer.finishSegment()
    let videos = videoUnits(units)
    XCTAssertEqual(videos.map(\.decodeTime), [90_000, 93_000])
    XCTAssertEqual(try avcNALs(videos[0].bytes), [aud, firstSlice, continuation])
    XCTAssertEqual(try avcNALs(videos[1].bytes), [aud, nextPicture])
  }

  private func adts(_ payload: Data, rateIndex: UInt8 = 3) -> Data {
    let length = payload.count + 7
    return Data([0xFF, 0xF1, 0x40 | rateIndex << 2, 0x80 | UInt8(length >> 11),
      UInt8((length >> 3) & 255), UInt8((length & 7) << 5) | 0x1F, 0xFC]) + payload
  }

  func testAudioKeepsOriginalPESClockSampleRateAndRawAACWithoutADTS() throws {
    var demuxer = NativeTransportDemuxer()
    var counter = 0
    let a = Data(repeating: 0x21, count: 140)
    let b = Data(repeating: 0x42, count: 150)
    var units: [NativeTransportDemuxer.Unit] = []
    for packet in packets(pes(adts(a) + adts(b), audio: true, pts: 900_900), pid: 256, counter: &counter) {
      units += try demuxer.append(packet, videoPID: 257, audioPID: 256)
    }
    units += try demuxer.finishSegment()
    let audio = units.compactMap { if case .audio(let audio) = $0 { audio } else { nil } }
    XCTAssertEqual(audio.map(\.decodeTime), [480_480, 481_504])
    XCTAssertEqual(audio.map(\.duration), [1024, 1024])
    XCTAssertEqual(audio.map(\.bytes), [a, b])
    XCTAssertEqual(demuxer.audioConfiguration?.rate, 48_000)
    XCTAssertEqual(demuxer.audioConfiguration?.channels, 2)
    XCTAssertEqual(demuxer.audioConfiguration?.bytes, Data([0x11, 0x90]))
  }

  func testMissingAudioPacketAndTruncatedPESFailExplicitly() throws {
    let payload = adts(Data(repeating: 0x21, count: 500))
    var counter = 0
    let values = packets(pes(payload, audio: true, pts: 90_000), pid: 256, counter: &counter)
    var demuxer = NativeTransportDemuxer()
    _ = try demuxer.append(values[0], videoPID: 257, audioPID: 256)
    XCTAssertThrowsError(try demuxer.append(values[2], videoPID: 257, audioPID: 256)) {
      XCTAssertEqual($0 as? NativeHLSFailureDetail, .transportContinuity)
    }
    demuxer = NativeTransportDemuxer()
    _ = try demuxer.append(values[0], videoPID: 257, audioPID: 256)
    XCTAssertThrowsError(try demuxer.finishSegment())
  }

  func testMP4InitializationDerivesCodecDimensionsAndContainsBothTrackDefaults() throws {
    let config = try NativeFragmentedMP4.Configuration(sps: sps, pps: pps,
      audioConfig: Data([0x11, 0x90]), audioRate: 48_000, audioChannels: 2)
    XCTAssertEqual(config.width, 64)
    XCTAssertEqual(config.height, 64)
    let initialization = NativeFragmentedMP4.initialization(config)
    let track = try NativeCMAF.videoTrack(initialization)
    XCTAssertEqual(track.id, 1)
    XCTAssertEqual(track.scale, 90_000)
    let moov = try NativeCMAF.child(initialization, "moov")
    let trex = try NativeCMAF.boxes(NativeCMAF.child(moov, "mvex"))
    XCTAssertEqual(trex.count, 2)
  }

  func testMP4FragmentPreservesDecodeTimeReorderingAndSamplePayloadOffsets() throws {
    let video = [
      NativeFragmentedMP4.Sample(decodeTime: 9_000_000, duration: 1500,
        compositionOffset: 3000, independent: true, bytes: Data([1, 2, 3])),
      NativeFragmentedMP4.Sample(decodeTime: 9_001_500, duration: 1500,
        compositionOffset: -1500, independent: false, bytes: Data([4, 5])),
    ]
    let audio = [NativeFragmentedMP4.Sample(decodeTime: 4_800_000, duration: 1024,
      compositionOffset: 0, independent: true, bytes: Data([6, 7]))]
    let data = try NativeFragmentedMP4.fragment(sequence: 7, video: video, audio: audio)
    let moof = try NativeCMAF.child(data, "moof")
    let timing = try NativeCMAF.timing(moof, track: .init(id: 1, scale: 90_000, duration: 0, flags: 0))
    XCTAssertEqual(timing.start, 100)
    XCTAssertEqual(timing.duration, 1.0 / 30, accuracy: 0.000001)
    XCTAssertTrue(timing.independent)
    let trafs = try NativeCMAF.boxes(moof).filter { $0.type == "traf" }
    XCTAssertEqual(trafs.count, 2)
    let videoRun = try NativeCMAF.child(trafs[0].payload, "trun")
    let audioRun = try NativeCMAF.child(trafs[1].payload, "trun")
    XCTAssertEqual(videoRun[0], 1, "Signed composition offsets must remain signed")
    XCTAssertEqual(try NativeCMAF.integer(videoRun, 24), 3000)
    XCTAssertEqual(try NativeCMAF.integer(videoRun, 40), UInt64(UInt32(bitPattern: -1500)))
    let videoOffset = Int(try NativeCMAF.integer(videoRun, 8))
    let audioOffset = Int(try NativeCMAF.integer(audioRun, 8))
    XCTAssertEqual(data.subdata(in: videoOffset..<(videoOffset + 5)), Data([1, 2, 3, 4, 5]))
    XCTAssertEqual(data.subdata(in: audioOffset..<(audioOffset + 2)), Data([6, 7]))
  }

  func testMP4WriterRejectsUnrepresentedTrackGapsAndEmptyVideo() throws {
    let a = NativeFragmentedMP4.Sample(decodeTime: 90_000, duration: 3000,
      compositionOffset: 0, independent: true, bytes: Data([1]))
    let b = NativeFragmentedMP4.Sample(decodeTime: 96_000, duration: 3000,
      compositionOffset: 0, independent: false, bytes: Data([2]))
    XCTAssertThrowsError(try NativeFragmentedMP4.fragment(sequence: 1, video: [a, b], audio: [])) {
      XCTAssertEqual($0 as? NativeHLSError, .transition)
    }
    XCTAssertThrowsError(try NativeFragmentedMP4.fragment(sequence: 1, video: [], audio: []))
  }

  func testSwitchingMovieRetainsAudioAndDeclaresAllVideoDescriptions() throws {
    let config = try NativeFragmentedMP4.Configuration(sps: sps, pps: pps,
      audioConfig: Data([0x11, 0x90]), audioRate: 48_000, audioChannels: 2)
    let original = NativeFragmentedMP4.initialization(config)
    let combined = try NativeFragmentedMP4.switchingInitialization([original, original], maximumResolutionIndex: 1)
    let tracks = try NativeCMAF.boxes(NativeCMAF.child(combined, "moov")).filter { $0.type == "trak" }
    let mdia = try NativeCMAF.child(tracks[0].payload, "mdia")
    let stbl = try NativeCMAF.child(NativeCMAF.child(mdia, "minf"), "stbl")
    let stsd = try NativeCMAF.child(stbl, "stsd")
    XCTAssertEqual(try NativeCMAF.integer(stsd, 4), 2)
    XCTAssertEqual(try NativeCMAF.boxes(Data(stsd.dropFirst(8))).count, 2)
    let originalAudio = try NativeCMAF.boxes(NativeCMAF.child(original, "moov")).filter { $0.type == "trak" }[1]
    XCTAssertEqual(tracks[1].payload, originalAudio.payload)
    XCTAssertThrowsError(try NativeFragmentedMP4.switchingInitialization([], maximumResolutionIndex: 0))
  }

  func testKeyframeSwitchRebasesOnlyDecodeTimeAndRetainsExactPresentationAndPayload() throws {
    let video = [
      NativeFragmentedMP4.Sample(decodeTime: 9_000_000, duration: 1500,
        compositionOffset: 3000, independent: true, bytes: Data([1, 2, 3])),
      NativeFragmentedMP4.Sample(decodeTime: 9_001_500, duration: 1500,
        compositionOffset: -1500, independent: false, bytes: Data([4, 5])),
    ]
    let audio = [NativeFragmentedMP4.Sample(decodeTime: 4_800_000, duration: 1024,
      compositionOffset: 0, independent: true, bytes: Data([6, 7]))]
    let original = try NativeFragmentedMP4.fragment(sequence: 1, video: video, audio: audio)
    let switched = try NativeFragmentedMP4.switchingFragment(original, videoDescriptionIndex: 2, decodeStart: 9_003_000)
    let trafs = try NativeCMAF.boxes(NativeCMAF.child(switched, "moof")).filter { $0.type == "traf" }
    let header = try NativeCMAF.child(trafs[0].payload, "tfhd")
    XCTAssertEqual(try NativeCMAF.integer(header, 8), 2)
    let clock = try NativeCMAF.child(trafs[0].payload, "tfdt")
    XCTAssertEqual(try NativeCMAF.integer(clock, 4, 8), 9_003_000)
    let run = try NativeCMAF.child(trafs[0].payload, "trun")
    XCTAssertEqual(try NativeCMAF.integer(run, 24), 0)
    XCTAssertEqual(Int32(bitPattern: UInt32(try NativeCMAF.integer(run, 40))), -4500)
    XCTAssertEqual(9_003_000 + 0, 9_000_000 + video[0].compositionOffset)
    XCTAssertEqual(try NativeCMAF.child(switched, "mdat"), try NativeCMAF.child(original, "mdat"))
    let offset = Int(try NativeCMAF.integer(run, 8))
    XCTAssertEqual(switched.subdata(in: offset..<(offset + 5)), Data([1, 2, 3, 4, 5]))
    let originalAudio = try NativeCMAF.boxes(NativeCMAF.child(original, "moof")).filter { $0.type == "traf" }[1]
    let originalAudioClock = try NativeCMAF.child(originalAudio.payload, "tfdt")
    XCTAssertEqual(try NativeCMAF.child(trafs[1].payload, "tfdt"), originalAudioClock)
    XCTAssertThrowsError(try NativeFragmentedMP4.switchingFragment(Data(), videoDescriptionIndex: 1, decodeStart: 0))
  }

  func testDiscontinuitySuccessorKeepsItsOwnExplicitPrefetchDateAcrossAWallClockGap() throws {
    let root = URL(string: "https://fixture.test/live.m3u8")!
    let manifest = try NativeCMAF.manifest("""
      #EXTM3U
      #EXT-X-TARGETDURATION:2
      #EXT-X-MEDIA-SEQUENCE:5
      #EXT-X-PROGRAM-DATE-TIME:2026-10-16T00:00:00.000Z
      #EXTINF:2,
      5.ts
      #EXT-X-DISCONTINUITY
      #EXT-X-PROGRAM-DATE-TIME:2026-10-16T00:00:03.000Z
      #EXT-X-TWITCH-PREFETCH:6.ts
      """, url: root)
    let first = try XCTUnwrap(manifest.entries[0].date)
    let second = try XCTUnwrap(manifest.entries[1].date)
    XCTAssertEqual(second.timeIntervalSince(first), 3)
    let successor = NativeControlledHLSOrigin.successor(in: [(manifest.entries[1], second)],
      previousSequence: 5, previousVariant: 0, previousPeriod: 0, previousDate: first,
      variant: 0, nextDate: first.addingTimeInterval(2))
    XCTAssertEqual(successor?.0.sequence, 6)
    XCTAssertEqual(successor?.1, second)
  }

  func testMediaClockUnwrapsHistoryBeforeALiveJoinImmediatelyAfterRollover() throws {
    var clock = NativeMediaClock()
    let date = Date(timeIntervalSince1970: 1000)
    try clock.observe(period: 0, date: date, presentationTime: NativeMediaClock.wrap + 90_000)
    let historical = try XCTUnwrap(clock.reference(period: 0, date: date.addingTimeInterval(-2)))
    XCTAssertEqual(historical, NativeMediaClock.wrap - 90_000)
    XCTAssertEqual(try NativeMediaClock.unwrap(NativeMediaClock.wrap - 90_000, near: historical), historical)
    XCTAssertEqual(try NativeMediaClock.unwrap(270_000,
      near: XCTUnwrap(clock.reference(period: 0, date: date.addingTimeInterval(2)))),
      NativeMediaClock.wrap + 270_000)
  }

  func testMediaClockScopesTimestampResetsToTheirOwnDiscontinuityAndHandlesBoundaryJitter() throws {
    var clock = NativeMediaClock()
    let date = Date(timeIntervalSince1970: 1000)
    try clock.observe(period: 0, date: date, presentationTime: NativeMediaClock.wrap + 9_000_000)
    try clock.observe(period: 1, date: date.addingTimeInterval(20), presentationTime: NativeMediaClock.wrap + 90_000)
    XCTAssertEqual(try clock.reference(period: 1, date: date.addingTimeInterval(22)), NativeMediaClock.wrap + 270_000)
    XCTAssertEqual(try NativeMediaClock.unwrap(1000, near: NativeMediaClock.wrap - 500), NativeMediaClock.wrap + 1000)
    XCTAssertEqual(try NativeMediaClock.unwrap(NativeMediaClock.wrap - 1000,
      near: NativeMediaClock.wrap + 500), NativeMediaClock.wrap - 1000)
    XCTAssertThrowsError(try NativeMediaClock.unwrap(NativeMediaClock.wrap, near: 0))
  }

  private func transportFixture(clock: UInt64) -> [Data] {
    var tableCounter = 0
    var output = packets(Data([0, 0, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xF0, 0, 0, 0, 0, 0]),
      pid: 0, counter: &tableCounter)
    tableCounter = 0
    output += packets(Data([0, 2, 0xB0, 23, 0, 1, 0xC1, 0, 0, 0xE1, 1, 0xF0, 0,
      0x1B, 0xE1, 1, 0xF0, 0, 0x0F, 0xE1, 0, 0xF0, 0, 0, 0, 0, 0]), pid: 4096, counter: &tableCounter)
    var videoCounter = 0
    var audioCounter = 0
    var audioClock = clock
    for frame in 0..<60 {
      let time = clock + UInt64(frame * 3000)
      let payload = nal(Data([9, 0xF0]))
        + (frame == 0 ? nal(sps) + nal(pps) : Data())
        + nal(Data([frame == 0 ? 0x65 : 0x41, 0x80, 0x88]))
      output += packets(pes(payload, pts: time), pid: 257, counter: &videoCounter)
      while audioClock <= time + 3000 {
        output += packets(pes(adts(Data([0x21, 0x10, 0x04])), audio: true, pts: audioClock),
          pid: 256, counter: &audioCounter)
        audioClock += 1920
      }
    }
    return output
  }

  func testStreamingRemuxPublishesBeforeEOFWithContinuousSourcePresentationAndAudio() throws {
    var remuxer = try NativeTransportRemuxer(presentationEpoch: NativeMediaClock.wrap)
    let packets = transportFixture(clock: 90_000)
    var parts: [NativeTransportRemuxer.Part] = []
    for packet in packets { parts += try remuxer.append(packet) }
    XCTAssertFalse(parts.isEmpty, "Live parts must not wait for the whole segment")
    parts += try remuxer.finish(expectedDuration: 2)
    XCTAssertEqual(parts.count, 5)
    XCTAssertEqual(parts.reduce(0) { $0 + $1.videoSamples }, 60)
    XCTAssertEqual(parts.reduce(0) { $0 + $1.audioSamples }, 94)
    XCTAssertEqual(parts.reduce(0) { $0 + $1.duration }, 2, accuracy: 0.000001)
    XCTAssertEqual(parts[0].presentationTime, Int64(NativeMediaClock.wrap) + 90_000)
    XCTAssertTrue(parts[0].independent)
    XCTAssertTrue(parts.dropFirst().allSatisfy { !$0.independent })
    XCTAssertTrue(parts.allSatisfy { (0.3825...0.45).contains($0.duration) })
    XCTAssertThrowsError(try remuxer.append(packets[0]))
  }

  private func controlledFixture(slow: Bool, crossesDiscontinuity: Bool = false,
                                 noisyProbe: Bool = false,
                                 advancesTo: Int? = nil,
                                 trace: (@Sendable (NativeHLSPlaybackDiagnostic) -> Void)? = nil,
                                 failure: @escaping @Sendable (NativeHLSError) -> Void) throws
    -> NativeControlledHLSOrigin {
    actor Publication {
      private var crossed = false
      private var probes = 0
      private var completedSequence = 19
      func advance() { crossed = true }
      func hasAdvanced() -> Bool { crossed }
      func nextProbe() -> Int { probes += 1; return probes }
      func completed(_ sequence: Int) { completedSequence = max(completedSequence, sequence) }
      func latest() -> Int { completedSequence }
    }
    let publication = Publication()
    let base = Date().addingTimeInterval(-40)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n"
    var media: [String: Data] = [:]
    for sequence in 0..<20 {
      if crossesDiscontinuity, sequence == 10 { text += "#EXT-X-DISCONTINUITY\n" }
      text += "#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: base.addingTimeInterval(Double(sequence * 2))))\n"
      text += "#EXTINF:2,\n\(sequence).ts\n"
    }
    if crossesDiscontinuity {
      text += "#EXT-X-DISCONTINUITY\n"
      text += "#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: base.addingTimeInterval(41)))\n"
    }
    text += "#EXT-X-TWITCH-PREFETCH:20.ts\n"
    for sequence in 0...(advancesTo ?? 20) {
      let localSequence = crossesDiscontinuity ? sequence % 10 : sequence
      media["\(sequence).ts"] = transportFixture(clock: UInt64((localSequence * 2 + 1) * 90_000))
        .reduce(into: Data()) { $0.append($1) }
    }
    var advancingManifests: [Int: Data] = [:]
    if let advancesTo {
      for latest in 19...advancesTo {
        let first = max(0, latest - 19)
        var playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:\(first)\n"
        for sequence in first...latest {
          playlist += "#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: base.addingTimeInterval(Double(sequence * 2))))\n"
          playlist += "#EXTINF:2,\n\(sequence).ts\n"
        }
        playlist += latest == advancesTo ? "#EXT-X-ENDLIST\n" : "#EXT-X-TWITCH-PREFETCH:\(latest + 1).ts\n"
        advancingManifests[latest] = Data(playlist.utf8)
      }
    }
    let body = Data(text.utf8)
    let rolledBody = Data("""
      #EXTM3U
      #EXT-X-TARGETDURATION:6
      #EXT-X-MEDIA-SEQUENCE:20
      #EXT-X-DISCONTINUITY-SEQUENCE:2
      #EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: base.addingTimeInterval(41)))
      #EXTINF:2,
      20.ts
      #EXT-X-ENDLIST
      """.utf8)
    let mediaSamples = media
    let advancingBodies = advancingManifests
    let variants = try (0..<2).map { id in
      let url = URL(string: "https://fixture.test/\(id)/live.m3u8")!
      return NativeControlledHLSOrigin.Variant(id: id, url: url, bitrate: id == 0 ? 230_000 : 1_400_000,
        manifest: try NativeCMAF.manifest(text, url: url))
    }
    return NativeControlledHLSOrigin(variants: variants, headers: [:], history: 30, target: 6,
      namespace: UUID().uuidString, budget: .init(), loadData: { request in
        guard let url = request.url else { throw URLError(.badURL) }
        let data: Data
        if url.pathExtension == "m3u8" {
          let advanced = await publication.hasAdvanced()
          let latest = await publication.latest()
          data = advancingBodies[latest] ?? (crossesDiscontinuity && advanced ? rolledBody : body)
        }
        else {
          if slow { try await Task.sleep(for: .seconds(30)) }
          if noisyProbe, request.value(forHTTPHeaderField: "Range") != nil {
            let attempt = await publication.nextProbe()
            if attempt == 1 { try await Task.sleep(for: .milliseconds(750)) }
          }
          guard let sample = mediaSamples[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
          data = sample
          if advancesTo != nil, request.value(forHTTPHeaderField: "Range") == nil,
            let sequence = Int(url.deletingPathExtension().lastPathComponent) {
            await publication.completed(sequence)
          }
          if crossesDiscontinuity, url.lastPathComponent == "20.ts" { await publication.advance() }
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
          throw URLError(.badServerResponse)
        }
        return (data, response)
      }, diagnostic: { _ in }, trace: trace, failure: failure)
  }

  func testSlowCapacityProbeIsConfirmedBeforeDowngradingHealthyControlledLivePlayback() async throws {
    let capacity = expectation(description: "The slow probe must receive a fresh confirmation")
    let failure = expectation(description: "The isolated probe slowdown must not fail or downshift live")
    failure.isInverted = true
    let origin = try controlledFixture(slow: false, noisyProbe: true, trace: { detail in
      if detail.event == .rendition, detail.counters["rendition"] == 0 { failure.fulfill() }
      if detail.attributes["reason"] == "capacity_sample",
        let first = detail.metrics["initial_capacity_bps"], first < 1_400_000 {
        XCTAssertGreaterThan(detail.metrics["estimated_capacity_bps"] ?? 0, 1_400_000 / 0.75)
        capacity.fulfill()
      }
    }) { _ in failure.fulfill() }
    addTeardownBlock { await origin.stop() }
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/root.m3u8")!)
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/0.m3u8")!)
    await fulfillment(of: [capacity], timeout: 5)
    await origin.stop()
    await fulfillment(of: [failure], timeout: 0.1)
  }

  func testControlledProducerCrossesTimestampResetAndRetainsOldPeriodRewindAfterManifestRolls() async throws {
    let failure = expectation(description: "A declared upstream transition must not fail live")
    failure.isInverted = true
    let origin = try controlledFixture(slow: false, crossesDiscontinuity: true) { _ in failure.fulfill() }
    addTeardownBlock { await origin.stop() }
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/root.m3u8")!)
    let url = URL(string: "strozz-native-ll://fixture/media/0.m3u8")!
    var playlist = ""
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    repeat {
      guard case .playlist(let bytes) = try await origin.response(url) else { return XCTFail("Expected playlist") }
      playlist = String(decoding: bytes, as: UTF8.self)
      if playlist.contains("#EXT-X-ENDLIST") { break }
      try await Task.sleep(for: .milliseconds(25))
    } while ContinuousClock.now < deadline
    XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"), "The real producer must finish the successor period")
    guard case .playlist(let ended) = try await origin.response(
      URL(string: "strozz-native-ll://fixture/media/0.m3u8?_HLS_msn=1000")!) else {
      return XCTFail("An ended publication must remain readable for later reload requests")
    }
    XCTAssertEqual(String(decoding: ended, as: UTF8.self), playlist)
    for period in 0...2 {
      XCTAssertTrue(playlist.contains("/init/0/\(period).mp4"))
      let initialization = await origin.media("/init/0/\(period).mp4")
      XCTAssertNotNil(initialization)
    }
    XCTAssertEqual(playlist.components(separatedBy: "#EXT-X-DISCONTINUITY\n").count - 1, 2)
    let latestBytes = await origin.media("/segment/0/20.mp4")
    let latest = try XCTUnwrap(latestBytes)
    let moof = try NativeCMAF.boxes(latest).first { $0.type == "moof" }
    let timing = try NativeCMAF.timing(XCTUnwrap(moof).payload,
      track: .init(id: 1, scale: 90_000, duration: 0, flags: 0))
    XCTAssertEqual(timing.start, Double(NativeMediaClock.wrap) / 90_000 + 1, accuracy: 0.000001)
    let oldBytes = await origin.media("/segment/0/9.mp4")
    XCTAssertNotNil(oldBytes, "Old-period metadata must survive the upstream manifest sliding past it")
    await fulfillment(of: [failure], timeout: 0.1)
  }

  func testStableControlledPublicationPreservesPartBytesAndCacheAccounting() async throws {
    let origin = try controlledFixture(slow: false) { error in XCTFail("Unexpected origin failure: \(error)") }
    addTeardownBlock { await origin.stop() }
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/root.m3u8")!)
    let url = URL(string: "strozz-native-ll://fixture/media/0.m3u8")!
    _ = try await origin.response(url)
    for _ in 0..<100 {
      if await origin.snapshot().parts == 10 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let before = await origin.snapshot()
    XCTAssertEqual(before.parts, 10)
    guard case .playlist(let expected) = try await origin.response(url) else { return XCTFail("Expected playlist") }
    for _ in 0..<20 {
      guard case .playlist(let repeated) = try await origin.response(url) else { return XCTFail("Expected playlist") }
      XCTAssertEqual(repeated, expected, "Stable publication must not alter wire bytes")
    }
    let text = String(decoding: expected, as: UTF8.self)
    var resources = Set<String>()
    for line in text.components(separatedBy: .newlines)
      where line.hasPrefix("#EXT-X-PART:") || line.hasPrefix("#EXT-X-PRELOAD-HINT:") {
      let attributes = NativeCMAF.attributes(String(line.split(separator: ":", maxSplits: 1)[1]))
      let resource = try XCTUnwrap(attributes["URI"].flatMap(URL.init(string:)))
      resources.insert(resource.path)
    }
    XCTAssertEqual(resources.count, 10, "Include the intentionally withheld preload part in byte accounting")
    var bytes = 0
    for resource in resources {
      let value = await origin.media(resource)
      bytes += try XCTUnwrap(value).count
    }
    XCTAssertEqual(before.cachedMediaBytes, bytes)
    let pending = Task {
      try await origin.response(URL(string: "strozz-native-ll://fixture/media/0.m3u8?_HLS_msn=20&_HLS_part=127")!)
    }
    try await Task.sleep(for: .milliseconds(35))
    pending.cancel()
    do {
      _ = try await pending.value
      XCTFail("A cancelled blocked reload must not return cached success")
    } catch { XCTAssertTrue(error is CancellationError) }
    guard case .playlist(let healthy) = try await origin.response(url) else { return XCTFail("Live must stay healthy") }
    XCTAssertEqual(healthy, expected)
    await origin.stop()
    let stopped = await origin.snapshot()
    XCTAssertEqual(stopped.cachedMediaBytes, 0)
  }

  func testManifestDateReusePreservesFractionPrecisionOffsetsAndFallback() throws {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    let values = ["2026-10-19T01:00:00.123Z", "2026-10-19T01:00:02Z",
      "2026-10-19T01:00:04.123456Z", "2026-10-19T01:00:06.9999999+05:30",
      "2026-10-19T01:00:08.123-0700"]
    var text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
    for (index, value) in values.enumerated() {
      text += "#EXT-X-PROGRAM-DATE-TIME:\(value)\n#EXTINF:2,\n\(index).ts\n"
    }
    let manifest = try NativeCMAF.manifest(text, url: URL(string: "https://fixture.test/live.m3u8")!)
    XCTAssertEqual(manifest.entries.map(\.date), values.map { fractional.date(from: $0) ?? whole.date(from: $0) })
  }

  func testExpiredHistoricalRequestDoesNotTerminateHealthyControlledLivePlayback() async throws {
    let failure = expectation(description: "Historical absence must not poison live")
    failure.isInverted = true
    let origin = try controlledFixture(slow: false) { _ in failure.fulfill() }
    addTeardownBlock { await origin.stop() }
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/root.m3u8")!)
    let url = URL(string: "strozz-native-ll://fixture/media/0.m3u8")!
    guard case .playlist(let first) = try await origin.response(url) else { return XCTFail("Expected playlist") }
    XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("#EXT-X-PART:"))
    let historicalBytes = await origin.media("/segment/0/9.mp4")
    let historical = try XCTUnwrap(historicalBytes)
    let historicalMoof = try NativeCMAF.boxes(historical).first { $0.type == "moof" }
    let timing = try NativeCMAF.timing(XCTUnwrap(historicalMoof).payload,
      track: .init(id: 1, scale: 90_000, duration: 0, flags: 0))
    XCTAssertEqual(timing.start, Double(NativeMediaClock.wrap) / 90_000 + 19, accuracy: 0.000001)
    let absent = await origin.media("/segment/0/999999.mp4")
    XCTAssertNil(absent)
    let absentInitialization = await origin.media("/init/0/999999.mp4")
    XCTAssertNil(absentInitialization)
    guard case .playlist = try await origin.response(url) else { return XCTFail("Live must remain available") }
    let healthy = await origin.snapshot()
    XCTAssertGreaterThan(healthy.cachedMediaBytes, 0)
    await origin.stop()
    let stopped = await origin.snapshot()
    XCTAssertEqual(stopped.cachedMediaBytes, 0)
    await fulfillment(of: [failure], timeout: 0.1)
  }

  func testStopCancelsControlledStartupAndDoesNotReportAPlaybackFailure() async throws {
    let failure = expectation(description: "Stopping startup is not a playback error")
    failure.isInverted = true
    let origin = try controlledFixture(slow: true) { _ in failure.fulfill() }
    let request = Task { try await origin.response(URL(string: "strozz-native-ll://fixture/root.m3u8")!) }
    try await Task.sleep(for: .milliseconds(30))
    await origin.stop()
    do {
      _ = try await request.value
      XCTFail("Stopped startup must not publish a master")
    } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    await fulfillment(of: [failure], timeout: 0.1)
  }

  func testAdvancingPublicationInvalidatesCachedPlaylistsAndRetainsDVRMetadataAfterMediaEviction() async throws {
    let origin = try controlledFixture(slow: false, advancesTo: 50) { error in
      XCTFail("Unexpected advancing origin failure: \(error)")
    }
    addTeardownBlock { await origin.stop() }
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/root.m3u8")!)
    let url = URL(string: "strozz-native-ll://fixture/media/0.m3u8")!
    var ended = ""
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    repeat {
      guard case .playlist(let data) = try await origin.response(url) else { return XCTFail("Expected playlist") }
      ended = String(decoding: data, as: UTF8.self)
      if ended.contains("#EXT-X-ENDLIST") { break }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    XCTAssertTrue(ended.contains("#EXT-X-ENDLIST"), "Completion must invalidate an earlier live response")
    XCTAssertTrue(ended.contains("PART-HOLD-BACK=3.5"),
      "Losing prefetch changes the existing cadence policy and must invalidate cached server control")
    XCTAssertTrue(ended.contains("/segment/0/50.mp4"))
    XCTAssertFalse(ended.contains("/segment/0/19.mp4"), "The bounded history must evict expired metadata")
    XCTAssertTrue(ended.contains("/segment/0/35.mp4"), "Keep the complete requested rewind duration")
    XCTAssertFalse(ended.contains("#EXTINF:0.000000"), "Evicting encoded parts must retain segment duration")
    XCTAssertEqual(ended.components(separatedBy: "#EXTINF:2.000000,").count - 1, 16)
    let latest = await origin.media("/segment/0/50.mp4")
    let initial = await origin.media("/segment/0/19.mp4")
    let retainedHistory = await origin.media("/segment/0/35.mp4")
    XCTAssertNotNil(latest)
    XCTAssertNil(initial)
    XCTAssertNotNil(retainedHistory, "Uncached rewind media must still be reconstructed without changing byte accounting")
    let before = await origin.snapshot()
    let retained = try XCTUnwrap(retainedHistory)
    // Encoded media retains only the last 26 seconds; the 30-second metadata
    // window includes older segments whose bytes are fetched on demand.
    var retainedBytes = 0
    for sequence in 38...50 {
      let media = await origin.media("/segment/0/\(sequence).mp4")
      retainedBytes += try XCTUnwrap(media).count
    }
    XCTAssertEqual(before.cachedMediaBytes, retainedBytes)
    XCTAssertGreaterThan(retained.count, 0)
    let after = await origin.snapshot()
    XCTAssertEqual(before.cachedMediaBytes, after.cachedMediaBytes)
  }
}

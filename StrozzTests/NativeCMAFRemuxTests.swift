import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeCMAFRemuxTests: XCTestCase {
  func testExact450msBoundaryDoesNotTryToSplitAnIndivisibleLastSample() throws {
    let cases: [(Int, [UInt64])] = [
      (1000, [133, 150, 167]),
      (60_000, [6000, 12_000, 9000]),
      (90_000, [9000, 9000, 9000, 13_500]),
      (1_000_000, [133_000, 150_000, 167_000]),
    ]
    for (scale, durations) in cases {
      let format = try NativeCMAFRemuxer.Format(initialization(scale: scale))
      let source = sampleStream(scale: scale, durations: durations)
      var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 1,
        firstSequence: 1, presentationReference: nil)
      let parts = try converter.append(source) + converter.finish(expectedDuration: 0.45)
      XCTAssertEqual(parts.count, 1, "A legal exact-target part must not require a sample split")
      XCTAssertEqual(parts[0].duration, 0.45)
      XCTAssertEqual(parts[0].videoSamples, durations.count)
      for track in [format.video, format.audio] {
        let before = try samples(source, track: track)
        let after = try samples(parts[0].bytes, track: track)
        let epoch = Int64(NativeCMAFClock.epochSeconds * track.scale)
        XCTAssertEqual(before.bytes, after.bytes)
        XCTAssertEqual(before.decode.map { $0 + epoch }, after.decode)
        XCTAssertEqual(before.presentation.map { $0 + epoch }, after.presentation)
        XCTAssertEqual(before.durations, after.durations)
        XCTAssertEqual(before.flags, after.flags)
      }
      var excessive = durations
      excessive[excessive.count - 1] += 1
      var rejected = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 1,
        firstSequence: 1, presentationReference: nil)
      XCTAssertThrowsError(try rejected.append(sampleStream(scale: scale, durations: excessive))) { error in
        XCTAssertEqual(NativeHLSError.classify(error), .partDuration,
          "Do not admit an unpartitionable part one video tick over the maximum")
      }
    }
  }

  func testMappedCMAFDropsOnlyIncompatibleHRDTimingAndRewritesSampleSizes() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    let timingAndCaption = Data([6, 0, 1, 0x11, 1, 1, 0x22, 4, 1, 0x55, 0x80])
    let caption = Data([6, 4, 1, 0x55, 0x80])
    let picture = Data([0x65, 0x80, 0x88])
    let payload = word(UInt64(timingAndCaption.count)) + timingAndCaption + word(UInt64(picture.count)) + picture
    let source = fragment(videoClock: 1_000_000, audioClock: 48_000, audioCount: 5,
      sequence: 1, independent: true, videoPayload: payload)
    var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 1,
      firstSequence: 1, presentationReference: nil)
    let parts = try converter.append(source) + converter.finish(expectedDuration: 0.1)
    let output = try XCTUnwrap(parts.first).bytes
    let image = try samples(output, track: format.video)
    XCTAssertEqual(image.bytes, [word(UInt64(caption.count)) + caption + word(UInt64(picture.count)) + picture])
    XCTAssertEqual(image.durations, [100_000])
    let originalAudio = try samples(source, track: format.audio)
    let audio = try samples(output, track: format.audio)
    XCTAssertEqual(originalAudio.bytes, audio.bytes)
    XCTAssertEqual(originalAudio.durations, audio.durations)
    XCTAssertThrowsError(try NativeFragmentedMP4.removingRemappedTimingAVC(Data([0, 0, 0, 8, 6])))
  }

  func testVariableCMAFFragmentsSplitAtSamplesWithoutChangingPayloadOrLatencyContract() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    var source = Data()
    var videoClock: UInt64 = 1_000_000
    var audioClock: UInt64 = 48_000
    for (index, durations) in [[33_000, 34_000, 33_000, 33_000], [33_000, 34_000, 33_000],
      [33_000, 34_000, 33_000, 33_000], [33_000, 34_000, 33_000]].enumerated() {
      var time = videoClock
      let video = durations.enumerated().map { number, duration in
        defer { time += UInt64(duration) }
        return NativeFragmentedMP4.Sample(decodeTime: time, duration: UInt32(duration),
          compositionOffset: number == 1 ? -1000 : 0, independent: index == 0 && number == 0,
          bytes: Data([0, 0, 0, 3, index == 0 && number == 0 ? 0x65 : 0x41, UInt8(index), UInt8(number)]))
      }
      let target = UInt64((Double(time) * 48_000 / 1_000_000).rounded())
      let count = Int((target - audioClock + 1023) / 1024)
      let audio = (0..<count).map { number in
        NativeFragmentedMP4.Sample(decodeTime: audioClock + UInt64(number * 1024), duration: 1024,
          compositionOffset: 0, independent: true, bytes: Data([0x21, UInt8(number), UInt8(index)]))
      }
      let original = try NativeFragmentedMP4.fragment(sequence: UInt32(index + 1), video: video, audio: audio)
      var movie = Data()
      for item in try NativeCMAF.boxes(NativeCMAF.child(original, "moof")) {
        guard item.type == "traf" else { movie += box(item.type, item.payload); continue }
        var track = Data()
        for component in try NativeCMAF.boxes(item.payload) {
          var value = component.payload
          if component.type == "tfhd" {
            value.replaceSubrange(4..<8, with: word(try NativeCMAF.integer(value, 4) == 1 ? 2 : 1))
          }
          track += box(component.type, value)
        }
        movie += box("traf", track)
      }
      source += box("moof", movie) + box("mdat", try NativeCMAF.child(original, "mdat"))
      videoClock = time
      audioClock += UInt64(count * 1024)
    }
    var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 2,
      firstSequence: 40, presentationReference: nil)
    let parts = try converter.append(source) + converter.finish(expectedDuration: 0.466)
    XCTAssertEqual(parts.count, 2)
    XCTAssertEqual(parts[0].duration, 0.433, accuracy: 0.000001)
    XCTAssertEqual(parts[1].duration, 0.033, accuracy: 0.000001)
    XCTAssertTrue(parts[0].independent)
    XCTAssertFalse(parts[1].independent)
    XCTAssertEqual(parts.reduce(0) { $0 + $1.videoSamples }, 14)
    let output = parts.reduce(into: Data()) { $0.append($1.bytes) }
    for track in [format.video, format.audio] {
      let before = try samples(source, track: track)
      let after = try samples(output, track: track)
      XCTAssertEqual(before.bytes, after.bytes, "Do not re-encode, reorder or discard any compressed samples")
      XCTAssertEqual(before.presentation.map { $0 - before.presentation[0] },
        after.presentation.map { $0 - after.presentation[0] })
      XCTAssertEqual(before.decode.map { $0 - before.decode[0] }, after.decode.map { $0 - after.decode[0] })
      XCTAssertEqual(before.durations, after.durations)
      XCTAssertEqual(before.flags, after.flags)
    }
    let sequences = try NativeCMAF.boxes(output).filter { $0.type == "moof" }
      .map { try NativeCMAF.integer(NativeCMAF.child($0.payload, "mfhd"), 4) }
    XCTAssertEqual(sequences, Array(40..<45).map(UInt64.init))
    XCTAssertEqual(converter.nextSequence, 45)
  }

  private func samples(_ data: Data, track: NativeCMAF.Track) throws ->
    (bytes: [Data], presentation: [Int64], decode: [Int64], durations: [UInt64], flags: [UInt64]) {
    var payloads: [Data] = [], presentation: [Int64] = [], decode: [Int64] = []
    var durations: [UInt64] = [], flags: [UInt64] = []
    var offset = 0
    for item in try NativeCMAF.boxes(data) {
      defer { offset += item.payload.count + 8 }
      guard item.type == "moof" else { continue }
      for child in try NativeCMAF.boxes(item.payload) where child.type == "traf" {
        let header = try NativeCMAF.child(child.payload, "tfhd")
        guard try NativeCMAF.integer(header, 4) == track.id else { continue }
        let clock = try NativeCMAF.child(child.payload, "tfdt")
        var time = Int64(try NativeCMAF.integer(clock, 4, clock.first == 1 ? 8 : 4))
        for run in try NativeCMAF.boxes(child.payload) where run.type == "trun" {
          let fields = try NativeCMAF.integer(run.payload, 0) & 0xFFFFFF
          let count = Int(try NativeCMAF.integer(run.payload, 4))
          var body = offset + Int(try NativeCMAF.integer(run.payload, 8))
          var position = 12
          for _ in 0..<count {
            let duration = try NativeCMAF.integer(run.payload, position)
            let size = Int(try NativeCMAF.integer(run.payload, position + 4))
            var next = position + 8
            let flag = fields & 0x400 != 0 ? try NativeCMAF.integer(run.payload, next) : track.flags
            if fields & 0x400 != 0 { next += 4 }
            let composition: Int64
            if fields & 0x800 != 0 {
              composition = Int64(Int32(bitPattern: UInt32(try NativeCMAF.integer(run.payload, next))))
              next += 4
            } else { composition = 0 }
            guard size > 0, body >= 0, body <= data.count - size else { throw NativeHLSError.invalidMedia }
            payloads.append(data.subdata(in: body..<(body + size)))
            presentation.append(time + composition)
            decode.append(time)
            durations.append(duration)
            flags.append(flag)
            time += Int64(duration)
            body += size
            position = next
          }
        }
      }
    }
    return (payloads, presentation, decode, durations, flags)
  }

  private func sampleStream(scale: Int, durations: [UInt64]) -> Data {
    var output = Data()
    var video = UInt64(scale)
    var audio: UInt64 = 48_000
    for (index, duration) in durations.enumerated() {
      let nextVideo = video + duration
      let targetAudio = nextVideo * 48_000 / UInt64(scale)
      let count = Int((targetAudio - audio + 1023) / 1024)
      output += fragment(videoClock: video, audioClock: audio, audioCount: count,
        sequence: UInt64(index + 1), independent: index == 0, videoDuration: duration)
      video = nextVideo
      audio += UInt64(count * 1024)
    }
    return output
  }

  func testSplittingAnOversizedNormalizedFragmentKeepsEverySampleAndRejectsInvalidBounds() throws {
    let videoTrack = NativeCMAF.Track(id: 1, scale: 90_000, duration: 0, flags: 0)
    let audioTrack = NativeCMAF.Track(id: 2, scale: 48_000, duration: 0, flags: 0)
    let video = (0..<30).map { index -> NativeFragmentedMP4.Sample in
      let clock = UInt64(9_000_000) + UInt64(index) * 1500
      let composition: Int32 = index.isMultiple(of: 2) ? 0 : -750
      let kind: UInt8 = index == 0 ? 0x65 : 0x41
      let bytes = Data([0, 0, 0, 2, kind, UInt8(index)])
      return .init(decodeTime: clock, duration: 1500,
        compositionOffset: composition, independent: index == 0, bytes: bytes)
    }
    let audio = (0..<24).map { index in
      NativeFragmentedMP4.Sample(decodeTime: UInt64(4_800_000 + index * 1024), duration: 1024,
        compositionOffset: 0, independent: true, bytes: Data([0x21, UInt8(index)]))
    }
    let source = try NativeFragmentedMP4.fragment(sequence: 1, video: video, audio: audio)
    let normalized = try NativeFragmentedMP4.controlledFragment(source, video: videoTrack, audio: audioTrack,
      videoDescriptionIndex: 2, videoDecodeTime: 9_000_000, compositionShift: 0,
      audioDecodeTime: 4_800_000, sequence: 7)
    let split = try NativeFragmentedMP4.splitControlledFragment(normalized, video: videoTrack,
      audio: audioTrack, maximumVideoTicks: 40_500, sequence: 7)
    let first = try NativeCMAF.fragmentTiming(NativeCMAF.child(split.0, "moof"), track: videoTrack)
    XCTAssertEqual(first.duration, 40_500)
    for track in [videoTrack, audioTrack] {
      let before = try samples(normalized, track: track)
      let after = try samples(split.0 + split.1, track: track)
      XCTAssertEqual(before.bytes, after.bytes)
      XCTAssertEqual(before.presentation, after.presentation)
      XCTAssertEqual(before.decode, after.decode)
      XCTAssertEqual(before.durations, after.durations)
      XCTAssertEqual(before.flags, after.flags)
    }
    for (limit, sequence) in [(UInt64(0), UInt32(7)), (90, 7), (40_500, UInt32.max)] {
      XCTAssertThrowsError(try NativeFragmentedMP4.splitControlledFragment(normalized,
        video: videoTrack, audio: audioTrack, maximumVideoTicks: limit, sequence: sequence)) { error in
        if limit == 90 {
          XCTAssertEqual(NativeHLSError.classify(error), .partDuration)
          let diagnostic = NativeHLSFailureDiagnostic(error: error, operation: "indexing",
            rendition: 0, active: 0, fatal: true)
          XCTAssertEqual(diagnostic.attributes["detail"], "partial_sample_boundary")
          XCTAssertEqual(diagnostic.counters["incoming_video_ticks"], 45_000)
          XCTAssertEqual(diagnostic.counters["maximum_video_ticks"], 90)
          XCTAssertEqual(diagnostic.counters["first_video_sample_ticks"], 1500)
          XCTAssertEqual(diagnostic.counters["video_timescale"], 90_000)
          XCTAssertEqual(diagnostic.counters["incoming_video_samples"], 30)
          XCTAssertEqual(diagnostic.counters["incoming_audio_samples"], 24)
        }
      }
    }
    XCTAssertThrowsError(try NativeFragmentedMP4.splitControlledFragment(Data(normalized.dropLast()),
      video: videoTrack, audio: audioTrack, maximumVideoTicks: 40_500, sequence: 7))
  }

  func testFreeSpaceBoxesPreserveRemuxedMediaAcrossChunkBoundaries() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    let source = segment(videoClock: 19_000_000, audioClock: 912_000)
    var original = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 3,
      firstSequence: 70, presentationReference: nil)
    let expected = try original.append(source) + original.finish(expectedDuration: 2)
    for type in ["free", "skip"] {
      for padding in [box(type, Data()), box(type, Data([1, 2, 3])),
        word(1) + Data(type.utf8) + word(0) + word(16)] {
        var padded = padding
        for item in try NativeCMAF.boxes(source) {
          padded += box(item.type, item.payload)
          if item.type == "mdat" { padded += padding }
        }
        for chunkSize in [1, 7, 37, padded.count] {
          var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 3,
            firstSequence: 70, presentationReference: nil)
          var parts: [NativeTransportRemuxer.Part] = []
          for offset in stride(from: 0, to: padded.count, by: chunkSize) {
            parts += try converter.append(padded.subdata(in: offset..<min(offset + chunkSize, padded.count)))
          }
          parts += try converter.finish(expectedDuration: 2)
          XCTAssertEqual(parts.map(\.bytes), expected.map(\.bytes),
            "\(type) padding must not change samples, clocks, offsets or part boundaries")
          XCTAssertEqual(parts.map(\.duration), expected.map(\.duration))
          XCTAssertEqual(parts.map(\.independent), expected.map(\.independent))
          XCTAssertEqual(converter.nextSequence, original.nextSequence)
        }
      }
    }
  }

  func testFreeSpaceBoxesStillRejectInvalidSizesTruncationAndEmbeddedOffsets() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    let source = fragment(videoClock: 1_000_000, audioClock: 48_000, audioCount: 5,
      sequence: 1, independent: true)
    for type in ["free", "skip"] {
      for padding in [word(7) + Data(type.utf8), word(33 * 1024 * 1024) + Data(type.utf8),
        Data(box(type, Data([1])).dropLast())] {
        var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 1,
          firstSequence: 1, presentationReference: nil)
        XCTAssertThrowsError(try converter.append(source + padding) + converter.finish(expectedDuration: 0.1)) {
          XCTAssertEqual(NativeHLSError.classify($0), .invalidMedia)
        }
      }
      var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 1,
        firstSequence: 1, presentationReference: nil)
      let movie = try box("moof", NativeCMAF.child(source, "moof"))
      XCTAssertThrowsError(try converter.append(movie + box(type, Data()))) {
        XCTAssertEqual(NativeHLSError.classify($0), .unsupported,
          "Do not discard bytes between moof and mdat without adjusting their offsets")
      }
    }
  }

  func testUnknownEightByteMediaBoxReportsOnlyItsStructuralIdentity() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 1,
      firstSequence: 1, presentationReference: nil)
    XCTAssertThrowsError(try converter.append(box("zzzz", Data()))) { error in
      XCTAssertEqual(NativeHLSError.classify(error), .unsupported)
      let diagnostic = NativeHLSFailureDiagnostic(error: error, operation: "indexing",
        rendition: 0, active: 0, fatal: true)
      XCTAssertEqual(diagnostic.attributes["detail"], "unsupported_iso_box")
      XCTAssertEqual(diagnostic.counters["iso_box_type"], 0x7A7A7A7A)
      XCTAssertEqual(diagnostic.counters["iso_box_bytes"], 8)
    }
  }

  func testControlledPlaybackIsTheReleaseDefaultWithoutDiagnosticLaunchArguments() {
    #if DEBUG
    XCTAssertEqual(NativeLowLatencyHLS.controlledAutoEnabled,
      ProcessInfo.processInfo.environment["STROZZ_NATIVE_CONTROLLED_AUTO"] != "0")
    #else
    XCTAssertTrue(NativeLowLatencyHLS.controlledAutoEnabled,
      "TestFlight must ship the verified engine even when a Debug opt-out is present in the environment")
    #endif
  }

  private func word(_ value: UInt64) -> Data {
    Data((0..<4).reversed().map { UInt8((value >> ($0 * 8)) & 255) })
  }

  private func box(_ type: String, _ payload: Data) -> Data {
    word(UInt64(payload.count + 8)) + Data(type.utf8) + payload
  }

  private func full(_ type: String, _ payload: Data, flags: UInt64 = 0) -> Data {
    box(type, word(flags) + payload)
  }

  private func initialization(scale: Int = 1_000_000, channels: Int = 2) throws -> Data {
    let config = try NativeFragmentedMP4.Configuration(
      sps: Data([0x67, 0x4D, 0x40, 0x0A, 0xEC, 0xA2, 0x13, 0x60, 0x22, 0,
        0, 3, 0, 2, 0, 0, 3, 0, 0x78, 0x1E, 0x24, 0x4B, 0x2C]),
      pps: Data([0x68, 0xEB, 0xE3, 0xCB, 0x20]),
      audioConfig: channels == 2 ? Data([0x11, 0x90]) : Data([0x11, 0x88]),
      audioRate: 48_000, audioChannels: channels, videoTimescale: scale)
    func reversedIDs(_ data: Data) throws -> Data {
      try NativeCMAF.boxes(data).reduce(into: Data()) { result, item in
        var payload = item.payload
        if item.type == "tkhd" || item.type == "trex" {
          let offset = item.type == "tkhd" ? 12 : 4
          let id = try NativeCMAF.integer(payload, offset)
          payload.replaceSubrange(offset..<(offset + 4), with: word(id == 1 ? 2 : 1))
        } else if ["moov", "trak", "mvex"].contains(item.type) {
          payload = try reversedIDs(payload)
        }
        result.append(box(item.type, payload))
      }
    }
    return try reversedIDs(NativeFragmentedMP4.initialization(config))
  }

  private func fragment(videoClock: UInt64, audioClock: UInt64, audioCount: Int,
                        sequence: UInt64, independent: Bool, videoPayload: Data? = nil,
                        videoDuration: UInt64 = 100_000) -> Data {
    let videoBytes = videoPayload ?? Data([0, 0, 0, 2, independent ? 0x65 : 0x41, UInt8(sequence & 255)])
    let audioBytes = Data(repeating: 0x21, count: audioCount * 3)
    func traf(id: UInt64, audio: Bool, offset: Int) -> Data {
      let header = full("tfhd", word(id), flags: 0x020000)
      let clock = full("tfdt", word((audio ? audioClock : videoClock) % (1 << 32)))
      var run = word(UInt64(audio ? audioCount : 1)) + word(UInt64(offset))
      if audio {
        for _ in 0..<audioCount { run += word(1024) + word(3) }
      } else {
        run += word(videoDuration) + word(UInt64(videoBytes.count))
          + word(independent ? 0x02000000 : 0x01010000)
      }
      return box("traf", header + clock + full("trun", run, flags: audio ? 0x301 : 0x701))
    }
    func movie(audioOffset: Int, videoOffset: Int) -> Data {
      box("moof", full("mfhd", word(sequence))
        + traf(id: 1, audio: true, offset: audioOffset)
        + traf(id: 2, audio: false, offset: videoOffset))
    }
    let size = movie(audioOffset: 0, videoOffset: 0).count
    return movie(audioOffset: size + 8, videoOffset: size + 8 + audioBytes.count)
      + box("mdat", audioBytes + videoBytes)
  }

  private func segment(videoClock: UInt64, audioClock: UInt64) -> Data {
    var result = box("emsg", Data([0, 0, 0, 0]))
    var audio = audioClock
    for index in 0..<20 {
      let video = videoClock + UInt64(index * 100_000)
      let target = UInt64((Double(video + 100_000) * 48_000 / 1_000_000).rounded())
      let count = max(1, Int((target - audio + 1023) / 1024))
      result += fragment(videoClock: video, audioClock: audio, audioCount: count,
        sequence: UInt64(index + 1), independent: index == 0)
      audio += UInt64(count * 1024)
    }
    return result
  }

  func testReadsIncomingMicrosecondMovieWithAudioOneVideoTwoAndAACDescription() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    XCTAssertEqual(format.video.id, 2)
    XCTAssertEqual(format.audio.id, 1)
    XCTAssertEqual(format.video.scale, 1_000_000)
    XCTAssertEqual(format.configuration.videoTimescale, 1_000_000)
    XCTAssertEqual(format.configuration.audioRate, 48_000)
    XCTAssertEqual(format.configuration.audioConfig, Data([0x11, 0x90]))
    XCTAssertEqual(format.configuration.width, 64)
    XCTAssertEqual(format.configuration.height, 64)
  }

  func testStreamsBeforeEOFAndPreservesPayloadsWhileMakingOffsetsDefaultsAndClocksExplicit() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    let source = segment(videoClock: 19_000_000, audioClock: 912_000)
    var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 3,
      firstSequence: 70, presentationReference: nil)
    var parts: [NativeTransportRemuxer.Part] = []
    for offset in stride(from: 0, to: source.count - 1, by: 37) {
      parts += try converter.append(source.subdata(in: offset..<min(offset + 37, source.count - 1)))
    }
    XCTAssertFalse(parts.isEmpty, "Publishing must not wait for the completed source body")
    parts += try converter.append(Data(source.suffix(1)))
    parts += try converter.finish(expectedDuration: 2)
    XCTAssertEqual(parts.count, 5)
    XCTAssertEqual(parts.reduce(0) { $0 + $1.videoSamples }, 20)
    XCTAssertEqual(parts.reduce(0) { $0 + $1.audioSamples }, 94)
    XCTAssertEqual(parts.reduce(0) { $0 + $1.duration }, 2, accuracy: 0.000001)
    XCTAssertEqual(parts[0].decodeTime, 100_019_000_000)
    XCTAssertEqual(parts[0].audioDecodeTime, 4_800_912_000)
    XCTAssertTrue(parts[0].independent)
    XCTAssertTrue(parts.dropFirst().allSatisfy { !$0.independent })
    XCTAssertTrue(parts.allSatisfy { (0.3825...0.45).contains($0.duration) })
    let output = parts.reduce(into: Data()) { $0.append($1.bytes) }
    XCTAssertEqual(try NativeCMAF.boxes(source).filter { $0.type == "mdat" }.map(\.payload),
      try NativeCMAF.boxes(output).filter { $0.type == "mdat" }.map(\.payload))
    let moof = try NativeCMAF.child(parts[0].bytes.prefix(firstMoofSize(parts[0].bytes)), "moof")
    let tracks = try NativeCMAF.boxes(moof).filter { $0.type == "traf" }
    for track in tracks {
      let tfhd = try NativeCMAF.child(track.payload, "tfhd")
      let id = try NativeCMAF.integer(tfhd, 4)
      XCTAssertEqual(try NativeCMAF.integer(tfhd, 8), id == 2 ? 3 : 1)
      XCTAssertEqual(try NativeCMAF.child(track.payload, "tfdt").first, 1)
      let run = try NativeCMAF.child(track.payload, "trun")
      XCTAssertEqual(try NativeCMAF.integer(run, 0) & 0xFFFFFF, id == 2 ? 0xF01 : 0x701)
      let offset = Int(try NativeCMAF.integer(run, 8))
      XCTAssertGreaterThan(offset, try firstMoofSize(parts[0].bytes))
      XCTAssertLessThan(offset, parts[0].bytes.count)
    }
    XCTAssertEqual(converter.nextSequence, 90)
    XCTAssertThrowsError(try converter.append(source))
  }

  private func firstMoofSize(_ bytes: Data) throws -> Int {
    Int(try NativeCMAF.integer(bytes, 0))
  }

  func testUnequalV0WrapPeriodsRecoverTheirCommonPhaseAndHistoricalReference() throws {
    let seconds: UInt64 = 90_000
    let video = NativeCMAF.FragmentTiming(version: 0, decodeTime: seconds * 1_000_000 % (1 << 32),
      duration: 100_000, samples: 1, firstComposition: 0, independent: true)
    let audio = NativeCMAF.FragmentTiming(version: 0, decodeTime: seconds * 48_000 % (1 << 32),
      duration: 4800, samples: 5, firstComposition: 0, independent: true)
    let clocks = try NativeCMAFClock.initial(video: video, audio: audio,
      videoScale: 1_000_000, audioScale: 48_000, reference: nil)
    XCTAssertEqual(clocks.0, 190_000_000_000)
    XCTAssertEqual(clocks.1, 9_120_000_000)
    var clock = NativeMediaClock()
    let date = Date(timeIntervalSince1970: 1000)
    try clock.observe(period: 0, date: date, presentationTime: clocks.0, scale: 1_000_000)
    let historical = try XCTUnwrap(clock.reference(period: 0, date: date.addingTimeInterval(-2), scale: 1_000_000))
    XCTAssertEqual(try NativeCMAFClock.unwrap((seconds - 2) * 1_000_000 % (1 << 32),
      version: 0, scale: 1_000_000, near: historical), clocks.0 - 2_000_000)
    XCTAssertEqual(try clock.reference(period: 0, date: date, scale: 90_000), 17_100_000_000)
  }

  func testExtendedSizeMovieAndMediaHeadersRetainCorrectPayloadOffsets() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    let source = fragment(videoClock: 1_000_000, audioClock: 48_000, audioCount: 5,
      sequence: 1, independent: true)
    let oldMovie = try NativeCMAF.child(source, "moof")
    var movie = Data()
    for item in try NativeCMAF.boxes(oldMovie) {
      guard item.type == "traf" else { movie.append(box(item.type, item.payload)); continue }
      var track = Data()
      for component in try NativeCMAF.boxes(item.payload) {
        var bytes = component.payload
        if component.type == "trun" {
          let offset = try NativeCMAF.integer(bytes, 8)
          bytes.replaceSubrange(8..<12, with: word(offset + 16))
        }
        track.append(box(component.type, bytes))
      }
      movie.append(box("traf", track))
    }
    func extended(_ type: String, _ payload: Data) -> Data {
      let size = UInt64(payload.count + 16)
      return word(1) + Data(type.utf8)
        + Data((0..<8).reversed().map { UInt8((size >> ($0 * 8)) & 255) }) + payload
    }
    let input = extended("moof", movie) + extended("mdat", try NativeCMAF.child(source, "mdat"))
    var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 1,
      firstSequence: 1, presentationReference: nil)
    let parts = try converter.append(input) + converter.finish(expectedDuration: 0.1)
    let output = try XCTUnwrap(parts.first).bytes
    XCTAssertEqual(try NativeCMAF.child(output, "mdat"), try NativeCMAF.child(source, "mdat"))
    let outputMovie = try NativeCMAF.child(output, "moof")
    for track in try NativeCMAF.boxes(outputMovie) where track.type == "traf" {
      let run = try NativeCMAF.child(track.payload, "trun")
      let offset = Int(try NativeCMAF.integer(run, 8))
      XCTAssertTrue(output.indices.contains(offset))
      XCTAssertGreaterThan(offset, outputMovie.count + 8)
      let id = try NativeCMAF.integer(NativeCMAF.child(track.payload, "tfhd"), 4)
      XCTAssertEqual(output.subdata(in: offset..<(offset + (id == 2 ? 6 : 3))),
        id == 2 ? Data([0, 0, 0, 2, 0x65, 1]) : Data(repeating: 0x21, count: 3))
    }
  }

  func testVideoAndAudioV0RolloverWithinSegmentsKeepUnbrokenTimelines() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    for (video, audio) in [
      ((UInt64(1) << 32) - 50_000, UInt64((Double((UInt64(1) << 32) - 50_000) * 0.048).rounded())),
      (UInt64((Double((UInt64(1) << 32) - 2048) / 0.048).rounded()), (UInt64(1) << 32) - 2048),
    ] {
      var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 1,
        firstSequence: 1, presentationReference: nil)
      let parts = try converter.append(segment(videoClock: video, audioClock: audio))
        + converter.finish(expectedDuration: 2)
      let times = try parts.flatMap { try NativeCMAF.boxes($0.bytes) }.filter { $0.type == "moof" }
        .map { try NativeCMAF.fragmentTiming($0.payload, track: format.video).decodeTime }
      XCTAssertEqual(times.count, 20)
      for (before, after) in zip(times, times.dropFirst()) { XCTAssertEqual(after - before, 100_000) }
    }
  }

  func testRejectsTruncationIncompatibleMovieTimescalesAndAudioFormats() throws {
    let input = try initialization()
    let format = try NativeCMAFRemuxer.Format(input)
    var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 1,
      firstSequence: 1, presentationReference: nil)
    _ = try converter.append(Data(segment(videoClock: 1_000_000, audioClock: 48_000).dropLast()))
    XCTAssertThrowsError(try converter.finish(expectedDuration: 2))
    XCTAssertThrowsError(try NativeFragmentedMP4.switchingInitialization(
      [input, initialization(scale: 90_000)], maximumResolutionIndex: 0))
    XCTAssertThrowsError(try NativeFragmentedMP4.switchingInitialization(
      [input, initialization(channels: 1)], maximumResolutionIndex: 0))
    XCTAssertThrowsError(try NativeCMAFRemuxer.Format(Data([1, 2, 3])))
  }

  func testSignedBFrameCompositionKeepsPresentationAndAudioWhileNormalizingOnlyDecodeOrigin() throws {
    let format = try NativeCMAFRemuxer.Format(initialization())
    let samples = [
      NativeFragmentedMP4.Sample(decodeTime: 9_000_000, duration: 50_000, compositionOffset: 100_000,
        independent: true, bytes: Data([0, 0, 0, 2, 0x65, 3])),
      NativeFragmentedMP4.Sample(decodeTime: 9_050_000, duration: 50_000, compositionOffset: -50_000,
        independent: false, bytes: Data([0, 0, 0, 2, 0x41, 5])),
    ]
    let audio = (0..<5).map { index in
      NativeFragmentedMP4.Sample(decodeTime: UInt64(432_000 + index * 1024), duration: 1024,
        compositionOffset: 0, independent: true, bytes: Data([6, 7]))
    }
    let encoded = try NativeFragmentedMP4.fragment(sequence: 1, video: samples, audio: audio)
    let oldMoof = try NativeCMAF.child(encoded, "moof")
    var rewrittenIDs = Data()
    for child in try NativeCMAF.boxes(oldMoof) {
      guard child.type == "traf" else { rewrittenIDs.append(box(child.type, child.payload)); continue }
      var payload = Data()
      for component in try NativeCMAF.boxes(child.payload) {
        var value = component.payload
        if component.type == "tfhd" {
          let id = try NativeCMAF.integer(value, 4)
          value.replaceSubrange(4..<8, with: word(id == 1 ? 2 : 1))
        }
        payload.append(box(component.type, value))
      }
      rewrittenIDs.append(box("traf", payload))
    }
    let input = box("moof", rewrittenIDs) + box("mdat", try NativeCMAF.child(encoded, "mdat"))
    var converter = try NativeCMAFRemuxer(format: format, videoDescriptionIndex: 2,
      firstSequence: 7, presentationReference: nil)
    let parts = try converter.append(input) + converter.finish(expectedDuration: 0.1)
    let part = try XCTUnwrap(parts.first)
    XCTAssertEqual(part.decodeTime, 100_009_100_000)
    XCTAssertEqual(part.audioDecodeTime, 4_800_432_000)
    let movie = try NativeCMAF.child(part.bytes, "moof")
    let track = try XCTUnwrap(NativeCMAF.boxes(movie).first {
      $0.type == "traf" && (try? NativeCMAF.integer(NativeCMAF.child($0.payload, "tfhd"), 4)) == 2
    })
    let run = try NativeCMAF.child(track.payload, "trun")
    XCTAssertEqual(Int32(bitPattern: UInt32(try NativeCMAF.integer(run, 24))), 0)
    XCTAssertEqual(Int32(bitPattern: UInt32(try NativeCMAF.integer(run, 40))), -150_000)
    XCTAssertEqual(part.decodeTime + 50_000 - 150_000, 100_009_000_000)
    XCTAssertEqual(try NativeCMAF.child(part.bytes, "mdat"), try NativeCMAF.child(input, "mdat"))
  }

  func testInitialClockPhaseUsesPresentationRatherThanDecodeDelay() throws {
    let video = NativeCMAF.FragmentTiming(version: 0, decodeTime: 8_000_000,
      duration: 100_000, samples: 1, firstComposition: 1_000_000, independent: true)
    let audio = NativeCMAF.FragmentTiming(version: 0, decodeTime: 432_000,
      duration: 4800, samples: 5, firstComposition: 0, independent: true)
    let clocks = try NativeCMAFClock.initial(video: video, audio: audio,
      videoScale: 1_000_000, audioScale: 48_000, reference: nil)
    XCTAssertEqual(clocks.0, 100_008_000_000)
    XCTAssertEqual(clocks.1, 4_800_432_000)
  }

  func testControlledOriginActuallyOwnsMappedCMAFAutoAndPreservesRewind() async throws {
    let initialization = try initialization()
    let base = Date().addingTimeInterval(-40)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var manifest = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"init.mp4\"\n"
    var media: [String: Data] = [:]
    for sequence in 0...20 {
      if sequence == 8 { manifest += "#EXT-X-MAP:URI=\"rotated-init.mp4\"\n" }
      if sequence == 10 { manifest += "#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"period-init.mp4\"\n" }
      let localSequence = sequence < 10 ? sequence : sequence - 10
      media["\(sequence).m4s"] = segment(videoClock: UInt64(localSequence * 2 + 1) * 1_000_000,
        audioClock: UInt64(localSequence * 2 + 1) * 48_000)
      if sequence < 20 {
        manifest += "#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: base.addingTimeInterval(Double(sequence * 2))))\n#EXTINF:2,\n\(sequence).m4s\n"
      }
    }
    manifest += "#EXT-X-TWITCH-PREFETCH:20.m4s\n"
    let mediaData = media
    let playlist = Data(manifest.utf8)
    let master = Data("""
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=230000,RESOLUTION=64x64
      0/live.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=64x64
      1/live.m3u8
      """.utf8)
    let origin = NativeHLSOrigin(root: URL(string: "https://fixture.test/master.m3u8")!,
      headers: [:], history: 30, loadData: { request in
        let url = try XCTUnwrap(request.url)
        let data: Data
        switch url.lastPathComponent {
        case "master.m3u8": data = master
        case "live.m3u8": data = playlist
        case "init.mp4", "rotated-init.mp4", "period-init.mp4": data = initialization
        default: data = try XCTUnwrap(mediaData[url.lastPathComponent])
        }
        return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
      }, controlledAuto: true, failure: { _ in XCTFail("Mapped CMAF must not fail controlled setup") })
    addTeardownBlock { await origin.stop() }
    guard case .playlist(let root) = try await origin.response(URL(string: "strozz-native-ll://fixture/root.m3u8")!)
      else { return XCTFail("Expected controlled master") }
    XCTAssertTrue(String(decoding: root, as: UTF8.self).contains("-controlled"))
    XCTAssertEqual(String(decoding: root, as: UTF8.self).components(separatedBy: "#EXT-X-STREAM-INF:").count, 2)
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/0.m3u8")!)
    let oldBytes = await origin.media("/segment/0/9.mp4")
    let old = try XCTUnwrap(oldBytes)
    let moof = try NativeCMAF.boxes(old).first { $0.type == "moof" }
    let video = try NativeCMAF.videoTrack(initialization)
    XCTAssertEqual(try NativeCMAF.fragmentTiming(XCTUnwrap(moof).payload, track: video).decodeTime, 100_019_000_000)
    let initialMap = await origin.media("/init/0/0.mp4")
    let currentMap = await origin.media("/init/0/1.mp4")
    XCTAssertNotNil(initialMap)
    XCTAssertNotNil(currentMap)
    let compatibleMapHistory = await origin.media("/segment/0/7.mp4")
    XCTAssertNotNil(compatibleMapHistory, "An unchanged codec behind a rotated map must retain rewind")
    let active = try await origin.updateControlledPlayback(buffer: 1.5, budget: .init())
    XCTAssertTrue(active)
  }
}

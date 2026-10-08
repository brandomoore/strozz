import AVKit
import XCTest
@testable import Strozz

@MainActor
final class NativeSourceDecodingLiveTests: XCTestCase {
  func testOptInSequentialStandardAndNativeDecoding() async throws {
    #if targetEnvironment(simulator)
    let environment = ProcessInfo.processInfo.environment
    guard environment["STROZZ_DECODE_COMPARISON"] == "1",
      let channel = environment["STROZZ_DECODE_CHANNEL"] else {
      throw XCTSkip("Enable STROZZ_DECODE_COMPARISON and select STROZZ_DECODE_CHANNEL.")
    }
    let playback = try await PlaybackService.resolve(for: channel)
    let requestedQuality = environment["STROZZ_DECODE_QUALITY"] ?? "Auto"
    let quality = requestedQuality == "Source"
      ? try XCTUnwrap(playback.qualities.filter { !$0.isAudioOnly }.max { $0.bitrate < $1.bitrate }).name
      : requestedQuality
    guard quality == "Auto" || playback.qualities.contains(where: { $0.name == quality && !$0.isAudioOnly }) else {
      return XCTFail("Requested comparison quality is unavailable")
    }
    for native in [false, true] {
      try await check(playback.url(forQuality: quality), channel: channel, native: native, audible: false)
    }
    #else
    throw XCTSkip("Never take over a physical device for the source comparison.")
    #endif
  }

  func testOptInPhysicalStandardAndNativeDecoding() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Physical verification requires its own explicit opt-in.")
    #else
    let environment = ProcessInfo.processInfo.environment
    guard environment["STROZZ_PHYSICAL_DECODE_COMPARISON"] == "1",
      let channel = environment["STROZZ_DECODE_CHANNEL"],
      let quality = environment["STROZZ_DECODE_QUALITY"] else {
      throw XCTSkip("Explicitly select STROZZ_PHYSICAL_DECODE_COMPARISON, channel, and quality.")
    }
    let playback = try await PlaybackService.resolve(for: channel)
    guard quality == "Auto" || playback.qualities.contains(where: { $0.name == quality && !$0.isAudioOnly }) else {
      return XCTFail("The explicitly selected physical comparison quality is unavailable")
    }
    for native in [false, true] {
      try await check(playback.url(forQuality: quality), channel: channel, native: native,
        audible: environment["STROZZ_PHYSICAL_TEST_AUDIO"] == "audible")
    }
    #endif
  }

  func testOptInAdaptiveRenditionTransitions() async throws {
    #if targetEnvironment(simulator)
    let environment = ProcessInfo.processInfo.environment
    guard environment["STROZZ_ADAPTIVE_SWITCH_COMPARISON"] == "1",
      let channel = environment["STROZZ_DECODE_CHANNEL"] else {
      throw XCTSkip("Enable STROZZ_ADAPTIVE_SWITCH_COMPARISON and select STROZZ_DECODE_CHANNEL.")
    }
    let playback = try await PlaybackService.resolve(for: channel)
    XCTAssertGreaterThan(playback.qualities.filter { !$0.isAudioOnly }.count, 1)
    let engines = environment["STROZZ_ADAPTIVE_SWITCH_NATIVE_ONLY"] == "1" ? [true] : [false, true]
    for native in engines {
      try await check(playback.master, channel: channel, native: native, audible: false, adaptive: true)
    }
    #else
    throw XCTSkip("Adaptive stress checks must not interrupt physical TV playback.")
    #endif
  }

  func testOptInGridToExpandedAutoStaysAtSustainableQuality() async throws {
    #if targetEnvironment(simulator)
    let environment = ProcessInfo.processInfo.environment
    guard environment["STROZZ_AUTO_EXPANSION_COMPARISON"] == "1",
      let channel = environment["STROZZ_DECODE_CHANNEL"] else {
      throw XCTSkip("Enable STROZZ_AUTO_EXPANSION_COMPARISON and select STROZZ_DECODE_CHANNEL.")
    }
    let playback = try await PlaybackService.resolve(for: channel)
    try await check(playback.master, channel: channel, native: true, audible: false, expansion: true)
    #else
    throw XCTSkip("Auto budget experiments must not interrupt physical TV playback.")
    #endif
  }

  private func check(_ url: URL, channel: String, native: Bool, audible: Bool,
                     adaptive: Bool = false, expansion: Bool = false) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let engine = native ? NativeLowLatencyHLS(sourceURL: url, headers: PlaybackService.streamHeaders,
      history: 1800) { error in XCTFail("Native comparison failed: \(error.rawValue)") } : nil
    let asset = AVURLAsset(url: engine?.assetURL ?? url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders])
    if let engine { asset.resourceLoader.setDelegate(engine, queue: engine.queue) }
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 3
    item.automaticallyPreservesTimeOffsetFromLive = native
    if expansion {
      item.preferredPeakBitRate = 3_000_000
      item.preferredMaximumResolution = CGSize(width: 1280, height: 720)
    }
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = !audible
    try PlaybackAudioSession.activate()
    let controller = AVPlayerViewController()
    controller.player = player
    window.rootViewController = controller
    let metrics = NativePlaybackMetricCapture()
    metrics.attach(item)
    defer {
      metrics.stop()
      player.pause()
      player.replaceCurrentItem(with: nil)
      controller.player = nil
      engine?.stop()
      window.rootViewController = previous
    }
    var samples: [[String: String]] = []
    var aligned = false
    var fresh = 0
    var heights = Set<Int>()
    var missingFrames = 0
    var referenceSourceAge: Double?
    var maximumSourceAgeChange = 0.0
    var settledQualityChanges = 0
    var previousHeight = 0
    let sampleCount = expansion ? 240 : (adaptive ? 180 : 60)
    if adaptive || expansion { await engine?.origin.enableRequestDiagnostics() }
    player.play()
    for second in 0..<sampleCount {
      try await Task.sleep(for: .seconds(1))
      if expansion, second == 30 {
        item.preferredPeakBitRate = 0
        item.preferredMaximumResolution = .zero
      }
      if adaptive, second == 45 || second == 90 || second == 135 {
        let low = second != 90
        item.preferredPeakBitRate = low ? 800_000 : 0
        item.preferredMaximumResolution = low ? CGSize(width: 640, height: 360) : .zero
      }
      if !aligned, let engine, player.timeControlStatus == .playing,
        await engine.origin.liveTargetDate() != nil {
        aligned = true
        let offset = item.recommendedTimeOffsetFromLive
        if offset.seconds.isFinite, offset.seconds >= 0 { item.configuredTimeOffsetFromLive = offset }
        item.automaticallyPreservesTimeOffsetFromLive = false
        let timeout = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          item.cancelPendingSeeks()
        }
        let positioned = await item.seek(to: .positiveInfinity, toleranceBefore: .zero, toleranceAfter: .zero)
        timeout.cancel()
        XCTAssertTrue(positioned, "\(channel): bounded native startup alignment")
      }
      let clock = item.currentTime()
      let hasFrame = output.hasNewPixelBuffer(forItemTime: clock)
        && output.copyPixelBuffer(forItemTime: clock, itemTimeForDisplay: nil) != nil
      missingFrames = hasFrame ? 0 : missingFrames + 1
      if adaptive || expansion, second == 30 || (second >= 15 && missingFrames == 3) {
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
          controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "\(channel) \(native ? "native" : "standard") rendered second \(second)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
      }
      if adaptive || expansion, second >= 15, missingFrames == 3, let engine {
        add(try await NativePlaybackMetricCapture.originAttachment(engine.origin,
          name: "Adaptive missing frames \(channel) second \(second)"))
        let timeline = await engine.origin.timelineDiagnostics()
        let data = try JSONSerialization.data(withJSONObject: timeline, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Adaptive timeline \(channel) second \(second)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      if second >= 15, hasFrame, controller.isReadyForDisplay { fresh += 1 }
      if second >= 15, item.presentationSize.height > 0 {
        heights.insert(Int(item.presentationSize.height))
      }
      let height = Int(item.presentationSize.height)
      if expansion, second >= 60, previousHeight > 0, height > 0, previousHeight != height {
        settledQualityChanges += 1
      }
      previousHeight = height
      let buffer = item.loadedTimeRanges.map(\.timeRangeValue)
        .filter { $0.start.seconds <= clock.seconds && $0.end.seconds >= clock.seconds }
        .map { $0.end.seconds - clock.seconds }.max() ?? 0
      if let date = item.currentDate() {
        let age = Date().timeIntervalSince(date)
        if second == 30 { referenceSourceAge = age }
        if second >= 45, let referenceSourceAge {
          maximumSourceAgeChange = max(maximumSourceAgeChange, abs(age - referenceSourceAge))
        }
      }
      samples.append(["seconds": String(second), "clock": String(clock.seconds),
        "date": Date().ISO8601Format(),
        "playback_date": item.currentDate()?.ISO8601Format() ?? "unknown",
        "loaded_ranges": item.loadedTimeRanges.map(\.timeRangeValue)
          .map { "\($0.start.seconds)...\($0.end.seconds)" }.joined(separator: ","),
        "fresh": String(hasFrame), "ready": String(controller.isReadyForDisplay),
        "buffer": String(buffer), "peak_bitrate": String(item.preferredPeakBitRate),
        "dropped_frames": String(item.accessLog()?.events.reduce(0) { $0 + $1.numberOfDroppedVideoFrames } ?? 0),
        "error_count": String(item.errorLog()?.events.count ?? 0),
        "height": String(Double(item.presentationSize.height)), "state": String(player.timeControlStatus.rawValue)])
    }
    let name = "\(channel) \(native ? "native" : "standard")"
    if adaptive || expansion, let engine {
      add(try await NativePlaybackMetricCapture.originAttachment(engine.origin, name: "Adaptive requests \(name)"))
    }
    add(try metrics.attachment(name: "Decode requests \(name)"))
    let data = try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "Decode samples \(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertNil(item.error, name)
    XCTAssertGreaterThanOrEqual(fresh, adaptive || expansion ? Int(ceil(Double(sampleCount - 15) * 0.98)) : 44,
      "\(name): verified video after startup, including rendition transitions")
    if adaptive {
      XCTAssertGreaterThanOrEqual(heights.count, 2, "\(name): preferences must cause actual rendition changes")
      XCTAssertEqual(item.errorLog()?.events.count ?? 0, 0, "\(name): adaptive media errors")
      XCTAssertNotNil(referenceSourceAge, "\(name): a verified source-clock reference is required")
      XCTAssertLessThanOrEqual(maximumSourceAgeChange, 5,
        "\(name): a rendition switch must not rebase the playback date or build up latency")
    }
    if expansion {
      XCTAssertLessThanOrEqual(settledQualityChanges, 2, "\(name): Auto must not oscillate after budget release")
      XCTAssertGreaterThanOrEqual(Int(item.presentationSize.height), 720, "\(name): quality must not collapse")
    }
  }
}

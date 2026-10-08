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

  private func check(_ url: URL, channel: String, native: Bool, audible: Bool) async throws {
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
    player.play()
    for second in 0..<60 {
      try await Task.sleep(for: .seconds(1))
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
      if second >= 15, hasFrame, controller.isReadyForDisplay { fresh += 1 }
      samples.append(["seconds": String(second), "clock": String(clock.seconds),
        "fresh": String(hasFrame), "ready": String(controller.isReadyForDisplay),
        "height": String(Double(item.presentationSize.height)), "state": String(player.timeControlStatus.rawValue)])
    }
    let name = "\(channel) \(native ? "native" : "standard")"
    add(try metrics.attachment(name: "Decode requests \(name)"))
    let data = try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "Decode samples \(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertNil(item.error, name)
    XCTAssertGreaterThanOrEqual(fresh, 44, "\(name): verified video in the final 45 seconds")
  }
}

import AVFoundation
import XCTest
import SwiftUI
@testable import Strozz

@MainActor
final class NativeTwitchDeviceTests: XCTestCase {
  /// Explicit physical-device integration check, not part of offline simulator validation.
  func testPhysicalTwitchContainers() async throws {
    try await checkPhysicalPlayback(seconds: 65)
  }

  func testPhysicalSustainedTransportStream() async throws {
    try await checkAppPlayback(channel: "zackrawrr")
  }

  func testPhysicalSustainedCMAF() async throws {
    try await checkAppPlayback(channel: "shroud")
  }

  private func checkAppPlayback(channel: String) async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Physical app playback check")
    #else
    let environment = AppEnvironment()
    let model = PlayerModel()
    let name = "NativePlaybackTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    defer { defaults.removePersistentDomain(forName: name) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let playerView = PlayerView(channel: channel, auth: environment.auth, model: model)
      .environment(environment)
      .defaultAppStorage(defaults)
    let host = UIHostingController(rootView: playerView)
    window.rootViewController = host
    defer {
      window.rootViewController = previous
      model.player.pause()
      model.nativeHLS?.stop()
    }
    var progressing = 0
    var previousTime = 0.0
    var samples: [String] = []
    var sourceAges: [Double] = []
    for second in 0..<360 {
      try await Task.sleep(for: .seconds(1))
      guard second >= 20 else { continue }
      let time = model.player.currentTime().seconds
      if time > previousTime + 0.05 { progressing += 1 }
      previousTime = time
      let age = model.player.currentItem?.currentDate().map { Date().timeIntervalSince($0) }
      if let age { sourceAges.append(age) }
      if second % 10 == 0 {
        samples.append("\(second) native=\(model.isUsingNativeHLS) age=\(age ?? -1) clock=\(time) fallback=\(model.nativeFallbackReason ?? "none")")
      }
      if model.nativeFallbackReason != nil || model.errorMessage != nil || model.isOffline { break }
    }
    let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
    attachment.name = "Full app sustained \(channel)"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertNil(model.nativeFallbackReason)
    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.isOffline)
    XCTAssertTrue(model.isUsingNativeHLS)
    XCTAssertGreaterThanOrEqual(progressing, 320)
    let sorted = sourceAges.sorted()
    XCTAssertFalse(sorted.isEmpty)
    if !sorted.isEmpty { XCTAssertLessThan(sorted[sorted.count / 2], 10) }
    #endif
  }

  private func checkPhysicalPlayback(seconds: Int, channels: [String] = ["caedrel", "shroud"]) async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Run explicitly on the physical Apple TV to validate native decoding.")
    #else
    for channel in channels {
      let resolved = try await PlaybackService.resolve(for: channel)
      let engine = NativeLowLatencyHLS(sourceURL: resolved.master,
        headers: PlaybackService.streamHeaders, history: 1800) { error in
          XCTFail("Native engine failure: \(error.rawValue)")
        }
      let asset = AVURLAsset(url: engine.assetURL,
        options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders])
      asset.resourceLoader.setDelegate(engine, queue: engine.queue)
      let item = AVPlayerItem(asset: asset)
      item.preferredForwardBufferDuration = 1
      item.automaticallyPreservesTimeOffsetFromLive = true
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
      item.add(output)
      let player = AVPlayer(playerItem: item)
      player.isMuted = true
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previousWindow = scene.keyWindow
      let window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      window.rootViewController = controller
      window.windowLevel = .alert
      window.makeKeyAndVisible()
      let layer = AVPlayerLayer(player: player)
      layer.frame = window.bounds
      controller.view.layer.addSublayer(layer)
      defer {
        player.pause()
        player.replaceCurrentItem(with: nil)
        engine.stop()
        layer.player = nil
        layer.removeFromSuperlayer()
        window.isHidden = true
        previousWindow?.makeKey()
      }
      player.play()
      var freshFrames = 0
      var ageSamples: [Double] = []
      var offsets: [Double] = []
      var startupAligned = false
      var edgeSamples: [Double] = []
      var timeline: [String] = []
      var previousHeight: CGFloat = 0
      for sample in 0..<seconds {
        try await Task.sleep(for: .seconds(1))
        if previousHeight > 0, item.presentationSize.height > 0, previousHeight != item.presentationSize.height {
          startupAligned = false
        }
        if item.presentationSize.height > 0 { previousHeight = item.presentationSize.height }
        if !startupAligned, player.timeControlStatus == .playing, let target = await engine.origin.liveTargetDate() {
          startupAligned = true
          _ = await item.seek(to: target)
        }
        if sample == 25 { item.preferredPeakBitRate = 2_200_000 }
        if sample == 45 { item.preferredPeakBitRate = 0 }
        if sample < 15 { continue }
        if output.hasNewPixelBuffer(forItemTime: item.currentTime()),
          output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil {
          freshFrames += 1
        }
        if let date = item.currentDate() { ageSamples.append(Date().timeIntervalSince(date)) }
        if let edgeAge = await engine.origin.snapshot().edgeAge { edgeSamples.append(edgeAge) }
        if sample % 5 == 0 {
          timeline.append("\(sample) age=\(ageSamples.last ?? -1) edge=\(edgeSamples.last ?? -1) height=\(item.presentationSize.height) clock=\(item.currentTime().seconds)")
        }
        if item.configuredTimeOffsetFromLive.seconds.isFinite {
          offsets.append(item.configuredTimeOffsetFromLive.seconds)
        }
        XCTAssertNil(item.error)
      }
      let sorted = ageSamples.sorted()
      let medianAge = sorted.isEmpty ? Double.infinity : sorted[sorted.count / 2]
      let parts = await engine.origin.snapshot().parts
      let measuredSamples = seconds - 15
      print("PHYSICAL_NATIVE \(channel) fresh=\(freshFrames)/\(measuredSamples) age=\(medianAge) parts=\(parts) offsets=\(Set(offsets))")
      let errors = item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? []
      let result = XCTAttachment(string: "\(channel): fresh=\(freshFrames)/\(measuredSamples) age=\(medianAge) parts=\(parts) offsets=\(Set(offsets)) status=\(player.timeControlStatus.rawValue) height=\(item.presentationSize.height) clock=\(item.currentTime().seconds) errors=\(errors)\n\(timeline.joined(separator: "\n"))")
      result.name = "Physical native playback \(channel)"
      result.lifetime = .keepAlways
      add(result)
      XCTAssertGreaterThanOrEqual(freshFrames, Int(Double(measuredSamples) * 0.94))
      XCTAssertLessThan(medianAge, 10, "Source-clock estimate must not reproduce the 21s regression")
      XCTAssertGreaterThan(parts, 50)
      XCTAssertTrue(offsets.contains { abs($0 - 1.5) < 0.01 })
    }
    #endif
  }
}

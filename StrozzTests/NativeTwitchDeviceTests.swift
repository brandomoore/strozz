import AVFoundation
import XCTest
@testable import Strozz

@MainActor
final class NativeTwitchDeviceTests: XCTestCase {
  /// Explicit physical-device integration check, not part of offline simulator validation.
  func testPhysicalTwitchContainers() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Run explicitly on the physical Apple TV to validate native decoding.")
    #else
    for channel in ["caedrel", "shroud"] {
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
      for sample in 0..<65 {
        try await Task.sleep(for: .seconds(1))
        if !startupAligned, player.timeControlStatus == .playing {
          startupAligned = true
          await player.seek(to: .positiveInfinity)
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
      print("PHYSICAL_NATIVE \(channel) fresh=\(freshFrames)/50 age=\(medianAge) parts=\(parts) offsets=\(Set(offsets))")
      let errors = item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? []
      let result = XCTAttachment(string: "\(channel): fresh=\(freshFrames)/50 age=\(medianAge) parts=\(parts) offsets=\(Set(offsets)) status=\(player.timeControlStatus.rawValue) height=\(item.presentationSize.height) clock=\(item.currentTime().seconds) errors=\(errors)\n\(timeline.joined(separator: "\n"))")
      result.name = "Physical native playback \(channel)"
      result.lifetime = .keepAlways
      add(result)
      XCTAssertGreaterThanOrEqual(freshFrames, 47)
      XCTAssertLessThan(medianAge, 10, "Source-clock estimate must not reproduce the 21s regression")
      XCTAssertGreaterThan(parts, 50)
      XCTAssertTrue(offsets.contains { abs($0 - 1.5) < 0.01 })
    }
    #endif
  }
}

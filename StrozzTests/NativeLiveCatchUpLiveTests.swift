import AVFoundation
import AVKit
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class NativeLiveCatchUpLiveTests: XCTestCase {
  func testOptInSimulatorLiveStartupAndQualityChanges() async throws {
    try await runLiveScenario(probeRecovery: false)
  }

  func testOptInSimulatorNativeFailureRecovery() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_NATIVE_RECOVERY_PROBE"] == "1" else {
      throw XCTSkip("Set STROZZ_NATIVE_RECOVERY_PROBE=1 to inject a native failure.")
    }
    try await runLiveScenario(probeRecovery: true)
  }

  func testOptInSimulatorBufferedDriftUsesRateWithoutReload() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_NATIVE_RATE_PROBE"] == "1" else {
      throw XCTSkip("Set STROZZ_NATIVE_RATE_PROBE=1 to create a bounded live drift.")
    }
    try await runLiveScenario(probeRecovery: false, probeDrift: true)
  }

  func testOptInSimulatorWholeSegmentsAndPinnedNativeQuality() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_NATIVE_QUALITY_PROBE"] == "1" else {
      throw XCTSkip("Set STROZZ_NATIVE_QUALITY_PROBE=1 with a whole-segment live channel.")
    }
    try await runLiveScenario(probeRecovery: false, probeQuality: true)
  }

  func testOptInSustainedAutoQualityWithoutControllerIntervention() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_NATIVE_STEADY_QUALITY_PROBE"] == "1" else {
      throw XCTSkip("Set STROZZ_NATIVE_STEADY_QUALITY_PROBE=1 for a twelve-minute Auto quality check.")
    }
    try await runLiveScenario(probeRecovery: false, probeSteadyQuality: true)
  }

  private func runLiveScenario(probeRecovery: Bool, probeDrift: Bool = false,
                               probeQuality: Bool = false, probeSteadyQuality: Bool = false) async throws {
    #if !targetEnvironment(simulator)
    guard probeSteadyQuality,
      ProcessInfo.processInfo.environment["STROZZ_NATIVE_PHYSICAL_QUALITY_PROBE"] == "1" else {
      throw XCTSkip("Physical playback requires explicit STROZZ_NATIVE_PHYSICAL_QUALITY_PROBE=1.")
    }
    #endif
    guard var channel = ProcessInfo.processInfo.environment["STROZZ_CATCH_UP_LIVE_CHANNEL"],
      !channel.isEmpty, channel.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    else { throw XCTSkip("Set STROZZ_CATCH_UP_LIVE_CHANNEL for a bounded live simulator check.") }
    #if !targetEnvironment(simulator)
    if await PlaybackService.streamLiveStatus(for: channel) == .offline,
      let fallback = ProcessInfo.processInfo.environment["STROZZ_PHYSICAL_FALLBACK_CHANNEL"],
      !fallback.isEmpty, fallback.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
      channel = fallback
    }
    #endif
    let environment = AppEnvironment()
    let model = PlayerModel()
    model.player.isMuted = true
    #if !targetEnvironment(simulator)
    model.player.isMuted = ProcessInfo.processInfo.environment["STROZZ_PHYSICAL_TEST_AUDIO"] != "1"
    #endif
    var engineBeforeRetry: NativeLowLatencyHLS?
    let suite = "NativeCatchUpLive.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    defer { defaults.removePersistentDomain(forName: suite) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousWindow = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
    let view = PlayerView(channel: channel, auth: environment.auth, model: model)
    window.rootViewController = UIHostingController(rootView:
      view.environment(environment).defaultAppStorage(defaults))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousWindow?.makeKey()
      view.stopLatencyMonitor()
      view.stopPlaybackWatchdog()
      model.nativeHLS?.stop()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
    }
    var previousClock = 0.0
    var advancing = 0
    var freshFrames = 0
    var maximumRate: Float = 1
    var itemBeforeDrift: AVPlayerItem?
    var initialDrift: Double?
    var remainingDrift: Double?
    var previousCorrectionRate: Float = 1
    var correctionTransitions = 0
    var ages: [Double] = []
    var observations: [String] = []
    var recoveryStartedAt: TimeInterval?
    var recoveryFinishedAt: TimeInterval?
    var steadySamples = 0
    var steadyFreshFrames = 0
    var qualitySamples: [[Bool]] = [[], [], []]
    var qualityFrameItem: AVPlayerItem?
    var qualityFrameOutput: AVPlayerItemVideoOutput?
    var steadyQualitySamples = 0
    var bestQualitySamples = 0
    var severeQualitySamples = 0
    let durationSeconds = probeSteadyQuality ? 720 : (probeDrift || probeQuality ? 240 : 180)
    for second in 0..<durationSeconds {
      try await Task.sleep(for: .seconds(1))
      if probeSteadyQuality && second == 5 {
        func surfaces(_ controller: UIViewController) -> String {
          let ready = (controller as? AVPlayerViewController).map { " ready=\($0.isReadyForDisplay)" } ?? ""
          return "\(type(of: controller)) bounds=\(controller.view.bounds) window=\(controller.view.window != nil)\(ready)\n"
            + controller.children.map(surfaces).joined()
        }
        if let controller = window.rootViewController {
          observations.append("Surface: key=\(window.isKeyWindow) hidden=\(window.isHidden)\n\(surfaces(controller))")
          let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
          }
          let attachment = XCTAttachment(image: image)
          attachment.name = "Sustained quality player surface"
          attachment.lifetime = .keepAlways
          add(attachment)
        }
      }
      if !probeRecovery && !probeDrift && !probeQuality && !probeSteadyQuality && second == 45 {
        model.player.currentItem?.preferredPeakBitRate = 1_500_000
      }
      if !probeRecovery && !probeDrift && !probeQuality && !probeSteadyQuality && second == 90 {
        model.player.currentItem?.preferredPeakBitRate = 0
      }
      if probeSteadyQuality && second >= 20 {
        let best = try XCTUnwrap(model.playback?.qualities.filter { !$0.isAudioOnly }.max { $0.bitrate < $1.bitrate })
        let height = try XCTUnwrap(PlayerView.verticalResolution(from: best.name))
        let renderedHeight = model.player.currentItem?.presentationSize.height ?? 0
        steadyQualitySamples += 1
        if renderedHeight >= CGFloat(height) { bestQualitySamples += 1 }
        if renderedHeight < CGFloat(min(height, 480)) { severeQualitySamples += 1 }
      }
      if probeQuality && second >= 20 {
        let best = try XCTUnwrap(model.playback?.qualities.filter { !$0.isAudioOnly }.max { $0.bitrate < $1.bitrate })
        if second == 60 {
          let index = try XCTUnwrap(view.qualityOptions.firstIndex(of: best.name))
          view.selectQuality(at: index)
          XCTAssertTrue(model.isUsingNativeHLS, "Pinning a video must not switch engines")
          XCTAssertEqual(model.nativeHLS?.sourceURL, best.url)
        }
        if second == 120 {
          let index = try XCTUnwrap(view.qualityOptions.firstIndex(of: LivePlaybackProfile.nativeLowLatency.pickerLabel))
          view.selectQuality(at: index)
          XCTAssertTrue(model.isUsingNativeHLS)
        }
        if second == 20 {
          let stats = await model.nativeHLS?.origin.snapshot()
          XCTAssertEqual(stats?.hasPrefetch, false, "This probe must exercise whole-segment delivery")
          XCTAssertLessThan(try XCTUnwrap(stats?.holdBack), 10)
          func surfaces(_ controller: UIViewController) -> String {
            "\(type(of: controller)) bounds=\(controller.view.bounds) window=\(controller.view.window != nil)\n"
              + controller.children.map(surfaces).joined()
          }
          if let controller = window.rootViewController {
            observations.append("Surface: window=\(window.bounds)\n\(surfaces(controller))")
          }
        }
        if (20..<60).contains(second) || (75..<120).contains(second) || second >= 135 {
          let height = try XCTUnwrap(PlayerView.verticalResolution(from: best.name))
          let window = second < 60 ? 0 : (second < 120 ? 1 : 2)
          qualitySamples[window].append((model.player.currentItem?.presentationSize.height ?? 0) >= CGFloat(height))
          XCTAssertTrue(model.isUsingNativeHLS)
        }
      }
      if probeDrift && second == 40 {
        itemBeforeDrift = model.player.currentItem
        model.player.pause()
      }
      if probeDrift && second == 45 {
        if let target = await model.nativeHLS?.origin.liveTargetDate(),
           let date = model.player.currentItem?.currentDate() {
          initialDrift = target.timeIntervalSince(date) - (model.chatSyncBaseline.nativeCushion ?? 0)
        }
        model.player.play()
      }
      if probeDrift && second > 45,
         let target = await model.nativeHLS?.origin.liveTargetDate(),
         let date = model.player.currentItem?.currentDate() {
        remainingDrift = target.timeIntervalSince(date) - (model.chatSyncBaseline.nativeCushion ?? 0)
        let correctionRate = model.nativeCatchUpAppliedRate
        if abs(correctionRate - previousCorrectionRate) > 0.001 { correctionTransitions += 1 }
        previousCorrectionRate = correctionRate
      }
      if probeRecovery && second == 60 {
        engineBeforeRetry = model.nativeHLS
        recoveryStartedAt = ProcessInfo.processInfo.systemUptime
        view.recoverNativeHLS(.unavailable)
      }
      maximumRate = max(maximumRate, model.player.rate)
      let clock = model.player.currentTime().seconds
      let freshFrame: Bool
      if probeQuality, let item = model.player.currentItem {
        if item !== qualityFrameItem {
          if let qualityFrameItem, let qualityFrameOutput { qualityFrameItem.remove(qualityFrameOutput) }
          let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
          item.add(output)
          qualityFrameItem = item
          qualityFrameOutput = output
        }
        freshFrame = qualityFrameOutput?.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil
      } else {
        freshFrame = model.playbackTelemetry.videoFrameAge.map { $0 < 4 } ?? false
      }
      if probeDrift && second == 15 {
        XCTAssertTrue(model.nativeStartupComplete)
        let targetDate = await model.nativeHLS?.origin.liveTargetDate()
        let target = try XCTUnwrap(targetDate)
        let displayed = try XCTUnwrap(model.player.currentItem?.currentDate())
        XCTAssertLessThanOrEqual(target.timeIntervalSince(displayed), NativeLiveCatchUp.startupToleranceSeconds,
                                 "Initial playback must start near live without manual correction")
      }
      if probeRecovery, recoveryStartedAt != nil, recoveryFinishedAt == nil,
         model.nativeHLS !== engineBeforeRetry, model.isUsingNativeHLS, freshFrame,
         clock > previousClock + 0.05,
         let target = await model.nativeHLS?.origin.liveTargetDate(),
         let displayed = model.player.currentItem?.currentDate(),
         target.timeIntervalSince(displayed) < NativeLiveCatchUp.minimumExcessSeconds {
        recoveryFinishedAt = ProcessInfo.processInfo.systemUptime
      }
      if second >= 15 {
        if clock > previousClock + 0.05 { advancing += 1 }
        if freshFrame { freshFrames += 1 }
        if recoveryStartedAt == nil || recoveryFinishedAt != nil {
          steadySamples += 1
          if freshFrame { steadyFreshFrames += 1 }
        }
        if let date = model.player.currentItem?.currentDate() { ages.append(Date().timeIntervalSince(date)) }
      }
      previousClock = clock
      if second.isMultiple(of: 5) {
        let reportSeconds = await model.nativeHLS?.origin.snapshot().reportRefreshSeconds
        observations.append("\(second) native=\(model.isUsingNativeHLS) clock=\(clock) frameAge=\(model.playbackTelemetry.videoFrameAge ?? -1) age=\(ages.last ?? -1) rate=\(model.player.rate) extra=\(model.nativeCatchUp.extraDelay ?? -1) quality=\(model.resolvedQualityName ?? "-") reportSeconds=\(reportSeconds ?? -1)")
      }
      if model.errorMessage != nil || model.isOffline || model.nativeFallbackReason != nil { break }
    }
    let evidence = XCTAttachment(string: observations.joined(separator: "\n"))
    evidence.name = "Simulator native catch-up \(channel)"
    evidence.lifetime = .keepAlways
    add(evidence)
    XCTAssertNil(model.errorMessage)
    XCTAssertNil(model.nativeFallbackReason)
    XCTAssertFalse(model.isOffline)
    XCTAssertTrue(model.isUsingNativeHLS)
    if probeSteadyQuality {
      XCTAssertEqual(view.preferredQuality, "Auto")
      XCTAssertEqual(severeQualitySamples, 0, "Healthy Auto playback must not collapse to 160p/360p")
      XCTAssertEqual(steadyQualitySamples, durationSeconds - 20)
      XCTAssertGreaterThanOrEqual(bestQualitySamples, Int(ceil(Double(steadyQualitySamples) * 0.99)))
      XCTAssertTrue(model.nativeRecovery.attempts.isEmpty)
      XCTAssertEqual(model.player.currentItem?.accessLog()?.events.reduce(0) { $0 + $1.numberOfStalls }, 0)
    }
    if probeQuality {
      for (index, samples) in qualitySamples.enumerated() {
        XCTAssertFalse(samples.isEmpty)
        XCTAssertGreaterThanOrEqual(samples.filter { $0 }.count, Int(ceil(Double(samples.count) * 0.95)),
          "Auto / pinned / Auto window \(index) must sustain the best available video, not stay at 360p")
      }
      XCTAssertTrue(model.nativeRecovery.attempts.isEmpty)
    }
    if probeRecovery {
      XCTAssertNotNil(engineBeforeRetry)
      XCTAssertFalse(model.nativeHLS === engineBeforeRetry)
      XCTAssertGreaterThanOrEqual(model.nativeRecovery.attempts.count, 1)
      let began = try XCTUnwrap(recoveryStartedAt)
      let finished = try XCTUnwrap(recoveryFinishedAt, "Retry must restore fresh native video near live")
      XCTAssertLessThanOrEqual(finished - began, view.startupPlaybackTimeoutSeconds)
      XCTAssertGreaterThanOrEqual(steadySamples, 150)
      XCTAssertGreaterThanOrEqual(steadyFreshFrames, Int(ceil(Double(steadySamples) * 0.95)))
      let recoveryEvidence = XCTAttachment(string:
        "reconnect_seconds=\(finished - began) steady_frames=\(steadyFreshFrames)/\(steadySamples)")
      recoveryEvidence.lifetime = .keepAlways
      add(recoveryEvidence)
    } else {
      XCTAssertGreaterThanOrEqual(freshFrames, durationSeconds - 23, "An advancing clock alone is not proof of decoded video")
    }
    XCTAssertGreaterThanOrEqual(advancing, durationSeconds - 23)
    XCTAssertLessThanOrEqual(maximumRate, NativeLiveCatchUp.maximumRate)
    if probeDrift {
      XCTAssertNotNil(itemBeforeDrift)
      XCTAssertTrue(model.player.currentItem === itemBeforeDrift, "Drift must not replace the player item")
      XCTAssertTrue(model.nativeRecovery.attempts.isEmpty, "Drift must not require native reloads")
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(initialDrift), NativeLiveCatchUp.minimumExcessSeconds)
      XCTAssertLessThanOrEqual(try XCTUnwrap(remainingDrift), NativeLiveCatchUp.settledExcessSeconds + 0.5,
                              "Catch-up must reach live, not merely reduce the delay")
      XCTAssertGreaterThan(maximumRate, 1, "Buffered drift should be corrected by rate")
      XCTAssertEqual(model.player.rate, 1, "Rate should return to normal after reaching live")
      XCTAssertEqual(correctionTransitions, 2, "One entry and one exit, not repeated speed changes")
    }
    let sortedAges = ages.sorted()
    XCTAssertFalse(sortedAges.isEmpty)
    if !sortedAges.isEmpty { XCTAssertLessThan(sortedAges[sortedAges.count / 2], 10) }
  }
}

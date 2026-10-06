import AVFoundation
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

  private func runLiveScenario(probeRecovery: Bool, probeDrift: Bool = false) async throws {
    #if targetEnvironment(simulator)
    guard let channel = ProcessInfo.processInfo.environment["STROZZ_CATCH_UP_LIVE_CHANNEL"],
      !channel.isEmpty, channel.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    else { throw XCTSkip("Set STROZZ_CATCH_UP_LIVE_CHANNEL for a bounded live simulator check.") }
    let environment = AppEnvironment()
    let model = PlayerModel()
    model.player.isMuted = true
    var engineBeforeRetry: NativeLowLatencyHLS?
    let suite = "NativeCatchUpLive.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    defer { defaults.removePersistentDomain(forName: suite) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let view = PlayerView(channel: channel, auth: environment.auth, model: model)
    window.rootViewController = UIHostingController(rootView:
      view.environment(environment).defaultAppStorage(defaults))
    defer {
      window.rootViewController = previous
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
    let durationSeconds = probeDrift ? 240 : 180
    for second in 0..<durationSeconds {
      try await Task.sleep(for: .seconds(1))
      if !probeRecovery && !probeDrift && second == 45 { model.player.currentItem?.preferredPeakBitRate = 1_500_000 }
      if !probeRecovery && !probeDrift && second == 90 { model.player.currentItem?.preferredPeakBitRate = 0 }
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
      let freshFrame = model.playbackTelemetry.videoFrameAge.map { $0 < 4 } ?? false
      if probeDrift && second == 15 {
        XCTAssertTrue(model.nativeStartupComplete)
        let targetDate = await model.nativeHLS?.origin.liveTargetDate()
        let target = try XCTUnwrap(targetDate)
        let displayed = try XCTUnwrap(model.player.currentItem?.currentDate())
        XCTAssertLessThanOrEqual(target.timeIntervalSince(displayed), NativeLiveCatchUp.minimumExcessSeconds,
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
        observations.append("\(second) native=\(model.isUsingNativeHLS) clock=\(clock) frameAge=\(model.playbackTelemetry.videoFrameAge ?? -1) age=\(ages.last ?? -1) rate=\(model.player.rate) extra=\(model.nativeCatchUp.extraDelay ?? -1) quality=\(model.resolvedQualityName ?? "-")")
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
    #else
    throw XCTSkip("This live smoke check only runs on an explicitly configured simulator.")
    #endif
  }
}

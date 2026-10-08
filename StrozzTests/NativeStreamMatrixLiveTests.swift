import AVKit
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class NativeStreamMatrixLiveTests: XCTestCase {
  private enum MatrixFailure: Error, Equatable {
    case offline, nativeFallback, playerError, playerReplaced, playbackTimedOut
  }

  func testReadinessReportsSourceFailures() async {
    for failure in [MatrixFailure.offline, .nativeFallback, .playerError] {
      let model = PlayerModel()
      model.isOffline = failure == .offline
      model.nativeFallbackReason = failure == .nativeFallback ? NativeHLSError.unsupported.rawValue : nil
      model.errorMessage = failure == .playerError ? "Synthetic playback failure" : nil
      do {
        try await ready(model, host: UIViewController())
        XCTFail("Expected \(failure)")
      } catch {
        XCTAssertEqual(error as? MatrixFailure, failure)
      }
    }
  }

  func testOptInDiverseStreamLifecycleMatrix() async throws {
    #if targetEnvironment(simulator)
    let configuration = ProcessInfo.processInfo.environment
    guard configuration["STROZZ_STREAM_MATRIX"] == "1",
      let names = configuration["STROZZ_MATRIX_CHANNELS"] else {
      throw XCTSkip("Enable STROZZ_STREAM_MATRIX and select STROZZ_MATRIX_CHANNELS for bounded, sequential live checks.")
    }
    let channels = names.split(separator: ",").map(String.init)
    let steadySeconds = Int(configuration["STROZZ_MATRIX_STEADY_SECONDS"] ?? "180")
    let resumedSeconds = Int(configuration["STROZZ_MATRIX_RESUMED_SECONDS"] ?? "45")
    guard let steadySeconds, (180...1800).contains(steadySeconds),
      let resumedSeconds, (45...900).contains(resumedSeconds) else {
      return XCTFail("Steady playback must be 180...1800 seconds and resumed playback 45...900 seconds")
    }
    guard !channels.isEmpty, channels.count <= 10,
      channels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } })
    else { return XCTFail("Provide one to ten Twitch channel logins") }
    for channel in channels {
      try Task.checkCancellation()
      if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
        return XCTFail("Host thermal pressure ended the matrix; remaining sources were not tested")
      }
      do {
        try await check(channel, steadySeconds: steadySeconds, resumedSeconds: resumedSeconds)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as MatrixFailure {
        XCTFail("\(channel) did not complete: \(error)")
      } catch {
        let error = error as NSError
        XCTFail("\(channel) did not complete: \(error.domain) \(error.code)")
      }
    }
    #else
    throw XCTSkip("The matrix must never take over a physical TV.")
    #endif
  }

  private func check(_ channel: String, steadySeconds: Int, resumedSeconds: Int) async throws {
    let run = try XCTUnwrap(testRun)
    let initialFailures = run.failureCount
    let environment = AppEnvironment()
    let model = PlayerModel()
    model.player.isMuted = true
    let suite = "StreamMatrix.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let view = PlayerView(channel: channel, auth: environment.auth, model: model)
    let host = UIHostingController(rootView: view.environment(environment).defaultAppStorage(defaults))
    var samples: [[String: String]] = []
    var phase = "startup"
    var outcome = "incomplete"
    let metrics = NativePlaybackMetricCapture()
    window.rootViewController = host
    defer {
      window.rootViewController = previous
      model.nativeRefreshTask?.cancel()
      model.fallbackRestoreTask?.cancel()
      model.channelMetadataTask?.cancel()
      view.cancelNativeStartup()
      view.stopLatencyMonitor()
      view.stopPlaybackWatchdog()
      model.nativeHLS?.stop()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
      defaults.removePersistentDomain(forName: suite)
      samples.append(["phase": phase, "outcome": outcome,
        "offline": String(model.isOffline),
        "native_fallback": model.nativeFallbackReason ?? "none",
        "player_error": String(model.errorMessage != nil)])
      do {
        add(try metrics.attachment(name: "Stream requests \(channel)"))
        let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Stream matrix \(channel)"
        attachment.lifetime = .keepAlways
        add(attachment)
      } catch { XCTFail("Could not record \(channel) matrix evidence") }
    }
    let began = Date()
    try await ready(model, host: host, metrics: metrics)
    samples.append(["phase": phase, "startup_seconds": String(Date().timeIntervalSince(began))])

    phase = "steady"
    try await observe(model, channel: channel, seconds: steadySeconds, phase: phase, samples: &samples)
    let beforeReturn = model.player
    let beforeSurface = try XCTUnwrap(videoController(in: host))
    phase = "background"
    model.beginPlaybackAbsence(.background, isVOD: false)
    model.backgroundedAt = Date()
    view.suspendNativePlayback()
    view.handleAudioInterruption(Notification(name: AVAudioSession.interruptionNotification, userInfo: [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
    ]))
    try await Task.sleep(for: .seconds(10))
    phase = "foreground"
    let resumed = Date()
    view.handleReturnToForeground()
    await model.nativeRefreshTask?.value
    try await ready(model, host: host, metrics: metrics)
    XCTAssertFalse(model.player === beforeReturn, channel)
    XCTAssertNil(beforeReturn.currentItem, channel)
    XCTAssertFalse(try XCTUnwrap(videoController(in: host)) === beforeSurface, channel)
    XCTAssertFalse(model.audioInterrupted, channel)
    samples.append(["phase": phase, "recovery_seconds": String(Date().timeIntervalSince(resumed))])
    try await observe(model, channel: channel, seconds: resumedSeconds, phase: phase, samples: &samples)

    phase = "paused_return"
    view.toggleRewindPlayPause()
    XCTAssertTrue(model.isUserPaused, channel)
    let paused = try XCTUnwrap(model.player.currentItem?.currentDate())
    model.backgroundedAt = Date()
    view.suspendNativePlayback()
    view.handleAudioInterruption(Notification(name: AVAudioSession.interruptionNotification, userInfo: [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
    ]))
    try await Task.sleep(for: .seconds(5))
    view.handleReturnToForeground()
    await model.nativeRefreshTask?.value
    XCTAssertNil(model.errorMessage, channel)
    XCTAssertTrue(model.isUserPaused, channel)
    XCTAssertEqual(model.player.rate, 0, channel)
    let actual = try XCTUnwrap(model.player.currentItem?.currentDate())
    XCTAssertEqual(actual.timeIntervalSince(paused), 0, accuracy: 1, channel)
    XCTAssertTrue(model.player.isMuted, "The matrix must remain silent")
    samples.append(["phase": phase, "position_error_seconds": String(actual.timeIntervalSince(paused)),
      "paused": String(model.isUserPaused), "muted": String(model.player.isMuted)])
    phase = "completed"
    outcome = run.failureCount == initialFailures ? "passed" : "failed"
  }

  private func ready(_ model: PlayerModel, host: UIViewController,
                     metrics: NativePlaybackMetricCapture? = nil) async throws {
    for _ in 0..<300 {
      try Task.checkCancellation()
      metrics?.attach(model.player.currentItem)
      await model.nativeHLS?.origin.enableRequestDiagnostics()
      if model.isOffline { throw MatrixFailure.offline }
      if model.nativeFallbackReason != nil { throw MatrixFailure.nativeFallback }
      if model.errorMessage != nil { throw MatrixFailure.playerError }
      if model.nativeStartupComplete, model.player.timeControlStatus == .playing,
        videoController(in: host)?.isReadyForDisplay == true,
        model.playbackTelemetry.videoFrameAge.map({ $0 < 3 }) == true { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MatrixFailure.playbackTimedOut
  }

  private func observe(_ model: PlayerModel, channel: String, seconds: Int, phase: String,
                       samples: inout [[String: String]]) async throws {
    let item = try XCTUnwrap(model.player.currentItem)
    let origin = model.nativeHLS?.origin
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(output)
    defer { item.remove(output) }
    var advancing = 0
    var frames = 0
    var waiting = 0
    var severeDownshift = 0
    var lastClock = item.currentTime().seconds
    var lastFrameTime = CMTime.invalid
    let highest = model.playback?.qualities.filter { !$0.isAudioOnly }.max { $0.bitrate < $1.bitrate }
    let bestHeight = highest.flatMap { PlayerView.verticalResolution(from: $0.name) } ?? 0
    for second in 0..<seconds {
      try await Task.sleep(for: .seconds(1))
      let clock = item.currentTime().seconds
      if clock.isFinite, clock > lastClock + 0.05 { advancing += 1 }
      lastClock = clock
      var frameTime = CMTime.invalid
      if output.hasNewPixelBuffer(forItemTime: item.currentTime()),
        output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: &frameTime) != nil,
        frameTime.isNumeric, !lastFrameTime.isNumeric || frameTime > lastFrameTime {
        frames += 1
        lastFrameTime = frameTime
      }
      if model.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
        waiting += 1
        if waiting == 1, let origin {
          add(try await NativePlaybackMetricCapture.originAttachment(origin, name: "\(channel) \(phase) first wait"))
        }
      }
      let height = item.presentationSize.height
      if second >= 15, bestHeight >= 720, height > 0, height < 480 { severeDownshift += 1 }
      if second.isMultiple(of: 5) {
        let source = await model.nativeHLS?.origin.snapshot()
        let buffer = item.loadedTimeRanges.map(\.timeRangeValue)
          .filter { $0.start.seconds <= clock && $0.end.seconds >= clock }
          .map { $0.end.seconds - clock }.max() ?? 0
        var sample: [String: String] = [
          "phase": phase, "seconds": String(second), "height": String(Double(height)),
          "rate": String(model.player.rate), "buffer": String(buffer),
          "fresh_frames": String(frames), "waiting_samples": String(waiting),
          "source_age": item.currentDate().map { String(Date().timeIntervalSince($0)) } ?? "unknown",
          "native": String(model.isUsingNativeHLS),
        ]
        if let prefetch = source?.hasPrefetch { sample["prefetch"] = String(prefetch) }
        if let holdBack = source?.holdBack { sample["hold_back"] = String(holdBack) }
        if let refresh = source?.reportRefreshSeconds { sample["report_refresh_seconds"] = String(refresh) }
        if let discontinuities = source?.inferredDiscontinuities {
          sample["inferred_discontinuities"] = String(discontinuities)
        }
        samples.append(sample)
      }
      let failure: MatrixFailure?
      if model.isOffline { failure = .offline }
      else if model.nativeFallbackReason != nil { failure = .nativeFallback }
      else if model.errorMessage != nil { failure = .playerError }
      else if item !== model.player.currentItem { failure = .playerReplaced }
      else { failure = nil }
      if let failure {
        if let origin {
          add(try await NativePlaybackMetricCapture.originAttachment(origin, name: "\(channel) \(phase) failure"))
        }
        throw failure
      }
    }
    if let origin {
      add(try await NativePlaybackMetricCapture.originAttachment(origin, name: "\(channel) \(phase) end"))
    }
    samples.append(["phase": phase, "samples": String(seconds), "advancing": String(advancing),
      "fresh_frames": String(frames), "waiting_samples": String(waiting),
      "severe_downshift_samples": String(severeDownshift)])
    XCTAssertGreaterThanOrEqual(advancing, Int(ceil(Double(seconds) * 0.98)), "\(channel) \(phase): clock progress")
    XCTAssertGreaterThanOrEqual(frames, Int(ceil(Double(seconds) * 0.98)), "\(channel) \(phase): decoded frame progress")
    XCTAssertLessThanOrEqual(waiting, 2, "\(channel) \(phase): buffering was visible")
    XCTAssertEqual(severeDownshift, 0, "\(channel) \(phase): 160p/360p quality collapse")
    XCTAssertTrue(model.nativeRecovery.attempts.isEmpty, "\(channel) \(phase): unexpected native restart")
  }

  private func videoController(in controller: UIViewController) -> AVPlayerViewController? {
    if let player = controller as? AVPlayerViewController { return player }
    return controller.children.lazy.compactMap { self.videoController(in: $0) }.first
  }
}

import AVFoundation
import Combine
import XCTest

@testable import Strozz

@MainActor
final class LivePlaybackStartupTests: XCTestCase {
  func testPresentationDoesNotRevealAnUnloadedPlayer() {
    let model = PlayerModel()
    XCTAssertFalse(model.revealPlaybackIfStarted())
    XCTAssertTrue(model.isLoading)
  }

  func testNativePlaybackRevealsImmediatelyWithoutWaitingForHealthSamples() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("startup-presentation-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeSilentAudio(to: url)
    let model = PlayerModel()
    model.player.isMuted = true
    model.player.automaticallyWaitsToMinimizeStalling = true
    let presented = expectation(description: "Native playback reveals the loading screen")
    var observation: AnyCancellable?
    var presentationCount = 0
    observation = model.player.publisher(for: \.timeControlStatus)
      .receive(on: RunLoop.main)
      .sink { _ in
        if model.revealPlaybackIfStarted() {
          presentationCount += 1
          XCTAssertFalse(model.startupProgress.hasStarted)
          XCTAssertFalse(model.startupProgress.allowsRateAdjustment(
            isPlaying: true, isLoading: model.isLoading, shouldPlay: true))
          presented.fulfill()
        }
      }
    defer {
      observation?.cancel()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
    }
    model.player.replaceCurrentItem(with: AVPlayerItem(url: url))
    XCTAssertFalse(model.revealPlaybackIfStarted())
    model.player.play()
    await fulfillment(of: [presented], timeout: 5)
    XCTAssertFalse(model.isLoading)
    XCTAssertEqual(presentationCount, 1)
    XCTAssertFalse(model.revealPlaybackIfStarted())
    XCTAssertTrue(model.player.automaticallyWaitsToMinimizeStalling)

    model.isLoading = true
    model.errorMessage = "Cannot play stream"
    XCTAssertFalse(model.revealPlaybackIfStarted())
    model.errorMessage = nil
    model.isOffline = true
    XCTAssertFalse(model.revealPlaybackIfStarted())
    model.isOffline = false
    model.player.pause()
    XCTAssertFalse(model.revealPlaybackIfStarted())
    model.player.replaceCurrentItem(with: nil)
    XCTAssertFalse(model.revealPlaybackIfStarted())
    XCTAssertTrue(model.isLoading)
  }

  private func writeSilentAudio(to url: URL) throws {
    let file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ])
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 88_200))
    buffer.frameLength = buffer.frameCapacity
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    samples.update(repeating: 0, count: Int(buffer.frameLength))
    try file.write(from: buffer)
  }

  func testNonzeroInitialHLSTimestampDoesNotMeanPlaybackStarted() {
    var progress = LivePlaybackStartup.Progress(now: 0)
    XCTAssertFalse(progress.observe(clock: 3597, isPlaying: false, now: 1))
    XCTAssertFalse(progress.observe(clock: 3597, isPlaying: true, now: 2))
    XCTAssertFalse(progress.observe(clock: 3597, isPlaying: true, now: 2.5))
    XCTAssertFalse(progress.hasStarted)
  }

  func testStartupRequiresSustainedAdvancingPlayback() {
    var progress = LivePlaybackStartup.Progress(now: 0)
    XCTAssertFalse(progress.observe(clock: 14, isPlaying: true, now: 1))
    XCTAssertFalse(progress.observe(clock: 14.25, isPlaying: true, now: 1.25))
    XCTAssertTrue(progress.observe(clock: 14.5, isPlaying: true, now: 1.5))
  }

  func testInitialSeekDoesNotCountAsClockProgress() {
    var progress = LivePlaybackStartup.Progress(now: 0)
    XCTAssertFalse(progress.observe(clock: 0, isPlaying: true, now: 1))
    XCTAssertFalse(progress.observe(clock: 3597, isPlaying: true, now: 1.5))
    XCTAssertFalse(progress.observe(clock: 3597.25, isPlaying: true, now: 1.75))
    XCTAssertTrue(progress.observe(clock: 3597.5, isPlaying: true, now: 2))
  }

  func testBufferingResetsStartupProgress() {
    var progress = LivePlaybackStartup.Progress(now: 0)
    _ = progress.observe(clock: 14, isPlaying: true, now: 1)
    _ = progress.observe(clock: 14.25, isPlaying: true, now: 1.25)
    XCTAssertFalse(progress.observe(clock: 14.25, isPlaying: false, now: 1.5))
    XCTAssertFalse(progress.observe(clock: 14.25, isPlaying: true, now: 2))
    XCTAssertFalse(progress.observe(clock: 14.5, isPlaying: true, now: 2.25))
    XCTAssertTrue(progress.observe(clock: 14.75, isPlaying: true, now: 2.5))
  }

  func testInvalidOrRewoundClockDoesNotStartPlayback() {
    var progress = LivePlaybackStartup.Progress(now: 0)
    XCTAssertFalse(progress.observe(clock: .nan, isPlaying: true, now: 0))
    XCTAssertFalse(progress.observe(clock: .infinity, isPlaying: true, now: 1))
    XCTAssertFalse(progress.observe(clock: 14, isPlaying: true, now: 2))
    XCTAssertFalse(progress.observe(clock: 12, isPlaying: true, now: 2.5))
    XCTAssertFalse(progress.hasStarted)
  }

  func testConcurrentMonitorSamplesDoNotEraseUsefulProgress() {
    var progress = LivePlaybackStartup.Progress(now: 0)
    _ = progress.observe(clock: 14, isPlaying: true, now: 1)
    XCTAssertFalse(progress.observe(clock: 14, isPlaying: true, now: 1.01))
    XCTAssertTrue(progress.observe(clock: 14.5, isPlaying: true, now: 1.5))
  }

  func testRateControllerCannotBypassStartupOrRebuffering() {
    var progress = LivePlaybackStartup.Progress(now: 0)
    XCTAssertFalse(progress.allowsRateAdjustment(isPlaying: true, isLoading: false, shouldPlay: true))
    _ = progress.observe(clock: 14, isPlaying: true, now: 1)
    _ = progress.observe(clock: 14.5, isPlaying: true, now: 1.5)
    XCTAssertTrue(progress.allowsRateAdjustment(isPlaying: true, isLoading: false, shouldPlay: true))
    XCTAssertFalse(progress.allowsRateAdjustment(isPlaying: false, isLoading: false, shouldPlay: true))
    XCTAssertFalse(progress.allowsRateAdjustment(isPlaying: true, isLoading: true, shouldPlay: true))
    XCTAssertFalse(progress.allowsRateAdjustment(isPlaying: true, isLoading: false, shouldPlay: false))
  }

  func testNewItemRequiresItsOwnStartupProgress() {
    var progress = LivePlaybackStartup.Progress(now: 0)
    _ = progress.observe(clock: 14, isPlaying: true, now: 1)
    _ = progress.observe(clock: 14.5, isPlaying: true, now: 1.5)
    XCTAssertTrue(progress.hasStarted)
    progress = LivePlaybackStartup.Progress(now: 3)
    XCTAssertEqual(progress.createdAt, 3)
    XCTAssertFalse(progress.hasStarted)
    XCTAssertFalse(progress.observe(clock: 3597, isPlaying: true, now: 4))
  }

  func testYouTubeUsesStableForwardBufferPreference() {
    let item = YouTubePlaybackPolicy.makeItem(url: URL(string: "https://example.com/live.m3u8")!)
    XCTAssertEqual(item.preferredForwardBufferDuration, 8)
    XCTAssertEqual(item.configuredTimeOffsetFromLive.seconds, 6)
    XCTAssertFalse(item.automaticallyPreservesTimeOffsetFromLive)
  }

  func testYouTubeAddsOnlyTwoSecondsOfMarginAfterRecovery() {
    let item = YouTubePlaybackPolicy.makeItem(
      url: URL(string: "https://example.com/live.m3u8")!, isRecovery: true)
    XCTAssertEqual(item.preferredForwardBufferDuration, 8)
    XCTAssertEqual(item.configuredTimeOffsetFromLive.seconds, 8)
    XCTAssertFalse(item.automaticallyPreservesTimeOffsetFromLive)
  }

  func testStartupSourceIsResolvedOnceAndReturnedForDirectInstallation() async throws {
    let calls = ProbeCalls()
    let source = try await LivePlaybackStartup.resolveYouTube {
      await calls.recordAttempt()
      return Self.source
    }
    let attempts = await calls.attempts
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(source.target, Self.source.target)
    XCTAssertEqual(source.live.hlsMaster, Self.source.live.hlsMaster)
    XCTAssertEqual(source.live.concurrentViewers, 42)
  }

  func testUnavailableYouTubePropagatesForTwitchFallback() async {
    do {
      _ = try await LivePlaybackStartup.resolveYouTube {
        throw AltSourceService.ResolutionError.noLiveVideo
      }
      XCTFail("An unavailable source must not be selected")
    } catch AltSourceService.ResolutionError.noLiveVideo {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSourceSelectionTimeoutCancelsLookupBeforeReturning() async {
    let calls = ProbeCalls()
    let start = ContinuousClock.now
    do {
      _ = try await LivePlaybackStartup.resolveYouTube(timeout: .milliseconds(50)) {
        await calls.recordAttempt()
        do {
          try await Task.sleep(for: .seconds(30))
          return Self.source
        } catch {
          await calls.recordCancellation()
          throw error
        }
      }
      XCTFail("The slow source must time out")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let cancelled = await calls.cancelled
    XCTAssertTrue(cancelled)
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
  }

  func testDismissingPlayerCancelsSourceSelection() async {
    let calls = ProbeCalls()
    let task = Task {
      try await LivePlaybackStartup.resolveYouTube {
        await calls.recordAttempt()
        try await Task.sleep(for: .seconds(30))
        return Self.source
      }
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled startup must not install a source")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testLateLookupResultCannotReplaceTimedOutSelection() async {
    do {
      _ = try await LivePlaybackStartup.resolveYouTube(timeout: .milliseconds(50)) {
        do {
          try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
          return Self.source
        }
        return Self.source
      }
      XCTFail("A lookup completing during cancellation must not replace Twitch")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  nonisolated private static var source: LivePlaybackStartup.YouTubeSource {
    LivePlaybackStartup.YouTubeSource(
      target: "@example",
      live: AltSourceService.YouTubeLive(
        hlsMaster: URL(string: "https://example.com/live.m3u8")!,
        concurrentViewers: 42))
  }

  private actor ProbeCalls {
    var attempts = 0
    var cancelled = false
    func recordAttempt() { attempts += 1 }
    func recordCancellation() { cancelled = true }
  }
}

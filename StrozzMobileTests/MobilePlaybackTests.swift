import AVFoundation
import XCTest
@testable import StrozzMobile

@MainActor
final class MobilePlaybackTests: XCTestCase {
  func testReplacementMobileAppUsesTheNewIdentityAndStorage() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.thatcube.Strozz")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Strozz")
    XCTAssertEqual(TopShelf.appGroupID, "group.com.thatcube.Strozz")
  }

  func testResponsiveLayouts() {
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 390, height: 780), isPhone: true, hideChat: false), .portrait)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 780, height: 390), isPhone: true, hideChat: false, phoneLandscape: true), .videoOnly)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 390, height: 300), isPhone: true, hideChat: false), .portrait)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 834, height: 1194), isPhone: false, hideChat: false), .portrait)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 1024, height: 740), isPhone: false, hideChat: false), .sideBySide)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 400, height: 1000), isPhone: false, hideChat: false), .portrait)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 1024, height: 740), isPhone: false, hideChat: true), .videoOnly)
  }

  func testQualitySelectionDoesNotSilentlyReplaceMissingQualityWithAuto() {
    let master = URL(string: "https://example.com/master.m3u8")!
    let video = URL(string: "https://example.com/video.m3u8")!
    let playback = StreamPlayback(master: master, qualities: [
      StreamQuality(id: "source", name: "Source", url: video, isAudioOnly: false, bitrate: 1000)
    ])
    XCTAssertEqual(MobileQuality.native.source(in: playback), master)
    XCTAssertEqual(MobileQuality.automatic.source(in: playback), master)
    XCTAssertEqual(MobileQuality.fixed("source").source(in: playback), video)
    XCTAssertNil(MobileQuality.fixed("missing").source(in: playback))
  }

  func testDecodeRecoveryChoosesVideoAndNeverLoopsOnSource() {
    let url = URL(string: "https://example.com/video.m3u8")!
    let source = StreamQuality(id: "source", name: "Source", url: url, isAudioOnly: false, bitrate: 5000)
    let lower = StreamQuality(id: "lower", name: "Low", url: url, isAudioOnly: false, bitrate: 1000)
    let audio = StreamQuality(id: "audio", name: "Audio", url: url, isAudioOnly: true, bitrate: 9999)
    XCTAssertEqual(MobilePlaybackModel.decodeRecoveryQuality(in: [lower, audio, source], selection: .native), source)
    XCTAssertEqual(MobilePlaybackModel.decodeRecoveryQuality(in: [lower, source], selection: .automatic), source)
    XCTAssertNil(MobilePlaybackModel.decodeRecoveryQuality(in: [lower, source], selection: .fixed(source.id)))
    XCTAssertNil(MobilePlaybackModel.decodeRecoveryQuality(in: [audio], selection: .native))
  }

  func testPinnedQualityRetainsEnginePreferenceAndAirPlayExplicitlyLeavesNative() {
    let model = MobilePlaybackModel(muted: true)
    model.select(.fixed("720p60"))
    XCTAssertTrue(model.requestsNativePlayback)
    model.prepareForAirPlay()
    XCTAssertEqual(model.selection, .automatic)
    XCTAssertFalse(model.requestsNativePlayback)
    model.select(.fixed("720p60"))
    XCTAssertFalse(model.requestsNativePlayback, "An explicit standard selection remains standard")
    model.select(.native)
    model.select(.fixed("720p60"))
    XCTAssertTrue(model.requestsNativePlayback)
  }

  func testStoppedLoadCannotResurrectPlayer() async {
    let gate = ResolutionGate()
    let model = MobilePlaybackModel { _ in await gate.wait() }
    model.start(channel: "test")
    await gate.waitUntilRequested()
    model.stop()
    gate.finish()
    await Task.yield()
    XCTAssertFalse(model.isActive)
    XCTAssertNil(model.player.currentItem)
    XCTAssertFalse(model.isLoading)
  }

  func testBackgroundInvalidatesResolveAndForegroundResolvesAgain() async {
    let gate = ResolutionGate()
    var calls = 0
    let model = MobilePlaybackModel(muted: true) { _ in
      calls += 1
      return await gate.wait()
    }
    model.start(channel: "test")
    await gate.waitUntilRequested()
    let previousPlayer = model.player
    model.player.volume = 0.35
    model.suspend()
    gate.finish()
    await Task.yield()
    XCTAssertNil(model.player.currentItem)
    model.resume()
    await gate.waitUntilRequested()
    XCTAssertEqual(calls, 2)
    XCTAssertFalse(model.player === previousPlayer)
    XCTAssertEqual(model.player.volume, 0.35, accuracy: 0.001)
    XCTAssertTrue(model.player.isMuted)
    model.stop()
    gate.finish()
  }

  func testAudioFailureDoesNotSpendNativeRetriesOrSelectStandardPlayback() async throws {
    let gate = ResolutionGate()
    var calls = 0
    let model = MobilePlaybackModel(muted: true) { _ in
      calls += 1
      return await gate.wait()
    }
    model.activateAudioSession = { throw NSError(domain: "AudioFixture", code: 1) }
    model.start(channel: "test")
    for _ in 0..<100 {
      if model.errorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(model.presentationState, .unavailable)
    XCTAssertEqual(calls, 0)
    XCTAssertNil(model.nativeFailure)
    XCTAssertEqual(model.selection, .native)
    XCTAssertEqual(model.player.rate, 0)
    model.activateAudioSession = {}
    model.retry()
    await gate.waitUntilRequested()
    XCTAssertEqual(calls, 1)
    XCTAssertNil(model.errorMessage)
    model.stop()
    gate.finish()
  }

  func testRepeatedMediaResetErrorsSurfaceFailureInsteadOfHangingOrFallingBack() async throws {
    var calls = 0
    let model = MobilePlaybackModel(muted: true) { _ in
      calls += 1
      throw NSError(domain: AVFoundationErrorDomain, code: AVError.mediaServicesWereReset.rawValue)
    }
    model.activateAudioSession = {}
    defer { model.stop() }
    model.start(channel: "test")
    for _ in 0..<200 {
      if model.errorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(calls, 2)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertFalse(model.isLoading)
    XCTAssertNil(model.nativeFailure)
    XCTAssertEqual(model.selection, .native)
    XCTAssertEqual(model.player.rate, 0)
  }

  func testMediaResetNotificationsCoalesceAndNeverResurrectStoppedPlayback() async throws {
    var pending: [CheckedContinuation<StreamPlayback, Never>] = []
    let model = MobilePlaybackModel(muted: true) { _ in
      await withCheckedContinuation { pending.append($0) }
    }
    model.activateAudioSession = {}
    defer {
      model.stop()
      for continuation in pending {
        continuation.resume(returning: StreamPlayback(
          master: URL(string: "https://example.invalid/stale.m3u8")!, qualities: []))
      }
    }
    model.start(channel: "test")
    for _ in 0..<100 {
      if pending.count == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let previousPlayer = model.player
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
    XCTAssertNil(model.player.currentItem)
    XCTAssertEqual(model.presentationState, .loading)
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    for _ in 0..<100 {
      if pending.count == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(pending.count, 2)
    XCTAssertFalse(model.player === previousPlayer)
    XCTAssertTrue(model.player.isMuted)
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    await Task.yield()
    XCTAssertEqual(pending.count, 2)
    XCTAssertNil(model.nativeFailure)
    model.stop()
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    await Task.yield()
    XCTAssertFalse(model.isActive)
    XCTAssertEqual(pending.count, 2)
  }

  func testBackgroundResetDefersAudioAndSourceUntilResume() async {
    let gate = ResolutionGate()
    var activations = 0
    let model = MobilePlaybackModel(muted: true) { _ in await gate.wait() }
    model.activateAudioSession = { activations += 1 }
    model.start(channel: "test")
    await gate.waitUntilRequested()
    model.suspend()
    gate.finish()
    let previousPlayer = model.player
    model.handleMediaServicesReset()
    await Task.yield()
    XCTAssertEqual(activations, 1)
    XCTAssertTrue(model.player === previousPlayer)
    model.resume()
    await gate.waitUntilRequested()
    XCTAssertEqual(activations, 2)
    XCTAssertFalse(model.player === previousPlayer)
    model.stop()
    gate.finish()
  }

  func testInterruptionWithoutResumePermissionKeepsPlaybackPaused() async {
    let gate = ResolutionGate()
    let model = MobilePlaybackModel(muted: true) { _ in await gate.wait() }
    model.activateAudioSession = {}
    model.start(channel: "test")
    await gate.waitUntilRequested()
    model.handleAudioInterruption(Notification(name: AVAudioSession.interruptionNotification, userInfo: [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
    ]))
    gate.finish()
    model.handleAudioInterruption(Notification(name: AVAudioSession.interruptionNotification, userInfo: [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
    ]))
    await gate.waitUntilRequested()
    XCTAssertTrue(model.isPaused)
    XCTAssertEqual(model.player.rate, 0)
    model.stop()
    gate.finish()
  }

  func testTransientNativeFailureResolvesAgainWithoutSelectingStandard() async throws {
    var pending: [CheckedContinuation<StreamPlayback, Never>] = []
    let model = MobilePlaybackModel(muted: true) { _ in
      await withCheckedContinuation { pending.append($0) }
    }
    model.start(channel: "test")
    for _ in 0..<100 {
      if pending.count == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    model.recoverNative(.unavailable)
    for _ in 0..<100 {
      if pending.count == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(pending.count, 2)
    XCTAssertEqual(model.selection, .native)
    XCTAssertNil(model.nativeFailure)
    XCTAssertTrue(model.isLoading)
    model.stop()
    for continuation in pending {
      continuation.resume(returning: StreamPlayback(
        master: URL(string: "https://example.com/stale.m3u8")!, qualities: []))
    }
    await Task.yield()
    XCTAssertNil(model.player.currentItem)
  }
}

@MainActor
private final class ResolutionGate {
  private var pending: CheckedContinuation<StreamPlayback, Never>?

  func wait() async -> StreamPlayback {
    await withCheckedContinuation { pending = $0 }
  }

  func waitUntilRequested() async {
    for _ in 0..<500 {
      if pending != nil { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Playback did not reach the injected resolver")
  }

  func finish() {
    pending?.resume(returning: StreamPlayback(
      master: URL(string: "https://example.com/live.m3u8")!, qualities: []))
    pending = nil
  }
}

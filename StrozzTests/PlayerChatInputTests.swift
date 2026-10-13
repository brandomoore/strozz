import AVKit
import os
import SwiftUI
import XCTest

@testable import Strozz

@MainActor
final class PlayerChatInputTests: XCTestCase {
  func testChatScrollHandoffsNeverBrieflyFocusPlaybackControls() async throws {
    for theme in AppTheme.allCases {
      for opaque in [false, true] {
        for signedIn in [false, true] {
          try await assertStableChatHandoffs(theme: theme, opaque: opaque, signedIn: signedIn)
        }
      }
    }
  }

  private func assertStableChatHandoffs(theme: AppTheme, opaque: Bool, signedIn: Bool) async throws {
    let probe = InputProbe()
    let context = "\(theme.rawValue), opaque=\(opaque), signedIn=\(signedIn)"
    try await withPlayer(isVOD: false, probe: probe, theme: theme, opaque: opaque, signedIn: signedIn) { view, _ in
      view.stepToChatInput(from: .quality)
      try await settle()
      XCTAssertEqual(view.focus, .chatInput)
      let chatFocus = try XCTUnwrap(probe.nativeFocus.last ?? nil)

      for exit in 0..<3 {
        probe.nativeFocus.removeAll()
        probe.focusChanges.removeAll()
        view.chatInputFocusedAt = .distantPast
        view.handleChatUpPress()
        try await settle()
        XCTAssertNotNil(view.chatSoftPauseRemaining)
        view.handleChatUpPress()
        try await settle()
        XCTAssertTrue(view.isChatScrolling)
        XCTAssertEqual(view.focus, .chatInput)
        XCTAssertTrue(probe.nativeFocus.allSatisfy { $0 == chatFocus },
          "\(context): Native focus changed while entering scroll: \(probe.nativeFocus)")
        XCTAssertTrue(probe.focusChanges.allSatisfy { $0 == .chatInput },
          "\(context): SwiftUI focus changed while entering scroll: \(probe.focusChanges)")

        probe.nativeFocus.removeAll()
        probe.focusChanges.removeAll()
        switch exit {
        case 0: view.handleChatDownPress()
        case 1: view.handlePlayerExitCommand()
        default: XCTAssertFalse(view.applyScrollDelta(100))
        }
        try await settle()
        XCTAssertFalse(view.isChatScrolling)
        XCTAssertNil(view.chatFrozenMessages)
        XCTAssertEqual(view.focus, .chatInput)
        XCTAssertTrue(probe.nativeFocus.allSatisfy { $0 == chatFocus },
          "\(context): Native focus changed while leaving scroll: \(probe.nativeFocus)")
        XCTAssertTrue(probe.focusChanges.allSatisfy { $0 == .chatInput },
          "\(context): SwiftUI focus changed while leaving scroll: \(probe.focusChanges)")
      }

      // A deliberate exit is still honored; no delayed correction steals it back.
      view.exitChatComposerLeft()
      try await settle()
      XCTAssertEqual(view.focus, .chatToggle)
      view.requestSeekBarFocus()
      try await settle()
      XCTAssertEqual(view.focus, .rewindScrubber)
      XCTAssertTrue(view.scrubberOwnsInput)
    }
  }

  func testVODScrollExitReenablesControlsWithoutRepausingChat() async throws {
    try await withPlayer(isVOD: true) { view, _ in
      view.stepToChatInput(from: .quality)
      try await settle()
      view.chatFrozenMessages = view.chat.messages
      view.chatInputFocusedAt = .distantPast
      view.handleChatUpPress()
      try await settle()
      XCTAssertTrue(view.isChatScrolling)
      view.handlePlayerExitCommand()
      try await settle()
      XCTAssertEqual(view.focus, .chatToggle)
      XCTAssertFalse(view.chatIsFrozen)
      view.requestSeekBarFocus()
      try await settle()
      XCTAssertTrue(view.scrubberOwnsInput)
    }
  }

  func testChatFocusRejectsDiscreteAndAnalogSeekingForLiveAndVOD() async throws {
    for isVOD in [false, true] {
      try await withPlayer(isVOD: isVOD) { view, item in
        view.stepToChatInput(from: .quality)
        try await settle()
        XCTAssertEqual(view.focus, view.chatFocusAnchor)
        view.chatInputFocusedAt = .distantPast
        view.chatFrozenMessages = view.chat.messages
        view.handleScrubberMoveCommand(.left)
        view.handleScrubberMoveCommand(.right)
        view.beginScrub()
        view.handleScrubTick(0.5)
        XCTAssertEqual(item.seeks.count, 0, "Chat focus alone excludes transport input")

        for _ in 0..<2 {
          view.handleChatUpPress()
          XCTAssertTrue(view.chatIsFrozen)
          let intent = view.model.nativePositionIntent
          let anchor = view.chatScrollAnchorID
          // Exercise late events even if tvOS delivers them to the old target.
          view.handleScrubberMoveCommand(.left)
          view.handleScrubberMoveCommand(.right)
          view.beginScrub()
          view.handleScrubTick(-0.5)
          view.startScrubInput()
          view.requestSeekBarFocus()

          XCTAssertEqual(item.seeks.count, 0)
          XCTAssertNil(view.scrubTargetSeconds)
          XCTAssertEqual(view.model.nativePositionIntent, intent)
          XCTAssertEqual(view.chatScrollAnchorID, anchor)
          XCTAssertEqual(view.focus, view.chatFocusAnchor)
          XCTAssertNil(view.scrubInput.onScrubMoved)
          XCTAssertFalse(view.scrubberFocusable)
        }
        XCTAssertTrue(view.isChatScrolling)
        view.focus = .rewindScrubber
        view.handleScrubberMoveCommand(.left)
        view.handleScrubTick(-0.5)
        try await settle()
        XCTAssertEqual(view.focus, view.chatFocusAnchor)
        XCTAssertTrue(view.isChatScrolling, "Rejected focus must not resume VOD chat")
        XCTAssertEqual(item.seeks.count, 0)
        let before = view.trackpadScrollIndex
        view.handleChatUpPress()
        XCTAssertLessThan(view.trackpadScrollIndex, before, "Chat must still scroll upward")

        view.showControls = false
        view.focus = .video
        view.handlePlayerMoveCommand(.left)
        view.handlePlayerMoveCommand(.right)
        view.handleScrubberMoveCommand(.left)
        view.handleScrubTick(0.5)
        XCTAssertTrue(view.isChatScrolling)
        XCTAssertFalse(view.showControls)
        XCTAssertEqual(item.seeks.count, 0)
      }
    }
  }

  func testLeavingScrubberStopsAnalogInputAndReturningStillSeeks() async throws {
    for isVOD in [false, true] {
      try await withPlayer(isVOD: isVOD) { view, item in
        view.requestSeekBarFocus()
        try await settle()
        XCTAssertEqual(view.focus, .rewindScrubber)
        XCTAssertTrue(view.scrubberOwnsInput, ownershipState(view))
        let lateBegin = try XCTUnwrap(view.scrubInput.onScrubBegan)
        let lateMove = try XCTUnwrap(view.scrubInput.onScrubMoved)

        view.handleScrubberMoveCommand(.left)
        XCTAssertEqual(item.seeks.last, 90)
        view.scrubCommitTask?.cancel()
        view.beginScrub()
        view.lastScrubSeekAt = .distantPast
        view.handleScrubTick(-0.2)
        XCTAssertEqual(item.seeks.last, 80)
        XCTAssertTrue(view.isScrubbing)

        view.handleScrubberMoveCommand(.down)
        try await settle()
        XCTAssertEqual(view.focus, .quality)
        XCTAssertFalse(view.isScrubbing)
        XCTAssertNil(view.scrubInput.onScrubMoved)
        view.stepToChatInput(from: .quality)
        try await settle()
        let count = item.seeks.count
        lateBegin()
        lateMove(0.5)
        view.handleScrubberMoveCommand(.right)
        XCTAssertEqual(item.seeks.count, count, "Stale analog callbacks cannot seek from chat")
        XCTAssertFalse(view.isScrubbing)

        view.model.resetChatReading()
        view.activateControl(.quality)
        try await settle()
        view.requestSeekBarFocus()
        try await settle()
        XCTAssertTrue(view.scrubberOwnsInput, ownershipState(view))
        view.lastScrubSeekAt = .distantPast
        view.handleScrubberMoveCommand(.right)
        XCTAssertEqual(item.seeks.count, count + 1)
        XCTAssertNotNil(view.scrubInput.onScrubMoved)
      }
    }
  }

  func testChatReadStateRevokesScrubbingBeforeFocusCorrection() async throws {
    try await withPlayer(isVOD: false) { view, item in
      view.requestSeekBarFocus()
      try await settle()
      XCTAssertTrue(view.scrubberOwnsInput)
      let lateMove = try XCTUnwrap(view.scrubInput.onScrubMoved)
      view.startSoftPause()
      XCTAssertEqual(view.focus, .rewindScrubber, "Exercise the pre-correction interval")
      XCTAssertFalse(view.scrubberOwnsInput)
      XCTAssertFalse(view.scrubberFocusable)
      lateMove(-0.3)
      view.handleScrubberMoveCommand(.left)
      XCTAssertEqual(item.seeks.count, 0)
      try await settle()
      XCTAssertNil(view.scrubInput.onScrubMoved)
    }
  }

  private func withPlayer(
    isVOD: Bool,
    probe: InputProbe = InputProbe(),
    theme: AppTheme = .dark,
    opaque: Bool = false,
    signedIn: Bool = false,
    body: (PlayerView, InputTrackingItem) async throws -> Void
  ) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let model = PlayerModel()
    let item = InputTrackingItem(url: URL(fileURLWithPath: "/nonexistent-input-fixture"))
    model.player.replaceCurrentItem(with: item)
    model.isLoading = false
    model.isUserPaused = true
    model.activeChannel = "fixture"
    model.chat.messages = try (0..<40).map { index in
      try XCTUnwrap(ChatMessage(ircLine:
        "@id=message-\(index);display-name=Viewer :viewer!viewer@host PRIVMSG #fixture :Message \(index)"
      ))
    }
    let auth = TwitchAuthSession()
    auth.isAuthenticated = signedIn
    var player = PlayerView(channel: "fixture", auth: auth,
      vod: isVOD ? .init(id: "fixture", title: "Fixture") : nil, model: model)
    player.inputTestContent = { view in
      probe.view = view
      return AnyView(view.focusManagementHandler(view.remoteCommandHandlers(
        HStack(alignment: .bottom, spacing: 24) {
          view.bottomOverlay
          view.chatPane
        }
        .padding(40)
      ))
      .onChange(of: view.focus) { _, value in probe.focusChanges.append(value) }
      .onAppear {
        view.showControls = true
        view.showChat = true
        view.focus = .quality
      })
    }
    let defaults = UserDefaults.standard
    let previousSignOut = defaults.object(forKey: PersistenceKey.icloudAccountSignedOut)
    defaults.set(true, forKey: PersistenceKey.icloudAccountSignedOut)
    let environment = AppEnvironment()
    defaults.set(previousSignOut, forKey: PersistenceKey.icloudAccountSignedOut)
    let host = InputHostingController(rootView: player
      .environment(environment)
      .environment(\.themePalette, theme.palette(systemColorScheme: .dark))
      .environment(\.glassDisabled, opaque))
    host.onFocusUpdate = { view in
      probe.nativeFocus.append(view.map(ObjectIdentifier.init))
    }
    window.rootViewController = host
    host.view.layoutIfNeeded()
    defer {
      probe.view?.stopScrubInput()
      probe.view?.hideTask?.cancel()
      probe.view?.focusRecoveryTask?.cancel()
      model.scrubCommitTask?.cancel()
      model.resetChatReading()
      model.player.replaceCurrentItem(with: nil)
      window.rootViewController = previous
      probe.view = nil
    }
    try await settle()
    let view = try XCTUnwrap(probe.view)
    XCTAssertEqual(view.focus, .quality)
    try await body(view, item)
  }

  private func settle() async throws {
    try await Task.sleep(for: .milliseconds(350))
  }

  private func ownershipState(_ view: PlayerView) -> String {
    "controls=\(view.showControls) focus=\(String(describing: view.focus)) frozen=\(view.chatIsFrozen) "
      + "compact=\(view.isMultiviewCompact) settings=\(view.showChatSettings) rewards=\(view.showRewards) "
      + "quality=\(view.isQualityMenuPresented) sleeping=\(view.isSleeping) error=\(String(describing: view.errorMessage))"
  }
}

@MainActor
private final class InputProbe {
  var view: PlayerView?
  var focusChanges: [PlayerView.Focusable?] = []
  var nativeFocus: [ObjectIdentifier?] = []
}

@MainActor
private final class InputHostingController<Content: View>: UIHostingController<Content> {
  var onFocusUpdate: ((UIView?) -> Void)?

  override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
    super.didUpdateFocus(in: context, with: coordinator)
    onFocusUpdate?(context.nextFocusedView)
  }
}

private final class InputTrackingItem: AVPlayerItem, @unchecked Sendable {
  private nonisolated let recordedSeeks = OSAllocatedUnfairLock(initialState: [Double]())
  var seeks: [Double] { recordedSeeks.withLock { $0 } }
  override func currentTime() -> CMTime { CMTime(seconds: 100, preferredTimescale: 600) }
  override var seekableTimeRanges: [NSValue] {
    [NSValue(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 200, preferredTimescale: 600)))]
  }
  override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) {
    recordedSeeks.withLock { $0.append(time.seconds) }
  }
  override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                     completionHandler: (@Sendable (Bool) -> Void)?) {
    recordedSeeks.withLock { $0.append(time.seconds) }
    completionHandler?(true)
  }
}

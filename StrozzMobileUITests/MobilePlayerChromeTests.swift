import UIKit
import XCTest

@MainActor
final class MobilePlayerChromeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testSwipeMinimizesWithFullChatHistoryAndRestoresReadingPosition() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_LONG_CHAT_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate() }
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    let expanded = video.frame
    let timeline = app.scrollViews["mobile-chat-timeline"]
    for _ in 0..<3 { timeline.swipeDown() }
    XCTAssertTrue(app.buttons["Jump to present"].exists)
    for _ in 0..<3 {
      let start = video.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25))
      let clock = Date()
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 150)),
        withVelocity: .slow, thenHoldForDuration: 0)
      let mini = app.buttons["mobile-expand-player"]
      XCTAssertTrue(mini.waitForExistence(timeout: 2))
      XCTAssertLessThan(video.frame.width, expanded.width - 50)
      let measurement = XCTAttachment(string: "Swipe and XCTest synchronization: \(Date().timeIntervalSince(clock)) seconds")
      measurement.name = "Full-history minimize interaction"
      measurement.lifetime = .keepAlways
      add(measurement)
      mini.tap()
      XCTAssertTrue(app.buttons["mobile-controls-toggle"].waitForExistence(timeout: 2))
      XCTAssertEqual(video.frame.width, expanded.width, accuracy: 1)
      XCTAssertTrue(app.buttons["Jump to present"].exists)
    }
  }

  func testDetailsCollapseWithControlsAndTappingVideoRestoresBoth() {
    let app = launch()
    defer { app.terminate() }
    let details = app.otherElements["mobile-stream-details"]
    let controls = app.buttons["mobile-play-pause"]
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let timeline = app.scrollViews["mobile-chat-timeline"]
    XCTAssertTrue(details.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Stream chat"].exists)
    XCTAssertFalse(app.buttons["mobile-toggle-chat"].exists, "Portrait has no sideways chat toggle")
    XCTAssertTrue(app.staticTexts["Sample streamer"].exists)
    XCTAssertTrue(app.staticTexts["A stream description that appears with the controls"].exists)
    XCTAssertTrue(controls.exists)
    let uptime = app.staticTexts["mobile-stream-uptime"]
    XCTAssertTrue(uptime.exists)
    XCTAssertFalse(details.staticTexts["Auto - Native Low Latency"].exists)
    tapVideo(app)
    if !controls.waitForExistence(timeout: 0.3) { tapVideo(app) }
    XCTAssertTrue(details.exists)
    let videoFrame = video.frame
    let expandedChat = timeline.frame
    capture(app, "Stream profile and controls on entry")
    waitForHidden(details)
    XCTAssertFalse(controls.exists)
    XCTAssertFalse(uptime.exists, "Uptime follows the controls rather than becoming always visible")
    XCTAssertGreaterThan(timeline.frame.height, expandedChat.height + 50)
    XCTAssertEqual(timeline.frame.minY, video.frame.maxY, accuracy: 1,
      "Collapsed chat must start directly below the video without an empty heading row")
    XCTAssertEqual(video.frame, videoFrame, "Collapsing details must not resize the video")
    assertLatestVisible(app, timeline: timeline)
    capture(app, "Video and chat after automatic collapse")

    tapVideo(app)
    XCTAssertTrue(details.waitForExistence(timeout: 2))
    XCTAssertTrue(controls.exists)
    XCTAssertEqual(timeline.frame.height, expandedChat.height, accuracy: 1)
    assertLatestVisible(app, timeline: timeline)
    tapVideo(app)
    waitForHidden(details)
    XCTAssertFalse(controls.exists)

    for _ in 0..<3 { timeline.swipeDown() }
    let jump = app.buttons["Jump to present"]
    XCTAssertTrue(jump.waitForExistence(timeout: 3))
    tapVideo(app)
    XCTAssertTrue(details.waitForExistence(timeout: 2))
    XCTAssertTrue(jump.exists, "Revealing details must not recreate chat or lose its read position")
    tapVideo(app)
    waitForHidden(details)
    XCTAssertTrue(jump.exists)
    tapVideo(app)
    app.buttons["mobile-minimize-player"].tap()
    XCTAssertFalse(details.exists)
    XCTAssertTrue(app.buttons["mobile-expand-player"].waitForExistence(timeout: 3))
    app.buttons["mobile-expand-player"].tap()
    XCTAssertTrue(details.waitForExistence(timeout: 3))
    XCTAssertTrue(jump.exists, "Minimizing and restoring must keep the existing chat position")
    XCTAssertEqual(video.frame, videoFrame)
  }

  func testPausedKeepsDetailsVisible() {
    let app = launch()
    defer { app.terminate() }
    let details = app.otherElements["mobile-stream-details"]
    let pause = app.buttons["mobile-play-pause"]
    XCTAssertTrue(pause.waitForExistence(timeout: 10))
    pause.tap()
    XCTAssertEqual(pause.label, "Play")
    let hiddenWhilePaused = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: details)
    hiddenWhilePaused.isInverted = true
    waitForExpectations(timeout: 5)
  }

  func testLiveTimeAndViewersAreOneUnboxedRow() {
    let app = launch()
    defer { app.terminate() }
    let uptime = app.staticTexts["mobile-stream-uptime"]
    XCTAssertTrue(uptime.waitForExistence(timeout: 10))
    app.buttons["mobile-mute"].tap()
    let live = app.descendants(matching: .any).matching(identifier: "mobile-live-status").firstMatch
    let viewers = app.descendants(matching: .any).matching(identifier: "mobile-viewer-readout").firstMatch
    XCTAssertTrue(viewers.exists)
    XCTAssertEqual(live.frame.midY, viewers.frame.midY, accuracy: 1,
      "Elapsed time and viewers must sit side by side, not stack")
    XCTAssertEqual(live.frame.minX - viewers.frame.maxX, 14, accuracy: 1)
    XCTAssertLessThan(live.frame.maxX, app.buttons["mobile-mute"].frame.minX)
    XCTAssertFalse(app.staticTexts["Live"].exists, "The elapsed timer replaces the redundant Live word")
    capture(app, "Horizontal red-dot time and viewer readouts without backplates")
  }

  func testQualitySheetHoldsDetailsAndRestartsTheIdleTimeout() {
    let app = launch()
    defer { app.terminate() }
    let details = app.otherElements["mobile-stream-details"]
    let pause = app.buttons["mobile-play-pause"]
    XCTAssertTrue(pause.waitForExistence(timeout: 10))
    app.buttons["Playback quality"].tap()
    XCTAssertTrue(app.navigationBars["Playback quality"].waitForExistence(timeout: 3))
    let closedEarly = expectation(for: NSPredicate(format: "exists == false"),
      evaluatedWith: app.navigationBars["Playback quality"])
    closedEarly.isInverted = true
    waitForExpectations(timeout: 5)
    app.buttons["Done"].tap()
    XCTAssertTrue(details.waitForExistence(timeout: 2))
    XCTAssertTrue(pause.exists)
    waitForHidden(details)
    XCTAssertFalse(pause.exists)
  }

  func testLandscapePreservesTheVideoAndSideChatLayout() {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let details = app.otherElements["mobile-stream-details"]
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let timeline = app.scrollViews["mobile-chat-timeline"]
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    expectation(for: NSPredicate { _, _ in
      app.frame.width > app.frame.height && video.frame.width > video.frame.height
    }, evaluatedWith: app)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(app.frame.contains(video.frame))
    if UIDevice.current.userInterfaceIdiom == .phone {
      XCTAssertFalse(details.exists, "Phone fullscreen must not reveal an offscreen profile")
      XCTAssertFalse(timeline.isHittable)
      XCTAssertGreaterThan(video.frame.width, video.frame.height)
      let fullscreenWidth = video.frame.width
      let toggle = app.buttons["mobile-toggle-chat"]
      tapVideo(app)
      if !toggle.waitForExistence(timeout: 0.3) { tapVideo(app) }
      XCTAssertEqual(toggle.label, "Show chat")
      app.buttons["mobile-play-pause"].tap()
      toggle.tap()
      XCTAssertTrue(timeline.waitForExistence(timeout: 3))
      XCTAssertTrue(app.frame.contains(timeline.frame))
      XCTAssertGreaterThanOrEqual(timeline.frame.minX, video.frame.maxX)
      assertCenteredSideLayout(app, video: video)
      XCTAssertEqual(toggle.label, "Hide chat")
      capture(app, "Phone landscape with optional side chat")
      app.buttons["mobile-toggle-chat"].tap()
      XCTAssertEqual(video.frame.width, fullscreenWidth, accuracy: 1)
      XCTAssertEqual(app.buttons["mobile-toggle-chat"].label, "Show chat")
      capture(app, "Phone landscape after hiding side chat")
      let hiddenChat = app.otherElements["mobile-player-chat-region"]
      XCTAssertGreaterThanOrEqual(hiddenChat.frame.minX, video.frame.maxX - 1)
      let rotate = app.buttons["mobile-rotate-player"]
      XCTAssertEqual(rotate.label, "Rotate to portrait")
      rotate.tap()
      expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
      waitForExpectations(timeout: 5)
      app.scrollViews["mobile-chat-timeline"].swipeDown()
      XCTAssertTrue(app.buttons["Jump to present"].waitForExistence(timeout: 3))
      XCTAssertFalse(toggle.exists)
    } else {
      tapVideo(app)
      if !details.waitForExistence(timeout: 0.5) { tapVideo(app) }
      XCTAssertTrue(details.waitForExistence(timeout: 2))
      let videoFrame = video.frame
      let chatFrame = timeline.frame
      XCTAssertTrue(app.frame.contains(chatFrame), "Side chat must stay fully on screen")
      XCTAssertGreaterThanOrEqual(chatFrame.minX, videoFrame.maxX)
      assertCenteredSideLayout(app, video: video)
      waitForHidden(details)
      XCTAssertEqual(video.frame, videoFrame)
      XCTAssertEqual(timeline.frame, chatFrame)
      tapVideo(app)
      XCTAssertTrue(details.waitForExistence(timeout: 2))
      XCTAssertEqual(timeline.frame, chatFrame)
      capture(app, "Tablet side chat with stream profile revealed")
    }
  }

  func testRepeatedPortraitLandscapeTransitionsPreserveDraftAndChat() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_DRAFT_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let field = app.textViews["mobile-chat-composer-input"]
    let timeline = app.scrollViews["mobile-chat-timeline"]
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let portraitWidth = video.frame.width
    field.tap()
    field.typeText("Keep this draft while rotating")
    XCTAssertEqual(video.frame.width, portraitWidth, accuracy: 1,
      "The portrait keyboard must not move chat into a sidebar")
    XCTAssertFalse(app.buttons["mobile-toggle-chat"].exists,
      "Opening the keyboard in portrait must not switch to the landscape layout")
    tapVideo(app)
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
    waitForExpectations(timeout: 5)
    timeline.swipeDown()
    XCTAssertTrue(app.buttons["Jump to present"].exists)
    let portraitVideo = video.frame
    for iteration in 0..<2 {
      XCUIDevice.shared.orientation = iteration == 0 ? .landscapeLeft : .landscapeRight
      expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
      waitForExpectations(timeout: 5)
      if UIDevice.current.userInterfaceIdiom == .phone {
        if !app.buttons["mobile-toggle-chat"].isHittable { tapVideo(app) }
        if app.buttons["mobile-toggle-chat"].label == "Show chat" { app.buttons["mobile-toggle-chat"].tap() }
      }
      let rotatedTimeline = app.scrollViews["mobile-chat-timeline"]
      XCTAssertTrue(rotatedTimeline.waitForExistence(timeout: 5))
      XCTAssertEqual(field.value as? String, "Keep this draft while rotating")
      XCTAssertTrue(app.buttons["Jump to present"].exists)
      assertCenteredSideLayout(app, video: video)
      capture(app, "Landscape \(iteration) with centered video and retained draft")
      let jump = app.buttons["Jump to present"]
      jump.tap()
      waitForHidden(jump)
      rotatedTimeline.swipeDown()
      XCTAssertTrue(jump.waitForExistence(timeout: 3))
      XCUIDevice.shared.orientation = .portrait
      expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
      waitForExpectations(timeout: 5)
      XCTAssertEqual(field.value as? String, "Keep this draft while rotating")
      XCTAssertTrue(app.buttons["Jump to present"].exists)
      XCTAssertEqual(video.frame.width, portraitVideo.width, accuracy: 1)
      XCTAssertEqual(video.frame.height, portraitVideo.height, accuracy: 1)
      XCTAssertGreaterThanOrEqual(timeline.frame.minY, video.frame.maxY)
      capture(app, "Portrait \(iteration) after rotation with retained draft")
    }
  }

  private func assertCenteredSideLayout(_ app: XCUIApplication, video: XCUIElement) {
    let chat = app.otherElements["mobile-player-chat-region"]
    XCTAssertTrue(chat.exists)
    XCTAssertLessThanOrEqual(chat.frame.width, 320.5)
    XCTAssertLessThanOrEqual(chat.frame.width, app.frame.width / 3 + 1)
    // Scroll-view accessibility bounds include the iPad status-bar area even
    // when drawing is clipped; use the fixture's actual safe-area layout proposal.
    let viewport = (app.otherElements["fixture-player-viewport"].value as? String ?? "")
      .split(separator: " ").compactMap { Double($0) }
    XCTAssertEqual(viewport.count, 2)
    guard viewport.count == 2 else { return }
    XCTAssertEqual(video.frame.midY, viewport[0] + viewport[1] / 2, accuracy: 1,
      "The video must stay vertically centered even when profile details are revealed")
    XCTAssertLessThanOrEqual(video.frame.maxX, chat.frame.minX + 1)
  }

  func testLandscapeProfileDoesNotOverlapControlsOrMoveTheVideo() {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    tapVideo(app)
    if !app.buttons["mobile-toggle-chat"].waitForExistence(timeout: 0.3) { tapVideo(app) }
    if app.buttons["mobile-toggle-chat"].label == "Show chat" { app.buttons["mobile-toggle-chat"].tap() }
    tapVideo(app)
    if !app.buttons["mobile-play-pause"].waitForExistence(timeout: 0.3) { tapVideo(app) }
    app.buttons["mobile-play-pause"].tap()
    let details = app.otherElements["mobile-stream-details"]
    XCTAssertTrue(details.waitForExistence(timeout: 2))
    let videoFrame = video.frame
    let detailsFrame = details.frame
    let buttonsFrame = app.buttons["mobile-mute"].frame
    XCTAssertGreaterThanOrEqual(detailsFrame.minY, videoFrame.minY)
    XCTAssertLessThanOrEqual(detailsFrame.maxY, videoFrame.maxY + 1)
    XCTAssertLessThanOrEqual(buttonsFrame.maxY, detailsFrame.minY + 1)
    assertCenteredSideLayout(app, video: video)
    capture(app, "Centered landscape video with compact profile and clear controls")
  }

  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launch()
    return app
  }

  private func tapVideo(_ app: XCUIApplication) {
    app.buttons["mobile-controls-toggle"]
      .coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
  }

  private func waitForHidden(_ element: XCUIElement) {
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
    waitForExpectations(timeout: 7)
  }

  private func assertLatestVisible(_ app: XCUIApplication, timeline: XCUIElement) {
    let latest = app.descendants(matching: .any).matching(identifier: "mobile-chat-latest-message").firstMatch
    XCTAssertTrue(latest.exists)
    XCTAssertGreaterThan(latest.frame.height, 0)
    XCTAssertGreaterThanOrEqual(latest.frame.minY, timeline.frame.minY - 1)
    XCTAssertLessThanOrEqual(latest.frame.maxY, timeline.frame.maxY + 1)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

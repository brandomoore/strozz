import UIKit
import XCTest

@MainActor
final class MobilePlayerChromeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testDetailsCollapseWithControlsAndTappingVideoRestoresBoth() {
    let app = launch()
    defer { app.terminate() }
    let details = app.otherElements["mobile-stream-details"]
    let controls = app.buttons["mobile-play-pause"]
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let timeline = app.scrollViews["mobile-chat-panel"]
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
    XCTAssertLessThan(live.frame.maxX, viewers.frame.minX)
    XCTAssertLessThan(viewers.frame.maxX, app.buttons["mobile-mute"].frame.minX)
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
    let timeline = app.scrollViews["mobile-chat-panel"]
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
      let toggle = app.buttons["mobile-toggle-chat"]
      XCTAssertEqual(toggle.label, "Show chat")
      toggle.tap()
      XCTAssertTrue(timeline.waitForExistence(timeout: 3))
      XCTAssertTrue(app.frame.contains(timeline.frame))
      XCTAssertGreaterThanOrEqual(timeline.frame.minX, video.frame.maxX)
      XCTAssertEqual(toggle.label, "Hide chat")
      capture(app, "Phone landscape with optional side chat")
      toggle.tap()
      XCTAssertFalse(timeline.isHittable)
      let rotate = app.buttons["mobile-rotate-player"]
      XCTAssertEqual(rotate.label, "Rotate to portrait")
      rotate.tap()
      expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
      waitForExpectations(timeout: 5)
      XCTAssertTrue(timeline.isHittable)
      XCTAssertFalse(toggle.exists)
    } else {
      tapVideo(app)
      if !details.waitForExistence(timeout: 0.5) { tapVideo(app) }
      XCTAssertTrue(details.waitForExistence(timeout: 2))
      let videoFrame = video.frame
      let chatFrame = timeline.frame
      XCTAssertTrue(app.frame.contains(chatFrame), "Side chat must stay fully on screen")
      XCTAssertGreaterThanOrEqual(chatFrame.minX, videoFrame.maxX)
      waitForHidden(details)
      XCTAssertEqual(video.frame, videoFrame)
      XCTAssertEqual(timeline.frame, chatFrame)
      tapVideo(app)
      XCTAssertTrue(details.waitForExistence(timeout: 2))
      XCTAssertEqual(timeline.frame, chatFrame)
      capture(app, "Tablet side chat with stream profile revealed")
    }
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
    XCTAssertTrue(latest.isHittable)
    XCTAssertLessThanOrEqual(latest.frame.maxY, timeline.frame.maxY + 1)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

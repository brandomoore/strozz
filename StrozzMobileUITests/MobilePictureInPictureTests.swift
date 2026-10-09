import XCTest

@MainActor
final class MobilePictureInPictureTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testSwipeReturnsToBrowseWithAnInAppPlayerAndRestoresOrReplacesIt() throws {
    try requireLiveTests()
    let app = launch()
    defer { app.terminate() }
    app.buttons["Browse"].firstMatch.tap()
    let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'category-'")).firstMatch
    XCTAssertTrue(category.waitForExistence(timeout: 35))
    category.tap()
    let streams = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'"))
    XCTAssertTrue(streams.element(boundBy: 1).waitForExistence(timeout: 35))
    let previousPage = app.navigationBars.firstMatch.identifier
    let first = streams.element(boundBy: 0).identifier
    let second = streams.element(boundBy: 1).identifier
    app.buttons[first].tap()
    waitForVideo(app)
    let surface = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let expanded = surface.frame
    let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.25))
    let end = start.withOffset(CGVector(dx: 0, dy: 120))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
    XCTAssertTrue(app.buttons["mobile-expand-player"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.navigationBars[previousPage].exists)
    XCTAssertTrue(surface.exists, "The playing surface stays mounted")
    XCTAssertLessThan(surface.frame.width, expanded.width - 100)
    XCTAssertFalse(app.otherElements["PIPUIView"].exists, "Native PiP is reserved for leaving the app")
    XCTAssertTrue(app.buttons[first].isHittable)
    capture("In-app player over originating category")

    app.buttons["Home"].firstMatch.tap()
    XCTAssertTrue(app.buttons["mobile-expand-player"].exists, "The mini-player follows tab navigation")
    app.buttons["Browse"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars[previousPage].exists)
    expandMiniPlayer(app)
    XCTAssertEqual(surface.frame.width, expanded.width, accuracy: 1)
    collapseWithChevron(app)
    app.buttons[first].tap()
    waitForVideo(app)
    collapseWithChevron(app)
    app.buttons[second].tap()
    waitForVideo(app)
    collapseWithChevron(app)
    capture("Replacement stream in the in-app player")
    showMiniPlayerControls(app)
    app.buttons["Close player"].tap()
    XCTAssertFalse(app.buttons["mobile-expand-player"].exists)
    XCTAssertFalse(surface.exists)
    XCTAssertTrue(app.buttons[second].isHittable)
  }

  func testMiniPlayerCanBeDraggedResizedAndExpandedWithoutLosingPlacement() throws {
    try requireLiveTests()
    let app = launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
    XCTAssertTrue(stream.waitForExistence(timeout: 45))
    stream.tap()
    waitForVideo(app)
    collapseWithChevron(app)
    let mini = app.buttons["mobile-expand-player"]
    let original = mini.frame
    drag(mini, by: CGVector(dx: -60, dy: -180))
    XCTAssertTrue(mini.exists, "Dragging must not expand or close the player")
    XCTAssertEqual(mini.frame.minX, original.minX - 60, accuracy: 2)
    XCTAssertEqual(mini.frame.minY, original.minY - 180, accuracy: 2)
    XCTAssertEqual(mini.frame.width, original.width, accuracy: 1)
    mini.pinch(withScale: 1.3, velocity: 0.8)
    // XCTest's synthesized scale differs from recognizer magnification, even on a fixed-size view.
    // Unit tests verify exact scaling; here require real resizing and an on-screen result.
    XCTAssertGreaterThan(mini.frame.width, original.width + 30)
    XCTAssertTrue(app.frame.contains(mini.frame))
    let larger = mini.frame
    mini.pinch(withScale: 0.8, velocity: -0.8)
    XCTAssertLessThan(mini.frame.width, larger.width - 20)
    let customized = mini.frame
    XCTAssertEqual(customized.width / customized.height, 16 / 9, accuracy: 0.02)
    app.buttons["Browse"].firstMatch.tap()
    XCTAssertEqual(mini.frame.minX, customized.minX, accuracy: 1)
    XCTAssertEqual(mini.frame.minY, customized.minY, accuracy: 1)
    XCTAssertEqual(mini.frame.width, customized.width, accuracy: 1)
    expandMiniPlayer(app)
    collapseWithChevron(app)
    XCTAssertEqual(mini.frame.minX, customized.minX, accuracy: 2)
    XCTAssertEqual(mini.frame.minY, customized.minY, accuracy: 2)
    XCTAssertEqual(mini.frame.width, customized.width, accuracy: 2)
    XCUIDevice.shared.orientation = .landscapeLeft
    expectation(for: NSPredicate { _, _ in
      app.frame.width > app.frame.height && app.frame.contains(mini.frame)
    }, evaluatedWith: app)
    waitForExpectations(timeout: 5)
    let rotated = settledFrame(mini)
    XCTAssertTrue(app.frame.contains(rotated), "Rotated mini-player \(rotated) must fit inside \(app.frame)")
    capture("Rotated mini-player")
    XCUIDevice.shared.orientation = .portrait
    expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
    waitForExpectations(timeout: 5)
    let restored = settledFrame(mini)
    XCTAssertEqual(restored.minY, customized.minY, accuracy: 2)
    XCTAssertEqual(restored.width, customized.width, accuracy: 2)
    showMiniPlayerControls(app)
    app.buttons["mobile-mini-play-pause"].tap()
    XCTAssertEqual(app.buttons["mobile-mini-play-pause"].label, "Play")
    app.buttons["mobile-mini-play-pause"].tap()
    XCTAssertEqual(app.buttons["mobile-mini-play-pause"].label, "Pause")
    capture("Moved and resized in-app player")
    showMiniPlayerControls(app)
    app.buttons["Close player"].tap()
    XCTAssertFalse(mini.exists)
  }

  private func drag(_ element: XCUIElement, by delta: CGVector) {
    let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(delta),
                withVelocity: .slow, thenHoldForDuration: 0.15)
  }

  func testVerticalFlicksReachEdgesWhileGentleReleasesStayControlled() throws {
    try requireLiveTests()
    let app = launch()
    defer { app.terminate() }
    let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
    XCTAssertTrue(stream.waitForExistence(timeout: 45))
    stream.tap()
    waitForVideo(app)
    let surface = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let topEdge = surface.frame.minY + 12
    collapseWithChevron(app)
    let mini = app.buttons["mobile-expand-player"]
    let original = settledFrame(mini)
    func flick(_ distance: CGFloat, speed: CGFloat) {
      let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                  withVelocity: XCUIGestureVelocity(rawValue: speed), thenHoldForDuration: 0)
    }
    flick(-140, speed: 2000)
    let top = settledFrame(mini)
    XCTAssertEqual(top.minY, topEdge, accuracy: 2, "A deliberate upward flick should reach the top")
    XCTAssertEqual(top.minX, original.minX, accuracy: 2)
    XCTAssertEqual(top.size, original.size)
    capture("Mini-player after an upward edge flick")
    flick(140, speed: 2000)
    let bottom = settledFrame(mini)
    XCTAssertEqual(bottom.minY, original.minY, accuracy: 2, "A deliberate downward flick should reach the bottom")
    XCTAssertEqual(bottom.minX, original.minX, accuracy: 2)
    XCTAssertTrue(app.frame.contains(bottom))
    let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -140)),
                withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0)
    XCTAssertTrue(mini.exists)
    let settled = settledFrame(mini)
    XCTAssertLessThan(settled.minY, original.minY - 141, "A gentle release should coast beyond the finger's endpoint")
    XCTAssertGreaterThan(settled.minY, original.minY - 281, "Momentum should be short and bounded")
    XCTAssertEqual(settled.width, original.width, accuracy: 0.5)
    XCTAssertEqual(settled.height, original.height, accuracy: 0.5)
    XCTAssertTrue(app.frame.contains(settled))
    drag(mini, by: CGVector(dx: -30, dy: -40))
    XCTAssertEqual(mini.frame.minX, settled.minX - 30, accuracy: 2)
    XCTAssertEqual(mini.frame.minY, settled.minY - 40, accuracy: 2)
    capture("Mini-player after a gentle glide and precise reposition")
    expandMiniPlayer(app)
  }

  func testMiniPlayerControlsFadeAndFirstTapRevealsWithoutExpanding() throws {
    try requireLiveTests()
    let app = launch()
    defer { app.terminate() }
    let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
    XCTAssertTrue(stream.waitForExistence(timeout: 45))
    stream.tap()
    waitForVideo(app)
    collapseWithChevron(app)
    let mini = app.buttons["mobile-expand-player"]
    let pause = app.buttons["mobile-mini-play-pause"]
    XCTAssertTrue(pause.exists)
    func waitForHiddenControls() {
      expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pause)
      waitForExpectations(timeout: 8)
      XCTAssertFalse(app.buttons["Close player"].exists)
      XCTAssertEqual(mini.label, "Show playback controls")
    }
    waitForHiddenControls()
    capture("Mini-player with controls and shading hidden")
    mini.tap()
    XCTAssertTrue(pause.waitForExistence(timeout: 2))
    XCTAssertTrue(mini.exists, "The first tap reveals controls without expanding")
    XCTAssertEqual(mini.label, "Expand player")
    capture("Mini-player with localized button fades")
    mini.tap()
    XCTAssertFalse(mini.exists, "The next tap expands the player")
    waitForVideo(app)
    collapseWithChevron(app)
    pause.tap()
    XCTAssertEqual(pause.label, "Play")
    let disappearsWhilePaused = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pause)
    disappearsWhilePaused.isInverted = true
    waitForExpectations(timeout: 5)
    pause.tap()
    XCTAssertEqual(pause.label, "Pause")
    waitForHiddenControls()
    drag(mini, by: CGVector(dx: -40, dy: -60))
    XCTAssertTrue(pause.exists, "Moving the player reveals its controls")
    XCTAssertTrue(mini.exists)
    waitForHiddenControls()
    mini.pinch(withScale: 1.1, velocity: 0.8)
    XCTAssertTrue(pause.exists, "Resizing the player reveals its controls")
    XCTAssertTrue(mini.exists)
    app.buttons["Close player"].tap()
    XCTAssertFalse(mini.exists)
  }

  private func settledFrame(_ element: XCUIElement) -> CGRect {
    var previous = CGRect.null
    var unchangedSince = Date()
    let settled = NSPredicate { _, _ in
      let current = element.frame
      if abs(current.minX - previous.minX) > 0.1 || abs(current.minY - previous.minY) > 0.1
        || abs(current.width - previous.width) > 0.1 || abs(current.height - previous.height) > 0.1 {
        previous = current
        unchangedSince = Date()
      }
      return Date().timeIntervalSince(unchangedSince) >= 0.2
    }
    expectation(for: settled, evaluatedWith: element)
    waitForExpectations(timeout: 5)
    return element.frame
  }

  func testLeavingAppUsesNativePiPAndReturningRestoresTheMiniPlayer() throws {
    try requireLiveTests()
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_NATIVE_PIP_TESTS"] == "1" else {
      throw XCTSkip("Run native-background transitions on a PiP-capable destination.")
    }
    let app = launch()
    defer { app.terminate() }
    let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
    XCTAssertTrue(stream.waitForExistence(timeout: 45))
    stream.tap()
    waitForVideo(app)
    collapseWithChevron(app)
    let mini = app.buttons["mobile-expand-player"]
    drag(mini, by: CGVector(dx: -60, dy: -180))
    mini.pinch(withScale: 1.25, velocity: 0.8)
    let customized = mini.frame
    XCUIDevice.shared.press(.home)
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.activate()
    defer { settings.terminate() }
    XCTAssertTrue(settings.navigationBars.firstMatch.waitForExistence(timeout: 10))
    let pip = app.otherElements["PIPUIView"]
    capture("Native PiP over another app")
    XCTAssertTrue(pip.waitForExistence(timeout: 12), "Require a real system PiP window outside Strozz")
    app.activate()
    XCTAssertTrue(app.buttons["mobile-expand-player"].waitForExistence(timeout: 12))
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.otherElements["PIPUIView"])
    waitForExpectations(timeout: 12)
    XCTAssertFalse(app.alerts["Picture in Picture"].exists)
    XCTAssertEqual(mini.frame.minX, customized.minX, accuracy: 2)
    XCTAssertEqual(mini.frame.minY, customized.minY, accuracy: 2)
    XCTAssertEqual(mini.frame.width, customized.width, accuracy: 2)
    expandMiniPlayer(app)
    capture("Expanded player after native handoff")
  }

  func testNativeRestoreButtonReturnsDirectlyToExpandedPlayer() throws {
    try requireLiveTests()
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_NATIVE_PIP_TESTS"] == "1" else {
      throw XCTSkip("Run native restore on a PiP-capable destination.")
    }
    let app = launch()
    defer { app.terminate() }
    let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
    XCTAssertTrue(stream.waitForExistence(timeout: 45))
    stream.tap()
    waitForVideo(app)
    let surface = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let expandedFrame = surface.frame
    collapseWithChevron(app)
    let mini = app.buttons["mobile-expand-player"]
    drag(mini, by: CGVector(dx: -60, dy: -180))
    mini.pinch(withScale: 1.25, velocity: 0.8)
    let customized = mini.frame
    XCUIDevice.shared.press(.home)
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.activate()
    defer { settings.terminate() }
    let pip = app.otherElements["PIPUIView"]
    XCTAssertTrue(pip.waitForExistence(timeout: 12))
    pip.tap()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    capture("Native PiP restore controls")
    let restore = springboard.buttons["Restore fullscreen"]
    XCTAssertTrue(restore.waitForExistence(timeout: 5), springboard.debugDescription)
    restore.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pip)
    waitForExpectations(timeout: 12)
    XCTAssertFalse(app.buttons["mobile-expand-player"].exists)
    XCTAssertEqual(surface.frame.width, expandedFrame.width, accuracy: 1)
    XCTAssertEqual(surface.frame.height, expandedFrame.height, accuracy: 1)
    XCTAssertEqual(surface.frame.minX, expandedFrame.minX, accuracy: 1)
    XCTAssertEqual(surface.frame.minY, expandedFrame.minY, accuracy: 1)
    waitForVideo(app)
    capture("Direct expanded destination from native restore")
    collapseWithChevron(app)
    XCTAssertEqual(mini.frame.minX, customized.minX, accuracy: 2)
    XCTAssertEqual(mini.frame.minY, customized.minY, accuracy: 2)
    XCTAssertEqual(mini.frame.width, customized.width, accuracy: 2)
  }

  private func requireLiveTests() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set STROZZ_MOBILE_LIVE_TESTS=1 for live mini-player verification.")
    }
  }

  private func launch() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    return app
  }

  private func waitForVideo(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 10))
    let loading = app.descendants(matching: .any).matching(identifier: "mobile-video-loading").firstMatch
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
    waitForExpectations(timeout: 45)
    XCTAssertFalse(app.buttons["Try again"].exists)
  }

  private func collapseWithChevron(_ app: XCUIApplication) {
    if !app.buttons["mobile-minimize-player"].isHittable {
      app.buttons["mobile-controls-toggle"].tap()
    }
    app.buttons["mobile-minimize-player"].tap()
    XCTAssertTrue(app.buttons["mobile-expand-player"].waitForExistence(timeout: 10))
  }

  private func showMiniPlayerControls(_ app: XCUIApplication) {
    let pause = app.buttons["mobile-mini-play-pause"]
    if !pause.exists { app.buttons["mobile-expand-player"].tap() }
    XCTAssertTrue(pause.waitForExistence(timeout: 2))
  }

  private func expandMiniPlayer(_ app: XCUIApplication) {
    let mini = app.buttons["mobile-expand-player"]
    mini.tap()
    if mini.exists { mini.tap() }
    waitForVideo(app)
  }

  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}

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
    app.buttons["mobile-expand-player"].tap()
    waitForVideo(app)
    XCTAssertEqual(surface.frame.width, expanded.width, accuracy: 1)
    collapseWithChevron(app)
    app.buttons[first].tap()
    waitForVideo(app)
    collapseWithChevron(app)
    app.buttons[second].tap()
    waitForVideo(app)
    collapseWithChevron(app)
    capture("Replacement stream in the in-app player")
    app.buttons["Close player"].tap()
    XCTAssertFalse(app.buttons["mobile-expand-player"].exists)
    XCTAssertFalse(surface.exists)
    XCTAssertTrue(app.buttons[second].isHittable)
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
    app.buttons["mobile-expand-player"].tap()
    waitForVideo(app)
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
    let expandedSize = surface.frame.size
    collapseWithChevron(app)
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
    XCTAssertEqual(surface.frame.width, expandedSize.width, accuracy: 1)
    XCTAssertEqual(surface.frame.height, expandedSize.height, accuracy: 1)
    waitForVideo(app)
    capture("Direct expanded destination from native restore")
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

  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}

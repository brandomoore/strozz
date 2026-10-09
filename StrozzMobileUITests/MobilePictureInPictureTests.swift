import XCTest

@MainActor
final class MobilePictureInPictureTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testSwipeOverVideoReturnsToBrowseAndChevronCollapsesTheNextStream() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set STROZZ_MOBILE_LIVE_TESTS=1 for native Picture in Picture verification.")
    }
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
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
    let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.25))
    let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.9))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
    if app.alerts["Picture in Picture"].waitForExistence(timeout: 2) {
      let unsupported = app.staticTexts["Picture in Picture is not supported on this device."].exists
      capture(app, name: "PiP unavailable without dismissing the player")
      XCTAssertTrue(surface.exists)
      app.alerts.buttons["OK"].tap()
      if unsupported {
        throw XCTSkip("This runtime does not support native PiP; exercise the native transitions on a physical device.")
      }
      XCTFail("Native PiP did not start")
      return
    }
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: surface)
    waitForExpectations(timeout: 12)
    XCTAssertTrue(app.navigationBars[previousPage].waitForExistence(timeout: 12))
    let pip = app.otherElements["PIPUIView"]
    XCTAssertTrue(pip.waitForExistence(timeout: 10), "Require AVKit's actual floating window")
    capture(app, name: "Native PiP over originating category")
    let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let hierarchy = XCTAttachment(string: app.debugDescription + "\nSYSTEM:\n" + system.debugDescription)
    hierarchy.name = "Native PiP controls"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    XCTAssertTrue(app.buttons[first].waitForExistence(timeout: 10), "Return to the originating category, not Home")

    app.buttons[first].tap()
    waitForVideo(app)
    XCTAssertFalse(pip.exists, "Selecting the playing stream restores it inline")
    showControls(app)
    app.buttons["mobile-minimize-player"].tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: surface)
    waitForExpectations(timeout: 12)
    XCTAssertTrue(pip.waitForExistence(timeout: 10))

    app.buttons[second].tap()
    waitForVideo(app)
    showControls(app)
    app.buttons["mobile-minimize-player"].tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: surface)
    waitForExpectations(timeout: 12)
    XCTAssertTrue(app.navigationBars[previousPage].waitForExistence(timeout: 12))
    XCTAssertTrue(pip.waitForExistence(timeout: 10))
    capture(app, name: "Replacement stream in native PiP")
  }

  private func waitForVideo(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 10))
    let loading = app.descendants(matching: .any).matching(identifier: "mobile-video-loading").firstMatch
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
    waitForExpectations(timeout: 45)
    XCTAssertFalse(app.buttons["Try again"].exists)
    capture(app, name: "Inline video before PiP")
  }

  private func showControls(_ app: XCUIApplication) {
    if !app.buttons["mobile-minimize-player"].isHittable {
      app.buttons["mobile-controls-toggle"].tap()
    }
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}

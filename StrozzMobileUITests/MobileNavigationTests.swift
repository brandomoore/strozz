import XCTest

@MainActor
final class MobileNavigationTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testAccountThemesAndSignedOutFollowing() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    defer { app.terminate() }
    app.buttons["Following"].firstMatch.tap()
    XCTAssertTrue(app.buttons["Sign in to Twitch"].waitForExistence(timeout: 10))
    app.buttons["Account"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
    for theme in ["Light", "Dark", "OLED", "System"] {
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Theme")).firstMatch.tap()
      app.buttons[theme].firstMatch.tap()
      capture(app, name: "account-\(theme)")
    }
    XCTAssertTrue(app.switches["Sync chat to extra delay"].exists)
  }

  func testLiveBrowseSearchAndPlayerRotation() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set STROZZ_MOBILE_LIVE_TESTS=1 for the bounded network/UI smoke test.")
    }
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    defer {
      app.terminate()
      XCUIDevice.shared.orientation = .portrait
    }
    let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
    XCTAssertTrue(stream.waitForExistence(timeout: 45))
    capture(app, name: "live-feed")
    stream.tap()
    XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Stream chat"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Sign in to chat"].exists)
    let loaded = NSPredicate(format: "exists == false")
    let spinner = app.descendants(matching: .any).matching(identifier: "mobile-video-loading").firstMatch
    expectation(for: loaded, evaluatedWith: spinner)
    waitForExpectations(timeout: 45)
    XCTAssertFalse(app.buttons["Try again"].exists)
    capture(app, name: "portrait-player")
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    video.tap()
    let playPause = app.buttons["Play/Pause"]
    XCTAssertTrue(playPause.waitForExistence(timeout: 5))
    if playPause.label == "Play" { playPause.tap() }
    let fullscreen = app.buttons["Fullscreen Button"]
    XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
    fullscreen.tap()
    app.tap()
    capture(app, name: "native-fullscreen")
    let exitFullscreen = app.buttons["Close Button"]
    XCTAssertTrue(exitFullscreen.waitForExistence(timeout: 5))
    exitFullscreen.tap()
    XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
    video.tap()
    if playPause.waitForExistence(timeout: 5), playPause.label == "Play" { playPause.tap() }
    app.buttons["Playback quality"].tap()
    XCTAssertTrue(app.buttons["Auto - Standard"].waitForExistence(timeout: 5))
    capture(app, name: "quality-menu")
    app.buttons["Auto - Standard"].tap()
    expectation(for: loaded, evaluatedWith: spinner)
    waitForExpectations(timeout: 45)
    rotate(.landscapeLeft)
    expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
    waitForExpectations(timeout: 10)
    expectation(for: loaded, evaluatedWith: spinner)
    waitForExpectations(timeout: 45)
    if UIDevice.current.userInterfaceIdiom == .pad {
      let chat = app.descendants(matching: .any).matching(identifier: "mobile-chat-panel").firstMatch
      XCTAssertTrue(chat.exists)
      XCTAssertGreaterThanOrEqual(chat.frame.minX, video.frame.maxX - 2)
      XCTAssertLessThanOrEqual(chat.frame.maxX, app.frame.maxX + 2)
    } else {
      XCTAssertFalse(app.staticTexts["Stream chat"].exists)
    }
    capture(app, name: "landscape-player")
    XCTAssertTrue(app.buttons["Close player"].isHittable)
    app.buttons["Close player"].tap()
    rotate(.portrait)
    app.buttons["Browse"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Browse"].waitForExistence(timeout: 10))
    let categories = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'category-'"))
    XCTAssertTrue(categories.firstMatch.waitForExistence(timeout: 30))
    if UIDevice.current.userInterfaceIdiom == .phone {
      XCTAssertGreaterThanOrEqual(categories.count, 3)
      XCTAssertEqual(categories.element(boundBy: 0).frame.minY, categories.element(boundBy: 2).frame.minY, accuracy: 2)
      XCTAssertLessThan(categories.element(boundBy: 0).frame.maxX, categories.element(boundBy: 1).frame.minX)
    }
    capture(app, name: "categories")
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText("buddha")
    XCTAssertTrue(app.buttons["stream-buddha"].waitForExistence(timeout: 30))
    capture(app, name: "search")
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func rotate(_ orientation: UIDeviceOrientation) {
    XCUIDevice.shared.orientation = orientation
    let settled = expectation(description: "Rotation transition finished")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
    wait(for: [settled], timeout: 3)
  }
}

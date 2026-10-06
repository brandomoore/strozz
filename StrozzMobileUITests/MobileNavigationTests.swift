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
    showControls(app)
    capture(app, name: "portrait-player")
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let playPause = app.buttons["mobile-play-pause"]
    XCTAssertTrue(playPause.waitForExistence(timeout: 5))
    playPause.tap()
    XCTAssertEqual(playPause.label, "Play")
    playPause.tap()
    XCTAssertEqual(playPause.label, "Pause")
    let mute = app.buttons["Unmute"]
    XCTAssertTrue(mute.exists)
    mute.tap()
    XCTAssertTrue(app.buttons["Mute"].exists)
    app.buttons["Mute"].tap()
    let fullscreen = app.buttons["Fullscreen"]
    XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
    fullscreen.tap()
    let exitFullscreen = app.buttons["Exit fullscreen"]
    XCTAssertTrue(exitFullscreen.waitForExistence(timeout: 5))
    if UIDevice.current.userInterfaceIdiom == .phone {
      expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
      waitForExpectations(timeout: 10)
    }
    capture(app, name: "custom-fullscreen")
    exitFullscreen.tap()
    showControls(app)
    XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Back to live"].exists)
    XCTAssertTrue(app.buttons["Share stream"].exists)
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
    showControls(app)
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

  func testHomePlaysOnlyOneMutedPreviewWhileScrolling() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set STROZZ_MOBILE_LIVE_TESTS=1 for muted Home previews.")
    }
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    defer { app.terminate() }
    let previews = app.buttons.matching(NSPredicate(format: "value == 'Muted live preview'"))
    XCTAssertTrue(previews.firstMatch.waitForExistence(timeout: 35))
    XCTAssertEqual(previews.count, 1)
    let navigationBar = app.navigationBars["Strozz"]
    let firstCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
    XCTAssertLessThanOrEqual(navigationBar.frame.height, 60, "Home uses a compact navigation header")
    XCTAssertGreaterThanOrEqual(firstCard.frame.minY, navigationBar.frame.maxY)
    XCTAssertLessThanOrEqual(firstCard.frame.minY - navigationBar.frame.maxY, 16,
                            "Streams should start directly below the navigation bar")
    XCTAssertFalse(app.staticTexts["Live now"].exists)
    let first = previews.firstMatch.identifier
    capture(app, name: "home-muted-preview")
    app.scrollViews.firstMatch.swipeUp()
    let next = previews.matching(NSPredicate(format: "identifier != %@", first)).firstMatch
    XCTAssertTrue(next.waitForExistence(timeout: 35))
    XCTAssertEqual(previews.count, 1)
    let selected = app.buttons[next.identifier]
    XCTAssertTrue(selected.isHittable, "The preview must belong to an on-screen card")
    capture(app, name: "home-next-preview")
    selected.tap()
    XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
    XCTAssertEqual(previews.count, 0)
    app.buttons["Close player"].tap()
    app.buttons["Browse"].firstMatch.tap()
    XCTAssertEqual(previews.count, 0)
  }

  private func showControls(_ app: XCUIApplication) {
    if !app.buttons["mobile-play-pause"].exists {
      app.descendants(matching: .any).matching(identifier: "mobile-controls-toggle").firstMatch.tap()
    }
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

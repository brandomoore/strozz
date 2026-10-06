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
    for title in ["Home", "Browse", "Account"] { XCTAssertTrue(app.buttons[title].firstMatch.exists) }
    if UIDevice.current.userInterfaceIdiom == .phone {
      XCTAssertEqual(app.tabBars.buttons.count, 3)
      XCTAssertFalse(app.tabBars.buttons["Following"].exists)
    }
    app.segmentedControls.buttons["Following"].tap()
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
    // Pause keeps controls visible while screenshots and rotation are inspected.
    playPause.tap()
    XCTAssertEqual(playPause.label, "Play")
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
    showControls(app)
    exitFullscreen.tap()
    showControls(app)
    XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
    XCTAssertEqual(playPause.label, "Play", "Fullscreen must preserve the paused state")
    playPause.tap()
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
    let heading = app.staticTexts["mobile-home-heading"]
    let filters = app.scrollViews["mobile-home-filters"]
    let firstCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
    XCTAssertTrue(heading.isHittable)
    XCTAssertFalse(app.navigationBars["Strozz"].exists)
    XCTAssertEqual(heading.frame.minX, firstCard.frame.minX, accuracy: 1)
    XCTAssertGreaterThanOrEqual(firstCard.frame.minY, filters.frame.maxY)
    XCTAssertLessThanOrEqual(firstCard.frame.minY - filters.frame.maxY, 20,
                            "Streams should follow the compact Home controls")
    let channelKey = String(firstCard.identifier.dropFirst("stream-".count))
    let artwork = app.descendants(matching: .any).matching(identifier: "artwork-\(channelKey)").firstMatch
    let viewers = app.descendants(matching: .any).matching(identifier: "viewers-\(channelKey)").firstMatch
    XCTAssertTrue(artwork.exists)
    XCTAssertTrue(viewers.exists)
    XCTAssertLessThan(viewers.frame.midX, artwork.frame.midX)
    XCTAssertGreaterThan(viewers.frame.midY, artwork.frame.midY)
    XCTAssertEqual(viewers.frame.maxY, artwork.frame.maxY, accuracy: 8)
    XCTAssertFalse(app.staticTexts["Live now"].exists)
    let first = previews.firstMatch.identifier
    capture(app, name: "home-muted-preview")
    app.scrollViews.firstMatch.swipeUp()
    XCTAssertFalse(heading.exists && heading.isHittable, "The Home heading must scroll away with the feed")
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
    XCTAssertTrue(app.navigationBars["Browse"].waitForExistence(timeout: 5))
    XCTAssertEqual(previews.count, 0)
  }

  func testHomeCategoryFiltersAndFeedSwitching() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set STROZZ_MOBILE_LIVE_TESTS=1 for Home category filtering.")
    }
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    defer { app.terminate() }
    let filter = app.buttons.matching(NSPredicate(
      format: "identifier BEGINSWITH 'home-filter-' AND identifier != 'home-filter-all'")).firstMatch
    XCTAssertTrue(filter.waitForExistence(timeout: 30))
    let category = filter.label
    filter.tap()
    let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
    XCTAssertTrue(stream.waitForExistence(timeout: 30))
    XCTAssertTrue(stream.label.contains(category))
    capture(app, name: "home-category")
    app.segmentedControls.buttons["Following"].tap()
    XCTAssertTrue(app.buttons["Sign in to Twitch"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "value == 'Muted live preview'")).count, 0)
    app.buttons["Sign in to Twitch"].tap()
    XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
    app.buttons["Home"].firstMatch.tap()
    app.segmentedControls.buttons["Live"].tap()
    app.buttons["home-filter-all"].tap()
    XCTAssertTrue(stream.waitForExistence(timeout: 30))
  }

  private func showControls(_ app: XCUIApplication) {
    let playPause = app.buttons["mobile-play-pause"]
    if playPause.exists && playPause.label == "Play" { return }
    let toggle = app.descendants(matching: .any).matching(identifier: "mobile-controls-toggle").firstMatch
    // Refresh the timeout using video space that isn't covered by Play/Pause.
    let videoSpace = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.4))
    if playPause.exists { videoSpace.tap() }
    if !playPause.exists { videoSpace.tap() }
    XCTAssertTrue(playPause.exists)
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

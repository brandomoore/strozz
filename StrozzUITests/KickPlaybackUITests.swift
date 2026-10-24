import XCTest

final class KickPlaybackUITests: XCTestCase {
  #if os(iOS)
    @MainActor
    func testKickDirectoryKeepsRootNavigationAvailable() {
      let app = XCUIApplication()
      app.launch()
      defer { app.terminate() }
      let sidebar = app.buttons["sidebar-kick"]
      if sidebar.waitForExistence(timeout: 5) {
        sidebar.tap()
        XCTAssertTrue(app.buttons["kick-find-channel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sidebar-home"].exists)
        screenshot("Kick with tablet navigation", app: app)
        app.buttons["sidebar-home"].tap()
      } else {
        let kick = app.tabBars.buttons["Kick"]
        XCTAssertTrue(kick.waitForExistence(timeout: 10))
        kick.tap()
        XCTAssertTrue(app.buttons["kick-find-channel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        screenshot("Kick with compact navigation", app: app)
        app.tabBars.buttons["Home"].tap()
      }
      XCTAssertFalse(app.buttons["kick-find-channel"].isHittable)
    }
  #endif

  #if os(tvOS)
    @MainActor
    func testTwitchPlayerCanHandOffToKickAndReturnToItsOriginalControls() throws {
      let app = XCUIApplication()
      app.launchEnvironment["STROZZ_PLAYER_UI_CHANNEL"] = "xqc"
      app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
      app.launch()
      defer { app.terminate() }
      let quality = app.descendants(matching: .any)["player-quality-menu"].firstMatch
      for _ in 0..<12 {
        XCUIRemote.shared.press(.up)
        if quality.waitForExistence(timeout: 3) { break }
      }
      XCTAssertTrue(quality.exists)
      activate(quality)
      let source = app.descendants(matching: .any).matching(
        NSPredicate(format: "label BEGINSWITH 'Source'")
      ).firstMatch
      XCTAssertTrue(source.waitForExistence(timeout: 5))
      activate(source)
      activate(app.buttons["Kick"].firstMatch)
      let close = app.buttons["platform-live-close"]
      XCTAssertTrue(close.waitForExistence(timeout: 20))
      screenshot("Twitch to Kick handoff", app: app)
      activate(close)
      for _ in 0..<10 {
        XCUIRemote.shared.press(.up)
        if quality.waitForExistence(timeout: 3) { break }
      }
      XCTAssertTrue(quality.exists)
      let video = app.descendants(matching: .any)["player-video-surface"].firstMatch
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == 'Ready'"), object: video)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed)
      screenshot("Original Twitch controls restored", app: app)
    }
  #endif

  @MainActor
  func testKickChannelCanOpenAndSwitchSourceWithoutReturningToBrowsing() throws {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_KICK_UI_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    defer { app.terminate() }
    let find = app.buttons["kick-find-channel"]
    XCTAssertTrue(find.waitForExistence(timeout: 15))
    activate(find)
    let watch = app.buttons["kick-watch-live"]
    XCTAssertTrue(
      watch.waitForExistence(timeout: 30),
      "Ordinary public channel access must find a live Kick channel")
    screenshot("Kick channel lookup", app: app)
    activate(watch)
    let source = app.buttons["platform-live-source"]
    XCTAssertTrue(source.waitForExistence(timeout: 20))
    let pause = app.buttons["platform-live-pause"]
    XCTAssertTrue(pause.waitForExistence(timeout: 5))
    XCTAssertTrue(pause.isHittable)
    activate(pause)
    XCTAssertEqual(pause.label, "Play")
    screenshot("Kick paused player", app: app)
    activate(source)
    XCTAssertTrue(
      app.descendants(matching: .any)["platform-source-target"].firstMatch.waitForExistence(
        timeout: 5))
    XCTAssertTrue(app.buttons["platform-source-switch"].exists)
    screenshot("Kick source editor", app: app)
    activate(app.buttons["Cancel"])
    XCTAssertTrue(app.buttons["platform-live-close"].waitForExistence(timeout: 5))
    activate(source)
    #if os(tvOS)
      activate(app.cells["Platform"].firstMatch)
    #else
      activate(app.descendants(matching: .any)["platform-source-platform"].firstMatch)
    #endif
    activate(app.descendants(matching: .any)["Twitch"].firstMatch)
    activate(app.buttons["platform-source-switch"].firstMatch)
    let status = app.staticTexts["platform-live-source-status"]
    let twitch = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label BEGINSWITH 'Twitch'"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [twitch], timeout: 10), .completed)
    XCTAssertEqual(pause.label, "Play", "Switching providers must preserve explicit pause intent")
    activate(source)
    activate(app.buttons["Kick: xqc"].firstMatch)
    let kick = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label BEGINSWITH 'Kick'"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [kick], timeout: 10), .completed)
    screenshot("Kick restored after Twitch source", app: app)
    activate(app.buttons["platform-live-close"])
    XCTAssertTrue(find.waitForExistence(timeout: 10))
  }

  @MainActor
  private func activate(_ element: XCUIElement) {
    #if os(tvOS)
      for direction in [XCUIRemote.Button.right, .left, .up, .down] {
        for step in 0...4 {
          if element.hasFocus
            || element.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
              .count > 0
            || XCUIApplication().cells.matching(NSPredicate(format: "hasFocus == true"))
              .containing(
                .any, identifier: element.identifier.isEmpty ? element.label : element.identifier
              ).count > 0
          {
            XCUIRemote.shared.press(.select)
            return
          }
          if step < 4 { XCUIRemote.shared.press(direction) }
        }
      }
      let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      XCTFail("Cannot navigate to \(element.label)")
    #else
      element.tap()
    #endif
  }

  @MainActor
  private func screenshot(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

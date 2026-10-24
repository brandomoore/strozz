import XCTest

final class KickPlaybackUITests: XCTestCase {
  private var kickChannel: String {
    ProcessInfo.processInfo.environment["STROZZ_KICK_CHANNEL"] ?? "xqc"
  }
  private var twitchChannel: String {
    ProcessInfo.processInfo.environment["STROZZ_KICK_SWITCH_TWITCH_CHANNEL"] ?? kickChannel
  }
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
      app.launchEnvironment["STROZZ_PLAYER_UI_CHANNEL"] = twitchChannel
      app.launchEnvironment["STROZZ_PLAYER_UI_KICK_TARGET"] = kickChannel
      app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
      app.launch()
      defer { app.terminate() }
      let video = app.descendants(matching: .any)["player-video-surface"].firstMatch
      waitForReady(video, platform: "Twitch")
      let quality = app.descendants(matching: .any)["player-quality-menu"].firstMatch
      revealTVControls(quality)
      XCTAssertTrue(quality.exists)
      activate(quality)
      let source = app.descendants(matching: .any).matching(
        NSPredicate(format: "label BEGINSWITH 'Source'")
      ).firstMatch
      XCTAssertTrue(source.waitForExistence(timeout: 5))
      activate(source)
      activate(app.buttons["Kick"].firstMatch)
      waitForReady(video, platform: "Kick")
      XCTAssertFalse(app.buttons["platform-live-close"].exists)
      screenshot("Twitch to Kick handoff", app: app)
      for _ in 0..<3 {
        if source.exists { XCUIRemote.shared.press(.menu) }
        else { break }
      }
      revealTVControls(quality)
      activate(quality)
      activate(app.descendants(matching: .any).matching(
        NSPredicate(format: "label BEGINSWITH 'Source'")).firstMatch)
      activate(app.descendants(matching: .any)["Twitch"].firstMatch)
      waitForReady(video, platform: "Twitch")
      screenshot("Same player switched back to Twitch", app: app)
    }
  #endif

  @MainActor
  func testKickChannelCanOpenAndSwitchSourceWithoutReturningToBrowsing() throws {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_KICK_UI_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_KICK_CHANNEL"] = kickChannel
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
    #if os(tvOS)
      let video = app.descendants(matching: .any)["player-video-surface"].firstMatch
      waitForReady(video, platform: "Kick")
      let quality = app.descendants(matching: .any)["player-quality-menu"].firstMatch
      revealTVControls(quality)
      XCTAssertTrue(app.buttons["Chat Settings"].exists)
      XCTAssertFalse(app.buttons["platform-live-close"].exists)
      screenshot("Kick in the existing TV player", app: app)
      activate(quality)
      XCTAssertTrue(app.descendants(matching: .any).matching(
        NSPredicate(format: "label BEGINSWITH 'Source'")).firstMatch.waitForExistence(timeout: 5))
      screenshot("Existing TV quality menu for Kick", app: app)
      for _ in 0..<4 {
        XCUIRemote.shared.press(.menu)
        if find.isHittable { break }
      }
    #else
      let video = app.descendants(matching: .any)["mobile-video-surface"].firstMatch
      waitForReady(video, platform: "Kick")
      revealMobileControls(app)
      XCTAssertTrue(app.otherElements["mobile-player-chat-region"].exists)
      XCTAssertTrue(app.buttons["mobile-minimize-player"].exists)
      XCTAssertFalse(app.buttons["platform-live-close"].exists)
      screenshot("Kick in the existing mobile player", app: app)
      app.buttons["Playback quality"].tap()
      XCTAssertTrue(app.textFields["player-source-target"].waitForExistence(timeout: 5))
      screenshot("Existing mobile quality sheet for Kick", app: app)
      app.descendants(matching: .any)["player-source-platform"].firstMatch.tap()
      app.buttons["Twitch"].tap()
      let field = app.textFields["player-source-target"]
      let current = field.value as? String ?? kickChannel
      field.tap()
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + twitchChannel)
      app.buttons["player-source-switch"].tap()
      waitForReady(video, platform: "Twitch")
      revealMobileControls(app)
      app.buttons["Playback quality"].tap()
      app.buttons["Kick: \(kickChannel)"].tap()
      waitForReady(video, platform: "Kick")
      revealMobileControls(app)
      app.buttons["mobile-minimize-player"].tap()
      XCTAssertTrue(app.buttons["mobile-expand-player"].waitForExistence(timeout: 5))
      screenshot("Kick uses the existing mini-player", app: app)
      app.buttons["mobile-expand-player"].tap()
      revealMobileControls(app)
      app.buttons["Close player"].tap()
    #endif
    XCTAssertTrue(find.waitForExistence(timeout: 10))
  }

  @MainActor
  private func waitForReady(_ video: XCUIElement, platform: String) {
    XCTAssertTrue(video.waitForExistence(timeout: 30))
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == 'Ready' AND label == %@", "\(platform) stream"), object: video)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
  }

  #if os(tvOS)
  @MainActor
  private func revealTVControls(_ quality: XCUIElement) {
    for _ in 0..<8 {
      XCUIRemote.shared.press(.up)
      if quality.waitForExistence(timeout: 2) { return }
    }
    XCTFail("The existing player controls are missing")
  }
  #else
  @MainActor
  private func revealMobileControls(_ app: XCUIApplication) {
    if !app.buttons["Playback quality"].isHittable { app.buttons["mobile-controls-toggle"].tap() }
    XCTAssertTrue(app.buttons["Playback quality"].waitForExistence(timeout: 10))
  }
  #endif

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

import XCTest

@MainActor
final class CreatorChannelsUITests: XCTestCase {
  func testLinkedChannelsReachableWithRemoteAndRootIsReadOnly() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_PLAYER_UI_CHANNEL"] = "caedrel"
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES", "-showChatByDefault", "YES"]
    app.launch()
    defer { app.terminate() }
    let video = app.descendants(matching: .any)["player-video-surface"].firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 30))
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Ready'"), object: video)
    guard XCTWaiter.wait(for: [ready], timeout: 45) == .completed else {
      capture(app, "Live playback unavailable before TV editor check")
      throw XCTSkip("TV has no deterministic single-player fixture; live Twitch did not become ready.")
    }
    capture(app, "Existing TV player")
    let focus = app.descendants(matching: .any)["player-video-focus"].firstMatch
    guard focus.waitForExistence(timeout: 30) else {
      capture(app, "TV live playback did not expose video focus")
      throw XCTSkip("Live video unavailable; the Ready accessibility value alone does not prove playback.")
    }
    let settings = app.descendants(matching: .any)["Chat Settings"].firstMatch
    for _ in 0..<4 {
      XCUIRemote.shared.press(.up)
      if settings.waitForExistence(timeout: 2) { break }
    }
    capture(app, "TV controls before chat settings")
    XCTAssertTrue(settings.exists)
    activate(settings, app: app)
    let linked = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH 'Linked creator channels'")).firstMatch
    XCTAssertTrue(linked.waitForExistence(timeout: 5))
    capture(app, "TV chat settings before linked channels")
    activate(linked, app: app)
    let twitch = app.textFields["creator-twitch-target"]
    XCTAssertTrue(twitch.waitForExistence(timeout: 5))
    XCTAssertFalse(twitch.isEnabled, "The current/root Twitch channel must be read-only")
    XCTAssertEqual(twitch.value as? String, "caedrel")
    XCTAssertTrue(app.textFields["creator-kick-target"].isEnabled)
    XCTAssertTrue(app.textFields["creator-youtube-target"].isEnabled)
    capture(app, "TV linked channels editor")
    activate(app.buttons["Cancel"].firstMatch, app: app)
    XCTAssertTrue(linked.waitForExistence(timeout: 5))
    capture(app, "Cancel returns to TV chat settings")
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(video.exists)
    capture(app, "Existing TV player after editor")
  }

  private func activate(_ element: XCUIElement, app: XCUIApplication) {
    for direction in [XCUIRemote.Button.right, .left, .down, .up] {
      for step in 0...8 {
        if element.hasFocus
          || element.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).count > 0
          || app.cells.matching(NSPredicate(format: "hasFocus == true"))
            .containing(.any, identifier: element.identifier.isEmpty ? element.label : element.identifier).count > 0 {
          XCUIRemote.shared.press(.select)
          return
        }
        if step < 8 { XCUIRemote.shared.press(direction) }
      }
    }
    capture(app, "Remote focus failure")
    XCTFail("Cannot remotely focus \(element.label)")
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name) hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }
}

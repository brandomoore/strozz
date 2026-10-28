import XCTest

@MainActor
final class CreatorChannelsUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testLinkedChannelsFromQualitySettings() {
    verifyEditor()
  }

  func testLinkedChannelsFromChatSettings() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["mobile-chat-settings"].waitForExistence(timeout: 10))
    capture(app, "Player before chat settings")
    app.buttons["mobile-chat-settings"].tap()
    XCTAssertTrue(app.navigationBars["Chat settings"].waitForExistence(timeout: 5))
    capture(app, "Chat settings initial position")
    let linked = app.buttons["Linked creator channels"]
    let form = app.descendants(matching: .any)["mobile-chat-settings-form"].firstMatch
    for _ in 0..<6 {
      if linked.exists && linked.isHittable { break }
      form.swipeUp()
    }
    capture(app, "Chat sources entry availability")
    XCTAssertTrue(linked.exists && linked.isHittable,
      "Active player Chat settings must expose Linked creator channels")
    linked.tap()
    XCTAssertTrue(app.textFields["creator-kick-target"].waitForExistence(timeout: 3))
    capture(app, "Linked creator editor from chat")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
    app.buttons["Done"].tap()
    XCTAssertTrue(app.otherElements["mobile-player-chat-region"].waitForExistence(timeout: 3))
  }

  func testLinkedChannelsInLightAppearanceWithLargeText() {
    verifyEditor(lightAndLargeText: true)
  }

  private func verifyEditor(lightAndLargeText: Bool = false) {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    if lightAndLargeText {
      app.launchEnvironment["STROZZ_PLAYER_THEME"] = "light"
      app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["Playback quality"].waitForExistence(timeout: 10))
    capture(app, "Existing player before editor")
    app.buttons["Playback quality"].tap()
    XCTAssertTrue(app.buttons["Linked creator channels"].waitForExistence(timeout: 5))
    capture(app, "Quality sheet entry")
    app.buttons["Linked creator channels"].tap()
    let kick = app.textFields["creator-kick-target"]
    XCTAssertTrue(kick.waitForExistence(timeout: 5))
    XCTAssertTrue(kick.isEnabled)
    XCTAssertTrue(app.textFields["creator-youtube-target"].isEnabled)
    // The layout fixture intentionally has no active creator session or root.
    capture(app, "Linked creator editor from quality")
    kick.tap()
    kick.typeText("https://example.com/not-a-kick-channel")
    capture(app, "Optional Kick field accepts editing")
    let save = app.buttons["creator-save-channels"]
    scrollTo(save, app: app)
    capture(app, "Save channels after scrolling")
    XCTAssertTrue(save.isHittable)
    save.tap()
    let error = app.staticTexts.matching(NSPredicate(
      format: "label CONTAINS[c] 'valid' OR label CONTAINS[c] 'kick.com'")).firstMatch
    XCTAssertTrue(error.waitForExistence(timeout: 3), "Validation error must be visible")
    capture(app, "Invalid link validation")
    let cancel = app.buttons["Cancel"]
    scrollTo(cancel, app: app)
    cancel.tap()
    XCTAssertTrue(app.navigationBars["Playback quality"].waitForExistence(timeout: 3))
    capture(app, "Cancel returns to quality")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["mobile-chat-settings"].waitForExistence(timeout: 5))
    capture(app, "Existing player after quality editor")
    app.buttons["Playback quality"].tap()
    app.buttons["Linked creator channels"].tap()
    XCTAssertTrue(kick.waitForExistence(timeout: 3))
    XCTAssertEqual(kick.value as? String, "Kick channel", "Cancel must discard the draft")
    capture(app, "Reopened editor discards cancelled draft")
    scrollTo(cancel, app: app)
    cancel.tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
    app.buttons["Done"].tap()
    XCTAssertTrue(app.otherElements["mobile-player-chat-region"].waitForExistence(timeout: 3))
    capture(app, "Existing player after cancelling editor twice")
  }

  private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<6 {
      if element.exists && element.isHittable { return }
      let form = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
      let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
      start.press(forDuration: 0.05,
        thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
    }
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

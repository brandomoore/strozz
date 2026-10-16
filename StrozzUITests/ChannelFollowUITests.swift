import XCTest

@MainActor
final class ChannelFollowUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testFollowUnfollowAndFocusAcrossThemes() {
    #if os(tvOS)
    let opacityModes = [false, true]
    #else
    let opacityModes = [false]
    #endif
    for theme in ["system", "dark", "oled", "light"] {
      for opaque in opacityModes {
        let app = launch(theme: theme, opaque: opaque)
        let follow = app.buttons["channel-follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 10))
        wait(for: follow, key: "label", value: "Follow")
        #if os(tvOS)
        waitForFocus(follow)
        XCUIRemote.shared.press(.select)
        #else
        follow.tap()
        #endif
        wait(for: follow, key: "label", value: "Following")
        wait(for: app.staticTexts["follow-list-state"], key: "label", value: "Following list updated")
        #if os(tvOS)
        XCTAssertTrue(follow.hasFocus, "Changing follow state must not move focus")
        XCUIRemote.shared.press(.select)
        #else
        follow.tap()
        #endif
        let unfollow = app.buttons["Unfollow"].firstMatch
        XCTAssertTrue(unfollow.waitForExistence(timeout: 5))
        #if os(tvOS)
        activate(app.buttons["Cancel"].firstMatch)
        #else
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        else { app.otherElements["PopoverDismissRegion"].firstMatch.tap() }
        #endif
        XCTAssertEqual(follow.label, "Following")
        activate(follow)
        XCTAssertTrue(unfollow.waitForExistence(timeout: 5))
        activate(unfollow)
        wait(for: follow, key: "label", value: "Follow")
        wait(for: app.staticTexts["follow-list-state"], key: "label", value: "Not in Following")
        #if os(tvOS)
        XCTAssertTrue(follow.hasFocus)
        #endif
        XCTAssertTrue(follow.isHittable)
        XCTAssertTrue(app.frame.contains(follow.frame))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "follow-\(theme)-opaque-\(opaque)"
        image.lifetime = .keepAlways
        add(image)
        app.terminate()
      }
    }
  }

  func testSignedOutAndRewardsConnectionNotices() {
    for setting in ["STROZZ_FOLLOW_SIGNED_OUT", "STROZZ_FOLLOW_DISCONNECTED"] {
      let app = launch(extra: [setting: "1"])
      defer { app.terminate() }
      let follow = app.buttons["channel-follow"]
      XCTAssertTrue(follow.waitForExistence(timeout: 10))
      activate(follow)
      XCTAssertTrue(app.alerts["Twitch following"].waitForExistence(timeout: 5))
      if setting == "STROZZ_FOLLOW_DISCONNECTED" {
        XCTAssertTrue(app.buttons["Connect Twitch Rewards"].firstMatch.exists)
      } else {
        XCTAssertFalse(app.buttons["Connect Twitch Rewards"].firstMatch.exists)
      }
      activate(app.buttons["Cancel"].firstMatch)
      XCTAssertEqual(app.staticTexts["follow-list-state"].label, "Not in Following")
    }
  }

  private func launch(
    theme: String = "system", opaque: Bool = false, extra: [String: String] = [:]
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = [
      "STROZZ_FOLLOW_FIXTURE": "1", "STROZZ_FOLLOW_THEME": theme,
      "STROZZ_FOLLOW_OPAQUE": opaque ? "1" : "0",
    ].merging(extra) { _, new in new }
    app.launch()
    return app
  }

  private func wait(for element: XCUIElement, key: String, value: String) {
    let predicate = NSPredicate(format: "%K == %@", key, value)
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
      timeout: 8), .completed)
  }

  private func activate(_ element: XCUIElement) {
    #if os(tvOS)
    // Native tvOS confirmation actions sit side by side; the page controls are vertical.
    for direction in [XCUIRemote.Button.right, .left, .up, .down] {
      for step in 0...3 {
        if element.hasFocus || element.buttons.matching(NSPredicate(format: "hasFocus == true")).count > 0 {
          XCUIRemote.shared.press(.select)
          return
        }
        if step < 3 { XCUIRemote.shared.press(direction) }
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

  #if os(tvOS)
  private func waitForFocus(_ element: XCUIElement) {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
  }
  #endif
}

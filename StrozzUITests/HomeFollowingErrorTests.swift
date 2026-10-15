import XCTest

@MainActor
final class HomeFollowingErrorTests: XCTestCase {
  private func launch(theme: String = "dark", opaque: Bool = true,
                      keepChannels: Bool = false, gated: Bool = false) throws -> XCUIApplication {
    guard ProcessInfo.processInfo.environment["STROZZ_HOME_ERROR_TESTS"] == "1" else {
      throw XCTSkip("Enable the deterministic Home error fixture on an owned simulator.")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_HOME_ERROR_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_HOME_ERROR_THEME"] = theme
    app.launchEnvironment["STROZZ_HOME_ERROR_OPAQUE"] = opaque ? "1" : "0"
    app.launchEnvironment["STROZZ_HOME_ERROR_KEEP_CHANNELS"] = keepChannels ? "1" : "0"
    app.launchEnvironment["STROZZ_HOME_ERROR_GATE"] = gated ? "1" : "0"
    app.launch()
    let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Following 1")).firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 10))
    waitForFocus(card)
    return app
  }

  private func waitForFocus(_ element: XCUIElement) {
    expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: element)
    waitForExpectations(timeout: 5)
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testErrorKeepsFollowingVisibleAndRetryDoesNotReportFalseSuccess() throws {
    for theme in ["system", "dark", "oled", "light"] {
      for opaque in [false, true] {
        let app = try launch(theme: theme, opaque: opaque, gated: true)
        defer { app.terminate() }
        let title = app.staticTexts["following-title"]
        let initialY = title.frame.minY
        XCUIRemote.shared.press(.playPause)
        let status = app.descendants(matching: .any).matching(identifier: "following-status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        waitForFocus(status)
        XCUIRemote.shared.press(.playPause)
        let retry = app.buttons["following-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        waitForFocus(retry)
        let error = app.staticTexts["following-error"]
        XCTAssertTrue(error.exists)
        XCTAssertTrue(error.label.contains("Secure credential storage is unavailable"))
        XCTAssertGreaterThanOrEqual(error.frame.minY, 0)
        XCTAssertLessThanOrEqual(error.frame.maxY, app.frame.maxY)
        XCTAssertEqual(title.frame.minY, initialY, accuracy: 3,
          "An error must not scroll Following away into the next rail")
        capture(app, name: "Following error \(theme) opaque \(opaque)")
        XCUIRemote.shared.press(.select)
        let refresh = app.buttons["following-refresh"]
        waitForFocus(refresh)
        XCTAssertTrue(app.staticTexts["Refresh failed"].waitForExistence(timeout: 5))
        XCTAssertTrue(error.exists)
        XCTAssertFalse(app.staticTexts["Refreshed"].exists)
        XCUIRemote.shared.press(.select)
        let restored = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Following 1")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: error)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(refresh.hasFocus, "Recovery must not reset the viewer's focus")
      }
    }
  }

  func testFailedRefreshKeepsTheFocusedCachedChannel() throws {
    let app = try launch(theme: "light", opaque: true, keepChannels: true)
    defer { app.terminate() }
    XCUIRemote.shared.press(.right)
    let second = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Following 2")).firstMatch
    waitForFocus(second)
    XCUIRemote.shared.press(.playPause)
    let error = app.staticTexts["following-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 5))
    XCTAssertTrue(second.hasFocus)
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Following 1")).firstMatch.exists)
    XCTAssertGreaterThanOrEqual(error.frame.minY, 0)
    XCTAssertLessThanOrEqual(error.frame.maxY, app.frame.maxY)
    capture(app, name: "Cached Following remains usable after refresh failure")
  }

  func testBackgroundErrorDoesNotStealFocusAndFollowingRemainsReachableAbove() throws {
    let app = try launch()
    defer { app.terminate() }
    XCUIRemote.shared.press(.down)
    let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Recommended 1")).firstMatch
    waitForFocus(first)
    XCUIRemote.shared.press(.right)
    XCUIRemote.shared.press(.right)
    let third = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Recommended 3")).firstMatch
    waitForFocus(third)
    XCUIRemote.shared.press(.playPause)
    XCTAssertTrue(app.buttons["following-retry"].waitForExistence(timeout: 5))
    XCTAssertTrue(third.hasFocus, "A background failure must not pull the viewer out of another rail")
    XCUIRemote.shared.press(.up)
    expectation(for: NSPredicate { _, _ in
      app.buttons["following-retry"].hasFocus || app.buttons["following-refresh"].hasFocus
        || app.buttons["following-directory"].hasFocus
    }, evaluatedWith: app)
    waitForExpectations(timeout: 5)
    XCTAssertGreaterThanOrEqual(app.staticTexts["following-error"].frame.minY, 0)
    capture(app, name: "Remote Up returns to the Following error section")
  }
}

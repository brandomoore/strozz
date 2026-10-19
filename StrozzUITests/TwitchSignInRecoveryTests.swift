import XCTest

@MainActor
final class TwitchSignInRecoveryTests: XCTestCase {
  func testBlockedSignInShowsReadableRecoveryAndNoUnissuedQRCode() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_SIGN_IN_TESTS"] == "1" else {
      throw XCTSkip("Enable the synthetic sign-in fixture on an owned TV simulator.")
    }
    continueAfterFailure = false
    for theme in ["system", "dark", "oled", "light"] {
      for opaque in [false, true] {
        let app = XCUIApplication()
        app.launchEnvironment["STROZZ_SIGN_IN_FIXTURE"] = "1"
        app.launchEnvironment["STROZZ_SIGN_IN_BLOCKED"] = "1"
        app.launchEnvironment["STROZZ_SIGN_IN_THEME"] = theme
        app.launchEnvironment["STROZZ_SIGN_IN_OPAQUE"] = opaque ? "1" : "0"
        app.launch()
        defer { app.terminate() }
        let fresh = app.buttons["twitch-sign-in-fresh"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 10))
        let error = app.staticTexts["twitch-sign-in-error"]
        XCTAssertTrue(error.exists)
        XCTAssertFalse(error.label.contains("Another device"))
        XCTAssertFalse(app.images["twitch-sign-in-qr"].exists)
        XCTAssertFalse(app.staticTexts["Getting your code…"].exists)
        for element in [fresh, error] {
          XCTAssertGreaterThanOrEqual(element.frame.minY, 0)
          XCTAssertLessThanOrEqual(element.frame.maxY, app.frame.maxY)
          XCTAssertGreaterThanOrEqual(element.frame.minX, 0)
          XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
        }
        capture(app, name: "Recovery \(theme) opaque=\(opaque)")
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: fresh)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["TEST-CODE"].waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
        capture(app, name: "Issued white QR \(theme) opaque=\(opaque)")
      }
    }
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

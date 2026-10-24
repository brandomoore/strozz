import XCTest

@MainActor
final class MultiviewStatusTests: XCTestCase {
  func testOfflineAndFailureMessagesKeepRemoteRetryAcrossThemesAndTileSizes() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_STATUS_TESTS"] == "1" else {
      throw XCTSkip("Enable the synthetic multiview-status fixture on an owned simulator.")
    }
    continueAfterFailure = false
    for theme in ["system", "dark", "oled", "light"] {
      for opaque in [false, true] {
        for compact in [false, true] {
          for failed in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_FIXTURE"] = "1"
            app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_THEME"] = theme
            app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_OPAQUE"] = opaque ? "1" : "0"
            app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_COMPACT"] = compact ? "1" : "0"
            app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_FAILURE"] = failed ? "1" : "0"
            app.launch()
            defer { app.terminate() }
            let pane = app.buttons["multiview-status-pane"]
            XCTAssertTrue(pane.waitForExistence(timeout: 10))
            expectation(for: NSPredicate(format: "value == %@", failed ? "Unavailable" : "Offline"), evaluatedWith: pane)
            expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: pane)
            waitForExpectations(timeout: 5)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(theme) opaque=\(opaque) compact=\(compact) failed=\(failed)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCUIRemote.shared.press(.select)
            let retries = app.staticTexts["multiview-status-retries"]
            expectation(for: NSPredicate(format: "label == %@", "Retries: 1"), evaluatedWith: retries)
            waitForExpectations(timeout: 5)
          }
        }
      }
    }
  }
}

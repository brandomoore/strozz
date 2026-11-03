import XCTest

@MainActor
final class MultiviewStatusTests: XCTestCase {
  func testOfflineActionsFitSmallPanesAndRemainReachable() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_STATUS_TESTS"] == "1" else {
      throw XCTSkip("Enable the synthetic multiview-status fixture on an owned simulator.")
    }
    continueAfterFailure = false
    for size in [CGSize(width: 300, height: 169), .init(width: 500, height: 281),
      .init(width: 600, height: 338), .init(width: 640, height: 360), .init(width: 800, height: 450)] {
      let app = XCUIApplication()
      app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_FIXTURE"] = "1"
      app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_WIDTH"] = "\(size.width)"
      app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_HEIGHT"] = "\(size.height)"
      app.launch()
      defer { app.terminate() }
      let pane = app.buttons["multiview-status-pane"]
      XCTAssertTrue(pane.waitForExistence(timeout: 10))
      expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: pane)
      waitForExpectations(timeout: 5)
      let tile = app.otherElements["multiview-status-tile"]
      let profile = app.buttons.matching(identifier: "multiview-profile-status-fixture").firstMatch
      let remove = app.buttons.matching(identifier: "multiview-remove-status-fixture").firstMatch
      XCTAssertTrue(profile.waitForExistence(timeout: 5))
      XCTAssertTrue(remove.exists)
      XCUIRemote.shared.press(.down)
      expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: profile)
      waitForExpectations(timeout: 5)
      for action in [profile, remove] {
        XCTAssertLessThanOrEqual(action.frame.height, 80, "Actions must not wrap into tall buttons")
        XCTAssertGreaterThanOrEqual(action.frame.minX, tile.frame.minX)
        XCTAssertLessThanOrEqual(action.frame.maxX, tile.frame.maxX)
        XCTAssertGreaterThanOrEqual(action.frame.minY, pane.frame.maxY)
        XCTAssertLessThanOrEqual(action.frame.maxY, tile.frame.maxY)
      }
      XCTAssertLessThan(profile.frame.maxX, remove.frame.minX)
      XCUIRemote.shared.press(.select)
      let actions = app.staticTexts["multiview-status-actions"]
      expectation(for: NSPredicate(format: "label == %@", "Profiles: 1, removals: 0"), evaluatedWith: actions)
      waitForExpectations(timeout: 5)
      XCUIRemote.shared.press(.right)
      expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: remove)
      waitForExpectations(timeout: 5)
      XCUIRemote.shared.press(.select)
      expectation(for: NSPredicate(format: "label == %@", "Profiles: 1, removals: 1"), evaluatedWith: actions)
      waitForExpectations(timeout: 5)
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = "Offline actions \(Int(size.width))x\(Int(size.height))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

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

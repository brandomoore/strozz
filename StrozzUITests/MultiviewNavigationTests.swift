import XCTest

@MainActor
final class MultiviewNavigationTests: XCTestCase {
  func testOptInRemoteOpensNormalControlsAndReturnsToTheSamePane() throws {
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_MULTIVIEW_UI_TESTS"] == "1",
      let channels = settings["STROZZ_MATRIX_CHANNELS"],
      let selected = channels.split(separator: ",").dropFirst().first else {
      throw XCTSkip("Explicitly select live multiview channels for the remote navigation check.")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MULTIVIEW_UI_CHANNELS"] = channels
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES"]
    app.launch()
    defer { app.terminate() }
    let pane = app.buttons["multiview-pane-\(selected)"].firstMatch
    XCTAssertTrue(pane.waitForExistence(timeout: 30))
    expectation(for: NSPredicate(format: "value == %@", "Live"), evaluatedWith: pane)
    waitForExpectations(timeout: 45)
    XCUIRemote.shared.press(.right)
    expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: pane)
    waitForExpectations(timeout: 5)
    capture(app, name: "Remote native multiview")
    XCUIRemote.shared.press(.select)
    let expanded = app.descendants(matching: .any).matching(identifier: "expanded-stream-\(selected)").firstMatch
    XCTAssertTrue(expanded.waitForExistence(timeout: 5))
    expectation(for: NSPredicate(format: "value == %@", "Live"), evaluatedWith: expanded)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "player-video-focus")
      .firstMatch.waitForExistence(timeout: 5))
    XCUIRemote.shared.press(.up)
    let quality = app.buttons["player-quality-menu"].firstMatch
    XCTAssertTrue(quality.waitForExistence(timeout: 5))
    if app.buttons["Channel info"].hasFocus {
      XCUIRemote.shared.press(.right)
    }
    capture(app, name: "Remote expanded normal player")
    XCUIRemote.shared.press(.select)
    let engineStatus = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Native LL-HLS"))
      .firstMatch
    XCTAssertTrue(engineStatus.waitForExistence(timeout: 5))
    XCUIRemote.shared.press(.menu)
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: engineStatus)
    waitForExpectations(timeout: 5)
    capture(app, name: "After closing quality menu")
    XCTAssertTrue(expanded.exists, "Closing the quality menu must not close multiview")
    XCUIRemote.shared.press(.menu)
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: quality)
    waitForExpectations(timeout: 5)
    capture(app, name: "Expanded video with controls hidden")
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(pane.waitForExistence(timeout: 5))
    expectation(for: NSPredicate(format: "value == %@", "Live"), evaluatedWith: pane)
    waitForExpectations(timeout: 5)
    expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: pane)
    waitForExpectations(timeout: 5)
    capture(app, name: "Remote returned multiview")
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(expanded.waitForExistence(timeout: 5), "Return must focus the same stream, not another pane")
    expectation(for: NSPredicate(format: "value == %@", "Live"), evaluatedWith: expanded)
    waitForExpectations(timeout: 5)
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(pane.waitForExistence(timeout: 5))
    expectation(for: NSPredicate(format: "value == %@", "Live"), evaluatedWith: pane)
    waitForExpectations(timeout: 5)
    XCUIRemote.shared.press(.playPause)
    XCTAssertTrue(app.buttons["Spotlight"].waitForExistence(timeout: 5))
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

}

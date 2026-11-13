import XCTest

@MainActor
final class StreamCategoryUITests: XCTestCase {
  func testLongPressNavigatesToCategoryAndBack() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["STROZZ_RUN_LIVE_CATEGORY_UI_TESTS"] == "1",
      "Requires live Twitch category resolution.")
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_CATEGORY_UI_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate() }
    let card = app.descendants(matching: .any)["category-fixture-card"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 10))
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    let action = app.descendants(matching: .any)["stream-go-to-category-categoryfixture"].firstMatch
    XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(action.label, "Go to Just Chatting")
    let actionCell = app.cells.containing(.any, identifier: "stream-go-to-category-categoryfixture").firstMatch
    for _ in 0..<4 where !actionCell.hasFocus { XCUIRemote.shared.press(.down) }
    XCTAssertTrue(actionCell.hasFocus)
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.buttons["Refresh"].waitForExistence(timeout: 25), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Just Chatting"].firstMatch.exists)
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    XCTAssertTrue(action.waitForExistence(timeout: 5), "Back must restore a usable card focus.")
    XCUIRemote.shared.press(.menu)
  }
}

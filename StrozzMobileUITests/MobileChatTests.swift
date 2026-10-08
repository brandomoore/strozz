import XCTest

@MainActor
final class MobileChatTests: XCTestCase {
  func testJumpToPresentAfterScrollingResizingAndShowingKeyboard() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "chat"
    app.launch()
    defer { app.terminate() }
    let timeline = app.scrollViews["mobile-chat-timeline"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 10))
    let latest = app.descendants(matching: .any).matching(identifier: "mobile-chat-latest-message").firstMatch
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    let jump = app.buttons["mobile-chat-jump-to-present"]
    for _ in 0..<3 { timeline.swipeDown() }
    XCTAssertTrue(jump.waitForExistence(timeout: 5))
    XCTAssertTrue(jump.isHittable)
    XCTAssertGreaterThanOrEqual(jump.frame.height, 44)
    jump.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: jump)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(latest.isHittable)
    app.buttons["Resize chat"].tap()
    XCTAssertTrue(latest.isHittable)
    let field = app.textFields["Send a message"]
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(latest.isHittable)
    XCTAssertLessThanOrEqual(latest.frame.maxY, field.frame.minY + 1)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Mobile chat live edge with keyboard"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

import XCTest

@MainActor
final class MobileChatTests: XCTestCase {
  func testTappingEmoteShowsLargerNamedPreviewAndHandlesMissingImages() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "emotes"
    app.launch()
    defer { app.terminate() }
    let emote = app.buttons["chat-emote-FixtureWave"]
    XCTAssertTrue(emote.waitForExistence(timeout: 10))
    let inlineFrame = emote.frame
    emote.tap()
    let name = app.staticTexts["emote-detail-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertEqual(name.label, "FixtureWave")
    let artwork = app.descendants(matching: .any).matching(identifier: "emote-detail-artwork").firstMatch
    XCTAssertTrue(artwork.waitForExistence(timeout: 5))
    expectation(for: NSPredicate(format: "value == %@", "Loaded"), evaluatedWith: artwork)
    waitForExpectations(timeout: 5)
    XCTAssertGreaterThan(artwork.frame.height, inlineFrame.height * 4)
    let sheet = app.otherElements["emote-detail"].firstMatch
    XCTAssertTrue(name.isHittable)
    XCTAssertGreaterThanOrEqual(name.frame.minY, sheet.frame.minY)
    XCTAssertLessThanOrEqual(name.frame.maxY, sheet.frame.maxY - 12, "The emote name must not be clipped")
    XCTAssertLessThanOrEqual(artwork.frame.maxY, sheet.frame.maxY - 12)
    XCTAssertFalse(app.buttons["emote-detail-retry"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Enlarged named mobile emote"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["emote-detail-done"].tap()
    XCTAssertTrue(emote.waitForExistence(timeout: 5))
    app.buttons["chat-emote-FixtureBroken"].tap()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertEqual(name.label, "FixtureBroken")
    let retry = app.buttons["emote-detail-retry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 5))
    retry.tap()
    XCTAssertTrue(retry.waitForExistence(timeout: 5))
    app.buttons["emote-detail-done"].tap()
    XCTAssertFalse(name.exists)
    XCTAssertTrue(emote.exists)
  }

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
    XCTAssertFalse(jump.exists)
    XCTAssertFalse(app.staticTexts["Live chat"].exists)
    let viewport = timeline.frame
    for _ in 0..<3 { timeline.swipeDown() }
    XCTAssertTrue(jump.waitForExistence(timeout: 5))
    XCTAssertTrue(jump.isHittable)
    XCTAssertGreaterThanOrEqual(jump.frame.height, 44)
    assertSameFrame(timeline.frame, viewport)
    jump.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: jump)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(latest.isHittable)
    XCTAssertFalse(app.staticTexts["Live chat"].exists)
    assertSameFrame(timeline.frame, viewport)
    XCTAssertLessThanOrEqual(timeline.frame.maxY - latest.frame.maxY, 16,
                            "There must be no blank status row below the latest message")
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

  private func assertSameFrame(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
    // Accessibility coordinates can differ by floating-point roundoff after scrolling.
    XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.width, expected.width, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, accuracy: 0.000001, file: file, line: line)
  }
}

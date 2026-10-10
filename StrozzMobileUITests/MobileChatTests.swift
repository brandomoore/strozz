import XCTest

@MainActor
final class MobileChatTests: XCTestCase {
  func testNativeGIFCanBeEnlargedAndReturnsToTheSameChatLayout() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "emotes"
    app.launchEnvironment["STROZZ_GIF_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate() }
    let gif = app.buttons["chat-gif"]
    XCTAssertTrue(gif.waitForExistence(timeout: 10))
    let inlineFrame = gif.frame
    XCTAssertGreaterThanOrEqual(inlineFrame.height, 72)
    XCTAssertLessThanOrEqual(inlineFrame.height, 120)
    gif.tap()
    XCTAssertTrue(app.navigationBars["GIF"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["emote-detail-name"].label, "[Fixture Wave GIF]")
    XCTAssertEqual(app.staticTexts["emote-detail-provider"].label, "GIPHY")
    let artwork = app.descendants(matching: .any).matching(identifier: "emote-detail-artwork").firstMatch
    expectation(for: NSPredicate(format: "value == %@", "Loaded"), evaluatedWith: artwork)
    waitForExpectations(timeout: 5)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Native Twitch GIF preview"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["emote-detail-done"].tap()
    XCTAssertTrue(gif.waitForExistence(timeout: 5))
    XCTAssertEqual(gif.frame, inlineFrame)
  }

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
    let field = app.descendants(matching: .any).matching(identifier: "mobile-chat-composer-input").firstMatch
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(latest.isHittable)
    XCTAssertLessThanOrEqual(latest.frame.maxY, field.frame.minY + 1)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Mobile chat live edge with keyboard"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testRoundedComposerMorphsSettingsAndSendsFromButtonAndKeyboard() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "composer"
    app.launch()
    defer { app.terminate() }
    let field = app.descendants(matching: .any).matching(identifier: "mobile-chat-composer-input").firstMatch
    let send = app.buttons["mobile-chat-send"]
    let settings = app.buttons["mobile-chat-settings"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let capsule = app.otherElements["mobile-chat-composer"]
    XCTAssertEqual(capsule.frame.height, 44, accuracy: 0.5)
    XCTAssertGreaterThanOrEqual(settings.frame.width, 44)
    XCTAssertGreaterThanOrEqual(settings.frame.height, 44)
    XCTAssertEqual(settings.frame.midX, capsule.frame.maxX - 22, accuracy: 0.5)
    XCTAssertEqual(settings.frame.midY, capsule.frame.midY, accuracy: 0.5)
    XCTAssertFalse(send.exists)
    let latest = app.descendants(matching: .any).matching(identifier: "mobile-chat-latest-message").firstMatch
    let originalMessageHeight = latest.frame.height
    let emptyScreenshot = XCTAttachment(screenshot: app.screenshot())
    emptyScreenshot.name = "Rounded empty composer in light appearance"
    emptyScreenshot.lifetime = .keepAlways
    add(emptyScreenshot)
    app.buttons["Reduce transparency"].tap()
    let opaqueScreenshot = XCTAttachment(screenshot: app.screenshot())
    opaqueScreenshot.name = "Rounded empty composer in opaque light appearance"
    opaqueScreenshot.lifetime = .keepAlways
    add(opaqueScreenshot)
    app.buttons["Reduce transparency"].tap()
    settings.tap()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mobile-chat-settings-form")
      .firstMatch.waitForExistence(timeout: 5))
    let textSize = app.steppers["chat-setting-text-size"]
    XCTAssertTrue(textSize.waitForExistence(timeout: 5))
    let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
    settingsScreenshot.name = "Mobile chat appearance settings"
    settingsScreenshot.lifetime = .keepAlways
    add(settingsScreenshot)
    textSize.buttons["chat-setting-text-size-Increment"].tap()
    XCTAssertTrue(textSize.label.contains("17"))
    app.buttons["Done"].tap()
    XCTAssertGreaterThan(latest.frame.height, originalMessageHeight, "Saved text size must affect rendered messages")
    XCTAssertEqual(capsule.frame.height, 44, accuracy: 0.5,
      "Chat message-size changes must not enlarge the composer")
    settings.tap()
    XCTAssertTrue(textSize.waitForExistence(timeout: 5))
    XCTAssertTrue(textSize.label.contains("17"), "Chat appearance must persist when reopening settings")
    app.buttons["Done"].tap()
    let initialHeight = field.frame.height
    field.tap()
    let message = String(repeating: "A longer chat message. ", count: 6).trimmingCharacters(in: .whitespaces)
    field.typeText(message)
    XCTAssertTrue(send.isEnabled)
    XCTAssertFalse(settings.exists)
    XCTAssertGreaterThan(field.frame.height, initialHeight)
    XCTAssertGreaterThanOrEqual(send.frame.width, 44)
    XCTAssertGreaterThanOrEqual(send.frame.height, 44)
    XCTAssertEqual(send.frame.midX, capsule.frame.maxX - 22, accuracy: 0.5)
    XCTAssertEqual(send.frame.midY, capsule.frame.maxY - 22, accuracy: 0.5,
      "The Send circle must share the expanded composer's bottom-right corner center")
    XCTAssertEqual(field.value as? String, message)
    app.buttons["Change appearance"].tap()
    app.buttons["Reduce transparency"].tap()
    XCTAssertEqual(field.value as? String, message)
    XCTAssertTrue(send.isEnabled)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Rounded multiline composer with opaque dark appearance"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["Sending"].tap()
    XCTAssertFalse(field.isEnabled)
    XCTAssertFalse(send.isEnabled)
    app.buttons["Sending"].tap()
    field.tap()
    let keyboardSend = app.keyboards.buttons["Send"].firstMatch
    XCTAssertTrue(keyboardSend.waitForExistence(timeout: 5))
    keyboardSend.tap()
    XCTAssertEqual(app.staticTexts["composer-submitted"].label, message)
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    XCTAssertFalse(send.exists)
    XCTAssertEqual(capsule.frame.height, 44, accuracy: 0.5)
    field.tap()
    field.typeText("   ")
    XCTAssertTrue(settings.exists)
    XCTAssertFalse(send.exists)
    field.typeText("Button send")
    send.tap()
    XCTAssertEqual(app.staticTexts["composer-submitted"].label, "Button send")
    XCTAssertTrue(settings.exists)
  }

  func testResetAppearancePreservesHighlightKeywords() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "composer"
    app.launch()
    defer { app.terminate() }
    let settings = app.buttons["mobile-chat-settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    settings.tap()
    let form = app.descendants(matching: .any).matching(identifier: "mobile-chat-settings-form").firstMatch
    XCTAssertTrue(form.waitForExistence(timeout: 5))
    let keywords = app.descendants(matching: .any).matching(identifier: "chat-setting-keywords").firstMatch
    for _ in 0..<5 where !keywords.isHittable { form.swipeUp() }
    XCTAssertTrue(keywords.isHittable)
    keywords.tap()
    keywords.typeText("keep this keyword")
    app.buttons["Done"].tap()
    settings.tap()
    let reset = app.buttons["Reset appearance"]
    for _ in 0..<6 where !reset.isHittable { form.swipeUp() }
    XCTAssertTrue(reset.isHittable)
    reset.tap()
    for _ in 0..<5 where !keywords.isHittable { form.swipeDown() }
    XCTAssertEqual(keywords.value as? String, "keep this keyword")
    app.buttons["Done"].tap()
  }

  private func assertSameFrame(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
    // Accessibility coordinates can differ by floating-point roundoff after scrolling.
    XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.width, expected.width, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, accuracy: 0.000001, file: file, line: line)
  }

  func testCompactPointsOpenDetailsWithoutLosingTheDraft() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "composer"
    app.launchEnvironment["STROZZ_REWARDS_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate() }
    let points = app.buttons["mobile-chat-rewards"]
    XCTAssertTrue(points.waitForExistence(timeout: 10))
    XCTAssertEqual(points.value as? String, "57,990")
    XCTAssertEqual(points.label, "Delibird's")
    XCTAssertEqual(points.frame.minX, 8, accuracy: 1)
    XCTAssertLessThanOrEqual(points.frame.width, 72, "Points must not reserve a padded 96-point column")
    let field = app.textViews["mobile-chat-composer-input"]
    XCTAssertLessThanOrEqual(points.frame.maxX, field.frame.minX)
    XCTAssertGreaterThanOrEqual(points.frame.height, 44)
    field.tap()
    field.typeText("My unsent draft")
    points.tap()
    XCTAssertTrue(app.navigationBars["Channel points"].waitForExistence(timeout: 3))
    let balance = app.descendants(matching: .any).matching(identifier: "mobile-rewards-balance").firstMatch
    let streak = app.descendants(matching: .any).matching(identifier: "mobile-rewards-streak").firstMatch
    XCTAssertTrue(balance.waitForExistence(timeout: 3))
    XCTAssertTrue(balance.label.contains("Delibird's"))
    XCTAssertTrue((balance.label + String(describing: balance.value ?? "")).contains("57,990"))
    XCTAssertTrue((streak.label + String(describing: streak.value ?? "")).contains("10 streams"))
    let detailsShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    detailsShot.name = "Exact points and streak details"
    detailsShot.lifetime = .keepAlways
    add(detailsShot)
    app.buttons["Done"].tap()
    XCTAssertEqual(field.value as? String, "My unsent draft")
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "Compact points beside the mobile composer"
    shot.lifetime = .keepAlways
    add(shot)
  }
}

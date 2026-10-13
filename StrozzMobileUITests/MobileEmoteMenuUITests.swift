import XCTest

@MainActor
final class MobileEmoteMenuUITests: XCTestCase {
  func testOptInLiveCatalogArtwork() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_EMOTE_MENU_LIVE_TEST"] == "1" else {
      throw XCTSkip("Opt in to load current provider catalogs.")
    }
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "emote-menu"
    app.launchEnvironment["STROZZ_EMOTE_MENU_LIVE"] = "1"
    app.launch()
    defer { app.terminate() }
    let ready = app.staticTexts["emote-fixture-ready"]
    XCTAssertTrue(ready.waitForExistence(timeout: 10))
    expectation(for: NSPredicate(format: "label != '0'"), evaluatedWith: ready)
    waitForExpectations(timeout: 45)
    app.buttons["mobile-chat-emotes"].tap()
    XCTAssertTrue(app.buttons["emote-menu-done"].waitForExistence(timeout: 5))
    capture("Live channel emote browser")
    app.searchFields.firstMatch.tap()
    app.searchFields.firstMatch.typeText("CAUGHT")
    let emote = app.buttons["emote-menu-item-CAUGHT"]
    XCTAssertTrue(emote.waitForExistence(timeout: 5))
    expectation(for: NSPredicate(format: "value == 'Loaded'"), evaluatedWith: emote)
    waitForExpectations(timeout: 15)
    emote.tap()
    XCTAssertEqual(app.staticTexts["emote-menu-feedback"].label, "Added CAUGHT")
    capture("Real CAUGHT artwork in the emote browser")
  }

  func testPartialCatalogStillOffersEmotesAndEmptySearchFeedback() {
    let app = launchFixture(partial: true)
    defer { app.terminate() }
    app.buttons["mobile-chat-emotes"].tap()
    XCTAssertTrue(app.otherElements["emote-menu-error"].waitForExistence(timeout: 5)
      || app.staticTexts["Some emotes couldn't load. Available emotes are shown."].exists)
    XCTAssertTrue(app.buttons["Retry"].exists)
    app.buttons["emote-menu-item-CAUGHT"].tap()
    XCTAssertEqual(app.staticTexts["emote-menu-feedback"].label, "Added CAUGHT")
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("NoSuchEmoteFixture")
    XCTAssertTrue(app.staticTexts["No matching emotes"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["emote-menu-done"].exists)
    app.buttons["emote-menu-done"].tap()
    XCTAssertEqual(app.textViews["mobile-chat-composer-input"].value as? String, "CAUGHT ")
  }

  func testSearchProviderFiltersInsertionAndCopyPreserveDraft() {
    let app = launchFixture()
    defer { app.terminate() }
    let field = app.textViews["mobile-chat-composer-input"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText("Hello")
    app.buttons["mobile-chat-emotes"].tap()
    let done = app.buttons["emote-menu-done"]
    XCTAssertTrue(done.waitForExistence(timeout: 5))
    let providers = app.segmentedControls["emote-menu-provider"]
    XCTAssertTrue(providers.waitForExistence(timeout: 5))
    let all = providers.buttons["All"]
    XCTAssertTrue(all.isSelected)
    for label in ["All", "Twitch", "7TV", "BTTV", "FFZ"] {
      let button = providers.buttons[label]
      XCTAssertTrue(button.isHittable, "\(label) must be directly tappable without opening a menu")
      XCTAssertEqual(button.frame.midY, all.frame.midY, accuracy: 1)
    }
    for (provider, name) in [("Twitch", "Kappa"), ("BTTV", "FeelsGoodMan"), ("FFZ", "FrankerZ")] {
      providers.buttons[provider].tap()
      XCTAssertTrue(providers.buttons[provider].isSelected)
      XCTAssertTrue(app.buttons["emote-menu-item-\(name)"].waitForExistence(timeout: 3))
      XCTAssertEqual(app.staticTexts["emote-menu-count"].label, "1 emote")
    }
    all.tap()
    XCTAssertTrue(all.isSelected)
    XCTAssertEqual(app.staticTexts["emote-menu-count"].label, "205 emotes")
    providers.buttons["7TV"].tap()
    XCTAssertTrue(providers.buttons["7TV"].isSelected)
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("xdd")
    let emote = app.buttons["emote-menu-item-xdd"]
    XCTAssertTrue(emote.waitForExistence(timeout: 3))
    providers.buttons["Twitch"].tap()
    XCTAssertTrue(app.staticTexts["No matching emotes"].waitForExistence(timeout: 3))
    XCTAssertEqual(search.value as? String, "xdd", "Provider switching must preserve the query")
    providers.buttons["7TV"].tap()
    XCTAssertTrue(emote.waitForExistence(timeout: 3))
    emote.tap()
    XCTAssertEqual(app.staticTexts["emote-menu-feedback"].label, "Added xdd")
    emote.tap()
    emote.press(forDuration: 1)
    app.buttons["Copy emote name"].tap()
    XCTAssertEqual(app.staticTexts["emote-menu-feedback"].label, "Copied xdd")
    capture("Search and copy in the native emote menu")
    done.tap()
    XCTAssertEqual(field.value as? String, "Hello xdd xdd ")
    XCTAssertEqual(app.staticTexts["composer-submitted"].label, "")
    field.tap()
    field.typeText("tail")
    XCTAssertEqual(field.value as? String, "Hello xdd xdd tail")
    app.buttons["mobile-chat-send"].tap()
    XCTAssertEqual(app.staticTexts["composer-submitted"].label, "Hello xdd xdd tail")
  }

  func testReadOnlyMenuAndPreviewCopyInLightAndOLED() {
    let app = launchFixture(readOnly: true)
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["mobile-chat-emotes"].waitForExistence(timeout: 10))
    for appearance in ["Light", "OLED"] {
      app.buttons["mobile-chat-emotes"].tap()
      let caught = app.buttons["emote-menu-item-CAUGHT"]
      XCTAssertTrue(caught.waitForExistence(timeout: 5))
      capture("\(appearance) emote grid")
      caught.tap()
      XCTAssertEqual(app.staticTexts["emote-menu-feedback"].label, "Copied CAUGHT")
      caught.press(forDuration: 1)
      app.buttons["View emote"].tap()
      let copy = app.buttons["emote-detail-copy"]
      XCTAssertTrue(copy.waitForExistence(timeout: 5))
      copy.tap()
      XCTAssertEqual(copy.label, "Copied")
      app.buttons["emote-detail-done"].tap()
      app.buttons["emote-menu-done"].tap()
      XCTAssertEqual(app.textViews["mobile-chat-composer-input"].value as? String, "")
      app.buttons["Change appearance"].tap()
      app.buttons["Reduce transparency"].tap()
    }
  }

  private func launchFixture(readOnly: Bool = false, partial: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "emote-menu"
    if readOnly { app.launchEnvironment["STROZZ_EMOTE_MENU_READ_ONLY"] = "1" }
    if partial { app.launchEnvironment["STROZZ_EMOTE_MENU_PARTIAL"] = "1" }
    app.launch()
    let ready = app.staticTexts["emote-fixture-ready"]
    XCTAssertTrue(ready.waitForExistence(timeout: 10))
    expectation(for: NSPredicate(format: "label == '205'"), evaluatedWith: ready)
    waitForExpectations(timeout: 5)
    return app
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

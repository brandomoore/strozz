import XCTest

@MainActor
final class MultiviewBrowseTests: XCTestCase {
  func testSharedHoldActionsAcrossBrowseAndSearch() {
    verifySharedHoldActions(theme: "light", opaque: true)
  }

  func testSharedHoldActionsAndManagerInDarkTheme() {
    verifySharedHoldActions(theme: "dark", opaque: false)
  }

  func testInlineLineupGrowsWithoutChangingHeight() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MULTIVIEW_BROWSE_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_THEME"] = "light"
    app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_OPAQUE"] = "1"
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["Browse"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["multiview-lineup"].exists)
    capture(app, "Inline Browse empty has no reserved button")
    XCUIRemote.shared.press(.down)
    var frames: [CGRect] = []
    for (index, login) in ["alpha", "beta", "gamma"].enumerated() {
      if index > 0 { XCUIRemote.shared.press(.right) }
      let card = app.descendants(matching: .any)["stream-card-\(login)"].firstMatch
      expectFocus(card)
      selectContextAction("multiview-toggle-\(login)", in: app)
      expectValue(card, "In multiview")
      expectFocus(card)
      let lineup = app.buttons["multiview-lineup"]
      expectValue(lineup, "\(index + 1) streams")
      frames.append(lineup.frame)
      capture(app, "Inline Browse \(index + 1) avatars")
    }
    for frame in frames.dropFirst() {
      XCTAssertEqual(frame.height, frames[0].height, accuracy: 1)
      XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 1)
    }
    XCTAssertEqual(frames[1].width - frames[0].width, 34, accuracy: 1)
    XCTAssertEqual(frames[2].width - frames[1].width, 34, accuracy: 1)
    XCTAssertEqual(frames[0].height, 70, accuracy: 1)
    print("INLINE_GEOMETRY one=\(frames[0]) two=\(frames[1]) three=\(frames[2])")
  }

  func testNativeContextStartAndReturnPreserveSearchQuery() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MULTIVIEW_BROWSE_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["Browse"].waitForExistence(timeout: 10))
    XCUIRemote.shared.press(.down)
    let alpha = app.descendants(matching: .any)["stream-card-alpha"].firstMatch
    expectFocus(alpha)
    selectContextAction("multiview-toggle-alpha", in: app)
    expectFocus(alpha)
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    let start = app.descendants(matching: .any)["multiview-context-start"].firstMatch
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    XCTAssertEqual(start.label, "Start multiview")
    XCTAssertFalse(start.isEnabled)
    capture(app, "Native context Start disabled with one selection")
    XCUIRemote.shared.press(.menu)
    expectFocus(alpha)
    XCUIRemote.shared.press(.right)
    let beta = app.descendants(matching: .any)["stream-card-beta"].firstMatch
    expectFocus(beta)
    selectContextAction("multiview-toggle-beta", in: app)
    expectFocus(beta)
    XCUIRemote.shared.press(.left)
    expectFocus(alpha)
    XCUIRemote.shared.press(.up)
    if !app.buttons["Search"].hasFocus { XCUIRemote.shared.press(.right) }
    expectFocus(app.buttons["Search"])
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
    for expectedLabel in ["Start multiview", "Return to multiview"] {
      focusSearchBeta(app)
      XCTAssertEqual(app.searchFields.firstMatch.value as? String, "example")
      XCUIRemote.shared.press(.select, forDuration: 1.2)
      XCTAssertTrue(start.waitForExistence(timeout: 5))
      XCTAssertEqual(start.label, expectedLabel)
      XCTAssertTrue(start.isEnabled)
      focusContextAction("multiview-context-start", in: app)
      capture(app, "Search native context \(expectedLabel)")
      XCUIRemote.shared.press(.select)
      XCTAssertTrue(app.staticTexts["Fixture multiview"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["2 streams"].exists)
      capture(app, "Search context \(expectedLabel) requested playback")
      returnFromFixturePlayback(app)
      XCTAssertTrue(beta.waitForExistence(timeout: 5))
      XCTAssertEqual(app.searchFields.firstMatch.value as? String, "example")
      expectValue(beta, "In multiview")
      capture(app, "Search restored after context \(expectedLabel)")
    }
  }

  private func verifySharedHoldActions(theme: String, opaque: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MULTIVIEW_BROWSE_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_THEME"] = theme
    app.launchEnvironment["STROZZ_MULTIVIEW_STATUS_OPAQUE"] = opaque ? "1" : "0"
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    defer { app.terminate() }
    let alpha = app.descendants(matching: .any)["stream-card-alpha"].firstMatch
    XCTAssertTrue(alpha.waitForExistence(timeout: 10))
    capture(app, "Initial Browse focus")
    XCTAssertFalse(app.buttons["multiview-lineup"].isHittable)
    XCUIRemote.shared.press(.down)
    capture(app, "Browse focus after Down")
    expectFocus(alpha)
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    capture(app, "Browse native context menu")
    let addAlpha = app.cells.containing(.any, identifier: "multiview-toggle-alpha").firstMatch
    XCTAssertTrue(addAlpha.waitForExistence(timeout: 5))
    XCTAssertEqual(app.cells.count, 1, "The lineup-only card has no Watch or Go to Channel callbacks.")
    XCTAssertEqual(app.descendants(matching: .any)["multiview-toggle-alpha"].firstMatch.label,
      "Add to multiview")
    for _ in 0..<3 {
      if addAlpha.hasFocus { break }
      XCUIRemote.shared.press(.down)
    }
    expectFocus(addAlpha)
    capture(app, "Native Browse hold menu")
    XCUIRemote.shared.press(.select)
    expectValue(alpha, "In multiview")
    expectFocus(alpha)
    XCTAssertTrue(app.buttons["multiview-lineup"].exists)
    capture(app, "Browse selection retains focus")

    XCUIRemote.shared.press(.up)
    if !app.buttons["Search"].hasFocus { XCUIRemote.shared.press(.right) }
    expectFocus(app.buttons["Search"])
    XCUIRemote.shared.press(.select)
    let beta = app.descendants(matching: .any)["stream-card-beta"].firstMatch
    XCTAssertTrue(beta.waitForExistence(timeout: 10))
    let channels = app.staticTexts["Channels"]
    let categories = app.staticTexts["Categories"]
    XCTAssertTrue(channels.exists)
    XCTAssertTrue(categories.exists)
    XCTAssertLessThan(channels.frame.minY, categories.frame.minY)
    let alphaInSearch = app.descendants(matching: .any)["stream-card-alpha"].firstMatch
    expectValue(alphaInSearch, "In multiview")
    capture(app, "Channels first in Search")

    focusSearchBeta(app)
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    let addBeta = app.cells.containing(.any, identifier: "multiview-toggle-beta").firstMatch
    XCTAssertTrue(addBeta.waitForExistence(timeout: 5))
    // Watch and Go to Channel precede the multiview action in real Search.
    for _ in 0..<3 {
      if addBeta.hasFocus { break }
      XCUIRemote.shared.press(.down)
    }
    expectFocus(addBeta)
    XCUIRemote.shared.press(.select)
    expectValue(beta, "In multiview")
    expectFocus(beta)
    XCTAssertEqual(app.buttons["multiview-lineup"].value as? String, "2 streams")
    XCTAssertEqual(app.searchFields.firstMatch.value as? String, "example")
    capture(app, "One lineup across Browse and Search")

    focusFixtureLineup(app)
    XCUIRemote.shared.press(.select)
    let start = app.buttons["multiview-start"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    XCTAssertEqual(start.label, "Start multiview")
    XCTAssertTrue(start.isEnabled)
    capture(app, "\(theme) lineup manager before playback")
    focusManagerStart(app)
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.staticTexts["Fixture multiview"].waitForExistence(timeout: 5))
    capture(app, "\(theme) fixture playback request")
    returnFromFixturePlayback(app)
    XCTAssertTrue(app.buttons["multiview-lineup"].waitForExistence(timeout: 5))
    focusFixtureLineup(app)
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    XCTAssertEqual(start.label, "Return to multiview")
    let removeAlpha = app.buttons["multiview-remove-alpha"]
    expectFocus(removeAlpha)
    XCUIRemote.shared.press(.select)
    XCTAssertFalse(removeAlpha.exists)
    expectFocus(app.buttons["multiview-remove-beta"])
    capture(app, "\(theme) manager removal preserves next focus")
    focusManagerStart(app)
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.staticTexts["Fixture multiview"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["1 streams"].exists)
    returnFromFixturePlayback(app)
    focusFixtureLineup(app)
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    focusManagerStart(app)
    XCUIRemote.shared.press(.right)
    expectFocus(app.buttons["Clear"])
    XCUIRemote.shared.press(.select)
    expectValue(beta, "")
    XCTAssertFalse(app.buttons["multiview-lineup"].isHittable)
    XCTAssertEqual(app.searchFields.firstMatch.value as? String, "example")
    capture(app, "\(theme) cleared lineup keeps Search query")
  }

  func testRealHomeReturnsFromWallWithoutLosingLineup() {
    continueAfterFailure = false
    let app = XCUIApplication()
    let liveNames = ProcessInfo.processInfo.environment["STROZZ_MATRIX_CHANNELS"]
    app.launchEnvironment["STROZZ_MULTIVIEW_UI_CHANNELS"] = liveNames ?? "multiviewfixtureone,multiviewfixturetwo"
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES"]
    app.launch()
    defer { app.terminate() }
    let panes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'multiview-pane-'"))
    XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 20))
    XCTAssertEqual(panes.count, 2)
    capture(app, "Real multiview wall")
    XCUIRemote.shared.press(.menu)
    let lineup = app.buttons["multiview-lineup"]
    XCTAssertTrue(lineup.waitForExistence(timeout: 10))
    capture(app, "Real Home after wall Menu")
    if liveNames != nil {
      XCUIRemote.shared.press(.down)
      capture(app, "Home focus below tabs")
      for _ in 0..<4 {
        if lineup.hasFocus { break }
        XCUIRemote.shared.press(.right)
      }
      if !lineup.hasFocus { XCUIRemote.shared.press(.up) }
      expectFocus(lineup)
      XCUIRemote.shared.press(.select)
      let start = app.buttons["multiview-start"]
      XCTAssertTrue(start.waitForExistence(timeout: 5))
      XCTAssertEqual(start.label, "Return to multiview")
      capture(app, "Real Home return manager")
      focusManagerStart(app)
      XCUIRemote.shared.press(.select)
      XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 10))
      XCTAssertEqual(panes.count, 2)
      capture(app, "Real wall returned from shared manager")

      XCUIRemote.shared.press(.menu)
      let topCards = app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH 'topstreams-'"))
      XCTAssertTrue(topCards.firstMatch.waitForExistence(timeout: 15))
      for _ in 0..<5 {
        if topCards.allElementsBoundByIndex.contains(where: { $0.hasFocus }) { break }
        XCUIRemote.shared.press(.down)
      }
      XCTAssertTrue(topCards.allElementsBoundByIndex.contains(where: { $0.hasFocus }))
      XCUIRemote.shared.press(.select, forDuration: 1.2)
      let contextReturn = app.descendants(matching: .any)["multiview-context-start"].firstMatch
      XCTAssertTrue(contextReturn.waitForExistence(timeout: 5))
      XCTAssertEqual(contextReturn.label, "Return to multiview")
      XCTAssertTrue(contextReturn.isEnabled)
      focusContextAction("multiview-context-start", in: app)
      capture(app, "Real Home native Return to multiview")
      XCUIRemote.shared.press(.select)
      XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 10))
      XCTAssertEqual(panes.count, 2)
      capture(app, "Real wall returned from native Home context menu")
    }
  }

  func testRealHomeAndBrowseLineupScrollsWithControls() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MULTIVIEW_UI_CHANNELS"] =
      ProcessInfo.processInfo.environment["STROZZ_MATRIX_CHANNELS"] ?? "multiviewfixtureone,multiviewfixturetwo"
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES"]
    app.launch()
    defer { app.terminate() }
    let panes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'multiview-pane-'"))
    XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 20))
    XCUIRemote.shared.press(.menu)
    let lineup = app.buttons["multiview-lineup"]
    let refresh = app.buttons["following-refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 20))
    XCTAssertTrue(lineup.waitForExistence(timeout: 5))
    let homeLineupFrame = lineup.frame
    let homeRefreshFrame = refresh.frame
    let homeTitle = app.staticTexts["following-title"]
    let homeTitleFrame = homeTitle.frame
    XCTAssertEqual(homeLineupFrame.midY, homeRefreshFrame.midY, accuracy: 3)
    XCTAssertLessThan(homeLineupFrame.maxX, homeRefreshFrame.minX)
    if app.buttons["following-directory"].exists {
      XCTAssertLessThan(homeLineupFrame.maxX, app.buttons["following-directory"].frame.minX)
      XCTAssertEqual(homeLineupFrame.midY, app.buttons["following-directory"].frame.midY, accuracy: 3)
    }
    capture(app, "Real Home inline lineup beside Refresh")
    for index in 0..<7 {
      XCUIRemote.shared.press(.down)
      capture(app, "Real Home scroll step \(index + 1)")
      if index >= 3 && lineup.frame.maxY < 0 && refresh.frame.maxY < 0 { break }
    }
    XCTAssertFalse(lineup.isHittable)
    XCTAssertFalse(refresh.isHittable)
    XCTAssertLessThan(lineup.frame.maxY, 0)
    XCTAssertEqual(lineup.frame.midY - homeLineupFrame.midY,
      refresh.frame.midY - homeRefreshFrame.midY, accuracy: 3)
    XCTAssertLessThan(homeTitle.frame.maxY, 0)
    XCTAssertEqual(lineup.frame.midY - homeLineupFrame.midY,
      homeTitle.frame.midY - homeTitleFrame.midY, accuracy: 3)
    let homeScrolledFrame = lineup.frame
    capture(app, "Real Home controls scrolled away together")

    let browseTab = app.tabBars.buttons["Browse"]
    for _ in 0..<10 {
      if app.tabBars.buttons.allElementsBoundByIndex.contains(where: { $0.hasFocus }) { break }
      XCUIRemote.shared.press(.up)
    }
    for _ in 0..<4 {
      if browseTab.hasFocus { break }
      XCUIRemote.shared.press(.right)
    }
    expectFocus(browseTab)
    XCUIRemote.shared.press(.select)
    let browseRefresh = app.buttons["Refresh"]
    XCTAssertTrue(browseRefresh.waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Browse"].exists)
    XCTAssertGreaterThan(lineup.frame.minY, 0)
    let browseLineupFrame = lineup.frame
    let browseRefreshFrame = browseRefresh.frame
    let browseTitle = app.staticTexts["Browse"]
    let browseTitleFrame = browseTitle.frame
    XCTAssertEqual(browseLineupFrame.midY, browseRefreshFrame.midY, accuracy: 3)
    XCTAssertLessThan(browseLineupFrame.maxX, browseRefreshFrame.minX)
    capture(app, "Real Browse inline lineup beside Refresh")
    for index in 0..<8 {
      XCUIRemote.shared.press(.down)
      capture(app, "Real Browse scroll step \(index + 1)")
      if index >= 3 && lineup.frame.maxY < 0 && browseRefresh.frame.maxY < 0 { break }
    }
    XCTAssertFalse(lineup.isHittable)
    XCTAssertFalse(browseRefresh.isHittable)
    XCTAssertLessThan(lineup.frame.maxY, 0)
    XCTAssertEqual(lineup.frame.midY - browseLineupFrame.midY,
      browseRefresh.frame.midY - browseRefreshFrame.midY, accuracy: 3)
    XCTAssertLessThan(browseTitle.frame.maxY, 0)
    XCTAssertEqual(lineup.frame.midY - browseLineupFrame.midY,
      browseTitle.frame.midY - browseTitleFrame.midY, accuracy: 3)
    capture(app, "Real Browse controls scrolled away together")
    print("INLINE_SCROLL home=\(homeLineupFrame) -> \(homeScrolledFrame); browse=\(browseLineupFrame) -> \(lineup.frame)")
  }

  func testFullLineupDisablesAddingAnotherSearchChannel() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MULTIVIEW_BROWSE_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_MULTIVIEW_BROWSE_FULL"] = "1"
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["Browse"].waitForExistence(timeout: 10))
    XCUIRemote.shared.press(.right)
    expectFocus(app.buttons["Search"])
    XCUIRemote.shared.press(.select)
    let alpha = app.descendants(matching: .any)["stream-card-alpha"].firstMatch
    XCTAssertTrue(alpha.waitForExistence(timeout: 10))
    let beta = app.descendants(matching: .any)["stream-card-beta"].firstMatch
    let kick = app.descendants(matching: .any)["stream-card-kick:example"].firstMatch
    capture(app, "Full lineup Search results")
    for _ in 0..<4 {
      if alpha.hasFocus || beta.hasFocus || kick.hasFocus { break }
      XCUIRemote.shared.press(.down)
    }
    for _ in 0..<2 {
      if kick.hasFocus { break }
      XCUIRemote.shared.press(.right)
    }
    expectFocus(kick)
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    let action = app.descendants(matching: .any)["multiview-toggle-kick:example"].firstMatch
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    XCTAssertEqual(action.label, "Multiview full")
    capture(app, "Full lineup native context menu")
    let fullActionIsEnabled = action.isEnabled
    if fullActionIsEnabled {
      XCUIRemote.shared.press(.down)
      XCUIRemote.shared.press(.down)
      expectFocus(app.cells.containing(.any, identifier: "multiview-toggle-kick:example").firstMatch)
      capture(app, "Defect enabled full-lineup action receives native focus")
      XCUIRemote.shared.press(.select)
    } else {
      XCUIRemote.shared.press(.menu)
    }
    expectFocus(kick)
    XCTAssertEqual(app.buttons["multiview-lineup"].value as? String, "6 streams")
    XCUIRemote.shared.press(.left)
    XCUIRemote.shared.press(.left)
    expectFocus(alpha)
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    let remove = app.cells.containing(.any, identifier: "multiview-toggle-alpha").firstMatch
    XCTAssertTrue(remove.waitForExistence(timeout: 5))
    for _ in 0..<3 {
      if remove.hasFocus { break }
      XCUIRemote.shared.press(.down)
    }
    expectFocus(remove)
    XCUIRemote.shared.press(.select)
    expectValue(alpha, "")
    expectFocus(alpha)
    XCTAssertEqual(app.buttons["multiview-lineup"].value as? String, "5 streams")
    capture(app, "Full lineup still permits removing existing selection")
    XCTAssertFalse(fullActionIsEnabled)
  }

  func testOptInRealPlayerAndChannelPageShareSelection() throws {
    guard let login = ProcessInfo.processInfo.environment["STROZZ_MATRIX_CHANNELS"]?
      .split(separator: ",").first.map(String.init) else {
      throw XCTSkip("Provide live channels to verify real player and channel-page controls.")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_PLAYER_UI_CHANNEL"] = login
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES"]
    app.launch()
    defer { app.terminate() }
    let video = app.descendants(matching: .any)["player-video-focus"].firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 30))
    capture(app, "Real single player")
    XCUIRemote.shared.press(.up)
    let add = app.buttons["player-multiview"]
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    capture(app, "Real player add control")
    for _ in 0..<3 {
      if add.hasFocus { break }
      XCUIRemote.shared.press(app.buttons["player-quality-menu"].hasFocus ? .left : .right)
    }
    expectFocus(add)
    XCTAssertEqual(add.label, "Add to multiview")
    XCUIRemote.shared.press(.select)
    expectation(for: NSPredicate(format: "label == 'Multiview'"), evaluatedWith: add)
    waitForExpectations(timeout: 5)
    expectFocus(add)
    XCUIRemote.shared.press(.select)
    let start = app.buttons["multiview-start"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    XCTAssertFalse(start.isEnabled)
    XCTAssertTrue(app.buttons["multiview-remove-\(login)"].exists)
    capture(app, "Real player shared manager with one selection")
    XCUIRemote.shared.press(.menu)
    expectFocus(add)
    XCUIRemote.shared.press(.left)
    expectFocus(app.buttons["Channel info"])
    XCUIRemote.shared.press(.select)
    let liveCard = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH 'Live,'")).firstMatch
    XCTAssertTrue(liveCard.waitForExistence(timeout: 25))
    capture(app, "Real channel page shares lineup")
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    let action = app.descendants(matching: .any)["multiview-toggle-\(login)"].firstMatch
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    XCTAssertEqual(action.label, "Remove from multiview")
    expectFocus(app.cells.containing(.any, identifier: "multiview-toggle-\(login)").firstMatch)
    capture(app, "Real channel-page hold action")
    XCUIRemote.shared.press(.select)
    XCTAssertFalse(app.buttons["multiview-lineup"].isHittable)
    expectFocus(liveCard)
    capture(app, "Real channel-page removal retains focus")
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    XCTAssertEqual(action.label, "Add to multiview")
    expectFocus(app.cells.containing(.any, identifier: "multiview-toggle-\(login)").firstMatch)
    capture(app, "Real channel-page re-add menu")
    XCUIRemote.shared.press(.select)
    expectFocus(liveCard)
    capture(app, "Real channel-page selection restored")
    let pageLineup = try XCTUnwrap(app.buttons.matching(identifier: "multiview-lineup")
      .allElementsBoundByIndex.first(where: { $0.isHittable }))
    XCTAssertEqual(pageLineup.value as? String, "1 streams")
  }

  private func expectFocus(_ element: XCUIElement) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasFocus == true"), object: element)
    let result = XCTWaiter.wait(for: [expectation], timeout: 5)
    if result != .completed { capture(XCUIApplication(), "Unexpected focus") }
    XCTAssertEqual(result, .completed)
  }

  private func focusManagerStart(_ app: XCUIApplication) {
    let start = app.buttons["multiview-start"]
    for _ in 0..<3 {
      if start.hasFocus || app.buttons["Clear"].hasFocus { break }
      XCUIRemote.shared.press(.down)
    }
    if app.buttons["Clear"].hasFocus { XCUIRemote.shared.press(.left) }
    expectFocus(start)
  }

  private func returnFromFixturePlayback(_ app: XCUIApplication) {
    expectFocus(app.buttons["Browse streams"])
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(app.staticTexts["Fixture multiview"].waitForNonExistence(timeout: 5))
  }

  private func focusFixtureLineup(_ app: XCUIApplication) {
    let lineup = app.buttons["multiview-lineup"]
    if app.searchFields.firstMatch.exists {
      focusSearchBeta(app)
      XCUIRemote.shared.press(.right)
      XCUIRemote.shared.press(.up)
      if !lineup.hasFocus {
        XCUIRemote.shared.press(.right)
      }
      if !lineup.hasFocus {
        XCUIRemote.shared.press(.down)
      }
      expectFocus(lineup)
      capture(app, "Search inline lineup receives native focus")
      return
    }
    for _ in 0..<4 {
      if app.buttons["Browse"].hasFocus || app.buttons["Search"].hasFocus || lineup.hasFocus { break }
      XCUIRemote.shared.press(.up)
    }
    for _ in 0..<2 {
      if lineup.hasFocus { break }
      XCUIRemote.shared.press(.right)
    }
    expectFocus(lineup)
  }

  private func focusSearchBeta(_ app: XCUIApplication) {
    let alpha = app.descendants(matching: .any)["stream-card-alpha"].firstMatch
    let beta = app.descendants(matching: .any)["stream-card-beta"].firstMatch
    let kick = app.descendants(matching: .any)["stream-card-kick:example"].firstMatch
    let category = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == 'Example category'")).firstMatch
    for _ in 0..<5 {
      if alpha.hasFocus || beta.hasFocus || kick.hasFocus { break }
      XCUIRemote.shared.press(category.hasFocus ? .up : .down)
    }
    if alpha.hasFocus { XCUIRemote.shared.press(.right) }
    if kick.hasFocus { XCUIRemote.shared.press(.left) }
    expectFocus(beta)
  }

  private func selectContextAction(_ identifier: String, in app: XCUIApplication) {
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    focusContextAction(identifier, in: app)
    XCUIRemote.shared.press(.select)
  }

  private func focusContextAction(_ identifier: String, in app: XCUIApplication) {
    let action = app.cells.containing(.any, identifier: identifier).firstMatch
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    for _ in 0..<5 {
      if action.hasFocus { break }
      XCUIRemote.shared.press(.down)
    }
    expectFocus(action)
  }

  private func expectValue(_ element: XCUIElement, _ value: String) {
    expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
    waitForExpectations(timeout: 5)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name) hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }
}

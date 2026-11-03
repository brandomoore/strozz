import XCTest

@MainActor
final class MultiviewShortcutUITests: XCTestCase {
  private var currentSurface = "home"

  override func setUp() {
    continueAfterFailure = false
  }

  func testActualHomeLineupGeometryFocusAndEmptyManagerDismissal() throws {
    let app = launchFixture(count: 0, cards: "home")
    defer { app.terminate() }
    let first = app.descendants(matching: .any)["following-twitch"].firstMatch
    let second = app.descendants(matching: .any)["following-kick:kick"].firstMatch
    let lineup = app.buttons["multiview-lineup"]
    let nextTitle = app.staticTexts["shortcut-home-next-title"]
    focusHomeElement(first, app: app)
    let initialCard = first.frame
    let initialNextTitle = nextTitle.frame
    let initialState = try homeState(app)
    XCTAssertFalse(lineup.exists, "The empty lineup must not be actionable in accessibility.")

    for count in [1, 0] {
      press(.playPause, app: app, name: "actual Home quick toggle to \(count)")
      try expectHomeState(app, count: count)
      XCTAssertTrue(first.hasFocus, "Membership changes must retain the exact focused Home card.")
      assertFrame(first.frame, equals: initialCard, name: "Focused Home card")
      assertFrame(nextTitle.frame, equals: initialNextTitle, name: "Following section's next sibling")
      let state = try homeState(app)
      for key in ["section", "scroll"] {
        let expected = try XCTUnwrap(initialState[key] as? [Double])
        let actual = try XCTUnwrap(state[key] as? [Double])
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(actual.count, expected.count)
        for (old, new) in zip(expected, actual) {
          XCTAssertEqual(new, old, accuracy: 0.01, "\(key) must not move or resize.")
        }
      }
      XCTAssertEqual(lineup.exists, count != 0)
    }

    let directory = app.buttons["following-directory"]
    let refresh = app.buttons["following-refresh"]
    focusHomeElement(directory, app: app)
    press(.right, app: app, name: "empty header right reaches Refresh")
    XCTAssertTrue(refresh.hasFocus)
    press(.left, app: app, name: "empty header left reaches See All")
    XCTAssertTrue(directory.hasFocus)
    press(.left, app: app, name: "empty lineup has no invisible focus stop")
    XCTAssertTrue(directory.hasFocus)
    XCTAssertFalse(lineup.exists)

    focusHomeElement(first, app: app)
    press(.playPause, app: app, name: "add single entry before manager removal")
    try expectHomeState(app, count: 1)
    focusHomeElement(lineup, app: app)
    XCTAssertTrue(lineup.hasFocus)
    press(.select, app: app, name: "open native single-entry lineup manager")
    let removeFirst = app.buttons["multiview-remove-twitch"]
    XCTAssertTrue(removeFirst.waitForExistence(timeout: 5))
    focusHomeElement(removeFirst, app: app)
    press(.select, app: app, name: "remove final manager entry")
    XCTAssertTrue(app.buttons["multiview-start"].waitForNonExistence(timeout: 5))
    XCTAssertFalse(removeFirst.exists)
    XCTAssertFalse(lineup.exists)
    try expectHomeState(app, count: 0)

    focusHomeElement(first, app: app)
    press(.playPause, app: app, name: "add again after last-entry dismissal")
    try expectHomeState(app, count: 1)
    let singleWidth = lineup.frame.width
    XCTAssertEqual(lineup.value as? String, "1 streams")
    focusHomeElement(second, app: app)
    press(.playPause, app: app, name: "second avatar grows real Home button")
    try expectHomeState(app, count: 2)
    XCTAssertEqual(lineup.value as? String, "2 streams")
    XCTAssertGreaterThan(lineup.frame.width, singleWidth + 25)
    let widths = XCTAttachment(string: "One avatar: \(singleWidth)pt; two: \(lineup.frame.width)pt; delta: \(lineup.frame.width - singleWidth)pt")
    widths.name = "Actual Home lineup avatar width"
    widths.lifetime = .keepAlways
    add(widths)
    focusHomeElement(lineup, app: app)
    XCTAssertTrue(lineup.hasFocus)
    press(.select, app: app, name: "open native two-entry lineup manager")
    XCTAssertTrue(app.buttons["multiview-remove-kick:kick"].waitForExistence(timeout: 5))
    focusHomeElement(app.buttons["Clear"], app: app)
    press(.select, app: app, name: "Clear dismisses native lineup manager")
    XCTAssertTrue(app.buttons["multiview-start"].waitForNonExistence(timeout: 5))
    XCTAssertFalse(lineup.exists)
    try expectHomeState(app, count: 0)
    focusHomeElement(first, app: app)
    press(.playPause, app: app, name: "add again after Clear")
    try expectHomeState(app, count: 1)
    XCTAssertTrue(first.hasFocus)
    assertFrame(first.frame, equals: initialCard, name: "Home card after manager round trips")
    assertFrame(nextTitle.frame, equals: initialNextTitle, name: "Next section after manager round trips")
    focusHomeElement(lineup, app: app)
    press(.select, app: app, name: "reopen manager after Clear")
    XCTAssertTrue(removeFirst.waitForExistence(timeout: 5))
    press(.menu, app: app, name: "dismiss reopened manager normally")
    XCTAssertTrue(app.buttons["multiview-start"].waitForNonExistence(timeout: 5))
    try expectHomeState(app, count: 1)
  }

  private func homeState(_ app: XCUIApplication) throws -> [String: Any] {
    let element = app.staticTexts["shortcut-home-state"]
    let value = try XCTUnwrap(element.value as? String)
    let attachment = XCTAttachment(string: value)
    attachment.name = "Actual Home geometry and playback state"
    attachment.lifetime = .keepAlways
    add(attachment)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
  }

  private func expectHomeState(_ app: XCUIApplication, count: Int) throws {
    let state = try homeState(app)
    XCTAssertEqual(state["count"] as? Int, count)
    XCTAssertEqual(state["requests"] as? Int, 0, "Membership changes must not start a wall.")
    XCTAssertEqual(state["navigations"] as? Int, 0)
    for key in ["opening", "showing", "controller"] {
      XCTAssertEqual(state[key] as? Bool, false, "Unexpected playback state: \(state)")
    }
  }

  private func assertFrame(_ actual: CGRect, equals expected: CGRect, name: String) {
    for (old, new) in zip([expected.minX, expected.minY, expected.width, expected.height],
                          [actual.minX, actual.minY, actual.width, actual.height]) {
      XCTAssertEqual(new, old, accuracy: 0.01, name)
    }
  }

  private func focusHomeElement(_ target: XCUIElement, app: XCUIApplication) {
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    for step in 0..<8 {
      if target.hasFocus { return }
      let cards = ["following-twitch", "following-kick:kick", "following-selectedoffline",
        "following-offline", "following-youtube:youtube", "following-extra"]
        .map { app.descendants(matching: .any)[$0].firstMatch }
      let focused = (app.buttons.allElementsBoundByIndex + cards)
        .first { $0.exists && $0.hasFocus }
      let current = focused?.frame ?? .zero
      let direction: XCUIRemote.Button
      if target.frame.maxY < current.minY,
         focused?.identifier.hasPrefix("following-") == true,
         focused?.identifier != "following-directory",
         focused?.identifier != "following-refresh",
         target.frame.midX > current.maxX {
        // Native directional focus needs a card beneath the right-aligned header.
        direction = .right
      } else {
        direction = abs(target.frame.midY - current.midY) > 80
          ? (target.frame.midY < current.midY ? .up : .down)
          : (target.frame.midX < current.midX ? .left : .right)
      }
      press(direction, app: app, name: "native focus \(target.identifier) step \(step)")
    }
    XCTAssertTrue(target.hasFocus, app.debugDescription)
  }

  func testProductionCardPressMembershipInAllFocusWrappers() {
    continueAfterFailure = true
    for mode in ["rail", "grid", "tile"] {
      let app = launchFixture(count: 0, cards: mode)
      defer { app.terminate() }
      for key in ["twitch", "kick:kick"] {
        let card = focusCard(key, mode: mode, app: app)
        let durations: [TimeInterval?] = [nil, 0.3, 0.3, nil]
        for (index, duration) in durations.enumerated() {
          press(.playPause, duration: duration, app: app, name: "\(mode) \(key) toggle \(index)")
          let selected = index.isMultiple(of: 2)
          XCTAssertEqual(card.value as? String ?? "", selected ? "In multiview" : "")
          expectCardState(app, "count=\(selected ? 1 : 0)")
          expectCardState(app, "navigation=0")
          expectState(app, "requests=0")
          expectState(app, "short=0")
          XCTAssertTrue(card.hasFocus)
        }
      }
      app.terminate()
    }
  }

  func testProductionCardEligibilityCapacityAndRemoval() {
    let app = launchFixture(count: 3, cards: "grid")
    defer { app.terminate() }
    let offline = focusCard("selectedoffline", mode: "grid", app: app)
    XCTAssertEqual(offline.value as? String, "In multiview")
    press(.playPause, app: app, name: "remove selected offline card")
    XCTAssertEqual(offline.value as? String ?? "", "")
    expectCardState(app, "count=2")
    for key in ["selectedoffline", "offline", "youtube:youtube"] {
      _ = focusCard(key, mode: "grid", app: app)
      press(.playPause, duration: 0.3, app: app, name: "ineligible \(key) preserves short command")
      expectCardState(app, "count=2")
      expectState(app, "short=0")
      XCTAssertFalse(app.alerts.firstMatch.exists)
    }
    focus("shortcut-non-card", app: app)
    press(.playPause, app: app, name: "non-card preserves native short command")
    expectState(app, "short=1")
    expectCardState(app, "navigation=0")
    app.terminate()

    let full = launchFixture(count: 6, cards: "rail")
    defer { full.terminate() }
    _ = focusCard("extra", mode: "rail", app: full)
    press(.playPause, app: full, name: "full lineup feedback")
    let notice = full.alerts.firstMatch
    XCTAssertTrue(notice.waitForExistence(timeout: 3))
    XCTAssertTrue(notice.staticTexts["Multiview holds up to six streams."].exists)
    expectCardState(full, "count=6")
    press(.select, app: full, name: "acknowledge capacity")
    XCTAssertFalse(notice.exists)
    let selected = focusCard("twitch", mode: "rail", app: full)
    press(.playPause, duration: 0.3, app: full, name: "remove selected while full")
    XCTAssertEqual(selected.value as? String ?? "", "")
    expectCardState(full, "count=5")
    let extra = focusCard("extra", mode: "rail", app: full)
    press(.playPause, app: full, name: "fill released slot")
    XCTAssertEqual(extra.value as? String, "In multiview")
    expectCardState(full, "count=6")
    expectCardState(full, "navigation=0")
    expectState(full, "short=0")
  }

  func testProductionCardCapacityNotice() {
    let app = launchFixture(count: 6, cards: "tile")
    defer { app.terminate() }
    _ = focusCard("extra", mode: "tile", app: app)
    press(.playPause, duration: 0.3, app: app, name: "full lineup rejects seventh focused stream")
    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3), app.debugDescription)
    XCTAssertTrue(app.alerts.firstMatch.staticTexts["Multiview holds up to six streams."].exists)
  }

  func testProductionSelectedLiveCardsRemoveInFocusWrappers() {
    continueAfterFailure = true
    for mode in ["rail", "grid", "tile"] {
      let app = launchFixture(count: mode == "rail" ? 6 : 2, cards: mode)
      defer { app.terminate() }
      for key in ["twitch", "kick:kick"] {
        let card = focusCard(key, mode: mode, app: app)
        XCTAssertEqual(card.value as? String, "In multiview")
        press(.playPause, duration: 0.3, app: app, name: "\(mode) remove selected live \(key)")
        XCTAssertEqual(card.value as? String ?? "", "")
        expectCardState(app, "navigation=0")
      }
      app.terminate()
    }
  }

  func testProductionUnsupportedCardsAndNonCardControlRemainUnchanged() {
    let app = launchFixture(count: 0, cards: "grid")
    defer { app.terminate() }
    for key in ["offline", "youtube:youtube"] {
      _ = focusCard(key, mode: "grid", app: app)
      press(.playPause, duration: 0.3, app: app, name: "unsupported \(key) remains unchanged")
      expectCardState(app, "count=0")
      expectCardState(app, "navigation=0")
      XCTAssertFalse(app.alerts.firstMatch.exists)
    }
    focus("shortcut-non-card", app: app)
    press(.playPause, app: app, name: "non-card native command still delivered")
    expectState(app, "short=1")
    expectCardState(app, "count=0")
  }

  func testProductionCardHoldAndRealPlayerTransport() throws {
    let single = launchFixture(count: 1, cards: "tile")
    defer { single.terminate() }
    let card = focusCard("twitch", mode: "tile", app: single)
    press(.playPause, duration: 1.1, app: single, name: "one-card hold remains selected")
    let toast = single.descendants(matching: .any)["multiview-shortcut-toast"].firstMatch
    XCTAssertTrue(toast.waitForExistence(timeout: 2))
    XCTAssertTrue(toast.label.contains("Add another stream"))
    XCTAssertTrue(toast.isHittable)
    XCTAssertEqual(card.value as? String, "In multiview")
    expectCardState(single, "count=1")
    expectState(single, "short=0")
    expectState(single, "requests=0")
    single.terminate()

    let app = launchFixture(count: 2, cards: "rail")
    defer { app.terminate() }
    _ = focusCard("twitch", mode: "rail", app: app)
    press(.playPause, duration: 1.1, app: app, name: "card hold opens real mounted wall")
    let pane = app.buttons["multiview-pane-Twitch"]
    XCTAssertTrue(pane.waitForExistence(timeout: 20), app.debugDescription)
    let diagnostic = app.descendants(matching: .any)["layout-fixture-state"].firstMatch
    XCTAssertTrue(diagnostic.waitForExistence(timeout: 10))
    func state() throws -> [String: Any] {
      let value = try XCTUnwrap(diagnostic.value as? String)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }
    let before = try state()
    let original = try XCTUnwrap(before["panes"] as? [[String: Any]])
    XCTAssertEqual(original.count, 2, "Hold release must not toggle the focused card.")
    XCTAssertFalse(app.buttons["multiview-layout"].exists)
    press(.playPause, app: app, name: "ordinary production wall short opens controls")
    XCTAssertTrue(app.buttons["multiview-layout"].waitForExistence(timeout: 5))
    press(.playPause, app: app, name: "ordinary production wall short closes controls")
    XCTAssertFalse(app.buttons["multiview-layout"].exists)
    press(.select, app: app, name: "expand real selected player")
    XCTAssertFalse(try XCTUnwrap(try state()["expanded"] as? String).isEmpty)
    press(.playPause, app: app, name: "ordinary expanded player pause")
    var panes = try XCTUnwrap(try state()["panes"] as? [[String: Any]])
    XCTAssertEqual(panes[0]["rate"] as? Double, 0)
    press(.playPause, app: app, name: "ordinary expanded player resume")
    panes = try XCTUnwrap(try state()["panes"] as? [[String: Any]])
    XCTAssertGreaterThan(try XCTUnwrap(panes[0]["rate"] as? Double), 0)
    press(.playPause, duration: 1.1, app: app, name: "hold collapses real player without pause")
    XCTAssertEqual(try state()["expanded"] as? String, "")
    panes = try XCTUnwrap(try state()["panes"] as? [[String: Any]])
    for (old, new) in zip(original, panes) {
      for key in ["id", "model", "player", "item", "surface"] {
        XCTAssertEqual(old[key] as? String, new[key] as? String, "Hold retains \(key)")
      }
    }
    press(.menu, app: app, name: "browse after real hold")
    expectSurface(app, "home")
    expectCardState(app, "count=2")
    expectCardState(app, "navigation=0")
    expectState(app, "short=0")
    expectState(app, "requests=2")
  }

  private func expectCardState(_ app: XCUIApplication, _ value: String) {
    let state = app.staticTexts["shortcut-card-state"].label
    XCTAssertTrue(state.components(separatedBy: ";").contains(value), "Expected \(value): \(state)")
  }

  @discardableResult
  private func focusCard(_ key: String, mode: String, app: XCUIApplication) -> XCUIElement {
    let prefix = mode == "rail" ? "shortcut-card-" : "stream-card-"
    let target = app.descendants(matching: .any)[prefix + key].firstMatch
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    let candidates = ["twitch", "kick:kick", "selectedoffline", "offline", "youtube:youtube", "extra"]
      .map { app.descendants(matching: .any)[prefix + $0].firstMatch }
      + [app.buttons["shortcut-non-card"]]
    for step in 0..<8 {
      if target.hasFocus { return target }
      let current = candidates.first(where: { $0.exists && $0.hasFocus })?.frame ?? .zero
      let direction: XCUIRemote.Button = abs(target.frame.midY - current.midY) > 80
        ? (target.frame.midY < current.midY ? .up : .down)
        : (target.frame.midX < current.midX ? .left : .right)
      press(direction, app: app, name: "\(mode) focus \(key) step \(step)")
    }
    XCTAssertTrue(target.hasFocus, app.debugDescription)
    return target
  }

  func testBriefAndSubthresholdPressDeliverOneShortCommandEach() {
    let app = launchFixture(count: 2)
    defer { app.terminate() }
    press(.playPause, app: app, name: "brief")
    expectState(app, "short=1")
    expectState(app, "requests=0")
    press(.playPause, duration: 0.3, app: app, name: "subthreshold")
    expectState(app, "short=2")
    expectState(app, "requests=0")
    expectSurface(app, "home")
  }

  func testLongRepeatedAndVeryLongHoldsDoNotDeliverShortCommands() {
    let app = launchFixture(count: 2)
    defer { app.terminate() }
    press(.playPause, duration: 1.1, app: app, name: "first hold")
    expectSurface(app, "wall")
    expectState(app, "requests=1")
    expectState(app, "short=0")
    let identity = activeText("shortcut-identities", app: app).label
    press(.playPause, duration: 1.1, app: app, name: "wall repeated hold")
    expectState(app, "requests=2")
    expectState(app, "short=0")
    expectState(app, "hud=false")
    expectState(app, "paused=false")
    XCTAssertEqual(activeText("shortcut-identities", app: app).label, identity)
    press(.playPause, duration: 4, app: app, name: "very long wall hold")
    expectState(app, "requests=3")
    expectState(app, "short=0")
    XCTAssertEqual(activeText("shortcut-identities", app: app).label, identity)
    focus("shortcut-expand", app: app)
    press(.select, app: app, name: "expand mounted pane")
    expectSurface(app, "expanded")
    press(.playPause, duration: 1.1, app: app, name: "expanded hold collapses")
    expectSurface(app, "wall")
    expectState(app, "requests=4")
    expectState(app, "short=0")
    XCTAssertEqual(activeText("shortcut-identities", app: app).label, identity)
    press(.playPause, app: app, name: "ordinary wall transport")
    expectState(app, "short=1")
    expectState(app, "hud=true")
    expectState(app, "paused=true")
  }

  func testZeroLineupToastKeepsHomeSelectionAndFocus() {
    verifyToast(count: 0, modal: false)
  }

  func testOneLineupToastKeepsHomeSelectionAndFocus() {
    verifyToast(count: 1, modal: false)
  }

  func testZeroLineupToastAboveCoverKeepsSelectionAndFocus() {
    verifyToast(count: 0, modal: true)
  }

  func testOneLineupToastAboveCoverKeepsSelectionAndFocus() {
    verifyToast(count: 1, modal: true)
  }

  func testLightOpaqueToastAboveCover() {
    verifyToast(count: 0, modal: true, lightOpaque: true)
  }

  func testNestedPresentationsDismissBindingsAndReopen() {
    let app = launchFixture(count: 2)
    defer { app.terminate() }
    for iteration in 1...2 {
      focus("shortcut-open-sheet", app: app)
      press(.select, app: app, name: "open sheet \(iteration)")
      expectSurface(app, "sheet")
      expectState(app, "sheet=true")
      focus("shortcut-open-nested-cover", app: app)
      press(.select, app: app, name: "open cover \(iteration)")
      expectSurface(app, "cover")
      focus("shortcut-open-nested-sheet", app: app)
      press(.select, app: app, name: "open nested sheet \(iteration)")
      expectSurface(app, "nested")
      expectState(app, "nested=true")
      press(.playPause, duration: 1.1, app: app, name: "hold through nested presentations \(iteration)")
      expectSurface(app, "wall")
      expectState(app, "requests=\(iteration)")
      expectState(app, "short=0")
      expectState(app, "sheet=false")
      expectState(app, "cover=false")
      expectState(app, "nested=false")
      press(.menu, app: app, name: "browse after nested dismissal \(iteration)")
      expectSurface(app, "home")
    }
  }

  func testDirectCoverDismissesAndCanReopen() {
    let app = launchFixture(count: 2)
    defer { app.terminate() }
    for iteration in 1...2 {
      focus("shortcut-open-cover", app: app)
      press(.select, app: app, name: "open direct cover \(iteration)")
      expectSurface(app, "cover")
      press(.playPause, duration: 1.1, app: app, name: "hold direct cover \(iteration)")
      expectSurface(app, "wall")
      expectState(app, "cover=false")
      expectState(app, "short=0")
      press(.menu, app: app, name: "return from direct cover \(iteration)")
      expectSurface(app, "home")
    }
  }

  func testAutomaticDismissPromptCannotInterposePlaybackHandoff() {
    let ordinary = launchFixture(count: 2, automaticPrompt: true)
    defer { ordinary.terminate() }
    focus("shortcut-open-cover", app: ordinary)
    press(.select, app: ordinary, name: "open ordinary onboarding cover")
    expectSurface(ordinary, "cover")
    focus("shortcut-close-cover", app: ordinary)
    press(.select, app: ordinary, name: "ordinary cover dismissal triggers prompt")
    expectSurface(ordinary, "prompt")
    expectHandoff(ordinary, "dismissals=1")
    expectHandoff(ordinary, "prompts=1")
    expectHandoff(ordinary, "openingAtDismiss=false")
    expectHandoff(ordinary, "visibleAtDismiss=false")
    expectState(ordinary, "requests=0")
    focus("shortcut-close-prompt", app: ordinary)
    press(.select, app: ordinary, name: "dismiss ordinary onboarding prompt")
    expectSurface(ordinary, "home")
    expectHandoff(ordinary, "hasPrompted=true")
    ordinary.terminate()

    let held = launchFixture(count: 2, automaticPrompt: true)
    defer { held.terminate() }
    expectHandoff(held, "hasPrompted=false")
    focus("shortcut-open-cover", app: held)
    press(.select, app: held, name: "open eligible onboarding cover")
    expectSurface(held, "cover")
    press(.playPause, duration: 1.1, app: held, name: "hold reserves playback before onDismiss")
    expectSurface(held, "wall")
    expectState(held, "requests=1")
    expectState(held, "short=0")
    expectState(held, "cover=false")
    expectHandoff(held, "dismissals=1")
    expectHandoff(held, "prompts=0")
    expectHandoff(held, "prompt=false")
    expectHandoff(held, "openingAtDismiss=true")
    expectHandoff(held, "visibleAtDismiss=false")
    expectHandoff(held, "requestsAtDismiss=0")
    expectHandoff(held, "opening=false")
    Thread.sleep(forTimeInterval: 1)
    capture(held, "playback wall without deferred onboarding prompt")
    expectSurface(held, "wall")
    expectHandoff(held, "prompts=0")
    XCTAssertFalse(held.staticTexts["shortcut-surface-prompt"].exists)
  }

  func testModalShortPressesRemainNative() {
    let app = launchFixture(count: 2)
    defer { app.terminate() }
    focus("shortcut-open-sheet", app: app)
    press(.select, app: app, name: "open sheet for short commands")
    expectSurface(app, "sheet")
    press(.playPause, app: app, name: "native short in sheet")
    expectState(app, "short=1")
    press(.playPause, duration: 0.3, app: app, name: "subthreshold in sheet")
    expectState(app, "short=2")
    expectState(app, "requests=0")
    focus("shortcut-open-nested-cover", app: app)
    press(.select, app: app, name: "open cover for short command")
    expectSurface(app, "cover")
    press(.playPause, app: app, name: "native short in cover")
    expectState(app, "short=3")
    expectState(app, "requests=0")
    press(.playPause, duration: 1.1, app: app, name: "cover hold after native short")
    expectSurface(app, "wall")
    expectState(app, "short=3")
    expectState(app, "requests=1")
  }

  func testContextMenuOrdinaryActionThenHold() {
    let app = launchFixture(count: 2)
    defer { app.terminate() }
    focus("shortcut-context", app: app)
    press(.select, duration: 1.2, app: app, name: "ordinary native context")
    let action = app.cells.containing(.any, identifier: "shortcut-context-action").firstMatch
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    if !action.hasFocus { press(.down, app: app, name: "focus native context action") }
    XCTAssertTrue(action.hasFocus)
    press(.select, app: app, name: "perform ordinary context action")
    expectState(app, "context=1")
    focus("shortcut-context", app: app)
    press(.select, duration: 1.2, app: app, name: "native context before shortcut")
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    press(.playPause, duration: 1.1, app: app, name: "hold from native context")
    expectSurface(app, "wall")
    expectState(app, "requests=1")
    expectState(app, "short=0")
  }

  func testKeyboardOrdinaryMenuDismissalThenHold() {
    let app = launchFixture(count: 2)
    defer { app.terminate() }
    focus("shortcut-search", app: app, isTextField: true)
    press(.select, app: app, name: "open native keyboard")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    press(.menu, app: app, name: "ordinary keyboard dismissal")
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    expectSurface(app, "home")
    focus("shortcut-search", app: app, isTextField: true)
    press(.select, app: app, name: "reopen native keyboard")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    press(.playPause, duration: 1.1, app: app, name: "hold from native keyboard")
    expectSurface(app, "wall")
    expectState(app, "requests=1")
    expectState(app, "short=0")
  }

  func testProductionHomeWallAndExpandedPaneShortcut() throws {
    let app = try launchProduction()
    defer { app.terminate() }
    let panes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'multiview-pane-' AND enabled == true"))
    XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 30))
    XCTAssertEqual(panes.count, 2)
    capture(app, "production seeded wall")
    press(.menu, app: app, name: "browse to real Home")
    XCTAssertTrue(app.buttons["multiview-lineup"].waitForExistence(timeout: 10))
    press(.playPause, duration: 1.1, app: app, name: "hold from real Home")
    XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(panes.count, 2)
    let initialIDs = panes.allElementsBoundByIndex.map(\.identifier)
    press(.playPause, duration: 1.1, app: app, name: "hold on real wall")
    XCTAssertFalse(app.buttons["multiview-layout"].exists, "A long hold must not toggle the wall HUD.")
    XCTAssertEqual(panes.allElementsBoundByIndex.map(\.identifier), initialIDs)
    press(.right, app: app, name: "focus real pane")
    // The production pane's AX wrapper does not consistently expose UIKit focus;
    // Select must expand the right-hand pane reached by the real Right event.
    let pane = panes.element(boundBy: 1)
    let id = String(pane.identifier.dropFirst("multiview-pane-".count))
    press(.select, app: app, name: "expand real pane")
    let expanded = app.descendants(matching: .any)["expanded-stream-\(id)"].firstMatch
    XCTAssertTrue(expanded.waitForExistence(timeout: 5))
    press(.playPause, duration: 1.1, app: app, name: "hold collapses real pane")
    XCTAssertTrue(pane.waitForExistence(timeout: 5))
    XCTAssertFalse(expanded.exists)
    XCTAssertEqual(panes.allElementsBoundByIndex.map(\.identifier), initialIDs)
    press(.playPause, app: app, name: "real wall short press")
    XCTAssertTrue(app.buttons["multiview-layout"].waitForExistence(timeout: 5))
  }

  func testProductionSettingsAndSearchShortcut() throws {
    let app = try launchProduction()
    defer { app.terminate() }
    let panes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'multiview-pane-' AND enabled == true"))
    XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 30))
    for tab in ["Settings", "Search"] {
      press(.menu, app: app, name: "browse before \(tab)")
      XCTAssertTrue(panes.firstMatch.waitForNonExistence(timeout: 10))
      XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 10))
      for step in 0..<8 {
        let target = app.buttons[tab].firstMatch
        if target.exists && target.hasFocus { break }
        let anyTabFocused = ["Home", "Browse", "Search", "Settings"].contains {
          app.buttons[$0].firstMatch.exists && app.buttons[$0].firstMatch.hasFocus
        }
        press(anyTabFocused ? (tab == "Search" && app.buttons["Settings"].firstMatch.hasFocus ? .left : .right) : .up,
          app: app, name: "\(tab) tab navigation \(step)")
      }
      XCTAssertTrue(app.buttons[tab].firstMatch.hasFocus)
      press(.select, app: app, name: "select real \(tab)")
      if tab == "Search" { XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10)) }
      press(.down, app: app, name: "enter real \(tab)")
      press(.playPause, duration: 1.1, app: app, name: "hold from real \(tab)")
      XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 10))
      XCTAssertEqual(panes.count, 2)
    }
  }

  private func verifyToast(count: Int, modal: Bool, lightOpaque: Bool = false) {
    let app = launchFixture(count: count, lightOpaque: lightOpaque)
    defer { app.terminate() }
    if modal {
      focus("shortcut-open-cover", app: app)
      press(.select, app: app, name: "open insufficient-lineup cover")
      expectSurface(app, "cover")
    }
    focus("shortcut-select-B", app: app)
    press(.select, app: app, name: "select B before toast")
    expectState(app, "selection=B")
    let identity = activeText("shortcut-identities", app: app).label
    let button = panel(app).buttons["shortcut-select-B"]
    XCTAssertTrue(button.hasFocus)
    press(.playPause, duration: 1.1, app: app, name: "insufficient lineup hold")
    let toast = app.descendants(matching: .any)["multiview-shortcut-toast"].firstMatch
    XCTAssertTrue(toast.waitForExistence(timeout: 2))
    XCTAssertTrue(toast.label.contains(count == 0 ? "Add two streams" : "Add another stream"))
    XCTAssertTrue(toast.isHittable, "The toast must be visible above the current presentation.")
    expectState(app, "requests=0")
    expectState(app, "short=0")
    expectState(app, "selection=B")
    XCTAssertTrue(button.hasFocus)
    XCTAssertEqual(activeText("shortcut-identities", app: app).label, identity)
    press(.playPause, duration: 1.1, app: app, name: "refresh insufficient-lineup toast")
    XCTAssertTrue(toast.exists)
    expectState(app, "short=0")
    Thread.sleep(forTimeInterval: 1.1)
    capture(app, "toast after original deadline")
    XCTAssertTrue(toast.exists, "The second hold must refresh the existing timeout.")
    XCTAssertTrue(button.hasFocus)
    XCTAssertTrue(toast.waitForNonExistence(timeout: 5))
    capture(app, "toast timed out")
    expectSurface(app, modal ? "cover" : "home")
    expectState(app, "selection=B")
    XCTAssertTrue(button.hasFocus)
    XCTAssertEqual(activeText("shortcut-identities", app: app).label, identity)
  }

  private func launchFixture(count: Int, lightOpaque: Bool = false,
                             automaticPrompt: Bool = false, cards: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MULTIVIEW_SHORTCUT_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_MULTIVIEW_SHORTCUT_COUNT"] = String(count)
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    if let cards { app.launchEnvironment["STROZZ_MULTIVIEW_SHORTCUT_CARDS"] = cards }
    if lightOpaque {
      app.launchEnvironment["STROZZ_MULTIVIEW_SHORTCUT_THEME"] = "light"
      app.launchEnvironment["STROZZ_MULTIVIEW_SHORTCUT_OPAQUE"] = "1"
    }
    if automaticPrompt {
      app.launchEnvironment["STROZZ_MULTIVIEW_SHORTCUT_AUTOPROMPT"] = "1"
    }
    app.launch()
    expectSurface(app, "home")
    capture(app, "fixture initial count \(count)")
    return app
  }

  private func launchProduction() throws -> XCUIApplication {
    guard let channels = ProcessInfo.processInfo.environment["STROZZ_MATRIX_CHANNELS"],
      channels.split(separator: ",").count == 2 else {
      throw XCTSkip("Provide two currently live STROZZ_MATRIX_CHANNELS; fake channels are retired by real Home status refresh.")
    }
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MULTIVIEW_UI_CHANNELS"] = channels
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES"]
    app.launch()
    return app
  }

  private func expectSurface(_ app: XCUIApplication, _ name: String) {
    currentSurface = name
    let element = activeText("shortcut-surface", app: app)
    let predicate = NSPredicate(format: "label == %@", "Shortcut \(name)")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
      timeout: 5), .completed, app.debugDescription)
  }

  private func expectState(_ app: XCUIApplication, _ value: String) {
    let state = activeText("shortcut-state", app: app).label
    XCTAssertTrue(state.components(separatedBy: ";").contains(value), "Expected \(value): \(state)")
  }

  private func expectHandoff(_ app: XCUIApplication, _ value: String) {
    let state = activeText("shortcut-handoff", app: app).label
    XCTAssertTrue(state.components(separatedBy: ";").contains(value), "Expected \(value): \(state)")
  }

  private func activeText(_ identifier: String, app: XCUIApplication) -> XCUIElement {
    app.staticTexts["\(identifier)-\(currentSurface)"]
  }

  private func panel(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["shortcut-panel-\(currentSurface)"].firstMatch
  }

  private func focus(_ identifier: String, app: XCUIApplication, isTextField: Bool = false) {
    let surface = panel(app)
    let element = isTextField ? surface.textFields[identifier] : surface.buttons[identifier]
    XCTAssertTrue(element.waitForExistence(timeout: 5))
    for step in 0..<10 {
      if element.hasFocus { return }
      let focused = (surface.buttons.allElementsBoundByIndex + surface.textFields.allElementsBoundByIndex)
        .first(where: \.hasFocus)
      let target = element.frame
      let current = focused?.frame ?? CGRect.zero
      let direction: XCUIRemote.Button = abs(target.midY - current.midY) > 30
        ? (target.midY < current.midY ? .up : .down)
        : (target.midX < current.midX ? .left : .right)
      press(direction, app: app, name: "focus \(identifier) step \(step)")
      Thread.sleep(forTimeInterval: 0.3)
    }
    XCTAssertTrue(element.hasFocus, app.debugDescription)
  }

  private func press(_ button: XCUIRemote.Button, duration: TimeInterval? = nil,
                     app: XCUIApplication, name: String) {
    capture(app, "before \(name)")
    if let duration { XCUIRemote.shared.press(button, forDuration: duration) }
    else { XCUIRemote.shared.press(button) }
    capture(app, "after \(name)")
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name) hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }
}

import XCTest

@MainActor
final class MultiviewShortcutUITests: XCTestCase {
  private var currentSurface = "home"

  override func setUp() {
    continueAfterFailure = false
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
    XCTAssertFalse(app.buttons["Spotlight"].exists, "A long hold must not toggle the wall HUD.")
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
    XCTAssertTrue(app.buttons["Spotlight"].waitForExistence(timeout: 5))
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
                             automaticPrompt: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MULTIVIEW_SHORTCUT_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_MULTIVIEW_SHORTCUT_COUNT"] = String(count)
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
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

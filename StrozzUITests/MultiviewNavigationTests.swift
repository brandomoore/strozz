import XCTest

@MainActor
final class MultiviewNavigationTests: XCTestCase {
  // AX success does not prove video/outline alignment: review the retained native screenshots too.
  func testOptInLivePictureGeometryAndRemoteFocus() throws {
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_MULTIVIEW_UI_TESTS"] == "1",
      let input = settings["STROZZ_MATRIX_CHANNELS"] else {
      throw XCTSkip("Explicitly select live channels for picture/outline review.")
    }
    let channels = input.split(separator: ",").map(String.init)
    let counts = settings["STROZZ_GEOMETRY_COUNTS"]?.split(separator: ",").compactMap { Int($0) } ?? [2, 3, 4]
    continueAfterFailure = false
    for count in counts {
      XCTAssertTrue([2, 3, 4, 6].contains(count))
      XCTAssertGreaterThanOrEqual(channels.count, min(count, 4))
      let app = XCUIApplication()
      app.launchEnvironment["STROZZ_MULTIVIEW_UI_CHANNELS"] = channels.prefix(min(count, 4)).joined(separator: ",")
      app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
      app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES"]
      app.launch()
      defer { app.terminate() }
      let panes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'multiview-pane-'"))
      XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 30))
      if count == 6 { addTwoLiveHomeChannels(app) }
      let allLive = NSPredicate { _, _ in
        panes.count == count && panes.allElementsBoundByIndex.allSatisfy { $0.value as? String == "Live" }
      }
      let ready = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: allLive, object: nil)], timeout: 60)
      capture(app, name: "\(count) grid playback readiness")
      XCTAssertEqual(ready, .completed, "Every pane must be live; placeholders cannot establish pixel alignment.")
      for layout in ["featured", "grid", "spotlight"] {
        if layout != "featured" {
          XCUIRemote.shared.press(.playPause)
          let toggle = app.buttons["multiview-layout"]
          XCTAssertTrue(toggle.waitForExistence(timeout: 5))
          capture(app, name: "\(count) layout HUD")
          XCTAssertTrue(toggle.hasFocus || toggle.descendants(matching: .any)
            .allElementsBoundByIndex.contains(where: \.hasFocus))
          XCUIRemote.shared.press(.select)
          let titles = ["featured": "Featured", "spotlight": "Spotlight", "grid": "Equal"]
          let choice = app.cells.containing(.any, identifier: titles[layout]!).firstMatch
          XCTAssertTrue(choice.waitForExistence(timeout: 5))
          for _ in 0..<3 {
            if choice.hasFocus { break }
            XCUIRemote.shared.press(layout == "grid" ? .down : .up)
          }
          XCTAssertTrue(choice.hasFocus)
          XCUIRemote.shared.press(.select)
          capture(app, name: "\(count) \(layout) HUD")
          XCUIRemote.shared.press(.menu)
        } else {
          XCUIRemote.shared.press(.left)
        }
        capture(app, name: "\(count) \(layout) active")
        for pane in panes.allElementsBoundByIndex {
          print("PICTURE_GEOMETRY count=\(count) layout=\(layout) id=\(pane.identifier) frame=\(pane.frame) status=\(pane.value ?? "") focused=\(pane.hasFocus)")
        }
        Thread.sleep(forTimeInterval: 11)
        capture(app, name: "\(count) \(layout) idle")
        let route: [XCUIRemote.Button] = layout == "spotlight"
          ? [.down, .right, .left, .up]
          : count == 2 ? [.right, .left] : count == 3 ? [.right, .down, .left]
          : count == 6 ? [.right, .right, .down, .left, .left, .up] : [.right, .down, .left, .up]
        for (index, direction) in route.enumerated() {
          XCUIRemote.shared.press(direction)
          capture(app, name: "\(count) \(layout) focus \(index)")
          XCTAssertTrue(panes.allElementsBoundByIndex.contains(where: \.hasFocus))
        }
        guard let focused = panes.allElementsBoundByIndex.first(where: \.hasFocus) else {
          XCTFail("No pane focused before expansion")
          return
        }
        let selected = String(focused.identifier.dropFirst("multiview-pane-".count))
        XCUIRemote.shared.press(.select)
        let expanded = app.descendants(matching: .any)["expanded-stream-\(selected)"].firstMatch
        XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        capture(app, name: "\(count) \(layout) expanded")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: focused)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        capture(app, name: "\(count) \(layout) returned")
      }
      app.terminate()
    }
  }

  private func addTwoLiveHomeChannels(_ app: XCUIApplication) {
    capture(app, name: "Six pane setup seeded four")
    XCUIRemote.shared.press(.menu)
    let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'topstreams-'"))
    XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20))
    capture(app, name: "Six pane setup Home")
    for _ in 0..<6 {
      if cards.allElementsBoundByIndex.contains(where: \.hasFocus) { break }
      XCUIRemote.shared.press(.down)
      capture(app, name: "Six pane setup find top streams")
    }
    XCTAssertTrue(cards.allElementsBoundByIndex.contains(where: \.hasFocus))
    var added = 0
    for index in 0..<12 {
      if let focused = cards.allElementsBoundByIndex.first(where: \.hasFocus),
        focused.value as? String == "In multiview" {
        XCUIRemote.shared.press(.right)
        capture(app, name: "Six pane setup skip selected \(index)")
        continue
      }
      XCUIRemote.shared.press(.select, forDuration: 1.2)
      let action = app.descendants(matching: .any).matching(NSPredicate(
        format: "identifier BEGINSWITH 'multiview-toggle-' AND label == 'Add to multiview'")).firstMatch
      capture(app, name: "Six pane setup context \(index)")
      if action.exists {
        focusContextAction(action.identifier, app: app)
        capture(app, name: "Six pane setup add \(added + 1)")
        XCUIRemote.shared.press(.select)
        added += 1
      } else {
        XCUIRemote.shared.press(.menu)
      }
      capture(app, name: "Six pane setup selection \(index)")
      if added == 2 { break }
      XCUIRemote.shared.press(.right)
      capture(app, name: "Six pane setup next candidate \(index)")
    }
    XCTAssertEqual(added, 2, "Six-pane review needs two additional real live channels.")
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    focusContextAction("multiview-context-start", app: app)
    capture(app, name: "Six pane setup return to wall")
    XCUIRemote.shared.press(.select)
  }

  private func focusContextAction(_ identifier: String, app: XCUIApplication) {
    let cell = app.cells.containing(.any, identifier: identifier).firstMatch
    XCTAssertTrue(cell.waitForExistence(timeout: 5))
    for _ in 0..<5 {
      if cell.hasFocus { break }
      XCUIRemote.shared.press(.down)
    }
    XCTAssertTrue(cell.hasFocus)
  }

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
    XCTAssertTrue(app.buttons["multiview-layout"].waitForExistence(timeout: 5))
  }

  private func capture(_ app: XCUIApplication, name: String) {
    Thread.sleep(forTimeInterval: 0.5)
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

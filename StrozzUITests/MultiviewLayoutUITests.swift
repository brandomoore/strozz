import XCTest
import UIKit
import Vision

@MainActor
final class MultiviewLayoutUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testNativeLayoutMenuHasAccessibleName() throws {
    let app = try launch(count: 2)
    defer { app.terminate() }
    press(.playPause, app: app, "Layout menu accessibility name")
    XCTAssertEqual(app.buttons["multiview-layout"].label, "Layout",
      "The menu button needs an accessible name, not only its current layout value.")
  }

  func testControlAccessibilityIdentifiersRemainDistinct() throws {
    let app = try launch(count: 2)
    defer { app.terminate() }
    press(.playPause, app: app, "inspect leaf identifiers")
    XCTAssertTrue(app.buttons["multiview-layout"].exists)
    XCTAssertTrue(app.buttons["multiview-browse"].exists)
    XCTAssertTrue(app.buttons["multiview-controls-done"].exists)
    press(.select, app: app, "inspect choice identifiers")
    for title in ["Featured", "Spotlight", "Equal"] {
      XCTAssertEqual(app.cells.containing(.any, identifier: title).count, 1)
    }
    assertSelectedLayout("featured", app: app)
  }

  func testToolbarLayoutPickerBackAndPlayerIdentity() throws {
    let app = try launch(count: 6)
    defer { app.terminate() }
    press(.right, app: app, "focus secondary")
    let before = try state(app)
    let audio = try XCTUnwrap(before["audio"] as? String)
    XCTAssertNotEqual(audio, "layout-0")
    press(.playPause, app: app, "open bottom toolbar")
    expectFocus("multiview-layout", app: app)
    try assertIdentity(before, try state(app))
    try assertAudio(audio, app: app)
    let toolbarState = try state(app)
    let toolbarFrames = toolbarControls(app).map(\.frame)
    press(.select, app: app, "open layout picker")
    XCTAssertEqual(toolbarFrames, toolbarControls(app).map(\.frame))
    try assertPictureFrames(toolbarState, try state(app))
    expectFocus("multiview-layout-featured", app: app)
    assertSelectedLayout("featured", app: app)
    press(.down, app: app, "focus Spotlight")
    expectFocus("multiview-layout-spotlight", app: app)
    press(.select, app: app, "select Spotlight")
    expectFocus("multiview-layout", app: app)
    XCTAssertEqual(try state(app)["layout"] as? String, "spotlight")
    try assertIdentity(before, try state(app))
    try assertAudio(audio, app: app)
    press(.select, app: app, "reopen picker")
    expectFocus("multiview-layout-featured", app: app)
    assertSelectedLayout("spotlight", app: app)
    press(.menu, app: app, "Back closes only picker")
    expectFocus("multiview-layout", app: app)
    XCTAssertFalse(control("multiview-layout-spotlight", app: app).exists)
    press(.up, app: app, "wall disabled above toolbar")
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'multiview-pane-' AND enabled == true")).firstMatch.exists)
    try assertAudio(audio, app: app)
    Thread.sleep(forTimeInterval: 11)
    capture(app, "toolbar survives chrome idle timeout")
    XCTAssertTrue(control("multiview-layout", app: app).exists)
    press(.menu, app: app, "Back restores original pane")
    XCTAssertFalse(control("multiview-layout", app: app).exists)
    try assertAudio(audio, app: app)
    try assertIdentity(before, try state(app))
    press(.select, app: app, "expand restored pane")
    XCTAssertEqual(try state(app)["expanded"] as? String, audio)
    try assertIdentity(before, try state(app))
    press(.menu, app: app, "collapse same player")
    XCTAssertEqual(try state(app)["expanded"] as? String, "")
    try assertAudio(audio, app: app)
    try assertIdentity(before, try state(app))
  }

  func testContextLayoutMakePrimaryAndEqualExclusion() throws {
    let app = try launch(count: 4)
    defer { app.terminate() }
    press(.right, app: app, "focus secondary")
    let before = try state(app)
    let audio = try XCTUnwrap(before["audio"] as? String)
    press(.select, duration: 1.2, app: app, "hold secondary")
    let makePrimary = app.cells.containing(.any, identifier: "multiview-make-primary-\(audio)").firstMatch
    XCTAssertTrue(makePrimary.waitForExistence(timeout: 5))
    focusCell(makePrimary, app: app)
    press(.select, app: app, "make secondary primary")
    XCTAssertEqual(try state(app)["primary"] as? String, audio)
    try assertAudio(audio, app: app)
    try assertIdentity(before, try state(app))
    press(.select, duration: 1.2, app: app, "hold new primary")
    XCTAssertFalse(app.descendants(matching: .any)["multiview-make-primary-\(audio)"].firstMatch.exists)
    let layout = app.cells.containing(.any, identifier: "multiview-context-layout").firstMatch
    XCTAssertTrue(layout.waitForExistence(timeout: 5))
    focusCell(layout, app: app)
    press(.select, app: app, "context Layout opens native submenu")
    expectFocus("multiview-layout-featured", app: app)
    assertSelectedLayout("featured", app: app)
    press(.down, app: app, "picker Spotlight")
    press(.down, app: app, "picker Equal")
    expectFocus("multiview-layout-grid", app: app)
    press(.select, app: app, "select Equal")
    XCTAssertFalse(control("multiview-layout", app: app).exists, "Context submenu returns directly to the pane.")
    try assertAudio(audio, app: app)
    XCTAssertEqual(try state(app)["layout"] as? String, "grid")
    press(.select, duration: 1.2, app: app, "hold Equal pane")
    XCTAssertTrue(app.cells.containing(.any, identifier: "multiview-context-layout").firstMatch.exists)
    XCTAssertFalse(app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'multiview-make-primary-'")).firstMatch.exists)
    capture(app, "Equal context excludes Make primary")
    press(.menu, app: app, "dismiss Equal context")
    try assertIdentity(before, try state(app))
  }

  func testLegacyAddAndLineupBrowseRoutes() throws {
    let legacy = try launch(count: 2)
    defer { legacy.terminate() }
    press(.playPause, app: legacy, "legacy controls")
    XCTAssertTrue(control("multiview-browse", app: legacy).label.contains("Add stream"))
    press(.right, app: legacy, "focus legacy Add")
    expectFocus("multiview-browse", app: legacy)
    press(.select, app: legacy, "open real legacy Add picker")
    XCTAssertTrue(legacy.staticTexts["Add stream"].waitForExistence(timeout: 5))
    capture(legacy, "legacy Add picker")
    press(.menu, app: legacy, "cancel legacy Add picker")
    XCTAssertTrue(control("multiview-layout", app: legacy).waitForExistence(timeout: 5))
    legacy.terminate()

    let app = try launch(count: 3, lineup: true)
    defer { app.terminate() }
    let before = try state(app)
    press(.playPause, app: app, "lineup controls")
    XCTAssertTrue(control("multiview-browse", app: app).label.contains("Browse streams"))
    press(.right, app: app, "focus Browse")
    press(.select, app: app, "browse retained lineup")
    XCTAssertTrue(app.buttons["layout-fixture-return"].waitForExistence(timeout: 5))
    XCTAssertEqual(try state(app)["browsing"] as? Bool, true)
    press(.select, app: app, "return retained lineup")
    XCTAssertTrue(app.buttons["multiview-pane-layout-0"].waitForExistence(timeout: 5))
    try assertIdentity(before, try state(app))
  }

  func testSpotlightContextFullScreenAndDone() throws {
    let app = try launch(count: 6, layout: "spotlight")
    defer { app.terminate() }
    press(.down, app: app, "Spotlight secondary")
    let before = try state(app)
    let audio = try XCTUnwrap(before["audio"] as? String)
    XCTAssertNotEqual(audio, "layout-0")
    press(.select, duration: 1.2, app: app, "hold Spotlight secondary")
    XCTAssertTrue(app.cells.containing(.any, identifier: "multiview-make-primary-\(audio)").firstMatch.exists)
    let fullScreen = app.cells.containing(.any, identifier: "Full screen").firstMatch
    XCTAssertTrue(fullScreen.exists)
    focusCell(fullScreen, app: app)
    press(.select, app: app, "context full screen")
    XCTAssertEqual(try state(app)["expanded"] as? String, audio)
    try assertIdentity(before, try state(app))
    press(.menu, app: app, "collapse context full screen")
    try assertAudio(audio, app: app)
    press(.playPause, app: app, "controls before Done")
    press(.right, app: app, "focus Done")
    expectFocus("multiview-controls-done", app: app)
    press(.select, app: app, "Done restores pane")
    XCTAssertFalse(control("multiview-layout", app: app).exists)
    try assertAudio(audio, app: app)
    try assertIdentity(before, try state(app))
  }

  func testNativeCountsLayoutsAndToolbarBounds() throws {
    for count in 1...6 {
      let app = try launch(count: count)
      defer { app.terminate() }
      let baseline = try state(app)
      for layout in ["featured", "spotlight", "grid"] {
        press(.playPause, app: app, "\(count) \(layout) toolbar")
        try assertPicturesAboveToolbar(app)
        press(.select, app: app, "\(count) \(layout) picker")
        focusLayout(layout, app: app)
        try assertControlsInViewport(app)
        press(.select, app: app, "\(count) choose \(layout)")
        XCTAssertEqual(try state(app)["layout"] as? String, layout)
        try assertPicturesAboveToolbar(app)
        try assertIdentity(baseline, try state(app))
        press(.menu, app: app, "\(count) \(layout) wall")
        capture(app, "\(count) \(layout) decoded wall")
      }
      app.terminate()
    }
  }

  func test854LogicalViewportControls() throws {
    continueAfterFailure = true
    try viewport(width: 854, height: 480)
  }
  func test854LineupToolbarBoundsAndLabels() throws {
    continueAfterFailure = true
    try viewport(width: 854, height: 480, lineup: true)
  }
  func test1920LineupNormalButtonSizesAndNativeChoices() throws {
    try viewport(width: 1920, height: 1080, lineup: true)
  }
  func test1280LogicalViewportControls() throws { try viewport(width: 1280, height: 720) }
  func test3840LogicalViewportControls() throws { try viewport(width: 3840, height: 2160) }

  private func viewport(width: Int, height: Int, lineup: Bool = false) throws {
    for count in [2, 6] {
      let app = try launch(count: count, width: width, height: height, lineup: lineup)
      defer { app.terminate() }
      press(.right, app: app, "\(width)x\(height) \(count) Featured secondary metadata")
      let before = try state(app)
      press(.playPause, app: app, "\(width)x\(height) toolbar")
      try assertNormalButtonSizes(app)
      let ids = ["multiview-layout"]
        + (control("multiview-browse", app: app).exists ? ["multiview-browse"] : [])
        + ["multiview-controls-done"]
      for (index, id) in ids.enumerated() {
        if index > 0 { press(.right, app: app, "\(width)x\(height) focus \(id)") }
        expectFocus(id, app: app)
        try assertControlsInViewport(app)
        try assertRenderedLabel(controlTitle(id, app: app), in: control(id, app: app), app: app)
      }
      for _ in 1..<ids.count { press(.left, app: app, "\(width)x\(height) return to Layout") }
      expectFocus("multiview-layout", app: app)
      let toolbarState = try state(app)
      let toolbarFrames = toolbarControls(app).map(\.frame)
      press(.select, app: app, "\(width)x\(height) picker")
      XCTAssertEqual(toolbarFrames, toolbarControls(app).map(\.frame))
      try assertPictureFrames(toolbarState, try state(app))
      assertSelectedLayout("featured", app: app)
      for (index, choice) in ["featured", "spotlight", "grid"].enumerated() {
        if index > 0 { press(.down, app: app, "\(width)x\(height) focus \(choice)") }
        let id = "multiview-layout-\(choice)"
        expectFocus(id, app: app)
        try assertControlsInViewport(app)
        try assertRenderedLabel(controlTitle(id, app: app), in: control(id, app: app), app: app)
      }
      press(.menu, app: app, "\(width)x\(height) Back closes picker")
      expectFocus("multiview-layout", app: app)
      XCTAssertFalse(control("multiview-layout-grid", app: app).exists)
      try assertIdentity(before, try state(app))
      try assertAudio(try XCTUnwrap(before["audio"] as? String), app: app)
      press(.select, app: app, "\(width)x\(height) reopen picker")
      expectFocus("multiview-layout-featured", app: app)
      press(.down, app: app, "\(width)x\(height) Spotlight")
      press(.select, app: app, "\(width)x\(height) select Spotlight")
      try assertPicturesAboveToolbar(app)
      press(.menu, app: app, "\(width)x\(height) close")
      capture(app, "\(width)x\(height) \(count) Spotlight secondary metadata")
      try assertIdentity(before, try state(app))
      try assertAudio(try XCTUnwrap(before["audio"] as? String), app: app)
      for layout in ["grid", "featured"] {
        press(.playPause, app: app, "\(width) reopen controls for \(layout)")
        press(.select, app: app, "\(width) native choices for \(layout)")
        focusLayout(layout, app: app)
        press(.select, app: app, "\(width) select \(layout)")
        XCTAssertEqual(try state(app)["layout"] as? String, layout)
        expectFocus("multiview-layout", app: app)
        press(.select, app: app, "\(width) verify selected \(layout)")
        XCTAssertTrue(control("multiview-layout-featured", app: app).waitForExistence(timeout: 5))
        assertSelectedLayout(layout, app: app)
        press(.menu, app: app, "\(width) dismiss verified menu")
        try assertPicturesAboveToolbar(app)
        try assertIdentity(before, try state(app))
        try assertAudio(try XCTUnwrap(before["audio"] as? String), app: app)
        press(.menu, app: app, "\(width) return wall after \(layout)")
      }
      app.terminate()
    }
  }

  func testSmallMetadataAndOutsideOutlineContainment() throws {
    for (width, height) in [(854, 480), (1280, 720)] {
      for layout in ["featured", "spotlight"] {
        let app = try launch(count: 6, width: width, height: height, layout: layout)
        defer { app.terminate() }
        press(.playPause, app: app, "\(width) \(layout) dismiss onboarding hint")
        press(.menu, app: app, "\(width) \(layout) return to clean wall")
        press(layout == "featured" ? .right : .down, app: app, "\(width) \(layout) selected metadata")
        try assertFocusedOutlineTracksPicture(app)
        capture(app, "\(width) \(layout) metadata contained")
        app.terminate()
      }
    }
  }

  func testThemesAndTransparency() throws {
    for theme in ["system", "dark", "oled", "light"] {
      for opaque in [false, true] {
        let app = try launch(count: 6, theme: theme, opaque: opaque)
        defer { app.terminate() }
        press(.playPause, app: app, "\(theme) opaque-\(opaque) toolbar")
        try assertControlsInViewport(app)
        press(.select, app: app, "\(theme) opaque-\(opaque) picker")
        expectFocus("multiview-layout-featured", app: app)
        try assertControlsInViewport(app)
        press(.down, app: app, "\(theme) opaque-\(opaque) focus Spotlight")
        press(.select, app: app, "\(theme) opaque-\(opaque) choose Spotlight")
        press(.menu, app: app, "\(theme) opaque-\(opaque) return wall")
        press(.down, app: app, "\(theme) opaque-\(opaque) compact metadata")
        XCTAssertNotEqual(try state(app)["audio"] as? String, "layout-0")
        capture(app, "\(theme) opaque-\(opaque) compact metadata")
        app.terminate()
      }
    }
  }

  func testNativeReducedMotionPreference() throws {
    let app = try launch(count: 6, theme: "light", opaque: true)
    defer { app.terminate() }
    guard try state(app)["reduceMotion"] as? Bool == true else {
      throw XCTSkip("Enable the assigned simulator's Reduce Motion preference before running this test.")
    }
    let before = try state(app)
    press(.playPause, app: app, "Reduced Motion toolbar")
    press(.select, app: app, "Reduced Motion picker")
    press(.down, app: app, "Reduced Motion Spotlight")
    press(.select, app: app, "Reduced Motion layout transition")
    press(.menu, app: app, "Reduced Motion close toolbar")
    press(.down, app: app, "Reduced Motion secondary metadata")
    try assertIdentity(before, try state(app))
  }

  func testNativeReducedTransparencyPreference() throws {
    for (width, height) in [(1920, 1080), (854, 480)] {
      let app = try launch(count: 6, width: width, height: height, theme: "light", lineup: true)
      defer { app.terminate() }
      guard try state(app)["reduceTransparency"] as? Bool == true else {
        throw XCTSkip("Enable the assigned simulator's Reduce Transparency preference before running this test.")
      }
      press(.playPause, app: app, "\(width) native Light Reduce Transparency toolbar")
      try assertControlsInViewport(app)
      try assertOpaqueLabelContrast("multiview-layout", app: app)
      try assertOpaqueLabelContrast("multiview-browse", app: app)
      try assertOpaqueLabelContrast("multiview-controls-done", app: app)
      press(.select, app: app, "\(width) native Light Reduce Transparency picker")
      expectFocus("multiview-layout-featured", app: app)
      try assertControlsInViewport(app)
      try assertOpaqueLabelContrast("multiview-layout-featured", app: app)
      try assertOpaqueLabelContrast("multiview-layout-spotlight", app: app)
      try assertOpaqueLabelContrast("multiview-layout-grid", app: app)
      press(.down, app: app, "\(width) native Light Reduce Transparency Spotlight")
      press(.select, app: app, "\(width) native Light Reduce Transparency selected")
      press(.menu, app: app, "\(width) native Light Reduce Transparency close")
      app.terminate()
    }
  }

  private func launch(count: Int, width: Int? = nil, height: Int? = nil, theme: String = "dark",
                      opaque: Bool = false, lineup: Bool = false, layout: String = "featured") throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = [
      "STROZZ_MULTIVIEW_LAYOUT_FIXTURE": "1", "STROZZ_LAYOUT_COUNT": "\(count)",
      "STROZZ_LAYOUT_THEME": theme, "STROZZ_LAYOUT_OPAQUE": opaque ? "1" : "0",
      "STROZZ_LAYOUT_LINEUP": lineup ? "1" : "0",
      "STROZZ_LAYOUT_MODE": layout,
    ]
    if let width, let height {
      app.launchEnvironment["STROZZ_LAYOUT_WIDTH"] = "\(width)"
      app.launchEnvironment["STROZZ_LAYOUT_HEIGHT"] = "\(height)"
    }
    app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES", "-showChatByDefault", "NO",
      "-streamRewindEnabled", "NO", "-experimentalYouTubeMergeEnabled", "NO", "-experimentalKickMergeEnabled", "NO"]
    app.launch()
    let diagnostics = app.descendants(matching: .any)["layout-fixture-state"].firstMatch
    XCTAssertTrue(diagnostics.waitForExistence(timeout: 20))
    let populated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "{"),
      object: diagnostics)
    XCTAssertEqual(XCTWaiter.wait(for: [populated], timeout: 5), .completed,
      "Wait for the first mounted-window diagnostic sample, not only its AX element.")
    for _ in 0..<40 {
      if let panes = try state(app)["panes"] as? [[String: Any]],
        panes.count == count, panes.allSatisfy({ $0["ready"] as? Bool == true }) {
        capture(app, "initial decoded \(count) \(theme) opaque-\(opaque)")
        return app
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    XCTFail("Local AVKit pictures did not become ready: \(try state(app))")
    return app
  }

  private func state(_ app: XCUIApplication) throws -> [String: Any] {
    let element = app.descendants(matching: .any)["layout-fixture-state"].firstMatch
    let value = try XCTUnwrap(element.value as? String)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
  }

  private func assertIdentity(_ before: [String: Any], _ after: [String: Any],
                              file: StaticString = #filePath, line: UInt = #line) throws {
    let old = try XCTUnwrap(before["panes"] as? [[String: Any]])
    let new = try XCTUnwrap(after["panes"] as? [[String: Any]])
    XCTAssertEqual(old.count, new.count, file: file, line: line)
    for (a, b) in zip(old, new) {
      for key in ["id", "model", "player", "item", "surface"] {
        XCTAssertEqual(a[key] as? String, b[key] as? String, "Retain \(key)", file: file, line: line)
      }
    }
  }

  private func assertAudio(_ id: String, app: XCUIApplication) throws {
    let value = try state(app)
    XCTAssertEqual(value["audio"] as? String, id)
    for pane in try XCTUnwrap(value["panes"] as? [[String: Any]]) {
      XCTAssertEqual(pane["muted"] as? Bool, pane["id"] as? String != id)
    }
  }

  private func toolbarControls(_ app: XCUIApplication) -> [XCUIElement] {
    ["multiview-layout", "multiview-browse", "multiview-controls-done"]
      .map { control($0, app: app) }.filter(\.exists)
  }

  private func assertNormalButtonSizes(_ app: XCUIApplication) throws {
    let logical = try XCTUnwrap(try state(app)["logicalViewport"] as? [Double])
    let scale = min(1, min(app.frame.width / logical[0], app.frame.height / logical[1]))
    let dimensions = toolbarControls(app).map {
      "\($0.identifier): frame=\($0.frame); logicalHeight=\($0.frame.height / scale); focused=\($0.hasFocus)"
    }
    let attachment = XCTAttachment(string: dimensions.joined(separator: "\n"))
    attachment.name = "Measured normal toolbar sizes \(logical[0])"
    attachment.lifetime = .keepAlways
    add(attachment)
    for button in toolbarControls(app) {
      XCTAssertGreaterThanOrEqual(button.frame.height / scale, 44)
      XCTAssertLessThanOrEqual(button.frame.height / scale, 64, "Normal buttons must not return to the former ~80pt height.")
    }
  }

  private func assertPictureFrames(_ before: [String: Any], _ after: [String: Any]) throws {
    let old = try XCTUnwrap(before["panes"] as? [[String: Any]])
    let new = try XCTUnwrap(after["panes"] as? [[String: Any]])
    for (a, b) in zip(old, new) {
      XCTAssertEqual(a["picture"] as? [Double], b["picture"] as? [Double],
        "A native menu overlays video; it must not allocate an extra picker row or resize the wall.")
    }
  }

  private func assertSelectedLayout(_ layout: String, app: XCUIApplication) {
    let selected = control("multiview-layout-\(layout)", app: app)
    XCTAssertTrue(selected.images["checkmark"].exists, "Native selected checkmark must be exposed.")
    XCTAssertTrue(selected.descendants(matching: .any).allElementsBoundByIndex.contains(where: \.isSelected))
    for other in ["featured", "spotlight", "grid"] where other != layout {
      XCTAssertFalse(control("multiview-layout-\(other)", app: app).images["checkmark"].exists)
    }
  }

  private func assertPicturesAboveToolbar(_ app: XCUIApplication) throws {
    let top = control("multiview-layout", app: app).frame.minY
    for pane in try XCTUnwrap(try state(app)["panes"] as? [[String: Any]]) {
      let picture = try XCTUnwrap(pane["picture"] as? [Double])
      XCTAssertLessThan(picture[1] + picture[3], top - 8, "Decoded picture cannot underlap toolbar")
      XCTAssertEqual(picture[2] / picture[3], try XCTUnwrap(pane["aspect"] as? Double), accuracy: 0.01)
    }
  }

  private func assertControlsInViewport(_ app: XCUIApplication) throws {
    let viewport = try viewportFrame(app)
    for button in app.buttons.allElementsBoundByIndex where button.identifier.hasPrefix("multiview-layout")
      || ["multiview-browse", "multiview-controls-done"].contains(button.identifier) {
      XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(button.frame),
        "\(button.identifier) \(button.frame) exceeds logical viewport \(viewport)")
    }
    for choice in ["featured", "spotlight", "grid"] {
      let cell = control("multiview-layout-\(choice)", app: app)
      if cell.exists {
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(cell.frame),
          "Native menu choice \(choice) \(cell.frame) exceeds logical viewport \(viewport)")
      }
    }
  }

  private func viewportFrame(_ app: XCUIApplication) throws -> CGRect {
    let value = try state(app)
    let logical = try XCTUnwrap(value["logicalViewport"] as? [Double])
    let window = app.frame
    let scale = min(1, min(window.width / logical[0], window.height / logical[1]))
    return CGRect(x: window.midX - logical[0] * scale / 2, y: window.midY - logical[1] * scale / 2,
      width: logical[0] * scale, height: logical[1] * scale)
  }

  private func assertFocusedOutlineTracksPicture(_ app: XCUIApplication) throws {
    let value = try state(app)
    let audio = try XCTUnwrap(value["audio"] as? String)
    XCTAssertNotEqual(audio, "layout-0")
    let panes = try XCTUnwrap(value["panes"] as? [[String: Any]])
    let pane = try XCTUnwrap(panes.first { $0["id"] as? String == audio })
    let bounds = try XCTUnwrap(pane["picture"] as? [Double])
    let frame = CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3])
    let image = try XCTUnwrap(app.screenshot().image.cgImage)
    let scale = CGFloat(image.width) / app.frame.width
    for point in [
      CGPoint(x: frame.minX - 2, y: frame.midY), CGPoint(x: frame.maxX + 2, y: frame.midY),
      CGPoint(x: frame.midX, y: frame.minY - 2), CGPoint(x: frame.midX, y: frame.maxY + 2),
    ] {
      let pixels = try colors(image, rect: CGRect(x: point.x * scale - 1, y: point.y * scale - 1,
        width: 3, height: 3))
      XCTAssertTrue(pixels.keys.contains { components($0).min()! > 225 },
        "Focused outline must hug native picture \(frame), near \(point): \(pixels)")
    }
    let viewport = try viewportFrame(app)
    for point in [
      CGPoint(x: frame.minX - 7, y: frame.midY), CGPoint(x: frame.maxX + 7, y: frame.midY),
      CGPoint(x: frame.midX, y: frame.minY - 7), CGPoint(x: frame.midX, y: frame.maxY + 7),
    ] where viewport.contains(point) {
      let pixels = try colors(image, rect: CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1))
      XCTAssertTrue(pixels.keys.allSatisfy { components($0).max()! < 32 },
        "Metadata/outline must not spill into the ten-point picture gap near \(point): \(pixels)")
    }
  }

  private func assertRenderedLabel(_ expected: String, in button: XCUIElement, app: XCUIApplication) throws {
    _ = try recognizedLabel(expected, in: button, app: app)
  }

  private func recognizedLabel(_ expected: String, in button: XCUIElement,
                               app: XCUIApplication) throws -> (image: CGImage, textBounds: CGRect) {
    let screenshot = try XCTUnwrap(app.screenshot().image.cgImage)
    let scale = CGFloat(screenshot.width) / app.frame.width
    let frame = button.frame
    // Exclude the native menu's checkmark/icon columns so Vision does not merge
    // the four-square layout glyph into the word "Equal".
    let textInset: CGFloat = button.elementType == .cell ? 110 : 0
    let crop = CGRect(x: (frame.minX + textInset) * scale, y: frame.minY * scale,
      width: (frame.width - textInset) * scale, height: frame.height * scale)
    let image = try XCTUnwrap(screenshot.cropping(to: crop))
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let results = request.results ?? []
    let strings = results.compactMap { $0.topCandidates(1).first?.string }
    func normalized(_ text: String) -> String { text.lowercased().filter(\.isLetter) }
    let match = results.first {
      $0.topCandidates(1).contains { normalized($0.string).contains(normalized(expected)) }
    }
    let boxes = results.map {
      let box = $0.boundingBox
      return CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
        width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
    }
    let attachment = XCTAttachment(string: "\(button.identifier): expected \(expected), rendered OCR \(strings), "
      + "control frame=\(frame), screenshot scale=\(scale), rendered pixel bounds=\(boxes)")
    attachment.name = "Rendered label \(button.identifier)"
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let match else {
      let evidence = XCTAttachment(image: UIImage(cgImage: image))
      evidence.name = "Incomplete rendered label \(button.identifier)"
      evidence.lifetime = .keepAlways
      add(evidence)
      XCTFail("Full label '\(expected)' is not rendered: \(strings)")
      return (image, .zero)
    }
    let box = match.boundingBox
    return (image, CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
      width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height)))
  }

  private func assertOpaqueLabelContrast(_ identifier: String, app: XCUIApplication) throws {
    let button = control(identifier, app: app)
    let capture = try recognizedLabel(controlTitle(identifier, app: app), in: button, app: app)
    let histogram = try colors(capture.image, rect: capture.textBounds.integral)
    let total = histogram.values.reduce(0, +)
    let substantial = histogram.filter { $0.value >= max(3, total / 100) }
    let luminances = substantial.keys.map { color -> Double in
      let rgb = components(color).map { Double($0) / 255 }
        .map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
      return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
    }
    let contrast = (try XCTUnwrap(luminances.max()) + 0.05) / (try XCTUnwrap(luminances.min()) + 0.05)
    let attachment = XCTAttachment(string: "\(identifier) opaque glyph-region contrast=\(contrast), RGB counts=\(substantial)")
    attachment.name = "Measured contrast \(identifier)"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertGreaterThanOrEqual(contrast, 4.5, "Require normal-text contrast even for these large native labels.")
  }

  private func components(_ color: UInt32) -> [Int] {
    [Int((color >> 16) & 255), Int((color >> 8) & 255), Int(color & 255)]
  }

  private func colors(_ image: CGImage, rect: CGRect) throws -> [UInt32: Int] {
    let crop = try XCTUnwrap(image.cropping(to: rect.integral))
    var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
    try bytes.withUnsafeMutableBytes { raw in
      let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: crop.width, height: crop.height,
        bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    }
    var counts: [UInt32: Int] = [:]
    for offset in stride(from: 0, to: bytes.count, by: 4) {
      let color = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
      counts[color, default: 0] += 1
    }
    return counts
  }

  private func focusLayout(_ layout: String, app: XCUIApplication) {
    let names = ["featured", "spotlight", "grid"]
    for step in 0..<3 {
      if control("multiview-layout-\(layout)", app: app).hasFocus { return }
      let current = names.firstIndex { control("multiview-layout-\($0)", app: app).hasFocus } ?? 0
      let target = names.firstIndex(of: layout)!
      press(target < current ? .up : .down, app: app, "focus \(layout) \(step)")
    }
    expectFocus("multiview-layout-\(layout)", app: app)
  }

  private func focusCell(_ cell: XCUIElement, app: XCUIApplication) {
    for step in 0..<6 {
      if cell.hasFocus { return }
      press(.down, app: app, "context navigation \(step)")
    }
    XCTAssertTrue(cell.hasFocus, app.debugDescription)
  }

  private func expectFocus(_ identifier: String, app: XCUIApplication) {
    let target = control(identifier, app: app)
    XCTAssertTrue(target.waitForExistence(timeout: 5), app.debugDescription)
    let focused = NSPredicate { _, _ in
      MainActor.assumeIsolated {
        target.hasFocus || target.descendants(matching: .any).allElementsBoundByIndex.contains(where: \.hasFocus)
      }
    }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)],
      timeout: 5), .completed, app.debugDescription)
  }

  private func control(_ identifier: String, app: XCUIApplication) -> XCUIElement {
    if let title = choiceTitle(identifier) {
      // UIKit's native menu cells retain labels/selection but do not forward SwiftUI Picker tag identifiers.
      return app.cells.containing(.any, identifier: title).firstMatch
    }
    return app.buttons[identifier]
  }

  private func choiceTitle(_ identifier: String) -> String? {
    ["multiview-layout-featured": "Featured", "multiview-layout-spotlight": "Spotlight",
     "multiview-layout-grid": "Equal"][identifier]
  }

  private func controlTitle(_ identifier: String, app: XCUIApplication) -> String {
    choiceTitle(identifier) ?? (identifier == "multiview-layout" ? "Layout" : control(identifier, app: app).label)
  }

  private func press(_ button: XCUIRemote.Button, duration: TimeInterval? = nil,
                     app: XCUIApplication, _ name: String) {
    capture(app, "before \(name)")
    if let duration { XCUIRemote.shared.press(button, forDuration: duration) }
    else { XCUIRemote.shared.press(button) }
    Thread.sleep(forTimeInterval: 0.45)
    capture(app, "after \(name)")
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name) hierarchy and native diagnostics"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let diagnostics = app.descendants(matching: .any)["layout-fixture-state"].firstMatch
    if diagnostics.exists, let value = diagnostics.value as? String {
      let state = XCTAttachment(string: value)
      state.name = "\(name) full state JSON"
      state.lifetime = .keepAlways
      add(state)
    }
  }
}

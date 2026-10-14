import XCTest

@MainActor
final class MobileSidebarTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testTabletSidebarNavigationAndFullWidthPlayer() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad browsing sidebar") }
    let app = launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    XCUIDevice.shared.orientation = .landscapeLeft
    let home = app.buttons["sidebar-home"]
    XCTAssertTrue(home.waitForExistence(timeout: 10))
    XCTAssertTrue(home.isHittable)
    XCTAssertTrue(app.buttons["sidebar-stream-navigation0"].isHittable)
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Home")).count, 1,
      "Wide iPad navigation must not duplicate the sidebar as floating tabs")
    capture(app, name: "ipad-sidebar-landscape")
    app.buttons["sidebar-browse"].tap()
    XCTAssertTrue(app.staticTexts["Browse content"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["Browse"].exists)
    app.buttons["sidebar-account"].tap()
    XCTAssertTrue(app.staticTexts["Account content"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["Account"].exists)
    app.buttons["sidebar-stream-navigation0"].tap()
    XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
    capture(app, name: "ipad-sidebar-expanded-accessibility")
    XCTAssertFalse(home.isHittable, "Background sidebar controls cannot receive input during playback")
    XCTAssertFalse(home.isEnabled, "Native sidebar controls must also be disabled behind the player")
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 5))
    XCTAssertEqual(video.frame.minX, app.frame.minX, accuracy: 2, "The player must span the whole window, not the detail column")
    capture(app, name: "ipad-sidebar-full-width-player")
    if !app.buttons["mobile-minimize-player"].isHittable { app.buttons["mobile-controls-toggle"].tap() }
    app.buttons["mobile-minimize-player"].tap()
    XCTAssertTrue(home.waitForExistence(timeout: 5))
    XCTAssertTrue(home.isHittable)
    let mini = app.buttons["mobile-expand-player"]
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    app.buttons["sidebar-browse"].tap()
    XCTAssertTrue(app.staticTexts["Browse content"].waitForExistence(timeout: 5))
    XCTAssertTrue(mini.exists, "Changing browse destinations must keep the mini-player mounted")
    mini.tap()
    if mini.exists { mini.tap() }
    XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
    app.buttons["Close player"].tap()
    XCTAssertTrue(home.waitForExistence(timeout: 5))
    XCTAssertTrue(home.isHittable)
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(home.waitForExistence(timeout: 5))
    capture(app, name: "ipad-sidebar-portrait")
  }

  func testTabletNarrowWindowKeepsCompactNavigation() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad compact window") }
    let app = launch()
    defer { app.terminate() }
    let toggle = app.buttons["fixture-toggle-window"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    toggle.tap()
    let browse = app.buttons["Browse"].firstMatch
    XCTAssertTrue(browse.waitForExistence(timeout: 5))
    XCTAssertTrue(browse.isHittable)
    browse.tap()
    XCTAssertTrue(app.staticTexts["Browse content"].waitForExistence(timeout: 5))
    capture(app, name: "ipad-sidebar-narrow-window")
    toggle.tap()
    XCTAssertTrue(app.buttons["sidebar-browse"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["sidebar-browse"].isHittable)
  }

  func testSidebarLoadingSignedOutAndEmptyStates() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad sidebar states") }
    for state in ["restoring", "signed-out", "empty", "failed"] {
      let app = launch(state: state)
      defer { app.terminate() }
      XCTAssertTrue(app.buttons["sidebar-home"].waitForExistence(timeout: 10))
      if state == "restoring" {
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sidebar-follows-loading").firstMatch.exists)
        XCTAssertFalse(app.buttons["sidebar-sign-in"].exists)
        XCTAssertFalse(app.buttons["sidebar-stream-navigation0"].exists)
      } else if state == "signed-out" {
        let signIn = app.buttons["sidebar-sign-in"]
        XCTAssertTrue(signIn.exists)
        XCTAssertFalse(app.buttons["sidebar-stream-navigation0"].exists)
        signIn.tap()
        XCTAssertTrue(app.staticTexts["Account content"].waitForExistence(timeout: 5))
      } else if state == "empty" {
        XCTAssertTrue(app.staticTexts["sidebar-follows-empty"].exists)
      } else {
        XCTAssertTrue(app.buttons["sidebar-follows-retry"].exists)
        XCTAssertTrue(app.buttons["sidebar-stream-navigation0"].exists, "A refresh error keeps previous live channels")
      }
      capture(app, name: "ipad-sidebar-\(state)")
      app.terminate()
    }
  }

  func testSidebarThemesAccessibleTypeAndSolidSidebarSurface() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad sidebar themes") }
    for theme in ["Light", "Dark", "OLED", "System"] {
      let app = launch(theme: theme, accessible: theme == "Light")
      defer { app.terminate() }
      let row = app.buttons["sidebar-stream-navigation0"]
      XCTAssertTrue(row.waitForExistence(timeout: 10))
      let resolved = app.descendants(matching: .any).matching(identifier: "fixture-navigation-theme").firstMatch
      XCTAssertEqual(resolved.value as? String, theme.lowercased(), "Verify the selected theme, not a default fallback")
      XCTAssertTrue(row.isHittable)
      XCTAssertGreaterThanOrEqual(row.frame.height, 44)
      let sidebar = app.descendants(matching: .any).matching(identifier: "mobile-browsing-sidebar").firstMatch
      XCTAssertLessThanOrEqual(row.frame.maxX, sidebar.frame.maxX + 2)
      capture(app, name: "ipad-sidebar-\(theme)-opaque")
      app.terminate()
    }
  }

  func testPhoneRetainsThreeTabsWithoutSidebar() throws {
    guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone navigation") }
    let app = launch()
    defer { app.terminate() }
    XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.tabBars.buttons.count, 3)
    XCTAssertFalse(app.buttons["sidebar-home"].exists)
    app.tabBars.buttons["Browse"].tap()
    XCTAssertTrue(app.staticTexts["Browse content"].waitForExistence(timeout: 5))
    capture(app, name: "iphone-navigation-unchanged")
  }

  func testRealTabletBrowseAndAccountKeepIndependentNavigationStacks() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad real browsing navigation") }
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["sidebar-browse"].waitForExistence(timeout: 10))
    app.buttons["sidebar-browse"].tap()
    XCTAssertTrue(app.navigationBars["Browse"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.searchFields.firstMatch.exists)
    capture(app, name: "ipad-real-browse")
    app.buttons["sidebar-account"].tap()
    XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
    let overlays = app.buttons["account-overlays"]
    for _ in 0..<5 {
      if overlays.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(overlays.isHittable)
    overlays.tap()
    XCTAssertTrue(app.navigationBars["Overlays"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["sidebar-browse"].isHittable)
    app.buttons["sidebar-browse"].tap()
    XCTAssertTrue(app.navigationBars["Browse"].waitForExistence(timeout: 5))
    app.buttons["sidebar-account"].tap()
    XCTAssertTrue(app.navigationBars["Overlays"].waitForExistence(timeout: 5),
      "Sidebar destinations preserve each tab's existing navigation stack")
    capture(app, name: "ipad-real-account-stack-restored")
  }

  private func launch(state: String = "loaded", theme: String = "Dark",
                      accessible: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "navigation"
    app.launchEnvironment["STROZZ_NAVIGATION_FOLLOWS_STATE"] = state
    app.launchEnvironment["STROZZ_NAVIGATION_THEME"] = theme
    app.launchEnvironment["STROZZ_NAVIGATION_ACCESSIBLE"] = accessible ? "1" : "0"
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launch()
    return app
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

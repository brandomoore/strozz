import XCTest

@MainActor
final class PlayerChatLayoutTests: XCTestCase {
  func testOptInDirectEntryKeepsChatClearOfVideoAndControls() throws {
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_PLAYER_LAYOUT_TESTS"] == "1",
      let channel = settings["STROZZ_MATRIX_CHANNELS"]?.split(separator: ",").first else {
      throw XCTSkip("Select one live channel and enable STROZZ_PLAYER_LAYOUT_TESTS.")
    }
    continueAfterFailure = false
    for mode in ["side", "overlay", "glass"] {
      for width in [460, 820] {
        let app = XCUIApplication()
        app.launchEnvironment["STROZZ_PLAYER_UI_CHANNEL"] = String(channel)
        app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
        app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES",
          "-showChatByDefault", "YES", "-chatLayoutMode", mode, "-chatWidthValue", "\(width)",
          "-streamRewindEnabled", "YES"]
        app.launch()
        defer { app.terminate() }
        let video = app.descendants(matching: .any).matching(identifier: "player-video-surface").firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "value == %@", "Ready"), evaluatedWith: video)
        waitForExpectations(timeout: 45)
        let videoFocus = app.descendants(matching: .any).matching(identifier: "player-video-focus").firstMatch
        XCTAssertTrue(videoFocus.waitForExistence(timeout: 45))
        XCUIRemote.shared.press(.up)
        let toggle = app.buttons["player-chat-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let chat = app.descendants(matching: .any).matching(identifier: "player-chat-pane").firstMatch
        let timeline = app.descendants(matching: .any).matching(identifier: "player-live-timeline").firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Direct player \(mode) width \(width)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertGreaterThan(chat.frame.width, 0)
        XCTAssertLessThanOrEqual(toggle.frame.maxX, chat.frame.minX, "\(mode) \(width): collapse button")
        XCTAssertLessThanOrEqual(timeline.frame.maxX, chat.frame.minX, "\(mode) \(width): LIVE timeline")
        if mode == "side" {
          XCTAssertLessThanOrEqual(video.frame.maxX, chat.frame.minX, "Side chat must not cover video")
        }
      }
    }
  }
}

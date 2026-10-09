import XCTest

@MainActor
final class PlayerChatLayoutTests: XCTestCase {
  func testOptInInterruptedPlayerOffersFocusableResumeInsteadOfLoadingForever() throws {
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_PLAYER_LAYOUT_TESTS"] == "1",
      let channel = settings["STROZZ_MATRIX_CHANNELS"]?.split(separator: ",").first else {
      throw XCTSkip("Select a live channel and enable STROZZ_PLAYER_LAYOUT_TESTS.")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_PLAYER_UI_CHANNEL"] = String(channel)
    app.launchEnvironment["STROZZ_UI_AUDIO_INTERRUPTION"] = "1"
    app.launchEnvironment["STROZZ_MUTE_PLAYBACK"] = "1"
    app.launchArguments = ["-hasPromptedFirstLaunchSignIn", "YES"]
    app.launch()
    defer { app.terminate() }
    let resume = app.buttons["Resume playback"].firstMatch
    XCTAssertTrue(resume.waitForExistence(timeout: 45))
    expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: resume)
    waitForExpectations(timeout: 5)
    XCUIRemote.shared.press(.down)
    XCTAssertTrue(app.buttons["Back"].firstMatch.hasFocus)
    XCUIRemote.shared.press(.up)
    XCTAssertTrue(resume.hasFocus)
    XCUIRemote.shared.press(.select)
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: resume)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "player-video-focus")
      .firstMatch.waitForExistence(timeout: 10))
    XCUIRemote.shared.press(.up)
    XCTAssertTrue(app.buttons["player-quality-menu"].firstMatch.waitForExistence(timeout: 5))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Resumed stream after audio interruption"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

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
          "-streamRewindEnabled", "YES", "-showLatencyBadge", "YES",
          "-showViewerCount", "YES", "-showStreamDuration", "YES"]
        app.launch()
        defer { app.terminate() }
        let video = app.descendants(matching: .any).matching(identifier: "player-video-surface").firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "value == %@", "Ready"), evaluatedWith: video)
        waitForExpectations(timeout: 45)
        let videoFocus = app.descendants(matching: .any).matching(identifier: "player-video-focus").firstMatch
        XCTAssertTrue(videoFocus.waitForExistence(timeout: 45))
        let latency = app.descendants(matching: .any).matching(identifier: "player-latency").firstMatch
        XCTAssertFalse(latency.exists, "Readouts must remain hidden with playback controls")
        XCUIRemote.shared.press(.up)
        let toggle = app.buttons["player-chat-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(latency.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label MATCHES %@", "Latency from live: [0-9]+([.,][0-9]{2})?s"),
          evaluatedWith: latency)
        waitForExpectations(timeout: 15)
        let uptime = app.descendants(matching: .any).matching(identifier: "broadcast-uptime").firstMatch
        let viewers = app.descendants(matching: .any).matching(identifier: "player-viewers-twitch").firstMatch
        XCTAssertTrue(uptime.waitForExistence(timeout: 10))
        XCTAssertTrue(viewers.waitForExistence(timeout: 10))
        XCTAssertEqual(latency.frame.height, uptime.frame.height, accuracy: 1, "Readout text sizes must match")
        XCTAssertEqual(latency.frame.height, viewers.frame.height, accuracy: 1, "Readout text sizes must match")
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
        XCTAssertLessThanOrEqual(latency.frame.maxX, chat.frame.minX, "\(mode) \(width): latency readout")
        if mode == "side" {
          XCTAssertLessThanOrEqual(video.frame.maxX, chat.frame.minX, "Side chat must not cover video")
        }
        XCUIRemote.shared.press(.menu)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(latency.exists, "Latency must hide with the other playback controls")
        XCTAssertFalse(uptime.exists, "Uptime must hide with the other playback controls")
        XCTAssertFalse(viewers.exists, "Viewer counts must hide with the other playback controls")
      }
    }
  }
}

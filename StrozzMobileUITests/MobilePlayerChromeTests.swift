import UIKit
import XCTest

@MainActor
final class MobilePlayerChromeTests: XCTestCase {
  func testMacVolumeTrackTapsJumpWithoutDragging() throws {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_VOLUME_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      app.launch()
      let slider = app.sliders["mobile-volume-slider"]
      XCTAssertTrue(slider.waitForExistence(timeout: 10))
      captureVolumeVerification(app, "Volume before track clicks \(orientation.rawValue)")
      for position: CGFloat in [0.75, 0.25, 1, 0] {
        try tapVolume(slider, position: position)
        XCTAssertEqual(app.buttons["mobile-volume-mute"].label, position == 0 ? "Unmute" : "Mute")
      }
      try tapVolume(slider, position: 0.75)
      app.buttons["mobile-volume-mute"].tap()
      XCTAssertEqual(app.buttons["mobile-volume-mute"].label, "Unmute")
      try tapVolume(slider, position: 0.25)
      XCTAssertEqual(app.buttons["mobile-volume-mute"].label, "Mute")
      XCTAssertTrue(app.buttons["mobile-play-pause"].exists)
      XCTAssertFalse(app.buttons["mobile-expand-player"].exists)
      captureVolumeVerification(app, "Volume after track clicks \(orientation.rawValue)")
      app.buttons["mobile-play-pause"].tap()
      try tapVolume(slider, position: 0.75)
      let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: slider)
      XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 7), .completed,
        "A track click must release the editing hold and allow normal auto-hide")
      app.terminate()
    }
  }

  private func tapVolume(_ slider: XCUIElement, position: CGFloat) throws {
    XCTAssertTrue(slider.isHittable)
    // The 20-point thumb travels between its center positions at each end.
    var x = 10 + (slider.frame.width - 20) * position
    // Use the track edges for endpoints so synthesized-tap jitter cannot miss zero.
    if position == 0 { x = 1 }
    if position == 1 { x = slider.frame.width - 1 }
    slider.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
      .withOffset(CGVector(dx: x, dy: 0)).tap()
    let text = try XCTUnwrap(slider.value as? String)
    let percentage = try XCTUnwrap(Double(text.filter { $0.isNumber || $0 == "." }))
    if position == 0 || position == 1 {
      XCTAssertEqual(percentage, Double(position) * 100)
    } else {
      XCTAssertEqual(percentage, Double(position) * 100, accuracy: 2)
    }
  }

  func testMacVolumePillThemeAndTransparencyMatrix() throws {
    #if !targetEnvironment(simulator)
    throw XCTSkip("The appearance matrix changes Settings only on a simulator.")
    #endif
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_VOLUME_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    let originalTransparency = setVerificationReduceTransparency(false)
    defer { app.terminate(); setVerificationReduceTransparency(originalTransparency) }
    for opaque in [false, true] {
      setVerificationReduceTransparency(opaque)
      for theme in ["system", "dark", "oled", "light"] {
        let name = "Mac volume \(theme) \(opaque ? "opaque" : "glass")"
        app.launchEnvironment["STROZZ_PLAYER_THEME"] = theme
        app.launch()
        let slider = app.sliders["mobile-volume-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        captureVolumeVerification(app, "\(name) initial")
        assertCompactVolumePill(app, beside: "mobile-player-bottom-actions")
        slider.adjust(toNormalizedSliderPosition: 0.35)
        let mute = app.buttons["mobile-volume-mute"]
        XCTAssertTrue(slider.isHittable)
        XCTAssertTrue(mute.isHittable)
        XCTAssertTrue(app.frame.contains(slider.frame))
        XCTAssertTrue(app.frame.contains(mute.frame))
        XCTAssertFalse(slider.frame.intersects(mute.frame))
        XCTAssertGreaterThanOrEqual(mute.frame.width, 44)
        XCTAssertGreaterThanOrEqual(mute.frame.height, 44)
        captureVolumeVerification(app, "\(name) adjusted")
        app.terminate()
      }
    }
  }

  func testIPadMuteRemainsAvailableWithoutMacVolumeOverride() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_THEME"] = "light"
    app.launch()
    defer { app.terminate() }
    let mute = app.buttons["mobile-mute"]
    XCTAssertTrue(mute.waitForExistence(timeout: 10))
    XCTAssertFalse(app.sliders["mobile-volume-slider"].exists)
    let initialLabel = mute.label
    captureVolumeVerification(app, "iPad original mute")
    mute.tap()
    XCTAssertNotEqual(mute.label, initialLabel)
    captureVolumeVerification(app, "iPad toggled mute")
    mute.tap()
    XCTAssertEqual(mute.label, initialLabel)
    captureVolumeVerification(app, "iPad restored mute")
  }

  func testMacVolumeControlRemainsUsableInAudioOnlyMode() throws {
    try verifyMacVolumeControlInAudioOnlyMode()
  }

  func testMacVolumeControlRemainsOnScreenWithReducedTransparency() throws {
    #if !targetEnvironment(simulator)
    throw XCTSkip("This appearance check changes Settings only on a simulator.")
    #endif
    let original = setVerificationReduceTransparency(true)
    defer { setVerificationReduceTransparency(original) }
    try verifyMacVolumeControlInAudioOnlyMode()
  }

  private func verifyMacVolumeControlInAudioOnlyMode() throws {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_VOLUME_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_THEME"] = "light"
    app.launch()
    defer { app.terminate() }
    let mode = app.buttons["mobile-playback-mode"]
    XCTAssertTrue(mode.waitForExistence(timeout: 10))
    captureVolumeVerification(app, "Before audio-only mode")
    mode.tap()
    let audioOnly = app.buttons["Audio and chat"]
    XCTAssertTrue(audioOnly.waitForExistence(timeout: 3))
    captureVolumeVerification(app, "Audio-only mode selection")
    audioOnly.tap()
    let slider = app.sliders["mobile-volume-slider"]
    XCTAssertTrue(slider.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["mobile-audio-play-pause"].exists)
    captureVolumeVerification(app, "Audio-only inline volume initial")
    assertCompactVolumePill(app, beside: "mobile-player-mode-actions")
    try tapVolume(slider, position: 0.75)
    try tapVolume(slider, position: 0.35)
    let audible = slider.value as? String
    let mute = app.buttons["mobile-volume-mute"]
    captureVolumeVerification(app, "Audio-only volume adjusted")
    mute.tap()
    XCTAssertEqual(mute.label, "Unmute")
    captureVolumeVerification(app, "Audio-only volume muted")
    mute.tap()
    XCTAssertEqual(slider.value as? String, audible)
    captureVolumeVerification(app, "Audio-only volume restored")
    XCTAssertTrue(app.frame.contains(slider.frame), "The full volume slider must remain inside the window")
    XCTAssertTrue(app.frame.contains(mute.frame))
  }

  private func captureVolumeVerification(_ app: XCUIApplication, _ name: String) {
    capture(app, name)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name) hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }

  @discardableResult
  private func setVerificationReduceTransparency(_ enabled: Bool) -> Bool {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    defer { settings.terminate() }
    captureVolumeVerification(settings, "Accessibility settings before navigation")
    if !settings.switches["Reduce Transparency"].exists {
      let accessibility = settings.buttons["com.apple.settings.accessibility"]
      XCTAssertTrue(accessibility.waitForExistence(timeout: 5))
      accessibility.tap()
      captureVolumeVerification(settings, "Accessibility settings")
      let display = settings.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", "Display & Text Size")).firstMatch
      XCTAssertTrue(display.waitForExistence(timeout: 5))
      display.tap()
    }
    let transparency = settings.switches["Reduce Transparency"]
    XCTAssertTrue(transparency.waitForExistence(timeout: 5))
    captureVolumeVerification(settings, "Reduce Transparency before setting \(enabled)")
    let original = transparency.value as? String == "1"
    if original != enabled {
      let toggle = transparency.switches.firstMatch
      XCTAssertTrue(toggle.exists)
      toggle.tap()
    }
    let updated = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", enabled ? "1" : "0"), object: transparency)
    XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 3), .completed)
    captureVolumeVerification(settings, "Reduce Transparency set \(enabled)")
    return original
  }

  private func assertCompactVolumePill(_ app: XCUIApplication, beside actionsIdentifier: String) {
    let pill = app.otherElements["mobile-volume-control"]
    let actions = app.otherElements[actionsIdentifier]
    let slider = app.sliders["mobile-volume-slider"]
    let mute = app.buttons["mobile-volume-mute"]
    XCTAssertTrue(pill.exists)
    XCTAssertTrue(actions.exists)
    XCTAssertEqual(pill.frame.height, 44, accuracy: 1)
    XCTAssertEqual(pill.frame.height, actions.frame.height, accuracy: 1)
    XCTAssertLessThanOrEqual(pill.frame.width, 212)
    XCTAssertGreaterThanOrEqual(actions.frame.minX - pill.frame.maxX, 15,
      "Volume must have its own surface, separate from the neighboring actions")
    XCTAssertEqual(pill.frame.midY, actions.frame.midY, accuracy: 1)
    XCTAssertLessThan(slider.frame.maxX, mute.frame.minX, "Slider precedes speaker, matching the reference")
    XCTAssertTrue(app.frame.contains(pill.frame))
    XCTAssertTrue(pill.frame.contains(slider.frame))
    XCTAssertTrue(pill.frame.contains(mute.frame))
  }

  func testMacVolumePillAdjustsMutesAndKeepsControlsVisibleDuringDrag() throws {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_VOLUME_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate() }
    let slider = app.sliders["mobile-volume-slider"]
    XCTAssertTrue(slider.waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["mobile-mute"].exists)
    captureVolumeVerification(app, "Inline volume before interaction")
    assertCompactVolumePill(app, beside: "mobile-player-bottom-actions")
    slider.adjust(toNormalizedSliderPosition: 0.35)
    let mute = app.buttons["mobile-volume-mute"]
    XCTAssertEqual(mute.label, "Mute")
    let audible = slider.value as? String
    mute.tap()
    XCTAssertEqual(mute.label, "Unmute")
    XCTAssertNotEqual(slider.value as? String, audible)
    mute.tap()
    XCTAssertEqual(slider.value as? String, audible)
    captureVolumeVerification(app, "Inline volume before held drag")
    app.buttons["mobile-play-pause"].tap()
    // Holding the thumb beyond the usual auto-hide delay must not dismiss controls.
    let thumb = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
    thumb.press(forDuration: 5, thenDragTo:
      slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
    capture(app, "Inline volume after held drag")
    XCTAssertTrue(slider.exists)
    let percentage = try XCTUnwrap(slider.value as? String).filter { $0.isNumber || $0 == "." }
    XCTAssertGreaterThan(try XCTUnwrap(Double(percentage)), 60)
    XCTAssertFalse(app.buttons["mobile-expand-player"].exists, "Dragging volume must not minimize the player")
    XCTAssertTrue(app.frame.contains(slider.frame), "The full volume slider must remain inside the window")
    XCTAssertTrue(app.frame.contains(mute.frame))
    captureVolumeVerification(app, "Separate compact Mac volume pill in the bottom bar")
    let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      !slider.exists && !app.buttons["mobile-play-pause"].exists
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 7), .completed,
      "Volume editing must release the auto-hide hold after the drag ends")
    captureVolumeVerification(app, "Inline volume controls hidden after release")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    XCTAssertFalse(slider.exists, "The volume control disappearing must not resurrect the overlay")
    XCTAssertFalse(app.buttons["mobile-play-pause"].exists)
  }

  func testMacVolumePillFitsLandscapeAndNarrowVideoArea() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_VOLUME_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_CHAT_WIDTH_FIXTURE_RESET"] = "1"
    app.launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let slider = app.sliders["mobile-volume-slider"]
    XCTAssertTrue(slider.waitForExistence(timeout: 10))
    showSideChat(app)
    captureVolumeVerification(app, "Inline volume landscape normal")
    assertCompactVolumePill(app, beside: "mobile-player-bottom-actions")
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let originalWidth = video.frame.width
    let handle = app.descendants(matching: .any).matching(identifier: "mobile-chat-resize-handle").firstMatch
    XCTAssertTrue(handle.exists)
    let center = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: -300, dy: 0)),
      withVelocity: .slow, thenHoldForDuration: 0)
    captureVolumeVerification(app, "Inline volume landscape narrow")
    XCTAssertLessThan(video.frame.width, originalWidth - 80)
    assertCompactVolumePill(app, beside: "mobile-player-bottom-actions")
    let pill = app.otherElements["mobile-volume-control"]
    let actions = app.otherElements["mobile-player-bottom-actions"]
    XCTAssertTrue(video.frame.contains(pill.frame))
    XCTAssertTrue(video.frame.contains(actions.frame))
    XCTAssertGreaterThanOrEqual(pill.frame.minX - app.buttons["mobile-go-live"].frame.maxX, 8)
    XCTAssertTrue(slider.isHittable)
    slider.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5))
      .press(forDuration: 0.1, thenDragTo:
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)),
        withVelocity: .slow, thenHoldForDuration: 0)
    captureVolumeVerification(app, "Inline volume landscape narrow adjusted")
    let percentage = try XCTUnwrap(slider.value as? String).filter { $0.isNumber || $0 == "." }
    XCTAssertGreaterThan(try XCTUnwrap(Double(percentage)), 60)
    XCTAssertFalse(app.buttons["mobile-expand-player"].exists)
  }

  func testMacVolumePillActiveDragReleasesAutoHideHold() throws {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_VOLUME_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate() }
    let slider = app.sliders["mobile-volume-slider"]
    XCTAssertTrue(slider.waitForExistence(timeout: 10))
    slider.adjust(toNormalizedSliderPosition: 0.35)
    captureVolumeVerification(app, "Inline volume before active drag")
    app.buttons["mobile-play-pause"].tap()
    let thumb = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
    thumb.press(forDuration: 0.05, thenDragTo:
      slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 5)
    capture(app, "Inline volume after active drag and five-second hold")
    XCTAssertTrue(slider.exists, "Active slider editing must keep controls visible")
    let percentage = try XCTUnwrap(slider.value as? String).filter { $0.isNumber || $0 == "." }
    XCTAssertGreaterThan(try XCTUnwrap(Double(percentage)), 60)
    XCTAssertFalse(app.buttons["mobile-expand-player"].exists)
    XCTAssertTrue(app.frame.contains(slider.frame))
    captureVolumeVerification(app, "Inline volume active drag released")
    let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      !slider.exists && !app.buttons["mobile-play-pause"].exists
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 7), .completed,
      "Ending active volume editing must release the auto-hide hold")
    captureVolumeVerification(app, "Inline volume hidden after active drag")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    XCTAssertFalse(slider.exists, "Controls must stay hidden after their disappearance callbacks")
    XCTAssertFalse(app.buttons["mobile-play-pause"].exists)
  }

  func testNativeFailureOffersRetryWithoutStandardAuto() throws {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_NATIVE_ERROR_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate() }
    let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Native playback failed")).firstMatch
    XCTAssertTrue(error.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Using standard playback")).firstMatch.exists)
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.exists)
    capture(app, "Native playback failure retains explicit retry")
    retry.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: error)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(app.buttons["mobile-play-pause"].waitForExistence(timeout: 5))
    app.buttons["Playback quality"].tap()
    XCTAssertTrue(app.buttons["Auto - Native Low Latency"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["Auto - Standard"].exists)
    capture(app, "Native retry keeps the native-only quality menu")
  }

  func testGlassPlayerControlsRemainUsableInLightAppearance() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_THEME"] = "light"
    app.launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    XCTAssertTrue(app.buttons["mobile-play-pause"].waitForExistence(timeout: 10))
    showSideChat(app)
    capture(app, "Native grouped glass player controls in light appearance")
    let topGroup = app.otherElements["mobile-player-top-actions"]
    let bottomGroup = app.otherElements["mobile-player-bottom-actions"]
    XCTAssertEqual(topGroup.frame.height, 44, accuracy: 1)
    XCTAssertEqual(topGroup.frame.minX, app.buttons["mobile-playback-mode"].frame.minX, accuracy: 1)
    XCTAssertEqual(topGroup.frame.maxX, topGroup.buttons["Close player"].frame.maxX, accuracy: 1)
    XCTAssertEqual(bottomGroup.frame.height, 44, accuracy: 1)
    XCTAssertEqual(bottomGroup.frame.minX, app.buttons["mobile-mute"].frame.minX, accuracy: 1)
    XCTAssertEqual(bottomGroup.frame.maxX, app.buttons["mobile-rotate-player"].frame.maxX, accuracy: 1)
    for identifier in ["mobile-minimize-player", "mobile-mute", "mobile-toggle-chat",
                       "mobile-rotate-player", "mobile-playback-mode"] {
      let button = app.buttons[identifier]
      XCTAssertTrue(button.exists)
      XCTAssertGreaterThanOrEqual(button.frame.width, 44)
      XCTAssertGreaterThanOrEqual(button.frame.height, 44)
      try assertDarkGlyphVisible(button)
    }
    let mute = app.buttons["mobile-mute"]
    let previousMuteLabel = mute.label
    mute.tap()
    XCTAssertNotEqual(mute.label, previousMuteLabel)
    app.buttons["mobile-playback-mode"].tap()
    XCTAssertTrue(app.navigationBars["Playback mode"].waitForExistence(timeout: 3))
    app.buttons["Done"].tap()
    app.buttons["Playback quality"].tap()
    XCTAssertTrue(app.navigationBars["Playback quality"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["Auto - Native Low Latency"].exists)
    XCTAssertFalse(app.buttons["Auto - Standard"].exists)
    XCTAssertFalse(app.buttons["Auto - Low Latency"].exists)
    XCTAssertFalse(app.buttons["Auto - High Quality"].exists)
    capture(app, "Native-only automatic playback menu")
    app.buttons["Done"].tap()
    app.buttons["mobile-minimize-player"].tap()
    XCTAssertTrue(app.buttons["mobile-expand-player"].waitForExistence(timeout: 3))
    capture(app, "Mini-player glass buttons in light appearance")
  }

  func testOptInPinchZoomKeepsActualLiveVideoVisible() throws {
    guard let login = ProcessInfo.processInfo.environment["STROZZ_ZOOM_LIVE_CHANNEL"] else {
      throw XCTSkip("Select a live channel to verify rendered video while pinching.")
    }
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_ZOOM_LIVE_CHANNEL"] = login
    app.launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let viewport = app.buttons["mobile-controls-toggle"]
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(viewport.waitForExistence(timeout: 15))
    expectation(for: NSPredicate { _, _ in
      !app.otherElements["mobile-video-loading"].exists && app.buttons["mobile-play-pause"].exists
    }, evaluatedWith: app)
    waitForExpectations(timeout: 40)
    tapVideo(app)
    capture(app, "Actual live picture before content zoom")
    let original = video.frame
    viewport.pinch(withScale: 2, velocity: 1)
    XCTAssertGreaterThan(video.frame.width, original.width * 1.5)
    XCTAssertFalse(app.buttons["mobile-expand-player"].exists)
    capture(app, "Actual live picture at two-times content zoom")
    let from = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
    from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 65, dy: 0)))
    capture(app, "Actual live picture after panning")
    viewport.pinch(withScale: 0.3, velocity: -1)
    XCTAssertEqual(video.frame.width, original.width, accuracy: 1)
  }

  func testExpandedVideoPinchZoomAndPanLeaveControlsAndChatUnscaled() {
    let app = launch(paused: true)
    defer { app.terminate() }
    let viewport = app.buttons["mobile-controls-toggle"]
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(viewport.waitForExistence(timeout: 10))
    let viewportFrame = viewport.frame
    let chatFrame = app.otherElements["mobile-player-chat-region"].frame
    let pauseFrame = app.buttons["mobile-play-pause"].frame
    let originalVideo = video.frame
    viewport.pinch(withScale: 2, velocity: 1)
    XCTAssertFalse(app.buttons["mobile-expand-player"].exists, "Pinching video must not minimize it")
    XCTAssertEqual(viewport.frame, viewportFrame)
    XCTAssertEqual(app.otherElements["mobile-player-chat-region"].frame, chatFrame)
    XCTAssertEqual(app.buttons["mobile-play-pause"].frame, pauseFrame)
    XCTAssertGreaterThan(video.frame.width, originalVideo.width * 1.5)
    let zoomed = video.frame
    let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 45, dy: 25)))
    XCTAssertEqual(viewport.frame, viewportFrame)
    XCTAssertFalse(app.buttons["mobile-expand-player"].exists, "Panning must not minimize the player")
    XCTAssertGreaterThan(video.frame.minX, zoomed.minX + 20)
    capture(app, "Pinched video with unscaled player controls and chat")
    viewport.pinch(withScale: 0.3, velocity: -1)
    XCTAssertEqual(video.frame.width, originalVideo.width, accuracy: 1)
    XCTAssertEqual(video.frame.minX, originalVideo.minX, accuracy: 1)

    viewport.pinch(withScale: 2, velocity: 1)
    app.buttons["mobile-minimize-player"].tap()
    let mini = app.buttons["mobile-expand-player"]
    XCTAssertTrue(mini.waitForExistence(timeout: 3))
    XCTAssertEqual(video.frame.width, mini.frame.width, accuracy: 1, "Mini-player must show the full picture")
    let miniWidth = mini.frame.width
    mini.pinch(withScale: 1.3, velocity: 1)
    XCTAssertGreaterThan(mini.frame.width, miniWidth + 10, "Existing mini-player resize gesture remains available")
    XCTAssertEqual(video.frame.width, mini.frame.width, accuracy: 1)
    mini.tap()
    XCTAssertTrue(viewport.waitForExistence(timeout: 3))
    XCTAssertEqual(video.frame.width, originalVideo.width, accuracy: 1)
    viewport.pinch(withScale: 2, velocity: 1)
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(viewport.waitForExistence(timeout: 5))
    XCTAssertEqual(video.frame.width, originalVideo.width, accuracy: 1, "Background playback must not retain a crop")
    capture(app, "Expanded player after resetting zoom through minimization")
  }

  func testFullscreenHidesStatusBarAndLeavingRestoresIt() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let fullscreen = app.buttons["mobile-rotate-player"]
    XCTAssertTrue(fullscreen.waitForExistence(timeout: 10))
    let statusBar = app.otherElements["fixture-status-bar"]
    expectation(for: NSPredicate(format: "value == 'visible'"), evaluatedWith: statusBar)
    waitForExpectations(timeout: 5)
    fullscreen.tap()
    expectation(for: NSPredicate(format: "value == 'hidden'"), evaluatedWith: statusBar)
    waitForExpectations(timeout: 5)
    capture(app, "Fullscreen video without system status bar")
    fullscreen.tap()
    expectation(for: NSPredicate(format: "value == 'visible'"), evaluatedWith: statusBar)
    waitForExpectations(timeout: 5)
    if UIDevice.current.userInterfaceIdiom == .pad {
      fullscreen.tap()
      app.buttons["mobile-minimize-player"].tap()
      XCTAssertTrue(app.buttons["mobile-expand-player"].waitForExistence(timeout: 3))
      expectation(for: NSPredicate(format: "value == 'visible'"), evaluatedWith: statusBar)
      waitForExpectations(timeout: 5)
    }
  }

  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testChatDividerAndSettingsResizePersistAndPreserveReadingPosition() {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = launch(paused: true)
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    showSideChat(app)
    let chat = app.otherElements["mobile-player-chat-region"]
    let handle = app.descendants(matching: .any).matching(identifier: "mobile-chat-resize-handle").firstMatch
    let timeline = app.scrollViews["mobile-chat-timeline"]
    XCTAssertTrue(handle.waitForExistence(timeout: 3))
    let originalWidth = chat.frame.width
    timeline.swipeDown()
    XCTAssertTrue(app.buttons["Jump to present"].waitForExistence(timeout: 3))
    let center = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: -70, dy: 0)),
      withVelocity: .slow, thenHoldForDuration: 0)
    XCTAssertEqual(chat.frame.width, originalWidth + 70, accuracy: 3)
    XCTAssertLessThanOrEqual(video.frame.maxX, chat.frame.minX + 1)
    XCTAssertTrue(app.buttons["Jump to present"].exists)
    let wider = chat.frame.width
    let moved = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    moved.press(forDuration: 0.1, thenDragTo: moved.withOffset(CGVector(dx: 40, dy: 0)),
      withVelocity: .slow, thenHoldForDuration: 0)
    XCTAssertEqual(chat.frame.width, wider - 40, accuracy: 3)
    let dragged = chat.frame.width

    app.buttons["mobile-chat-settings"].tap()
    let stepper = app.steppers["chat-setting-width"]
    XCTAssertTrue(stepper.waitForExistence(timeout: 3))
    capture(app, "Native saved side-chat width settings")
    stepper.buttons["chat-setting-width-Increment"].tap()
    app.buttons["Done"].tap()
    XCTAssertEqual(chat.frame.width, dragged + 20, accuracy: 2)
    let saved = chat.frame.width
    XCTAssertTrue(app.buttons["Jump to present"].exists)
    app.buttons["Jump to present"].tap()
    waitForHidden(app.buttons["Jump to present"])
    capture(app, "Resizable side chat after divider and settings adjustments")

    tapVideo(app)
    if !app.buttons["mobile-minimize-player"].waitForExistence(timeout: 0.3) { tapVideo(app) }
    app.buttons["mobile-minimize-player"].tap()
    XCTAssertTrue(app.buttons["mobile-expand-player"].waitForExistence(timeout: 3))
    XCTAssertFalse(handle.exists)
    app.buttons["mobile-expand-player"].tap()
    XCTAssertTrue(handle.waitForExistence(timeout: 3))
    XCTAssertEqual(chat.frame.width, saved, accuracy: 2)

    XCUIDevice.shared.orientation = .portrait
    expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
    waitForExpectations(timeout: 5)
    expectation(for: NSPredicate { _, _ in chat.frame.minY >= video.frame.maxY - 1 }, evaluatedWith: chat)
    waitForExpectations(timeout: 3)
    XCTAssertFalse(handle.exists)
    XCTAssertGreaterThanOrEqual(chat.frame.minY, video.frame.maxY - 1)
    XCUIDevice.shared.orientation = .landscapeLeft
    expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
    waitForExpectations(timeout: 5)
    showSideChat(app)
    XCTAssertEqual(chat.frame.width, saved, accuracy: 2)

    app.terminate()
    app.launchEnvironment.removeValue(forKey: "STROZZ_CHAT_WIDTH_FIXTURE_RESET")
    app.launch()
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    showSideChat(app)
    XCTAssertEqual(chat.frame.width, saved, accuracy: 2, "Saved width must survive relaunch")
    app.buttons["mobile-chat-settings"].tap()
    app.buttons["chat-setting-width-reset"].tap()
    app.buttons["Done"].tap()
    XCTAssertEqual(chat.frame.width, originalWidth, accuracy: 2)
  }

  private func assertDarkGlyphVisible(_ button: XCUIElement) throws {
    let image = try XCTUnwrap(button.screenshot().image.cgImage)
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var darkPixels = 0
    for y in (height / 4)..<(height * 3 / 4) {
      for x in (width / 4)..<(width * 3 / 4) {
        let offset = (y * width + x) * 4
        if pixels[offset + 3] > 200 && pixels[offset] < 80
          && pixels[offset + 1] < 80 && pixels[offset + 2] < 80 { darkPixels += 1 }
      }
    }
    XCTAssertGreaterThan(darkPixels, max(3, width * height / 200),
      "The light-theme glyph must remain visible above, not behind, the shared glass")
  }

  private func showSideChat(_ app: XCUIApplication) {
    let pause = app.buttons["mobile-play-pause"]
    if !pause.exists { tapVideo(app) }
    if !pause.waitForExistence(timeout: 0.3) { tapVideo(app) }
    if pause.label == "Pause" { pause.tap() }
    let toggle = app.buttons["mobile-toggle-chat"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 3))
    if toggle.label == "Show chat" { toggle.tap() }
  }

  func testChatResizeHandleFollowsControlsAndRestartsTimeoutAfterDragging() {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = launch(paused: true)
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    showSideChat(app)
    let handle = app.descendants(matching: .any).matching(identifier: "mobile-chat-resize-handle").firstMatch
    let controls = app.buttons["mobile-play-pause"]
    let chat = app.otherElements["mobile-player-chat-region"]
    XCTAssertTrue(handle.waitForExistence(timeout: 3))
    let initialChat = chat.frame
    let initialVideo = video.frame
    if controls.label == "Play" { controls.tap() }
    XCTAssertEqual(controls.label, "Pause", "The fixture must be playing before testing the idle timeout")
    waitForHidden(controls)
    XCTAssertFalse(handle.exists)
    XCTAssertEqual(chat.frame, initialChat)
    XCTAssertEqual(video.frame, initialVideo)

    tapVideo(app)
    XCTAssertTrue(handle.waitForExistence(timeout: 2))
    XCTAssertTrue(controls.exists)
    tapVideo(app)
    waitForHidden(handle)
    XCTAssertFalse(controls.exists)

    tapVideo(app)
    XCTAssertTrue(handle.waitForExistence(timeout: 2))
    let center = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: -40, dy: 0)),
      withVelocity: .slow, thenHoldForDuration: 5)
    XCTAssertEqual(chat.frame.width, initialChat.width + 40, accuracy: 3)
    XCTAssertTrue(handle.exists, "A drag must hold controls and restart the idle timeout on release")
    XCTAssertTrue(controls.exists)
    waitForHidden(controls)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "mobile-chat-resize-handle").firstMatch.exists)
    XCTAssertEqual(chat.frame.width, initialChat.width + 40, accuracy: 3)
  }

  func testSwipeMinimizesWithFullChatHistoryAndRestoresReadingPosition() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_LONG_CHAT_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate() }
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    let expanded = video.frame
    let timeline = app.scrollViews["mobile-chat-timeline"]
    for _ in 0..<3 { timeline.swipeDown() }
    XCTAssertTrue(app.buttons["Jump to present"].exists)
    for _ in 0..<3 {
      let start = video.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25))
      let clock = Date()
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 150)),
        withVelocity: .slow, thenHoldForDuration: 0)
      let mini = app.buttons["mobile-expand-player"]
      XCTAssertTrue(mini.waitForExistence(timeout: 2))
      XCTAssertLessThan(video.frame.width, expanded.width - 50)
      let measurement = XCTAttachment(string: "Swipe and XCTest synchronization: \(Date().timeIntervalSince(clock)) seconds")
      measurement.name = "Full-history minimize interaction"
      measurement.lifetime = .keepAlways
      add(measurement)
      mini.tap()
      XCTAssertTrue(app.buttons["mobile-controls-toggle"].waitForExistence(timeout: 2))
      XCTAssertEqual(video.frame.width, expanded.width, accuracy: 1)
      XCTAssertTrue(app.buttons["Jump to present"].exists)
    }
  }

  func testThreePlaybackModesRetainChatAndDraftAndRestoreVideo() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_DRAFT_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_LONG_CHAT_FIXTURE"] = "1"
    app.launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let chat = app.otherElements["mobile-player-chat-region"]
    let field = app.textViews["mobile-chat-composer-input"]
    let timeline = app.scrollViews["mobile-chat-timeline"]
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    let originalChatHeight = chat.frame.height
    field.tap()
    field.typeText("Keep this draft in every mode")
    tapVideo(app)
    if !app.buttons["mobile-playback-mode"].waitForExistence(timeout: 0.3) { tapVideo(app) }
    for _ in 0..<3 { timeline.swipeDown() }
    let jump = app.buttons["Jump to present"]
    XCTAssertTrue(jump.exists)

    selectMode("Chat only", in: app)
    let header = app.otherElements["mobile-chat-only-controls"]
    XCTAssertTrue(header.waitForExistence(timeout: 3))
    XCTAssertEqual(video.frame.size, .zero, "The mounted player must reserve no space")
    XCTAssertFalse(app.buttons["mobile-play-pause"].exists)
    XCTAssertFalse(app.buttons["mobile-audio-play-pause"].exists)
    XCTAssertGreaterThan(chat.frame.height, originalChatHeight + 100)
    XCTAssertEqual(field.value as? String, "Keep this draft in every mode")
    XCTAssertTrue(jump.exists)
    capture(app, "Chat only fills the window with accessible mode and close controls")

    selectMode("Audio and chat", in: app)
    let audio = app.buttons["mobile-audio-play-pause"]
    XCTAssertTrue(audio.waitForExistence(timeout: 3))
    XCTAssertEqual(video.frame.size, .zero)
    XCTAssertEqual(audio.label, "Pause audio")
    audio.tap()
    XCTAssertEqual(audio.label, "Play audio")
    audio.tap()
    XCTAssertEqual(audio.label, "Pause audio")
    XCTAssertEqual(field.value as? String, "Keep this draft in every mode")
    XCTAssertTrue(jump.exists)
    XCUIDevice.shared.orientation = .landscapeLeft
    expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
    waitForExpectations(timeout: 5)
    XCTAssertGreaterThan(chat.frame.width, app.frame.width * 0.8)
    XCTAssertTrue(header.frame.contains(app.buttons["mobile-playback-mode"].frame))
    capture(app, "Audio and full-width chat in landscape")

    selectMode("Video and chat", in: app)
    expectation(for: NSPredicate { _, _ in video.frame.width > 0 }, evaluatedWith: video)
    waitForExpectations(timeout: 3)
    XCTAssertFalse(header.exists)
    XCTAssertTrue(chat.exists, "Restoring video must also restore chat in phone landscape")
    XCTAssertLessThanOrEqual(video.frame.maxX, chat.frame.minX + 1)
    XCTAssertEqual(field.value as? String, "Keep this draft in every mode")
    XCTAssertTrue(jump.exists)
    waitForHidden(app.buttons["mobile-play-pause"])
  }

  func testChatOnlyRetainsACloseControlWithoutVideo() {
    let app = launch(paused: true)
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["mobile-playback-mode"].waitForExistence(timeout: 10))
    selectMode("Chat only", in: app)
    app.buttons["Close player"].tap()
    waitForHidden(app.otherElements["mobile-player-chat-region"])
  }

  func testChoosingVideoAndChatRevealsChatWithoutChangingPlaybackMode() {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = launch(paused: true)
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let toggle = app.buttons["mobile-toggle-chat"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    if toggle.label == "Hide chat" { toggle.tap() }
    selectMode("Video and chat", in: app)
    XCTAssertEqual(toggle.label, "Hide chat")
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let chat = app.otherElements["mobile-player-chat-region"]
    XCTAssertLessThanOrEqual(video.frame.maxX, chat.frame.minX + 1)
  }

  private func selectMode(_ mode: String, in app: XCUIApplication) {
    let button = app.buttons["mobile-playback-mode"]
    XCTAssertTrue(button.waitForExistence(timeout: 3))
    button.tap()
    XCTAssertTrue(app.navigationBars["Playback mode"].waitForExistence(timeout: 3))
    app.buttons[mode].tap()
    waitForHidden(app.navigationBars["Playback mode"])
  }

  func testDetailsCollapseWithControlsAndTappingVideoRestoresBoth() {
    let app = launch()
    defer { app.terminate() }
    let details = app.otherElements["mobile-stream-details"]
    let controls = app.buttons["mobile-play-pause"]
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let timeline = app.scrollViews["mobile-chat-timeline"]
    XCTAssertTrue(details.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Stream chat"].exists)
    XCTAssertFalse(app.buttons["mobile-toggle-chat"].exists, "Portrait has no sideways chat toggle")
    XCTAssertTrue(app.staticTexts["Sample streamer"].exists)
    XCTAssertTrue(app.staticTexts["A stream description that appears with the controls"].exists)
    XCTAssertTrue(controls.exists)
    let uptime = app.staticTexts["mobile-stream-uptime"]
    XCTAssertTrue(uptime.exists)
    XCTAssertFalse(details.staticTexts["Auto - Native Low Latency"].exists)
    tapVideo(app)
    if !controls.waitForExistence(timeout: 0.3) { tapVideo(app) }
    XCTAssertTrue(details.exists)
    let videoFrame = video.frame
    let expandedChat = timeline.frame
    capture(app, "Stream profile and controls on entry")
    waitForHidden(details)
    XCTAssertFalse(controls.exists)
    XCTAssertFalse(uptime.exists, "Uptime follows the controls rather than becoming always visible")
    XCTAssertGreaterThan(timeline.frame.height, expandedChat.height + 50)
    XCTAssertEqual(timeline.frame.minY, video.frame.maxY, accuracy: 1,
      "Collapsed chat must start directly below the video without an empty heading row")
    XCTAssertEqual(video.frame, videoFrame, "Collapsing details must not resize the video")
    assertLatestVisible(app, timeline: timeline)
    capture(app, "Video and chat after automatic collapse")

    tapVideo(app)
    XCTAssertTrue(details.waitForExistence(timeout: 2))
    XCTAssertTrue(controls.exists)
    XCTAssertEqual(timeline.frame.height, expandedChat.height, accuracy: 1)
    assertLatestVisible(app, timeline: timeline)
    tapVideo(app)
    waitForHidden(details)
    XCTAssertFalse(controls.exists)

    for _ in 0..<3 { timeline.swipeDown() }
    let jump = app.buttons["Jump to present"]
    XCTAssertTrue(jump.waitForExistence(timeout: 3))
    tapVideo(app)
    XCTAssertTrue(details.waitForExistence(timeout: 2))
    XCTAssertTrue(jump.exists, "Revealing details must not recreate chat or lose its read position")
    tapVideo(app)
    waitForHidden(details)
    XCTAssertTrue(jump.exists)
    tapVideo(app)
    app.buttons["mobile-minimize-player"].tap()
    XCTAssertFalse(details.exists)
    XCTAssertTrue(app.buttons["mobile-expand-player"].waitForExistence(timeout: 3))
    app.buttons["mobile-expand-player"].tap()
    XCTAssertTrue(details.waitForExistence(timeout: 3))
    XCTAssertTrue(jump.exists, "Minimizing and restoring must keep the existing chat position")
    XCTAssertEqual(video.frame, videoFrame)
  }

  func testPausedKeepsDetailsVisible() {
    let app = launch()
    defer { app.terminate() }
    let details = app.otherElements["mobile-stream-details"]
    let pause = app.buttons["mobile-play-pause"]
    XCTAssertTrue(pause.waitForExistence(timeout: 10))
    pause.tap()
    XCTAssertEqual(pause.label, "Play")
    let hiddenWhilePaused = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: details)
    hiddenWhilePaused.isInverted = true
    waitForExpectations(timeout: 5)
  }

  func testLiveTimeAndViewersAreOneUnboxedRow() {
    let app = launch()
    defer { app.terminate() }
    let uptime = app.staticTexts["mobile-stream-uptime"]
    XCTAssertTrue(uptime.waitForExistence(timeout: 10))
    app.buttons["mobile-mute"].tap()
    let live = app.descendants(matching: .any).matching(identifier: "mobile-live-status").firstMatch
    let viewers = app.descendants(matching: .any).matching(identifier: "mobile-viewer-readout").firstMatch
    XCTAssertTrue(viewers.exists)
    XCTAssertEqual(live.frame.midY, viewers.frame.midY, accuracy: 1,
      "Elapsed time and viewers must sit side by side, not stack")
    XCTAssertEqual(live.frame.minX - viewers.frame.maxX, 14, accuracy: 1)
    XCTAssertLessThan(live.frame.maxX, app.buttons["mobile-mute"].frame.minX)
    XCTAssertFalse(app.staticTexts["Live"].exists, "The elapsed timer replaces the redundant Live word")
    capture(app, "Horizontal red-dot time and viewer readouts without backplates")
  }

  func testQualitySheetHoldsDetailsAndRestartsTheIdleTimeout() {
    let app = launch()
    defer { app.terminate() }
    let details = app.otherElements["mobile-stream-details"]
    let pause = app.buttons["mobile-play-pause"]
    XCTAssertTrue(pause.waitForExistence(timeout: 10))
    app.buttons["Playback quality"].tap()
    XCTAssertTrue(app.navigationBars["Playback quality"].waitForExistence(timeout: 3))
    let closedEarly = expectation(for: NSPredicate(format: "exists == false"),
      evaluatedWith: app.navigationBars["Playback quality"])
    closedEarly.isInverted = true
    waitForExpectations(timeout: 5)
    app.buttons["Done"].tap()
    XCTAssertTrue(details.waitForExistence(timeout: 2))
    XCTAssertTrue(pause.exists)
    waitForHidden(details)
    XCTAssertFalse(pause.exists)
  }

  func testLandscapePreservesTheVideoAndSideChatLayout() {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let details = app.otherElements["mobile-stream-details"]
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    let timeline = app.scrollViews["mobile-chat-timeline"]
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    expectation(for: NSPredicate { _, _ in
      app.frame.width > app.frame.height && video.frame.width > video.frame.height
    }, evaluatedWith: app)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(app.frame.contains(video.frame))
    if UIDevice.current.userInterfaceIdiom == .phone {
      XCTAssertFalse(details.exists, "Phone fullscreen must not reveal an offscreen profile")
      XCTAssertFalse(timeline.isHittable)
      XCTAssertGreaterThan(video.frame.width, video.frame.height)
      let fullscreenWidth = video.frame.width
      let toggle = app.buttons["mobile-toggle-chat"]
      tapVideo(app)
      if !toggle.waitForExistence(timeout: 0.3) { tapVideo(app) }
      XCTAssertEqual(toggle.label, "Show chat")
      app.buttons["mobile-play-pause"].tap()
      toggle.tap()
      XCTAssertTrue(timeline.waitForExistence(timeout: 3))
      XCTAssertTrue(app.frame.contains(timeline.frame))
      XCTAssertGreaterThanOrEqual(timeline.frame.minX, video.frame.maxX)
      assertCenteredSideLayout(app, video: video)
      XCTAssertEqual(toggle.label, "Hide chat")
      capture(app, "Phone landscape with optional side chat")
      app.buttons["mobile-toggle-chat"].tap()
      XCTAssertEqual(video.frame.width, fullscreenWidth, accuracy: 1)
      XCTAssertEqual(app.buttons["mobile-toggle-chat"].label, "Show chat")
      capture(app, "Phone landscape after hiding side chat")
      let hiddenChat = app.otherElements["mobile-player-chat-region"]
      XCTAssertGreaterThanOrEqual(hiddenChat.frame.minX, video.frame.maxX - 1)
      let rotate = app.buttons["mobile-rotate-player"]
      XCTAssertEqual(rotate.label, "Rotate to portrait")
      rotate.tap()
      expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
      waitForExpectations(timeout: 5)
      app.scrollViews["mobile-chat-timeline"].swipeDown()
      XCTAssertTrue(app.buttons["Jump to present"].waitForExistence(timeout: 3))
      XCTAssertFalse(toggle.exists)
    } else {
      tapVideo(app)
      if !details.waitForExistence(timeout: 0.5) { tapVideo(app) }
      XCTAssertTrue(details.waitForExistence(timeout: 2))
      let videoFrame = video.frame
      let chatFrame = timeline.frame
      XCTAssertTrue(app.frame.contains(chatFrame), "Side chat must stay fully on screen")
      XCTAssertGreaterThanOrEqual(chatFrame.minX, videoFrame.maxX)
      assertCenteredSideLayout(app, video: video)
      waitForHidden(details)
      XCTAssertEqual(video.frame, videoFrame)
      XCTAssertEqual(timeline.frame, chatFrame)
      tapVideo(app)
      XCTAssertTrue(details.waitForExistence(timeout: 2))
      XCTAssertEqual(timeline.frame, chatFrame)
      capture(app, "Tablet side chat with stream profile revealed")
    }
  }

  func testRepeatedPortraitLandscapeTransitionsPreserveDraftAndChat() {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_PLAYER_DRAFT_FIXTURE"] = "1"
    app.launchEnvironment["STROZZ_CHAT_WIDTH_FIXTURE_RESET"] = "1"
    app.launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let field = app.textViews["mobile-chat-composer-input"]
    let timeline = app.scrollViews["mobile-chat-timeline"]
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let portraitWidth = video.frame.width
    field.tap()
    field.typeText("Keep this draft while rotating")
    XCTAssertEqual(video.frame.width, portraitWidth, accuracy: 1,
      "The portrait keyboard must not move chat into a sidebar")
    XCTAssertFalse(app.buttons["mobile-toggle-chat"].exists,
      "Opening the keyboard in portrait must not switch to the landscape layout")
    tapVideo(app)
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
    waitForExpectations(timeout: 5)
    timeline.swipeDown()
    XCTAssertTrue(app.buttons["Jump to present"].exists)
    let portraitVideo = video.frame
    for iteration in 0..<2 {
      XCUIDevice.shared.orientation = iteration == 0 ? .landscapeLeft : .landscapeRight
      expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
      waitForExpectations(timeout: 5)
      if UIDevice.current.userInterfaceIdiom == .phone {
        if !app.buttons["mobile-toggle-chat"].isHittable { tapVideo(app) }
        if app.buttons["mobile-toggle-chat"].label == "Show chat" { app.buttons["mobile-toggle-chat"].tap() }
      }
      let rotatedTimeline = app.scrollViews["mobile-chat-timeline"]
      XCTAssertTrue(rotatedTimeline.waitForExistence(timeout: 5))
      XCTAssertEqual(field.value as? String, "Keep this draft while rotating")
      XCTAssertTrue(app.buttons["Jump to present"].exists)
      assertCenteredSideLayout(app, video: video)
      capture(app, "Landscape \(iteration) with centered video and retained draft")
      let jump = app.buttons["Jump to present"]
      jump.tap()
      waitForHidden(jump)
      rotatedTimeline.swipeDown()
      XCTAssertTrue(jump.waitForExistence(timeout: 3))
      XCUIDevice.shared.orientation = .portrait
      expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
      waitForExpectations(timeout: 5)
      XCTAssertEqual(field.value as? String, "Keep this draft while rotating")
      XCTAssertTrue(app.buttons["Jump to present"].exists)
      XCTAssertEqual(video.frame.width, portraitVideo.width, accuracy: 1)
      XCTAssertEqual(video.frame.height, portraitVideo.height, accuracy: 1)
      XCTAssertGreaterThanOrEqual(timeline.frame.minY, video.frame.maxY - 1)
      capture(app, "Portrait \(iteration) after rotation with retained draft")
    }
  }

  private func assertCenteredSideLayout(_ app: XCUIApplication, video: XCUIElement) {
    let chat = app.otherElements["mobile-player-chat-region"]
    XCTAssertTrue(chat.exists)
    XCTAssertLessThanOrEqual(chat.frame.width, 320.5)
    XCTAssertLessThanOrEqual(chat.frame.width, app.frame.width / 3 + 1)
    // Scroll-view accessibility bounds include the iPad status-bar area even
    // when drawing is clipped; use the fixture's actual safe-area layout proposal.
    let viewport = (app.otherElements["fixture-player-viewport"].value as? String ?? "")
      .split(separator: " ").compactMap { Double($0) }
    XCTAssertEqual(viewport.count, 2)
    guard viewport.count == 2 else { return }
    XCTAssertEqual(video.frame.midY, viewport[0] + viewport[1] / 2, accuracy: 1,
      "The video must stay vertically centered even when profile details are revealed")
    XCTAssertLessThanOrEqual(video.frame.maxX, chat.frame.minX + 1)
  }

  func testLandscapeProfileDoesNotOverlapControlsOrMoveTheVideo() {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = launch()
    defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
    let video = app.descendants(matching: .any).matching(identifier: "mobile-video-surface").firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    tapVideo(app)
    if !app.buttons["mobile-toggle-chat"].waitForExistence(timeout: 0.3) { tapVideo(app) }
    if app.buttons["mobile-toggle-chat"].label == "Show chat" { app.buttons["mobile-toggle-chat"].tap() }
    tapVideo(app)
    if !app.buttons["mobile-play-pause"].waitForExistence(timeout: 0.3) { tapVideo(app) }
    app.buttons["mobile-play-pause"].tap()
    let details = app.otherElements["mobile-stream-details"]
    XCTAssertTrue(details.waitForExistence(timeout: 2))
    let videoFrame = video.frame
    let detailsFrame = details.frame
    let buttonsFrame = app.buttons["mobile-mute"].frame
    XCTAssertGreaterThanOrEqual(detailsFrame.minY, videoFrame.minY)
    XCTAssertLessThanOrEqual(detailsFrame.maxY, videoFrame.maxY + 1)
    XCTAssertLessThanOrEqual(buttonsFrame.maxY, detailsFrame.minY + 1)
    assertCenteredSideLayout(app, video: video)
    capture(app, "Centered landscape video with compact profile and clear controls")
  }

  private func launch(paused: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["STROZZ_LAYOUT_FIXTURE"] = "player-chrome"
    app.launchEnvironment["STROZZ_CHAT_WIDTH_FIXTURE_RESET"] = "1"
    if paused { app.launchEnvironment["STROZZ_PLAYER_PAUSED_FIXTURE"] = "1" }
    app.launch()
    return app
  }

  private func tapVideo(_ app: XCUIApplication) {
    app.buttons["mobile-controls-toggle"]
      .coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
  }

  private func waitForHidden(_ element: XCUIElement) {
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
    waitForExpectations(timeout: 7)
  }

  private func assertLatestVisible(_ app: XCUIApplication, timeline: XCUIElement) {
    let latest = app.descendants(matching: .any).matching(identifier: "mobile-chat-latest-message").firstMatch
    XCTAssertTrue(latest.exists)
    XCTAssertGreaterThan(latest.frame.height, 0)
    XCTAssertGreaterThanOrEqual(latest.frame.minY, timeline.frame.minY - 1)
    XCTAssertLessThanOrEqual(latest.frame.maxY, timeline.frame.maxY + 1)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

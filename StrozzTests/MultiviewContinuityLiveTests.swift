import AVKit
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class MultiviewContinuityLiveTests: XCTestCase {
  func testOptInLiveZoomKeepsPlayersItemsAndAVKitSurfaces() async throws {
    #if targetEnvironment(simulator)
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_MULTIVIEW_LIVE_TESTS"] == "1",
      let names = settings["STROZZ_MATRIX_CHANNELS"] else {
      throw XCTSkip("Enable STROZZ_MULTIVIEW_LIVE_TESTS with two to four live channels.")
    }
    try await check(names: names, settings: settings, muted: true, environment: AppEnvironment())
    #else
    throw XCTSkip("This opt-in check must not take over the physical TV.")
    #endif
  }

  func testOptInPhysicalLiveFollowedZoomKeepsPlayback() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Hardware verification requires its own explicit opt-in.")
    #else
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_MULTIVIEW_PHYSICAL_TESTS"] == "1",
      let names = settings["STROZZ_MATRIX_CHANNELS"] else {
      throw XCTSkip("Explicitly select live followed channels for a permitted hardware check.")
    }
    let requested = names.split(separator: ",").map { $0.lowercased() }
    guard requested.count == 4, Set(requested).count == 4 else {
      return XCTFail("Hardware verification requires four distinct followed channels")
    }
    for _ in 0..<50 {
      if AppEnvironment.playbackTestEnvironment != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let environment = try XCTUnwrap(AppEnvironment.playbackTestEnvironment)
    for _ in 0..<300 {
      if environment.accountSync.hasCompletedInitialSync,
        environment.follows.lastUpdatedAt != nil, !environment.follows.isLoading { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard environment.auth.isAuthenticated else {
      throw XCTSkip("Wait for the real account restoration; do not create a second auth session")
    }
    let liveFollowed = Set(environment.follows.channels.filter(\.isLive).map(\.channelKey))
    guard !environment.follows.isUsingDemoData, requested.allSatisfy(liveFollowed.contains) else {
      throw XCTSkip("The selected channels must still be live in the real Following list")
    }
    try await check(names: names, settings: settings,
      muted: settings["STROZZ_MULTIVIEW_TEST_AUDIO"] != "audible", environment: environment)
    #endif
  }

  private func check(names: String, settings: [String: String], muted: Bool,
                     environment: AppEnvironment) async throws {
    let logins = names.split(separator: ",").map(String.init)
    guard (2...4).contains(logins.count) else { return XCTFail("Select two to four live sources") }
    guard let holdSeconds = Int(settings["STROZZ_MULTIVIEW_HOLD_SECONDS"] ?? "5"),
      (5...300).contains(holdSeconds) else { return XCTFail("Expanded hold must be between 5 and 300 seconds") }
    let channels = logins.map { login in
      FollowedChannel(id: login, login: login, displayName: login, title: "", gameName: "",
        viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    }
    let controller = MultiviewController(channels: channels, muted: muted)
    let audiblePaneID = muted ? nil : controller.panes.first?.id
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let host = UIHostingController(rootView: MultiviewPlayerView(
      channels: channels, availableChannels: channels, auth: environment.auth, goLive: nil,
      onWatch: { _ in }, controller: controller)
      .environment(environment)
      .environment(\.themePalette, ThemePalette.dark))
    // Simulators stay silent; authorized hardware checks keep only the first stream audible.
    window.rootViewController = host
    defer {
      let states = controller.panes.map { pane in
        ["channel": pane.channel.login, "native": String(pane.model.isUsingNativeHLS),
         "offline": String(pane.model.isOffline), "loading": String(pane.isLoading),
         "error": String(pane.model.errorMessage != nil), "fallback": pane.model.nativeFallbackReason ?? "none"]
      }
      do {
        let data = try JSONSerialization.data(withJSONObject: states, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Multiview final states"
        attachment.lifetime = .keepAlways
        add(attachment)
      } catch { XCTFail("Could not preserve multiview state evidence") }
      controller.teardown()
      window.rootViewController = previous
    }
    controller.setAudiblePane(audiblePaneID)
    try await ready(controller, host: host, audiblePaneID: audiblePaneID)
    let players = controller.panes.map(\.player)
    let items = try controller.panes.map { try XCTUnwrap($0.player.currentItem) }
    let outputs = items.map { item in
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
      item.add(output)
      return output
    }
    defer {
      for (item, output) in zip(items, outputs) { item.remove(output) }
    }
    let originalSurfaces = surfaces(in: host)
    let surfacesByPlayer = Dictionary(uniqueKeysWithValues: originalSurfaces.compactMap { surface in
      surface.player.map { (ObjectIdentifier($0), surface) }
    })
    XCTAssertEqual(surfacesByPlayer.count, channels.count)
    attach(host, name: "Native multiview grid")
    var transitions: [[String: String]] = []
    for selected in controller.panes.prefix(muted ? 2 : 1) {
      let selectedIndex = try XCTUnwrap(controller.panes.firstIndex(where: { $0 === selected }))
      let output = outputs[selectedIndex]
      let surface = try XCTUnwrap(surfacesByPlayer[ObjectIdentifier(selected.player)])
      let gridFrame = surface.view.convert(surface.view.bounds, to: host.view)
      let startClock = selected.player.currentTime().seconds
      controller.expand(selected.id)
      var expandingFrames = 0
      for _ in 0..<15 {
        try await Task.sleep(for: .milliseconds(100))
        try assertIdentity(controller, host: host, players: players, items: items,
          surfaces: surfacesByPlayer, audiblePaneID: audiblePaneID)
        if output.hasNewPixelBuffer(forItemTime: items[selectedIndex].currentTime()),
          output.copyPixelBuffer(forItemTime: items[selectedIndex].currentTime(), itemTimeForDisplay: nil) != nil {
          expandingFrames += 1
        }
      }
      let expandedFrame = surface.view.convert(surface.view.bounds, to: host.view)
      XCTAssertGreaterThan(expandedFrame.width, gridFrame.width)
      XCTAssertGreaterThan(selected.player.currentTime().seconds, startClock + 0.5)
      XCTAssertTrue(surface.isReadyForDisplay)
      XCTAssertGreaterThanOrEqual(expandingFrames, 12, "Video must advance during the zoom, not just retain its owner")
      XCTAssertTrue(controller.panes.filter { $0 !== selected }.allSatisfy { $0.qualityTier == .thumbnail })
      attach(host, name: "Expanded normal player \(selected.channel.login)")
      let hiddenClocks = controller.panes.map { $0.player.currentTime().seconds }
      var previousHeight = selected.player.currentItem?.presentationSize.height ?? 0
      var qualityChanges = 0
      var freshFrames = 0
      let highest = selected.model.playback?.qualities.filter { !$0.isAudioOnly }
        .compactMap { PlayerView.verticalResolution(from: $0.name) }.max()
      var reachedHighestAt: Int?
      var dropsAfterHighest = 0
      for second in 0..<holdSeconds {
        try await Task.sleep(for: .seconds(1))
        try assertIdentity(controller, host: host, players: players, items: items,
          surfaces: surfacesByPlayer, audiblePaneID: audiblePaneID)
        let item = items[selectedIndex]
        let height = item.presentationSize.height
        if second >= 15, height > 0, previousHeight > 0, height != previousHeight { qualityChanges += 1 }
        if let highest {
          if height >= CGFloat(highest), reachedHighestAt == nil { reachedHighestAt = second }
          if second >= 15, reachedHighestAt != nil, height < previousHeight { dropsAfterHighest += 1 }
        }
        previousHeight = height
        if output.hasNewPixelBuffer(forItemTime: item.currentTime()),
          output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil {
          freshFrames += 1
        }
        transitions.append(["channel": selected.channel.login, "phase": "expanded", "second": String(second),
          "height": String(Double(height)), "clock": String(item.currentTime().seconds),
          "peak_bitrate": String(item.preferredPeakBitRate), "fresh_frames": String(freshFrames),
          "settled_quality_changes": String(qualityChanges),
          "reached_highest_at": reachedHighestAt.map(String.init) ?? "not_yet",
          "drops_after_highest": String(dropsAfterHighest)])
      }
      XCTAssertGreaterThanOrEqual(freshFrames, Int(ceil(Double(holdSeconds) * 0.98)),
        "Expanded Auto must keep delivering video, not merely preserve its player")
      if holdSeconds >= 60, highest != nil {
        // A monotonic startup upgrade is not oscillation. Require prompt full
        // quality and reject every subsequent drop in this unthrottled check.
        XCTAssertLessThanOrEqual(reachedHighestAt ?? holdSeconds, 30, "Expanded Auto must reach full quality promptly")
        XCTAssertEqual(dropsAfterHighest, 0, "Expanded Auto must not cycle away from sustained full quality")
      }
      for hidden in controller.panes where hidden !== selected {
        let index = try XCTUnwrap(controller.panes.firstIndex(where: { $0 === hidden }))
        let bytes = await hidden.model.nativeHLS?.origin.snapshot().cachedMediaBytes ?? 0
        transitions.append(["hidden_channel": hidden.channel.login,
          "height": String(Double(hidden.player.currentItem?.presentationSize.height ?? 0)),
          "bitrate_limit": String(hidden.player.currentItem?.preferredPeakBitRate ?? 0),
          "cached_media_bytes": String(bytes), "muted": String(hidden.player.isMuted)])
        XCTAssertEqual(hidden.player.currentItem?.preferredPeakBitRate, 800_000)
        XCTAssertTrue(hidden.player.isMuted)
        XCTAssertGreaterThan(hidden.player.currentTime().seconds - hiddenClocks[index], Double(holdSeconds) * 0.8,
          "Hidden panes must remain live, not merely retain an old item")
      }
      let expandedClock = selected.player.currentTime().seconds
      PlayerView(channel: selected.channel.login, auth: environment.auth, model: selected.model).closePlayer()
      var returningFrames = 0
      for _ in 0..<15 {
        try await Task.sleep(for: .milliseconds(100))
        try assertIdentity(controller, host: host, players: players, items: items,
          surfaces: surfacesByPlayer, audiblePaneID: audiblePaneID)
        if output.hasNewPixelBuffer(forItemTime: items[selectedIndex].currentTime()),
          output.copyPixelBuffer(forItemTime: items[selectedIndex].currentTime(), itemTimeForDisplay: nil) != nil {
          returningFrames += 1
        }
      }
      let returned = surface.view.convert(surface.view.bounds, to: host.view)
      XCTAssertEqual(returned.width, gridFrame.width, accuracy: 2)
      XCTAssertEqual(returned.height, gridFrame.height, accuracy: 2)
      XCTAssertGreaterThan(selected.player.currentTime().seconds, expandedClock + 0.5)
      XCTAssertGreaterThanOrEqual(returningFrames, 12, "Returning to the grid must retain advancing video")
      transitions.append(["channel": selected.channel.login, "grid_width": "\(gridFrame.width)",
        "expanded_width": "\(expandedFrame.width)", "returned_width": "\(returned.width)",
        "same_player_item_surface": "true", "expanding_frames": String(expandingFrames),
        "returning_frames": String(returningFrames)])
    }
    if muted {
      let pausedPane = controller.panes[0]
      let pausedItem = pausedPane.player.currentItem
      let pausedView = PlayerView(channel: pausedPane.channel.login, auth: environment.auth, model: pausedPane.model)
      pausedView.toggleRewindPlayPause()
      controller.expand(pausedPane.id)
      try await Task.sleep(for: .milliseconds(400))
      controller.collapse()
      try await Task.sleep(for: .milliseconds(400))
      XCTAssertTrue(pausedPane.model.isUserPaused)
      XCTAssertEqual(pausedPane.player.rate, 0)
      XCTAssertTrue(pausedPane.player.currentItem === pausedItem)
      pausedView.toggleRewindPlayPause()
    }
    attach(host, name: "Returned native multiview grid")
    let data = try JSONSerialization.data(withJSONObject: transitions, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "Multiview continuity identities"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func ready(_ controller: MultiviewController, host: UIViewController,
                     audiblePaneID: String?) async throws {
    for _ in 0..<450 {
      XCTAssertTrue(controller.panes.allSatisfy { $0.player.isMuted == ($0.id != audiblePaneID) })
      let rendered = surfaces(in: host)
      if controller.panes.allSatisfy({ pane in
        pane.model.isUsingNativeHLS && pane.model.nativeStartupComplete && !pane.isLoading
          && pane.player.timeControlStatus == .playing
          && pane.model.playbackTelemetry.videoFrameAge.map { $0 < 3 } == true
          && rendered.contains { $0.player === pane.player && $0.isReadyForDisplay }
      }) { return }
      if controller.panes.contains(where: { $0.hasError || $0.model.nativeFallbackReason != nil }) {
        for pane in controller.panes where pane.hasError || pane.model.nativeFallbackReason != nil {
          XCTFail("\(pane.channel.login): \(pane.model.isOffline ? "offline" : pane.model.nativeFallbackReason ?? "playback error")")
        }
        throw URLError(.cannotDecodeContentData)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("All multiview panes must show native video before testing the transition")
    throw URLError(.timedOut)
  }

  private func assertIdentity(_ controller: MultiviewController, host: UIViewController,
                              players: [AVPlayer], items: [AVPlayerItem],
                              surfaces original: [ObjectIdentifier: AVPlayerViewController],
                              audiblePaneID: String?) throws {
    let current = surfaces(in: host)
    for (index, pane) in controller.panes.enumerated() {
      XCTAssertTrue(pane.player === players[index], "Zoom must not create a player")
      XCTAssertTrue(pane.player.currentItem === items[index], "Zoom must not reload playback")
      XCTAssertTrue(current.contains { $0 === original[ObjectIdentifier(pane.player)] },
                    "Zoom must preserve the actual AVKit surface")
      XCTAssertTrue(pane.model.isUsingNativeHLS)
      XCTAssertEqual(pane.player.isMuted, pane.id != audiblePaneID, "Audio must remain with the authorized stream")
    }
    XCTAssertEqual(current.count, players.count, "No extra rendering owner may appear during zoom")
  }

  private func surfaces(in controller: UIViewController) -> [AVPlayerViewController] {
    if let surface = controller as? AVPlayerViewController { return [surface] }
    return controller.children.flatMap { surfaces(in: $0) }
  }

  private func attach(_ host: UIViewController, name: String) {
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

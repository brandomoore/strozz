import AVFoundation
import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileHomeLayoutTests: XCTestCase {
  func testSkeletonCardsReserveLoadedGeometryAtPhoneAndTabletWidths() {
    for width in [300.0, 356, 480] {
      for typeSize in [DynamicTypeSize.large, .accessibility2] {
        for theme in [AppTheme.system, .light, .dark, .oled] {
          let palette = theme.palette(systemColorScheme: .light)
          let skeleton = UIHostingController(rootView:
            MobileChannelCard(channel: LoadingSkeleton.channels[0])
              .modifier(LoadingSkeletonStyle())
              .environment(\.dynamicTypeSize, typeSize).environment(\.themePalette, palette))
          let loaded = UIHostingController(rootView:
            MobileChannelCard(channel: channel("Streamer"))
              .environment(\.dynamicTypeSize, typeSize).environment(\.themePalette, palette))
          let proposal = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
          XCTAssertEqual(skeleton.sizeThatFits(in: proposal).height, loaded.sizeThatFits(in: proposal).height, accuracy: 1)
        }
      }
    }
  }

  func testShortcutSkeletonMatchesTheRememberedCountWithoutUnusedRows() {
    for width in [300.0, 356, 788] {
      for typeSize in [DynamicTypeSize.large, .accessibility2] {
        let proposal = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
        var heights: [Int: CGFloat] = [:]
        for count in [0, 1, 2, 3, 4, 5, 6] {
          let restoring = UIHostingController(rootView:
            MobileFollowedShortcuts(channels: [], onSelect: { _ in }, onSeeAll: {},
                                    authenticated: false, isRestoringAccount: true, skeletonCount: count)
              .environment(\.dynamicTypeSize, typeSize))
          let reservedHeight = restoring.sizeThatFits(in: proposal).height
          for category in ["Just Chatting", ""] {
            let loaded = UIHostingController(rootView:
              MobileFollowedShortcuts(channels: (0..<count).map { channel("Streamer \($0)", category: category) },
                                      onSelect: { _ in }, onSeeAll: {})
                .environment(\.dynamicTypeSize, typeSize))
            XCTAssertEqual(reservedHeight, loaded.sizeThatFits(in: proposal).height, accuracy: 1,
                           "Reserve only \(count) shortcuts at \(width), \(typeSize), category '\(category)'")
          }
          heights[count] = reservedHeight
        }
        XCTAssertLessThan(heights[0]!, heights[6]!)
        XCTAssertLessThan(heights[2]!, heights[6]!, "Two live follows must not keep three rows")
        if !typeSize.isAccessibilitySize {
          XCTAssertEqual(heights[1]!, heights[2]!, accuracy: 1)
          XCTAssertEqual(heights[3]!, heights[4]!, accuracy: 1)
          XCTAssertEqual(heights[5]!, heights[6]!, accuracy: 1)
        }
      }
    }
  }

  func testRestoringAccountReservesShortcutSpaceBeforeAuthentication() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    var feedTop: CGFloat?
    func content(authenticated: Bool, restoring: Bool, loading: Bool, channels: [FollowedChannel],
                 skeletonCount: Int = 2) -> some View {
      VStack(alignment: .leading, spacing: 16) {
        MobileFollowedShortcuts(channels: channels, onSelect: { _ in }, onSeeAll: {},
                                isLoading: loading, authenticated: authenticated, isRestoringAccount: restoring,
                                skeletonCount: skeletonCount)
          .padding(.horizontal)
        Text("For you").font(.title3.bold())
          .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("followed-reservation")).minY } action: {
            feedTop = $0
          }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .coordinateSpace(name: "followed-reservation")
      .environment(\.themePalette, .light)
    }
    let controller = UIHostingController(rootView:
      content(authenticated: false, restoring: true, loading: false, channels: []))
    window.rootViewController = controller
    func layout() async throws {
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      controller.view.layoutIfNeeded()
    }
    try await layout()
    let reservedTop = try XCTUnwrap(feedTop)
    XCTAssertGreaterThan(reservedTop, 44, "Reserve the remembered compact row before authentication is known")
    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "For you followed shortcuts during account restoration"
    attachment.lifetime = .keepAlways
    add(attachment)

    controller.rootView = content(authenticated: true, restoring: false, loading: true, channels: [])
    try await layout()
    XCTAssertEqual(try XCTUnwrap(feedTop), reservedTop, accuracy: 1)
    for count in [1, 2] {
      controller.rootView = content(authenticated: true, restoring: false, loading: false,
        channels: (0..<count).map { channel("Streamer \($0)", category: "") })
      try await layout()
      XCTAssertEqual(try XCTUnwrap(feedTop), reservedTop, accuracy: 1, "Loaded follows must not move the feed")
    }
    controller.rootView = content(authenticated: true, restoring: false, loading: true,
      channels: [channel("Still live"), channel("Another")], skeletonCount: 6)
    try await layout()
    XCTAssertEqual(try XCTUnwrap(feedTop), reservedTop, accuracy: 1, "Refreshes retain existing cards, not skeletons")
    controller.rootView = content(authenticated: true, restoring: false, loading: false,
      channels: (0..<6).map { channel("Streamer \($0)") })
    try await layout()
    XCTAssertGreaterThan(try XCTUnwrap(feedTop), reservedTop + 80, "More live follows expand the section")
    controller.rootView = content(authenticated: true, restoring: false, loading: false, channels: [])
    try await layout()
    XCTAssertLessThan(try XCTUnwrap(feedTop), reservedTop + 1, "No live follows use only a compact empty state")
    controller.rootView = content(authenticated: false, restoring: false, loading: false, channels: [])
    try await layout()
    XCTAssertEqual(try XCTUnwrap(feedTop), 0, accuracy: 1, "Signed-out users must not retain an empty section")
  }

  func testShortcutCountIsAccountScopedAndRemembersOnlySuccessfulLiveResults() throws {
    let suite = "Strozz-follow-count-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(MobileFollowedShortcutCount.cached(for: nil, defaults: defaults), 6)
    XCTAssertEqual(MobileFollowedShortcutCount.cached(for: "first", defaults: defaults), 6)
    let follows = [channel("First"), channel("Second"), channel("Offline", live: false)]
    XCTAssertEqual(MobileFollowedShortcutCount.remember(follows, for: "first", isDemo: false,
      errorMessage: nil, defaults: defaults), 2)
    XCTAssertEqual(MobileFollowedShortcutCount.cached(for: "first", defaults: defaults), 2)
    XCTAssertEqual(MobileFollowedShortcutCount.cached(for: "second", defaults: defaults), 6)
    XCTAssertNil(MobileFollowedShortcutCount.remember([], for: "first", isDemo: false,
      errorMessage: "Network unavailable", defaults: defaults))
    XCTAssertNil(MobileFollowedShortcutCount.remember(LoadingSkeleton.channels, for: "first", isDemo: true,
      errorMessage: nil, defaults: defaults))
    XCTAssertNil(MobileFollowedShortcutCount.remember([], for: nil, isDemo: false,
      errorMessage: nil, defaults: defaults))
    XCTAssertEqual(MobileFollowedShortcutCount.cached(for: "first", defaults: defaults), 2)
    XCTAssertEqual(MobileFollowedShortcutCount.remember(LoadingSkeleton.channels, for: "second", isDemo: false,
      errorMessage: nil, defaults: defaults), 6)
    XCTAssertEqual(MobileFollowedShortcutCount.remember([], for: "first", isDemo: false,
      errorMessage: nil, defaults: defaults), 0)
    let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
    XCTAssertEqual(MobileFollowedShortcutCount.cached(for: "first", defaults: reopened), 0)
    XCTAssertEqual(MobileFollowedShortcutCount.cached(for: "second", defaults: reopened), 6)
    let filtered = MobileHomeFeed.visibleFollows(follows, authenticated: true, isDemo: false,
      category: TwitchCategory(id: "empty", name: "Minecraft", boxArtURL: nil, viewerCount: nil))
    XCTAssertTrue(filtered.isEmpty)
    XCTAssertEqual(MobileFollowedShortcutCount.remember(follows, for: "first", isDemo: false,
      errorMessage: nil, defaults: defaults), 2, "Cache the unfiltered live count, not a category result")
  }

  func testShortcutAnimationKeyOnlyChangesWhenRowsChange() {
    func rows(_ visible: Int, loading: Bool = false, cached: Int = 6, accessible: Bool = false) -> Int {
      MobileFollowedShortcutCount.rows(visibleCount: visible, isLoading: loading,
                                      cachedCount: cached, accessibilitySize: accessible)
    }
    XCTAssertEqual(rows(0, loading: true, cached: 2), 1)
    XCTAssertEqual(rows(0, loading: true, cached: 0), 0)
    XCTAssertEqual(rows(0), 0)
    XCTAssertEqual(rows(1), rows(2))
    XCTAssertEqual(rows(3), rows(4))
    XCTAssertEqual(rows(5), rows(6))
    XCTAssertEqual(rows(150), 3)
    XCTAssertEqual(rows(2, loading: true), 1, "Refreshing must not reset a loaded section to six slots")
    XCTAssertEqual(rows(2, accessible: true), 2)
    XCTAssertEqual(rows(6, accessible: true), 6)
  }

  func testOptInShortcutResizingKeepsMiniPlayerFramesAndUIResponsive() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_PIP_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Enable live playback checks to measure shortcut resizing with the mini-player.")
    }
    let browse = BrowseService()
    await browse.loadCategories()
    await browse.loadStreams(for: try XCTUnwrap(browse.categories.first))
    let stream = try XCTUnwrap(browse.categoryStreams.first)
    let session = MobilePlaybackSession()
    let state = ShortcutResizeState()
    let marker = UIView()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let host = UIHostingController(rootView: ShortcutResizeFixture(state: state, session: session, marker: marker))
    window.rootViewController = host
    defer { session.close(); window.rootViewController = previous }
    session.select(stream)
    for _ in 0..<450 {
      if session.model.isReadyForDisplay && session.model.player.timeControlStatus == .playing { break }
      if let error = session.model.errorMessage { XCTFail(error); throw URLError(.cannotLoadFromNetwork) }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(session.model.isReadyForDisplay)
    session.collapse()
    try await Task.sleep(for: .seconds(1))
    let player = session.model.player
    let surface = session.videoController
    let item = try XCTUnwrap(player.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(output)
    defer { item.remove(output) }
    let sampler = ShortcutFrameSampler(marker: marker, window: window)
    let link = CADisplayLink(target: sampler, selector: #selector(ShortcutFrameSampler.tick(_:)))
    link.add(to: .main, forMode: .common)
    defer { link.invalidate() }
    try await Task.sleep(for: .seconds(2))
    let baseline = sampler.intervals
    XCTAssertGreaterThan(baseline.count, 20)
    sampler.intervals = []
    sampler.positions = []
    let started = player.currentTime().seconds
    var decodedSamples = 0
    var startPositions: [CGFloat] = []
    var endPositions: [CGFloat] = []
    for count in [2, 6, 0, 6, 2, 6] {
      startPositions.append(sampler.position)
      state.channels = Array(LoadingSkeleton.channels.prefix(count))
      for _ in 0..<5 {
        try await Task.sleep(for: .milliseconds(100))
        let time = player.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time),
           output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { decodedSamples += 1 }
      }
      endPositions.append(sampler.position)
      XCTAssertTrue(session.model.player === player)
      XCTAssertTrue(session.videoController === surface)
    }
    let animated = sampler.intervals
    XCTAssertGreaterThan(player.currentTime().seconds - started, 2.5)
    XCTAssertGreaterThanOrEqual(decodedSamples, 26, "Resizing must not starve decoded mini-player frames")
    XCTAssertLessThan(endPositions[0], startPositions[0] - 80)
    XCTAssertGreaterThan(endPositions[1], startPositions[1] + 80)
    XCTAssertTrue(sampler.positions.contains { $0 > endPositions[0] + 5 && $0 < startPositions[0] - 5 },
                  "The following feed must pass through intermediate positions, not teleport")
    func percentile95(_ values: [Double]) throws -> Double {
      let sorted = values.sorted()
      return try XCTUnwrap(sorted.isEmpty ? nil : sorted[min(sorted.count - 1, sorted.count * 95 / 100)])
    }
    let baseline95 = try percentile95(baseline)
    let animated95 = try percentile95(animated)
    XCTAssertLessThanOrEqual(animated95, max(0.05, baseline95 * 1.75),
                            "Row resizing must not materially reduce UI responsiveness")
    XCTAssertLessThan(try XCTUnwrap(animated.max()), max(0.25, (baseline.max() ?? 0) + 0.10))
    let evidence = XCTAttachment(string:
      "baseline95=\(baseline95), resizing95=\(animated95), maxGap=\(animated.max() ?? 0), "
        + "decoded=\(decodedSamples)/30, feedStart=\(startPositions), feedEnd=\(endPositions)")
    evidence.name = "Adaptive shortcuts with live mini-player"
    evidence.lifetime = .keepAlways
    add(evidence)
    XCTAssertNil(session.model.errorMessage)
  }

  func testCategoryAndFollowingSkeletonsReserveMetadataLines() {
    let proposal = CGSize(width: 356, height: UIView.layoutFittingExpandedSize.height)
    let loading = UIHostingController(rootView: MobileFollowingRow(channel: LoadingSkeleton.channels[0]))
    for live in [false, true] {
      let loaded = UIHostingController(rootView: MobileFollowingRow(channel: channel("Streamer", live: live)))
      XCTAssertEqual(loading.sizeThatFits(in: proposal).height, loaded.sizeThatFits(in: proposal).height, accuracy: 1)
    }

    let categoryProposal = CGSize(width: 110, height: UIView.layoutFittingExpandedSize.height)
    let categoryLoading = UIHostingController(rootView: MobileCategoryCard(category: LoadingSkeleton.categories[0]))
    for viewers in [nil, 1200] as [Int?] {
      let category = TwitchCategory(id: "test", name: "Game", boxArtURL: nil, viewerCount: viewers)
      let loaded = UIHostingController(rootView: MobileCategoryCard(category: category))
      XCTAssertEqual(categoryLoading.sizeThatFits(in: categoryProposal).height,
                     loaded.sizeThatFits(in: categoryProposal).height, accuracy: 1)
    }
  }

  private func channel(_ name: String, category: String = "Just Chatting", live: Bool = true) -> FollowedChannel {
    FollowedChannel(id: name, login: name.lowercased(), displayName: name,
                    title: "A live stream with a longer title", gameName: category, viewerCount: 7500,
                    thumbnailURL: nil, profileImageURL: nil, isLive: live)
  }

  func testLiveHomeFollowsNeverIncludeAnonymousDemoOrOfflineChannels() {
    let channels = [channel("Live"), channel("Offline", live: false)]
    XCTAssertTrue(MobileHomeFeed.visibleFollows(channels, authenticated: false, isDemo: false, category: nil).isEmpty)
    XCTAssertTrue(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: true, category: nil).isEmpty)
    XCTAssertEqual(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: false, category: nil).map(\.login), ["live"])
  }

  func testFollowingDirectoryIncludesOfflineChannelsWithoutAListLimit() {
    let channels = (0..<150).map { channel("Follow\($0)", live: $0.isMultiple(of: 2)) }
    let result = MobileHomeFeed.directory(channels, authenticated: true, category: nil)
    XCTAssertEqual(result.count, 150)
    XCTAssertEqual(result.filter { !$0.isLive }.count, 75)
    XCTAssertTrue(MobileHomeFeed.directory(channels, authenticated: false, category: nil).isEmpty)
  }

  func testHomePrioritizesMostWatchedAndFollowsBeforeDiscoveryWithoutDuplicates() {
    let date = Date(timeIntervalSince1970: 100)
    let history = [
      WatchHistoryEntry(login: "favorite", displayName: "Favorite", gameName: "Chat", viewerCount: nil,
                        lastWatchedAt: date, watchCount: 10),
      WatchHistoryEntry(login: "visited", displayName: "Visited", gameName: "Chat", viewerCount: nil,
                        lastWatchedAt: date, watchCount: 4)
    ]
    let result = MobileHomeFeed.homeChannels(
      follows: [channel("Follow"), channel("Favorite"), channel("Offline", live: false)],
      watched: [channel("Visited"), channel("FAVORITE")],
      recommendations: [channel("Discovery"), channel("Favorite")], history: history, category: nil)
    XCTAssertEqual(result.map(\.channelKey), ["favorite", "visited", "follow", "discovery"])
  }

  func testPersonalHomeCategoryFilterDoesNotReplaceFollowsWithGlobalPopularStreams() {
    let category = TwitchCategory(id: "minecraft", name: "Minecraft", boxArtURL: nil, viewerCount: nil)
    let result = MobileHomeFeed.homeChannels(
      follows: [channel("Mine", category: "MINECRAFT"), channel("Chat")],
      watched: [], recommendations: [channel("Suggested", category: "Minecraft")], history: [], category: category)
    XCTAssertEqual(result.map(\.login), ["mine", "suggested"])
    let offline = MobileHomeFeed.directory([channel("Offline", category: "Minecraft", live: false)],
                                          authenticated: true, category: category)
    XCTAssertEqual(offline.map(\.login), ["offline"])
  }

  func testMobileHistoryScopesDoNotReadOtherAccountsOrTheTVHistory() throws {
    let suffix = UUID().uuidString
    let firstKey = PersistenceKey.mobileWatchHistory(accountID: "first-\(suffix)")
    let secondKey = PersistenceKey.mobileWatchHistory(accountID: "second-\(suffix)")
    let entries = [WatchHistoryEntry(login: "favorite", displayName: "Favorite", gameName: "Game",
      viewerCount: nil, lastWatchedAt: Date(), watchCount: 8)]
    Defaults.save(entries, forKey: firstKey)
    defer { UserDefaults.standard.removeObject(forKey: firstKey) }
    XCTAssertEqual(WatchHistoryService(storageKey: firstKey).entries.first?.watchCount, 8)
    XCTAssertTrue(WatchHistoryService(storageKey: secondKey).entries.isEmpty)
    XCTAssertNotEqual(firstKey, PersistenceKey.watchHistoryEntries)
  }

  func testFollowingCategoryFilterUsesActualLiveFollows() {
    let category = TwitchCategory(id: "chat", name: "Just Chatting", boxArtURL: nil, viewerCount: nil)
    let channels = [channel("Chat", category: "JUST CHATTING"), channel("Game", category: "Minecraft")]
    XCTAssertEqual(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: false, category: category).map(\.login), ["chat"])
  }

  func testSignedInHomeComponentsRenderWithoutAccountOrNetworkAccess() async throws {
    let channels = ["Ludwig", "xQc", "Valkyrae", "Extra", "Another", "Last"].map { channel($0) }
      + [channel("Offline channel", live: false)]
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    for theme in [AppTheme.light, .dark] {
      let content = ScrollView {
        VStack(spacing: 20) {
          MobileFollowedShortcuts(channels: channels, onSelect: { _ in }, onSeeAll: {})
          MobileFollowingContent(authenticated: true, channels: channels,
                                 isLoading: false, errorMessage: nil, filtered: false,
                                 onAccount: {}, onRetry: {}, onSelect: { _ in })
        }
        .padding()
      }
      .background(theme.palette(systemColorScheme: .light).chatSideSurface)
      .environment(\.themePalette, theme.palette(systemColorScheme: .light))
      .preferredColorScheme(theme.preferredColorScheme)
      let controller = UIHostingController(rootView: content)
      window.rootViewController = controller
      controller.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
        controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = "signed-in-components-\(theme.rawValue)"
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertGreaterThan(controller.view.bounds.width, 0)
    }
  }

  func testRestoringFollowingUsesNeutralPlaceholder() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let content = MobileFollowingContent(authenticated: false, isRestoringAccount: true,
      channels: [], isLoading: false, errorMessage: nil, filtered: false,
      onAccount: { XCTFail("Account restoration must not offer sign-in") }, onRetry: {}, onSelect: { _ in })
      .padding()
    let controller = UIHostingController(rootView: content)
    window.rootViewController = controller
    controller.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "Following account restoration"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

@MainActor
@Observable
private final class ShortcutResizeState {
  var channels = Array(LoadingSkeleton.channels.prefix(6))
}

private struct ShortcutResizeFixture: View {
  let state: ShortcutResizeState
  let session: MobilePlaybackSession
  let marker: UIView
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var auth = TwitchAuthSession()
  @State private var theme = ThemeManager()
  @State private var rewards = TwitchWatchRewardsSession()

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        MobileFollowedShortcuts(channels: state.channels, onSelect: { _ in }, onSeeAll: {})
        ShortcutPositionMarker(view: marker).frame(height: 1)
        Text("For you").font(.title3.bold())
        ForEach(LoadingSkeleton.channels) { MobileChannelCard(channel: $0) }
      }
      .animation(.easeInOut(duration: 0.22), value: MobileFollowedShortcutCount.rows(
        visibleCount: state.channels.count, isLoading: false, cachedCount: 6,
        accessibilitySize: typeSize.isAccessibilitySize))
      .padding()
    }
    .overlay {
      if let channel = session.channel { MobilePlayerView(channel: channel, session: session) }
    }
    .environment(auth).environment(theme).environment(rewards)
    .environment(\.themePalette, .light)
  }
}

private struct ShortcutPositionMarker: UIViewRepresentable {
  let view: UIView
  func makeUIView(context: Context) -> UIView { view }
  func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
private final class ShortcutFrameSampler: NSObject {
  let marker: UIView
  let window: UIWindow
  var intervals: [Double] = []
  var positions: [CGFloat] = []
  private var previous: CFTimeInterval?

  init(marker: UIView, window: UIWindow) {
    self.marker = marker
    self.window = window
  }

  var position: CGFloat {
    let layer = marker.layer.presentation() ?? marker.layer
    return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer).minY
  }

  @objc func tick(_ link: CADisplayLink) {
    if let previous { intervals.append(link.timestamp - previous) }
    previous = link.timestamp
    positions.append(position)
  }
}

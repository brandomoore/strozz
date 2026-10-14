#if DEBUG
import SwiftUI

struct MobileNavigationLayoutFixture: View {
  @State private var selection = 0
  @State private var visibility = NavigationSplitViewVisibility.all
  @State private var compactColumn = NavigationSplitViewColumn.detail
  @State private var narrow = false
  @State private var session: MobilePlaybackSession?
  @State private var auth = TwitchAuthSession()
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var sizeClass
  private let theme = ProcessInfo.processInfo.environment["STROZZ_NAVIGATION_THEME"]
    .flatMap { AppTheme(rawValue: $0.lowercased()) } ?? .dark
  private let accessible = ProcessInfo.processInfo.environment["STROZZ_NAVIGATION_ACCESSIBLE"] == "1"
  private let state = ProcessInfo.processInfo.environment["STROZZ_NAVIGATION_FOLLOWS_STATE"] ?? "loaded"

  private let channels = (0..<12).map { index in
    FollowedChannel(id: "navigation-\(index)", login: "navigation\(index)",
      displayName: "Streamer \(index + 1)", title: "An evening stream with friends",
      gameName: index.isMultiple(of: 2) ? "Just Chatting" : "Minecraft",
      viewerCount: 1200 + index * 700, thumbnailURL: nil, profileImageURL: nil, isLive: true)
  }

  var body: some View {
    GeometryReader { geometry in
      let tablet = UIDevice.current.userInterfaceIdiom == .pad
      let sidebar = tablet && !narrow && sizeClass == .regular && visibility != .detailOnly
      MobileNavigationFixtureTabs(selection: $selection, visibility: $visibility, compactColumn: $compactColumn,
        isTablet: tablet, isInteractive: session?.isExpanded != true,
        sidebar: sidebar, state: state, channels: channels, onSelect: select)
      .allowsHitTesting(session?.isExpanded != true)
      .accessibilityHidden(session?.isExpanded == true)
      .overlay {
        if let session, let channel = session.channel {
          MobilePlayerView(channel: channel, session: session)
            .id(ObjectIdentifier(session.model))
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if session?.isExpanded != true, tablet {
          Button(narrow ? "Use wide window" : "Use narrow window") { narrow.toggle() }
            .buttonStyle(.bordered)
            .padding()
            .accessibilityIdentifier("fixture-toggle-window")
        }
      }
      .frame(width: narrow ? min(480, geometry.size.width) : geometry.size.width)
      .environment(\.horizontalSizeClass, narrow ? .compact : sizeClass)
      .onChange(of: selection) { _, _ in compactColumn = .detail }
      .onChange(of: session?.isExpanded) { _, expanded in
        if expanded == false { compactColumn = .detail }
      }
    }
    .environment(auth)
    .environment(\.themePalette, theme.palette(systemColorScheme: colorScheme))
    .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large)
    .transaction { if accessible { $0.disablesAnimations = true } }
    .preferredColorScheme(theme.preferredColorScheme)
    .overlay(alignment: .bottomLeading) {
      Color.clear.frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityIdentifier("fixture-navigation-theme")
        .accessibilityValue(theme.rawValue)
        .allowsHitTesting(false)
    }
    .onDisappear { session?.close() }
  }

  private func select(_ channel: FollowedChannel) {
    session?.close()
    session = MobilePlaybackSession.layoutFixture(channel: channel)
  }
}

private struct MobileNavigationFixtureTabs: View {
  @Binding var selection: Int
  @Binding var visibility: NavigationSplitViewVisibility
  @Binding var compactColumn: NavigationSplitViewColumn
  let isTablet: Bool
  let isInteractive: Bool
  let sidebar: Bool
  let state: String
  let channels: [FollowedChannel]
  let onSelect: (FollowedChannel) -> Void

  var body: some View {
    let sidebarContent = MobileBrowsingSidebar(selection: $selection, channels: state == "empty" ? [] : channels,
      authenticated: state != "signed-out", restoring: state == "restoring", loading: state == "restoring",
      errorMessage: state == "failed" ? "Could not refresh followed channels. Try again." : nil,
      onSelect: onSelect, onRetry: {})
    TabView(selection: $selection) {
      MobileAdaptiveNavigation(isTablet: isTablet, isInteractive: isInteractive,
        visibility: $visibility, compactColumn: $compactColumn) {
        sidebarContent
      } detail: {
        NavigationStack {
          ScrollView { MobileChannelGrid(channels: channels, onSelect: onSelect).padding() }
            .navigationTitle("Home").navigationBarTitleDisplayMode(.inline)
            .toolbar(sidebar ? .hidden : .visible, for: .tabBar)
        }
      }
      .tabItem { Label { Text("Home") } icon: { Image("tb-home") } }.tag(0)
      MobileAdaptiveNavigation(isTablet: isTablet, isInteractive: isInteractive,
        visibility: $visibility, compactColumn: $compactColumn) {
        sidebarContent
      } detail: {
        NavigationStack {
          Text("Browse content").frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Browse").navigationBarTitleDisplayMode(.inline)
            .toolbar(sidebar ? .hidden : .visible, for: .tabBar)
        }
      }
      .tabItem { Label { Text("Browse") } icon: { Image("tb-layout-grid") } }.tag(1)
      MobileAdaptiveNavigation(isTablet: isTablet, isInteractive: isInteractive,
        visibility: $visibility, compactColumn: $compactColumn) {
        sidebarContent
      } detail: {
        NavigationStack {
          Text("Account content").frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
            .toolbar(sidebar ? .hidden : .visible, for: .tabBar)
        }
      }
      .tabItem { Label { Text("Account") } icon: { Image("tb-user-circle") } }.tag(2)
    }
    .toolbar(sidebar ? .hidden : .visible, for: .tabBar)
  }
}
#endif

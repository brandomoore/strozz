import SwiftUI

struct MobileAdaptiveNavigation<Sidebar: View, Detail: View>: View {
  let isTablet: Bool
  let isInteractive: Bool
  @Binding var visibility: NavigationSplitViewVisibility
  @Binding var compactColumn: NavigationSplitViewColumn
  let sidebar: Sidebar
  let detail: Detail

  init(isTablet: Bool, isInteractive: Bool = true, visibility: Binding<NavigationSplitViewVisibility>,
       compactColumn: Binding<NavigationSplitViewColumn>,
       @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
    self.isTablet = isTablet
    self.isInteractive = isInteractive
    _visibility = visibility
    _compactColumn = compactColumn
    self.sidebar = sidebar()
    self.detail = detail()
  }

  var body: some View {
    if isTablet {
      NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
        sidebar
          .disabled(!isInteractive)
          .allowsHitTesting(isInteractive)
          .accessibilityHidden(!isInteractive)
          .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 340)
      } detail: {
        detail
          .disabled(!isInteractive)
          .allowsHitTesting(isInteractive)
          .accessibilityHidden(!isInteractive)
      }
      .navigationSplitViewStyle(.balanced)
    } else {
      detail
    }
  }
}

struct MobileRootSidebar: View {
  let follows: FollowedChannelsService
  @Binding var selection: Int
  let onSelect: (FollowedChannel) -> Void
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(TwitchAccountSync.self) private var sync

  var body: some View {
    MobileBrowsingSidebar(
      selection: $selection,
      channels: MobileHomeFeed.visibleFollows(follows.channels, authenticated: auth.isAuthenticated,
        isDemo: follows.isUsingDemoData, category: nil),
      authenticated: auth.isAuthenticated, restoring: sync.isRestoringAccount,
      loading: follows.isLoading || (follows.lastUpdatedAt == nil && follows.errorMessage == nil),
      errorMessage: follows.errorMessage, onSelect: onSelect,
      onRetry: { Task { if !follows.isRefreshing { await follows.refresh(using: auth) } } })
      .refreshable {
        if auth.isAuthenticated, !follows.isRefreshing { await follows.refresh(using: auth) }
      }
  }
}

struct MobileBrowsingSidebar: View {
  @Binding var selection: Int
  let channels: [FollowedChannel]
  let authenticated: Bool
  let restoring: Bool
  let loading: Bool
  let errorMessage: String?
  let onSelect: (FollowedChannel) -> Void
  let onRetry: () -> Void
  @Environment(\.themePalette) private var palette
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    // These controls switch independent tabs, not the split view's detail item.
    List {
      Section {
        Button { selection = 0 } label: {
          Label { Text("Home") } icon: { Icon(glyph: .home, size: 22) }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .listRowBackground(selection == 0 ? palette.chromeOnOpaque.opacity(0.10) : .clear)
        .accessibilityAddTraits(selection == 0 ? .isSelected : [])
        .accessibilityIdentifier("sidebar-home")
        .accessibilityHidden(!isEnabled)
        Button { selection = 1 } label: {
          Label { Text("Browse") } icon: { Icon(glyph: .layoutGrid, size: 22) }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .listRowBackground(selection == 1 ? palette.chromeOnOpaque.opacity(0.10) : .clear)
        .accessibilityAddTraits(selection == 1 ? .isSelected : [])
        .accessibilityIdentifier("sidebar-browse")
        .accessibilityHidden(!isEnabled)
        Button { selection = 2 } label: {
          Label { Text("Account") } icon: { Icon(glyph: .userCircle, size: 22) }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .listRowBackground(selection == 2 ? palette.chromeOnOpaque.opacity(0.10) : .clear)
        .accessibilityAddTraits(selection == 2 ? .isSelected : [])
        .accessibilityIdentifier("sidebar-account")
        .accessibilityHidden(!isEnabled)
      }
      Section("Live followed channels") {
        if restoring {
          ProgressView("Loading followed channels")
            .frame(minHeight: 44)
            .accessibilityIdentifier("sidebar-follows-loading")
        } else if !authenticated {
          Text("Sign in to see the channels you follow.").foregroundStyle(.secondary)
          Button("Sign in to Twitch") { selection = 2 }
            .frame(minHeight: 44)
            .accessibilityIdentifier("sidebar-sign-in")
        } else {
          if let errorMessage {
            Text(errorMessage).font(.callout).foregroundStyle(.secondary)
            Button("Try again", action: onRetry)
              .frame(minHeight: 44)
              .accessibilityIdentifier("sidebar-follows-retry")
          }
          if channels.isEmpty, loading {
            ProgressView("Loading followed channels")
              .frame(minHeight: 44)
              .accessibilityIdentifier("sidebar-follows-loading")
          } else if channels.isEmpty, errorMessage == nil {
            Text("No followed channels are live right now.").foregroundStyle(.secondary)
              .accessibilityIdentifier("sidebar-follows-empty")
          }
          ForEach(channels, id: \.channelKey) { channel in
            Button { onSelect(channel) } label: {
              MobileSidebarChannelRow(name: channel.displayName, category: channel.gameName,
                title: channel.title, viewers: channel.viewerCount, avatarURL: channel.profileImageURL)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-stream-\(channel.channelKey)")
            .accessibilityHidden(!isEnabled)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(palette.cardOpaqueSurface)
    .navigationTitle("Strozz")
    .accessibilityIdentifier("mobile-browsing-sidebar")
  }
}

struct MobileSidebarChannelRow: View {
  let name: String
  let category: String
  let title: String
  let viewers: Int?
  let avatarURL: URL?
  @Environment(\.themePalette) private var palette
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      CachedAsyncImage(url: avatarURL) { image in
        image.resizable().scaledToFill()
      } placeholder: { Circle().fill(.quaternary) }
      .frame(width: avatarSize, height: avatarSize)
      .clipShape(Circle())
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(name).font(.body.weight(.semibold))
          .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        if !category.isEmpty {
          Text(category).font(.caption).foregroundStyle(.secondary)
            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        }
        if !title.isEmpty {
          Text(title).font(.caption).foregroundStyle(.secondary)
            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        }
        HStack(spacing: 5) {
          Circle().fill(palette.liveIndicator).frame(width: 6, height: 6).accessibilityHidden(true)
          if let viewers {
            Text(viewers, format: .number.notation(.compactName))
              .accessibilityLabel("\(viewers) viewers")
          } else {
            Text("Live")
          }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityHint("Open stream")
  }
}

struct MobileRootTabs: View {
  @Binding var selection: Int
  @Binding var homeProfile: FollowedChannel?
  @Binding var browseProfile: FollowedChannel?
  @Binding var sidebarVisibility: NavigationSplitViewVisibility
  @Binding var compactColumn: NavigationSplitViewColumn
  let preview: MobileHomePreview
  let previewsEnabled: Bool
  let history: WatchHistoryService
  let follows: FollowedChannelsService
  let isTablet: Bool
  let showsSidebar: Bool
  let isInteractive: Bool
  let onSelect: (FollowedChannel) -> Void

  var body: some View {
    let sidebar = MobileRootSidebar(follows: follows, selection: $selection, onSelect: onSelect)
    TabView(selection: $selection) {
      MobileAdaptiveNavigation(isTablet: isTablet, isInteractive: isInteractive,
        visibility: $sidebarVisibility, compactColumn: $compactColumn) {
        sidebar
      } detail: {
        NavigationStack {
          MobileHomeView(preview: preview, previewsEnabled: previewsEnabled, history: history,
            follows: follows, usesTabletNavigation: isTablet, showsFollowedShortcuts: !showsSidebar,
            onSelect: onSelect, onProfile: { homeProfile = $0 }, onAccount: { selection = 2 })
            .navigationDestination(item: $homeProfile) { MobileChannelProfileView(channel: $0, onLive: onSelect) }
            .toolbar(showsSidebar ? .hidden : .visible, for: .tabBar)
        }
      }
      .tabItem { Label { Text("Home") } icon: { Image("tb-home") } }
      .tag(0)

      MobileAdaptiveNavigation(isTablet: isTablet, isInteractive: isInteractive,
        visibility: $sidebarVisibility, compactColumn: $compactColumn) {
        sidebar
      } detail: {
        NavigationStack {
          MobileBrowseView(onSelect: onSelect)
            .navigationDestination(item: $browseProfile) { MobileChannelProfileView(channel: $0, onLive: onSelect) }
            .toolbar(showsSidebar ? .hidden : .visible, for: .tabBar)
        }
      }
      .tabItem { Label { Text("Browse") } icon: { Image("tb-layout-grid") } }
      .tag(1)

      MobileAdaptiveNavigation(isTablet: isTablet, isInteractive: isInteractive,
        visibility: $sidebarVisibility, compactColumn: $compactColumn) {
        sidebar
      } detail: {
        NavigationStack {
          MobileAccountView().toolbar(showsSidebar ? .hidden : .visible, for: .tabBar)
        }
      }
        .tabItem { Label { Text("Account") } icon: { Image("tb-user-circle") } }
        .tag(2)
    }
    .toolbar(showsSidebar ? .hidden : .visible, for: .tabBar)
  }
}

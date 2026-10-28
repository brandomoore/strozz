#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct MultiviewStatusFixture: View {
  @State private var controller = MultiviewController(channels: [
    FollowedChannel(id: "status-fixture", login: "statusfixture", displayName: "Fixture Stream",
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
  ])
  @State private var retries = 0
  @State private var profileRequests = 0
  @State private var removals = 0
  @State private var chrome = MultiviewChrome()
  @FocusState private var focused: Bool
  @FocusState private var actionFocus: MultiviewFocusTarget?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let settings = ProcessInfo.processInfo.environment
    let theme = AppTheme(rawValue: settings["STROZZ_MULTIVIEW_STATUS_THEME"] ?? "dark") ?? .dark
    let palette = theme.palette(systemColorScheme: scheme)
    let compact = settings["STROZZ_MULTIVIEW_STATUS_COMPACT"] == "1"
    let pane = controller.panes[0]
    VStack(spacing: 40) {
      ZStack {
        if settings["STROZZ_MULTIVIEW_STATUS_LIVE"] == "1" { Color.red }
        else { palette.videoControlScrim }
        MultiviewPaneTile(pane: pane, isFocused: focused, isPrimary: false, showsMetadata: false,
          showsChrome: chrome.isVisible,
          style: compact ? .compact : .full, palette: palette,
          glassDisabled: settings["STROZZ_MULTIVIEW_STATUS_OPAQUE"] == "1")
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        MultiviewPaneButton {
          if pane.hasError { controller.load(pane); retries += 1 }
        }
        .padding(.bottom, pane.model.isOffline
          ? MultiviewOfflineActions.reservedHeight(for: compact ? .compact : .full) : 0)
        .focused($focused)
        .accessibilityIdentifier("multiview-status-pane")
        .accessibilityLabel(pane.channel.displayName)
        .accessibilityValue(Text(pane.accessibilityStatus(isTransitioning: false)))
        if pane.model.isOffline {
          MultiviewOfflineActions(style: compact ? .compact : .full,
            onProfile: { profileRequests += 1 }, onRemove: { removals += 1 },
            profileFocus: $actionFocus, paneID: pane.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(compact ? 8 : 20)
        }
      }
      .frame(width: compact ? 300 : 800, height: compact ? 169 : 450)
      Text("Retries: \(retries)")
        .accessibilityIdentifier("multiview-status-retries")
      Text("Profiles: \(profileRequests), removals: \(removals)")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.backgroundColors.last ?? palette.cardOpaqueSurface)
    .preferredColorScheme(theme.preferredColorScheme)
    .task {
      pane.model.isLoading = false
      pane.isAudible = true
      pane.model.isOffline = settings["STROZZ_MULTIVIEW_STATUS_LIVE"] != "1"
        && settings["STROZZ_MULTIVIEW_STATUS_FAILURE"] != "1"
      pane.model.errorMessage = settings["STROZZ_MULTIVIEW_STATUS_FAILURE"] == "1" ? "Synthetic load failure" : nil
      await Task.yield()
      focused = true
      chrome.reveal()
    }
    .onMoveCommand { _ in chrome.reveal() }
    .onChange(of: focused) { _, _ in chrome.reveal() }
    .onChange(of: actionFocus) { _, _ in chrome.reveal() }
    .onDisappear { chrome.cancel(); controller.teardown() }
  }
}

struct MultiviewSelectionFixture: View {
  private static let channels = (0...6).map { index in
    FollowedChannel(id: "selection-\(index)", login: "selection\(index)", displayName: "Stream \(index)",
      title: "Selection fixture", gameName: "", viewerCount: 20,
      thumbnailURL: nil, profileImageURL: nil, isLive: true)
  }
  @State private var ended = false

  private var sections: [MultiviewChannelSection] {
    [.init(id: "following", title: "Following",
      channels: ended ? Array(Self.channels.dropFirst()) : Self.channels)]
  }

  private var initialSelection: MultiviewSelection {
    var value = MultiviewSelection()
    for channel in Self.channels.prefix(6) {
      value.toggle(channel, in: [.init(id: "following", title: "Following", channels: Self.channels)])
    }
    return value
  }

  var body: some View {
    VStack {
      Button(ended ? "Restore stream" : "End selected stream") { ended.toggle() }
        .accessibilityIdentifier("multiview-fixture-toggle")
      MultiviewSetupView(sections: sections, onStart: { _ in }, onCancel: {},
        selection: initialSelection)
    }
    .task {
      let mode = ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SELECTION_TIMED"]
      guard mode == "offline" || mode == "recover" else { return }
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      ended = true
      if mode == "recover" {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        ended = false
      }
    }
  }
}

struct MultiviewBrowseFixture: View {
  @State private var lineup: MultiviewLineup = {
    let lineup = MultiviewLineup { _ in .live }
    if ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_BROWSE_FULL"] == "1" {
      for login in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"] {
        lineup.toggle(FollowedChannel(id: login, login: login, displayName: login.capitalized,
          title: "", gameName: "", viewerCount: nil, thumbnailURL: nil,
          profileImageURL: nil, isLive: true))
      }
    }
    return lineup
  }()
  @State private var selectedChannel: FollowedChannel?
  @State private var channelPageTarget: ChannelPageTarget?
  @State private var refresh = PlaybackReturnRefreshCoordinator()
  @State private var searching = false
  @State private var search = SearchService(loadData: { request in
    let data = Data(#"""
      {"data":{"searchFor":{"channels":{"edges":[
        {"item":{"id":"search-alpha","login":"alpha","displayName":"Alpha","stream":{"id":"live-alpha","title":"Alpha live"}}},
        {"item":{"id":"search-beta","login":"beta","displayName":"Beta","stream":{"id":"live-beta","title":"Beta live"}}}
      ]},"games":{"edges":[{"item":{"id":"category","name":"Example category"}}]}}}}
      """#.utf8)
    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }, loadKick: { _ in
    KickChannel(slug: "example", displayName: "Example", title: "Kick live", category: "",
      viewerCount: 20, isLive: true, chatroomID: nil, imageURL: nil)
  })
  @FocusState private var focus: String?
  @Namespace private var focusScope
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let settings = ProcessInfo.processInfo.environment
    let theme = AppTheme(rawValue: settings["STROZZ_MULTIVIEW_STATUS_THEME"] ?? "dark") ?? .dark
    let palette = theme.palette(systemColorScheme: scheme)
    Group {
      if searching {
        VStack(spacing: 24) {
          browseControls
          SearchView(selectedChannel: $selectedChannel, channelPageTarget: $channelPageTarget,
            service: search, initialQuery: "example")
        }
      } else {
        ScrollView {
          VStack(spacing: 24) {
            browseControls
            HStack(spacing: 24) {
              ForEach(["alpha", "beta", "gamma"], id: \.self) { login in
                StreamChannelCard(channel: .init(id: login, login: login,
                  displayName: login.capitalized, title: "\(login.capitalized) live", gameName: "",
                  viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true),
                  isFocused: focus == login,
                  onWatch: login == "alpha" ? nil : { selectedChannel = $0 },
                  onGoToChannel: login == "alpha" ? nil : { channelPageTarget = ChannelPageTarget(channel: $0) })
                  .frame(width: 460)
                  .focusable()
                  .focused($focus, equals: login)
                  .focusEffectDisabled()
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppLayout.horizontalPadding)
            .focusSection()
          }
        }
      }
    }
    .focusScope(focusScope)
    .background(AppBackground(palette: palette))
    .environment(refresh)
    .environment(\.multiviewLineup, lineup)
    .environment(\.themePalette, palette)
    .environment(\.glassDisabled, settings["STROZZ_MULTIVIEW_STATUS_OPAQUE"] == "1")
    .environment(\.streamPreviewsEnabled, false)
    .preferredColorScheme(theme.preferredColorScheme)
    .onChange(of: lineup.playbackRequest) { _, _ in lineup.startPlayback() }
    .fullScreenCover(isPresented: Binding(
      get: { lineup.isShowingPlayback },
      set: { if !$0 { lineup.browse() } }
    )) {
      if let controller = lineup.controller {
        VStack(spacing: 30) {
          Text("Fixture multiview")
          Text("\(controller.panes.count) streams")
          Button("Browse streams") { lineup.browse() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.cardOpaqueSurface)
        .onExitCommand { lineup.browse() }
      }
    }
  }

  private var browseControls: some View {
    HStack(spacing: 24) {
      Button("Browse") { searching = false }
        .focused($focus, equals: "browse")
        .prefersDefaultFocus(true, in: focusScope)
      Button("Search") { searching = true }
      Spacer()
      if !searching { MultiviewLineupButton() }
    }
    .frame(height: 76)
    .padding(.horizontal, AppLayout.horizontalPadding)
  }
}
#endif

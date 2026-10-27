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
#endif

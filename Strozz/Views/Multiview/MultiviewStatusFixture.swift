#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct MultiviewStatusFixture: View {
  @State private var controller = MultiviewController(channels: [
    FollowedChannel(id: "status-fixture", login: "statusfixture", displayName: "Fixture Stream",
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
  ])
  @State private var retries = 0
  @FocusState private var focused: Bool
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let settings = ProcessInfo.processInfo.environment
    let theme = AppTheme(rawValue: settings["STROZZ_MULTIVIEW_STATUS_THEME"] ?? "dark") ?? .dark
    let palette = theme.palette(systemColorScheme: scheme)
    let compact = settings["STROZZ_MULTIVIEW_STATUS_COMPACT"] == "1"
    let pane = controller.panes[0]
    VStack(spacing: 40) {
      ZStack {
        palette.videoControlScrim
        MultiviewPaneTile(pane: pane, isFocused: focused, isPrimary: false, showsMetadata: false,
          style: compact ? .compact : .full, palette: palette,
          glassDisabled: settings["STROZZ_MULTIVIEW_STATUS_OPAQUE"] == "1")
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        MultiviewPaneButton {
          if pane.hasError { controller.load(pane); retries += 1 }
        }
        .focused($focused)
        .accessibilityIdentifier("multiview-status-pane")
        .accessibilityLabel(pane.channel.displayName)
        .accessibilityValue(Text(pane.accessibilityStatus(isTransitioning: false)))
      }
      .frame(width: compact ? 300 : 800, height: compact ? 169 : 450)
      Text("Retries: \(retries)")
        .accessibilityIdentifier("multiview-status-retries")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.backgroundColors.last ?? palette.cardOpaqueSurface)
    .preferredColorScheme(theme.preferredColorScheme)
    .task {
      pane.model.isLoading = false
      pane.model.isOffline = settings["STROZZ_MULTIVIEW_STATUS_FAILURE"] != "1"
      pane.model.errorMessage = pane.model.isOffline ? nil : "Synthetic load failure"
      await Task.yield()
      focused = true
    }
    .onDisappear { controller.teardown() }
  }
}
#endif

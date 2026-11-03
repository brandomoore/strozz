#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Real remote arbitration and presentation bindings, without mounted network players.
struct MultiviewShortcutFixture: View {
  @Observable
  @MainActor
  final class Model {
    let identity = UUID().uuidString
    let lineup = MultiviewLineup { _ in .live }
    var requests = 0
    var shortCommands = 0
    var selection = "A"
    var contextActions = 0
    var hud = false
    var paused = false
    var dismissalChecks = 0
    var prompts = 0
    var hasPrompted = false
    var openingAtDismiss = false
    var visibleAtDismiss = false
    var requestsAtDismiss = 0
    var navigations = 0

    static func channel(_ login: String, live: Bool = true, platform: LivePlatform = .twitch) -> FollowedChannel {
      var channel = FollowedChannel(id: login, login: login, displayName: login,
        title: "Native card shortcut verification", gameName: "", viewerCount: nil,
        thumbnailURL: nil, profileImageURL: nil, isLive: live)
      channel.platform = platform
      return channel
    }

    let cards = [
      channel("Twitch"), channel("Kick", platform: .kick), channel("SelectedOffline", live: false),
      channel("Offline", live: false), channel("YouTube", platform: .youtube), channel("Extra"),
    ]

    init() {
      let count = Int(ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_COUNT"] ?? "2") ?? 2
      if ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_CARDS"] != nil {
        let seeds = [Self.channel("Twitch"), Self.channel("Kick", platform: .kick),
          Self.channel("SelectedOffline")] + (0..<3).map { Self.channel("Filler\($0)") }
        for channel in seeds.prefix(min(max(count, 0), 6)) { lineup.toggle(channel) }
        if count == 3 { lineup.observe(.offline, key: "selectedoffline") }
        return
      }
      for index in 0..<min(max(count, 0), 2) {
        lineup.toggle(FollowedChannel(id: "shortcut-\(index)", login: "shortcut\(index)",
          displayName: "Stream \(index)", title: "", gameName: "", viewerCount: nil,
          thumbnailURL: nil, profileImageURL: nil, isLive: true))
      }
    }

    func shortPress() {
      shortCommands += 1
      if lineup.isShowingPlayback {
        hud.toggle()
        paused.toggle()
      }
    }
  }

  @State private var model = Model()
  @State private var sheet = false
  @State private var cover = false
  @State private var directCover = false
  @State private var nested = false
  @State private var automaticPrompt = false
  @State private var query = "example"
  @State private var showingDirectory = false
  @State private var homeFrame = CGRect.zero
  @State private var homeScrollGeometry: [CGFloat] = []
  @FocusState private var focusedCard: String?
  @Namespace private var cardNamespace
  @Environment(\.colorScheme) private var scheme

  private var theme: AppTheme {
    AppTheme(rawValue: ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_THEME"] ?? "dark") ?? .dark
  }
  private var palette: ThemePalette { theme.palette(systemColorScheme: scheme) }
  private var opaque: Bool { ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_OPAQUE"] == "1" }
  private var automaticPromptEnabled: Bool {
    ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_AUTOPROMPT"] == "1"
  }
  private var cardMode: String? { ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_CARDS"] }

  private var isPresentingCover: Bool {
    sheet || cover || directCover || nested || automaticPrompt
      || model.lineup.isShowingPlayback || model.lineup.isOpeningPlayback
  }

  var body: some View {
    ZStack {
      browsingSurface
      .opacity(model.lineup.isShowingPlayback ? 0 : 1)
      .disabled(model.lineup.isShowingPlayback)
      .accessibilityHidden(model.lineup.isShowingPlayback)
      if let controller = model.lineup.controller {
        if cardMode != nil {
          MultiviewLayoutFixture(lineup: model.lineup)
            .opacity(model.lineup.isShowingPlayback ? 1 : 0)
            .disabled(!model.lineup.isShowingPlayback)
            .accessibilityHidden(!model.lineup.isShowingPlayback)
        } else {
          surface(controller.expandedPaneID == nil ? "wall" : "expanded") {
            Button("Expand first pane") { controller.expand(controller.panes[0].id) }
              .accessibilityIdentifier("shortcut-expand")
            Button("Browse") { model.lineup.browse() }.accessibilityIdentifier("shortcut-browse")
          }
          .opacity(model.lineup.isShowingPlayback ? 1 : 0)
          .disabled(!model.lineup.isShowingPlayback)
          .accessibilityHidden(!model.lineup.isShowingPlayback)
          .onExitCommand { model.lineup.browse() }
        }
      }
    }
    .environment(\.multiviewLineup, model.lineup)
    .environment(\.streamPreviewsEnabled, false)
    .environment(\.themePalette, palette)
    .environment(\.glassDisabled, opaque)
    .alert("Multiview", isPresented: Binding(
      get: { cardMode != nil && model.lineup.notice != nil },
      set: { if !$0 { model.lineup.notice = nil } }
    )) {
      Button("OK", role: .cancel) { model.lineup.notice = nil }
    } message: { Text(model.lineup.notice ?? "") }
    .background(MultiviewRemoteShortcut(lineup: model.lineup, palette: palette, glassDisabled: opaque))
    .onChange(of: model.lineup.playbackRequest) { _, _ in
      model.requests += 1
      model.lineup.startPlayback()
    }
    .sheet(isPresented: $sheet, onDismiss: promptAfterDismissalIfNeeded) {
      surface("sheet") {
        Button("Open nested cover") { cover = true }.accessibilityIdentifier("shortcut-open-nested-cover")
        selectionButtons
      }
      .fullScreenCover(isPresented: $cover, onDismiss: promptAfterDismissalIfNeeded) {
        surface("cover") {
          Button("Open nested sheet") { nested = true }.accessibilityIdentifier("shortcut-open-nested-sheet")
          selectionButtons
        }
        .sheet(isPresented: $nested, onDismiss: promptAfterDismissalIfNeeded) {
          surface("nested") { selectionButtons }
        }
      }
    }
    .fullScreenCover(isPresented: $directCover, onDismiss: promptAfterDismissalIfNeeded) {
      surface("cover") {
        selectionButtons
        if automaticPromptEnabled {
          Button("Close cover") { directCover = false }.accessibilityIdentifier("shortcut-close-cover")
        }
      }
    }
    .sheet(isPresented: $automaticPrompt, onDismiss: { model.hasPrompted = true }) {
      surface("prompt") {
        Button("Dismiss prompt") { automaticPrompt = false }.accessibilityIdentifier("shortcut-close-prompt")
      }
    }
  }

  @ViewBuilder
  private var browsingSurface: some View {
    if cardMode == "home" {
      homeBrowser
    } else {
      surface("home") {
        if let cardMode {
          cardBrowser(mode: cardMode)
        } else {
          Button("Open sheet") { sheet = true }.accessibilityIdentifier("shortcut-open-sheet")
          Button("Open cover") { directCover = true }.accessibilityIdentifier("shortcut-open-cover")
          selectionButtons
          Button("Context actions") { model.contextActions += 1 }
            .accessibilityIdentifier("shortcut-context")
            .contextMenu {
              Button("Ordinary context action") { model.contextActions += 1 }
                .accessibilityIdentifier("shortcut-context-action")
            }
          TextField("Search", text: $query).accessibilityIdentifier("shortcut-search")
        }
      }
    }
  }

  private var homeBrowser: some View {
    let style = HomeRailStyle(focusHorizontalInset: CardMetrics.cardInset,
      focusVerticalInset: CardMetrics.cardInset, cardCornerRadius: CardMetrics.cardCornerRadius,
      mediaCornerRadius: CardMetrics.mediaCornerRadius)
    return GeometryReader { proxy in
      let rail = ChannelRailLayout.metrics(availableWidth: proxy.size.width, visibleCardCount: 3)
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 72) {
          HomeFollowingSection(channels: model.cards, rail: rail, style: style,
            isLoading: false, isRestoringAccount: false, isUsingDemoData: false,
            errorMessage: nil, showingFollowingDirectory: $showingDirectory,
            onRefresh: {}, onWatch: { _ in model.navigations += 1 },
            onGoToChannel: { _ in model.navigations += 1 }, focusedItemID: $focusedCard)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { homeFrame = $0 }
          VStack(alignment: .leading, spacing: 2) {
            Text("Recommended for you").font(.system(size: 32, weight: .bold))
              .accessibilityIdentifier("shortcut-home-next-title")
            HomeRailScrollView(rail: rail, style: style) {
              ForEach(model.cards.prefix(3), id: \.channelKey) { channel in
                HomeRailStreamCard(channel: channel, itemID: "recommended-\(channel.channelKey)",
                  layout: style.cardLayout(for: rail), onTap: { model.navigations += 1 },
                  focusedItemID: $focusedCard)
              }
            }
          }
        }
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.top, 32)
        .padding(.bottom, 12)
      }
      .scrollClipDisabled()
      .onScrollGeometryChange(for: [CGFloat].self) {
        [$0.contentOffset.x, $0.contentOffset.y, $0.contentSize.width, $0.contentSize.height,
         $0.containerSize.width, $0.containerSize.height]
      } action: { _, value in homeScrollGeometry = value }
    }
    .background(palette.cardOpaqueSurface)
    .preferredColorScheme(theme.preferredColorScheme)
    .overlay(alignment: .bottomLeading) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Shortcut home").accessibilityIdentifier("shortcut-surface-home")
        Text("Home layout verification")
          .accessibilityIdentifier("shortcut-home-state")
          .accessibilityValue(homeState)
      }
      .font(.system(size: 12))
      .allowsHitTesting(false)
    }
    .task {
      await Task.yield()
      focusedCard = HomeFollowingFocus.card(model.cards[0].channelKey)
    }
  }

  private var homeState: String {
    let data: [String: Any] = [
      "count": model.lineup.entries.count, "requests": model.requests,
      "navigations": model.navigations, "focused": focusedCard ?? "",
      "opening": model.lineup.isOpeningPlayback, "showing": model.lineup.isShowingPlayback,
      "controller": model.lineup.controller != nil,
      "section": [homeFrame.minX, homeFrame.minY, homeFrame.width, homeFrame.height],
      "scroll": homeScrollGeometry,
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), as: UTF8.self)
  }

  private func cardBrowser(mode: String) -> some View {
    VStack(spacing: 24) {
      Text(verbatim: "count=\(model.lineup.entries.count);keys=\(model.lineup.entries.map { $0.channel.channelKey }.sorted().joined(separator: ","));navigation=\(model.navigations);focused=\(focusedCard ?? "")")
        .font(.caption2)
        .accessibilityIdentifier("shortcut-card-state")
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(420)), count: 3), spacing: 24) {
        ForEach(model.cards, id: \.channelKey) { channel in
          fixtureCard(channel, mode: mode)
        }
      }
      .focusScope(cardNamespace)
      Button("Non-card control") { model.contextActions += 1 }
        .accessibilityIdentifier("shortcut-non-card")
        .focused($focusedCard, equals: "non-card")
        .onPlayPauseCommand { model.shortPress() }
    }
  }

  @ViewBuilder
  private func fixtureCard(_ channel: FollowedChannel, mode: String) -> some View {
    if mode == "rail" {
      HomeRailStreamCard(channel: channel, itemID: "shortcut-card-\(channel.channelKey)",
        layout: .rail(mediaWidth: 380, mediaHeight: 214, focusHorizontalInset: 16,
          focusVerticalInset: 12, cardCornerRadius: 20, mediaCornerRadius: 14),
        onTap: { model.navigations += 1 }, focusedItemID: $focusedCard)
    } else {
      let isFocused = focusedCard == channel.channelKey
      // ChannelPage's private FocusableTile differs from the category-grid wrapper
      // by default-focus preference and an outer scale; exercise that exact pattern.
      StreamChannelCard(channel: channel, isFocused: isFocused)
        .contentShape(RoundedRectangle(cornerRadius: CardMetrics.gridCardCornerRadius))
        .focusable(true)
        .focused($focusedCard, equals: channel.channelKey)
        .prefersDefaultFocus(mode == "tile" && channel.channelKey == "twitch", in: cardNamespace)
        .focusEffectDisabled()
        .onTapGesture { model.navigations += 1 }
        .scaleEffect(mode == "tile" && isFocused ? AppLayout.focusedCardScale : 1)
        .animation(AppLayout.focusScaleAnimation, value: isFocused)
        .zIndex(isFocused ? 2 : 0)
        .modifier(MultiviewCardShortcut(channel: channel))
    }
  }

  private func promptAfterDismissalIfNeeded() {
    guard automaticPromptEnabled else { return }
    model.dismissalChecks += 1
    model.openingAtDismiss = model.lineup.isOpeningPlayback
    model.visibleAtDismiss = model.lineup.isShowingPlayback
    model.requestsAtDismiss = model.requests
    // Mirrors Home's presentation guard; the opt-in launch makes onboarding eligible.
    guard !isPresentingCover, !model.hasPrompted else { return }
    model.prompts += 1
    automaticPrompt = true
  }

  private var selectionButtons: some View {
    HStack {
      Button("Select A") { model.selection = "A" }.accessibilityIdentifier("shortcut-select-A")
      Button("Select B") { model.selection = "B" }.accessibilityIdentifier("shortcut-select-B")
    }
  }

  @ViewBuilder
  private func surface<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
    let panel = VStack(spacing: 20) {
      Text("Shortcut \(name)").accessibilityIdentifier("shortcut-surface-\(name)")
      Text(verbatim: "requests=\(model.requests);short=\(model.shortCommands);sheet=\(sheet);cover=\(cover || directCover);nested=\(nested);selection=\(model.selection);hud=\(model.hud);paused=\(model.paused);context=\(model.contextActions)")
        .font(.caption2)
        .accessibilityIdentifier("shortcut-state-\(name)")
      if automaticPromptEnabled {
        Text(verbatim: "dismissals=\(model.dismissalChecks);prompts=\(model.prompts);prompt=\(automaticPrompt);opening=\(model.lineup.isOpeningPlayback);openingAtDismiss=\(model.openingAtDismiss);visibleAtDismiss=\(model.visibleAtDismiss);requestsAtDismiss=\(model.requestsAtDismiss);hasPrompted=\(model.hasPrompted)")
          .font(.caption2)
          .accessibilityIdentifier("shortcut-handoff-\(name)")
      }
      Text(verbatim: "model=\(model.identity);controller=\(model.lineup.controller.map { String(describing: ObjectIdentifier($0)) } ?? "none");panes=\(model.lineup.controller?.panes.map { String(describing: ObjectIdentifier($0.model)) }.joined(separator: ",") ?? "none");entries=\(model.lineup.entries.map { $0.id.uuidString }.joined(separator: ","))")
        .font(.caption2)
        .lineLimit(4)
        .accessibilityIdentifier("shortcut-identities-\(name)")
      content()
    }
    .padding(60)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.cardOpaqueSurface)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("shortcut-panel-\(name)")
    .preferredColorScheme(theme.preferredColorScheme)
    if cardMode == nil {
      panel.onPlayPauseCommand { model.shortPress() }
    } else {
      panel
    }
  }
}
#endif

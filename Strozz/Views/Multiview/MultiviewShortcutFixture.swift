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

    init() {
      let count = Int(ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_COUNT"] ?? "2") ?? 2
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
  @Environment(\.colorScheme) private var scheme

  private var theme: AppTheme {
    AppTheme(rawValue: ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_THEME"] ?? "dark") ?? .dark
  }
  private var palette: ThemePalette { theme.palette(systemColorScheme: scheme) }
  private var opaque: Bool { ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_OPAQUE"] == "1" }
  private var automaticPromptEnabled: Bool {
    ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SHORTCUT_AUTOPROMPT"] == "1"
  }

  private var isPresentingCover: Bool {
    sheet || cover || directCover || nested || automaticPrompt
      || model.lineup.isShowingPlayback || model.lineup.isOpeningPlayback
  }

  var body: some View {
    ZStack {
      surface("home") {
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
      .opacity(model.lineup.isShowingPlayback ? 0 : 1)
      .disabled(model.lineup.isShowingPlayback)
      .accessibilityHidden(model.lineup.isShowingPlayback)
      if let controller = model.lineup.controller {
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

  private func surface<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 20) {
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
    .onPlayPauseCommand { model.shortPress() }
    .preferredColorScheme(theme.preferredColorScheme)
  }
}
#endif

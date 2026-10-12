import SwiftUI

enum MobileEmoteProvider: String, CaseIterable, Identifiable {
  case twitch = "Twitch"
  case sevenTV = "7TV"
  case bttv = "BetterTTV"
  case ffz = "FrankerFaceZ"
  var id: Self { self }
}

enum MobileEmoteCatalog {
  static func emotes(from urls: [String: URL]) -> [MobileChatEmote] {
    urls.filter { !$0.key.isEmpty }.map { MobileChatEmote(name: $0.key, url: $0.value) }
      .sorted {
        let order = $0.name.localizedStandardCompare($1.name)
        return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
      }
  }

  static func filter(_ emotes: [MobileChatEmote], provider: MobileEmoteProvider?, search: String) -> [MobileChatEmote] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return emotes.filter {
      (provider == nil || $0.provider == provider?.rawValue)
        && (query.isEmpty || $0.name.localizedStandardContains(query))
    }
  }
}

enum MobileEmoteClipboard {
  static func copy(_ emote: MobileChatEmote, to pasteboard: UIPasteboard = .general) {
    pasteboard.string = emote.name
    UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied \(emote.name)"))
  }
}

struct MobileEmoteMenuButton: View {
  let action: () -> Void
  @Environment(\.themePalette) private var palette

  var body: some View {
    Button(action: action) {
      Icon(glyph: .moodSmile, size: 22)
        .foregroundStyle(palette.chatSidePrimaryText)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Emotes")
    .accessibilityIdentifier("mobile-chat-emotes")
  }
}

struct MobileChannelEmoteMenu: View {
  let channel: String
  let service: ChatService
  let composer: MobileChatComposerState
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(TwitchAccountSync.self) private var sync: TwitchAccountSync?

  private var insert: ((String) -> Bool)? {
    guard auth.isAuthenticated, sync?.isRestoringAccount != true else { return nil }
    return { composer.insertEmote($0) }
  }

  var body: some View {
    MobileEmoteMenu(channel: channel, urls: service.emoteURLs,
      isLoading: service.isLoadingEmoteCatalog, needsRetry: service.emoteCatalogNeedsRetry,
      insertionError: composer.errorMessage, sending: composer.sending, onInsert: insert,
      onRetry: { service.startEmoteCatalogLoading(for: channel) })
  }
}

struct MobileEmoteMenu: View {
  let channel: String
  let urls: [String: URL]
  let isLoading: Bool
  let needsRetry: Bool
  var insertionError: String? = nil
  var sending = false
  var onInsert: ((String) -> Bool)? = nil
  let onRetry: () -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @Environment(\.scenePhase) private var phase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(PersistenceKey.chatAnimatedEmotes) private var animated = true
  @ScaledMetric(relativeTo: .caption) private var cellWidth = 76.0
  @State private var emotes: [MobileChatEmote] = []
  @State private var search = ""
  @State private var provider: MobileEmoteProvider?
  @State private var inspected: MobileChatEmote?
  @State private var feedback: String?
  @State private var selectionCount = 0
  @State private var detent = PresentationDetent.large

  var body: some View {
    let filtered = MobileEmoteCatalog.filter(emotes, provider: provider, search: search)
    NavigationStack {
      VStack(spacing: 0) {
        MobileEmoteMenuHeader(channel: channel, count: filtered.count, provider: $provider)
        if needsRetry {
          HStack {
            Text("Some emotes couldn't load. Available emotes are shown.")
              .font(.caption)
            Spacer(minLength: 8)
            Button("Retry", action: onRetry).disabled(isLoading)
          }
          .padding(.horizontal, 16).padding(.bottom, 12)
          .accessibilityIdentifier("emote-menu-error")
        }
        if emotes.isEmpty && isLoading {
          ProgressView("Loading emotes")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
          ContentUnavailableView {
            Label {
              if search.isEmpty { Text("No emotes available") }
              else { Text("No matching emotes") }
            } icon: { Icon(glyph: .moodSmile, size: 36) }
          } description: {
            if needsRetry { Text("Try loading the emotes again.") }
            else { Text("Try another provider or search.") }
          }
        } else {
          ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth), spacing: 8)], spacing: 12) {
              ForEach(filtered) { emote in
                MobileEmoteMenuCell(emote: emote, animated: animated && !reduceMotion,
                  active: phase == .active && inspected == nil, inserts: onInsert != nil,
                  onSelect: { select(emote) }, onCopy: { copy(emote) },
                  onInspect: { inspected = emote })
                  .disabled(sending)
              }
            }
            .padding(16)
          }
          .scrollDismissesKeyboard(.interactively)
          .accessibilityIdentifier("emote-menu-grid")
        }
      }
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 4) {
          if let insertionError {
            Text(insertionError).foregroundStyle(palette.chatSidePrimaryText)
          } else if let feedback {
            Text(feedback).foregroundStyle(palette.chatSidePrimaryText)
              .accessibilityIdentifier("emote-menu-feedback")
          } else if onInsert != nil {
            Text("Tap to add to your message. Touch and hold to copy.")
          } else {
            Text("Tap to copy an emote. Sign in to add it to a message.")
          }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .foregroundStyle(palette.chatSideSecondaryText)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(palette.chatSideSurface)
      }
      .background(palette.chatSideSurface)
      .foregroundStyle(palette.chatSidePrimaryText)
      .navigationTitle("Emotes")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emotes")
      .searchPresentationToolbarBehavior(.avoidHidingContent)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("emote-menu-done")
        }
      }
    }
    .presentationDetents([.medium, .large], selection: $detent)
    .presentationDragIndicator(.visible)
    .presentationBackground(palette.chatSideSurface)
    .onChange(of: urls, initial: true) { _, urls in emotes = MobileEmoteCatalog.emotes(from: urls) }
    .onChange(of: provider) { _, _ in feedback = nil }
    .sensoryFeedback(.selection, trigger: selectionCount)
    .sheet(item: $inspected) { emote in
      MobileEmoteDetailView(emote: emote).environment(\.themePalette, palette)
    }
  }

  private func select(_ emote: MobileChatEmote) {
    if let onInsert {
      if onInsert(emote.name) {
        feedback = String(localized: "Added \(emote.name)")
        selectionCount += 1
      }
    } else {
      copy(emote)
    }
  }

  private func copy(_ emote: MobileChatEmote) {
    MobileEmoteClipboard.copy(emote)
    feedback = String(localized: "Copied \(emote.name)")
    selectionCount += 1
  }
}

private struct MobileEmoteMenuHeader: View {
  let channel: String
  let count: Int
  @Binding var provider: MobileEmoteProvider?
  @Environment(\.themePalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(channel)'s channel and global emotes")
        .font(.subheadline).foregroundStyle(palette.chatSideSecondaryText)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Picker("Provider", selection: $provider) {
          Text("All providers").tag(nil as MobileEmoteProvider?)
          ForEach(MobileEmoteProvider.allCases) { provider in
            Text(provider.rawValue).tag(Optional(provider))
          }
        }
        .pickerStyle(.menu)
        .tint(palette.chatSidePrimaryText)
        .accessibilityIdentifier("emote-menu-provider")
        Spacer(minLength: 8)
        Group {
          if count == 1 { Text("1 emote") }
          else { Text("\(count) emotes") }
        }
          .font(.caption).monospacedDigit()
          .foregroundStyle(palette.chatSideSecondaryText)
          .accessibilityIdentifier("emote-menu-count")
      }
    }
    .padding(16)
  }
}

private struct MobileEmoteMenuCell: View {
  let emote: MobileChatEmote
  let animated: Bool
  let active: Bool
  let inserts: Bool
  let onSelect: () -> Void
  let onCopy: () -> Void
  let onInspect: () -> Void
  @Environment(\.themePalette) private var palette
  @State private var visible = false
  @State private var requested = false
  @State private var failed = false
  @State private var loaded = false

  var body: some View {
    Button(action: onSelect) {
      VStack(spacing: 6) {
        ZStack {
          if failed {
            Icon(glyph: .alertCircle, size: 24).foregroundStyle(palette.chatSideSecondaryText)
          } else if requested {
            ChatEmoteImage(url: emote.url, animated: animated, active: visible && active, isGIF: false) { size in
              failed = size == nil
              loaded = size != nil
            }
          }
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(palette.cardOpaqueSurface, in: RoundedRectangle(cornerRadius: 12))
        Text(emote.name).font(.caption).lineLimit(2)
          .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
      }
      .foregroundStyle(palette.chatSidePrimaryText)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(emote.name)
    .accessibilityValue(failed ? Text("Image unavailable") : (loaded ? Text("Loaded") : Text("Loading")))
    .accessibilityHint(inserts ? Text("Adds this emote to your message") : Text("Copies this emote's name"))
    .accessibilityIdentifier("emote-menu-item-\(emote.name)")
    .contextMenu {
      Button("Copy emote name", action: onCopy)
      Button("View emote", action: onInspect)
    }
    .accessibilityAction(named: Text("Copy emote name"), onCopy)
    .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
    .onChange(of: visible) { _, visible in
      if visible { requested = true }
    }
    .onDisappear { visible = false }
  }
}

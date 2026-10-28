import SwiftUI

/// One titled group of channels offered on the multiview setup screen — e.g.
/// "Following", "Recommended for you", "Popular right now". Sections let the
/// picker double as a discovery surface instead of only listing follows.
struct MultiviewChannelSection: Identifiable, Equatable {
  let id: String
  let title: String
  let channels: [FollowedChannel]
}

struct MultiviewSelection: Equatable {
  static let offlineGrace: Duration = .seconds(10)
  enum ToggleResult { case updated, limitReached, unavailable }

  struct Entry: Equatable {
    var channel: FollowedChannel
    var sectionID: String
    var sectionTitle: String
    var position: Int
    var offlineSince: ContinuousClock.Instant?

    var offlineChannel: FollowedChannel {
      var value = FollowedChannel(id: channel.id, login: channel.login, displayName: channel.displayName,
        title: channel.title, gameName: channel.gameName, viewerCount: nil,
        thumbnailURL: channel.thumbnailURL, profileImageURL: channel.profileImageURL,
        isLive: false, isMature: channel.isMature)
      value.platform = channel.platform
      value.kick = channel.kick
      value.youtube = channel.youtube
      return value
    }
  }

  private(set) var entries: [Entry] = []
  var nextExpiry: ContinuousClock.Instant? {
    entries.compactMap { $0.offlineSince?.advanced(by: Self.offlineGrace) }.min()
  }

  static func liveSections(_ sections: [MultiviewChannelSection]) -> [MultiviewChannelSection] {
    var seen = Set<String>()
    return sections.compactMap { section in
      let channels = section.channels.filter { $0.isLive && seen.insert($0.channelKey).inserted }
      return channels.isEmpty ? nil : .init(id: section.id, title: section.title, channels: channels)
    }
  }

  func channels(in sections: [MultiviewChannelSection]) -> [FollowedChannel] {
    let live = Dictionary(uniqueKeysWithValues:
      Self.liveSections(sections).flatMap(\.channels).map { ($0.channelKey, $0) })
    return entries.compactMap { live[$0.channel.channelKey] }
  }

  func presentedSections(_ sections: [MultiviewChannelSection]) -> [MultiviewChannelSection] {
    var result = Self.liveSections(sections)
    let live = Set(result.flatMap(\.channels).map(\.channelKey))
    for entry in entries.sorted(by: { $0.position < $1.position })
      where !live.contains(entry.channel.channelKey) {
      if let index = result.firstIndex(where: { $0.id == entry.sectionID }) {
        let section = result[index]
        var channels = section.channels
        channels.insert(entry.offlineChannel, at: min(entry.position, channels.count))
        result[index] = .init(id: section.id, title: section.title, channels: channels)
      } else {
        result.append(.init(id: entry.sectionID, title: entry.sectionTitle, channels: [entry.offlineChannel]))
      }
    }
    return result
  }

  mutating func reconcile(_ sections: [MultiviewChannelSection], now: ContinuousClock.Instant = .now) {
    let live = Self.liveSections(sections)
    for index in entries.indices {
      let key = entries[index].channel.channelKey
      if let section = live.first(where: { $0.channels.contains(where: { $0.channelKey == key }) }),
        let position = section.channels.firstIndex(where: { $0.channelKey == key }) {
        entries[index] = .init(channel: section.channels[position], sectionID: section.id,
          sectionTitle: section.title, position: position)
      } else if entries[index].offlineSince == nil {
        entries[index].offlineSince = now
      }
    }
  }

  @discardableResult
  mutating func toggle(_ channel: FollowedChannel, in sections: [MultiviewChannelSection]) -> ToggleResult {
    reconcile(sections)
    if let index = entries.firstIndex(where: { $0.channel.channelKey == channel.channelKey }) {
      entries.remove(at: index)
    } else if channels(in: sections).count >= multiviewPaneLimit {
      return .limitReached
    } else if let section = Self.liveSections(sections).first(where: {
      $0.channels.contains(where: { $0.channelKey == channel.channelKey })
    }), let position = section.channels.firstIndex(where: { $0.channelKey == channel.channelKey }) {
      entries.append(.init(channel: section.channels[position], sectionID: section.id,
        sectionTitle: section.title, position: position))
    } else {
      return .unavailable
    }
    return .updated
  }

  mutating func expire(at now: ContinuousClock.Instant = .now) {
    entries.removeAll { $0.offlineSince.map { now >= $0.advanced(by: Self.offlineGrace) } ?? false }
  }
}

/// Picks up to ``multiviewPaneLimit`` live channels to watch together, then
/// hands the ordered selection to the multiview grid.
///
/// Channels are grouped into discovery sections (Following first, then
/// recommendations and popular streams) and rendered as native horizontal rails
/// of ``StreamChannelCard`` — the same card the Home grid uses, so each option
/// brings the thumbnail, hover-preview video, LIVE/viewer badge, avatar, and
/// title for free — wrapped in a selection overlay that shows the pick order, a
/// native focus-color ring when selected, and dims unselected cards once the
/// pick limit is reached.
struct MultiviewSetupView: View {
  let sections: [MultiviewChannelSection]
  var onStart: ([FollowedChannel]) -> Void
  var onCancel: () -> Void

  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Global stream-card size preference, shared with Home/Browse so the picker
  /// honours the same "N across" choice instead of a fixed width.
  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue
  @State private var selection: MultiviewSelection
  /// Set when the user activates a tile that's already at the pick limit; drives
  /// the "max streams" toast. A fresh token on each rejection restarts the
  /// auto-dismiss timer so rapid presses keep the toast visible.
  @State private var limitToastToken: UUID?
  @State private var selectionNotice = MultiviewSelection.ToggleResult.limitReached
  @FocusState private var focusedID: String?

  init(sections: [MultiviewChannelSection], onStart: @escaping ([FollowedChannel]) -> Void,
       onCancel: @escaping () -> Void, selection: MultiviewSelection = .init()) {
    self.sections = sections
    self.onStart = onStart
    self.onCancel = onCancel
    _selection = State(initialValue: selection)
  }

  private var cardSize: StreamCardSize { StreamCardSize.resolve(streamCardSizeRaw) }

  /// Live channels per section, deduped so a channel that appears in several
  /// pools is only offered once (in its highest-priority section). Keyed on
  /// `channelKey`, not `id` — the pools carry different kinds of id for the same
  /// streamer, so keying on `id` offered them twice and let you pick the same
  /// stream into two panes.
  private var resolvedSections: [MultiviewChannelSection] {
    selection.presentedSections(sections)
  }

  private var hasChannels: Bool { !resolvedSections.isEmpty }
  private var isAtLimit: Bool { orderedSelection.count >= multiviewPaneLimit }
  private var canStart: Bool { orderedSelection.count >= 2 }

  private var orderedSelection: [FollowedChannel] {
    selection.channels(in: sections)
  }

  var body: some View {
    GeometryReader { proxy in
      let rail = ChannelRailLayout.metrics(
        availableWidth: proxy.size.width,
        trailingSafeArea: proxy.safeAreaInsets.trailing,
        visibleCardCount: cardSize.visibleCardCount
      )

      ZStack {
        AppBackground(palette: palette).ignoresSafeArea()

        VStack(alignment: .leading, spacing: 0) {
          header

          if !hasChannels {
            emptyState
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 36) {
                ForEach(resolvedSections) { section in
                  sectionRail(section, rail: rail)
                }
              }
              .padding(.vertical, 28)
            }
          }
        }
      }
      .overlay(alignment: .bottom) {
        if limitToastToken != nil {
          limitToast
            .padding(.bottom, 56)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.spring(response: 0.35, dampingFraction: 0.85), value: limitToastToken)
      .task(id: limitToastToken) {
        guard limitToastToken != nil else { return }
        do { try await Task.sleep(for: .seconds(2.4)) } catch { return }
        limitToastToken = nil
      }
      .onChange(of: sections, initial: true) { _, value in
        selection.reconcile(value)
        if !isAtLimit { limitToastToken = nil }
      }
      .task(id: selection.nextExpiry) {
        guard let deadline = selection.nextExpiry else { return }
        do { try await ContinuousClock().sleep(until: deadline) } catch { return }
        withAnimation(.motionAware(.easeOut(duration: 0.4), reduceMotion: reduceMotion)) {
          selection.expire()
        }
      }
      .onExitCommand(perform: onCancel)
    }
  }

  /// Lightweight, non-focusable toast shown when the viewer tries to pick a 5th
  /// stream. It never steals focus — the disabled tiles stay reachable — it just
  /// explains why nothing happened.
  private var limitToast: some View {
    HStack(spacing: 12) {
      Icon(glyph: .alertCircle, size: 26)
        .foregroundStyle(.secondary)
      Group {
        if selectionNotice == .unavailable { Text("This channel is no longer live.") }
        else { Text("You can watch up to \(multiviewPaneLimit) streams at once") }
      }
      .font(.headline)
      .foregroundStyle(.primary)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 18)
    .background {
      if glassDisabled {
        Capsule().fill(palette.chromeOpaqueSurface)
          .overlay(Capsule().strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
      } else if #available(tvOS 26.0, *) {
        Capsule().glassEffect(.regular, in: Capsule())
      } else {
        Capsule().fill(.ultraThinMaterial)
      }
    }
    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    .accessibilityElement(children: .combine)
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 6) {
        Label {
          Text("Multiview")
            .font(.system(size: 40, weight: .bold))
        } icon: {
          Icon(glyph: .borderAll, size: 34)
        }
        Text("Choose up to \(multiviewPaneLimit) live channels to watch together.")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        onStart(orderedSelection)
      } label: {
        Text(canStart ? "Start Multiview (\(orderedSelection.count))" : "Pick 2+ channels")
          .font(.headline)
          .padding(.horizontal, 12)
      }
      .disabled(!canStart)
      .accessibilityIdentifier("multiview-start")
    }
    .padding(.horizontal, AppLayout.horizontalPadding)
    .padding(.top, 48)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Text("Not enough live channels")
        .font(.title2.weight(.semibold))
      Text("Multiview needs at least two channels that are live right now.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Section rail

  private func sectionRail(_ section: MultiviewChannelSection, rail: ChannelRailMetrics) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(section.title)
        .font(.system(size: 30, weight: .bold))
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, AppLayout.horizontalPadding)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: rail.spacing) {
          ForEach(section.channels, id: \.channelKey) { channel in
            tile(channel)
              .frame(width: rail.outerCardWidth)
              .transition(.opacity)
          }
        }
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.vertical, 16)
      }
      .scrollClipDisabled()
    }
    .focusSection()
  }

  // MARK: Tile

  private func tile(_ channel: FollowedChannel) -> some View {
    let order = orderedSelection.firstIndex { $0.channelKey == channel.channelKey }
    let isSelected = selection.entries.contains { $0.channel.channelKey == channel.channelKey }
    let isFocused = focusedID == channel.channelKey
    let dimmed = isAtLimit && !isSelected

    return StreamChannelCard(
      channel: channel,
      isFocused: isFocused,
      layout: .grid(),
      focusScale: 1,
      showsGameName: true,
      mediaOverlay: { cornerRadius in
        AnyView(
          selectionDecoration(order: order, isSelected: isSelected, cornerRadius: cornerRadius)
        )
      }
    )
    .opacity(dimmed ? 0.4 : 1)
    .scaleEffect(isFocused ? 1.04 : 1)
    .animation(.easeOut(duration: 0.18), value: isFocused)
    .animation(.easeOut(duration: 0.18), value: isSelected)
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .focusable(true)
    .focused($focusedID, equals: channel.channelKey)
    .focusEffectDisabled()
    .onTapGesture { toggle(channel) }
    .accessibilityIdentifier("multiview-select-\(channel.channelKey)")
    .accessibilityValue(channel.isLive ? "Live" : "Offline")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint(
      dimmed
        ? "Limit of \(multiviewPaneLimit) reached"
        : (isSelected
            ? (channel.isLive
                ? "Selected, position \((order ?? 0) + 1). Click to remove."
                : "Offline. Click to remove, or wait for automatic removal.")
            : "Click to add to multiview")
    )
  }

  /// The pick-order badge and selection ring, drawn on the card's thumbnail so
  /// they share its exact bounds and corner radius. Hanging them off the whole
  /// card instead would ring the caption too and, in the borderless "Posters"
  /// presentation, miss the artwork's radius entirely.
  private func selectionDecoration(
    order: Int?, isSelected: Bool, cornerRadius: CGFloat
  ) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .strokeBorder(isSelected ? selectionColor : Color.clear, lineWidth: 4)
      .overlay(alignment: .topTrailing) {
        Group {
          if let order {
            selectionBadge(order: order + 1)
          } else if isSelected {
            Icon(glyph: .x, size: 26)
              .foregroundStyle(selectionBadgeForeground)
              .frame(width: 52, height: 52)
              .background(selectionColor, in: Circle())
          } else {
            selectionPlaceholder
          }
        }
        .padding(14)
      }
  }

  /// The native tvOS selection/focus color: white on dark and OLED, black on
  /// the Light theme — never brand purple.
  private var selectionColor: Color {
    palette.isLight ? .black : .white
  }

  private var selectionBadgeForeground: Color {
    palette.isLight ? .white : .black
  }

  /// Numbered pick-order badge. A clean solid disc in the selection color with a
  /// contrasting, monospaced numeral so it reads at a glance and never feels
  /// cramped.
  private func selectionBadge(order: Int) -> some View {
    Text("\(order)")
      .font(.system(size: 26, weight: .bold, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(selectionBadgeForeground)
      .frame(width: 52, height: 52)
      .background(selectionColor, in: Circle())
      .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
  }

  /// Unselected (addable) indicator: a circle that exactly matches the numbered
  /// badge's size and position, so every selectable stream advertises the same
  /// tap target. A bold ring in the native selection color over a lightly
  /// frosted disc — the glass material is dialed to a low opacity so there's
  /// just a slight blur, not a heavy frost. Becomes an opaque palette disc under
  /// Reduce Transparency.
  private var selectionPlaceholder: some View {
    ZStack {
      if glassDisabled {
        Circle().fill(palette.chromeOpaqueSurface.opacity(0.85))
      } else {
        Circle().fill(.ultraThinMaterial).opacity(0.55)
        Circle().fill(selectionColor.opacity(0.08))
      }
      Circle().strokeBorder(selectionColor.opacity(0.9), lineWidth: 3)
    }
    .frame(width: 52, height: 52)
    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
  }

  private func toggle(_ channel: FollowedChannel) {
    let result = selection.toggle(channel, in: sections)
    if result != .updated {
      selectionNotice = result
      limitToastToken = UUID()
    }
  }
}

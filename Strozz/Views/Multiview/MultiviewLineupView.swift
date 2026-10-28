import SwiftUI

/// Attach outside the card's focusable wrapper, not inside its visual content.
struct MultiviewCardShortcut: ViewModifier {
  let channel: FollowedChannel
  @Environment(\.multiviewLineup) private var lineup

  func body(content: Content) -> some View {
    content.onPlayPauseCommand(perform: action)
  }

  private var action: (() -> Void)? {
    guard let lineup,
      lineup.contains(channel) || (channel.isLive && channel.platform != .youtube)
    else { return nil }
    return { lineup.toggle(channel) }
  }
}

struct MultiviewSelectionAction: View {
  let channel: FollowedChannel
  @Environment(\.multiviewLineup) private var lineup

  var body: some View {
    if let lineup {
      if channel.platform != .youtube, channel.isLive || lineup.contains(channel) {
        Button {
          lineup.toggle(channel)
        } label: {
          Label {
            if lineup.contains(channel) { Text("Remove from multiview") }
            else if lineup.isFull { Text("Multiview full") }
            else { Text("Add to multiview") }
          } icon: {
            Icon(glyph: lineup.contains(channel) ? .minus : .borderAll)
          }
        }
        .disabled(!lineup.contains(channel) && lineup.isFull)
        .accessibilityIdentifier("multiview-toggle-\(channel.channelKey)")
      }
      if !lineup.entries.isEmpty {
        Button {
          lineup.requestPlayback()
        } label: {
          Label {
            if lineup.controller == nil { Text("Start multiview") }
            else { Text("Return to multiview") }
          } icon: {
            Icon(glyph: .playerPlayFilled)
          }
        }
        .disabled(!lineup.canStart)
        .accessibilityIdentifier("multiview-context-start")
      }
    }
  }
}

struct MultiviewLineupButton: View {
  @Environment(\.multiviewLineup) private var lineup
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showingLineup = false
  @State private var startAfterDismissal = false

  var body: some View {
    if let lineup {
      let isEmpty = lineup.entries.isEmpty
      let avatars = lineup.entries.filter { $0.offlineSince == nil }
      Button { showingLineup = true } label: {
        HStack(spacing: 16) {
          Text("Multiview").lineLimit(1)
          HStack(spacing: -14) {
            ForEach(avatars) { entry in
              MultiviewAvatar(url: entry.channel.profileImageURL, size: 48)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                  removal: .opacity))
            }
          }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 40)
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: avatars.map(\.id))
      // Keep native button height in the row without reserving avatar width.
      .frame(width: isEmpty ? 0 : nil)
      .opacity(isEmpty ? 0 : 1)
      .disabled(isEmpty)
      .allowsHitTesting(!isEmpty)
      .accessibilityHidden(isEmpty)
      .accessibilityIdentifier("multiview-lineup")
      .accessibilityLabel("Multiview")
      .accessibilityValue("\(lineup.liveChannels.count) streams")
      .onChange(of: isEmpty) { _, empty in
        if empty {
          startAfterDismissal = false
          showingLineup = false
        }
      }
      .sheet(isPresented: $showingLineup, onDismiss: {
        if startAfterDismissal {
          startAfterDismissal = false
          lineup.requestPlayback()
        }
      }) {
        MultiviewLineupView(lineup: lineup) {
          startAfterDismissal = true
          showingLineup = false
        }
      }
    }
  }
}

private struct MultiviewAvatar: View {
  let url: URL?
  var size: CGFloat = 40
  @Environment(\.themePalette) private var palette

  var body: some View {
    CachedAsyncImage(url: url) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Circle().fill(palette.chromeOpaqueSurface)
        .overlay { Icon(glyph: .userCircle, size: size * 0.8).foregroundStyle(palette.chromeOnOpaque) }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay { Circle().strokeBorder(palette.chromeOpaqueBorder, lineWidth: 2) }
    .accessibilityHidden(true)
  }
}

struct MultiviewLineupView: View {
  let lineup: MultiviewLineup
  let onStart: () -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focusedKey: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      HStack {
        Text("Multiview").font(.title2.bold())
        Spacer()
        Text("\(lineup.liveChannels.count) / \(multiviewPaneLimit)").foregroundStyle(.secondary)
      }
      ScrollView {
        VStack(spacing: 16) {
          ForEach(lineup.entries) { entry in
            Button {
              let index = lineup.entries.firstIndex { $0.id == entry.id } ?? 0
              lineup.remove(entry.channel.channelKey)
              focusedKey = lineup.entries.isEmpty ? "done"
                : lineup.entries[min(index, lineup.entries.count - 1)].channel.channelKey
            } label: {
              HStack(spacing: 18) {
                MultiviewAvatar(url: entry.channel.profileImageURL)
                Text(entry.channel.displayName)
                if entry.offlineSince != nil { Text("Offline").foregroundStyle(.secondary) }
                Spacer()
                Icon(glyph: .x, size: 24)
              }
            }
            .focused($focusedKey, equals: entry.channel.channelKey)
            .accessibilityLabel("Remove \(entry.channel.displayName) from multiview")
            .accessibilityIdentifier("multiview-remove-\(entry.channel.channelKey)")
          }
        }
        .padding(12)
      }
      .frame(maxHeight: 420)
      HStack(spacing: 24) {
        Button(action: onStart) {
          if lineup.controller == nil { Text("Start multiview") }
          else { Text("Return to multiview") }
        }
        .disabled(!lineup.canStart)
        .accessibilityIdentifier("multiview-start")
        Button("Clear", role: .destructive) { lineup.clear(); dismiss() }
          .disabled(lineup.entries.isEmpty)
        Spacer()
        Button("Done") { dismiss() }
          .focused($focusedKey, equals: "done")
      }
    }
    .padding(48)
    .frame(width: 880)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: lineup.entries.map(\.id))
    .onExitCommand { dismiss() }
  }
}

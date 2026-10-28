import SwiftUI

struct MultiviewSelectionAction: View {
  let channel: FollowedChannel
  @Environment(\.multiviewLineup) private var lineup

  var body: some View {
    if let lineup, channel.platform != .youtube, channel.isLive || lineup.contains(channel) {
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
  }
}

struct MultiviewLineupButton: View {
  @Environment(\.multiviewLineup) private var lineup
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showingLineup = false
  @State private var startAfterDismissal = false

  var body: some View {
    if let lineup {
      let avatars = lineup.entries.filter { $0.offlineSince == nil }
      Button { showingLineup = true } label: {
        HStack(spacing: 16) {
          Text("Multiview").lineLimit(1)
          HStack(spacing: -12) {
            ForEach(avatars) { entry in
              MultiviewAvatar(url: entry.channel.profileImageURL)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                  removal: .opacity))
            }
          }
          .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: avatars.map(\.id))
        }
        .frame(width: 350, alignment: .leading)
      }
      .opacity(lineup.entries.isEmpty ? 0 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: lineup.entries.isEmpty)
      .disabled(lineup.entries.isEmpty)
      .accessibilityHidden(lineup.entries.isEmpty)
      .accessibilityIdentifier("multiview-lineup")
      .accessibilityLabel("Multiview")
      .accessibilityValue("\(lineup.liveChannels.count) streams")
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
  @Environment(\.themePalette) private var palette

  var body: some View {
    CachedAsyncImage(url: url) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Circle().fill(palette.chromeOpaqueSurface)
        .overlay { Icon(glyph: .userCircle, size: 32).foregroundStyle(palette.chromeOnOpaque) }
    }
    .frame(width: 40, height: 40)
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

import SwiftUI

/// The Home tab's "Following" (or "Trending" in demo mode) rail: the header with
/// its loading spinner, "See All" and refresh buttons, a focusable recovery state,
/// and the horizontal rail of merged Twitch + live-YouTube cards. Card content
/// (the merged `channels` list) and the watch / go-to actions are supplied by
/// `HomeView`, which still owns the cross-service merge and routing logic.
struct HomeFollowingSection: View {
  let channels: [FollowedChannel]
  let rail: ChannelRailMetrics
  let style: HomeRailStyle
  let isLoading: Bool
  let isRestoringAccount: Bool
  let isUsingDemoData: Bool
  let errorMessage: String?
  @Binding var showingFollowingDirectory: Bool
  let onRefresh: () -> Void
  let onWatch: (FollowedChannel) -> Void
  let onGoToChannel: (FollowedChannel) -> Void
  @FocusState.Binding var focusedItemID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(isUsingDemoData ? "Trending" : "Following")
          .font(.system(size: 32, weight: .bold))
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("following-title")

        if isLoading {
          ProgressView()
            .scaleEffect(0.85)
        }

        Spacer()

        HStack(spacing: 8) {
          if !isUsingDemoData {
            Button {
              showingFollowingDirectory = true
            } label: {
              Text("See All")
                .font(.system(size: 24, weight: .semibold))
            }
            .accessibilityLabel("See all followed channels")
            .focused($focusedItemID, equals: HomeFollowingFocus.directory)
            .accessibilityIdentifier(HomeFollowingFocus.directory)
          }

          Button {
            retry()
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 28, weight: .semibold))
          }
          .accessibilityLabel("Refresh")
          .focused($focusedItemID, equals: HomeFollowingFocus.refresh)
          .accessibilityIdentifier(HomeFollowingFocus.refresh)
        }
        .disabled(isRestoringAccount)
      }

      if channels.isEmpty {
        if isLoading {
          HomeStreamRailPlaceholder(
            rail: rail, style: style, isLoading: true,
            emptyMessage: "Loading streams"
          )
          .contentShape(Rectangle())
          .focusable()
          .focused($focusedItemID, equals: HomeFollowingFocus.status)
          .focusEffectDisabled()
          .accessibilityIdentifier(HomeFollowingFocus.status)
        } else {
          HomeFollowingRecoveryRail(
            rail: rail, style: style,
            isUsingDemoData: isUsingDemoData, errorMessage: errorMessage,
            onRefresh: retry, focusedItemID: $focusedItemID)
        }
      } else {
        if let errorMessage {
          HomeFollowingErrorNotice(
            isUsingDemoData: isUsingDemoData, errorMessage: errorMessage, onRefresh: retry,
            focusedItemID: $focusedItemID)
        }
        HomeRailScrollView(rail: rail, style: style) {
          ForEach(channels, id: \.channelKey) { channel in
            HomeRailStreamCard(
              channel: channel,
              itemID: "following-\(channel.channelKey)",
              layout: style.cardLayout(for: rail),
              onWatch: onWatch,
              onGoToChannel: onGoToChannel,
              onTap: { onWatch(channel) },
              focusedItemID: $focusedItemID
            )
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusSection()
    .onChange(of: channels.map(\.channelKey)) { previous, current in
      if let replacement = HomeFollowingFocus.replacement(
        focused: focusedItemID,
        previous: previous, current: current, isLoading: isLoading)
      {
        focusedItemID = replacement
      }
    }
    .onChange(of: isLoading) { _, loading in
      if !loading, focusedItemID == HomeFollowingFocus.status {
        focusedItemID =
          channels.first.map { HomeFollowingFocus.card($0.channelKey) }
          ?? HomeFollowingFocus.retry
      }
    }
    .onChange(of: errorMessage) { _, error in
      if error == nil, focusedItemID == HomeFollowingFocus.cachedRetry {
        focusedItemID = HomeFollowingFocus.refresh
      }
    }
  }

  private func retry() {
    focusedItemID = HomeFollowingFocus.refresh
    onRefresh()
  }
}

private struct HomeFollowingRecoveryRail: View {
  let rail: ChannelRailMetrics
  let style: HomeRailStyle
  let isUsingDemoData: Bool
  let errorMessage: String?
  let onRefresh: () -> Void
  @FocusState.Binding var focusedItemID: String?
  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled

  var body: some View {
    HomeStreamRailPlaceholder(rail: rail, style: style, isLoading: false, emptyMessage: "")
      .hidden()
      .accessibilityHidden(true)
      .overlay {
        VStack(alignment: .leading, spacing: 16) {
          if errorMessage != nil {
            HStack(spacing: 12) {
              Icon(glyph: .alertCircle, size: 32)
              Text(isUsingDemoData ? "Couldn't refresh Trending" : "Couldn't refresh Following")
            }
            .font(.headline)
          } else if isUsingDemoData {
            Text("No trending channels are available right now.").font(.headline)
          } else {
            Text("No live followed channels are available yet.").font(.headline)
          }
          if let errorMessage {
            Text(errorMessage)
              .font(.callout)
              .lineLimit(3)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("following-error")
          }
          Button("Try Again", action: onRefresh)
            .buttonStyle(.bordered)
            .focused($focusedItemID, equals: HomeFollowingFocus.retry)
            .accessibilityIdentifier(HomeFollowingFocus.retry)
        }
        .foregroundStyle(.primary)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
          if glassDisabled {
            RoundedRectangle(cornerRadius: style.cardCornerRadius).fill(palette.cardOpaqueSurface)
          } else {
            RoundedRectangle(cornerRadius: style.cardCornerRadius).fill(.regularMaterial)
          }
        }
        .overlay {
          RoundedRectangle(cornerRadius: style.cardCornerRadius)
            .strokeBorder(palette.cardOpaqueBorder, lineWidth: 1)
        }
      }
  }
}

private struct HomeFollowingErrorNotice: View {
  let isUsingDemoData: Bool
  let errorMessage: String
  let onRefresh: () -> Void
  @FocusState.Binding var focusedItemID: String?

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Icon(glyph: .alertCircle, size: 28)
      VStack(alignment: .leading, spacing: 4) {
        if isUsingDemoData {
          Text("Couldn't refresh Trending").font(.headline)
        } else {
          Text("Couldn't refresh Following. Showing the last loaded channels.")
            .font(.headline)
        }
        Text(errorMessage).font(.footnote)
          .accessibilityIdentifier("following-error")
      }
      Spacer()
      Button("Try Again", action: onRefresh)
        .buttonStyle(.bordered)
        .focused($focusedItemID, equals: HomeFollowingFocus.cachedRetry)
        .accessibilityIdentifier(HomeFollowingFocus.cachedRetry)
    }
    .foregroundStyle(.primary)
  }
}

enum HomeFollowingFocus {
  static let refresh = "following-refresh"
  static let directory = "following-directory"
  static let status = "following-status"
  static let retry = "following-retry"
  static let cachedRetry = "following-retry-cached"

  static func card(_ key: String) -> String { "following-\(key)" }

  static func replacement(
    focused: String?, previous: [String], current: [String],
    isLoading: Bool
  ) -> String? {
    guard let index = previous.firstIndex(where: { card($0) == focused }),
      !current.contains(previous[index])
    else { return nil }
    if current.isEmpty { return isLoading ? status : retry }
    return card(current[min(index, current.count - 1)])
  }
}

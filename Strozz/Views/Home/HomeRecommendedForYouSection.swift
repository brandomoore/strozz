import SwiftUI

/// The Home tab's "Recommended for you" rail — the on-device personalized
/// recommendations. Disabled personalization does not reserve a rail.
struct HomeRecommendedForYouSection: View {
  let personalizedEnabled: Bool
  let rail: ChannelRailMetrics
  let style: HomeRailStyle
  let onWatch: (FollowedChannel) -> Void
  let onGoToChannel: (FollowedChannel) -> Void
  let onNotInterested: (FollowedChannel) -> Void
  @FocusState.Binding var focusedItemID: String?

  @Environment(AppEnvironment.self) private var environment
  private var personalized: PersonalizedRecommendationsService { environment.personalized }

  var body: some View {
    let channels = personalized.channels

    if personalizedEnabled {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text("Recommended for you")
            .font(.system(size: 32, weight: .bold))
            .accessibilityAddTraits(.isHeader)

          if personalized.isLoading {
            ProgressView()
              .scaleEffect(0.85)
          }

          Spacer()
        }

        if channels.isEmpty {
          HomeStreamRailPlaceholder(
            rail: rail, style: style,
            isLoading: personalized.isLoading || personalized.lastUpdatedAt == nil,
            emptyMessage: "No personalized recommendations are available right now.")
        } else {
          HomeRailScrollView(rail: rail, style: style) {
            ForEach(channels, id: \.channelKey) { channel in
              HomeRailStreamCard(
                channel: channel,
                itemID: "foryou-\(channel.channelKey)",
                layout: style.cardLayout(for: rail),
                onWatch: onWatch,
                onGoToChannel: onGoToChannel,
                onNotInterested: onNotInterested,
                onTap: { onWatch(channel) },
                focusedItemID: $focusedItemID
              )
            }
          }
        }
      }
    }
  }
}

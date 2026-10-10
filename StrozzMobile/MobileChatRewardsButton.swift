import SwiftUI

struct MobileChatRewardsSummary {
  var balance: Int?
  var name: String
  var imageURL: URL?
  var streak: Int?
  var errorMessage: String?

  static func compactBalance(_ balance: Int, locale: Locale = .current) -> String {
    balance.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))
      .rounded(rule: .towardZero).locale(locale))
  }

  @MainActor
  static func snapshot(of tracker: TwitchWatchTracker) -> Self? {
    let points = tracker.channelRewards.points
    let errors = [tracker.errorMessage, tracker.channelRewards.errorMessage].compactMap { $0 }
    guard points != nil || tracker.streak != nil || !errors.isEmpty else { return nil }
    return Self(balance: points?.balance, name: points?.name ?? String(localized: "Channel points"),
      imageURL: points?.imageURL, streak: tracker.streak,
      errorMessage: errors.isEmpty ? nil : errors.joined(separator: "\n"))
  }
}

struct MobileChatRewardsButton: View {
  let summary: MobileChatRewardsSummary
  @State private var showDetails = false
  @Environment(\.themePalette) private var palette
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Button { showDetails = true } label: {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 2) {
          rewardIcon
          balance
        }
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      } else {
        HStack(spacing: 3) {
          rewardIcon
          balance
        }
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
    .fixedSize(horizontal: true, vertical: false)
    .foregroundStyle(palette.chatSidePrimaryText)
    .accessibilityLabel(Text(summary.name))
    .accessibilityValue(Text(summary.balance.map { $0.formatted() } ?? String(localized: "Details")))
    .accessibilityHint(summary.errorMessage == nil ? Text("Show balance and watch streak") : Text("Rewards need attention"))
    .accessibilityIdentifier("mobile-chat-rewards")
    .sheet(isPresented: $showDetails) {
      NavigationStack {
        Form {
          if let balance = summary.balance {
            LabeledContent(summary.name, value: balance.formatted())
              .accessibilityIdentifier("mobile-rewards-balance")
          }
          if let streak = summary.streak {
            LabeledContent("Watch streak", value: String(localized: "\(streak) streams"))
              .accessibilityIdentifier("mobile-rewards-streak")
          }
          if let error = summary.errorMessage {
            Text(error).foregroundStyle(.secondary)
          }
        }
        .scrollContentBackground(.hidden)
        .background(palette.chatSideSurface)
        .navigationTitle("Channel points")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetails = false } } }
      }
      .presentationDetents([.medium, .large])
      .environment(\.themePalette, palette)
    }
  }

  private var rewardIcon: some View {
    CachedAsyncImage(url: summary.imageURL) { image in
      image.resizable().scaledToFit()
    } placeholder: { Icon(glyph: .giftFilled, size: 18) }
      .frame(width: 18, height: 18)
      .overlay(alignment: .topTrailing) {
        if summary.errorMessage != nil {
          Icon(glyph: .alertCircle, size: 12)
            .background(palette.chatSideSurface, in: Circle())
        }
      }
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var balance: some View {
    if let value = summary.balance {
      Text(MobileChatRewardsSummary.compactBalance(value))
        .font(.caption.weight(.semibold)).monospacedDigit()
        .fixedSize()
    }
  }
}

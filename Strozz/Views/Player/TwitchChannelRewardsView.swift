import SwiftUI

struct TwitchChannelRewardsView: View {
  let rewards: TwitchChannelRewards
  let session: TwitchWatchRewardsSession
  let events: HermesEventService
  let onClose: () -> Void
  @Environment(\.glassDisabled) private var glassDisabled
  @State private var selected: TwitchChannelReward?
  @State private var confirmation: Redemption?
  @State private var showConfirmation = false
  @State private var action: Task<Void, Never>?

  private struct Redemption {
    let reward: TwitchChannelReward
    let message: String
    let emoteID: String?
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Text(selected == nil ? LocalizedStringResource("Polls & Rewards") : LocalizedStringResource("Redeem Reward"))
          .font(.title2.bold())
        Spacer()
        Button {
          if selected != nil { selected = nil } else { onClose() }
        } label: {
          Icon(glyph: selected == nil ? .x : .chevronLeft, size: 26)
        }
        .accessibilityLabel(Text(selected == nil
          ? LocalizedStringResource("Close rewards") : LocalizedStringResource("Back to rewards")))
      }
      if let points = rewards.points {
        Text("\(points.balance, format: .number) \(points.name)")
          .font(.headline)
      }
      if let error = rewards.errorMessage {
        Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
      }
      if let status = rewards.statusMessage {
        Text(status).font(.callout)
      }
      if rewards.isBusy { ProgressView() }
      if !session.isConnected {
        Text("Connect Twitch Rewards in Settings > Accounts.")
          .font(.callout)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            if let selected {
              TwitchRewardDetails(reward: selected, emotes: rewards.points?.emotes ?? []) { message, emoteID in
                confirmation = Redemption(reward: selected, message: message, emoteID: emoteID)
                showConfirmation = true
              }
            } else {
              TwitchPollVotingSection(rewards: rewards, events: events) { poll, choiceID in
                run { await rewards.vote(in: poll, choiceID: choiceID, currentPoll: { events.poll }) }
              }
              TwitchChannelRewardList(points: rewards.points) { selected = $0 }
            }
          }
          .padding(14)
        }
        .disabled(rewards.isBusy || !rewards.canInteract)
        Button("Refresh") { run { await rewards.reload() } }
          .disabled(rewards.isBusy || !rewards.canInteract)
      }
    }
    .padding(30)
    .settingsGlassPanel(disabled: glassDisabled)
    .focusSection()
    .task { await rewards.reload() }
    .onDisappear { action?.cancel() }
    .onExitCommand {
      if selected != nil { selected = nil } else { onClose() }
    }
    .confirmationDialog("Redeem this reward?", isPresented: $showConfirmation) {
      if let confirmation {
        Button("Spend \(confirmation.reward.cost) points") {
          run {
            await rewards.redeem(
              confirmation.reward, message: confirmation.message, emoteID: confirmation.emoteID)
            if rewards.statusMessage != nil { selected = nil }
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if let confirmation { Text(confirmation.reward.title) }
    }
  }

  private func run(_ operation: @escaping @MainActor () async -> Void) {
    action?.cancel()
    action = Task { await operation() }
  }
}

private struct TwitchPollVotingSection: View {
  let rewards: TwitchChannelRewards
  let events: HermesEventService
  let onVote: (LivePoll, String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let poll = events.poll, poll.isActive {
        Text(poll.title).font(.headline)
        if rewards.votedPollIDs.contains(poll.id) {
          Text("Vote submitted").foregroundStyle(.secondary)
        } else {
          ForEach(poll.choices) { choice in
            Button(choice.title) { onVote(poll, choice.id) }
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          Text("One free vote. No points spent.").font(.caption).foregroundStyle(.secondary)
        }
        Divider()
      } else {
        Text("No live poll").foregroundStyle(.secondary)
      }
    }
  }
}

private struct TwitchChannelRewardList: View {
  let points: TwitchChannelPoints?
  let onSelect: (TwitchChannelReward) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let points {
        if points.rewards.isEmpty {
          Text("No channel rewards available.").foregroundStyle(.secondary)
        }
        ForEach(points.rewards) { reward in
          Button {
            onSelect(reward)
          } label: {
            VStack(alignment: .leading, spacing: 5) {
              Text(reward.title).lineLimit(2)
              Text("\(reward.cost, format: .number) points").font(.caption)
              if !reward.isAvailable {
                Text("Unavailable").font(.caption)
              } else if reward.kind == .subOnlyMessage {
                Text("Available on Twitch").font(.caption)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .disabled(!reward.isAvailable || reward.cost > points.balance || reward.kind == .subOnlyMessage)
        }
      }
    }
  }
}

private struct TwitchRewardDetails: View {
  let reward: TwitchChannelReward
  let emotes: [TwitchRewardEmote]
  let onRedeem: (String, String?) -> Void
  @State private var message = ""
  @State private var emoteID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(reward.title).font(.headline)
      Text("\(reward.cost, format: .number) points")
      if let prompt = reward.prompt, !prompt.isEmpty {
        Text(prompt).font(.callout)
      }
      if reward.requiresInput {
        TextField("Message", text: $message)
        Text("\(message.utf16.count)/500").font(.caption).foregroundStyle(.secondary)
      }
      if reward.needsEmote {
        let eligible = reward.kind == .modifiedEmote ? emotes.flatMap(\.modifications) : emotes
        if eligible.isEmpty {
          Text("No eligible emotes available.").foregroundStyle(.secondary)
        }
        ForEach(eligible) { emote in
          Button {
            emoteID = emote.id
          } label: {
            HStack(spacing: 14) {
              CachedAsyncImage(url: URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(emote.id)/default/dark/2.0")) { image in
                image.resizable().scaledToFit()
              } placeholder: { ProgressView() }
                .frame(width: 48, height: 48)
              Text(emote.token)
              if emoteID == emote.id { Icon(glyph: .check, size: 22) }
            }
          }
        }
      }
      Button("Redeem") {
        onRedeem(message, emoteID)
      }
      .disabled(
        reward.requiresInput && (message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || message.utf16.count > 500)
          || reward.needsEmote && emoteID == nil)
    }
  }
}

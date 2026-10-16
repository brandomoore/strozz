import SwiftUI

struct ChannelFollowButton: View {
  let login: String
  let displayName: String
  let auth: TwitchAuthSession
  let rewards: TwitchWatchRewardsSession
  let follows: FollowedChannelsService
  @State private var model: TwitchChannelFollowModel
  @State private var showUnfollow = false
  @State private var showAccountNotice = false
  @State private var showConnection = false
  @State private var showError = false

  init(
    login: String, displayName: String, auth: TwitchAuthSession,
    rewards: TwitchWatchRewardsSession, follows: FollowedChannelsService,
    model: TwitchChannelFollowModel = TwitchChannelFollowModel()
  ) {
    self.login = login
    self.displayName = displayName
    self.auth = auth
    self.rewards = rewards
    self.follows = follows
    _model = State(initialValue: model)
  }

  private var context: TwitchChannelFollowModel.Context {
    .init(login: login, auth: auth)
  }

  private var title: LocalizedStringResource {
    if model.isFollowing == true { return "Following" }
    if model.isFollowing == nil, model.errorMessage != nil { return "Check follow status" }
    return "Follow"
  }

  var body: some View {
    Button(action: activate) {
      HStack(spacing: 8) {
        Icon(glyph: model.isFollowing == true ? .heartFilled : .heart, size: 22)
          .opacity(model.isBusy ? 0 : 1)
          .overlay {
            if model.isBusy { ProgressView().accessibilityLabel("Checking follow status") }
          }
        Text(title)
      }
    }
    .buttonStyle(.bordered)
    .accessibilityIdentifier("channel-follow")
    .accessibilityHint(model.isFollowing == true ? "Choose to unfollow this channel" : "Follow this channel on Twitch")
    // Keep the native button mounted and focusable while a request is running.
    .task(id: context) { await model.load(login: login, auth: auth) }
    .onChange(of: context) { _, _ in
      showUnfollow = false
      showAccountNotice = false
      showConnection = false
      showError = false
    }
    .onChange(of: model.errorMessage) { _, error in showError = error != nil }
    .confirmationDialog("Unfollow \(displayName)?", isPresented: $showUnfollow, titleVisibility: .visible) {
      Button("Unfollow", role: .destructive) { change(to: false) }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Twitch following", isPresented: $showAccountNotice) {
      if auth.isAuthenticated {
        Button("Connect Twitch Rewards") { showConnection = true }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if auth.isAuthenticated {
        Text("Following uses the same extra Twitch approval as rewards. This unofficial connection can stop working if Twitch changes its service.")
      } else {
        Text("Sign in to Twitch in Accounts to follow channels.")
      }
    }
    .alert("Could not update following", isPresented: $showError) {
      Button("Check status") { Task { await model.load(login: login, auth: auth) } }
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "")
    }
    #if os(tvOS)
    .fullScreenCover(isPresented: $showConnection) {
      TwitchWatchRewardsSignInView(session: rewards, userID: auth.userID ?? "")
    }
    #else
    .sheet(isPresented: $showConnection) {
      NavigationStack {
        Form { MobileWatchRewardsSettings() }
          .navigationTitle("Connect Twitch Rewards")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") { showConnection = false }
            }
          }
      }
      .environment(auth)
      .environment(rewards)
      .onChange(of: rewards.isConnected) { _, connected in
        if connected { showConnection = false }
      }
      .onDisappear { rewards.cancelConnection() }
    }
    #endif
  }

  private func activate() {
    guard !model.isBusy else { return }
    guard auth.isAuthenticated else {
      showAccountNotice = true
      return
    }
    guard model.isFollowing != nil else {
      Task { await model.load(login: login, auth: auth) }
      return
    }
    guard rewards.credential?.userID == auth.userID, rewards.isConnected else {
      showAccountNotice = true
      return
    }
    if model.isFollowing == true { showUnfollow = true }
    else { change(to: true) }
  }

  private func change(to following: Bool) {
    Task {
      await model.change(to: following, login: login, auth: auth, rewards: rewards, follows: follows)
    }
  }
}

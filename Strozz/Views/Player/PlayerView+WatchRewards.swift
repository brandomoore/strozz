import AVFoundation
import SwiftUI
import UIKit

extension PlayerView {
  func rewardsPresentation(_ content: some View) -> some View {
    content
      .disabled(showRewards)
      .overlay(alignment: .trailing) {
        if showRewards {
          TwitchChannelRewardsView(
            rewards: model.watchTracker.channelRewards,
            session: environment.watchRewards, events: hermes,
            onClose: closeRewards)
            .frame(width: 680)
            .padding(36)
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, palette.chromeColorScheme)
        }
      }
      .onChange(of: isUsingAltSource) { _, _ in
        if showRewards { closeRewards() }
        updateWatchRewards()
      }
      .onChange(of: isVOD) { _, _ in
        if showRewards { closeRewards() }
        updateWatchRewards()
      }
      .onChange(of: auth.userID) { _, _ in
        if showRewards { closeRewards() }
        updateWatchRewards()
      }
      .onChange(of: showStillWatching) { _, shown in
        if shown { showRewards = false }
      }
      .onChange(of: isSleeping) { _, sleeping in
        if sleeping { showRewards = false }
        updateWatchRewards()
      }
  }

  func closeRewards() {
    showRewards = false
    focus = isUsingAltSource || isVOD ? .quality : .rewards
    scheduleHide()
  }

  func monitorWatchRewards() async {
    while !Task.isCancelled {
      updateWatchRewards()
      do { try await Task.sleep(for: .seconds(1)) }
      catch { break }
    }
    model.watchTracker.stop()
  }

  func updateWatchRewards() {
    guard auth.isAuthenticated, let userID = auth.userID, let item = player.currentItem else {
      model.watchTracker.stop()
      return
    }
    let playback = TwitchWatchPlayback(
      target: .init(channel: activeChannel, userID: userID, itemID: ObjectIdentifier(item)),
      uptime: ProcessInfo.processInfo.systemUptime,
      playhead: item.currentTime().seconds,
      rate: Double(player.rate),
      ready: item.status == .readyToPlay && !isLoading && !isOffline
        && videoDecodeFrozenSince == nil,
      playing: player.timeControlStatus == .playing,
      twitchLive: !isVOD && !isUsingAltSource && liveVODHandoff?.isActive != true,
      foreground: UIApplication.shared.applicationState == .active && backgroundedAt == nil,
      visible: channelPageTarget == nil,
      userPaused: isUserPaused,
      seeking: isScrubbing || scrubTargetSeconds != nil || vodHandoffTransitionInFlight,
      sleeping: isSleeping,
      muted: player.isMuted || player.volume == 0)
    model.watchTracker.update(
      playback, session: environment.watchRewards, recorder: model.playbackTelemetry)
  }
}

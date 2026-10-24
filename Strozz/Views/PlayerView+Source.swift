import AVKit
import SwiftUI

extension PlayerView {
  var currentLiveTarget: PlatformLiveTarget {
    if isUsingAltSource {
      return PlatformLiveTarget(platform: .youtube, channel: youtubeAutoResolvedTarget)
    }
    return PlatformLiveTarget(
      platform: model.livePlatform,
      channel: model.livePlatform == .kick ? model.kickPlaybackTarget : activeChannel)
  }

  var livePlaybackHeaders: [String: String] { currentLiveTarget.headers }

  func initializeLiveSource() {
    guard !model.didInitializeLiveSource else { return }
    model.didInitializeLiveSource = true
    model.primaryPlatform = initialPlatform
    model.livePlatform = initialPlatform
    if initialPlatform == .kick { model.kickPlaybackTarget = channel }
  }

  func connectCurrentLiveChat() {
    chat.disconnect()
    if model.livePlatform == .kick {
      eventSub.stop()
      hermes.stop()
      model.watchTracker.stop()
      chat.youtubeMergeEnabled = false
      chat.configureExperimentalKickMerge(enabled: true, channelOrURL: model.kickPlaybackTarget)
    } else {
      applyExperimentalYouTubeSettings()
      applyExperimentalKickSettings()
      chat.connect(to: activeChannel)
      eventSub.start(forChannel: activeChannel, auth: auth)
      hermes.start(forChannel: activeChannel)
    }
  }

  func switchToKickSource(channel: String? = nil) {
    let manual = experimentalKickMergeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let input = channel ?? (manual.isEmpty ? kickMergeDefaultTarget : manual)
    let slug: String
    do { slug = try KickPlaybackService.slug(from: input) } catch {
      errorMessage = error.localizedDescription
      recordPlaybackEvent(
        "source_switch_failed", level: .error,
        attributes: PlaybackTelemetryRecorder.errorAttributes(error))
      return
    }
    guard model.livePlatform != .kick || model.kickPlaybackTarget != slug || isUsingAltSource else {
      return
    }
    recordPlaybackEvent("source_switch_started", attributes: ["to_source": "kick"])
    resetAltSourceWork()
    cancelNativeStartup()
    stopPlaybackWatchdog()
    stopRateController()
    model.channelMetadataTask?.cancel()
    model.nativeRefreshTask?.cancel()
    model.nativeRefreshTask = nil
    model.nativeGeneration = UUID()
    model.nativeHLS?.stop()
    model.nativeHLS = nil
    player.pause()
    replacePlaybackItem(with: nil)
    model.livePlatform = .kick
    model.kickPlaybackTarget = slug
    channelDisplayName = slug
    channelAvatarURL = nil
    streamTitle = ""
    model.channelStreamStartedAt = nil
    model.sourceQuality = "Auto"
    model.decodeRecoveryQualityID = nil
    model.triedDecodeRecovery = false
    model.nativeRecovery = NativePlaybackRecovery()
    isUsingAltSource = false
    altSourceStatus = nil
    playback = nil
    currentSourceURL = nil
    pinnedToLive = true
    isScrubbing = false
    resetVODHandoff()
    configurePlayerForLive()
    beginPlaybackTelemetry()
    connectCurrentLiveChat()
    model.channelMetadataTask = Task { await refreshChannelMetadata() }
    let generation = model.altRecovery.generation
    Task {
      guard generation == model.altRecovery.generation else { return }
      await load(reason: "switch to Kick")
    }
  }

  func loadCurrentStreamStatus(_ channel: String) async -> StreamLiveStatus {
    guard model.livePlatform == .kick else { return await model.loadStreamStatus(channel) }
    let target = currentLiveTarget
    do {
      return try await KickPlaybackService.channel(target.channel).isLive ? .live : .offline
    } catch {
      recordPlaybackEvent(
        "stream_status_failed", level: .warning,
        attributes: PlaybackTelemetryRecorder.errorAttributes(error))
      return .unknown
    }
  }
}

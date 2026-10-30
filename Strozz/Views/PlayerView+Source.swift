import AVKit
import SwiftUI

extension PlayerView {
  var currentLiveTarget: PlatformLiveTarget {
    if isUsingAltSource {
      return PlatformLiveTarget(platform: .youtube, channel: youtubeAutoResolvedTarget)
    }
    return PlatformLiveTarget(
      platform: model.livePlatform,
      channel: model.livePlatform == .kick ? model.kickPlaybackTarget
        : model.twitchPlaybackTarget.isEmpty ? activeChannel : model.twitchPlaybackTarget)
  }

  var livePlaybackHeaders: [String: String] { currentLiveTarget.headers }

  func initializeLiveSource() {
    guard !model.didInitializeLiveSource else { return }
    model.didInitializeLiveSource = true
    model.primaryPlatform = initialPlatform
    model.livePlatform = initialPlatform
    if initialPlatform == .kick { model.kickPlaybackTarget = channel }
    if initialPlatform == .twitch { model.twitchPlaybackTarget = channel }
  }

  func connectCurrentLiveChat() {
    let creator = model.creatorSession
    if creator.sources == nil {
      creator.start(.init(platform: initialPlatform, channel: activeChannel.isEmpty ? channel : activeChannel))
    }
    creator.resume()
    creator.selectVideo(currentLiveTarget)
    applyExperimentalYouTubeSettings()
    applyExperimentalKickSettings()
    synchronizeCreatorServices()
  }

  func synchronizeCreatorServices() {
    kickAutoResolvedTarget = model.creatorSession.sources?.kick ?? ""
    youtubeAutoResolvedTarget = model.creatorSession.sources?.youtube ?? ""
    if youtubeAutoResolvedTarget.isEmpty {
      youtubeSourceAvailable = false
      youtubeViewerCount = nil
    }
    let twitch = model.creatorSession.isActive && !isMultiviewCompact && !isVOD
      ? model.creatorSession.twitchChannel : nil
    guard model.eventSubChannel != twitch else { return }
    eventSub.stop()
    model.eventSubChannel = twitch
    if let twitch { eventSub.start(forChannel: twitch, auth: auth) }
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
    model.creatorSession.selectVideo(.init(platform: .kick, channel: slug))
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
    let target = currentLiveTarget
    if let update = model.creatorSession.twitchBroadcastStatus,
      update.target == target, update.reason == "twitch_event",
      (0..<10).contains(Date().timeIntervalSince(update.observedAt)) {
      return update.status
    }
    if target.platform == .twitch {
      let revision = model.creatorSession.hermes.broadcast.revision
      let status = await model.loadStreamStatus(target.channel)
      if revision != model.creatorSession.hermes.broadcast.revision {
        return model.creatorSession.hermes.broadcast.status
      }
      return status
    }
    guard target.platform == .kick else { return .unknown }
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

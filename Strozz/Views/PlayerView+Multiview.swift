import AVFoundation
import SwiftUI

struct MultiviewLoadRequest: Equatable {
  let reloadID: UUID?
  let browsing: Bool
}

extension PlayerView {
  var isMultiviewBrowsing: Bool { model.multiviewContext?.isBrowsing == true }

  var multiviewChannel: FollowedChannel {
    let target = currentLiveTarget
    var value = FollowedChannel(id: target.channel, login: target.channel,
      displayName: channelDisplayName.isEmpty ? target.channel : channelDisplayName,
      title: streamTitle, gameName: "", viewerCount: nil, thumbnailURL: posterURL,
      profileImageURL: channelAvatarURL, isLive: !isOffline)
    value.platform = target.platform
    return value
  }

  func suspendMultiviewForBrowsing() {
    model.multiviewContext?.needsBrowsingResume = true
    model.audioTakeoverTask?.cancel()
    model.channelMetadataTask?.cancel()
    model.watchTracker.stop()
    hideTask?.cancel()
    focusRecoveryTask?.cancel()
    multiviewFocusTask?.cancel()
    focus = nil
    trackpad.stop()
    model.creatorSession.suspend()
    eventSub.stop()
    model.eventSubChannel = nil
    captionController.stop()
    stopPlaybackWatchdog()
    stopLatencyMonitor(clearPlaybackIntent: false)
    resetAltSourceWork()
    suspendNativePlayback(reason: "multiview_browsing")
    player.pause()
  }

  func resumeMultiviewAfterBrowsingIfNeeded() -> Bool {
    guard let context = model.multiviewContext, context.needsBrowsingResume else { return false }
    context.needsBrowsingResume = false
    guard model.nativeNeedsRefresh || (isUsingAltSource && player.currentItem != nil) else { return false }
    if !isMultiviewCompact { connectCurrentLiveChat() }
    model.channelMetadataTask?.cancel()
    model.channelMetadataTask = Task { await refreshChannelMetadata() }
    resumePlaybackAfterAbsence(restoreLive: true)
    if !isMultiviewCompact {
      syncCaptions()
      focus = .video
    }
    return true
  }

  func usesDirectMultiviewVideoLayer(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    #if DEBUG
    return model.multiviewContext != nil && environment["STROZZ_MULTIVIEW_VIDEO_SURFACE"] == "layer"
    #else
    return false
    #endif
  }

  var isMultiviewCompact: Bool {
    model.multiviewContext.map { !$0.isExpanded } ?? false
  }

  func closePlayer() {
    if let context = model.multiviewContext { context.onClose?() }
    else { dismiss() }
  }

  func requestMultiviewFocus(_ target: Focusable) {
    guard !isMultiviewCompact else { return }
    multiviewFocusTask?.cancel()
    focus = nil
    multiviewFocusTask = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled, !isMultiviewCompact, !isQualityMenuPresented,
        target == .video ? !showControls : showControls else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { focus = target }
    }
  }

  func applyMultiviewBudget() {
    guard let context = model.multiviewContext, let item = player.currentItem else { return }
    let previousResolution = item.preferredMaximumResolution
    let previousBitrate = item.preferredPeakBitRate
    item.preferredMaximumResolution = context.qualityTier.maximumResolution
    item.preferredPeakBitRate = Double(context.qualityTier.targetBitrate)
    recordPlaybackEvent("multiview_budget_applied", metrics: [
      "previous_maximum_height": previousResolution.height,
      "previous_peak_bitrate_bps": previousBitrate,
      "preferred_maximum_width": item.preferredMaximumResolution.width,
      "preferred_maximum_height": item.preferredMaximumResolution.height,
      "preferred_peak_bitrate_bps": item.preferredPeakBitRate,
    ], flags: ["expanded": context.isExpanded])
    // Layout feedback should not wait for the periodic native catch-up tick.
    if let native = model.nativeHLS {
      let generation = model.nativeGeneration
      let tier = context.qualityTier
      Task { @MainActor in
        guard generation == model.nativeGeneration, context.qualityTier == tier,
          native === model.nativeHLS, item === player.currentItem else { return }
        await updateNativeResourceBudget(item: item, native: native)
      }
    }
  }

  func updateMultiviewPresentation() {
    guard let context = model.multiviewContext else { return }
    if isMultiviewCompact {
      multiviewFocusTask?.cancel()
      multiviewFocusTask = nil
      focusRecoveryTask?.cancel()
      focusRecoveryTask = nil
      hideTask?.cancel()
      hideTask = nil
      model.watchTracker.stop()
      trackpad.stop()
      model.creatorSession.suspend()
      eventSub.stop()
      model.eventSubChannel = nil
      captionController.stop()
      showControls = false
      showChatSettings = false
      showRewards = false
      focus = nil
      if !isUsingAltSource, !isVOD, context.quality != "Auto" {
        preferredQuality = "Auto"
        applyQualityPreference("Auto")
      }
    } else {
      goLive?.suppressedLogin = activeChannel
      trackpad.start()
      connectCurrentLiveChat()
      model.channelMetadataTask?.cancel()
      model.channelMetadataTask = Task {
        await refreshChannelMetadata()
        if streamRewindEnabled { await resolveBroadcastVODIfNeeded() }
        if model.primaryPlatform == .twitch {
          await refreshYouTubeAutoTarget()
          await refreshYouTubeSourceAvailability()
          await refreshKickAutoTarget()
        }
      }
      syncCaptions()
      showControls = false
      requestMultiviewFocus(.video)
    }
    applyMultiviewBudget()
  }
}

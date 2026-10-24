import AVFoundation
import SwiftUI

extension PlayerView {
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

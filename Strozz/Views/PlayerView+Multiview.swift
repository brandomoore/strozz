import AVFoundation
import SwiftUI

extension PlayerView {
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
    item.preferredMaximumResolution = context.qualityTier.maximumResolution
    item.preferredPeakBitRate = Double(context.qualityTier.targetBitrate)
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
      chat.disconnect()
      eventSub.stop()
      hermes.stop()
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
      chat.connect(to: activeChannel)
      eventSub.start(forChannel: activeChannel, auth: auth)
      hermes.start(forChannel: activeChannel)
      model.channelMetadataTask?.cancel()
      model.channelMetadataTask = Task {
        await refreshChannelMetadata()
        if streamRewindEnabled { await resolveBroadcastVODIfNeeded() }
        await refreshYouTubeAutoTarget()
        await refreshYouTubeSourceAvailability()
        await refreshKickAutoTarget()
      }
      syncCaptions()
      showControls = false
      requestMultiviewFocus(.video)
    }
    applyMultiviewBudget()
  }
}

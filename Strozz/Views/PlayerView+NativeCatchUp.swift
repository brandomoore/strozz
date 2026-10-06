import AVFoundation
import Foundation

extension PlayerView {
  var allowsNativeCatchUp: Bool {
    model.isUsingNativeHLS && !model.nativeNeedsRefresh && !isVOD && !isUsingAltSource
      && !isLoading && !isOffline && errorMessage == nil && !isRecoveringPlayback
      && didRequestPlayback && model.startupProgress.hasStarted
      && model.nativeStartupComplete
      && wallClockLowConfidenceStreak < wallClockUnavailableSamples
      && pinnedToLive && shouldPlayAltSource && scrubTargetSeconds == nil
      && !vodHandoffTransitionInFlight && !model.livePlaybackReturn.isAway
  }

  /// Restore only our own rate on the same, still-playing item. A pause, buffering
  /// wait or a newer playback owner must never be resumed by cleanup.
  func cancelNativeCatchUp(reason: String) {
    let previousRate = model.nativeCatchUpAppliedRate
    if let owner = model.nativeCatchUpItem, owner === player.currentItem,
      player.timeControlStatus == .playing, previousRate > 1,
      abs(player.rate - previousRate) < 0.001 {
      player.rate = 1
    }
    model.nativeCatchUp.interrupt(at: ProcessInfo.processInfo.systemUptime)
    model.nativeCatchUpAppliedRate = 1
    model.nativeCatchUpItem = nil
    if previousRate > 1 {
      recordPlaybackEvent("native_catch_up_rate_stopped", attributes: ["reason": reason])
    }
  }

  func updateNativeCatchUp() async {
    if model.isUsingNativeHLS, model.startupProgress.hasStarted {
      player.currentItem?.automaticallyPreservesTimeOffsetFromLive = false
    }
    guard allowsNativeCatchUp, let item = player.currentItem, let native = model.nativeHLS else {
      cancelNativeCatchUp(reason: "playback_intent")
      return
    }
    let generation = model.nativeGeneration
    let intent = model.nativePositionIntent
    let target = await native.origin.liveTargetDate()
    guard !Task.isCancelled, allowsNativeCatchUp, native === model.nativeHLS,
      generation == model.nativeGeneration, intent == model.nativePositionIntent,
      item === player.currentItem else { return }
    let rate = model.nativeCatchUp.observe(.init(
      uptime: ProcessInfo.processInfo.systemUptime, clock: item.currentTime().seconds,
      playbackDate: item.currentDate(), targetDate: target,
      rendition: computeResolvedQualityName(),
      isPlaying: player.timeControlStatus == .playing,
      buffer: bufferAheadSeconds(item) ?? 0, allowed: allowsNativeCatchUp,
      hasFreshVideo: model.playbackTelemetry.videoFrameAge.map { $0 < 4 } ?? false,
      playbackRate: player.rate, normalOffset: model.chatSyncBaseline.nativeCushion ?? 0))
    applyNativeCatchUpRate(rate, item: item)
  }

  func applyNativeCatchUpRate(_ rate: Float, item: AVPlayerItem) {
    guard allowsNativeCatchUp, item === player.currentItem,
      player.timeControlStatus == .playing, player.rate > 0,
      rate.isFinite, (1...NativeLiveCatchUp.maximumRate).contains(rate) else { return }
    if rate > 1, model.nativeCatchUpItem === item, model.nativeCatchUpAppliedRate == rate {
      return
    }
    guard abs(player.rate - rate) >= 0.005 else {
      if rate == 1 {
        model.nativeCatchUpItem = nil
        model.nativeCatchUpAppliedRate = 1
      }
      return
    }
    model.nativeCatchUpItem = rate > 1 ? item : nil
    model.nativeCatchUpAppliedRate = rate
    player.rate = rate
    recordPlaybackEvent("native_catch_up_rate_changed", metrics: [
      "rate": Double(rate),
      "excess_seconds": model.nativeCatchUp.extraDelay ?? 0,
      "buffer_ahead_seconds": bufferAheadSeconds(item) ?? 0
    ])
  }
}

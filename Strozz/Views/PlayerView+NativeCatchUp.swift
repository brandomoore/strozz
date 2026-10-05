import AVFoundation
import Foundation

extension PlayerView {
  var allowsNativeCatchUp: Bool {
    model.isUsingNativeHLS && !model.nativeNeedsRefresh && !isVOD && !isUsingAltSource
      && !isLoading && !isOffline && errorMessage == nil && !isRecoveringPlayback
      && didRequestPlayback && model.startupProgress.hasStarted
      && pinnedToLive && shouldPlayAltSource && scrubTargetSeconds == nil
      && !vodHandoffTransitionInFlight && !model.livePlaybackReturn.isAway
  }

  /// Invalidates the owner before cancelling AVPlayer, whose completion may run
  /// afterward. Only our own pending item's seek is cancelled.
  func cancelNativeCatchUp(reason: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    let request = model.nativeCatchUp.inFlight
    model.nativeCatchUp.interrupt(at: now)
    model.nativeCatchUpTask?.cancel()
    model.nativeCatchUpTask = nil
    model.nativeCatchUpItem?.cancelPendingSeeks()
    model.nativeCatchUpItem = nil
    if request != nil {
      recordPlaybackEvent("native_catch_up_cancelled", attributes: ["reason": reason])
    }
  }

  func updateNativeCatchUp() async {
    let now = ProcessInfo.processInfo.systemUptime
    guard allowsNativeCatchUp, let item = player.currentItem, let native = model.nativeHLS else {
      cancelNativeCatchUp(reason: "playback_intent", now: now)
      return
    }
    if model.nativeCatchUp.inFlight != nil {
      if model.nativeCatchUp.timedOut(at: now) {
        cancelNativeCatchUp(reason: "timeout", now: now)
        resetPlaybackHealth()
      }
      return
    }
    let generation = model.nativeGeneration
    let intent = model.nativePositionIntent
    let target = await native.origin.liveTargetDate()
    guard !Task.isCancelled, allowsNativeCatchUp, native === model.nativeHLS,
      generation == model.nativeGeneration, intent == model.nativePositionIntent,
      item === player.currentItem else { return }
    let request = model.nativeCatchUp.observe(.init(
      uptime: ProcessInfo.processInfo.systemUptime, clock: item.currentTime().seconds,
      playbackDate: item.currentDate(), targetDate: target,
      rendition: computeResolvedQualityName(),
      isPlaying: player.timeControlStatus == .playing,
      buffer: bufferAheadSeconds(item) ?? 0, allowed: allowsNativeCatchUp))
    guard let request else { return }
    model.nativeCatchUpItem = item
    model.nativeCatchUpTask = Task { @MainActor in
      guard !Task.isCancelled, model.nativeCatchUp.inFlight?.id == request.id,
        allowsNativeCatchUp, native === model.nativeHLS, item === player.currentItem,
        generation == model.nativeGeneration, intent == model.nativePositionIntent,
        player.timeControlStatus == .playing, (bufferAheadSeconds(item) ?? 0) >= 1,
        let before = item.currentDate(),
        request.target.timeIntervalSince(before) >= NativeLiveCatchUp.minimumExcessSeconds else {
        if model.nativeCatchUp.inFlight?.id == request.id {
          cancelNativeCatchUp(reason: "no_longer_needed")
        }
        return
      }
      resetPlaybackHealth()
      item.automaticallyPreservesTimeOffsetFromLive = true
      recordPlaybackEvent("native_catch_up_started",
        metrics: ["excess_seconds": request.target.timeIntervalSince(before)])
      let finished = await item.seek(to: request.target)
      guard !Task.isCancelled, item === player.currentItem, native === model.nativeHLS,
        generation == model.nativeGeneration, intent == model.nativePositionIntent,
        model.nativeCatchUp.finish(request.id, at: ProcessInfo.processInfo.systemUptime) else { return }
      model.nativeCatchUpTask = nil
      model.nativeCatchUpItem = nil
      resetPlaybackHealth()
      recordPlaybackEvent("native_catch_up_completed",
        metrics: ["duration_seconds": ProcessInfo.processInfo.systemUptime - request.startedAt],
        flags: ["finished": finished])
      // Seeking preserves AVPlayer's requested rate. Do not issue a play command
      // here: a pause or source change that happened meanwhile owns playback.
    }
  }
}

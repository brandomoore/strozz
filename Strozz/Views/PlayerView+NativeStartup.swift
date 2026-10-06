import AVFoundation
import Foundation

extension PlayerView {
  func cancelNativeStartup() {
    model.nativeStartupTask?.cancel()
    model.nativeStartupTask = nil
    model.nativeStartupItem?.cancelPendingSeeks()
    model.nativeStartupItem = nil
  }

  /// Position the new native item before showing video. This is not a drift
  /// correction: once presented, the same item catches up only by held rate.
  func startNativePlaybackAtLiveEdge() {
    guard model.nativeStartupTask == nil, let item = player.currentItem,
      model.isUsingNativeHLS, !model.nativeStartupComplete, shouldPlayAltSource else { return }
    let generation = model.nativeGeneration
    let intent = model.nativePositionIntent
    model.nativeStartupItem = item
    isLoading = true
    // AVPlayer does not publish a live seekable range until preparation starts.
    // The loading surface remains up until the owned alignment below completes.
    player.play()
    model.nativeStartupTask = Task { @MainActor in
      defer {
        if model.nativeStartupItem === item {
          model.nativeStartupItem = nil
          model.nativeStartupTask = nil
        }
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(startupPlaybackTimeoutSeconds))
      while item.status != .readyToPlay || item.seekableTimeRanges.isEmpty || !model.startupProgress.hasStarted {
        guard nativeStartupIsCurrent(item, generation: generation, intent: intent) else { return }
        if item.status == .failed {
          recoverNativeHLS(.unavailable)
          return
        }
        if ContinuousClock.now >= deadline {
          recoverNativeHLS(.timeout)
          return
        }
        model.startupProgress.observe(clock: item.currentTime().seconds,
          isPlaying: player.timeControlStatus == .playing, now: ProcessInfo.processInfo.systemUptime)
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      }
      guard nativeStartupIsCurrent(item, generation: generation, intent: intent) else { return }
      let target = await model.nativeHLS?.origin.liveTargetDate()
      let sourceBuffer = await model.nativeHLS?.origin.snapshot().forwardBuffer
      guard nativeStartupIsCurrent(item, generation: generation, intent: intent) else { return }
      if let sourceBuffer {
        item.preferredForwardBufferDuration = max(activeLivePlaybackPolicy.preferredForwardBufferDuration, sourceBuffer)
      }
      if let target, let displayed = item.currentDate(),
        target.timeIntervalSince(displayed) <= NativeLiveCatchUp.startupToleranceSeconds {
        item.automaticallyPreservesTimeOffsetFromLive = false
        model.nativeStartupComplete = true
        recordPlaybackEvent("native_startup_already_live")
        model.revealPlaybackIfStarted()
        return
      }
      let offset = item.recommendedTimeOffsetFromLive
      if offset.seconds.isFinite, offset.seconds >= 0 { item.configuredTimeOffsetFromLive = offset }
      item.automaticallyPreservesTimeOffsetFromLive = false
      recordPlaybackEvent("native_startup_alignment_started")
      let timeout = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        guard model.nativeStartupItem === item else { return }
        item.cancelPendingSeeks()
      }
      let positioned = await item.seek(to: CMTime.positiveInfinity,
                                      toleranceBefore: .zero, toleranceAfter: .zero)
      timeout.cancel()
      guard nativeStartupIsCurrent(item, generation: generation, intent: intent) else { return }
      guard positioned else {
        recoverNativeHLS(.timeout)
        return
      }
      model.nativeStartupComplete = true
      recordPlaybackEvent("native_startup_alignment_completed")
      if player.timeControlStatus != .playing { player.play() }
      model.revealPlaybackIfStarted()
    }
  }

  func nativeStartupIsCurrent(_ item: AVPlayerItem, generation: UUID, intent: UUID) -> Bool {
    !Task.isCancelled && model.nativeStartupItem === item && player.currentItem === item
      && generation == model.nativeGeneration && intent == model.nativePositionIntent
      && model.isUsingNativeHLS && !model.nativeNeedsRefresh && !isVOD && !isUsingAltSource
      && !isOffline && pinnedToLive && shouldPlayAltSource
  }
}

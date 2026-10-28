import AVFoundation
import Foundation

extension PlayerView {
  func recordAudioPlaybackState(reason: String) {
    guard model.playbackTelemetry.sessionID != nil else { return }
    let session = AVAudioSession.sharedInstance()
    let item = player.currentItem
    var counters: [String: Int] = ["native_restart_serial": model.nativeRestartSerial]
    if let item, item.status == .readyToPlay {
      let audio = model.playbackTelemetry.measure("audio_state_tracks") {
        item.tracks.filter { $0.assetTrack?.mediaType == .audio }
      }
      counters["audio_track_count"] = audio.count
      counters["enabled_audio_track_count"] = audio.filter(\.isEnabled).count
    }
    var metrics: [String: Double] = [
      "player_rate": Double(player.rate), "player_volume": Double(player.volume),
      "audio_output_volume": Double(session.outputVolume),
    ]
    metrics["buffer_ahead_seconds"] = item.flatMap(bufferAheadSeconds)
    recordPlaybackEvent("audio_playback_state", attributes: [
      "reason": reason,
      "audio_output_ports": session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","),
      "audio_session_category": session.category.rawValue,
      "audio_session_mode": session.mode.rawValue,
    ], metrics: metrics, counters: counters, flags: [
      "player_muted": player.isMuted, "user_paused": isUserPaused,
      "playback_requested": didRequestPlayback,
      "audio_interrupted": model.audioInterrupted,
      "audio_session_activation_failed": model.audioSessionActivationFailed,
      "media_services_unavailable": model.mediaServicesUnavailable,
      "native_needs_refresh": model.nativeNeedsRefresh,
      "video_presentation_visible": model.isVideoPresentationVisible,
    ])
  }

  @discardableResult
  func preparePlaybackAudio(reason: String) -> Bool {
    guard !model.audioInterrupted, !model.mediaServicesUnavailable, !model.multiviewSleepSuspended,
      backgroundedAt == nil, !isMultiviewBrowsing else { return false }
    recordAudioPlaybackState(reason: "before_audio_activation:\(reason)")
    do {
      try model.activateAudioSession()
      if model.audioSessionActivationFailed { errorMessage = nil }
      model.audioSessionActivationFailed = false
      recordPlaybackEvent("audio_session_activated", attributes: ["reason": reason])
      recordAudioPlaybackState(reason: "after_audio_activation:\(reason)")
      if !player.isMuted, player.volume > 0 {
        NotificationCenter.default.post(name: PlaybackAudioSession.audiblePlayerActivated, object: player)
      }
      return true
    } catch {
      model.audioSessionActivationFailed = true
      player.pause()
      isLoading = false
      errorMessage = String(localized: "Couldn't start audio playback. Please try again.")
      recordPlaybackEvent("audio_session_activation_failed", level: .error,
        attributes: PlaybackTelemetryRecorder.errorAttributes(error)
          .merging(["reason": reason]) { _, new in new })
      recordAudioPlaybackState(reason: "failed_audio_activation:\(reason)")
      return false
    }
  }

  func handleAudioInterruption(_ notification: Notification) {
    guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
    switch type {
    case .began:
      guard !model.audioInterrupted else { return }
      let reclaimStartup = isLoading && didRequestPlayback && !isUserPaused
        && !model.startupAudioClaimUsed && (model.startupAudioClaimUntil.map { $0 > Date() } ?? false)
        && !player.isMuted && player.volume > 0
      model.audioInterrupted = true
      cancelNativeStartup()
      cancelNativeCatchUp(reason: "audio_interruption")
      player.pause()
      resetPlaybackHealth()
      updateWatchRewards()
      recordPlaybackEvent("audio_interruption_began")
      if reclaimStartup {
        model.startupAudioClaimUsed = true
        let item = player.currentItem
        model.audioTakeoverTask = Task { @MainActor in
          defer {
            if !Task.isCancelled {
              model.audioTakeoverTask = nil
              if model.audioInterrupted, backgroundedAt == nil { showAudioInterruptionRecovery() }
            }
          }
          do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
          guard !Task.isCancelled, model.audioInterrupted, item === player.currentItem,
            !isUserPaused, backgroundedAt == nil, !isSleeping, channelPageTarget == nil,
            !model.mediaServicesUnavailable, !model.multiviewSleepSuspended else { return }
          resumeAfterAudioInterruption()
        }
      } else {
        showAudioInterruptionRecovery()
      }
    case .ended:
      let reclaimingSelection = model.audioTakeoverTask != nil
      model.audioTakeoverTask?.cancel()
      model.audioTakeoverTask = nil
      guard model.audioInterrupted else { return }
      model.audioInterrupted = false
      errorMessage = nil
      let options = AVAudioSession.InterruptionOptions(
        rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      if !options.contains(.shouldResume), !reclaimingSelection {
        isUserPaused = true
        isLoading = false
      }
      recordPlaybackEvent("audio_interruption_ended",
        flags: ["should_resume": options.contains(.shouldResume)])
      resumePlaybackAfterAbsence(restoreLive: false)
    @unknown default:
      recordPlaybackEvent("audio_interruption_unknown", level: .warning)
    }
  }

  private func showAudioInterruptionRecovery() {
    isLoading = false
    showChatSettings = false
    showRewards = false
    errorMessage = String(localized: "Playback was interrupted. Resume to use Strozz audio.")
  }

  func resumeMutedPaneAfterAudioActivation() {
    guard model.multiviewContext != nil, player.isMuted, model.audioInterrupted,
      !isUserPaused, !isSleeping, !model.mediaServicesUnavailable, !model.multiviewSleepSuspended,
      backgroundedAt == nil, channelPageTarget == nil else { return }
    model.audioInterrupted = false
    errorMessage = nil
    recordPlaybackEvent("audio_interruption_reclaimed", attributes: ["reason": "audible_multiview_owner"])
    resumePlaybackAfterAbsence(restoreLive: false)
  }

  func resumeAfterAudioInterruption() {
    guard model.audioInterrupted, backgroundedAt == nil, !isSleeping,
      !model.mediaServicesUnavailable, !model.multiviewSleepSuspended, channelPageTarget == nil else { return }
    isUserPaused = false
    model.audioInterrupted = false
    errorMessage = nil
    recordPlaybackEvent("audio_interruption_reclaimed",
      attributes: ["reason": model.audioTakeoverTask == nil ? "user_resume" : "selected_stream_startup"])
    resumePlaybackAfterAbsence(restoreLive: false)
  }

  func handleMediaServicesLost() {
    model.mediaServicesUnavailable = true
    recordPlaybackEvent("media_services_lost", level: .warning)
    invalidateMediaServicesPlayback()
  }

  func handleMediaServicesReset(
    resolve: (@MainActor () async throws -> StreamPlayback)? = nil
  ) {
    model.mediaServicesUnavailable = false
    model.audioInterrupted = false
    recordPlaybackEvent("media_services_reset", level: .warning)
    invalidateMediaServicesPlayback()
    recoverMediaServicesIfNeeded(resolve: resolve)
  }

  private func invalidateMediaServicesPlayback() {
    model.audioTakeoverTask?.cancel()
    model.audioTakeoverTask = nil
    guard player.currentItem != nil || model.nativeNeedsRefresh else { return }
    model.mediaServicesResetPending = true
    cancelNativeStartup()
    cancelNativeCatchUp(reason: "media_services_reset")
    if model.isUsingNativeHLS, !model.nativeNeedsRefresh {
      model.nativeRestartSerial += 1
      suspendNativePlayback(reason: "media_services_reset")
    }
    player.pause()
    resetPlaybackHealth()
  }

  func recoverMediaServicesIfNeeded(
    resolve: (@MainActor () async throws -> StreamPlayback)? = nil
  ) {
    guard model.mediaServicesResetPending, !model.mediaServicesUnavailable,
      !model.audioInterrupted, !isOffline, !isSleeping, backgroundedAt == nil,
      channelPageTarget == nil, !model.livePlaybackReturn.isAway, !isMultiviewBrowsing else { return }
    if model.isUsingNativeHLS {
      // A source retry already in flight will also replace its orphaned player.
      guard model.nativeRefreshTask == nil else { return }
      refreshNativeAfterSuspension(reason: "media_services_reset", resolve: resolve)
      return
    }
    guard let oldItem = player.currentItem else { return }
    guard let url = currentSourceURL else {
      errorMessage = String(localized: "Couldn't restart playback. Please reopen the stream.")
      isLoading = false
      recordPlaybackEvent("media_services_recovery_failed", level: .error,
        attributes: ["reason": "missing_source"])
      return
    }
    let date = (!pinnedToLive || isUserPaused) && !isVOD ? oldItem.currentDate() : nil
    let time = isVOD ? oldItem.currentTime() : nil
    model.beginPlaybackLoad()
    rebuildPlaybackPlayer(reason: "media_services_reset", isFailure: false)
    model.mediaServicesResetPending = false
    let item: AVPlayerItem
    if isVOD {
      item = AVPlayerItem(asset: AVURLAsset(url: url,
        options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]))
    } else {
      item = isUsingAltSource ? makeAltSourceItem(url: url) : makeItem(url: url)
    }
    replacePlaybackItem(with: item)
    if isVOD { installVODTimeObserver() }
    let generation = model.nativeGeneration
    let intent = model.nativePositionIntent
    model.fallbackRestoreTask = Task { @MainActor in
      if let date {
        await restoreNativePosition(date, item: item, generation: generation, intent: intent)
      } else if let time, time.seconds.isFinite, time.seconds > 0 {
        await restoreMediaServicesPosition(time, item: item, intent: intent)
      } else if canResumeFallback(item: item, generation: generation) {
        resumePlayback()
      }
      if item === player.currentItem, isUserPaused { isLoading = false }
    }
  }

  private func restoreMediaServicesPosition(
    _ time: CMTime, item: AVPlayerItem, intent: UUID
  ) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while item.status == .unknown, item.seekableTimeRanges.isEmpty, ContinuousClock.now < deadline {
      guard !Task.isCancelled, item === player.currentItem,
        intent == model.nativePositionIntent else { return }
      do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
    }
    guard !Task.isCancelled, item === player.currentItem,
      intent == model.nativePositionIntent else { return }
    let timeout = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard item === player.currentItem else { return }
      item.cancelPendingSeeks()
    }
    let restored = item.status == .readyToPlay || !item.seekableTimeRanges.isEmpty
      ? await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) : false
    timeout.cancel()
    guard !Task.isCancelled, item === player.currentItem,
      intent == model.nativePositionIntent else { return }
    guard restored else {
      errorMessage = String(localized: "Couldn't restore the previous playback position. Please try again.")
      isLoading = false
      recordPlaybackEvent("media_services_position_restore_failed", level: .error)
      return
    }
    recordPlaybackEvent("media_services_position_restored")
    if shouldPlayAltSource { resumePlayback() }
  }
}

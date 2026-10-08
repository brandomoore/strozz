import AVFoundation
import Foundation

extension PlayerView {
  private var playbackTelemetrySource: String {
    if isUsingAltSource { return "youtube" }
    if liveVODHandoff?.isActive == true { return "twitch_vod_handoff" }
    if isVOD { return "vod" }
    return "twitch"
  }

  private var playbackTelemetryContext: [String: String] {
    var attributes: [String: String] = [
      "source": model.playbackTelemetry.source,
      "quality": preferredQuality,
      "playback_profile": livePlaybackProfile.rawValue,
    ]
    if let context = model.multiviewContext {
      attributes["presentation"] = context.isExpanded ? "expanded" : "multiview"
      attributes["quality_budget"] = switch context.qualityTier {
      case .source: "source"
      case .grid: "grid"
      case .thumbnail: "thumbnail"
      }
    } else {
      attributes["presentation"] = "standalone"
    }
    if (player.currentItem?.presentationSize.width ?? 0) > 0, let resolvedQualityName {
      attributes["resolved_quality"] = resolvedQualityName
    }
    attributes["asset_host"] = PlaybackTelemetryRecorder.host(
      (player.currentItem?.asset as? AVURLAsset)?.url.absoluteString)
    return attributes
  }

  func beginPlaybackTelemetry() {
    lowLatencyProxy.resetTelemetry()
    model.playbackTelemetry.beginSession(
      channel: activeChannel,
      playbackMode: vod == nil ? "live" : "vod",
      attributes: playbackTelemetryContext,
      flags: [
        "low_latency_proxy_enabled": lowLatencyProxyEnabled,
        "stream_rewind_enabled": streamRewindEnabled,
        "prefer_youtube_source": preferYouTubeSource,
      ]
    )
    startPlaybackTelemetrySampling()
  }

  func startPlaybackTelemetrySampling() {
    model.playbackTelemetryTask?.cancel()
    recordPlaybackTelemetrySnapshot()
    model.playbackTelemetryTask = Task { @MainActor [self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        recordPlaybackTelemetrySnapshot()
      }
    }
  }

  func stopPlaybackTelemetry(reason: String) {
    recordPlaybackTelemetrySnapshot()
    model.playbackTelemetryTask?.cancel()
    model.playbackTelemetryTask = nil
    model.playbackTelemetry.endSession(reason: reason)
  }

  func recordPlaybackEvent(
    _ name: String,
    level: PlaybackTelemetryLevel = .info,
    attributes: [String: String] = [:],
    metrics: [String: Double] = [:],
    counters: [String: Int] = [:],
    flags: [String: Bool] = [:]
  ) {
    model.playbackTelemetry.trackItem(player.currentItem, source: playbackTelemetrySource)
    model.playbackTelemetry.recordEvent(
      name,
      level: level,
      attributes: playbackTelemetryContext.merging(attributes) { _, new in new },
      metrics: metrics,
      counters: counters,
      flags: flags
    )
  }

  func recordPlaybackTelemetrySnapshot() {
    model.playbackTelemetry.trackItem(player.currentItem, source: playbackTelemetrySource)
    model.playbackTelemetry.recordItemLogs()
    var snapshot = PlaybackTelemetrySnapshot()
    snapshot.attributes = playbackTelemetryContext
    snapshot.attributes["item_status"] = telemetryItemStatus(player.currentItem?.status)
    snapshot.attributes["player_status"] = String(player.status.rawValue)
    if let error = player.error {
      snapshot.attributes.merge(PlaybackTelemetryRecorder.errorAttributes(error)) { _, new in new }
    }
    snapshot.attributes["time_control_status"] = telemetryTimeControlStatus()
    snapshot.attributes["waiting_reason"] = diagWaitingReasonDescription()
    snapshot.attributes["thermal_state"] = telemetryThermalState()

    snapshot.metrics["player_rate"] = Double(player.rate)
    snapshot.metrics["player_volume"] = Double(player.volume)
    snapshot.flags["player_muted"] = player.isMuted
    snapshot.flags["audio_interrupted"] = model.audioInterrupted
    snapshot.flags["audio_session_activation_failed"] = model.audioSessionActivationFailed
    snapshot.flags["media_services_unavailable"] = model.mediaServicesUnavailable
    snapshot.flags["media_services_reset_pending"] = model.mediaServicesResetPending
    snapshot.flags["external_playback_active"] = player.isExternalPlaybackActive
    let audioSession = AVAudioSession.sharedInstance()
    snapshot.attributes["audio_session_category"] = audioSession.category.rawValue
    snapshot.attributes["audio_session_mode"] = audioSession.mode.rawValue
    snapshot.attributes["audio_output_ports"] = audioSession.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
    snapshot.flags["other_audio_playing"] = audioSession.isOtherAudioPlaying
    let outputVolume = Double(audioSession.outputVolume)
    if outputVolume.isFinite { snapshot.metrics["audio_output_volume"] = outputVolume }
    if let item = player.currentItem, item.status == .readyToPlay {
      let audioTracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
      snapshot.counters["audio_track_count"] = audioTracks.count
      snapshot.counters["enabled_audio_track_count"] = audioTracks.filter(\.isEnabled).count
    }
    snapshot.metrics["preferred_forward_buffer_seconds"] =
      player.currentItem?.preferredForwardBufferDuration ?? 0
    if let item = player.currentItem {
      snapshot.metrics["preferred_peak_bitrate_bps"] = item.preferredPeakBitRate
      snapshot.metrics["preferred_maximum_width"] = item.preferredMaximumResolution.width
      snapshot.metrics["preferred_maximum_height"] = item.preferredMaximumResolution.height
      let offset = item.configuredTimeOffsetFromLive.seconds
      if offset.isFinite { snapshot.metrics["configured_live_offset_seconds"] = offset }
      let recommended = item.recommendedTimeOffsetFromLive.seconds
      if recommended.isFinite { snapshot.metrics["recommended_live_offset_seconds"] = recommended }
      snapshot.flags["automatically_preserves_live_offset"] = item.automaticallyPreservesTimeOffsetFromLive
    }
    if isVOD {
      snapshot.metrics["desired_vod_rate"] = Double(vodPlaybackRate)
    } else if !isUsingAltSource {
      snapshot.metrics["desired_live_rate"] = Double(model.isUsingNativeHLS
        ? model.nativeCatchUp.rate : desiredLivePlaybackRate(policy: activeLivePlaybackPolicy))
    }

    snapshot.flags["loading"] = isLoading
    snapshot.flags["offline"] = isOffline
    snapshot.flags["playback_active"] = player.currentItem != nil && isPlaybackActive
    snapshot.flags["playback_requested"] = player.currentItem != nil && didRequestPlayback
    snapshot.flags["user_paused"] = isUserPaused
    snapshot.flags["scrubbing"] = isScrubbing || scrubTargetSeconds != nil
    snapshot.flags["background"] = backgroundedAt != nil
    snapshot.flags["pinned_to_live"] = pinnedToLive
    snapshot.flags["recovering"] = isRecoveringPlayback || model.altRecoveryTask != nil
    snapshot.flags["stream_unstable"] = isStreamUnstable
    snapshot.flags["decode_frozen"] = videoDecodeFrozenSince.map {
      Date().timeIntervalSince($0) >= 4
    } ?? false
    snapshot.flags["video_output_observed"] = model.playbackTelemetry.videoFrameAge != nil
    snapshot.metrics["video_frame_age_seconds"] = model.playbackTelemetry.videoFrameAge
    snapshot.flags["using_alt_source"] = isUsingAltSource
    snapshot.flags["native_ll_hls"] = model.isUsingNativeHLS
    snapshot.flags["native_startup_complete"] = model.nativeStartupComplete
    snapshot.flags["playback_date_mapping_valid"] = wallClockLowConfidenceStreak < wallClockUnavailableSamples
    snapshot.flags["native_catch_up_active"] = model.nativeCatchUp.isActive
    snapshot.flags["latency_readout_enabled"] = showLatencyBadge
    snapshot.metrics["native_live_edge_delay_seconds"] = model.chatSyncBaseline.liveEdgeDelay
    snapshot.metrics["native_catch_up_rate"] = Double(model.nativeCatchUp.rate)
    snapshot.metrics["native_catch_up_excess_seconds"] = model.nativeCatchUp.extraDelay
    snapshot.counters["native_parts_indexed"] = model.nativeParts
    snapshot.metrics["native_live_hold_back_seconds"] = model.nativeLiveHoldBack
    snapshot.metrics["native_source_edge_age_seconds"] = model.nativeSourceEdgeAge
    snapshot.metrics["native_report_refresh_seconds"] = model.nativeReportRefreshSeconds
    snapshot.metrics["native_report_refresh_max_seconds"] = model.nativeReportRefreshMaxSeconds
    snapshot.flags["native_source_has_prefetch"] = model.nativeSourceHasPrefetch
    snapshot.attributes["native_fallback"] = model.nativeFallbackReason
    if let native = model.nativeHLS {
      Task { @MainActor in
        let stats = await native.origin.snapshot()
        guard model.nativeHLS === native else { return }
        model.nativeParts = stats.parts
        model.nativeLiveHoldBack = stats.holdBack
        model.nativeSourceHasPrefetch = stats.hasPrefetch
        model.nativeSourceEdgeAge = stats.edgeAge
        model.nativeReportRefreshSeconds = stats.reportRefreshSeconds
        model.nativeReportRefreshMaxSeconds = stats.reportRefreshMaxSeconds
      }
    }
    snapshot.attributes["watch_rewards_state"] = model.watchTracker.state.rawValue
    snapshot.counters["watch_rewards_reports_accepted"] = model.watchTracker.acceptedReports
    snapshot.counters["watch_rewards_streak"] = model.watchTracker.streak
    snapshot.counters["watch_rewards_observed_increases"] = model.watchTracker.observedStreakIncreases
    snapshot.flags["low_latency_proxy_enabled"] = lowLatencyProxyEnabled
    snapshot.flags["stream_rewind_enabled"] = streamRewindEnabled
    snapshot.flags["chat_visible"] = showChat
    snapshot.flags["chat_connected"] = chat.isConnected
    snapshot.attributes["chat_mode"] = isVOD ? "replay" : "live"
    if isVOD {
      let state = replay.diagnostics
      snapshot.flags["chat_replay_ready"] = replay.isReady
      snapshot.flags["chat_replay_growing"] = state.growing
      snapshot.flags["chat_replay_fetching"] = state.fetching
      snapshot.flags["chat_replay_has_more"] = state.hasMore
      snapshot.counters["chat_replay_messages"] = replay.messages.count
      snapshot.metrics["chat_replay_offset_seconds"] = state.offset
      snapshot.metrics["chat_replay_frontier_seconds"] = state.frontier
      snapshot.metrics["chat_replay_refresh_age_seconds"] = replay.lastUpdatedAt.map { max(0, -$0.timeIntervalSinceNow) }
      snapshot.attributes["chat_replay_error"] = replay.errorMessage
    }
    snapshot.flags["chat_reading"] = chatIsFrozen
    snapshot.flags["chat_frozen_snapshot"] = chatFrozenMessages != nil
    snapshot.counters["chat_messages"] = chat.messages.count
    snapshot.counters["chat_emote_catalog_entries"] = chat.emoteURLs.count
    snapshot.flags["chat_emote_catalog_retry_pending"] = chat.emoteCatalogNeedsRetry
    snapshot.counters["chat_frozen_messages"] = chatFrozenMessages?.count ?? 0
    snapshot.counters["chat_pending_sync"] = chat.pendingSyncMessageCount
    snapshot.flags["chat_sync_enabled"] = chat.chatSyncEnabled
    snapshot.attributes["chat_sync_reference"] = model.chatSyncBaseline.reference.rawValue
    snapshot.metrics["chat_sync_normal_delay_seconds"] = model.chatSyncBaseline.normalDelay
    snapshot.metrics["chat_sync_native_cushion_seconds"] = model.chatSyncBaseline.nativeCushion
    snapshot.metrics["chat_sync_extra_delay_seconds"] = model.chatSyncBaseline.extraDelay
    snapshot.flags["chat_sync_drain_active"] = chat.syncDrainTask != nil
    snapshot.metrics["chat_sync_delay_seconds"] = chat.chatSyncDelaySeconds
    snapshot.metrics["chat_sync_next_release_seconds"] = chat.syncBuffer.first.map {
      $0.releaseAt.timeIntervalSinceNow
    }
    snapshot.metrics["chat_sync_scheduled_wake_seconds"] = chat.syncDrainDeadline.map {
      $0.timeIntervalSinceNow
    }
    snapshot.counters["chat_reconnects"] = chat.ircReconnectCount
    snapshot.attributes["chat_last_recovery"] = chat.ircLastRecoveryReason
    if let lastFrame = chat.ircHealth?.lastFrameAt {
      snapshot.metrics["chat_frame_age_seconds"] = max(0, ProcessInfo.processInfo.systemUptime - lastFrame)
    }

    snapshot.counters["diagnostic_stalls"] = diagStallCount
    snapshot.counters["diagnostic_jumps"] = diagJumpCount
    snapshot.counters["diagnostic_reloads"] = diagReloadCount

    if let item = player.currentItem {
      let current = CMTimeGetSeconds(item.currentTime())
      if current.isFinite {
        snapshot.metrics["playhead_seconds"] = current
      }
      if let ahead = bufferAheadSeconds(item), ahead.isFinite {
        snapshot.metrics["buffer_ahead_seconds"] = ahead
      }
      let size = item.presentationSize
      if size.width > 0, size.height > 0 {
        snapshot.metrics["presentation_width"] = Double(size.width)
        snapshot.metrics["presentation_height"] = Double(size.height)
      }
      snapshot.flags["buffer_empty"] = item.isPlaybackBufferEmpty
      snapshot.flags["buffer_full"] = item.isPlaybackBufferFull
      snapshot.flags["likely_to_keep_up"] = item.isPlaybackLikelyToKeepUp
      snapshot.counters["loaded_range_count"] = item.loadedTimeRanges.count
      snapshot.counters["seekable_range_count"] = item.seekableTimeRanges.count

      if let loaded = item.loadedTimeRanges.last?.timeRangeValue {
        let start = CMTimeGetSeconds(loaded.start)
        let duration = CMTimeGetSeconds(loaded.duration)
        if start.isFinite { snapshot.metrics["loaded_range_start_seconds"] = start }
        if duration.isFinite { snapshot.metrics["loaded_range_duration_seconds"] = duration }
      }
      if let window = currentSeekWindow() {
        snapshot.metrics["seekable_start_seconds"] = window.start
        snapshot.metrics["seekable_end_seconds"] = window.end
        snapshot.metrics["seekable_duration_seconds"] = window.end - window.start
        if !isVOD {
          snapshot.metrics["live_edge_gap_seconds"] = max(window.end - window.now, 0)
        }
      }
      if !isVOD, !isUsingAltSource {
        snapshot.metrics["wall_clock_latency_seconds"] = wallClockLatencySeconds
        snapshot.metrics["live_edge_latency_seconds"] = liveEdgeLatencySeconds
        snapshot.metrics["smoothed_latency_seconds"] = smoothedLatencySeconds
      }

      let accesses = item.accessLog()?.events ?? []
      if let access = accesses.last {
        let accessSnapshot = PlaybackTelemetryRecorder.accessSnapshot(access)
        snapshot.metrics.merge(accessSnapshot.metrics) { _, new in new }
        snapshot.counters.merge(accessSnapshot.counters) { _, new in new }
        snapshot.attributes["access_entry"] = String(accesses.count - 1)
      }
      if let error = item.error {
        snapshot.attributes.merge(PlaybackTelemetryRecorder.errorAttributes(error)) { _, new in new }
      }
    }

    if (player.currentItem?.asset as? AVURLAsset)?.url.scheme == LowLatencyHLSProxy.scheme {
      addProxyTelemetry(to: &snapshot)
    }
    model.playbackTelemetry.recordSnapshot(snapshot)
  }

  private func addProxyTelemetry(to snapshot: inout PlaybackTelemetrySnapshot) {
    let proxy = lowLatencyProxy.telemetrySnapshot
    snapshot.attributes["proxy_host"] = proxy.lastHost
    snapshot.metrics["proxy_last_request_ms"] = proxy.lastRequestDurationMilliseconds
    snapshot.metrics["proxy_target_duration_seconds"] = proxy.lastTargetDurationSeconds
    snapshot.metrics["proxy_retained_seconds"] = proxy.retainedSeconds
    snapshot.counters["proxy_requests"] = proxy.requestCount
    snapshot.counters["proxy_failed_requests"] = proxy.failedRequestCount
    snapshot.counters["proxy_cancelled_requests"] = proxy.cancelledRequestCount
    snapshot.counters["proxy_active_requests"] = proxy.activeRequestCount
    snapshot.counters["proxy_last_status"] = proxy.lastStatusCode
    snapshot.counters["proxy_last_failure_status"] = proxy.lastFailureStatusCode
    snapshot.counters["proxy_last_failure_error_code"] = proxy.lastFailureErrorCode
    snapshot.metrics["proxy_last_failure_uptime_seconds"] = proxy.lastFailureUptime
    snapshot.counters["proxy_last_response_bytes"] = proxy.lastResponseBytes
    snapshot.counters["proxy_media_refreshes"] = proxy.mediaPlaylistRefreshes
    snapshot.counters["proxy_media_sequence"] = proxy.lastMediaSequence
    snapshot.counters["proxy_tail_sequence"] = proxy.lastTailSequence
    snapshot.counters["proxy_segments"] = proxy.lastSegmentCount
    snapshot.counters["proxy_prefetch_segments"] = proxy.lastPrefetchCount
    snapshot.counters["proxy_promoted_prefetch_segments"] = proxy.lastPromotedPrefetchCount
    snapshot.counters["proxy_discontinuities"] = proxy.lastDiscontinuityCount
    snapshot.counters["proxy_retained_segments"] = proxy.retainedSegmentCount
    snapshot.flags["proxy_promotes_prefetch"] = proxy.promotesPrefetch
    snapshot.flags["proxy_retains_history"] = proxy.retainsHistory

    let instability = lowLatencyProxy.instabilityDiagnostics
    snapshot.metrics["proxy_instability_score"] = instability.score
    snapshot.counters["proxy_instability_refreshes"] = instability.refreshes
    snapshot.flags["proxy_predicted_unstable"] = instability.predictedUnstable
    if !instability.detail.isEmpty {
      snapshot.attributes["proxy_instability_reason"] = instability.detail
    }
  }

  func recordCurrentAccessLog() {
    model.playbackTelemetry.trackItem(player.currentItem, source: playbackTelemetrySource)
    model.playbackTelemetry.recordItemLogs()
  }

  func recordCurrentErrorLog() {
    recordCurrentAccessLog()
  }

  func replacePlaybackItem(with item: AVPlayerItem?) {
    if item == nil { model.mediaServicesResetPending = false }
    if item !== player.currentItem {
      model.nativeReportRefreshSeconds = nil
      model.nativeReportRefreshMaxSeconds = nil
      cancelNativeStartup()
      model.nativeStartupComplete = (item?.asset as? AVURLAsset)?.url.scheme != NativeLowLatencyHLS.scheme
      lastPlaybackDateSample = nil
      lastPlaybackTimeSampleSeconds = nil
      mon.playbackDateContinuity = PlaybackDateContinuity()
      wallClockLowConfidenceStreak = 0
      wallClockLatencySeconds = nil
      smoothedLatencySeconds = nil
      cancelNativeCatchUp(reason: "item_replaced")
      model.nativeCatchUp = NativeLiveCatchUp()
    }
    let rebuildingFailedPlayer = player.status == .failed && item != nil
    if rebuildingFailedPlayer { rebuildPlaybackPlayer(reason: "terminal_failure") }
    if (item?.asset as? AVURLAsset)?.url.scheme != NativeLowLatencyHLS.scheme {
      model.nativeNeedsRefresh = false
      model.nativeRefreshTask?.cancel()
      model.nativeHLS?.stop()
      model.nativeHLS = nil
      model.isUsingNativeHLS = false
      model.nativeGeneration = UUID()
    }
    if item !== player.currentItem {
      model.fallbackRestoreTask?.cancel()
      model.fallbackRestoreTask = nil
      model.chatSyncItemID = UUID()
      model.chatSyncBaseline.itemChanged()
      model.chatSyncSendAnchor = nil
      chatSyncSendClearTask?.cancel()
      chatSyncSendDeadline = nil
      applyChatSyncSettings()
      resetPlaybackHealth()
      model.startupProgress = LivePlaybackStartup.Progress()
    }
    model.playbackTelemetry.trackItem(item, source: playbackTelemetrySource)
    player.replaceCurrentItem(with: item)
    if let item, player.currentItem !== item, !rebuildingFailedPlayer {
      rebuildPlaybackPlayer(reason: "replacement_rejected")
      player.replaceCurrentItem(with: item)
    }
    if let item {
      guard player.currentItem === item else {
        player.pause()
        errorMessage = String(localized: "The video player couldn't restart. Please try again.")
        isLoading = false
        recordPlaybackEvent("player_item_replacement_failed", level: .error)
        return
      }
      let url = (item.asset as? AVURLAsset)?.url
      let usesProxy = url?.scheme == LowLatencyHLSProxy.scheme
      recordPlaybackEvent(
        "player_item_created",
        attributes: ["asset_scheme": url?.scheme ?? "unknown"],
        metrics: ["preferred_forward_buffer_seconds": item.preferredForwardBufferDuration],
        flags: [
          "uses_proxy": usesProxy,
          "promotes_prefetch": usesProxy && livePlaybackProfile
            .effectiveSelection(nativeAvailable: model.nativeFallbackReason == nil)
            .promotesPrefetch(legacyEnabled: lowLatencyProxyEnabled, unstable: isStreamUnstable),
          "retains_history": usesProxy && streamRewindEnabled,
          "stream_unstable": isStreamUnstable,
        ]
      )
    }
  }

  func rebuildPlaybackPlayer(reason: String, isFailure: Bool = true) {
    recordPlaybackEvent(isFailure ? "failed_player_replaced" : "playback_player_recreated",
      level: isFailure ? .error : .info,
      attributes: PlaybackTelemetryRecorder.errorAttributes(player.error)
        .merging(["reason": reason]) { _, new in new })
    removeVODTimeObserver()
    let previous = player
    previous.pause()
    previous.replaceCurrentItem(with: nil)
    let replacement = AVPlayer()
    replacement.volume = previous.volume
    replacement.isMuted = previous.isMuted
    replacement.automaticallyWaitsToMinimizeStalling = previous.automaticallyWaitsToMinimizeStalling
    replacement.appliesMediaSelectionCriteriaAutomatically = previous.appliesMediaSelectionCriteriaAutomatically
    replacement.actionAtItemEnd = previous.actionAtItemEnd
    replacement.allowsExternalPlayback = previous.allowsExternalPlayback
    model.player = replacement
  }

  private func telemetryItemStatus(_ status: AVPlayerItem.Status?) -> String {
    switch status {
    case .unknown: "unknown"
    case .readyToPlay: "ready"
    case .failed: "failed"
    case nil: "none"
    @unknown default: "future"
    }
  }

  private func telemetryTimeControlStatus() -> String {
    switch player.timeControlStatus {
    case .paused: "paused"
    case .waitingToPlayAtSpecifiedRate: "waiting"
    case .playing: "playing"
    @unknown default: "future"
    }
  }

  private func telemetryThermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "future"
    }
  }
}

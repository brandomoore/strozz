import AVKit
import SwiftUI

// Quality picker: the option list and button label, plus resolving the active
// variant name on the adaptive master playlist and applying a selection.
extension PlayerView {
  /// The active latency-vs-quality profile, decoded from its stored raw value.
  var livePlaybackProfile: LivePlaybackProfile {
    get { model.multiviewContext?.profile ?? LivePlaybackProfile.restored(rawValue: livePlaybackProfileRaw) }
    nonmutating set {
      if let context = model.multiviewContext { context.profile = newValue }
      else { livePlaybackProfileRaw = newValue.rawValue }
    }
  }

  func migrateNativeLiveProfile() {
    if livePlaybackProfileRaw != LivePlaybackProfile.nativeLowLatency.rawValue {
      livePlaybackProfileRaw = LivePlaybackProfile.nativeLowLatency.rawValue
    }
  }

  var isNativeLiveVideo: Bool {
    !isVOD && !isUsingAltSource && !isAudioOnlyActive && !player.isExternalPlaybackActive
  }

  /// Concrete buffer / catch-up tuning for the current profile and pin state.
  /// A stream flagged chronically unstable overrides everything with the
  /// deep-buffer stability fallback (smoothness over latency).
  var activeLivePlaybackPolicy: LivePlaybackPolicy {
    if isNativeLiveVideo {
      return .live(profile: .nativeLowLatency, isPinned: preferredQuality != "Auto")
    }
    if isStreamUnstable { return .stabilityFallback }
    return .standard(isPinned: preferredQuality != "Auto")
  }

  /// Applies the active policy to the live item without swapping the source —
  /// used when only the profile changes (the master URL stays the same).
  func applyActiveLivePlaybackPolicy() {
    let policy = activeLivePlaybackPolicy
    player.currentItem?.preferredForwardBufferDuration = policy.preferredForwardBufferDuration
    recordPlaybackEvent(
      "playback_policy_applied",
      attributes: [
        "profile": isStreamUnstable ? "stability_fallback" : livePlaybackProfile.rawValue,
        "quality": preferredQuality,
      ],
      metrics: [
        "forward_buffer_seconds": policy.preferredForwardBufferDuration,
        "min_playback_rate": Double(policy.minPlaybackRate),
        "max_catch_up_rate": Double(policy.maxCatchUpRate),
        "slowdown_buffer_floor_seconds": policy.slowdownBufferFloorSeconds,
        "catch_up_buffer_floor_seconds": policy.catchUpHealthyBufferSeconds,
      ],
      flags: [
        "gentle_catch_up_enabled": policy.enablesGentleCatchUp,
        "pinned_quality": preferredQuality != "Auto",
      ]
    )
    applyLiveLatencyCorrection()
  }

  var qualityOptions: [String] {
    LivePlaybackProfile.allCases.map(\.pickerLabel)
      + (playback?.qualities.map(\.name) ?? [])
  }

  /// Auto always uses the native row; a pinned rendition selects itself.
  var selectedQualityOption: String {
    preferredQuality == "Auto"
      ? livePlaybackProfile.pickerLabel
      : preferredQuality
  }

  var qualityEngineStatus: String? {
    guard !isUsingAltSource, !isVOD, !isAudioOnlyActive else { return nil }
    let notice = playback?.qualities.first(where: { $0.id == model.decodeRecoveryQualityID })
      .map { "A video rendition could not be decoded. Using \($0.name) instead." }
    guard livePlaybackProfile == .nativeLowLatency else { return notice }
    let status: String
    if let reason = model.nativeFallbackReason { status = "Native playback unavailable · \(reason)" }
    else if model.nativeNeedsRefresh { status = "Reconnecting Native LL-HLS" }
    else if model.isUsingNativeHLS { status = model.nativeParts > 0 ? "Native LL-HLS" : "Preparing Native LL-HLS" }
    else { status = "Preparing Native LL-HLS" }
    return notice.map { "\(status) · \($0)" } ?? status
  }

  func recoverUndecodableVideo() -> Bool {
    guard !isVOD, !isUsingAltSource, !isAudioOnlyActive, !player.isExternalPlaybackActive,
      !model.triedDecodeRecovery,
      let playback,
      let source = StreamQuality.decodeRecoveryQuality(in: playback.qualities,
        selectedID: playback.qualities.first(where: { $0.name == preferredQuality })?.id) else { return false }
    model.triedDecodeRecovery = true
    model.decodeRecoveryQualityID = source.id
    recordPlaybackEvent("video_decode_quality_recovery", level: .warning,
      attributes: ["quality": source.name])
    switchToSourceIfNeeded(source.url)
    return true
  }

  /// Text shown on the player's quality button: the selected variant (e.g.
  /// "1080p60"), or "Auto (1080p60)" reflecting the live adaptive resolution.
  var qualityButtonLabel: String {
    if preferredQuality == "Auto" {
      if let resolvedQualityName {
        return "Auto (\(resolvedQualityName))"
      }
      return "Auto"
    }
    return Self.shortQualityName(preferredQuality)
  }

  /// Every label the quality button could ever display for the current stream.
  /// The button reserves the width of the widest of these so the in-player
  /// title's available space stays constant as the live label changes (e.g.
  /// "Auto" -> "Auto (1080p60)"), preventing distracting title font reflow.
  var qualityButtonLabelCandidates: [String] {
    var labels: Set<String> = ["Auto"]
    let videoVariants = (playback?.qualities ?? []).filter { !$0.isAudioOnly }
    for quality in videoVariants {
      let short = Self.shortQualityName(quality.name)
      labels.insert(short)
      labels.insert("Auto (\(short))")
    }
    return labels.sorted()
  }

  /// Drops the "(Source)" suffix so the button reads "1080p60", not
  /// "1080p60 (Source)".
  static func shortQualityName(_ name: String) -> String {
    name.replacingOccurrences(of: " (Source)", with: "")
      .replacingOccurrences(of: " (source)", with: "")
      .trimmingCharacters(in: .whitespaces)
  }

  /// Parses the vertical resolution from a variant name, e.g. "1080p60" -> 1080.
  static func verticalResolution(from name: String) -> Int? {
    let lower = name.lowercased()
    guard let pIndex = lower.firstIndex(of: "p") else { return nil }
    let digits = lower[lower.startIndex..<pIndex].filter(\.isNumber)
    return Int(digits)
  }

  var resolvedPlaybackSize: CGSize? {
    if model.nativeControlledAuto { return model.playbackTelemetry.decodedVideoSize }
    return player.currentItem?.presentationSize
  }

  /// Multi-description movies keep static presentation metadata; use observed
  /// decoder dimensions rather than reporting the first description forever.
  func updateResolvedQuality() {
    let resolved = computeResolvedQualityName()
    // Assign only on change: this runs every second, and rewriting the same
    // `@State` value still re-executes the player body (flashing focus).
    if resolvedQualityName != resolved {
      let previous = resolvedQualityName
      resolvedQualityName = resolved
      if preferredQuality == "Auto", model.isUsingNativeHLS,
        let size = resolvedPlaybackSize, size.height > 0 {
        var metrics = ["resolved_video_width": Double(size.width), "resolved_video_height": Double(size.height),
          "player_rate": Double(player.rate)]
        if let item = player.currentItem {
          metrics["presentation_width"] = item.presentationSize.width
          metrics["presentation_height"] = item.presentationSize.height
        }
        metrics["buffer_ahead_seconds"] = player.currentItem.flatMap { bufferAheadSeconds($0) }
        metrics["video_frame_age_seconds"] = model.playbackTelemetry.videoFrameAge
        recordPlaybackEvent("native_adaptive_quality_observed",
          attributes: ["previous_quality": previous ?? "unknown", "resolved_quality": resolved ?? "unknown"],
          metrics: metrics)
      }
    }
  }

  func computeResolvedQualityName() -> String? {
    guard preferredQuality == "Auto" else {
      return nil
    }
    guard let playback else { return resolvedQualityName }

    let videoVariants = playback.qualities.filter { !$0.isAudioOnly }
    // Named variants that advertise a parseable resolution, e.g. "720p60".
    let namedCandidates: [(Int, String)] = videoVariants.compactMap { quality in
      guard let resolution = Self.verticalResolution(from: quality.name) else { return nil }
      return (resolution, Self.shortQualityName(quality.name))
    }

    // Preferred path: match the live adaptive resolution to the nearest named
    // variant so we keep its exact label (including frame rate).
    if let size = resolvedPlaybackSize, size.height > 0 {
      let height = Int(size.height.rounded())
      if let best = namedCandidates.min(by: { abs($0.0 - height) < abs($1.0 - height) }) {
        return best.1
      }
      // Variants don't expose a parseable resolution (e.g. transcoding
      // disabled, source named "chunked"): derive the label from the decoded
      // frame height directly so it still shows something accurate.
      return "\(height)p"
    }

    // Presentation size not yet known. If the stream offers a single video
    // rendition, Auto is effectively that rendition — show it rather than
    // leaving the label stuck on a bare "Auto".
    if videoVariants.count == 1 {
      return Self.shortQualityName(videoVariants[0].name)
    }
    return resolvedQualityName
  }

  /// The native Auto row and pinned renditions carry their own labels.
  func qualityDisplayLabel(_ option: String) -> String {
    return option
  }

  func selectQuality(at index: Int) {
    guard qualityOptions.indices.contains(index) else { return }
    model.nativeRecovery = NativePlaybackRecovery()
    errorMessage = nil
    model.triedDecodeRecovery = false
    let option = qualityOptions[index]
    let previousQuality = preferredQuality
    let previousProfile = livePlaybackProfile.rawValue
    if let profile = LivePlaybackProfile.allCases.first(where: { $0.pickerLabel == option }) {
      livePlaybackProfile = profile
      model.nativeFallbackReason = nil
      preferredQuality = "Auto"
      if isUsingAltSource {
        didManuallySelectSource = true
        switchToTwitchSource()
      } else {
        if let playback {
          replacePlaybackItem(with: makeItem(url: playback.master))
          if shouldPlayAltSource { startPlayback() }
        }
      }
    } else {
      preferredQuality = option
      applyQualityPreference(option)
    }
    updateResolvedQuality()
    recordPlaybackEvent(
      "quality_selected",
      attributes: [
        "selection": option,
        "previous_quality": previousQuality,
        "previous_profile": previousProfile,
        "current_quality": preferredQuality,
        "current_profile": livePlaybackProfile.rawValue,
      ]
    )
    focus = .quality
    scheduleHide()
  }
}

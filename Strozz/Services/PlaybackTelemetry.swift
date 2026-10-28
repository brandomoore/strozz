import AVFoundation
import Foundation

enum PlaybackTelemetryLevel: String, Codable, Sendable {
  case debug, info, warning, error
}

struct PlaybackTelemetrySnapshot: Equatable, Sendable {
  var attributes: [String: String] = [:]
  var metrics: [String: Double] = [:]
  var counters: [String: Int] = [:]
  var flags: [String: Bool] = [:]

  var phase: String {
    if flags["background"] == true { return "background" }
    if flags["offline"] == true { return "offline" }
    if flags["user_paused"] == true { return "paused" }
    if flags["scrubbing"] == true || flags["seek_pending"] == true { return "seeking" }
    if flags["recovering"] == true { return "recovering" }
    if flags["loading"] == true || flags["has_started"] != true { return "loading" }
    if flags["playback_requested"] != true { return "idle" }
    return attributes["time_control_status"] == "playing" ? "playing" : "waiting"
  }

  var stallKind: String? {
    guard phase == "playing" || phase == "waiting" else { return nil }
    // A waiting status can briefly flicker while the clock is still advancing.
    if flags["decode_frozen"] == true { return "decode_freeze" }
    guard (metrics["clock_not_advancing_seconds"] ?? 0) >= 4 else { return nil }
    if flags["buffer_empty"] == true || (metrics["buffer_ahead_seconds"] ?? .infinity) < 0.5 {
      return "network_or_buffer"
    }
    if attributes["time_control_status"] != "waiting" { return "playhead_not_advancing" }
    if (metrics["buffer_ahead_seconds"] ?? 0) >= 1.5 {
      return "healthy_buffer_wait"
    }
    return "waiting_unknown"
  }
}

struct PlaybackTelemetryRecord: Codable, Sendable {
  let schemaVersion: Int
  let timestamp: Date
  let uptimeSeconds: Double
  let sessionID: String
  let sequence: Int
  let kind: String
  let name: String
  let level: PlaybackTelemetryLevel
  let channel: String
  let playbackMode: String
  var attributes: [String: String]
  var metrics: [String: Double]
  var counters: [String: Int]
  let flags: [String: Bool]
}

final class PlaybackSchedulerProbe: @unchecked Sendable {
  struct Ticket: Equatable, Sendable {
    let id: Int
    let enqueuedAt: Double
  }

  struct Report: Sendable {
    let enqueuedAt: Double
    let observedAt: Double
    let backgroundInterval: Double
    let coalescedTicks: Int
    let resources: PlaybackTelemetrySnapshot
    var mainDelay: Double { max(0, observedAt - enqueuedAt) }
  }

  struct State {
    private(set) var enabled = false
    private(set) var generation = 0
    private var nextID = 0
    private var lastTick: Double?
    private var pending: Ticket?
    private var maximumInterval = 0.0
    private var coalesced = 0
    private var previousResource: PlaybackResourceSample?
    private var resources = PlaybackTelemetrySnapshot()

    init() {}

    mutating func setEnabled(_ enabled: Bool, at now: Double) {
      guard self.enabled != enabled else { return }
      self.enabled = enabled
      generation += 1
      pending = nil
      lastTick = enabled ? now : nil
      maximumInterval = 0
      coalesced = 0
      previousResource = nil
      resources = PlaybackTelemetrySnapshot()
    }

    mutating func tick(at now: Double, resource: PlaybackResourceSample? = nil) -> Ticket? {
      guard enabled else { return nil }
      maximumInterval = max(maximumInterval, lastTick.map { max(0, now - $0) } ?? 0)
      lastTick = now
      if let resource {
        let previous = resources
        resources = resource.since(previousResource)
        for (currentKey, peakKey) in [
          ("process_cpu_core_equivalents", "process_cpu_peak_core_equivalents"),
          ("process_resident_bytes", "process_peak_resident_bytes"),
          ("process_footprint_bytes", "process_peak_footprint_bytes"),
          ("resource_sample_duration_seconds", "resource_sample_peak_duration_seconds"),
        ] {
          if let current = resources.metrics[currentKey] {
            resources.metrics[peakKey] = max(current, previous.metrics[peakKey] ?? current)
          } else {
            resources.metrics[peakKey] = previous.metrics[peakKey]
          }
        }
        previousResource = resource
      }
      guard pending == nil else { coalesced += 1; return nil }
      nextID += 1
      let ticket = Ticket(id: nextID, enqueuedAt: now)
      pending = ticket
      return ticket
    }

    mutating func finish(_ ticket: Ticket, at now: Double) -> Report? {
      guard enabled, pending == ticket else { return nil }
      let report = Report(enqueuedAt: ticket.enqueuedAt, observedAt: now,
        backgroundInterval: maximumInterval, coalescedTicks: coalesced, resources: resources)
      pending = nil
      maximumInterval = 0
      coalesced = 0
      resources = PlaybackTelemetrySnapshot()
      return report
    }
  }

  private let lock = NSLock()
  private var state = State()
  private let timer: DispatchSourceTimer
  #if DEBUG
  private var resourceSampler = PlaybackResourceSampler()
  #endif
  private let report: @MainActor @Sendable (Report) -> Void

  init(report: @escaping @MainActor @Sendable (Report) -> Void) {
    self.report = report
    timer = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "strozz.playback-scheduler-probe", qos: .userInitiated))
    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
    timer.setEventHandler { [weak self] in
      guard let self,
        let generation = self.lock.withLock({ self.state.enabled ? self.state.generation : nil }) else { return }
      #if DEBUG
      let resource = self.resourceSampler.sample()
      #else
      let resource: PlaybackResourceSample? = nil
      #endif
      guard let ticket = self.lock.withLock({ () -> Ticket? in
        guard self.state.generation == generation else { return nil }
        return self.state.tick(at: ProcessInfo.processInfo.systemUptime, resource: resource)
      }) else { return }
      // One pending callback per player, even when main is blocked for minutes.
      DispatchQueue.main.async { [weak self] in
        guard let self,
          let value = self.lock.withLock({ self.state.finish(ticket, at: ProcessInfo.processInfo.systemUptime) })
        else { return }
        self.report(value)
      }
    }
    timer.resume()
  }

  func setEnabled(_ enabled: Bool) {
    lock.withLock { state.setEnabled(enabled, at: ProcessInfo.processInfo.systemUptime) }
  }

  func stop() {
    setEnabled(false)
    timer.cancel()
  }

  deinit { timer.cancel() }
}

/// Collects AVFoundation values on the main actor, but never encodes or touches
/// disk there. This is intentionally independent of the playback watchdog.
@MainActor
final class PlaybackTelemetryRecorder {
  static let directoryName = "PlaybackDiagnostics"

  struct Seek: Equatable {
    let id = UUID().uuidString
    let sessionID: String
    let itemID: Int
    let startedAt: Double
    let target: Double
  }

  private struct Session {
    let id = UUID().uuidString.lowercased()
    let channel: String
    let mode: String
    let startedAt: Double
    var sequence = 0
    var eventCounts: [String: Int] = [:]
  }

  private let writer: PlaybackTelemetryWriter
  private var session: Session?
  private var item: AVPlayerItem?
  private var itemID = 0
  private var accessCount = 0
  private var errorCount = 0
  private var lastAccess: PlaybackTelemetrySnapshot?
  private var lastSnapshot: PlaybackTelemetrySnapshot?
  private var lastSampleAt: Double?
  private var lastProgressAt: Double?
  private var itemStartedAt = 0.0
  private var hasStarted = false
  private var stallKind: String?
  private var stallStartedAt: Double?
  private var pendingSeek: Seek?
  private var latestSeek: Seek?
  private var lastVideoFrameAt: Double?
  private var lastRateEventAt = -Double.infinity
  private var lastRateReason: String?
  private var repeatedEvents: [String: Double] = [:]
  private var schedulerProbe: PlaybackSchedulerProbe?
  private var lastSchedulerReportAt = 0.0

  init(writer: PlaybackTelemetryWriter = PlaybackTelemetryWriter()) {
    self.writer = writer
  }

  deinit { schedulerProbe?.stop() }

  func startSchedulerMonitoring() {
    guard let session, schedulerProbe == nil else { return }
    let sessionID = session.id
    lastSchedulerReportAt = ProcessInfo.processInfo.systemUptime
    schedulerProbe = PlaybackSchedulerProbe { [weak self] report in
      guard let self, self.session?.id == sessionID else { return }
      let delayed = report.mainDelay >= 0.25 || report.backgroundInterval >= 1.25
      guard delayed || report.observedAt - self.lastSchedulerReportAt >= 15 else { return }
      self.lastSchedulerReportAt = report.observedAt
      self.recordEvent(delayed ? "playback_scheduler_delay" : "playback_scheduler_sample",
        level: delayed ? .warning : .debug, metrics: report.resources.metrics.merging([
          "probe_enqueued_uptime_seconds": report.enqueuedAt,
          "main_queue_delay_seconds": report.mainDelay,
          "background_probe_interval_seconds": report.backgroundInterval,
        ]) { _, new in new },
        counters: report.resources.counters.merging(["coalesced_probe_ticks": report.coalescedTicks]) { _, new in new })
    }
  }

  static func nativeDeliveryMetrics(_ input: [String: Double], dispatchedAt: Double,
                                   at now: Double = ProcessInfo.processInfo.systemUptime) -> [String: Double] {
    var metrics = input
    if let source = input["native_event_uptime_seconds"], source.isFinite, dispatchedAt.isFinite,
      now.isFinite, dispatchedAt >= source, now >= dispatchedAt {
      metrics["native_trace_dispatch_uptime_seconds"] = dispatchedAt
      metrics["native_trace_retention_delay_seconds"] = dispatchedAt - source
      metrics["main_actor_delivery_delay_seconds"] = now - dispatchedAt
    }
    return metrics
  }

  func measure<T>(_ operation: String, _ body: () -> T) -> T {
    let start = ProcessInfo.processInfo.systemUptime
    defer {
      let elapsed = ProcessInfo.processInfo.systemUptime - start
      if elapsed >= 0.1 {
        recordEvent("playback_main_operation_slow", level: .warning,
          attributes: ["operation": operation],
          metrics: ["operation_started_uptime_seconds": start, "duration_seconds": elapsed])
      }
    }
    return body()
  }

  var sessionID: String? { session?.id }
  private(set) var source = "none"
  var shortSessionID: String? { session.map { String($0.id.prefix(8)) } }
  var currentItemID: String { String(itemID) }
  var videoFrameAge: Double? { lastVideoFrameAt.map { ProcessInfo.processInfo.systemUptime - $0 } }
  private(set) var decodedVideoSize: CGSize?
  var isSeekPending: Bool { pendingSeek != nil }

  func beginSession(
    channel: String, playbackMode: String,
    attributes: [String: String] = [:], flags: [String: Bool] = [:]
  ) {
    endSession(reason: "superseded")
    session = Session(channel: channel, mode: playbackMode, startedAt: ProcessInfo.processInfo.systemUptime)
    itemID = 0
    repeatedEvents = [:]
    lastRateEventAt = -.infinity
    lastRateReason = nil
    var attributes = attributes
    attributes["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    attributes["app_build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    attributes["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
    emit(kind: "event", name: "session_started", attributes: attributes, flags: flags)
  }

  func endSession(reason: String) {
    guard let session else { return }
    schedulerProbe?.stop()
    schedulerProbe = nil
    recordItemLogs()
    endStall(outcome: "session_ended")
    emit(
      kind: "summary", name: "session_ended", attributes: ["reason": reason],
      metrics: ["duration_seconds": ProcessInfo.processInfo.systemUptime - session.startedAt],
      counters: self.session?.eventCounts ?? [:]
    )
    self.session = nil
    item = nil
    source = "none"
    resetItemState()
  }

  /// Call at every item replacement, before releasing the outgoing item.
  func trackItem(_ newItem: AVPlayerItem?, source: String = "unknown") {
    guard session != nil, newItem !== item else { return }
    recordItemLogs()
    endStall(outcome: "interrupted")
    item = newItem
    if newItem == nil { schedulerProbe?.setEnabled(false) }
    self.source = newItem == nil ? "none" : source
    itemID += 1
    resetItemState()
    emit(kind: "event", name: "item_changed", flags: ["has_item": newItem != nil])
  }

  private func resetItemState() {
    accessCount = 0
    errorCount = 0
    lastAccess = nil
    lastSnapshot = nil
    lastSampleAt = nil
    lastProgressAt = nil
    itemStartedAt = ProcessInfo.processInfo.systemUptime
    hasStarted = false
    pendingSeek = nil
    latestSeek = nil
    lastVideoFrameAt = nil
    decodedVideoSize = nil
  }

  func recordEvent(
    _ name: String, level: PlaybackTelemetryLevel = .info,
    attributes: [String: String] = [:], metrics: [String: Double] = [:],
    counters: [String: Int] = [:], flags: [String: Bool] = [:]
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    // Keep mode changes immediately; sample ramp steps at most every two seconds.
    if name == "playback_rate_changed" {
      let reason = attributes["reason"]
      guard reason != lastRateReason || now - lastRateEventAt >= 2 else { return }
      lastRateEventAt = now
      lastRateReason = reason
    }
    if ["alternate_item_failed", "alternate_resolve_suppressed", "recovery_suppressed"].contains(name) {
      guard now - (repeatedEvents[name] ?? -.infinity) >= 10 else { return }
      repeatedEvents[name] = now
    }
    emit(kind: "event", name: name, level: level, attributes: attributes,
         metrics: metrics, counters: counters, flags: flags)
  }

  func beginSeek(target: Double, kind: String) -> Seek? {
    guard let session else { return nil }
    let seek = Seek(sessionID: session.id, itemID: itemID,
                    startedAt: ProcessInfo.processInfo.systemUptime, target: target)
    pendingSeek = seek
    latestSeek = seek
    endStall(outcome: "interrupted")
    recordEvent("seek_requested", attributes: ["seek_id": seek.id, "kind": kind],
                metrics: ["target_seconds": target])
    return seek
  }

  @discardableResult
  func finishSeek(_ seek: Seek?, finished: Bool, actual: Double) -> Bool {
    guard let seek, seek.sessionID == session?.id else { return false }
    let current = seek.itemID == itemID && latestSeek == seek
    recordEvent(
      "seek_completed", level: finished && current ? .info : .warning,
      attributes: ["seek_id": seek.id, "outcome": current ? (finished ? "callback_completed" : "cancelled") : "superseded",
                   "seek_item_id": String(seek.itemID)],
      metrics: ["target_seconds": seek.target, "actual_seconds": actual,
                "duration_seconds": ProcessInfo.processInfo.systemUptime - seek.startedAt],
      flags: ["finished": finished]
    )
    if current {
      pendingSeek = nil
      latestSeek = nil
      lastSnapshot = nil
      lastProgressAt = nil
    }
    return current && finished
  }

  /// Called by the existing video watchdog only after it consumes a fresh frame.
  /// A second consumer would interfere with its hasNewPixelBuffer checks.
  func videoFrameObserved(size: CGSize? = nil) {
    guard session != nil else { return }
    if let size {
      guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
        recordEvent("invalid_decoded_frame_dimensions", level: .warning)
        return
      }
      if decodedVideoSize != size {
        decodedVideoSize = size
        recordEvent("decoded_video_format_changed",
          metrics: ["decoded_video_width": size.width, "decoded_video_height": size.height])
      }
    }
    if lastVideoFrameAt == nil {
      recordEvent("first_video_output_frame",
                  metrics: ["since_item_seconds": ProcessInfo.processInfo.systemUptime - itemStartedAt])
    }
    lastVideoFrameAt = ProcessInfo.processInfo.systemUptime
  }

  func recordSnapshot(_ input: PlaybackTelemetrySnapshot, uptime: Double = ProcessInfo.processInfo.systemUptime) {
    guard session != nil else { return }
    schedulerProbe?.setEnabled(input.flags["background"] != true && input.flags["playback_requested"] == true)
    if let seek = pendingSeek, uptime - seek.startedAt >= 15 {
      recordEvent("seek_deadline_exceeded", level: .warning, attributes: ["seek_id": seek.id],
                  metrics: ["target_seconds": seek.target])
      pendingSeek = nil
      lastSnapshot = nil
      lastProgressAt = nil
    }
    var snapshot = input
    snapshot.attributes["item_id"] = currentItemID
    snapshot.flags["seek_pending"] = isSeekPending
    let previous = lastSnapshot
    let delta = snapshot.metrics["playhead_seconds"].flatMap { now in
      previous?.metrics["playhead_seconds"].map { now - $0 }
    }
    let uninterrupted = input.flags["loading"] != true && input.flags["user_paused"] != true
      && input.flags["scrubbing"] != true && input.flags["background"] != true
      && input.flags["recovering"] != true && !isSeekPending && input.flags["offline"] != true
    if let delta, delta >= 0.05, uninterrupted {
      if !hasStarted {
        recordEvent("first_clock_progress", metrics: ["since_item_seconds": uptime - itemStartedAt])
      }
      hasStarted = true
      lastProgressAt = uptime
    }
    let missedSamples = lastSampleAt.map { uptime - $0 > 6 } ?? false
    if missedSamples { endStall(outcome: "interrupted", uptime: lastSampleAt ?? uptime) }
    if !uninterrupted || lastProgressAt == nil || missedSamples {
      lastProgressAt = uptime
    }
    snapshot.flags["has_started"] = hasStarted
    snapshot.metrics["clock_not_advancing_seconds"] = max(0, uptime - (lastProgressAt ?? uptime))
    snapshot.attributes["phase"] = snapshot.phase
    if let delta { snapshot.metrics["clock_delta_seconds"] = delta }
    if let lastSampleAt { snapshot.metrics["sample_interval_seconds"] = uptime - lastSampleAt }
    emit(kind: "sample", name: "playback_sample", level: .debug, attributes: snapshot.attributes,
         metrics: snapshot.metrics, counters: snapshot.counters, flags: snapshot.flags, uptime: uptime)

    if let previous {
      var changes: [String: String] = [:]
      for key in ["source", "phase", "item_status", "time_control_status", "waiting_reason",
                  "quality", "resolved_quality", "playback_profile", "thermal_state"] {
        if previous.attributes[key] != snapshot.attributes[key] {
          changes["from_\(key)"] = previous.attributes[key] ?? "none"
          changes["to_\(key)"] = snapshot.attributes[key] ?? "none"
        }
      }
      if !changes.isEmpty {
        emit(kind: "event", name: "playback_state_changed", attributes: changes,
             metrics: snapshot.metrics, flags: snapshot.flags, uptime: uptime)
      }
      if previous.attributes["access_entry"] == snapshot.attributes["access_entry"] {
        for key in ["avplayer_stalls", "dropped_video_frames", "download_overdue"] {
          if let before = previous.counters[key], let after = snapshot.counters[key], after > before {
            emit(kind: "event", name: "counter_increased", level: .warning,
                 attributes: ["counter": key], counters: ["previous": before, "current": after, "delta": after - before],
                 uptime: uptime)
          }
        }
      }
    }
    let newKind = snapshot.stallKind
    if newKind != stallKind {
      endStall(outcome: newKind != nil ? "reclassified" : (uninterrupted ? "recovered" : "interrupted"), uptime: uptime)
      if let newKind {
        stallKind = newKind
        stallStartedAt = uptime
        emit(kind: "event", name: "stall_started", level: .warning,
             attributes: snapshot.attributes.merging(["stall_kind": newKind]) { _, new in new },
             metrics: snapshot.metrics, flags: snapshot.flags, uptime: uptime)
      }
    }
    lastSnapshot = snapshot
    lastSampleAt = uptime
  }

  private func endStall(outcome: String, uptime: Double = ProcessInfo.processInfo.systemUptime) {
    if let stallKind, let stallStartedAt {
      emit(kind: "event", name: "stall_ended",
           attributes: ["stall_kind": stallKind, "outcome": outcome],
           metrics: ["duration_seconds": max(0, uptime - stallStartedAt)], uptime: uptime)
    }
    stallKind = nil
    stallStartedAt = nil
  }

  func recordItemLogs() {
    guard session != nil, let item else { return }
    let accesses = measure("access_log") { item.accessLog()?.events ?? [] }
    // The final entry is mutable/cumulative. Revisit it, but don't duplicate an
    // unchanged vector. Entry indices, not AVPlayer's private GUID, identify resets.
    let nextAccess = min(max(0, accessCount - 1), accesses.count)
    let accessStart = max(nextAccess, accesses.count - 8)
    if accessStart > nextAccess {
      recordEvent("log_entries_skipped", level: .warning, counters: ["access_entries": accessStart - nextAccess])
    }
    for index in accessStart..<accesses.count {
      let event = accesses[index]
      var snapshot = Self.accessSnapshot(event)
      snapshot.attributes["access_entry"] = String(index)
      if snapshot != lastAccess {
        emit(kind: "access_log", name: "avplayer_access_log",
             attributes: snapshot.attributes, metrics: snapshot.metrics, counters: snapshot.counters)
        lastAccess = snapshot
      }
    }
    accessCount = accesses.count
    let errors = measure("error_log") { item.errorLog()?.events ?? [] }
    let nextError = min(errorCount, errors.count)
    let errorStart = max(nextError, errors.count - 8)
    if errorStart > nextError {
      recordEvent("log_entries_skipped", level: .warning, counters: ["error_entries": errorStart - nextError])
    }
    for index in errorStart..<errors.count {
      let event = errors[index]
      var counters = ["status_code": event.errorStatusCode]
      if let status = Self.httpStatus(inErrorComment: event.errorComment) {
        counters["http_status"] = status
      }
      emit(kind: "error_log", name: "avplayer_error_log", level: .error,
           attributes: ["error_domain": event.errorDomain, "host": Self.host(event.uri),
                        "error_entry": String(index)],
           counters: counters)
    }
    errorCount = errors.count
    // Never persist localizedDescription, errorComment, userInfo, headers or
    // playbackSessionID: AVFoundation may include signed URLs/credentials there.
  }

  private static let httpStatusPattern = try! NSRegularExpression(
    pattern: #"\bHTTP(?:/[0-9.]+)?\s+([1-5][0-9]{2})\b"#,
    options: .caseInsensitive
  )

  /// Only the explicit HTTP status escapes SDK prose, never its URLs or text.
  static func httpStatus(inErrorComment comment: String?) -> Int? {
    guard let comment,
      let match = httpStatusPattern.firstMatch(in: comment, range: NSRange(comment.startIndex..., in: comment)),
      let range = Range(match.range(at: 1), in: comment) else { return nil }
    return Int(comment[range])
  }

  static func errorAttributes(_ error: Error?) -> [String: String] {
    guard let error else { return ["error_domain": "unknown"] }
    let nsError = error as NSError
    return ["error_domain": nsError.domain, "error_code": String(nsError.code)]
  }

  static func host(_ uri: String?) -> String {
    guard let uri, let host = URL(string: uri)?.host else { return "" }
    // Keep CDN DNS names, not server addresses.
    return PlaybackTelemetryWriter.sanitizedHost(host)
  }

  static func accessSnapshot(_ event: AVPlayerItemAccessLogEvent) -> PlaybackTelemetrySnapshot {
    PlaybackTelemetrySnapshot(
      attributes: ["host": host(event.uri)],
      metrics: [
        "observed_bitrate_bps": event.observedBitrate,
        "observed_bitrate_stddev_bps": event.observedBitrateStandardDeviation,
        "indicated_bitrate_bps": event.indicatedBitrate,
        "indicated_average_bitrate_bps": event.indicatedAverageBitrate,
        "average_video_bitrate_bps": event.averageVideoBitrate,
        "average_audio_bitrate_bps": event.averageAudioBitrate,
        "segments_downloaded_duration_seconds": event.segmentsDownloadedDuration,
        "duration_watched_seconds": event.durationWatched,
        "transfer_duration_seconds": event.transferDuration,
        "startup_time_seconds": event.startupTime,
      ].filter { $0.value.isFinite && $0.value >= 0 },
      counters: [
        "media_requests": event.numberOfMediaRequests,
        "bytes_transferred": Int(clamping: event.numberOfBytesTransferred),
        "avplayer_stalls": event.numberOfStalls,
        "dropped_video_frames": event.numberOfDroppedVideoFrames,
        "download_overdue": event.downloadOverdue,
        "server_address_changes": event.numberOfServerAddressChanges,
      ].filter { $0.value >= 0 }
    )
  }

  func flush() async { await writer.flush() }

  private func emit(
    kind: String, name: String, level: PlaybackTelemetryLevel = .info,
    attributes: [String: String] = [:], metrics: [String: Double] = [:],
    counters: [String: Int] = [:], flags: [String: Bool] = [:],
    uptime: Double = ProcessInfo.processInfo.systemUptime
  ) {
    guard var current = session else { return }
    current.sequence += 1
    if kind == "event" || kind == "error_log" { current.eventCounts[name, default: 0] += 1 }
    session = current
    var attributes = attributes
    attributes["item_id"] = currentItemID
    attributes["source"] = source
    writer.append(PlaybackTelemetryRecord(
      schemaVersion: 1, timestamp: Date(), uptimeSeconds: uptime,
      sessionID: current.id, sequence: current.sequence, kind: kind, name: name,
      level: level, channel: current.channel, playbackMode: current.mode,
      attributes: attributes, metrics: metrics, counters: counters, flags: flags
    ))
  }
}

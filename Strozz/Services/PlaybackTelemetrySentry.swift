import Foundation
import OSLog
import Sentry

enum PlaybackTelemetrySentry {
  // Public client ingest key, not an account/API credential.
  static let dsn = "https://36720ad8aa8ca8cb296b51320d03d367@o4511661948207104.ingest.us.sentry.io/4512286970675200"
  static let projectID = "4512286970675200"
  private static let log = Logger(subsystem: "com.thatcube.Strozz", category: "sentry-playback")
  private static let active = ActiveStreams()
  @MainActor private static var started = false

  private final class ActiveStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: PlaybackTelemetryRecord] = [:]

    func update(_ record: PlaybackTelemetryRecord) -> [PlaybackTelemetryRecord] {
      lock.withLock {
        if record.name == "session_ended" { records.removeValue(forKey: record.sessionID) }
        else {
          if records[record.sessionID] == nil, records.count >= 32,
             let oldest = records.min(by: { $0.value.uptimeSeconds < $1.value.uptimeSeconds }) {
            records.removeValue(forKey: oldest.key)
          }
          records[record.sessionID] = record
        }
        return records.values.sorted { $0.sessionID < $1.sessionID }
      }
    }
  }

  @MainActor
  static func start() {
    guard !started else { return }
    let environment = ProcessInfo.processInfo.environment
    #if DEBUG
    let debug = true
    #else
    let debug = false
    #endif
    #if targetEnvironment(simulator)
    let simulator = true
    #else
    let simulator = false
    #endif
    guard let distribution = PlaybackTelemetryDistribution.environment(
      receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent, debug: debug,
      simulator: simulator, verification: environment["STROZZ_SENTRY_VERIFICATION"] == "1",
      developmentRequested: environment["STROZZ_SENTRY_DEVELOPMENT"] == "1",
      developmentBuildEnabled: Bundle.main.object(forInfoDictionaryKey: "StrozzDevelopmentDiagnostics")
        as? String == "YES") else { return }
    started = true
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    SentrySDK.start { options in
      options.dsn = dsn
      options.environment = distribution
      options.releaseName = "com.thatcube.Strozz.\(platform)@\(version)+\(build)"
      options.dist = build
      options.sendDefaultPii = false
      options.enableAutoSessionTracking = false
      options.enableMemoryIntrospection = false
      options.enableAutoBreadcrumbTracking = false
      options.enableNetworkBreadcrumbs = false
      options.enableNetworkTracking = false
      options.enableCaptureFailedRequests = false
      options.enableAutoPerformanceTracing = false
      options.enableSwizzling = false
      options.enableAppHangTracking = false
      options.attachScreenshot = false
      options.attachViewHierarchy = false
      options.attachStacktrace = false
      options.tracesSampleRate = 0
      options.sampleRate = 1
      options.maxCacheItems = 128
      options.maxAttachmentSize = 128 * 1024
      options.maxBreadcrumbs = 64
      options.sendClientReports = true
      options.enableLogs = true
      options.beforeSend = beforeSend
      options.beforeSendLog = beforeSendLog
    }
    SentrySDK.configureScope { scope in
      scope.setTag(value: "strozz", key: "application")
      scope.setTag(value: platform, key: "apple_platform")
    }
    PlaybackTelemetryRemote.shared.enable { report in try capture(report) }
    log.info("Automatic playback diagnostics enabled for \(distribution, privacy: .public)")
  }

  static var platform: String {
    #if os(tvOS)
    "tvos"
    #else
    "ios"
    #endif
  }

  static func scrub(_ event: Event) -> Event {
    event.user = nil
    event.request = nil
    event.tags?.removeValue(forKey: "app.device")
    event.breadcrumbs = event.breadcrumbs?.filter { $0.category == "strozz.playback" }
    event.exceptions?.forEach { exception in
      if let value = exception.value { exception.value = PlaybackTelemetryReportState.redact(value) }
    }
    if var device = event.context?["device"] {
      for key in ["name", "id", "advertising_id", "unique_identifier"] { device.removeValue(forKey: key) }
      event.context?["device"] = device
    }
    event.context?.removeValue(forKey: "user")
    event.context?.removeValue(forKey: "culture")
    if var app = event.context?["app"] {
      for key in ["device_app_hash", "app_id", "view_names"] { app.removeValue(forKey: key) }
      event.context?["app"] = app
    }
    return event
  }

  // Function references must not inherit start()'s MainActor isolation.
  private static func beforeSend(_ event: Event) -> Event? { scrub(event) }

  private static func beforeSendLog(_ entry: SentryLog) -> SentryLog? {
    guard entry.body == "Strozz playback health" else { return nil }
    entry.attributes = entry.attributes.filter { !$0.key.hasPrefix("user.") }
    return entry
  }

  private static func capture(_ report: PlaybackTelemetryReport) throws {
    let record = report.record
    let streams = active.update(record)
    SentrySDK.configureScope { scope in
      scope.setContext(value: Dictionary(uniqueKeysWithValues: streams.map {
        ($0.sessionID, ["channel": $0.channel, "mode": $0.playbackMode, "event": $0.name,
                       "sequence": String($0.sequence)])
      }), key: "playback_streams")
    }
    if report.kind == .context { return }
    let breadcrumb = Breadcrumb(level: report.kind == .incident ? .warning : .info, category: "strozz.playback")
    breadcrumb.message = record.name
    breadcrumb.setData(value: record.sessionID, key: "stream_session_id")
    breadcrumb.setData(value: record.channel, key: "channel")
    breadcrumb.setData(value: record.sequence, key: "sequence")
    SentrySDK.addBreadcrumb(breadcrumb)
    if report.kind == .health {
      var attributes: [String: Any] = [
        "stream_session_id": record.sessionID, "channel": record.channel,
        "playback_mode": record.playbackMode, "event_name": record.name,
        "record_sequence": record.sequence, "apple_platform": platform,
        "history_records_omitted": report.historyRecordsOmitted,
        "incidents_coalesced": report.incidentsCoalesced,
        "remote_queue_records_omitted": record.counters["remote_queue_records_omitted"] ?? 0,
      ]
      for key in ["source", "phase", "presentation", "quality", "resolved_quality", "playback_profile"] {
        attributes[key] = record.attributes[key]
      }
      for key in ["buffer_ahead_seconds", "playhead_seconds", "clock_not_advancing_seconds",
                  "video_frame_age_seconds", "duration_seconds", "wall_clock_latency_seconds"] {
        attributes[key] = record.metrics[key]
      }
      for key in ["user_paused", "background", "loading", "offline", "decode_frozen"] {
        attributes[key] = record.flags[key]
      }
      SentrySDK.logger.info("Strozz playback health", attributes: attributes)
      return
    }
    let event = Event(level: report.kind == .recovery ? .info : record.level == .error ? .error : .warning)
    let groupedName = report.originalFingerprint?.dropFirst().first ?? record.name
    event.message = SentryMessage(formatted: "Strozz playback: \(groupedName)")
    event.timestamp = record.timestamp
    event.fingerprint = report.originalFingerprint ?? PlaybackTelemetryReportState.fingerprint(record)
    event.tags = ["application": "strozz", "apple_platform": platform,
                  "stream_session_id": record.sessionID, "channel": record.channel,
                  "playback_mode": record.playbackMode, "playback_event": record.name,
                  "diagnostic_kind": report.kind.rawValue]
    event.context = ["playback": [
      "attributes": record.attributes, "metrics": record.metrics, "counters": record.counters,
      "flags": record.flags, "sequence": record.sequence,
      "history_records_omitted": report.historyRecordsOmitted,
      "incidents_coalesced": report.incidentsCoalesced,
    ]]
    let history = try PlaybackTelemetryReportState.encodedHistory(report.history)
    SentrySDK.capture(event: event) { scope in
      scope.clearAttachments()
      scope.addAttachment(Attachment(data: history, filename: "playback-history.json"))
    }
  }
}

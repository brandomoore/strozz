import Foundation
import OSLog

struct PlaybackTelemetryReport: Sendable {
  enum Kind: String, Sendable { case incident, health, context }
  let kind: Kind
  let record: PlaybackTelemetryRecord
  let history: [PlaybackTelemetryRecord]
  let historyRecordsOmitted: Int
  let incidentsCoalesced: Int
}

enum PlaybackTelemetryDistribution {
  static func environment(receiptName: String?, debug: Bool, simulator: Bool,
                          verification: Bool, developmentRequested: Bool) -> String? {
    if debug && verification { return "verification" }
    guard !simulator else { return nil }
    if debug { return developmentRequested ? "development" : nil }
    return receiptName == "sandboxReceipt" ? "testflight" : nil
  }
}

struct PlaybackTelemetryReportState {
  private struct Session {
    var history: [(record: PlaybackTelemetryRecord, bytes: Int)] = []
    var bytes = 2
    var omitted = 0
    var coalesced = 0
    var lastSeen: Double
    var lastHealth = -Double.infinity
    var lastContext = -Double.infinity
    var fingerprints: [String: Double] = [:]
    var incidents: [Double] = []
  }

  private var sessions: [String: Session] = [:]
  private var incidents: [Double] = []
  let maximumSessions: Int
  let maximumHistoryRecords: Int
  let maximumHistoryBytes: Int

  init(maximumSessions: Int = 32, maximumHistoryRecords: Int = 128,
       maximumHistoryBytes: Int = 64 * 1024) {
    precondition(maximumSessions > 0 && maximumHistoryRecords > 0 && maximumHistoryBytes >= 2)
    self.maximumSessions = maximumSessions
    self.maximumHistoryRecords = maximumHistoryRecords
    self.maximumHistoryBytes = maximumHistoryBytes
  }

  var trackedSessionCount: Int { sessions.count }

  mutating func receive(_ input: PlaybackTelemetryRecord) throws -> [PlaybackTelemetryReport] {
    let record = Self.sanitized(input)
    let now = record.uptimeSeconds
    guard now.isFinite else { throw CocoaError(.coderInvalidValue) }
    var reports: [PlaybackTelemetryReport] = []
    if sessions[record.sessionID] == nil, sessions.count >= maximumSessions,
       let oldest = sessions.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
      if let last = oldest.value.history.last?.record {
        reports.append(PlaybackTelemetryReport(kind: .health, record: last,
          history: [], historyRecordsOmitted: oldest.value.omitted + oldest.value.history.count,
          incidentsCoalesced: oldest.value.coalesced))
      }
      sessions.removeValue(forKey: oldest.key)
    }
    var session = sessions[record.sessionID] ?? Session(lastSeen: now)
    session.lastSeen = now
    if record.name != "native_video_output_pull" {
      let size = try Self.encodedHistory([record]).count - 1
      if size + 2 <= maximumHistoryBytes {
        session.history.append((record, size))
        session.bytes += size
      } else {
        session.omitted += 1
      }
      while session.bytes > maximumHistoryBytes || session.history.count > maximumHistoryRecords {
        session.bytes -= session.history.removeFirst().bytes
        session.omitted += 1
      }
    }
    session.fingerprints = session.fingerprints.filter { now - $0.value < 30 }
    session.incidents.removeAll { now - $0 >= 60 }
    incidents.removeAll { now - $0 >= 60 }
    let significantWarning = record.level == .warning && [
      "stall_started", "seek_deadline_exceeded", "playback_scheduler_delay",
      "native_hls_resume_retry", "native_unrequested_pause_resume",
    ].contains(record.name)
    let unusedRendition = record.name == "native_hls_failure" && record.attributes["scope"] == "rendition"
    if (record.level == .error || significantWarning) && !unusedRendition {
      let fingerprint = Self.fingerprint(record).joined(separator: "|")
      if session.fingerprints[fingerprint] == nil && session.incidents.count < 12 && incidents.count < 120 {
        reports.append(PlaybackTelemetryReport(kind: .incident, record: record,
          history: session.history.map(\.record), historyRecordsOmitted: session.omitted,
          incidentsCoalesced: session.coalesced))
        session.fingerprints[fingerprint] = now
        session.incidents.append(now)
        incidents.append(now)
      } else {
        session.coalesced += 1
      }
    }
    if ["session_started", "session_ended", "app_backgrounded", "app_foregrounded"].contains(record.name)
      || (record.kind == "sample" && now - session.lastHealth >= 60) {
      reports.append(PlaybackTelemetryReport(kind: .health, record: record, history: [],
        historyRecordsOmitted: session.omitted, incidentsCoalesced: session.coalesced))
      session.lastHealth = now
      session.coalesced = 0
    } else if record.kind == "sample" && now - session.lastContext >= 5 {
      reports.append(PlaybackTelemetryReport(kind: .context, record: record, history: [],
        historyRecordsOmitted: session.omitted, incidentsCoalesced: session.coalesced))
      session.lastContext = now
    }
    if record.name == "session_ended" { sessions.removeValue(forKey: record.sessionID) }
    else { sessions[record.sessionID] = session }
    return reports
  }

  static func fingerprint(_ record: PlaybackTelemetryRecord) -> [String] {
    ["strozz-playback", record.name] + ["error_domain", "error_code", "detail", "scope", "operation"]
      .map { record.attributes[$0] ?? "none" }
  }

  static func encodedHistory(_ records: [PlaybackTelemetryRecord]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(records)
  }

  static func sanitized(_ input: PlaybackTelemetryRecord) -> PlaybackTelemetryRecord {
    let allowed: Set<String> = [
      "source", "quality", "resolved_quality", "playback_profile", "presentation", "quality_budget",
      "video_surface", "phase", "item_status", "time_control_status", "waiting_reason", "thermal_state",
      "reason", "operation", "scope", "detail", "status", "error_domain", "error_code", "outcome",
      "app_version", "app_build", "os_version", "input_format", "format", "codec", "codecs",
      "resolution", "pipeline", "video_codec",
      "audio_codec", "native_generation", "counter", "item_id", "host", "asset_host", "stage",
      "audio_category", "audio_mode", "audio_route_reason", "audio_output_ports", "audio_input_ports",
      "route_change_reason", "audio_session_category", "audio_session_mode",
    ]
    var attributes = input.attributes.filter { key, _ in
      allowed.contains(key) || ((key.hasPrefix("from_") || key.hasPrefix("to_"))
        && allowed.contains(String(key.dropFirst(key.hasPrefix("from_") ? 5 : 3))))
    }.mapValues(redact)
    for key in ["host", "asset_host"] {
      if let host = attributes[key] { attributes[key] = PlaybackTelemetryWriter.sanitizedHost(host) }
    }
    func safeKey(_ key: String) -> Bool {
      key.count <= 100 && key.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil
        && !["token", "signature", "password", "cookie", "email", "account", "user_id", "participant",
             "authorization", "secret", "activation", "client_id", "credential"]
          .contains(where: key.contains)
    }
    return PlaybackTelemetryRecord(schemaVersion: input.schemaVersion, timestamp: input.timestamp,
      uptimeSeconds: input.uptimeSeconds, sessionID: redact(input.sessionID), sequence: input.sequence,
      kind: redact(input.kind), name: redact(input.name), level: input.level,
      channel: redact(input.channel), playbackMode: redact(input.playbackMode), attributes: attributes,
      metrics: input.metrics.filter { safeKey($0.key) && $0.value.isFinite },
      counters: input.counters.filter { safeKey($0.key) }, flags: input.flags.filter { safeKey($0.key) })
  }

  static func redact(_ value: String) -> String {
    PlaybackTelemetryWriter.redact(value).replacingOccurrences(
      of: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
      with: "<email>", options: .regularExpression)
      .replacingOccurrences(of: #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#,
        with: "<address>", options: .regularExpression)
      .replacingOccurrences(of: #"(?i)(?<![0-9a-f:])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.%]+"#,
        with: "<address>", options: .regularExpression)
  }
}

/// One bounded utility queue for all pane writers, independent of local file retention.
final class PlaybackTelemetryRemote: @unchecked Sendable {
  static let shared = PlaybackTelemetryRemote()
  private static let log = Logger(subsystem: "com.thatcube.Strozz", category: "remote-playback-telemetry")
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.thatcube.Strozz.remote-playback-telemetry", qos: .utility)
  private var sink: (@Sendable (PlaybackTelemetryReport) throws -> Void)?
  private var pending: [String: Int] = [:]
  private var pendingCount = 0
  private var dropped = 0
  private var state = PlaybackTelemetryReportState()

  init(sink: (@Sendable (PlaybackTelemetryReport) throws -> Void)? = nil) {
    self.sink = sink
  }

  func enable(sink: @escaping @Sendable (PlaybackTelemetryReport) throws -> Void) {
    lock.withLock { self.sink = sink }
  }

  func append(_ input: PlaybackTelemetryRecord) {
    lock.lock()
    guard let sink else { lock.unlock(); return }
    guard pendingCount < 512, pending[input.sessionID, default: 0] < 64 else {
      dropped += 1
      let first = dropped == 1
      lock.unlock()
      if first { Self.log.error("Remote diagnostics queue full; omissions will be reported") }
      return
    }
    let omitted = dropped
    dropped = 0
    pendingCount += 1
    pending[input.sessionID, default: 0] += 1
    lock.unlock()
    queue.async { [self] in
      defer {
        lock.withLock {
          pendingCount -= 1
          pending[input.sessionID, default: 0] -= 1
          if pending[input.sessionID] == 0 { pending.removeValue(forKey: input.sessionID) }
        }
      }
      var record = input
      if omitted > 0 { record.counters["remote_queue_records_omitted"] = omitted }
      do {
        for report in try state.receive(record) { try sink(report) }
      } catch {
        lock.withLock { dropped += 1 }
        Self.log.error("Remote diagnostics preparation failed (code \((error as NSError).code))")
      }
    }
  }

  func flush() async {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }
}

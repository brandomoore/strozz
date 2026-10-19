import Foundation
import OSLog

/// Queue-confined encoding; retention coordinates open files across pane writers.
/// Bounded admission never makes the player wait for disk or an overloaded queue.
final class PlaybackTelemetryWriter: @unchecked Sendable {
  private final class FileState: @unchecked Sendable {
    let lock = NSLock()
    var openFiles: Set<URL> = []
  }
  private enum PersistenceError: Error { case activeFileCapacity }
  private static let files = FileState()
  private static let log = Logger(subsystem: "com.thatcube.Strozz", category: "PlaybackTelemetry")
  private let queue: DispatchQueue
  private let admissionLock = NSLock()
  private var pending = 0
  private var dropped = 0
  private let maximumPending: Int
  private let directory: URL
  private let maximumFileBytes: Int
  private let maximumFiles: Int
  private let mirrorToSystemLog: Bool
  private let encoder: JSONEncoder
  private let uptime: @Sendable () -> TimeInterval
  private var handle: FileHandle?
  private var partURL: URL?
  private var bytes = 0
  private var part = 0
  private var manifest: Manifest?
  private var retryAt: TimeInterval = 0
  private var nextFileCheckAt: TimeInterval = 0
  private var persistenceRecovery: String?
  private var unconfirmedRecords = 0
  private var lastWriteErrorCode: Int?

  private struct Manifest: Encodable {
    let schemaVersion = 1
    let sessionID: String
    var fileName: String
    let channel: String
    let playbackMode: String
    let startedAt: Date
    var endedAt: Date?
  }

  init(
    directory: URL = URL.cachesDirectory.appendingPathComponent("PlaybackDiagnostics", isDirectory: true),
    maximumFileBytes: Int = 4 * 1024 * 1024, maximumFiles: Int = 8,
    maximumPending: Int = 256, mirrorToSystemLog: Bool = true,
    queue: DispatchQueue = DispatchQueue(label: "com.thatcube.Strozz.playback-telemetry", qos: .utility),
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    precondition(maximumFileBytes > 0 && maximumFiles > 0 && maximumPending > 0)
    self.directory = directory.standardizedFileURL
    self.maximumFileBytes = maximumFileBytes
    self.maximumFiles = maximumFiles
    self.maximumPending = maximumPending
    self.mirrorToSystemLog = mirrorToSystemLog
    self.queue = queue
    self.uptime = uptime
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
  }

  deinit {
    let handle = handle
    let url = partURL
    let state = Self.files
    queue.async {
      state.lock.lock()
      defer { state.lock.unlock() }
      do { try handle?.close() }
      catch { PlaybackTelemetryWriter.log.error("Playback telemetry close failed (code \((error as NSError).code))") }
      if let url { state.openFiles.remove(url) }
    }
  }

  func append(_ record: PlaybackTelemetryRecord) {
    admissionLock.lock()
    guard pending < maximumPending else {
      dropped += 1
      let firstDrop = dropped == 1
      admissionLock.unlock()
      if firstDrop { Self.log.error("Playback telemetry queue full; records are being dropped") }
      return
    }
    pending += 1
    let droppedBefore = dropped
    dropped = 0
    admissionLock.unlock()
    queue.async { [self] in
      defer {
        admissionLock.lock()
        pending -= 1
        admissionLock.unlock()
      }
      // Panes have independent queues, but share the directory and retention limit.
      Self.files.lock.lock()
      defer { Self.files.lock.unlock() }
      var record = record
      record.attributes = record.attributes.filter { key, _ in
        let key = key.lowercased()
        return !["error", "error_comment", "avplayer_session_id"].contains(key)
          && !["token", "signature", "authorization", "password", "secret", "header", "cookie"].contains(where: key.contains)
      }.mapValues(Self.redact)
      for (key, value) in record.attributes where key == "host" || key.hasSuffix("_host") {
        record.attributes[key] = Self.sanitizedHost(value)
      }
      record.metrics = record.metrics.filter { $0.value.isFinite }
      if droppedBefore > 0 { record.counters["telemetry_records_dropped"] = droppedBefore }
      if mirrorToSystemLog, record.level != .debug {
        Self.log.info("session=\(record.sessionID, privacy: .public) #\(record.sequence) \(record.name, privacy: .public)")
      }
      let now = uptime()
      do {
        var data = try encoder.encode(record)
        data.append(0x0A)
        guard data.count <= maximumFileBytes else {
          Self.log.error("Playback telemetry record exceeds file limit; dropping sequence \(record.sequence)")
          return
        }
        if manifest?.sessionID != record.sessionID {
          try closePart()
          part = 0
          retryAt = 0
          nextFileCheckAt = 0
          persistenceRecovery = nil
          unconfirmedRecords = 0
          lastWriteErrorCode = nil
          manifest = Manifest(sessionID: record.sessionID, fileName: "", channel: record.channel,
                              playbackMode: record.playbackMode, startedAt: record.timestamp)
        }
        guard now >= retryAt else {
          unconfirmedRecords += 1
          return
        }
        if let partURL, now >= nextFileCheckAt {
          nextFileCheckAt = now + 15
          if !FileManager.default.fileExists(atPath: partURL.path) {
            Self.log.error("An active playback telemetry file disappeared; opening a new part")
            try closePart()
            persistenceRecovery = "active_file_missing"
          }
        }
        if let persistenceRecovery {
          record.attributes["telemetry_persistence_recovery"] = persistenceRecovery
          if unconfirmedRecords > 0 { record.counters["telemetry_persistence_records_unconfirmed"] = unconfirmedRecords }
          record.counters["telemetry_last_write_error_code"] = lastWriteErrorCode
          data = try encoder.encode(record)
          data.append(0x0A)
          guard data.count <= maximumFileBytes else {
            unconfirmedRecords += 1
            Self.log.error("Recovered telemetry record exceeds file limit; dropping sequence \(record.sequence)")
            return
          }
        }
        if handle == nil || bytes + data.count > maximumFileBytes {
          try openPart()
          nextFileCheckAt = now + 15
        }
        try handle?.write(contentsOf: data)
        bytes += data.count
        retryAt = 0
        persistenceRecovery = nil
        unconfirmedRecords = 0
        lastWriteErrorCode = nil
        if record.name == "session_ended" {
          manifest?.endedAt = record.timestamp
          try saveManifest()
          try handle?.synchronize()
          try closePart()
        }
      } catch {
        unconfirmedRecords += 1
        retryAt = now + 5
        persistenceRecovery = "write_failure"
        lastWriteErrorCode = (error as NSError).code
        // Do not print NSError/userInfo or paths which might contain user data.
        Self.log.error("Playback telemetry persistence failed (code \((error as NSError).code)); retrying after backoff")
        do { try closePart() }
        catch { Self.log.error("Playback telemetry recovery close failed (code \((error as NSError).code))") }
      }
    }
  }

  /// Drains earlier writes without blocking the main actor. Used by tests and
  /// orderly backgrounding; abrupt termination can still leave an incomplete tail.
  func flush() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        do { try handle?.synchronize() }
        catch { Self.log.error("Playback telemetry flush failed (code \((error as NSError).code))") }
        continuation.resume()
      }
    }
  }

  private func openPart() throws {
    try closePart()
    let active = Self.files.openFiles.filter { $0.deletingLastPathComponent() == directory }
    guard active.count < maximumFiles else {
      Self.log.error("Playback telemetry active-file capacity exhausted")
      throw PersistenceError.activeFileCapacity
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var directory = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    guard let sessionID = manifest?.sessionID else { return }
    part += 1
    let name = "playback-\(sessionID)-\(String(format: "%04d", part)).jsonl"
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    handle = try FileHandle(forWritingTo: url)
    partURL = url
    Self.files.openFiles.insert(url)
    bytes = 0
    manifest?.fileName = name
    try saveManifest()
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
    ).filter {
      $0.lastPathComponent.hasPrefix("playback-") && $0.pathExtension == "jsonl"
        && !Self.files.openFiles.contains($0)
    }
    let dated = try files.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) }
    for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(maximumFiles - active.count - 1) {
      try FileManager.default.removeItem(at: old)
    }
  }

  private func closePart() throws {
    let closing = handle
    handle = nil
    if let url = partURL { Self.files.openFiles.remove(url) }
    partURL = nil
    try closing?.close()
  }

  private func saveManifest() throws {
    try encoder.encode(manifest).write(to: directory.appendingPathComponent("latest-session.json"), options: .atomic)
  }

  static func redact(_ text: String) -> String {
    // Free-form network errors are excluded upstream; these are defense-in-depth
    // for future call sites, including our custom HLS scheme and JSON auth fields.
    var text = text.replacingOccurrences(
      of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"']+"#, with: "<url>", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"(?i)\b(?:bearer|oauth)\s*[: ]\s*[A-Za-z0-9._~+/%=-]+"#,
      with: "<credential>", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"(?i)["']?(?:[A-Za-z_]*token|[A-Za-z_]*signature|sig|authorization|client_secret|password)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;&]+)"#,
      with: "<credential>", options: .regularExpression)
    return String(text.prefix(500))
  }

  static func sanitizedHost(_ host: String) -> String {
    if !host.isEmpty && (host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." })) {
      return "<address>"
    }
    return host
  }
}

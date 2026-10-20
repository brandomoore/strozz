import Foundation
import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

private final class RemoteReports: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [PlaybackTelemetryReport] = []
  func append(_ report: PlaybackTelemetryReport) { lock.withLock { storage.append(report) } }
  var values: [PlaybackTelemetryReport] { lock.withLock { storage } }
}

final class PlaybackTelemetryRemoteTests: XCTestCase {
  private func record(_ name: String, session: String = "fixture-session", time: Double = 0,
                      level: PlaybackTelemetryLevel = .info, kind: String = "event",
                      attributes: [String: String] = [:]) -> PlaybackTelemetryRecord {
    PlaybackTelemetryRecord(schemaVersion: 1, timestamp: Date(timeIntervalSince1970: time),
      uptimeSeconds: time, sessionID: session, sequence: Int(time) + 1, kind: kind, name: name,
      level: level, channel: "fixture", playbackMode: "live", attributes: attributes,
      metrics: [:], counters: [:], flags: [:])
  }

  func testOnlyTestFlightOrExplicitDevelopmentVerificationUploadsAutomatically() {
    XCTAssertEqual(PlaybackTelemetryDistribution.environment(receiptName: "sandboxReceipt",
      debug: false, simulator: false, verification: false, developmentRequested: false), "testflight")
    for receipt in [nil, "receipt"] {
      XCTAssertNil(PlaybackTelemetryDistribution.environment(receiptName: receipt,
        debug: false, simulator: false, verification: false, developmentRequested: true))
    }
    XCTAssertNil(PlaybackTelemetryDistribution.environment(receiptName: "sandboxReceipt",
      debug: true, simulator: false, verification: false, developmentRequested: false))
    XCTAssertNil(PlaybackTelemetryDistribution.environment(receiptName: "sandboxReceipt",
      debug: false, simulator: true, verification: true, developmentRequested: true))
    XCTAssertEqual(PlaybackTelemetryDistribution.environment(receiptName: nil,
      debug: true, simulator: false, verification: false, developmentRequested: true), "development")
    XCTAssertEqual(PlaybackTelemetryDistribution.environment(receiptName: nil,
      debug: true, simulator: true, verification: true, developmentRequested: false), "verification")
  }

  func testOptedInDevelopmentBuildReportsWithoutLaunchEnvironmentButNeverEnablesOtherDistributions() {
    XCTAssertEqual(PlaybackTelemetryDistribution.environment(receiptName: nil,
      debug: true, simulator: false, verification: false, developmentRequested: false,
      developmentBuildEnabled: true), "development")
    XCTAssertNil(PlaybackTelemetryDistribution.environment(receiptName: nil,
      debug: true, simulator: true, verification: false, developmentRequested: false,
      developmentBuildEnabled: true))
    for receipt in [nil, "receipt"] {
      XCTAssertNil(PlaybackTelemetryDistribution.environment(receiptName: receipt,
        debug: false, simulator: false, verification: false, developmentRequested: false,
        developmentBuildEnabled: true))
    }
  }

  func testEveryConcurrentPaneRetainsItsOwnIncidentHistory() throws {
    var state = PlaybackTelemetryReportState()
    var incidents: [PlaybackTelemetryReport] = []
    for pane in 0..<8 {
      _ = try state.receive(record("session_started", session: "pane-\(pane)"))
    }
    for time in 1...20 {
      for pane in 0..<8 {
        _ = try state.receive(record("playback_sample", session: "pane-\(pane)",
          time: Double(time), level: .debug, kind: "sample"))
      }
    }
    for pane in 0..<8 {
      incidents += try state.receive(record("native_hls_failure", session: "pane-\(pane)",
        time: 21, level: .error, attributes: ["scope": "engine"])).filter { $0.kind == .incident }
    }
    XCTAssertEqual(incidents.count, 8)
    for report in incidents {
      XCTAssertEqual(report.history.count, 22)
      XCTAssertTrue(report.history.allSatisfy { $0.sessionID == report.record.sessionID })
    }
    XCTAssertEqual(state.trackedSessionCount, 8)
  }

  func testRapidHealthyChannelChangesAreReportedWithoutLeakingSessionState() throws {
    var state = PlaybackTelemetryReportState()
    var reports: [PlaybackTelemetryReport] = []
    for index in 0..<200 {
      let session = "stream-\(index)"
      reports += try state.receive(record("session_started", session: session, time: Double(index * 2)))
      reports += try state.receive(record("session_ended", session: session, time: Double(index * 2 + 1)))
    }
    XCTAssertEqual(reports.count, 400)
    XCTAssertTrue(reports.allSatisfy { $0.kind == .health })
    XCTAssertEqual(state.trackedSessionCount, 0)
  }

  func testHealthyStreamsSendMinuteHeartbeatsRatherThanEverySample() throws {
    var state = PlaybackTelemetryReportState()
    var reports = try state.receive(record("session_started"))
    for time in 1...180 {
      reports += try state.receive(record("playback_sample", time: Double(time), kind: "sample"))
    }
    XCTAssertEqual(reports.filter { $0.kind == .health }.count, 4)
    XCTAssertFalse(reports.contains { $0.kind == .incident })
    XCTAssertLessThanOrEqual(reports.filter { $0.kind == .context }.count, 37)
  }

  func testDuplicateFailuresRemainInHistoryAndAreCountedInTheNextHealthReport() throws {
    var state = PlaybackTelemetryReportState()
    _ = try state.receive(record("session_started"))
    var incidents: [PlaybackTelemetryReport] = []
    for time in 1...20 {
      incidents += try state.receive(record("native_hls_resume_failed", time: Double(time),
        level: .error, attributes: ["error_code": "-1005"])).filter { $0.kind == .incident }
    }
    XCTAssertEqual(incidents.count, 1)
    let health = try XCTUnwrap(state.receive(record("session_ended", time: 21)).first { $0.kind == .health })
    XCTAssertEqual(health.incidentsCoalesced, 19)
  }

  func testRecoveryCheckpointRetainsLateTransferAndResumeEvidenceInTheSameIssue() throws {
    var state = PlaybackTelemetryReportState()
    let failure = record("native_hls_failure", time: 10, level: .error,
      attributes: ["error_code": "-1001", "operation": "media"])
    _ = try state.receive(failure)
    _ = try state.receive(record("native_hls_delivery_timing", time: 11,
      attributes: ["stage": "media_transfer", "request_phase": "receiving_body",
                   "network_protocol": "h2", "connection_reused": "true"]))
    let interrupted = try state.receive(record("stall_ended", time: 12,
      attributes: ["outcome": "interrupted"]))
    XCTAssertFalse(interrupted.contains { $0.kind == .recovery },
      "Entering reconnect is not proof that playback recovered")
    _ = try state.receive(record("native_hls_resume_resolved", time: 14))
    let checkpoint = try XCTUnwrap(state.receive(record("first_video_output_frame", time: 20))
      .first { $0.kind == .recovery })
    XCTAssertEqual(checkpoint.originalFingerprint, PlaybackTelemetryReportState.fingerprint(failure))
    XCTAssertTrue(checkpoint.history.contains { $0.attributes["stage"] == "media_transfer" })
    XCTAssertTrue(checkpoint.history.contains { $0.name == "native_hls_resume_resolved" })
    XCTAssertEqual(checkpoint.history.last?.name, "first_video_output_frame")
    XCTAssertEqual(checkpoint.record.metrics["since_incident_seconds"], 10)
    XCTAssertEqual(checkpoint.record.attributes["outcome"], "fresh_frame")
    XCTAssertFalse(try state.receive(record("session_ended", time: 21)).contains { $0.kind == .recovery })
  }

  func testAPlayingStatusWithoutClockProgressCannotProduceARecoveryCheckpoint() throws {
    var state = PlaybackTelemetryReportState()
    _ = try state.receive(record("stall_started", time: 1, level: .warning))
    let waiting = record("playback_sample", time: 10, kind: "sample", attributes: ["phase": "playing"])
    XCTAssertFalse(try state.receive(waiting).contains { $0.kind == .recovery })
    var progressed = record("playback_sample", time: 12, kind: "sample", attributes: ["phase": "playing"])
    progressed.metrics["clock_delta_seconds"] = 2
    let checkpoint = try XCTUnwrap(state.receive(progressed).first { $0.kind == .recovery })
    XCTAssertEqual(checkpoint.record.attributes["outcome"], "clock_progress")
  }

  func testIncidentCheckpointDoesNotTreatAClosedSessionAsSuccessfulPlayback() throws {
    var state = PlaybackTelemetryReportState()
    _ = try state.receive(record("load_failed", time: 1, level: .error))
    let end = try XCTUnwrap(state.receive(record("session_ended", time: 2))
      .first { $0.kind == .recovery })
    XCTAssertEqual(end.record.name, "session_ended")
    XCTAssertEqual(end.record.attributes["outcome"], "session_ended")
    XCTAssertFalse(end.history.contains { $0.name == "first_video_output_frame" })
    XCTAssertEqual(state.trackedSessionCount, 0)
    _ = try state.receive(record("load_failed", session: "new", time: 3, level: .error))
    XCTAssertFalse(try state.receive(record("first_video_output_frame", session: "new", time: 124))
      .contains { $0.kind == .recovery }, "Do not attribute unrelated playback hours later to this stall")
  }

  func testOneNoisyPaneCannotSpendEveryOtherPanesIncidentBudget() throws {
    var state = PlaybackTelemetryReportState()
    var reports: [PlaybackTelemetryReport] = []
    for error in 0..<200 {
      reports += try state.receive(record("load_failed", time: Double(error) / 100,
        level: .error, attributes: ["error_code": String(error)]))
    }
    XCTAssertEqual(reports.filter { $0.kind == .incident }.count, 12)
    for pane in 1...7 {
      let fresh = try state.receive(record("load_failed", session: "pane-\(pane)", time: 3, level: .error))
      XCTAssertEqual(fresh.filter { $0.kind == .incident }.count, 1)
    }
  }

  func testUnusedRenditionFailureDoesNotBecomeAnActivePlaybackIncident() throws {
    var state = PlaybackTelemetryReportState()
    XCTAssertTrue(try state.receive(record("native_hls_failure", level: .error,
      attributes: ["scope": "rendition"])).isEmpty)
    XCTAssertEqual(try state.receive(record("native_hls_failure", time: 1, level: .error,
      attributes: ["scope": "engine"])).filter { $0.kind == .incident }.count, 1)
  }

  func testIncidentHistoryKeepsStructuredResourceTimingWithoutPerFrameNoise() throws {
    var state = PlaybackTelemetryReportState()
    _ = try state.receive(record("native_video_output_pull", time: 1))
    _ = try state.receive(record("native_hls_request", time: 2,
      attributes: ["stage": "upstream", "resolution": "1920x1080", "codecs": "avc1.64002a,mp4a.40.2"]))
    let incident = try XCTUnwrap(state.receive(record("native_hls_failure", time: 3, level: .error)).first)
    XCTAssertTrue(incident.history.contains { $0.name == "native_hls_request" })
    XCTAssertEqual(incident.history.first?.attributes["resolution"], "1920x1080")
    XCTAssertEqual(incident.history.first?.attributes["codecs"], "avc1.64002a,mp4a.40.2")
    XCTAssertFalse(incident.history.contains { $0.name == "native_video_output_pull" })
  }

  func testHistoryHasAnExactCountAndEncodedByteBudget() throws {
    var state = PlaybackTelemetryReportState(maximumHistoryRecords: 3, maximumHistoryBytes: 2048)
    for time in 0..<100 {
      _ = try state.receive(record("playback_sample", time: Double(time), kind: "sample"))
    }
    let report = try XCTUnwrap(state.receive(record("load_failed", time: 101, level: .error)).first)
    XCTAssertLessThanOrEqual(report.history.count, 3)
    XCTAssertLessThanOrEqual(try PlaybackTelemetryReportState.encodedHistory(report.history).count, 2048)
    XCTAssertGreaterThanOrEqual(report.historyRecordsOmitted, 98)
  }

  func testRemotePayloadCannotContainCredentialsChatEmailOrNetworkAddresses() throws {
    var input = record("load_failed", level: .error, attributes: [
      "reason": "https://video.example.test/live?token=secret-token bearer abc123 viewer@example.com 198.51.100.2 2001:db8::1",
      "authorization": "Bearer secret-token", "chat_text": "private chat",
      "asset_host": "192.0.2.10", "error_code": "-1005", "quality": "1080p60",
    ])
    input.metrics = ["buffer_ahead_seconds": 3, "token_value": 12, "invalid_seconds": .nan,
                     "activation_code": 123456, "client_id": 123]
    input.counters = ["account_id": 123, "video_samples": 30]
    let sanitized = PlaybackTelemetryReportState.sanitized(input)
    let encoded = String(decoding: try JSONEncoder().encode(sanitized), as: UTF8.self)
    for secret in ["secret-token", "abc123", "viewer@example.com", "private chat", "192.0.2.10",
                   "video.example.test", "account_id", "token_value", "activation_code", "client_id",
                   "198.51.100.2", "2001:db8::1"] {
      XCTAssertFalse(encoded.contains(secret), secret)
    }
    XCTAssertEqual(sanitized.attributes["error_code"], "-1005")
    XCTAssertEqual(sanitized.metrics["buffer_ahead_seconds"], 3)
    XCTAssertEqual(sanitized.counters["video_samples"], 30)
  }

  func testRemoteDeliverySurvivesLocalCacheWriteFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))
    defer { try? FileManager.default.removeItem(at: directory) }
    let reports = RemoteReports()
    let remote = PlaybackTelemetryRemote(sink: { reports.append($0) })
    let writer = PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false, remote: remote)
    writer.append(record("native_hls_resume_failed", level: .error))
    await writer.flush()
    XCTAssertEqual(reports.values.filter { $0.kind == .incident }.count, 1)
  }

  func testBlockedDeliveryDoesNotBlockPlaybackOrStarveAnotherPane() async {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let reports = RemoteReports()
    let remote = PlaybackTelemetryRemote(sink: { report in
      reports.append(report)
      if report.record.name == "session_started" && report.record.sessionID == "noisy" {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
    })
    remote.append(record("session_started", session: "noisy"))
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    let started = ProcessInfo.processInfo.systemUptime
    for index in 1...300 {
      remote.append(record("playback_sample", session: "noisy", time: Double(index), kind: "sample"))
    }
    remote.append(record("session_started", session: "other"))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1)
    release.signal()
    await remote.flush()
    let other = reports.values.first { $0.record.sessionID == "other" }
    XCTAssertNotNil(other)
    XCTAssertGreaterThan(other?.record.counters["remote_queue_records_omitted"] ?? 0, 0)
  }
}

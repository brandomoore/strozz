import AVFoundation
import XCTest

#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

private final class TelemetryTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval = 0
  var now: TimeInterval { lock.withLock { time } }
  func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

@MainActor
final class PlaybackTelemetryTests: XCTestCase {
  func testFailureCheckpointSurvivesVerboseRotationAndKeepsOriginalCause() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
      directory: directory, maximumFileBytes: 1_024, maximumFiles: 2,
      mirrorToSystemLog: false, remote: nil))
    recorder.beginSession(channel: "fixture", playbackMode: "live", attributes: ["app_build": "fixture"])
    recorder.recordEvent("native_hls_resume_failed", level: .error,
      attributes: ["error_domain": NSURLErrorDomain, "error_code": "-1001",
                   "error": "must never be saved", "token": "private",
                   "reason": "https://example.com/?token=private"])
    await recorder.flush()
    for _ in 0..<20 {
      recorder.recordEvent("native_hls_delivery_timing", level: .debug,
        attributes: ["detail": String(repeating: "x", count: 300)])
      await recorder.flush()
    }
    var snapshot = waitingSnapshot()
    snapshot.flags["error_present"] = true
    snapshot.attributes["recovery_blocked_by"] = "terminal_error"
    recorder.recordSnapshot(snapshot)
    await recorder.flush()
    XCTAssertFalse(try records(in: directory).contains { $0.name == "native_hls_resume_failed" })
    let id = try XCTUnwrap(recorder.sessionID)
    let file = directory.appendingPathComponent("Incidents/incident-\(id).json")
    let data = try Data(contentsOf: file)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "incident-\(id).json"
    attachment.lifetime = .keepAlways
    add(attachment)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let first = try XCTUnwrap(saved["firstFailure"] as? [String: Any])
    let attributes = try XCTUnwrap(first["attributes"] as? [String: String])
    XCTAssertEqual(first["name"] as? String, "native_hls_resume_failed")
    XCTAssertEqual(attributes["error_code"], "-1001")
    XCTAssertNil(attributes["error"])
    XCTAssertNil(attributes["token"])
    XCTAssertEqual(attributes["reason"], "<url>")
    XCTAssertNotNil(saved["sessionStarted"])
    let latest = try XCTUnwrap(saved["latestSample"] as? [String: Any])
    XCTAssertEqual((latest["attributes"] as? [String: String])?["phase"], "failed")
    XCTAssertEqual((latest["attributes"] as? [String: String])?["recovery_blocked_by"], "terminal_error")
    XCTAssertLessThanOrEqual(data.count, PlaybackTelemetryWriter.maximumIncidentBytes)
    XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    recorder.endSession(reason: "test")
    await recorder.flush()
  }

  func testFailuresHaveBoundedReservedAdmissionAndIndependentPersistence() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = DispatchQueue(label: "incident-priority-test")
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
      directory: directory, maximumFileBytes: 1_024, maximumFiles: 1, maximumPending: 2,
      mirrorToSystemLog: false, remote: nil, queue: queue))
    queue.suspend()
    recorder.beginSession(channel: "fixture", playbackMode: "live")
    recorder.recordEvent("trace", level: .debug)
    recorder.recordEvent("trace_dropped", level: .debug)
    recorder.recordEvent("original_failure", level: .error,
      attributes: ["error_code": "-1009"])
    for _ in 0..<30 { recorder.recordEvent("repeated_failure", level: .error) }
    queue.resume()
    await recorder.flush()
    let id = try XCTUnwrap(recorder.sessionID)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
      directory.appendingPathComponent("Incidents/incident-\(id).json"))) as? [String: Any])
    let original = try XCTUnwrap(saved["firstFailure"] as? [String: Any])
    XCTAssertEqual(original["name"] as? String, "original_failure")
    let latest = try XCTUnwrap(saved["latestFailure"] as? [String: Any])
    XCTAssertLessThanOrEqual(try XCTUnwrap(latest["sequence"] as? Int), 19,
      "Reserved priority admission must still be bounded")
    recorder.endSession(reason: "test")
    await recorder.flush()
  }

  func testIncidentRetentionProtectsActivePanesAndBoundsClosedSessions() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let active = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
      directory: directory, maximumFiles: 2, maximumIncidentFiles: 2,
      mirrorToSystemLog: false, remote: nil))
    let rotating = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
      directory: directory, maximumFileBytes: 1_024, maximumFiles: 2, maximumIncidentFiles: 2,
      mirrorToSystemLog: false, remote: nil))
    active.beginSession(channel: "still-failed", playbackMode: "live")
    active.recordEvent("original_failure", level: .error)
    await active.flush()
    let activeID = try XCTUnwrap(active.sessionID)
    for index in 0..<8 {
      rotating.beginSession(channel: "other-\(index)", playbackMode: "live")
      rotating.recordEvent("other_failure", level: .error)
      rotating.endSession(reason: "test")
      await rotating.flush()
      let files = try FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("Incidents"), includingPropertiesForKeys: nil)
      XCTAssertEqual(files.count, 2)
      XCTAssertTrue(files.contains { $0.lastPathComponent == "incident-\(activeID).json" })
    }
    active.endSession(reason: "test")
    await active.flush()
  }

  func testIncidentPersistsWhenAnotherPaneOccupiesRawFileCapacity() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let active = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
      directory: directory, maximumFiles: 1, mirrorToSystemLog: false, remote: nil))
    let failed = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
      directory: directory, maximumFiles: 1, mirrorToSystemLog: false, remote: nil))
    active.beginSession(channel: "active", playbackMode: "live")
    await active.flush()
    failed.beginSession(channel: "failed", playbackMode: "live")
    failed.recordEvent("original_failure", level: .error)
    await failed.flush()
    let id = try XCTUnwrap(failed.sessionID)
    XCTAssertFalse(try records(in: directory).contains { $0.sessionID == id })
    let data = try Data(contentsOf: directory.appendingPathComponent("Incidents/incident-\(id).json"))
    let checkpoint = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual((checkpoint["firstFailure"] as? [String: Any])?["name"] as? String, "original_failure")
    active.endSession(reason: "test")
    failed.endSession(reason: "test")
    await active.flush()
    await failed.flush()
  }

  func testIncidentWriteFailureBacksOffWithoutLosingOriginalCause() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))
    let clock = TelemetryTestClock()
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
      directory: directory, mirrorToSystemLog: false, remote: nil, uptime: { clock.now }))
    recorder.beginSession(channel: "fixture", playbackMode: "live")
    recorder.recordEvent("original_failure", level: .error)
    await recorder.flush()
    try FileManager.default.removeItem(at: directory)
    clock.advance(1)
    recorder.recordEvent("repeated_failure", level: .error)
    await recorder.flush()
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    clock.advance(5)
    recorder.recordEvent("after_backoff")
    await recorder.flush()
    let id = try XCTUnwrap(recorder.sessionID)
    let data = try Data(contentsOf: directory.appendingPathComponent("Incidents/incident-\(id).json"))
    let checkpoint = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual((checkpoint["firstFailure"] as? [String: Any])?["name"] as? String, "original_failure")
    XCTAssertEqual((checkpoint["latestFailure"] as? [String: Any])?["name"] as? String, "repeated_failure")
    recorder.endSession(reason: "test")
    await recorder.flush()
  }

  func testDefaultVerboseRetentionHasThirtyTwoPartsOutsideCaches() async throws {
    XCTAssertTrue(PlaybackTelemetryWriter.defaultDirectory.path.contains("/Application Support/"))
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
      directory: directory, maximumFileBytes: 1_024, mirrorToSystemLog: false, remote: nil))
    recorder.beginSession(channel: "fixture", playbackMode: "live")
    for _ in 0..<70 {
      recorder.recordEvent("trace", level: .debug, attributes: ["detail": String(repeating: "x", count: 400)])
      await recorder.flush()
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
    XCTAssertEqual(files.count, 32)
    recorder.endSession(reason: "test")
    await recorder.flush()
  }

  func testTerminalErrorIsNotReportedAsAnEndlessBufferingStall() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
      directory: directory, mirrorToSystemLog: false, remote: nil))
    recorder.beginSession(channel: "fixture", playbackMode: "live")
    let start = ProcessInfo.processInfo.systemUptime
    var snapshot = waitingSnapshot()
    snapshot.flags["error_present"] = true
    snapshot.attributes["recovery_blocked_by"] = "terminal_error"
    for second in stride(from: 0, through: 12, by: 2) {
      recorder.recordSnapshot(snapshot, uptime: start + Double(second))
    }
    await recorder.flush()
    let saved = try records(in: directory)
    XCTAssertEqual(saved.filter { $0.name == "playback_error_presented" }.count, 1)
    XCTAssertFalse(saved.contains { $0.name == "stall_started" })
    XCTAssertTrue(saved.filter { $0.kind == "sample" }.allSatisfy { $0.attributes["phase"] == "failed" })
    recorder.endSession(reason: "test")
    await recorder.flush()
  }

  func testUnderlyingErrorCodesAreRetainedWithoutFreeformDescriptions() {
    let underlying = NSError(domain: NSURLErrorDomain, code: -1001,
      userInfo: [NSLocalizedDescriptionKey: "private-token", NSURLErrorFailingURLErrorKey: "https://secret.example"])
    let error = NSError(domain: AVFoundationErrorDomain, code: -11800,
      userInfo: [NSUnderlyingErrorKey: underlying])
    let attributes = PlaybackTelemetryRecorder.errorAttributes(error)
    XCTAssertEqual(attributes["underlying_error_domain_1"], NSURLErrorDomain)
    XCTAssertEqual(attributes["underlying_error_code_1"], "-1001")
    XCTAssertFalse(attributes.values.joined().contains("private"))
    XCTAssertFalse(attributes.values.joined().contains("secret"))
  }

  func testAnActiveLogRecoversWhenItsCacheFileDisappears() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TelemetryTestClock()
    let writer = PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false, uptime: { clock.now })
    let recorder = PlaybackTelemetryRecorder(writer: writer)
    recorder.beginSession(channel: "fixture", playbackMode: "live")
    await recorder.flush()
    let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" })
    try FileManager.default.removeItem(at: file)
    clock.advance(16)
    recorder.recordEvent("audio_probe")
    await recorder.flush()
    let saved = try records(in: directory)
    XCTAssertEqual(saved.last?.name, "audio_probe",
      "Writing to an unlinked handle must not silently lose the rest of an active pane's session")
    XCTAssertEqual(saved.last?.attributes["telemetry_persistence_recovery"], "active_file_missing")
    XCTAssertEqual(saved.last?.sessionID, recorder.sessionID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Never overwrite an old part name")
  }

  func testTransientPersistenceFailureBacksOffAndRecoversWithinTheSameSession() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))
    let clock = TelemetryTestClock()
    let writer = PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false, uptime: { clock.now })
    let recorder = PlaybackTelemetryRecorder(writer: writer)
    recorder.beginSession(channel: "fixture", playbackMode: "live")
    await recorder.flush()
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    clock.advance(1)
    recorder.recordEvent("during_backoff")
    await recorder.flush()
    XCTAssertTrue(try records(in: directory).isEmpty)
    clock.advance(5)
    recorder.recordEvent("after_retry")
    await recorder.flush()
    let saved = try records(in: directory)
    XCTAssertEqual(saved.last?.name, "after_retry",
      "One failed disk write must not permanently disable audio/recovery evidence until the app restarts")
    XCTAssertEqual(saved.last?.attributes["telemetry_persistence_recovery"], "write_failure")
    XCTAssertEqual(saved.last?.counters["telemetry_persistence_records_unconfirmed"], 2)
    XCTAssertGreaterThan(saved.last?.counters["telemetry_last_write_error_code"] ?? 0, 0)
    XCTAssertEqual(saved.last?.sessionID, recorder.sessionID)
  }

  func testAWriterRecoversWhenActiveCapacityIsReleasedWithoutExceedingTheBudget() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TelemetryTestClock()
    let recorders = (0..<3).map { _ in
      PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
        directory: directory, maximumFiles: 2, mirrorToSystemLog: false, uptime: { clock.now }))
    }
    for (index, recorder) in recorders.enumerated() {
      recorder.beginSession(channel: "fixture\(index)", playbackMode: "live")
      await recorder.flush()
    }
    XCTAssertEqual(try records(in: directory).count, 2)
    recorders[0].endSession(reason: "test")
    await recorders[0].flush()
    clock.advance(6)
    recorders[2].recordEvent("capacity_recovered")
    await recorders[2].flush()
    let saved = try records(in: directory)
    let recovered = try XCTUnwrap(saved.first { $0.name == "capacity_recovered" })
    XCTAssertEqual(recovered.sessionID, recorders[2].sessionID)
    XCTAssertEqual(recovered.counters["telemetry_persistence_records_unconfirmed"], 1)
    XCTAssertTrue(saved.contains { $0.sessionID == recorders[1].sessionID },
      "Reopening one pane must never evict another pane's active file")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }.count, 2)
    for recorder in recorders {
      recorder.endSession(reason: "test")
      await recorder.flush()
    }
  }

  func testNativeSourceTimeIsNotReplacedByDelayedMainDelivery() {
    let detail = NativeHLSPlaybackDiagnostic(event: .delivery, attributes: ["stage": "ingress_remux"],
      metrics: ["max_ingress_wait_seconds": 0.1], counters: ["ingress_chunks": 4], uptime: 10)
    let delivered = PlaybackTelemetryRecorder.nativeDeliveryMetrics(detail.metrics, dispatchedAt: 10, at: 15)
    XCTAssertEqual(delivered["native_event_uptime_seconds"], 10)
    XCTAssertEqual(delivered["main_actor_delivery_delay_seconds"], 5)
    XCTAssertEqual(delivered["max_ingress_wait_seconds"], 0.1)
    XCTAssertNil(PlaybackTelemetryRecorder.nativeDeliveryMetrics([:], dispatchedAt: 10, at: 15)["main_actor_delivery_delay_seconds"])
    XCTAssertNil(PlaybackTelemetryRecorder.nativeDeliveryMetrics(detail.metrics, dispatchedAt: 10, at: 9)["main_actor_delivery_delay_seconds"])
    let retained = PlaybackTelemetryRecorder.nativeDeliveryMetrics(detail.metrics, dispatchedAt: 14, at: 15)
    XCTAssertEqual(retained["native_trace_retention_delay_seconds"], 4)
    XCTAssertEqual(retained["main_actor_delivery_delay_seconds"], 1)
  }

  func testIndependentProbeObservesABlockedMainQueueAndStopsWithSession() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "fixture", playbackMode: "live")
    recorder.startSchedulerMonitoring()
    recorder.recordSnapshot(PlaybackTelemetrySnapshot(flags: ["playback_requested": true]))
    recorder.measure("synthetic_main_block") { Thread.sleep(forTimeInterval: 1.6) }
    try await Task.sleep(for: .milliseconds(150))
    recorder.endSession(reason: "test")
    await recorder.flush()
    let saved = try records(in: directory)
    let delay = try XCTUnwrap(saved.first { $0.name == "playback_scheduler_delay" })
    XCTAssertGreaterThanOrEqual(delay.metrics["main_queue_delay_seconds"] ?? 0, 0.25)
    XCTAssertLessThan(delay.metrics["background_probe_interval_seconds"] ?? .infinity, 1.5)
    #if DEBUG
    XCTAssertNotNil(delay.metrics["resource_sample_uptime_seconds"])
    XCTAssertNotNil(delay.metrics["process_resident_bytes"])
    XCTAssertNotNil(delay.metrics["process_footprint_bytes"])
    XCTAssertNotNil(delay.metrics["volume_free_bytes"])
    XCTAssertNotNil(delay.metrics["resource_sample_duration_seconds"])
    #endif
    XCTAssertTrue(saved.contains { $0.attributes["operation"] == "synthetic_main_block" })
    XCTAssertEqual(saved.last?.name, "session_ended")
  }

  func testSchedulerProbeCoalescesWhileMainIsBlocked() throws {
    var state = PlaybackSchedulerProbe.State()
    state.setEnabled(true, at: 0)
    let ticket = try XCTUnwrap(state.tick(at: 1))
    for tick in 2...300 { XCTAssertNil(state.tick(at: Double(tick))) }
    let report = try XCTUnwrap(state.finish(ticket, at: 301))
    XCTAssertEqual(report.mainDelay, 300)
    XCTAssertEqual(report.backgroundInterval, 1)
    XCTAssertEqual(report.coalescedTicks, 299)
    XCTAssertNotNil(state.tick(at: 302))
  }

  func testSchedulerDistinguishesBackgroundQueueDelayAndCancelsStaleOwnership() throws {
    var state = PlaybackSchedulerProbe.State()
    state.setEnabled(true, at: 0)
    let ticket = try XCTUnwrap(state.tick(at: 5))
    let report = try XCTUnwrap(state.finish(ticket, at: 5.01))
    XCTAssertEqual(report.mainDelay, 0.01, accuracy: 0.0001)
    XCTAssertEqual(report.backgroundInterval, 5)
    let stale = try XCTUnwrap(state.tick(at: 6))
    state.setEnabled(false, at: 7)
    XCTAssertNil(state.finish(stale, at: 200))
    XCTAssertNil(state.tick(at: 201))
    state.setEnabled(true, at: 202)
    let resumed = try XCTUnwrap(state.tick(at: 203))
    XCTAssertNil(state.finish(stale, at: 204))
    XCTAssertEqual(state.finish(resumed, at: 204)?.backgroundInterval, 1)
  }

  func testResourceCPUUsesElapsedTimeAndDoesNotInventAMissingBaseline() {
    let before = PlaybackResourceSample(observedAt: 10, cpuSeconds: 50)
    let after = PlaybackResourceSample(observedAt: 12, cpuSeconds: 53)
    XCTAssertNil(after.since(nil).metrics["process_cpu_core_equivalents"])
    XCTAssertEqual(after.since(before).metrics["process_cpu_interval_seconds"], 2)
    XCTAssertEqual(after.since(before).metrics["process_cpu_core_equivalents"], 1.5)
    XCTAssertNil(before.since(after).metrics["process_cpu_core_equivalents"])
    let unavailable = PlaybackResourceSample(observedAt: 13,
      snapshot: PlaybackTelemetrySnapshot(counters: ["resource_cpu_error_code": 5]))
    XCTAssertNil(unavailable.since(after).metrics["process_cpu_core_equivalents"])
    XCTAssertEqual(unavailable.since(after).counters["resource_cpu_error_code"], 5)
    XCTAssertNil(after.since(unavailable).metrics["process_cpu_core_equivalents"])
  }

  func testPendingProbeRetainsResourcePeaksWithoutRetainingEverySample() throws {
    func sample(_ time: Double, _ cpu: Double, _ memory: Double) -> PlaybackResourceSample {
      PlaybackResourceSample(observedAt: time, cpuSeconds: cpu,
        snapshot: PlaybackTelemetrySnapshot(metrics: [
          "process_resident_bytes": memory, "process_footprint_bytes": memory / 2,
          "resource_sample_duration_seconds": 0.001,
        ]))
    }
    var state = PlaybackSchedulerProbe.State()
    state.setEnabled(true, at: 0)
    let first = try XCTUnwrap(state.tick(at: 1, resource: sample(1, 10, 100)))
    XCTAssertNil(state.finish(first, at: 1.01)?.resources.metrics["process_cpu_core_equivalents"])
    let blocked = try XCTUnwrap(state.tick(at: 2, resource: sample(2, 12, 300)))
    XCTAssertNil(state.tick(at: 3, resource: sample(3, 12.5, 200)))
    XCTAssertNil(state.tick(at: 7, resource: sample(7, 13.5, 100)))
    let report = try XCTUnwrap(state.finish(blocked, at: 7.1))
    XCTAssertEqual(report.coalescedTicks, 2)
    XCTAssertEqual(report.resources.metrics["process_cpu_interval_seconds"], 4)
    XCTAssertEqual(report.resources.metrics["process_cpu_core_equivalents"], 0.25)
    XCTAssertEqual(report.resources.metrics["process_cpu_peak_core_equivalents"], 2)
    XCTAssertEqual(report.resources.metrics["process_resident_bytes"], 100)
    XCTAssertEqual(report.resources.metrics["process_peak_resident_bytes"], 300)
    XCTAssertEqual(report.resources.metrics["process_peak_footprint_bytes"], 150)
    XCTAssertEqual(report.resources.metrics["resource_sample_uptime_seconds"], 7)
    let next = try XCTUnwrap(state.tick(at: 8, resource: sample(8, 14, 50)))
    let fresh = try XCTUnwrap(state.finish(next, at: 8.01))
    XCTAssertEqual(fresh.resources.metrics["process_cpu_peak_core_equivalents"], 0.5)
    XCTAssertEqual(fresh.resources.metrics["process_peak_resident_bytes"], 50)
    state.setEnabled(false, at: 9)
    state.setEnabled(true, at: 100)
    let resumed = try XCTUnwrap(state.tick(at: 101, resource: sample(101, 200, 75)))
    XCTAssertNil(state.finish(resumed, at: 101.01)?.resources.metrics["process_cpu_core_equivalents"],
      "Background/idle CPU must not be attributed to resumed playback")
  }

  #if DEBUG
  func testResourceSamplerBoundsDiskReadsAndReportsFailureWithoutStaleFreeSpace() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var sampler = PlaybackResourceSampler(directory: directory)
    let initial = sampler.sample(at: 0)
    XCTAssertNotNil(initial.cpuSeconds)
    XCTAssertGreaterThan(try XCTUnwrap(initial.snapshot.metrics["process_resident_bytes"]), 0)
    XCTAssertGreaterThan(try XCTUnwrap(initial.snapshot.metrics["process_footprint_bytes"]), 0)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(initial.snapshot.metrics["volume_free_bytes"]), 0)
    XCTAssertGreaterThan(try XCTUnwrap(initial.snapshot.metrics["volume_total_bytes"]), 0)
    try FileManager.default.removeItem(at: directory)
    let cached = sampler.sample(at: 14)
    XCTAssertEqual(cached.snapshot.metrics["volume_free_bytes"], initial.snapshot.metrics["volume_free_bytes"])
    XCTAssertEqual(cached.snapshot.metrics["disk_sample_uptime_seconds"], 0)
    let failed = sampler.sample(at: 15)
    XCTAssertNotNil(failed.snapshot.counters["resource_disk_error_code"])
    XCTAssertNil(failed.snapshot.metrics["volume_free_bytes"])
    XCTAssertNil(failed.snapshot.metrics["volume_total_bytes"])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    XCTAssertNotNil(sampler.sample(at: 16).snapshot.counters["resource_disk_error_code"])
    let recovered = sampler.sample(at: 30)
    XCTAssertNotNil(recovered.snapshot.metrics["volume_free_bytes"])
    XCTAssertNil(recovered.snapshot.counters["resource_disk_error_code"])
  }
  #endif

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func records(in directory: URL) throws -> [PlaybackTelemetryRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let string = try decoder.singleValueContainer().decode(String.self)
      return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
      .flatMap { try Data(contentsOf: $0).split(separator: 0x0A) }
      .map { try decoder.decode(PlaybackTelemetryRecord.self, from: Data($0)) }
      .sorted { $0.sequence < $1.sequence }
  }

  private func waitingSnapshot() -> PlaybackTelemetrySnapshot {
    PlaybackTelemetrySnapshot(
      attributes: ["time_control_status": "waiting", "item_status": "ready", "access_entry": "0"],
      metrics: ["buffer_ahead_seconds": 0, "clock_not_advancing_seconds": 6],
      flags: ["has_started": true, "playback_requested": true, "buffer_empty": true]
    )
  }

  func testClassificationExcludesIntentionalAndStartupWaits() {
    for flag in ["loading", "user_paused", "scrubbing", "seek_pending", "background", "recovering", "offline"] {
      var sample = waitingSnapshot()
      sample.flags[flag] = true
      sample.flags["decode_frozen"] = true
      XCTAssertNil(sample.stallKind, flag)
    }
    var startup = waitingSnapshot()
    startup.flags["has_started"] = false
    XCTAssertEqual(startup.phase, "loading")
    XCTAssertNil(startup.stallKind)
  }

  func testClassificationRequiresClockEvidence() {
    var sample = waitingSnapshot()
    XCTAssertEqual(sample.stallKind, "network_or_buffer")
    sample.metrics["clock_not_advancing_seconds"] = 0
    XCTAssertNil(sample.stallKind, "Waiting alone is not evidence of an interruption")
    sample.metrics["clock_not_advancing_seconds"] = 6
    sample.flags["buffer_empty"] = false
    sample.metrics["buffer_ahead_seconds"] = 8
    XCTAssertEqual(sample.stallKind, "healthy_buffer_wait")
    sample.attributes["time_control_status"] = "playing"
    XCTAssertEqual(sample.stallKind, "playhead_not_advancing")
    sample.flags["decode_frozen"] = true
    XCTAssertEqual(sample.stallKind, "decode_freeze")
  }

  func testDecodedDimensionsFollowRealFramesAndResetWithItemOwnership() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "fixture", playbackMode: "live")
    let first = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-first.mp4"))
    let second = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-second.mp4"))
    recorder.trackItem(first)
    recorder.videoFrameObserved(size: CGSize(width: 852, height: 480))
    recorder.videoFrameObserved(size: CGSize(width: 1920, height: 1080))
    XCTAssertEqual(recorder.decodedVideoSize, CGSize(width: 1920, height: 1080))
    XCTAssertNotEqual(recorder.decodedVideoSize, first.presentationSize)
    recorder.trackItem(second)
    XCTAssertNil(recorder.decodedVideoSize)
    XCTAssertNil(recorder.videoFrameAge)
    recorder.videoFrameObserved(size: CGSize(width: -1, height: 0))
    XCTAssertNil(recorder.decodedVideoSize)
    XCTAssertNil(recorder.videoFrameAge)
    recorder.endSession(reason: "test")
    await recorder.flush()
    let saved = try records(in: directory)
    XCTAssertEqual(saved.filter { $0.name == "decoded_video_format_changed" }.count, 2)
    XCTAssertEqual(saved.filter { $0.name == "invalid_decoded_frame_dimensions" }.count, 1)
  }

  func testSanitizationFiniteMetricsAndSessionLifecycle() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "public-channel", playbackMode: "live")
    recorder.recordEvent(
      "failure",
      attributes: [
        "reason": "strozz-ll://cdn.example/master?token=secret",
        "authorization": "Bearer private-value",
        "detail": #"{"token":"secret-value"} sig=secret-signature oauth:private"#,
        "error": "a raw secret without recognizable formatting",
        "token": "bare-private-value",
        "source_host": "192.0.2.1",
      ],
      metrics: ["buffer": 2, "nan": .nan, "infinity": .infinity]
    )
    recorder.endSession(reason: "test")
    await recorder.flush()
    let saved = try records(in: directory)
    XCTAssertEqual(saved.map(\.sequence), [1, 2, 3])
    XCTAssertEqual(saved.first?.schemaVersion, 1)
    XCTAssertEqual(saved.last?.name, "session_ended")
    XCTAssertEqual(Set(saved.map(\.sessionID)).count, 1)
    let failure = try XCTUnwrap(saved.first { $0.name == "failure" })
    XCTAssertEqual(failure.metrics, ["buffer": 2])
    XCTAssertEqual(failure.attributes["reason"], "<url>")
    XCTAssertNil(failure.attributes["error"])
    XCTAssertNil(failure.attributes["token"])
    XCTAssertEqual(failure.attributes["source_host"], "<address>")
    let strings = failure.attributes.values.joined()
    XCTAssertFalse(strings.contains("secret"))
    XCTAssertFalse(strings.contains("private"))
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: directory.appendingPathComponent("latest-session.json"))) as? [String: Any])
    XCTAssertNotNil(manifest["endedAt"])
  }

  func testErrorAttributesNeverIncludeSDKProseOrServerAddresses() {
    let error = NSError(domain: NSURLErrorDomain, code: -1009,
                        userInfo: [NSLocalizedDescriptionKey: "secret-token https://user:password@host/path"])
    XCTAssertEqual(PlaybackTelemetryRecorder.errorAttributes(error),
                   ["error_domain": NSURLErrorDomain, "error_code": "-1009"])
    XCTAssertEqual(PlaybackTelemetryRecorder.host("https://user:password@cdn.example/path?token=secret"), "cdn.example")
    XCTAssertEqual(PlaybackTelemetryRecorder.host("https://192.0.2.1/path"), "<address>")
    XCTAssertEqual(PlaybackTelemetryRecorder.host("https://[2001:db8::1]/path"), "<address>")
  }

  func testHTTPStatusExtractionKeepsOnlyExplicitStatusCodes() {
    XCTAssertEqual(PlaybackTelemetryRecorder.httpStatus(inErrorComment: "HTTP 403: Forbidden"), 403)
    XCTAssertEqual(PlaybackTelemetryRecorder.httpStatus(inErrorComment: "HTTP/1.1 503 https://example.com/?token=private"), 503)
    XCTAssertNil(PlaybackTelemetryRecorder.httpStatus(inErrorComment: "https://example.com/403?token=private"))
    XCTAssertNil(PlaybackTelemetryRecorder.httpStatus(inErrorComment: "segment exceeds variant BANDWIDTH"))
    XCTAssertNil(PlaybackTelemetryRecorder.httpStatus(inErrorComment: nil))
  }

  func testStallEpisodesAndCounterResets() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "channel", playbackMode: "live")
    let start = ProcessInfo.processInfo.systemUptime
    var sample = waitingSnapshot()
    sample.metrics["playhead_seconds"] = 0
    sample.counters["dropped_video_frames"] = 10
    recorder.recordSnapshot(sample, uptime: start)
    sample.metrics["playhead_seconds"] = 2
    recorder.recordSnapshot(sample, uptime: start + 2)
    recorder.recordSnapshot(sample, uptime: start + 4)
    recorder.recordSnapshot(sample, uptime: start + 6)
    sample.metrics["playhead_seconds"] = 4
    sample.attributes["access_entry"] = "1"
    sample.counters["dropped_video_frames"] = 50
    recorder.recordSnapshot(sample, uptime: start + 8)
    sample.counters["dropped_video_frames"] = 52
    recorder.recordSnapshot(sample, uptime: start + 10)
    recorder.endSession(reason: "test")
    await recorder.flush()
    let saved = try records(in: directory)
    XCTAssertEqual(saved.filter { $0.name == "stall_started" }.count, 1)
    let end = try XCTUnwrap(saved.first { $0.name == "stall_ended" })
    XCTAssertEqual(end.attributes["outcome"], "recovered")
    XCTAssertEqual(end.metrics["duration_seconds"], 2)
    let increases = saved.filter { $0.name == "counter_increased" }
    XCTAssertEqual(increases.count, 1)
    XCTAssertEqual(increases.first?.counters["delta"], 2)
  }

  func testSeekOutcomesAndItemSessionBoundaries() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "one", playbackMode: "live")
    recorder.trackItem(AVPlayerItem(url: URL(fileURLWithPath: "/not-a-video")))
    let first = recorder.beginSeek(target: 5, kind: "test")
    let second = recorder.beginSeek(target: 6, kind: "test")
    XCTAssertFalse(recorder.finishSeek(first, finished: false, actual: 0))
    XCTAssertTrue(recorder.isSeekPending)
    recorder.trackItem(AVPlayerItem(url: URL(fileURLWithPath: "/also-not-a-video")))
    XCTAssertFalse(recorder.isSeekPending)
    XCTAssertFalse(recorder.finishSeek(second, finished: true, actual: 6))
    recorder.beginSession(channel: "two", playbackMode: "vod")
    XCTAssertFalse(recorder.finishSeek(second, finished: true, actual: 6))
    recorder.endSession(reason: "test")
    await recorder.flush()
    let saved = try records(in: directory)
    let seeks = saved.filter { $0.name == "seek_completed" }
    XCTAssertEqual(seeks.count, 2, "A late callback must not enter the next channel session")
    XCTAssertTrue(seeks.allSatisfy { $0.attributes["outcome"] == "superseded" && $0.channel == "one" })
    XCTAssertEqual(Set(saved.filter { $0.channel == "one" }.map(\.sessionID)).count, 1)
    XCTAssertEqual(Set(saved.map(\.sessionID)).count, 2)
  }

  func testSeekDeadlineDoesNotRejectAValidLateLanding() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "channel", playbackMode: "live")
    recorder.trackItem(AVPlayerItem(url: URL(fileURLWithPath: "/not-a-video")), source: "twitch")
    let seek = recorder.beginSeek(target: 5, kind: "test")
    recorder.recordSnapshot(waitingSnapshot(), uptime: ProcessInfo.processInfo.systemUptime + 16)
    XCTAssertFalse(recorder.isSeekPending)
    XCTAssertTrue(recorder.finishSeek(seek, finished: true, actual: 5))
    XCTAssertFalse(recorder.finishSeek(seek, finished: true, actual: 5))
    recorder.endSession(reason: "test")
    await recorder.flush()
    XCTAssertTrue(try records(in: directory).contains { $0.name == "seek_deadline_exceeded" })
  }

  func testRotationRetentionAndBoundedQueue() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = DispatchQueue(label: "telemetry-test")
    let writer = PlaybackTelemetryWriter(directory: directory, maximumFileBytes: 1_024, maximumFiles: 3,
                                          maximumPending: 2, mirrorToSystemLog: false, queue: queue)
    let recorder = PlaybackTelemetryRecorder(writer: writer)
    queue.suspend()
    recorder.beginSession(channel: "channel", playbackMode: "live")
    recorder.recordEvent("queued")
    recorder.recordEvent("dropped")
    queue.resume()
    await recorder.flush()
    recorder.recordEvent("after_overflow")
    await recorder.flush()
    var saved = try records(in: directory)
    XCTAssertFalse(saved.contains { $0.name == "dropped" })
    XCTAssertEqual(saved.first { $0.name == "after_overflow" }?.counters["telemetry_records_dropped"], 1)
    for _ in 0..<12 {
      recorder.recordEvent("rotate", attributes: ["detail": String(repeating: "x", count: 300)])
      await recorder.flush()
    }
    recorder.endSession(reason: "test")
    await recorder.flush()
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
    XCTAssertEqual(files.count, 3)
    for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1_024) }
    saved = try records(in: directory)
    XCTAssertEqual(saved.last?.name, "session_ended")
    XCTAssertGreaterThan(try XCTUnwrap(saved.first?.sequence), 1)
    XCTAssertEqual(Set(saved.map(\.sequence)).count, saved.count)
  }

  func testConcurrentPaneWritersRetainEveryActiveSessionsLatestRecord() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writers = (0..<6).map { _ in
      PlaybackTelemetryWriter(directory: directory, maximumFileBytes: 1_024,
        maximumFiles: 8, mirrorToSystemLog: false)
    }
    let sessions = writers.map { _ in UUID().uuidString.lowercased() }
    for sequence in 1...40 {
      for index in writers.indices {
        writers[index].append(PlaybackTelemetryRecord(schemaVersion: 1, timestamp: Date(),
          uptimeSeconds: Double(sequence), sessionID: sessions[index], sequence: sequence,
          kind: "event", name: sequence == 1 ? "pane_failure" : "pane_sample",
          level: sequence == 1 ? .error : .info, channel: "fixture\(index)",
          playbackMode: "live", attributes: ["detail": String(repeating: "x", count: 300)],
          metrics: [:], counters: [:], flags: [:]))
      }
    }
    for writer in writers { await writer.flush() }
    let saved = try records(in: directory)
    for session in sessions {
      XCTAssertEqual(saved.filter { $0.sessionID == session }.map(\.sequence).max(), 40,
        "One pane rotating its log must not disable or unlink another pane's log")
      let data = try Data(contentsOf: directory.appendingPathComponent("Incidents/incident-\(session).json"))
      let checkpoint = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let failure = try XCTUnwrap(checkpoint["firstFailure"] as? [String: Any])
      XCTAssertEqual(failure["sessionID"] as? String, session)
      XCTAssertEqual(failure["sequence"] as? Int, 1)
      XCTAssertLessThanOrEqual(data.count, PlaybackTelemetryWriter.maximumIncidentBytes)
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
    XCTAssertLessThanOrEqual(files.count, 8)
    for file in files { XCTAssertFalse(try Data(contentsOf: file).isEmpty) }
  }

  func testRotationCannotUnlinkAQuietPanesOpenFile() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let quiet = PlaybackTelemetryWriter(directory: directory, maximumFileBytes: 1_024,
      maximumFiles: 3, mirrorToSystemLog: false)
    let busy = PlaybackTelemetryWriter(directory: directory, maximumFileBytes: 1_024,
      maximumFiles: 3, mirrorToSystemLog: false)
    let quietSession = UUID().uuidString
    let busySession = UUID().uuidString
    func write(_ writer: PlaybackTelemetryWriter, session: String, sequence: Int) {
      writer.append(PlaybackTelemetryRecord(schemaVersion: 1, timestamp: Date(),
        uptimeSeconds: Double(sequence), sessionID: session, sequence: sequence,
        kind: "event", name: "sample", level: .info, channel: "fixture",
        playbackMode: "live", attributes: ["detail": String(repeating: "x", count: 300)],
        metrics: [:], counters: [:], flags: [:]))
    }
    write(quiet, session: quietSession, sequence: 1)
    await quiet.flush()
    for sequence in 1...20 {
      write(busy, session: busySession, sequence: sequence)
      await busy.flush()
    }
    write(quiet, session: quietSession, sequence: 2)
    await quiet.flush()
    let saved = try records(in: directory)
    XCTAssertEqual(saved.filter { $0.sessionID == quietSession }.map(\.sequence).max(), 2)
    XCTAssertEqual(saved.filter { $0.sessionID == busySession }.map(\.sequence).max(), 20)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
    XCTAssertLessThanOrEqual(files.count, 3)
  }

  func testActiveWritersCannotExceedTheSharedFileBudget() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writers = (0..<3).map { _ in
      PlaybackTelemetryWriter(directory: directory, maximumFiles: 2, mirrorToSystemLog: false)
    }
    for (index, writer) in writers.enumerated() {
      writer.append(PlaybackTelemetryRecord(schemaVersion: 1, timestamp: Date(), uptimeSeconds: 0,
        sessionID: UUID().uuidString, sequence: 1, kind: "event", name: "session_started",
        level: .info, channel: "fixture\(index)", playbackMode: "live",
        attributes: [:], metrics: [:], counters: [:], flags: [:]))
      await writer.flush()
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
    XCTAssertEqual(files.count, 2)
    XCTAssertEqual(try records(in: directory).count, 2)
  }
}

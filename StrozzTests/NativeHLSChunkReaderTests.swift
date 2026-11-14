import Network
import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeHLSChunkReaderTests: XCTestCase {
  func testBlockedTransportResumeDoesNotHoldThePlaybackExecutor() async throws {
    let server = try ChunkReaderServer()
    let base = try await server.start()
    let entered = expectation(description: "Transport resume blocked")
    let acknowledged = expectation(description: "Chunk acknowledgement returned")
    let playbackAvailable = expectation(description: "Playback executor remains available")
    let reported = expectation(description: "Transport blocking is attributed")
    let gate = DispatchSemaphore(value: 0)
    let reader = NativeHLSChunkReader(resumeConsumedTask: { task in
      entered.fulfill()
      XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
      task.resume()
    })
    defer { gate.signal(); reader.stop(); server.stop() }
    let executor = NativeHLSExecutor(pipeline: "test")
    let stream = reader.stream(URLRequest(url: base.appendingPathComponent("segment")),
      observeTransfer: { report in
        if report.attributes["stage"] == "chunk_resume" {
          XCTAssertGreaterThanOrEqual(report.metrics["duration_seconds"] ?? 0, 0.1)
          XCTAssertNotNil(report.metrics["thread_cpu_seconds"])
          reported.fulfill()
        }
      })
    let pending = Task(executorPreference: executor) {
      var bytes = Data()
      for try await chunk in stream {
        bytes.append(chunk.data)
        reader.consumedChunk(chunk)
        acknowledged.fulfill()
      }
      return bytes
    }
    await fulfillment(of: [entered, acknowledged], timeout: 2)
    let otherWork = Task(executorPreference: executor) { playbackAvailable.fulfill() }
    await fulfillment(of: [playbackAvailable], timeout: 1)
    try await Task.sleep(for: .milliseconds(120))
    gate.signal()
    let bytes = try await pending.value
    await otherWork.value
    XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
    await fulfillment(of: [reported], timeout: 2)
  }

  func testSlowProcessingSeparatesCPUFromBlockedWallTime() throws {
    let timer = NativeHLSChunkReader.ProcessingTiming(start: .init(uptime: 10, cpu: 2))
    let report = try XCTUnwrap(timer.finish(at: .init(uptime: 15, cpu: 2.2),
      pipeline: "controlled_cmaf", stage: "remux_append", completed: true, counters: ["input_bytes": 100]))
    XCTAssertEqual(report.metrics["duration_seconds"], 5)
    XCTAssertEqual(report.metrics["thread_cpu_seconds"] ?? -1, 0.2, accuracy: 0.0001)
    XCTAssertEqual(report.metrics["non_cpu_wall_seconds"] ?? -1, 4.8, accuracy: 0.0001)
    XCTAssertEqual(report.metrics["operation_started_uptime_seconds"], 10)
    XCTAssertEqual(report.attributes["stage"], "remux_append")
    XCTAssertEqual(report.attributes["completed"], "true")
    XCTAssertEqual(report.counters["input_bytes"], 100)
    XCTAssertNil(timer.finish(at: .init(uptime: 10.01, cpu: 2.005),
      pipeline: "controlled_cmaf", stage: "remux_append", completed: true, counters: [:]),
      "Fast chunks must not produce per-chunk logs")
  }

  func testMissingCPUClockIsExplicitAndNeverReportedAsZeroWork() throws {
    let timer = NativeHLSChunkReader.ProcessingTiming(start: .init(uptime: 10, cpu: nil, errorCode: 22))
    let report = try XCTUnwrap(timer.finish(at: .init(uptime: 11, cpu: nil, errorCode: 22),
      pipeline: "passthrough", stage: "index_chunk", completed: false, counters: [:]))
    XCTAssertEqual(report.metrics["duration_seconds"], 1)
    XCTAssertNil(report.metrics["thread_cpu_seconds"])
    XCTAssertNil(report.metrics["non_cpu_wall_seconds"])
    XCTAssertEqual(report.counters["thread_cpu_start_error_code"], 22)
    XCTAssertEqual(report.counters["thread_cpu_end_error_code"], 22)
    XCTAssertEqual(report.attributes["completed"], "false")
  }

  func testSynchronousMeasurementPreservesResultAndReportsSlowThrownWork() throws {
    let probe = TransferReportProbe()
    let result = NativeHLSChunkReader.ProcessingTiming.measure(
      pipeline: "passthrough", stage: "index_chunk", counters: [:], trace: { probe.append($0) }) { 42 }
    XCTAssertEqual(result, 42)
    XCTAssertThrowsError(try NativeHLSChunkReader.ProcessingTiming.measure(
      pipeline: "passthrough", stage: "index_chunk", counters: [:], trace: { probe.append($0) }) {
        Thread.sleep(forTimeInterval: 0.12)
        throw URLError(.cannotDecodeContentData)
      }) { XCTAssertEqual(($0 as? URLError)?.code, .cannotDecodeContentData) }
    let report = try XCTUnwrap(probe.values.last)
    XCTAssertEqual(report.attributes["completed"], "false")
    XCTAssertGreaterThanOrEqual(report.metrics["duration_seconds"] ?? -1, 0.1)
    XCTAssertNotNil(report.metrics["thread_cpu_seconds"])
    XCTAssertNil(report.counters["thread_cpu_start_error_code"])
    XCTAssertNil(report.counters["thread_cpu_end_error_code"])
  }

  func testBodyGapSeparatesConsumerPauseFromUnpausedDeliveryDelay() throws {
    var timing = NativeHLSChunkReader.RequestTiming(startedAt: 0)
    timing.received(bytes: 100, at: 1)
    timing.consumed(pending: 0, at: 5)
    timing.received(bytes: 100, at: 6, admittedAt: 6.25)
    timing.consumed(pending: 0, at: 6.5)
    timing.received(bytes: 100, at: 9)
    let report = timing.diagnostic(error: URLError(.timedOut), at: 12)
    XCTAssertEqual(report.metrics["max_body_delivery_gap_seconds"], 5)
    XCTAssertEqual(report.metrics["max_unpaused_body_gap_seconds"], 2.5)
    XCTAssertEqual(report.metrics["max_delegate_admission_wait_seconds"], 0.25)
    XCTAssertEqual(report.metrics["terminal_unpaused_body_age_seconds"], 0,
      "An unacknowledged final chunk is consumer backpressure, not missing upstream bytes")
    timing.consumed(pending: 0, at: 12)
    let afterResume = timing.diagnostic(error: URLError(.timedOut), at: 14)
    XCTAssertEqual(afterResume.metrics["terminal_unpaused_body_age_seconds"], 2)
  }

  func testQueuedChunksDoNotTurnProcessingTimeIntoAnUpstreamGap() {
    var timing = NativeHLSChunkReader.RequestTiming(startedAt: 0)
    timing.received(bytes: 100, at: 1)
    timing.received(bytes: 100, at: 2)
    timing.consumed(pending: 1, at: 4)
    timing.received(bytes: 100, at: 5)
    let report = timing.diagnostic(error: nil, at: 6)
    XCTAssertEqual(report.metrics["max_body_delivery_gap_seconds"], 3)
    XCTAssertEqual(report.metrics["max_unpaused_body_gap_seconds"], 0)
    XCTAssertEqual(report.metrics["terminal_unpaused_body_age_seconds"], 0)
    let empty = NativeHLSChunkReader.RequestTiming(startedAt: 0).diagnostic(error: URLError(.timedOut), at: 8)
    XCTAssertNil(empty.metrics["max_unpaused_body_gap_seconds"])
  }

  func testFailedTransferDistinguishesNoResponseFromStoppedBodyBytes() {
    let noResponse = NativeHLSChunkReader.RequestTiming(startedAt: 10)
      .diagnostic(error: URLError(.timedOut), at: 18)
    XCTAssertEqual(noResponse.attributes["request_phase"], "before_response")
    XCTAssertEqual(noResponse.attributes["error_code"], "-1001")
    XCTAssertEqual(noResponse.counters["response_bytes_received"], 0)
    XCTAssertNil(noResponse.metrics["last_body_age_seconds"])
    XCTAssertNil(noResponse.metrics["dns_seconds"], "Missing network phases must remain unknown")
    var partial = NativeHLSChunkReader.RequestTiming(startedAt: 10)
    partial.responseAt = 10.1
    partial.status = 200
    partial.received(bytes: 1024, at: 10.2)
    partial.consumed(pending: 0, at: 10.3)
    let stalled = partial.diagnostic(error: URLError(.timedOut), at: 18.2)
    XCTAssertEqual(stalled.attributes["request_phase"], "receiving_body")
    XCTAssertEqual(stalled.counters["http_status"], 200)
    XCTAssertEqual(stalled.counters["response_bytes_received"], 1024)
    XCTAssertEqual(stalled.metrics["last_body_age_seconds"] ?? -1, 8, accuracy: 0.0001)
    XCTAssertEqual(stalled.metrics["consumer_pause_seconds"] ?? -1, 0.1, accuracy: 0.0001)
    XCTAssertEqual(stalled.metrics["first_body_seconds"] ?? -1, 0.2, accuracy: 0.0001)
  }

  func testTransferEvidenceKeepsConsumerBackpressureSeparateFromMissingBytes() {
    var timing = NativeHLSChunkReader.RequestTiming(startedAt: 0)
    timing.responseAt = 0.1
    timing.received(bytes: 100, at: 0.2)
    timing.received(bytes: 200, at: 0.3)
    timing.consumed(pending: 1, at: 3)
    let paused = timing.diagnostic(error: URLError(.timedOut), at: 5.2)
    XCTAssertEqual(paused.counters["pending_consumer_chunks"], 1)
    XCTAssertEqual(paused.metrics["consumer_pause_seconds"] ?? -1, 5, accuracy: 0.0001)
    XCTAssertEqual(paused.counters["response_chunks_received"], 2)
    XCTAssertEqual(paused.counters["response_bytes_received"], 300)
    timing.consumed(pending: 0, at: 5.3)
    let ended = timing.diagnostic(error: nil, at: 5.4)
    XCTAssertEqual(ended.attributes["outcome"], "completed")
    XCTAssertNil(ended.attributes["error_domain"])
    XCTAssertEqual(ended.counters["pending_consumer_chunks"], 0)
    XCTAssertEqual(ended.metrics["consumer_pause_seconds"] ?? -1, 5.1, accuracy: 0.0001)
  }

  func testTransferDiagnosticArrivesBeforeCompletionAndPreservesConnectionReuse() async throws {
    let server = try ChunkReaderServer()
    let base = try await server.start()
    let reader = NativeHLSChunkReader()
    let probe = TransferReportProbe()
    defer { reader.stop(); server.stop() }
    for index in 0..<2 {
      var bytes = Data()
      for try await chunk in reader.stream(URLRequest(url: base.appendingPathComponent("segment-\(index)")),
        observeTransfer: { probe.append($0) }) {
        bytes += chunk.data
        reader.consumedChunk(chunk)
      }
      XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
      XCTAssertEqual(probe.values.count, index + 1, "Evidence must precede the consumer's terminal callback")
    }
    let report = try XCTUnwrap(probe.values.last)
    XCTAssertEqual(report.attributes["outcome"], "completed")
    XCTAssertEqual(report.attributes["connection_reused"], "true")
    XCTAssertEqual(report.counters["response_bytes_received"], 4)
    XCTAssertEqual(report.counters["http_status"], 200)
    XCTAssertNotNil(report.metrics["first_body_seconds"])
    let attributes = report.attributes.values.joined()
    XCTAssertFalse(attributes.contains("127.0.0.1"))
    XCTAssertFalse(attributes.contains("segment-"))
    XCTAssertFalse(attributes.contains("http://"))
  }

  func testPartialBodyTimeoutRetainsBytesAndReportsBeforeTheErrorReachesTheConsumer() async throws {
    let server = try ChunkReaderServer()
    let base = try await server.start()
    let reader = NativeHLSChunkReader(resumeConsumedTask: { task in
      Thread.sleep(forTimeInterval: 0.15)
      task.resume()
    })
    let probe = TransferReportProbe()
    defer { reader.stop(); server.stop() }
    var bytes = Data()
    do {
      for try await chunk in reader.stream(
        URLRequest(url: base.appendingPathComponent("hold")),
        observeTransfer: { if $0.attributes["stage"] == "media_transfer" { probe.append($0) } }) {
        bytes += chunk.data
        reader.consumedChunk(chunk)
      }
      XCTFail("A partial transfer must still fail with its original error")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .timedOut)
      XCTAssertEqual(probe.values.count, 1)
    }
    XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
    let report = try XCTUnwrap(probe.values.first)
    XCTAssertEqual(report.attributes["request_phase"], "receiving_body")
    XCTAssertEqual(report.attributes["error_code"], "-1001")
    XCTAssertEqual(report.counters["response_bytes_received"], 4)
    XCTAssertNotNil(report.metrics["last_body_age_seconds"])
    XCTAssertGreaterThanOrEqual(report.metrics["consumer_pause_seconds"] ?? 0, 0.15,
      "Waiting for transport resume must not be misreported as an upstream delivery gap")
    XCTAssertFalse(report.attributes.values.joined().contains("127.0.0.1"))
    XCTAssertFalse(report.attributes.values.joined().contains("http://"))
  }

  func testDeliveryTimingSeparatesIngressFromConsumerAndProcessingDelays() {
    var timing = NativeHLSChunkReader.DeliveryTiming(startedAt: 10)
    timing.observe(bytes: 100, receivedAt: 10.1, consumedAt: 12.1, finishedAt: 15.1)
    timing.observe(bytes: 200, receivedAt: 15.2, consumedAt: 15.3, finishedAt: 15.4)
    XCTAssertEqual(timing.chunks, 2)
    XCTAssertEqual(timing.bytes, 300)
    XCTAssertEqual(timing.metrics["first_body_seconds"] ?? -1, 0.1, accuracy: 0.0001)
    XCTAssertEqual(timing.metrics["max_ingress_wait_seconds"] ?? -1, 0.1, accuracy: 0.0001)
    XCTAssertEqual(timing.metrics["max_consumer_queue_seconds"] ?? -1, 2, accuracy: 0.0001)
    XCTAssertEqual(timing.metrics["max_remux_publish_seconds"] ?? -1, 3, accuracy: 0.0001)
    XCTAssertEqual(timing.metrics["transfer_wall_seconds"] ?? -1, 5.4, accuracy: 0.0001)
  }

  private final class TransferReportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [NativeHLSPlaybackDiagnostic] = []
    func append(_ report: NativeHLSPlaybackDiagnostic) { lock.withLock { reports.append(report) } }
    var values: [NativeHLSPlaybackDiagnostic] { lock.withLock { reports } }
  }

  func testQueuedIngressCannotBeMisreportedAsNetworkWait() {
    var timing = NativeHLSChunkReader.DeliveryTiming(startedAt: 0)
    timing.observe(bytes: 100, receivedAt: 0.1, consumedAt: 0.2, finishedAt: 5)
    timing.observe(bytes: 100, receivedAt: 0.3, consumedAt: 5.1, finishedAt: 5.2)
    XCTAssertEqual(timing.metrics["max_ingress_wait_seconds"] ?? -1, 0.1, accuracy: 0.0001)
    XCTAssertEqual(timing.metrics["max_consumer_queue_seconds"] ?? -1, 4.8, accuracy: 0.0001)
    var deliveryWait = NativeHLSChunkReader.DeliveryTiming(startedAt: 0)
    deliveryWait.observe(bytes: 100, receivedAt: 5, consumedAt: 5.01, finishedAt: 5.02)
    XCTAssertEqual(deliveryWait.metrics["max_ingress_wait_seconds"], 5)
    XCTAssertEqual(deliveryWait.metrics["max_consumer_queue_seconds"] ?? -1, 0.01, accuracy: 0.0001)
  }

  func testBurstDeliveryWaitsForTheIndexerWithoutDroppingMedia() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChunkBurstProtocol.self]
    let reader = NativeHLSChunkReader(configuration: configuration)
    defer { reader.stop() }
    let probe = ChunkBurstProbe()
    let request = NSMutableURLRequest(url: URL(string: "https://chunk-reader.test/burst")!)
    URLProtocol.setProperty(reader, forKey: "chunkReader", in: request)
    URLProtocol.setProperty(probe, forKey: "probe", in: request)
    let stream = reader.stream(request as URLRequest)
    for _ in 0..<300 {
      if probe.delivered >= 32 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(probe.delivered, 32, "Delivery must remain bounded while the indexer is busy")
    var received = Data()
    for try await chunk in stream {
      received.append(chunk.data)
      reader.consumedChunk(chunk)
    }
    XCTAssertEqual(received, ChunkBurstProtocol.body)
  }

  func testStoppingBackpressuredDeliveryReleasesTheProducer() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChunkBurstProtocol.self]
    let reader = NativeHLSChunkReader(configuration: configuration)
    defer { reader.stop() }
    let exited = expectation(description: "Blocked producer released")
    let request = NSMutableURLRequest(url: URL(string: "https://chunk-reader.test/burst")!)
    URLProtocol.setProperty(reader, forKey: "chunkReader", in: request)
    URLProtocol.setProperty(exited, forKey: "producerExited", in: request)
    let stream = reader.stream(request as URLRequest)
    try await Task.sleep(for: .milliseconds(200))
    reader.stop()
    await fulfillment(of: [exited], timeout: 3)
    do {
      for try await chunk in stream { reader.consumedChunk(chunk) }
      XCTFail("Stopping must not report a complete segment")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
  }

  func testDuplicateAndRetiredChunkAcknowledgementsDoNotReleaseNewChunks() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChunkBurstProtocol.self]
    let reader = NativeHLSChunkReader(configuration: configuration)
    defer { reader.stop() }
    let request = NSMutableURLRequest(url: URL(string: "https://chunk-reader.test/burst")!)
    URLProtocol.setProperty(reader, forKey: "chunkReader", in: request)
    var retired: NativeHLSChunkReader.Chunk?
    for _ in 0..<2 {
      let stream = reader.stream(request as URLRequest)
      try await Task.sleep(for: .milliseconds(200))
      if let retired { reader.consumedChunk(retired) }
      var received = Data()
      for try await chunk in stream {
        if retired == nil { retired = chunk }
        received.append(chunk.data)
        reader.consumedChunk(chunk)
        reader.consumedChunk(chunk)
      }
      XCTAssertEqual(received, ChunkBurstProtocol.body)
    }
  }

  func testCancellingBackpressuredDeliveryDoesNotBlockItsSuccessor() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChunkBurstProtocol.self]
    let reader = NativeHLSChunkReader(configuration: configuration)
    defer { reader.stop() }
    let exited = expectation(description: "Cancelled producer released")
    let request = NSMutableURLRequest(url: URL(string: "https://chunk-reader.test/burst")!)
    URLProtocol.setProperty(reader, forKey: "chunkReader", in: request)
    URLProtocol.setProperty(exited, forKey: "producerExited", in: request)
    let urlRequest = request as URLRequest
    let pending = Task {
      for try await chunk in reader.stream(urlRequest) {
        defer { reader.consumedChunk(chunk) }
        try await Task.sleep(for: .milliseconds(10))
      }
      try Task.checkCancellation()
    }
    try await Task.sleep(for: .milliseconds(200))
    pending.cancel()
    do {
      try await pending.value
      XCTFail("Cancellation must not report a complete segment")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
    await fulfillment(of: [exited], timeout: 3)
    let nextRequest = NSMutableURLRequest(url: URL(string: "https://chunk-reader.test/next")!)
    URLProtocol.setProperty(reader, forKey: "chunkReader", in: nextRequest)
    var received = Data()
    for try await chunk in reader.stream(nextRequest as URLRequest) {
      received.append(chunk.data)
      reader.consumedChunk(chunk)
    }
    XCTAssertEqual(received, ChunkBurstProtocol.body)
  }

  func testLargeSegmentRemainsByteExactWithASlowIndexer() async throws {
    let server = try ChunkReaderServer()
    let base = try await server.start()
    let reader = NativeHLSChunkReader()
    defer { reader.stop(); server.stop() }
    var received = Data()
    for try await chunk in reader.stream(URLRequest(url: base.appendingPathComponent("large"))) {
      defer { reader.consumedChunk(chunk) }
      try await Task.sleep(for: .milliseconds(2))
      received.append(chunk.data)
    }
    XCTAssertEqual(received, ChunkReaderServer.largeBody)
    let next = try await Self.read(reader, url: base.appendingPathComponent("next"))
    XCTAssertEqual(next, Data([1, 2, 3, 4]))
    XCTAssertEqual(server.connectionCount, 1)
  }

  func testSequentialSegmentsReuseTheSameConnection() async throws {
    let server = try ChunkReaderServer()
    let base = try await server.start()
    let reader = NativeHLSChunkReader()
    defer { reader.stop(); server.stop() }
    for number in 0..<3 {
      let data = try await Self.read(reader, url: base.appendingPathComponent("segment-\(number)"))
      XCTAssertEqual(data, Data([1, 2, 3, 4]))
    }
    XCTAssertEqual(server.connectionCount, 1, "Serial media requests must reuse the rendition's HTTP session")
  }

  func testCancellingAnIncompleteSegmentDoesNotCancelItsSuccessor() async throws {
    let server = try ChunkReaderServer()
    let base = try await server.start()
    let reader = NativeHLSChunkReader()
    defer { reader.stop(); server.stop() }
    let pending = Task { try await NativeHLSChunkReaderTests.read(reader, url: base.appendingPathComponent("hold")) }
    for _ in 0..<100 {
      if server.requestCount > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(server.requestCount, 1)
    pending.cancel()
    do {
      _ = try await pending.value
      XCTFail("Cancelled media must not be treated as a completed segment")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
    let next = try await Self.read(reader, url: base.appendingPathComponent("next"))
    XCTAssertEqual(next, Data([1, 2, 3, 4]))
  }

  func testStoppingReaderIsTerminal() async throws {
    let server = try ChunkReaderServer()
    let base = try await server.start()
    let reader = NativeHLSChunkReader()
    defer { server.stop(); reader.stop() }
    reader.stop()
    do {
      _ = try await Self.read(reader, url: base.appendingPathComponent("stopped"))
      XCTFail("Stopped reader must not start another request")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
    XCTAssertEqual(server.requestCount, 0)
  }

  func testOverlappingRequestCannotReplaceAnActiveSegment() async throws {
    let server = try ChunkReaderServer()
    let base = try await server.start()
    let reader = NativeHLSChunkReader()
    defer { reader.stop(); server.stop() }
    let pending = Task { try await NativeHLSChunkReaderTests.read(reader, url: base.appendingPathComponent("hold")) }
    for _ in 0..<100 {
      if server.requestCount > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    do {
      _ = try await Self.read(reader, url: base.appendingPathComponent("overlap"))
      XCTFail("Concurrent use must fail rather than replace the active continuation")
    } catch {
      XCTAssertEqual(error as? NativeHLSError, .unavailable)
    }
    XCTAssertEqual(server.requestCount, 1)
    pending.cancel()
    do {
      _ = try await pending.value
      XCTFail("The active request should remain cancellable")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
  }

  func testHTTPFailureDoesNotContaminateTheNextRequest() async throws {
    let server = try ChunkReaderServer()
    let base = try await server.start()
    let reader = NativeHLSChunkReader()
    defer { reader.stop(); server.stop() }
    do {
      _ = try await Self.read(reader, url: base.appendingPathComponent("failure"))
      XCTFail("Failed HTTP media must not be accepted")
    } catch {
      XCTAssertEqual(error as? NativeHLSFailureDetail, .httpStatus(503))
      XCTAssertEqual(NativeHLSError.classify(error), .unavailable)
    }
    let data = try await Self.read(reader, url: base.appendingPathComponent("next"))
    XCTAssertEqual(data, Data([1, 2, 3, 4]))
  }

  private static func read(_ reader: NativeHLSChunkReader, url: URL) async throws -> Data {
    var data = Data()
    for try await chunk in reader.stream(URLRequest(url: url)) {
      data.append(chunk.data)
      reader.consumedChunk(chunk)
    }
    try Task.checkCancellation()
    return data
  }
}

private final class ChunkBurstProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var delivered: Int { lock.withLock { count } }
  func didDeliver() { lock.withLock { count += 1 } }
}

private final class ChunkBurstProtocol: URLProtocol, @unchecked Sendable {
  static var body: Data {
    (0..<128).reduce(into: Data()) { $0.append(Data(repeating: UInt8($1), count: 1024)) }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "chunk-reader.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let reader = URLProtocol.property(forKey: "chunkReader", in: request) as? NativeHLSChunkReader,
      let task = task as? URLSessionDataTask else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: 200,
      httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/mp2t"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    // Model callbacks already queued before URLSession observes suspension.
    for index in 0..<128 {
      reader.urlSession(.shared, dataTask: task, didReceive: Data(repeating: UInt8(index), count: 1024))
      (URLProtocol.property(forKey: "probe", in: request) as? ChunkBurstProbe)?.didDeliver()
    }
    reader.urlSession(.shared, task: task, didCompleteWithError: nil)
    (URLProtocol.property(forKey: "producerExited", in: request) as? XCTestExpectation)?.fulfill()
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class ChunkReaderServer: @unchecked Sendable {
  static let largeBody = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
  private let queue = DispatchQueue(label: "strozz.tests.chunk-reader")
  private let listener: NWListener
  private var connections: [UUID: NWConnection] = [:]
  private var accepted = 0
  private var requests = 0

  var connectionCount: Int { queue.sync { accepted } }
  var requestCount: Int { queue.sync { requests } }

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.listener.stateUpdateHandler = { state in
          switch state {
          case .ready:
            self.listener.stateUpdateHandler = nil
            if let port = self.listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)") {
              continuation.resume(returning: url)
            } else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
          case .failed(let error):
            self.listener.stateUpdateHandler = nil
            continuation.resume(throwing: error)
          default: break
          }
        }
        self.listener.newConnectionHandler = { [weak self] connection in
          guard let self else { connection.cancel(); return }
          let id = UUID()
          self.accepted += 1
          self.connections[id] = connection
          connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
          }
          connection.start(queue: self.queue)
          self.receive(connection, id: id, buffer: Data())
        }
        self.listener.start(queue: self.queue)
      }
    }
  }

  private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, done, error in
      guard let self, error == nil else { connection.cancel(); return }
      var buffer = buffer
      if let bytes { buffer.append(bytes) }
      guard buffer.count <= 16384 else { connection.cancel(); return }
      guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
        if done { connection.cancel() } else { self.receive(connection, id: id, buffer: buffer) }
        return
      }
      self.requests += 1
      let path = text.split(separator: " ").dropFirst().first ?? ""
      let failed = path == "/failure"
      let held = path == "/hold"
      let body = path == "/large" ? Self.largeBody : Data([1, 2, 3, 4])
      let status = failed ? "503 Service Unavailable" : "200 OK"
      var response = Data(("HTTP/1.1 \(status)\r\nContent-Length: \(held ? 1024 : body.count)\r\n"
        + "Content-Type: video/mp2t\r\nConnection: keep-alive\r\n\r\n").utf8)
      response.append(body)
      connection.send(content: response, completion: .contentProcessed { [weak self] error in
        guard error == nil, !held else { return }
        self?.receive(connection, id: id, buffer: Data())
      })
    }
  }

  func stop() {
    queue.async {
      self.listener.cancel()
      self.connections.values.forEach { $0.cancel() }
      self.connections.removeAll()
    }
  }
}

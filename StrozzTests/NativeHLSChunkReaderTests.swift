import Network
import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeHLSChunkReaderTests: XCTestCase {
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
    let pending = Task { try await Self.read(reader, url: base.appendingPathComponent("hold")) }
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
    let pending = Task { try await Self.read(reader, url: base.appendingPathComponent("hold")) }
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

import Network
import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeHLSChunkReaderTests: XCTestCase {
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
      XCTAssertEqual(error as? NativeHLSError, .unavailable)
    }
    let data = try await Self.read(reader, url: base.appendingPathComponent("next"))
    XCTAssertEqual(data, Data([1, 2, 3, 4]))
  }

  private static func read(_ reader: NativeHLSChunkReader, url: URL) async throws -> Data {
    var data = Data()
    for try await chunk in reader.stream(URLRequest(url: url)) {
      data.append(chunk)
      reader.consumedChunk()
    }
    try Task.checkCancellation()
    return data
  }
}

private final class ChunkReaderServer: @unchecked Sendable {
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
      let body = Data([1, 2, 3, 4])
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

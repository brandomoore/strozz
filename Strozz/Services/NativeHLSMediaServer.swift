import Foundation
import Network

/// Serves bounded, already-produced TS parts on loopback only. No disk or TLS trust changes.
final class NativeHLSMediaServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "strozz.native-hls.media")
  private let listener: NWListener
  private let response: @Sendable (String) async -> Data?
  private var connections: [UUID: NWConnection] = [:]
  private var stopped = false
  private var startCompleted = false

  init(response: @escaping @Sendable (String) async -> Data?) throws {
    self.response = response
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        self.listener.stateUpdateHandler = { state in
          guard !self.startCompleted else { return }
          switch state {
          case .ready:
            guard let port = self.listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
              self.startCompleted = true
              self.listener.stateUpdateHandler = nil
              continuation.resume(throwing: NativeHLSError.unavailable)
              return
            }
            self.startCompleted = true
            self.listener.stateUpdateHandler = nil
            continuation.resume(returning: url)
          case .failed, .cancelled:
            self.startCompleted = true
            self.listener.stateUpdateHandler = nil
            continuation.resume(throwing: NativeHLSError.unavailable)
          default: break
          }
        }
        self.listener.newConnectionHandler = { [weak self] connection in
          guard let self, !self.stopped, self.connections.count < 16 else { connection.cancel(); return }
          let id = UUID()
          self.connections[id] = connection
          connection.start(queue: self.queue)
          self.read(connection, id: id, buffer: Data())
          self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.connections.removeValue(forKey: id)?.cancel()
          }
        }
        self.listener.start(queue: self.queue)
      }
    }
  }

  private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
      guard let self else { connection.cancel(); return }
      var data = buffer
      if let bytes { data.append(bytes) }
      guard error == nil, data.count <= 16384 else { self.connections.removeValue(forKey: id)?.cancel(); return }
      guard let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") else {
        if complete { self.connections.removeValue(forKey: id)?.cancel() }
        else { self.read(connection, id: id, buffer: data) }
        return
      }
      let lines = text.components(separatedBy: "\r\n")
      let first = lines[0].split(separator: " ")
      guard first.count == 3, first[0] == "GET",
        let url = URL(string: String(first[1]), relativeTo: URL(string: "http://127.0.0.1")!)
      else { self.send(connection, id: id, status: "400 Bad Request", data: Data()); return }
      let range = lines.first { $0.lowercased().hasPrefix("range:") }?.split(separator: ":", maxSplits: 1).last
        .map { String($0).trimmingCharacters(in: .whitespaces) }
      let contentType = url.pathExtension == "mp4" ? "video/mp4" : "video/mp2t"
      Task {
        let body = await self.response(url.path)
        self.queue.async {
          guard self.connections[id] != nil else { return }
          guard let body else { self.send(connection, id: id, status: "404 Not Found", data: Data()); return }
          if let range {
            guard range.hasPrefix("bytes=") else {
              self.send(connection, id: id, status: "416 Range Not Satisfiable", data: Data()); return
            }
            let values = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard values.count == 2, let start = Int(values[0]), start >= 0, start < body.count,
              values[1].isEmpty || Int(values[1]) != nil else {
              self.send(connection, id: id, status: "416 Range Not Satisfiable", data: Data()); return
            }
            let end = min(Int(values[1]) ?? (body.count - 1), body.count - 1)
            guard end >= start else { self.send(connection, id: id, status: "416 Range Not Satisfiable", data: Data()); return }
            self.send(connection, id: id, status: "206 Partial Content", data: body.subdata(in: start..<(end + 1)),
              extra: "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n", contentType: contentType)
          } else { self.send(connection, id: id, status: "200 OK", data: body, contentType: contentType) }
        }
      }
    }
  }

  private func send(_ connection: NWConnection, id: UUID, status: String, data: Data, extra: String = "",
                    contentType: String = "video/mp2t") {
    var response = Data(("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\n"
      + "Cache-Control: no-store\r\nAccept-Ranges: bytes\r\nConnection: close\r\n" + extra + "\r\n").utf8)
    response.append(data)
    connection.send(content: response, completion: .contentProcessed { [weak self] _ in
      self?.connections.removeValue(forKey: id)?.cancel()
    })
  }

  func stop() {
    queue.async {
      self.stopped = true
      self.listener.cancel()
      self.connections.values.forEach { $0.cancel() }
      self.connections.removeAll()
    }
  }
}

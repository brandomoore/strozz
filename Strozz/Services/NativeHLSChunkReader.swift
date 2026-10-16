import Foundation

/// URLSession delivers chunks; awaiting once per byte cannot sustain live video
/// on the TV's CPU, particularly in a development build.
final class NativeHLSChunkReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  struct Chunk: Sendable {
    let data: Data
    fileprivate let task: URLSessionDataTask
    fileprivate let id: Int
  }

  private static let capacity = 32
  #if DEBUG
  private var metricsObservers: [Int: @Sendable ([String: String]) -> Void] = [:]
  #endif
  private let lock = NSCondition()
  private var continuation: AsyncThrowingStream<Chunk, Error>.Continuation?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var pendingChunks: Set<Int> = []
  private var nextChunkID = 0
  private var stopped = false
  private let configuration: URLSessionConfiguration

  init(configuration: URLSessionConfiguration = .ephemeral) {
    self.configuration = configuration
    super.init()
  }

  func stream(_ request: URLRequest,
              observeMetrics: (@Sendable ([String: String]) -> Void)? = nil) -> AsyncThrowingStream<Chunk, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.capacity)) { continuation in
      lock.lock()
      guard !stopped, self.task == nil else {
        let error: Error = stopped ? CancellationError() : NativeHLSError.unavailable
        lock.unlock()
        continuation.finish(throwing: error)
        return
      }
      let session: URLSession
      if let existing = self.session {
        session = existing
      } else {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
      }
      self.continuation = continuation
      pendingChunks.removeAll(keepingCapacity: true)
      let task = session.dataTask(with: request)
      self.task = task
      #if DEBUG
      metricsObservers[task.taskIdentifier] = observeMetrics
      #endif
      lock.unlock()
      continuation.onTermination = { [weak self, weak task] _ in
        if let task { self?.cancel(task) }
      }
      task.resume()
    }
  }

  private func cancel(_ task: URLSessionTask) {
    lock.lock()
    if self.task === task {
      self.task = nil
      continuation = nil
      pendingChunks.removeAll(keepingCapacity: true)
      lock.broadcast()
    }
    lock.unlock()
    task.cancel()
  }

  func stop() {
    lock.lock()
    stopped = true
    let continuation = self.continuation
    let session = self.session
    self.continuation = nil
    self.session = nil
    self.task = nil
    pendingChunks.removeAll(keepingCapacity: true)
    lock.broadcast()
    #if DEBUG
    metricsObservers.removeAll()
    #endif
    lock.unlock()
    continuation?.finish(throwing: CancellationError())
    session?.invalidateAndCancel()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    lock.lock()
    let continuation = self.task === dataTask ? self.continuation : nil
    lock.unlock()
    guard let continuation else { completionHandler(.cancel); return }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      continuation.finish(throwing: NativeHLSFailureDetail.httpStatus(
        (response as? HTTPURLResponse)?.statusCode ?? -1))
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    // Suspension cannot retract delegate callbacks URLSession already queued.
    // Wait on its delegate thread, not the indexer's cooperative executor.
    while self.task === dataTask, pendingChunks.count >= Self.capacity {
      lock.wait()
    }
    let continuation = self.task === dataTask ? self.continuation : nil
    guard let continuation else { lock.unlock(); dataTask.cancel(); return }
    let id = nextChunkID
    nextChunkID += 1
    pendingChunks.insert(id)
    lock.unlock()
    dataTask.suspend()
    switch continuation.yield(Chunk(data: data, task: dataTask, id: id)) {
    case .dropped:
      continuation.finish(throwing: NativeHLSError.indexerOverrun)
      dataTask.cancel()
    case .terminated:
      dataTask.cancel()
    default:
      break
    }
  }

  func consumedChunk(_ chunk: Chunk) {
    lock.lock()
    let consumed = task === chunk.task && pendingChunks.remove(chunk.id) != nil
    if consumed { lock.signal() }
    lock.unlock()
    if consumed { chunk.task.resume() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = self.task === task ? self.continuation : nil
    if self.task === task {
      self.task = nil
      self.continuation = nil
      pendingChunks.removeAll(keepingCapacity: true)
      lock.broadcast()
    }
    #if DEBUG
    metricsObservers.removeValue(forKey: task.taskIdentifier)
    #endif
    lock.unlock()
    if let error { continuation?.finish(throwing: error) }
    else { continuation?.finish() }
  }

  #if DEBUG
  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    lock.lock()
    let observeMetrics = metricsObservers[task.taskIdentifier]
    lock.unlock()
    for transaction in metrics.transactionMetrics {
      var values = ["reused": String(transaction.isReusedConnection),
        "protocol": transaction.networkProtocolName ?? "unknown"]
      for (name, start, end) in [
        ("connect_seconds", transaction.connectStartDate, transaction.connectEndDate),
        ("tls_seconds", transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
        ("first_byte_seconds", transaction.requestEndDate, transaction.responseStartDate),
      ] {
        if let start, let end { values[name] = String(end.timeIntervalSince(start)) }
      }
      observeMetrics?(values)
    }
  }
  #endif
}

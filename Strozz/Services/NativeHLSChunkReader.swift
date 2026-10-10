import Foundation

/// URLSession delivers chunks; awaiting once per byte cannot sustain live video
/// on the TV's CPU, particularly in a development build.
final class NativeHLSChunkReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  #if DEBUG
  private var metricsObservers: [Int: @Sendable ([String: String]) -> Void] = [:]
  #endif
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var stopped = false

  func stream(_ request: URLRequest,
              observeMetrics: (@Sendable ([String: String]) -> Void)? = nil) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
      }
      self.continuation = continuation
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
    let continuation = self.task === dataTask ? self.continuation : nil
    lock.unlock()
    guard let continuation else { dataTask.cancel(); return }
    dataTask.suspend()
    switch continuation.yield(data) {
    case .dropped:
      continuation.finish(throwing: NativeHLSError.indexerOverrun)
      dataTask.cancel()
    case .terminated:
      dataTask.cancel()
    default:
      break
    }
  }

  func consumedChunk() {
    lock.lock(); let task = self.task; lock.unlock()
    task?.resume()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = self.task === task ? self.continuation : nil
    if self.task === task {
      self.task = nil
      self.continuation = nil
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

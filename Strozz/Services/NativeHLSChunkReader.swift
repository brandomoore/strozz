import Foundation

/// URLSession delivers chunks; awaiting once per byte cannot sustain live video
/// on the TV's CPU, particularly in a development build.
final class NativeHLSChunkReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  struct Chunk: Sendable {
    let data: Data
    let receivedAtUptime: Double
    fileprivate let task: URLSessionDataTask
    fileprivate let id: Int
  }

  struct DeliveryTiming {
    let startedAt: Double
    private(set) var chunks = 0
    private(set) var bytes = 0
    private var firstBodyAt: Double?
    private var previousFinishedAt: Double?
    private var maximumIngressWait = 0.0
    private var maximumConsumerDelay = 0.0
    private var maximumProcessing = 0.0

    init(startedAt: Double) { self.startedAt = startedAt }

    mutating func observe(bytes: Int, receivedAt: Double, consumedAt: Double, finishedAt: Double) {
      chunks += 1
      self.bytes += bytes
      if firstBodyAt == nil { firstBodyAt = receivedAt }
      // Exclude our previous chunk's processing/backpressure from ingress wait.
      maximumIngressWait = max(maximumIngressWait, receivedAt - (previousFinishedAt ?? startedAt))
      maximumConsumerDelay = max(maximumConsumerDelay, consumedAt - receivedAt)
      maximumProcessing = max(maximumProcessing, finishedAt - consumedAt)
      previousFinishedAt = finishedAt
    }

    var metrics: [String: Double] {
      var values = [
        "request_started_uptime_seconds": startedAt,
        "max_ingress_wait_seconds": maximumIngressWait,
        "max_consumer_queue_seconds": maximumConsumerDelay,
        "max_remux_publish_seconds": maximumProcessing,
      ]
      values["first_body_seconds"] = firstBodyAt.map { max(0, $0 - startedAt) }
      values["transfer_wall_seconds"] = previousFinishedAt.map { max(0, $0 - startedAt) }
      return values
    }
  }

  struct RequestTiming: Sendable {
    let startedAt: Double
    var responseAt: Double?
    var firstBodyAt: Double?
    var lastBodyAt: Double?
    var receivedBytes = 0
    var receivedChunks = 0
    var pendingConsumerChunks = 0
    var status: Int?
    var consumerPausedAt: Double?
    var consumerPausedSeconds = 0.0
    var networkAttributes: [String: String] = [:]
    var networkMetrics: [String: Double] = [:]

    mutating func received(bytes: Int, at now: Double) {
      if firstBodyAt == nil { firstBodyAt = now }
      lastBodyAt = now
      receivedBytes += bytes
      receivedChunks += 1
      pendingConsumerChunks += 1
      if consumerPausedAt == nil { consumerPausedAt = now }
    }

    mutating func consumed(pending: Int, at now: Double) {
      pendingConsumerChunks = pending
      guard pending == 0 else { return }
      if let consumerPausedAt { consumerPausedSeconds += max(0, now - consumerPausedAt) }
      consumerPausedAt = nil
    }

    func diagnostic(error: Error?, at now: Double) -> NativeHLSPlaybackDiagnostic {
      var attributes = networkAttributes
      attributes["stage"] = "media_transfer"
      attributes["outcome"] = error == nil ? "completed" : "failed"
      attributes["request_phase"] = lastBodyAt != nil ? "receiving_body"
        : responseAt != nil ? "awaiting_body" : "before_response"
      if let error {
        let value = error as NSError
        attributes["error_domain"] = value.domain
        attributes["error_code"] = String(value.code)
      }
      var metrics = networkMetrics
      metrics["request_started_uptime_seconds"] = startedAt
      metrics["request_duration_seconds"] = max(0, now - startedAt)
      metrics["response_headers_seconds"] = responseAt.map { max(0, $0 - startedAt) }
      metrics["first_body_seconds"] = firstBodyAt.map { max(0, $0 - startedAt) }
      metrics["last_body_age_seconds"] = lastBodyAt.map { max(0, now - $0) }
      metrics["consumer_pause_seconds"] = consumerPausedSeconds
        + (consumerPausedAt.map { max(0, now - $0) } ?? 0)
      var counters = ["response_bytes_received": receivedBytes, "response_chunks_received": receivedChunks]
      counters["http_status"] = status
      counters["pending_consumer_chunks"] = pendingConsumerChunks
      return .init(event: .delivery, attributes: attributes, metrics: metrics, counters: counters, uptime: now)
    }
  }

  private struct TransferObservation {
    var timing: RequestTiming
    let report: @Sendable (NativeHLSPlaybackDiagnostic) -> Void
  }

  private static let capacity = 32
  #if DEBUG
  private var metricsObservers: [Int: @Sendable ([String: String]) -> Void] = [:]
  #endif
  private var transfers: [Int: TransferObservation] = [:]
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
              observeMetrics: (@Sendable ([String: String]) -> Void)? = nil,
              observeTransfer: (@Sendable (NativeHLSPlaybackDiagnostic) -> Void)? = nil
  ) -> AsyncThrowingStream<Chunk, Error> {
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
      if let observeTransfer {
        transfers[task.taskIdentifier] = TransferObservation(
          timing: RequestTiming(startedAt: ProcessInfo.processInfo.systemUptime), report: observeTransfer)
      }
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
    transfers.removeValue(forKey: task.taskIdentifier)
    #if DEBUG
    metricsObservers.removeValue(forKey: task.taskIdentifier)
    #endif
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
    transfers.removeAll()
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
    transfers[dataTask.taskIdentifier]?.timing.responseAt = ProcessInfo.processInfo.systemUptime
    transfers[dataTask.taskIdentifier]?.timing.status = (response as? HTTPURLResponse)?.statusCode
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
    let receivedAt = ProcessInfo.processInfo.systemUptime
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
    transfers[dataTask.taskIdentifier]?.timing.received(bytes: data.count, at: receivedAt)
    lock.unlock()
    dataTask.suspend()
    switch continuation.yield(Chunk(data: data, receivedAtUptime: receivedAt, task: dataTask, id: id)) {
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
    if consumed {
      transfers[chunk.task.taskIdentifier]?.timing.consumed(
        pending: pendingChunks.count, at: ProcessInfo.processInfo.systemUptime)
      lock.signal()
    }
    lock.unlock()
    if consumed { chunk.task.resume() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = self.task === task ? self.continuation : nil
    let transfer = transfers.removeValue(forKey: task.taskIdentifier)
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
    if let transfer {
      transfer.report(transfer.timing.diagnostic(error: error, at: ProcessInfo.processInfo.systemUptime))
    }
    if let error { continuation?.finish(throwing: error) }
    else { continuation?.finish() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    lock.lock()
    #if DEBUG
    let observeMetrics = metricsObservers[task.taskIdentifier]
    #endif
    if transfers[task.taskIdentifier] != nil, let transaction = metrics.transactionMetrics.last {
      var attributes = ["connection_reused": String(transaction.isReusedConnection),
        "network_protocol": transaction.networkProtocolName ?? "unknown",
        "network_expensive": String(transaction.isExpensive),
        "network_constrained": String(transaction.isConstrained),
        "network_cellular": String(transaction.isCellular)]
      attributes["connection_phase"] = transaction.secureConnectionStartDate != nil
        && transaction.secureConnectionEndDate == nil ? "tls"
        : transaction.connectStartDate != nil && transaction.connectEndDate == nil ? "connect"
        : transaction.domainLookupStartDate != nil && transaction.domainLookupEndDate == nil ? "dns"
        : transaction.requestEndDate != nil ? "request_sent" : "unobserved"
      transfers[task.taskIdentifier]?.timing.networkAttributes = attributes
      for (name, start, end) in [
        ("dns_seconds", transaction.domainLookupStartDate, transaction.domainLookupEndDate),
        ("connect_seconds", transaction.connectStartDate, transaction.connectEndDate),
        ("tls_seconds", transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
        ("first_byte_seconds", transaction.requestEndDate, transaction.responseStartDate),
        ("response_body_seconds", transaction.responseStartDate, transaction.responseEndDate),
      ] {
        if let start, let end {
          let value = end.timeIntervalSince(start)
          if value.isFinite, value >= 0 { transfers[task.taskIdentifier]?.timing.networkMetrics[name] = value }
        }
      }
    }
    lock.unlock()
    #if DEBUG
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
    #endif
  }
}

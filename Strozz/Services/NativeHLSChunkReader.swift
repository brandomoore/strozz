import Foundation

/// URLSession delivers chunks; awaiting once per byte cannot sustain live video
/// on the TV's CPU, particularly in a development build.
final class NativeHLSChunkReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
  private var session: URLSession?
  private var task: URLSessionDataTask?

  func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.timeoutIntervalForRequest = 8
      configuration.timeoutIntervalForResource = 12
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      lock.lock()
      self.continuation = continuation
      self.session = session
      let task = session.dataTask(with: request)
      self.task = task
      lock.unlock()
      continuation.onTermination = { [weak self] _ in self?.stop() }
      task.resume()
    }
  }

  func stop() {
    lock.lock()
    let continuation = self.continuation
    let session = self.session
    self.continuation = nil
    self.session = nil
    self.task = nil
    lock.unlock()
    continuation?.finish()
    session?.invalidateAndCancel()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      lock.lock(); let continuation = self.continuation; lock.unlock()
      continuation?.finish(throwing: NativeHLSError.unavailable)
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    dataTask.suspend()
    lock.lock(); let continuation = self.continuation; lock.unlock()
    if case .dropped = continuation?.yield(data) {
      continuation?.finish(throwing: NativeHLSError.indexerOverrun)
      dataTask.cancel()
    }

  }

  func consumedChunk() {
    lock.lock(); let task = self.task; lock.unlock()
    task?.resume()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock(); let continuation = self.continuation; lock.unlock()
    if let error { continuation?.finish(throwing: error) }
    else { continuation?.finish() }
    session.finishTasksAndInvalidate()
  }
}

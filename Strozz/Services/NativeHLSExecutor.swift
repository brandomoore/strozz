import Foundation

/// Keep media ingestion and its nonisolated async continuations off the shared cooperative pool.
final class NativeHLSExecutor: SerialExecutor, TaskExecutor {
  private let queue = DispatchQueue(label: "strozz.native-hls.playback", qos: .userInitiated)
  private let pipeline: String
  private let trace: (@Sendable (NativeHLSPlaybackDiagnostic) -> Void)?

  init(pipeline: String, trace: (@Sendable (NativeHLSPlaybackDiagnostic) -> Void)? = nil) {
    self.pipeline = pipeline
    self.trace = trace
  }

  func checkIsolated() {
    dispatchPrecondition(condition: .onQueue(queue))
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let enqueuedAt = trace.map { _ in ProcessInfo.processInfo.systemUptime }
    queue.async { [self] in
      if let enqueuedAt {
        let delay = ProcessInfo.processInfo.systemUptime - enqueuedAt
        if delay >= 0.1 {
          trace?(.init(event: .delivery,
            attributes: ["pipeline": pipeline, "stage": "executor_queue"],
            metrics: ["duration_seconds": delay, "enqueued_uptime_seconds": enqueuedAt], counters: [:]))
        }
      }
      NativeHLSChunkReader.ProcessingTiming.measure(
        pipeline: pipeline, stage: "executor_job", counters: [:], trace: trace) {
          job.runSynchronously(isolatedTo: asUnownedSerialExecutor(),
            taskExecutor: asUnownedTaskExecutor())
        }
    }
  }
}

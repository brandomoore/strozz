import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeHLSExecutorTests: XCTestCase {
  func testOptInIngestionContinuesWhileCooperativeWorkerIsBlocked() async throws {
    guard ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1" else {
      throw XCTSkip("Run in a dedicated test host with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1.")
    }
    let pair = AsyncThrowingStream<Int, Error>.makeStream()
    let consumed = expectation(description: "Chunk consumed before shared worker unblocks")
    let blocked = expectation(description: "Shared worker released")
    let consumer = Consumer(executor: NativeHLSExecutor(pipeline: "test"))
    let pending = await consumer.start(pair.stream) {
      // Start the competing job only after ingestion is mounted on its own executor.
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
        Task.detached {
          NativeHLSExecutorTests.blockSharedWorker(pair.continuation, completed: blocked)
        }
      }
    }
    let check = Task(executorPreference: consumer.executor) {
      let values = try await pending.value
      XCTAssertEqual(values, [1])
      consumed.fulfill()
    }
    await fulfillment(of: [consumed], timeout: 1)
    await fulfillment(of: [blocked], timeout: 3)
    try await check.value
  }

  func testActorAndNonisolatedChunkContinuationsUsePlaybackExecutor() async throws {
    let executor = NativeHLSExecutor(pipeline: "test")
    let consumer = Consumer(executor: executor)
    let pair = AsyncThrowingStream<Int, Error>.makeStream()
    let pending = await consumer.start(pair.stream)
    for value in 0..<32 { pair.continuation.yield(value) }
    pair.continuation.finish()
    let values = try await pending.value
    XCTAssertEqual(values, Array(0..<32))
  }

  func testSlowPlaybackJobDoesNotBlockAnotherPlaybackExecutor() async throws {
    let entered = expectation(description: "First player blocked")
    let finished = expectation(description: "Second player finished")
    let first = NativeHLSExecutor(pipeline: "first")
    let second = NativeHLSExecutor(pipeline: "second")
    let gate = DispatchSemaphore(value: 0)
    let blocked = Task(executorPreference: first) {
      NativeHLSExecutorTests.wait(gate, entered: entered)
    }
    await fulfillment(of: [entered], timeout: 2)
    defer { gate.signal() }
    let consumer = Consumer(executor: second)
    let pair = AsyncThrowingStream<Int, Error>.makeStream()
    let pending = await consumer.start(pair.stream)
    pair.continuation.yield(7)
    pair.continuation.finish()
    let completed = Task {
      let values = try await pending.value
      XCTAssertEqual(values, [7])
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 1)
    gate.signal()
    await blocked.value
    try await completed.value
  }

  func testCancellationStillTerminatesAWaitingChunkConsumer() async throws {
    let consumer = Consumer(executor: NativeHLSExecutor(pipeline: "test"))
    let pair = AsyncThrowingStream<Int, Error>.makeStream()
    let pending = await consumer.start(pair.stream)
    pending.cancel()
    do {
      _ = try await pending.value
      XCTFail("Cancelled ingestion must not report a complete segment")
    } catch { XCTAssertTrue(error is CancellationError) }
    pair.continuation.finish()
  }

  func testSlowJobsAndQueuedWorkHaveDistinctDiagnostics() async throws {
    let jobReported = expectation(description: "Slow executor job reported")
    let queueReported = expectation(description: "Executor wait reported")
    let entered = expectation(description: "Executor occupied")
    let executor = NativeHLSExecutor(pipeline: "test") { report in
      XCTAssertEqual(report.attributes["pipeline"], "test")
      if report.attributes["stage"] == "executor_job" {
        XCTAssertGreaterThanOrEqual(report.metrics["duration_seconds"] ?? 0, 0.1)
        XCTAssertNotNil(report.metrics["thread_cpu_seconds"])
        jobReported.fulfill()
      } else if report.attributes["stage"] == "executor_queue" {
        XCTAssertGreaterThanOrEqual(report.metrics["duration_seconds"] ?? 0, 0.1)
        XCTAssertNotNil(report.metrics["enqueued_uptime_seconds"])
        queueReported.fulfill()
      }
    }
    let gate = DispatchSemaphore(value: 0)
    let blocked = Task(executorPreference: executor) { NativeHLSExecutorTests.wait(gate, entered: entered) }
    await fulfillment(of: [entered], timeout: 2)
    let queued = Task(executorPreference: executor) { 42 }
    try await Task.sleep(for: .milliseconds(150))
    gate.signal()
    await blocked.value
    let value = await queued.value
    XCTAssertEqual(value, 42)
    await fulfillment(of: [jobReported, queueReported], timeout: 2)
  }

  private static func wait(_ gate: DispatchSemaphore, entered: XCTestExpectation) {
    entered.fulfill()
    XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
  }

  private static func blockSharedWorker(
    _ continuation: AsyncThrowingStream<Int, Error>.Continuation, completed: XCTestExpectation
  ) {
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
      continuation.yield(1)
      continuation.finish()
    }
    Thread.sleep(forTimeInterval: 2)
    completed.fulfill()
  }

  private actor Consumer {
    nonisolated let executor: NativeHLSExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    init(executor: NativeHLSExecutor) { self.executor = executor }

    func start(_ stream: AsyncThrowingStream<Int, Error>,
               ready: @escaping @Sendable () -> Void = {}) -> Task<[Int], Error> {
      Task(executorPreference: executor) {
        self.assertIsolated()
        ready()
        var values: [Int] = []
        for try await value in stream {
          self.assertIsolated()
          await Self.checkTaskExecutor(self.executor)
          values.append(value)
        }
        try Task.checkCancellation()
        return values
      }
    }

    private nonisolated static func checkTaskExecutor(_ executor: NativeHLSExecutor) async {
      executor.checkIsolated()
    }
  }
}

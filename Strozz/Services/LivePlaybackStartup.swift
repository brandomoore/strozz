import Foundation

enum LivePlaybackStartup {
  struct YouTubeSource: Sendable {
    let target: String
    let live: AltSourceService.YouTubeLive
  }

  /// Bound source selection before creating any player item. A slow optional
  /// source must not hold up Twitch indefinitely or replace it after it starts.
  static func resolveYouTube(
    timeout: Duration = .seconds(4),
    operation: @escaping @Sendable () async throws -> YouTubeSource
  ) async throws -> YouTubeSource {
    try await withThrowingTaskGroup(of: YouTubeSource.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        try Task.checkCancellation()
        return try await operation()
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw URLError(.timedOut)
      }
      guard let source = try await group.next() else { throw CancellationError() }
      try Task.checkCancellation()
      return source
    }
  }

  /// A nonzero HLS clock may only be AVPlayer landing on its initial live
  /// timestamp. Require advancing playback, not that initial seek, before
  /// enabling the live rate/stability controllers. Presentation follows
  /// AVPlayer's native playing state without waiting for these samples.
  struct Progress {
    let createdAt: TimeInterval
    private(set) var hasStarted = false
    private var lastClock: Double?
    private var lastSampleAt: TimeInterval?
    private var advancingSeconds: Double = 0

    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
      createdAt = now
    }

    @discardableResult
    mutating func observe(clock: Double, isPlaying: Bool, now: TimeInterval) -> Bool {
      guard !hasStarted else { return true }
      guard isPlaying, clock.isFinite else {
        lastClock = nil
        lastSampleAt = nil
        advancingSeconds = 0
        return false
      }
      if let lastSampleAt, now - lastSampleAt < 0.2 { return false }
      defer {
        lastClock = clock
        lastSampleAt = now
      }
      guard let lastClock, let lastSampleAt else { return false }
      let advance = clock - lastClock
      let elapsed = now - lastSampleAt
      guard advance > 0.05, advance <= elapsed * 1.5 + 0.1 else {
        advancingSeconds = 0
        return false
      }
      advancingSeconds += advance
      hasStarted = advancingSeconds >= 0.5
      return hasStarted
    }

    func allowsRateAdjustment(isPlaying: Bool, isLoading: Bool, shouldPlay: Bool) -> Bool {
      hasStarted && isPlaying && !isLoading && shouldPlay
    }
  }
}

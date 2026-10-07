import AVFoundation

@MainActor
enum PlaybackPositionRestoration {
  static func restore(
    _ date: Date, on item: AVPlayerItem,
    isCurrent: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    var canSeek = false
    while ContinuousClock.now < deadline {
      guard !Task.isCancelled, isCurrent(), item.status != .failed else { return false }
      // A fresh paused HLS owner can expose its timeline before readyToPlay.
      if item.status == .readyToPlay || (!item.seekableTimeRanges.isEmpty && item.currentDate() != nil) {
        canSeek = true
        break
      }
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
    }
    guard canSeek, !Task.isCancelled, isCurrent() else { return false }
    let timeout = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard isCurrent() else { return }
      item.cancelPendingSeeks()
    }
    defer { timeout.cancel() }
    var restored = await item.seek(to: date)
    guard !Task.isCancelled, isCurrent() else { return false }
    if restored, let actual = item.currentDate() {
      let correction = date.timeIntervalSince(actual)
      let target = item.currentTime().seconds + correction
      // Date seeks may land on a nearby keyframe rather than the paused instant.
      if abs(correction) > 0.25, target.isFinite {
        restored = await item.seek(to: CMTime(seconds: target, preferredTimescale: 600),
          toleranceBefore: .zero, toleranceAfter: .zero)
      }
    }
    guard !Task.isCancelled, isCurrent() else { return false }
    return restored && item.currentDate().map { abs($0.timeIntervalSince(date)) <= 1 } == true
  }
}

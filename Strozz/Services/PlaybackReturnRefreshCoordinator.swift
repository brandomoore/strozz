import Foundation
import Observation

/// Refreshes the originating list once the player cover has finished closing.
/// Focus stays owned by the list/native focus engine, never by a delayed task.
@MainActor
@Observable
final class PlaybackReturnRefreshCoordinator {
  typealias Refresh = @MainActor @Sendable () async -> Void

  @ObservationIgnored private var originRefresh: Refresh?
  @ObservationIgnored private(set) var inFlight: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  func prepareOrigin(_ refresh: @escaping Refresh) {
    cancelRefresh()
    originRefresh = refresh
  }

  func discardOrigin() {
    originRefresh = nil
  }

  func cancelRefresh() {
    inFlight?.cancel()
    inFlight = nil
    generation = UUID()
  }

  func playerDidDismiss(refreshHome: @escaping Refresh) {
    let refreshOrigin = originRefresh
    originRefresh = nil
    cancelRefresh()
    let token = generation
    inFlight = Task {
      guard !Task.isCancelled else { return }
      await refreshOrigin?()
      if !Task.isCancelled { await refreshHome() }
      if generation == token { inFlight = nil }
    }
  }
}

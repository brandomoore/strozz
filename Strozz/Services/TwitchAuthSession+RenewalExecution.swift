import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class TwitchRenewalExecution {
  enum Event {
    case deferred, protectionUnavailable, protectionExpired
  }

  typealias EndProtection = @MainActor () -> Void
  typealias BeginProtection = @MainActor (@escaping @MainActor () -> Void) -> EndProtection?
  private let isActive: @MainActor () -> Bool
  private let beginProtection: BeginProtection

  init(isActive: @escaping @MainActor () -> Bool, beginProtection: @escaping BeginProtection) {
    self.isActive = isActive
    self.beginProtection = beginProtection
  }

  var canStart: Bool { isActive() }

  func run<Value: Sendable>(
    onEvent: @escaping @MainActor (Event) -> Void,
    operation: @escaping @MainActor () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    guard canStart else {
      onEvent(.deferred)
      throw CancellationError()
    }
    var task: Task<Value, Error>?
    var expired = false
    guard let end = beginProtection({
      expired = true
      onEvent(.protectionExpired)
      task?.cancel()
    }) else {
      onEvent(.protectionUnavailable)
      throw CancellationError()
    }
    defer { end() }
    guard !expired else { throw CancellationError() }

    // Caller/view cancellation must not discard an accepted single-use grant.
    // Only expiration cancels this worker; account ownership is checked inside it.
    let admitted = Task {
      try Task.checkCancellation()
      return try await operation()
    }
    task = admitted
    return try await admitted.value
  }
}

#if canImport(UIKit)
extension TwitchRenewalExecution {
  static func application() -> TwitchRenewalExecution {
    .init(isActive: { UIApplication.shared.applicationState == .active }, beginProtection: { expire in
      var identifier = UIBackgroundTaskIdentifier.invalid
      @MainActor func end() {
        guard identifier != .invalid else { return }
        let finished = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(finished)
      }
      identifier = UIApplication.shared.beginBackgroundTask(withName: "Twitch credential renewal") {
        expire()
        end()
      }
      guard identifier != .invalid else { return nil }
      return { end() }
    })
  }
}
#endif

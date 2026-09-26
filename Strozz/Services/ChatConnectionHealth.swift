import Foundation

/// Socket health is measured with protocol acknowledgements, not message volume:
/// a quiet channel must never be mistaken for a broken connection.
struct ChatConnectionHealth {
  enum Failure: String {
    case joinTimeout = "join_timeout"
    case pongTimeout = "pong_timeout"
    case pingFailed = "ping_failed"
    case sendFailed = "send_failed"
    case receiveFailed = "receive_failed"
    case serverReconnect = "server_reconnect"
  }

  enum Action: Equatable {
    case wait
    case ping
    case reconnect(Failure)
  }

  static let joinTimeout: TimeInterval = 20
  static let pingInterval: TimeInterval = 30
  static let pongTimeout: TimeInterval = 15

  private let startedAt: TimeInterval
  private var joined = false
  private var lastPongAt: TimeInterval
  private(set) var pingSentAt: TimeInterval?
  private(set) var lastFrameAt: TimeInterval?

  init(now: TimeInterval) {
    startedAt = now
    lastPongAt = now
  }

  mutating func receivedFrame(now: TimeInterval) {
    lastFrameAt = now
  }

  mutating func joinedChannel(now: TimeInterval) {
    guard !joined else { return }
    joined = true
    lastPongAt = now
  }

  mutating func receivedPong(sentAt: TimeInterval, now: TimeInterval) {
    guard pingSentAt == sentAt else { return }
    pingSentAt = nil
    lastPongAt = now
  }

  mutating func nextAction(now: TimeInterval) -> Action {
    guard joined else {
      return now - startedAt >= Self.joinTimeout ? .reconnect(.joinTimeout) : .wait
    }
    if let pingSentAt {
      return now - pingSentAt >= Self.pongTimeout ? .reconnect(.pongTimeout) : .wait
    }
    guard now - lastPongAt >= Self.pingInterval else { return .wait }
    pingSentAt = now
    return .ping
  }
}

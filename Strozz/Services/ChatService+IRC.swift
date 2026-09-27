import Foundation
import OSLog

/// IRC-over-WebSocket transport and line parsing for `ChatService`: the receive
/// loop, command sending, and tokenizing raw IRC frames (PRIVMSG, USERNOTICE,
/// CAP/JOIN handshake, PING/PONG, raid notices) into `ChatMessage`s.
extension ChatService {
  private static let ircLog = Logger(subsystem: "com.thatcube.Strozz", category: "Chat")

  func openIRCConnection() {
    ircTransportID = UUID()
    ircFailurePending = false
    hasSentJoin = false
    hasCapAck = false
    isConnected = false
    ircHealth = ChatConnectionHealth(now: ProcessInfo.processInfo.systemUptime)
    let socket = connection.connect(to: endpoint)
    sendIRCHandshake()
    startIRCHealthWatchdog(socket: socket)
  }

  func startIRCHealthWatchdog(socket: URLSessionWebSocketTask) {
    ircHealthTask?.cancel()
    ircHealthTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled, let self,
          self.connection.currentTask === socket, !self.ircFailurePending else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch self.ircHealth?.nextAction(now: now) {
        case .ping:
          socket.sendPing { [weak self] error in
            Task { @MainActor in
              guard let self, self.connection.currentTask === socket,
                !self.ircFailurePending else { return }
              if error != nil {
                self.invalidateIRCConnection(socket: socket, reason: .pingFailed)
              } else {
                self.ircHealth?.receivedPong(
                  sentAt: now, now: ProcessInfo.processInfo.systemUptime)
              }
            }
          }
        case .reconnect(let reason):
          self.invalidateIRCConnection(socket: socket, reason: reason)
          return
        case .wait, .none:
          break
        }
      }
    }
  }

  func invalidateIRCConnection(socket: URLSessionWebSocketTask, reason: ChatConnectionHealth.Failure) {
    guard connection.currentTask === socket, !ircFailurePending else { return }
    ircFailurePending = true
    isConnected = false
    ircLastRecoveryReason = reason.rawValue
    ircHealthTask?.cancel()
    ircHealthTask = nil
    Self.ircLog.warning("Recovering Twitch chat: \(reason.rawValue, privacy: .public)")
    // Cancelling unblocks receive(); that loop owns the single backoff/rejoin path.
    socket.cancel(with: .goingAway, reason: nil)
  }

  /// The anonymous (`justinfan`) login handshake. Sent on every fresh socket —
  /// the first connect, an auto-reconnect after a receive error, and the rebuild
  /// after the app returns from the background.
  func sendIRCHandshake() {
    send("PASS SCHMOOPIIE")
    send("NICK justinfan\(Int.random(in: 10_000..<99_999))")
    send("CAP REQ :twitch.tv/tags twitch.tv/commands")
  }

  func sendJoinIfNeeded() {
    guard !hasSentJoin, let channel else { return }
    send("JOIN #\(channel)")
    hasSentJoin = true
  }

  func send(_ command: String) {
    guard let socket = connection.currentTask, !ircFailurePending else { return }
    socket.send(.string(command + "\r\n")) { [weak self] error in
      guard error != nil else { return }
      Task { @MainActor in
        self?.invalidateIRCConnection(socket: socket, reason: .sendFailed)
      }
    }
  }

  func receiveLoop() async {
    while !Task.isCancelled {
      guard let currentSocket = connection.currentTask else { break }
      do {
        let frame = try await currentSocket.receive()
        guard !Task.isCancelled, connection.currentTask === currentSocket,
          !ircFailurePending else { continue }
        ircHealth?.receivedFrame(now: ProcessInfo.processInfo.systemUptime)
        switch frame {
        case .string(let text): await handle(text)
        case .data(let data): await handle(String(decoding: data, as: UTF8.self))
        @unknown default: break
        }
      } catch {
        guard !Task.isCancelled, connection.currentTask === currentSocket else { break }
        invalidateIRCConnection(socket: currentSocket, reason: .receiveFailed)

        // Reconnect with exponential backoff (3s, 6s, 12s… capped at 30s),
        // preserving the message buffer.
        guard let channelToRejoin = channel else { break }
        let delay = connection.nextBackoffDelay()
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, channel == channelToRejoin else { break }

        ircReconnectCount += 1
        openIRCConnection()
        // Loop continues — next iteration receives on the new socket.
      }
    }
  }

  func handle(_ raw: String) async {
    guard !Task.isCancelled, !ircFailurePending else { return }
    let session = sessionID
    let transport = ircTransportID
    // A single frame can batch multiple IRC lines. Control lines (PING/PONG,
    // CAP/JOIN handshake, end-of-NAMES, raids) touch connection state and stay on
    // the main actor — they're cheap and rare. The expensive PRIVMSG/USERNOTICE
    // lines are handed to the serial background pipeline, which parses them into
    // `ChatMessage`s and computes their `segments` off the main actor before we
    // enqueue the finished batch.
    var messagePieces: [String] = []
    for piece in raw.components(separatedBy: "\r\n") where !piece.isEmpty {
      let fields = Self.ircFields(piece)
      guard let command = fields.first else { continue }
      if command == "PING" {
        send("PONG " + fields.dropFirst().joined(separator: " "))
        continue
      }
      if command == "RECONNECT" {
        if let socket = connection.currentTask {
          invalidateIRCConnection(socket: socket, reason: .serverReconnect)
        }
        return
      }
      if command == "CAP", fields.count > 3, fields[2] == "ACK",
        fields[3].contains("twitch.tv/tags") {
        hasCapAck = true
        sendJoinIfNeeded()
        continue
      }
      if command == "366", fields.count > 2, fields[2].lowercased() == "#\(channel ?? "")" {
        isConnected = true
        ircHealth?.joinedChannel(now: ProcessInfo.processInfo.systemUptime)
        connection.resetBackoff()
        continue
      }
      if command == "USERNOTICE", let raid = parseRaidEvent(from: piece) {
        pendingRaid = raid
        continue
      }
      messagePieces.append(piece)
    }

    guard !messagePieces.isEmpty else { return }
    let parsedMessages = await ingestPipeline.parseAndTokenize(messagePieces)
    guard !Task.isCancelled, sessionID == session, ircTransportID == transport,
      !ircFailurePending, !parsedMessages.isEmpty else { return }
    enqueue(contextualizeCommunityGifts(parsedMessages))
  }

  private func contextualizeCommunityGifts(_ messages: [ChatMessage]) -> [ChatMessage] {
    var result = messages
    var minecraftGiftIndices: [Int] = []
    for index in result.indices {
      guard let gift = result[index].communityGiftNotice else { continue }
      if let count = gift.massGiftCount, count > 0,
        gift.senderLogin != "minecraft" {
        if communityGiftBatches[gift.id] == nil {
          communityGiftBatchOrder.append(gift.id)
        }
        communityGiftBatches[gift.id] = (result[index].username, count)
        if communityGiftBatchOrder.count > 32 {
          communityGiftBatches.removeValue(forKey: communityGiftBatchOrder.removeFirst())
        }
      } else if gift.senderLogin == "minecraft" {
        minecraftGiftIndices.append(index)
      }
    }
    for index in minecraftGiftIndices {
      guard let gift = result[index].communityGiftNotice,
        let batch = communityGiftBatches[gift.id],
        !batch.gifter.isEmpty,
        gift.senderLogin != batch.gifter.lowercased(),
        let original = result[index].systemMessage else { continue }
      result[index].systemMessage =
        "Bonus on \(batch.gifter)'s \(batch.count)-sub gift: \(original)"
    }
    return result
  }

  private static func ircFields(_ line: String) -> [Substring] {
    var rest = Substring(line)
    for prefix: Character in ["@", ":"] {
      if rest.first == prefix, let space = rest.firstIndex(of: " ") {
        rest = rest[rest.index(after: space)...]
      }
    }
    return rest.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
  }

  /// Parse a Twitch USERNOTICE line for `msg-id=raid` and return a `RaidEvent`.
  private func parseRaidEvent(from line: String) -> RaidEvent? {
    // Line format:
    //   @tags :tmi.twitch.tv USERNOTICE #channel [:message]
    guard line.contains(" USERNOTICE ") else { return nil }

    // Extract tags section.
    var tags: [String: String] = [:]
    if line.first == "@", let spaceIdx = line.firstIndex(of: " ") {
      let tagString = line[line.index(after: line.startIndex)..<spaceIdx]
      for pair in tagString.split(separator: ";") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if kv.count == 2 { tags[String(kv[0])] = String(kv[1]) }
        else if kv.count == 1 { tags[String(kv[0])] = "" }
      }
    }

    guard tags["msg-id"] == "raid" else { return nil }

    let login = tags["msg-param-login"] ?? ""
    let displayName = tags["msg-param-displayName"] ?? login
    let viewerCount = Int(tags["msg-param-viewerCount"] ?? "0") ?? 0
    guard !login.isEmpty else { return nil }

    return RaidEvent(login: login, displayName: displayName, viewerCount: viewerCount)
  }
}

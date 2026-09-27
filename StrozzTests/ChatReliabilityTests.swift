import XCTest

@testable import Strozz

@MainActor
final class ChatReliabilityTests: XCTestCase {
  func testTimedPauseReleasesSnapshotWhenCountdownExpires() throws {
    let model = PlayerModel()
    let message = try message("before pause")
    let start = Date(timeIntervalSince1970: 1_000)
    model.beginChatSoftPause(messages: [message], seconds: 10, now: start)

    XCTAssertTrue(model.updateChatSoftPause(now: start.addingTimeInterval(9)))
    XCTAssertEqual(model.chatSoftPauseRemaining, 1)
    XCTAssertEqual(model.chatFrozenMessages?.first?.id, message.id)
    XCTAssertFalse(model.updateChatSoftPause(now: start.addingTimeInterval(10)))
    XCTAssertNil(model.chatFrozenMessages)
    XCTAssertNil(model.chatSoftPauseRemaining)
    XCTAssertNil(model.chatSoftPauseDeadline)
    XCTAssertNil(model.softPauseTask)
    XCTAssertFalse(model.isChatScrolling)
  }

  func testPauseExpiresAfterSuspensionWithoutCountingMissedTicks() throws {
    let model = PlayerModel()
    let start = Date(timeIntervalSince1970: 1_000)
    model.beginChatSoftPause(messages: [try message("old")], seconds: 10, now: start)

    XCTAssertFalse(model.updateChatSoftPause(now: start.addingTimeInterval(120)))
    XCTAssertNil(model.chatFrozenMessages)
    XCTAssertNil(model.chatSoftPauseRemaining)
  }

  func testEmptyPausedSnapshotDoesNotStrandNewMessages() {
    let model = PlayerModel()
    let start = Date(timeIntervalSince1970: 1_000)
    model.beginChatSoftPause(messages: [], seconds: 10, now: start)
    XCTAssertNotNil(model.chatFrozenMessages)

    XCTAssertFalse(model.updateChatSoftPause(now: start.addingTimeInterval(10)))
    XCTAssertNil(model.chatFrozenMessages)
  }

  func testPromotingPauseToScrollPreservesSnapshotWithoutCountdown() throws {
    let model = PlayerModel()
    let original = try message("reading")
    model.beginChatSoftPause(messages: [original], seconds: 10)
    model.cancelChatSoftPause()
    model.isChatScrolling = true

    XCTAssertFalse(model.updateChatSoftPause(now: .distantFuture))
    XCTAssertEqual(model.chatFrozenMessages?.first?.id, original.id)
    XCTAssertTrue(model.isChatScrolling)
    XCTAssertNil(model.chatSoftPauseRemaining)
  }

  func testResetForCollapseOrChannelChangeClearsAllReadState() throws {
    let model = PlayerModel()
    let original = try message("reading")
    model.beginChatSoftPause(messages: [original], seconds: 10)
    model.isChatScrolling = true
    model.chatScrollAnchorID = original.id
    model.chatScrollTarget = ChatScrollTarget(id: original.id, anchor: .bottom, nonce: 1)
    model.trackpadScrollIndex = 20
    model.lastSentScrollIndex = 20
    let oldTask = Task { @MainActor in }
    model.trackpadScrollTask = oldTask
    model.chatHoldTask = Task { @MainActor in }

    model.resetChatReading()

    XCTAssertTrue(oldTask.isCancelled)
    XCTAssertNil(model.chatFrozenMessages)
    XCTAssertNil(model.chatSoftPauseRemaining)
    XCTAssertNil(model.chatScrollAnchorID)
    XCTAssertNil(model.chatScrollTarget)
    XCTAssertNil(model.trackpadScrollTask)
    XCTAssertNil(model.chatHoldTask)
    XCTAssertFalse(model.isChatScrolling)
    XCTAssertEqual(model.trackpadScrollIndex, 0)
    XCTAssertEqual(model.lastSentScrollIndex, -1)
  }

  func testFocusHandoffCanKeepScrollGateButNeverFrozenData() throws {
    let model = PlayerModel()
    model.chatFrozenMessages = [try message("old")]
    model.isChatScrolling = true

    model.resetChatReading(preservingScrollMode: true)

    XCTAssertTrue(model.isChatScrolling)
    XCTAssertNil(model.chatFrozenMessages)
    XCTAssertNil(model.chatScrollTarget)
    model.isChatScrolling = false
    XCTAssertFalse(model.isChatScrolling)
  }

  func testChatTextCannotImpersonateConnectionControlLines() async {
    let chat = ChatService()
    chat.channel = "example"
    await chat.handle(":viewer!viewer@host PRIVMSG #example : CAP * ACK twitch.tv/tags 366 RECONNECT\r\n")

    XCTAssertFalse(chat.hasCapAck)
    XCTAssertFalse(chat.isConnected)
    XCTAssertEqual(chat.messages.count, 1)
    chat.disconnect()
  }

  func testMinecraftBonusIdentifiesPurchaserFromSharedCommunityGiftID() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    let header = giftNotice(
      kind: "submysterygift", sender: "Viewer", batchID: "batch-1", count: 5,
      text: "Viewer is gifting 5 Tier 1 Subs to the community!"
    )
    let bonus = giftNotice(
      kind: "subgift", sender: "Minecraft", batchID: "batch-1",
      text: "Minecraft gifted a Tier 1 sub to Recipient!"
    )
    let purchaserGifts = (1...5).map { recipient in
      giftNotice(
        kind: "subgift", sender: "Viewer", batchID: "batch-1",
        text: "Viewer gifted a Tier 1 sub to Recipient\(recipient)!"
      )
    }

    await chat.handle(header)
    await chat.handle(([bonus] + purchaserGifts).joined(separator: "\r\n"))

    let notices = chat.messages + chat.pendingAppends
    XCTAssertEqual(notices.count, 7)
    XCTAssertEqual(notices[0].systemMessage, "Viewer is gifting 5 Tier 1 Subs to the community!")
    XCTAssertEqual(
      notices[1].systemMessage,
      "Bonus on Viewer's 5-sub gift: Minecraft gifted a Tier 1 sub to Recipient!"
    )
    XCTAssertEqual(
      notices.dropFirst(2).compactMap(\.systemMessage),
      (1...5).map { "Viewer gifted a Tier 1 sub to Recipient\($0)!" }
    )
  }

  func testMinecraftBonusCorrelatesWhenHeaderComesLaterInSameFrame() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    await chat.handle(
      giftNotice(
        kind: "subgift", sender: "Minecraft", batchID: "batch-2",
        text: "Minecraft gifted a Tier 1 sub to Recipient!"
      ) + "\r\n" + giftNotice(
        kind: "submysterygift", sender: "Viewer", batchID: "batch-2", count: 10,
        text: "Viewer is gifting 10 Tier 1 Subs to the community!"
      )
    )

    XCTAssertEqual(
      chat.messages.first?.systemMessage,
      "Bonus on Viewer's 10-sub gift: Minecraft gifted a Tier 1 sub to Recipient!"
    )
  }

  func testIndependentMinecraftGiftsAndUnrelatedBatchesKeepTwitchWording() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    let independent = giftNotice(
      kind: "subgift", sender: "Minecraft", batchID: "unrelated",
      text: "Minecraft gifted a Tier 1 sub to Recipient!"
    )
    await chat.handle(giftNotice(
      kind: "submysterygift", sender: "Viewer", batchID: "batch-3", count: 5,
      text: "Viewer is gifting 5 Tier 1 Subs to the community!"
    ))
    await chat.handle(independent)

    XCTAssertEqual(
      (chat.messages + chat.pendingAppends).last?.systemMessage,
      "Minecraft gifted a Tier 1 sub to Recipient!"
    )

    chat.disconnect()
    await chat.handle(giftNotice(
      kind: "subgift", sender: "Minecraft", batchID: "batch-3",
      text: "Minecraft gifted a Tier 1 sub to Recipient!"
    ))
    XCTAssertEqual(chat.messages.first?.systemMessage, "Minecraft gifted a Tier 1 sub to Recipient!")
  }

  func testMinecraftOwnCommunityGiftsAreNotCalledPurchaserBonuses() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    await chat.handle(giftNotice(
      kind: "submysterygift", sender: "Minecraft", batchID: "minecraft-batch", count: 5,
      text: "Minecraft is gifting 5 Tier 1 Subs to the community!"
    ))
    await chat.handle(giftNotice(
      kind: "subgift", sender: "Minecraft", batchID: "minecraft-batch",
      text: "Minecraft gifted a Tier 1 sub to Recipient!"
    ))

    XCTAssertEqual(
      (chat.messages + chat.pendingAppends).last?.systemMessage,
      "Minecraft gifted a Tier 1 sub to Recipient!"
    )
  }

  func testJoinConfirmationMustMatchCurrentChannel() async {
    let chat = ChatService()
    chat.channel = "example"
    await chat.handle(":tmi.twitch.tv 366 justinfan #other :End of NAMES list\r\n")
    XCTAssertFalse(chat.isConnected)
    await chat.handle(":tmi.twitch.tv 366 justinfan #example :End of NAMES list\r\n")
    XCTAssertTrue(chat.isConnected)
    chat.disconnect()
  }

  func testDisconnectInvalidatesSessionAndClearsAllPendingData() async {
    let chat = ChatService()
    let oldSession = chat.sessionID
    let oldTransport = chat.ircTransportID
    await chat.handle(":viewer!viewer@host PRIVMSG #example :first\r\n")
    XCTAssertEqual(chat.messages.count, 1)
    chat.disconnect()

    XCTAssertNotEqual(chat.sessionID, oldSession)
    XCTAssertNotEqual(chat.ircTransportID, oldTransport)
    XCTAssertTrue(chat.messages.isEmpty)
    XCTAssertTrue(chat.pendingAppends.isEmpty)
    XCTAssertTrue(chat.syncBuffer.isEmpty)
    XCTAssertNil(chat.ircHealthTask)
    XCTAssertNil(chat.ircHealth)
  }

  func testCancelledMergeCannotAppendOldMessages() async throws {
    let chat = ChatService()
    let old = try message("stale")
    let task = Task { @MainActor in await chat.enqueueTokenized([old]) }
    task.cancel()
    await task.value

    XCTAssertTrue(chat.messages.isEmpty)
    XCTAssertTrue(chat.pendingAppends.isEmpty)
  }

  func testCancelledSyncDrainCannotClearReplacementTask() async throws {
    let chat = ChatService()
    chat.configureChatSync(enabled: true, delaySeconds: 60)
    chat.enqueue([try message("first")])
    let cancelledDrain = try XCTUnwrap(chat.syncDrainTask)
    chat.flushSyncBuffer()
    chat.enqueue([try message("second")])
    let replacement = try XCTUnwrap(chat.syncDrainTask)

    await cancelledDrain.value

    XCTAssertEqual(chat.syncDrainTask, replacement)
    XCTAssertEqual(chat.pendingSyncMessageCount, 1)
    chat.disconnect()
    await replacement.value
  }

  func testRollingBufferKeepsNewestMessagesWithinBound() async {
    let chat = ChatService()
    let lines = (0..<700).map { ":viewer!viewer@host PRIVMSG #example :line-\($0)" }
    // Distinct timestamps preserve input ordering through the sync sort.
    let stamped = lines.enumerated().map {
      "@tmi-sent-ts=\(1_000_000 + $0.offset);display-name=Viewer " + $0.element
    }
    await chat.handle(stamped.joined(separator: "\r\n"))

    XCTAssertEqual(chat.messages.count, chat.maxBufferedMessages)
    XCTAssertEqual(chat.messages.last?.text, "line-699")
    XCTAssertEqual(Set(chat.messages.map(\.id)).count, chat.messages.count)
    chat.disconnect()
  }

  func testReturningToLiveRetimesQueuedChatWithoutAnotherMessage() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.configureChatSync(enabled: true, delaySeconds: 754)
    let held = try message("held at suspended video position")
    chat.enqueue([held])
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(chat.messages.isEmpty)

    chat.configureChatSync(enabled: true, delaySeconds: 0.8)
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(chat.syncBuffer.first).releaseAt.timeIntervalSince(held.timestamp), 0.81)
    try await Task.sleep(for: .seconds(1.1))

    XCTAssertEqual(chat.messages.map(\.id), [held.id])
    XCTAssertEqual(chat.pendingSyncMessageCount, 0)
    XCTAssertNil(chat.syncDrainTask)
  }

  func testEarlierArrivingBacklogWakesDrainSleepingOnLaterMessage() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.configureChatSync(enabled: true, delaySeconds: 60)
    let later = try message("future")
    chat.enqueue([later])
    try await Task.sleep(for: .milliseconds(30))
    let backlog = (0..<5).map {
      ChatMessage(youtubeAuthor: "fixture", text: "past-\($0)", youtubeEmoteURLs: [:],
                  timestamp: Date().addingTimeInterval(-90 + Double($0)))
    }

    chat.enqueue(backlog)
    try await Task.sleep(for: .seconds(1.7))

    XCTAssertEqual(chat.messages.map(\.id), backlog.map(\.id))
    XCTAssertEqual(chat.syncBuffer.map(\.message.id), [later.id])
    XCTAssertEqual(chat.pendingSyncMessageCount, 1)
  }

  func testLaterMessagesDoNotRestartTheScheduledDrain() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.configureChatSync(enabled: true, delaySeconds: 60)
    chat.enqueue([try message("first")])
    let drain = try XCTUnwrap(chat.syncDrainTask)
    let deadline = try XCTUnwrap(chat.syncDrainDeadline)
    try await Task.sleep(for: .milliseconds(30))
    chat.enqueue([try message("second")])

    XCTAssertEqual(chat.syncDrainTask, drain)
    XCTAssertEqual(chat.syncDrainDeadline, deadline)
    XCTAssertEqual(chat.pendingSyncMessageCount, 2)
  }

  func testShortenedDelayCancellationCannotClearTheNewDrain() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.configureChatSync(enabled: true, delaySeconds: 754)
    chat.enqueue([try message("held")])
    let oldDrain = try XCTUnwrap(chat.syncDrainTask)
    try await Task.sleep(for: .milliseconds(30))
    chat.configureChatSync(enabled: true, delaySeconds: 17)
    let replacement = try XCTUnwrap(chat.syncDrainTask)
    let deadline = try XCTUnwrap(chat.syncDrainDeadline)

    await oldDrain.value

    XCTAssertTrue(oldDrain.isCancelled)
    XCTAssertEqual(chat.syncDrainTask, replacement)
    XCTAssertEqual(chat.syncDrainDeadline, deadline)
    XCTAssertLessThan(deadline.timeIntervalSinceNow, 17)
  }

  func testForegroundRechecksOverdueMessagesWithoutAnotherArrival() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.configureChatSync(enabled: true, delaySeconds: 60)
    let held = try message("held")
    chat.enqueue([held])
    let oldDrain = try XCTUnwrap(chat.syncDrainTask)
    try await Task.sleep(for: .milliseconds(30))
    // Model wall-clock deadlines passing while the sleeping task is suspended.
    chat.syncBuffer[0].releaseAt = Date().addingTimeInterval(-1)
    chat.restartSyncDrain()
    await oldDrain.value
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(chat.messages.map(\.id), [held.id])
    XCTAssertEqual(chat.pendingSyncMessageCount, 0)
    XCTAssertNil(chat.syncDrainTask)
    XCTAssertNil(chat.syncDrainDeadline)
  }

  func testShortenedDelayKeepsFutureTimestampAnchoredToArrival() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.configureChatSync(enabled: true, delaySeconds: 754)
    let skewed = ChatMessage(
      youtubeAuthor: "fixture", text: "future clock", youtubeEmoteURLs: [:],
      timestamp: Date().addingTimeInterval(600))
    let arrival = Date()
    chat.enqueue([skewed])
    chat.configureChatSync(enabled: true, delaySeconds: 17)

    let pending = try XCTUnwrap(chat.syncBuffer.first)
    XCTAssertLessThan(pending.releaseAt.timeIntervalSince(arrival), 17.1)
    XCTAssertGreaterThan(pending.releaseAt.timeIntervalSince(arrival), 16.9)
  }

  func testShortenedDelayHonorsStartupRampAndDoesNotPostponeOldMessages() throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.syncWarmupStart = Date().addingTimeInterval(-15)
    chat.configureChatSync(enabled: true, delaySeconds: 60)
    let held = try message("warming up")
    chat.enqueue([held])
    chat.configureChatSync(enabled: true, delaySeconds: 20)

    let pending = try XCTUnwrap(chat.syncBuffer.first)
    XCTAssertEqual(pending.releaseAt.timeIntervalSince(held.timestamp), 10, accuracy: 0.1)
    chat.configureChatSync(enabled: true, delaySeconds: 60)
    XCTAssertEqual(chat.syncBuffer.first?.releaseAt, pending.releaseAt)
  }

  func testVideoDelayChangeDoesNotCollapseBacklogTrickle() throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.configureChatSync(enabled: true, delaySeconds: 60)
    let backlog = (0..<5).map {
      ChatMessage(youtubeAuthor: "fixture", text: "past-\($0)", youtubeEmoteURLs: [:],
                  timestamp: Date().addingTimeInterval(-90 + Double($0)))
    }
    chat.enqueue(backlog)
    let deadlines = chat.syncBuffer.map(\.releaseAt)

    chat.configureChatSync(enabled: true, delaySeconds: 17)

    XCTAssertEqual(chat.syncBuffer.map(\.releaseAt), deadlines)
    XCTAssertEqual(deadlines.last!.timeIntervalSince(deadlines.first!), 1.2, accuracy: 0.001)
  }

  func testTurningSyncOffFlushesOnceAndClearsWakeDeadline() async throws {
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.configureChatSync(enabled: true, delaySeconds: 754)
    let held = try message("held")
    chat.enqueue([held])
    let oldDrain = try XCTUnwrap(chat.syncDrainTask)
    try await Task.sleep(for: .milliseconds(30))

    chat.configureChatSync(enabled: false, delaySeconds: 17)
    await oldDrain.value
    chat.restartSyncDrain()

    XCTAssertEqual(chat.messages.map(\.id), [held.id])
    XCTAssertEqual(chat.pendingSyncMessageCount, 0)
    XCTAssertNil(chat.syncDrainTask)
    XCTAssertNil(chat.syncDrainDeadline)
  }

  private func message(_ text: String) throws -> ChatMessage {
    try XCTUnwrap(ChatMessage(ircLine: ":viewer!viewer@host PRIVMSG #example :\(text)"))
  }

  private func giftNotice(
    kind: String, sender: String, batchID: String, count: Int? = nil, text: String
  ) -> String {
    let countTag = count.map { ";msg-param-mass-gift-count=\($0)" } ?? ""
    let escaped = text.replacingOccurrences(of: " ", with: "\\s")
    return "@msg-id=\(kind);login=\(sender.lowercased());display-name=\(sender);msg-param-community-gift-id=\(batchID)\(countTag);system-msg=\(escaped) :tmi.twitch.tv USERNOTICE #example"
  }
}

final class ChatConnectionHealthTests: XCTestCase {
  func testMissingJoinTimesOutEvenWhenServerSendsOtherFrames() {
    var health = ChatConnectionHealth(now: 100)
    health.receivedFrame(now: 119)
    XCTAssertEqual(health.nextAction(now: 119), .wait)
    XCTAssertEqual(health.nextAction(now: 120), .reconnect(.joinTimeout))
  }

  func testQuietHealthyChannelIsKeptAliveByPongs() {
    var health = ChatConnectionHealth(now: 100)
    health.joinedChannel(now: 101)
    for cycle in 0..<100 {
      let sentAt = 131.0 + Double(cycle) * 31
      XCTAssertEqual(health.nextAction(now: sentAt - 1), .wait)
      XCTAssertEqual(health.nextAction(now: sentAt), .ping)
      health.receivedPong(sentAt: sentAt, now: sentAt + 1)
    }
    XCTAssertNil(health.lastFrameAt)
  }

  func testSilentSocketTimesOutWithinOneHeartbeatDeadline() {
    var health = ChatConnectionHealth(now: 0)
    health.joinedChannel(now: 0)
    XCTAssertEqual(health.nextAction(now: 30), .ping)
    XCTAssertEqual(health.nextAction(now: 44.9), .wait)
    XCTAssertEqual(health.nextAction(now: 45), .reconnect(.pongTimeout))
  }

  func testLatePongFromEarlierProbeCannotClearCurrentDeadline() {
    var health = ChatConnectionHealth(now: 0)
    health.joinedChannel(now: 0)
    XCTAssertEqual(health.nextAction(now: 30), .ping)
    health.receivedPong(sentAt: 30, now: 31)
    XCTAssertEqual(health.nextAction(now: 61), .ping)
    health.receivedPong(sentAt: 30, now: 62)
    XCTAssertEqual(health.nextAction(now: 76), .reconnect(.pongTimeout))
  }

  func testPendingPingDoesNotSendRepeatedProbes() {
    var health = ChatConnectionHealth(now: 0)
    health.joinedChannel(now: 0)
    XCTAssertEqual(health.nextAction(now: 30), .ping)
    XCTAssertEqual(health.nextAction(now: 35), .wait)
    XCTAssertEqual(health.nextAction(now: 40), .wait)
  }

  func testReplacementConnectionGetsFreshJoinDeadline() {
    var health = ChatConnectionHealth(now: 0)
    health.joinedChannel(now: 0)
    XCTAssertEqual(health.nextAction(now: 30), .ping)
    health = ChatConnectionHealth(now: 50)
    health.receivedPong(sentAt: 30, now: 51)
    XCTAssertEqual(health.nextAction(now: 69), .wait)
    XCTAssertEqual(health.nextAction(now: 70), .reconnect(.joinTimeout))
  }
}

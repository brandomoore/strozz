import Observation
import OSLog
import SwiftUI

/// Selection survives navigation; the controller is only the mounted playback
/// projection of this lineup, never a second queue.
@MainActor
@Observable
final class MultiviewLineup {
  struct Entry: Identifiable, Equatable {
    let id: UUID
    var channel: FollowedChannel
    var offlineSince: ContinuousClock.Instant?
  }

  private(set) var entries: [Entry] = []
  private(set) var controller: MultiviewController?
  private(set) var isShowingPlayback = false
  private(set) var isOpeningPlayback = false
  private(set) var playbackRequest = UUID()
  var notice: String?
  @ObservationIgnored private let loadStatus: @MainActor (FollowedChannel) async -> StreamLiveStatus
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "MultiviewLineup")

  init(loadStatus: @escaping @MainActor (FollowedChannel) async -> StreamLiveStatus = MultiviewLineup.liveStatus) {
    self.loadStatus = loadStatus
  }

  var liveChannels: [FollowedChannel] {
    entries.filter { $0.offlineSince == nil }.map(\.channel)
  }
  var canStart: Bool { liveChannels.count >= (controller == nil ? 2 : 1) }
  var isFull: Bool { (isShowingPlayback ? entries.count : liveChannels.count) >= multiviewPaneLimit }
  var nextExpiry: ContinuousClock.Instant? {
    guard !isShowingPlayback else { return nil }
    return entries.compactMap { $0.offlineSince?.advanced(by: MultiviewSelection.offlineGrace) }.min()
  }

  func contains(_ channel: FollowedChannel) -> Bool {
    entries.contains { $0.channel.channelKey == channel.channelKey }
  }

  func toggle(_ channel: FollowedChannel) {
    if contains(channel) {
      remove(channel.channelKey)
      return
    }
    guard channel.platform != .youtube, channel.isLive else {
      notice = String(localized: "Only live Twitch and Kick streams can be added.")
      return
    }
    guard !isFull else {
      notice = String(localized: "Multiview holds up to six streams.")
      return
    }
    entries.append(.init(id: UUID(), channel: channel))
    synchronizePanes()
  }

  func remove(_ key: String) {
    entries.removeAll { $0.channel.channelKey == key }
    synchronizePanes()
  }

  func clear() {
    entries.removeAll()
    controller?.teardown()
    controller = nil
    isShowingPlayback = false
    isOpeningPlayback = false
  }

  func preparePlaybackRequest() { isOpeningPlayback = true }
  func cancelPlaybackRequest() { isOpeningPlayback = false }

  func requestPlayback() {
    preparePlaybackRequest()
    playbackRequest = UUID()
  }

  func startPlayback() {
    defer { isOpeningPlayback = false }
    if isShowingPlayback {
      controller?.collapse()
      return
    }
    guard canStart else {
      notice = String(localized: "Select at least two live streams.")
      return
    }
    synchronizePanes()
    if controller == nil {
      controller = MultiviewController(channels: liveChannels,
        muted: ProcessInfo.processInfo.environment["STROZZ_MUTE_PLAYBACK"] == "1")
    }
    isShowingPlayback = true
    controller?.collapse()
    controller?.setBrowsing(false)
  }

  func browse() {
    isShowingPlayback = false
    controller?.setBrowsing(true)
    synchronizePanes()
  }

  /// Only explicit provider observations can retire selections. Absence from a
  /// Following, category or search response says nothing about another channel.
  func observe(_ status: StreamLiveStatus, key: String, now: ContinuousClock.Instant = .now) {
    guard let index = entries.firstIndex(where: { $0.channel.channelKey == key }) else { return }
    switch status {
    case .live:
      // Do not reclaim a slot already filled while this channel was offline.
      if !isShowingPlayback, entries[index].offlineSince != nil, isFull { return }
      entries[index].offlineSince = nil
    case .offline:
      if entries[index].offlineSince == nil { entries[index].offlineSince = now }
    case .unknown: return
    }
    if !isShowingPlayback { synchronizePanes() }
  }

  func expire(at now: ContinuousClock.Instant = .now) {
    guard !isShowingPlayback else { return }
    entries.removeAll {
      $0.offlineSince.map { now >= $0.advanced(by: MultiviewSelection.offlineGrace) } ?? false
    }
    synchronizePanes()
  }

  func refreshStatuses() async {
    for entry in entries {
      let status = await loadStatus(entry.channel)
      guard !Task.isCancelled, !isShowingPlayback else { return }
      // Removing then re-adding a channel creates a new selection generation.
      guard entries.contains(where: { $0.id == entry.id }) else { continue }
      if status == .unknown {
        Self.logger.warning("Could not refresh a selected stream's live status")
      }
      observe(status, key: entry.channel.channelKey)
    }
  }

  func synchronize(_ pane: MultiviewPane, previousKey: String) {
    guard let index = entries.firstIndex(where: { $0.channel.channelKey == previousKey }) else { return }
    if entries.contains(where: { $0.id != entries[index].id && $0.channel.channelKey == pane.channel.channelKey }) {
      controller?.removePane(pane.id)
      remove(previousKey)
      return
    }
    entries[index].channel = pane.channel
    observe(pane.model.isOffline ? .offline : .live, key: pane.channel.channelKey)
  }

  private func synchronizePanes() {
    guard let controller else { return }
    let channels = isShowingPlayback ? entries.map(\.channel) : liveChannels
    let wanted = Set(channels.map(\.channelKey))
    for pane in controller.panes where !wanted.contains(pane.channel.channelKey) {
      if controller.panes.count == 1 {
        controller.teardown()
        self.controller = nil
        isShowingPlayback = false
        return
      }
      controller.removePane(pane.id)
    }
    for channel in channels where !controller.panes.contains(where: { $0.channel.channelKey == channel.channelKey }) {
      controller.addPane(channel)
    }
  }

  private static func liveStatus(_ channel: FollowedChannel) async -> StreamLiveStatus {
    switch channel.platform {
    case .twitch: return await PlaybackService.streamLiveStatus(for: channel.login)
    case .kick:
      do { return try await KickPlaybackService.channel(channel.login).isLive ? .live : .offline }
      catch KickPlaybackService.Failure.notFound { return .offline }
      catch { return .unknown }
    case .youtube: return .unknown
    }
  }
}

extension EnvironmentValues {
  @Entry var multiviewLineup: MultiviewLineup? = nil
}

import AVKit
import Foundation
import Observation
import SwiftUI

let multiviewPaneLimit = 6

enum MultiviewLayout: String, CaseIterable {
  case featured, spotlight, grid

  var title: LocalizedStringResource {
    switch self {
    case .featured: "Featured"
    case .spotlight: "Spotlight"
    case .grid: "Equal"
    }
  }

  var glyph: Glyph {
    switch self {
    case .featured: .sidebarRightCollapse
    case .spotlight: .layoutBottombar
    case .grid: .layoutGrid
    }
  }

  var hasPrimary: Bool { self != .grid }
}

enum MultiviewQualityTier {
  case source, grid, grid720, grid1080, thumbnail, hidden

  var targetBitrate: Int {
    switch self {
    case .source, .grid720, .grid1080: 0
    case .grid: 3_000_000
    case .thumbnail, .hidden: 800_000
    }
  }

  var maximumResolution: CGSize {
    switch self {
    case .source: .zero
    case .grid, .grid720: CGSize(width: 1280, height: 720)
    case .grid1080: CGSize(width: 1920, height: 1080)
    case .thumbnail: CGSize(width: 854, height: 480)
    case .hidden: CGSize(width: 640, height: 360)
    }
  }
}

/// Presentation changes must not become playback-session changes.
@MainActor
@Observable
final class MultiviewPlaybackContext {
  var isExpanded = false
  private(set) var videoAspectRatio = MultiviewGeometry.defaultAspectRatio
  var videoIsVisible = true
  var isBrowsing = false
  var qualityTier: MultiviewQualityTier = .grid
  var profile = LivePlaybackProfile.nativeLowLatency
  var quality = "Auto"
  var reloadID = UUID()
  var focusRequest = UUID()
  var exitRequests = 0
  var playPauseRequests = 0
  var moveRequests = 0
  var moveDirection = MoveCommandDirection.up
  var watchRequests = 0
  var requestedChannel: FollowedChannel?
  @ObservationIgnored var needsBrowsingResume = false
  @ObservationIgnored var onClose: (() -> Void)?

  func updateVideoAspectRatio(_ size: CGSize?) {
    guard let size, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0 else { return }
    let ratio = size.width / size.height
    if videoAspectRatio != ratio { videoAspectRatio = ratio }
  }
}

@MainActor
@Observable
final class MultiviewPane: Identifiable {
  let id: String
  var channel: FollowedChannel
  let model: PlayerModel
  let presentation: MultiviewPlaybackContext
  var isAudible = false

  var player: AVPlayer { model.player }
  var isLoading: Bool { model.isLoading }
  var hasError: Bool { model.errorMessage != nil || model.isOffline }
  var qualityTier: MultiviewQualityTier { presentation.qualityTier }
  var isTwitchLive: Bool {
    channel.platform == .twitch && model.livePlatform == .twitch
      && !model.isUsingAltSource && model.liveVODHandoff?.isActive != true
  }
  var playbackTarget: PlatformLiveTarget {
    .init(platform: model.livePlatform,
      channel: model.livePlatform == .kick ? model.kickPlaybackTarget : model.activeChannel)
  }

  func synchronizeChannel() {
    let target = playbackTarget
    guard !target.channel.isEmpty,
      target.channel != channel.login || target.platform != channel.platform else { return }
    channel = FollowedChannel(id: id, login: target.channel, displayName: model.channelDisplayName,
      title: model.streamTitle, gameName: "", viewerCount: nil, thumbnailURL: nil,
      profileImageURL: model.channelAvatarURL, isLive: true)
    channel.platform = target.platform
  }

  func accessibilityStatus(isTransitioning: Bool) -> LocalizedStringResource {
    if model.isOffline { return "Offline" }
    if isLoading { return "Loading" }
    if hasError { return "Unavailable" }
    return isTransitioning ? "Transitioning" : "Live"
  }

  init(channel: FollowedChannel) {
    id = channel.platform == .twitch ? channel.id : "\(channel.platform.rawValue):\(channel.id)"
    self.channel = channel
    presentation = MultiviewPlaybackContext()
    model = PlayerModel()
    model.multiviewContext = presentation
    model.isLoading = true
    model.activeChannel = channel.login
    model.channelDisplayName = channel.displayName
    model.channelAvatarURL = channel.profileImageURL
    model.streamTitle = channel.title
    model.player.isMuted = true
  }

  func stop() {
    model.audioTakeoverTask?.cancel()
    model.audioTakeoverTask = nil
    model.isLoading = true
    model.nativeGeneration = UUID()
    model.nativeStartupTask?.cancel()
    model.nativeRefreshTask?.cancel()
    model.fallbackRestoreTask?.cancel()
    model.latencyTask?.cancel()
    model.playbackWatchdogTask?.cancel()
    model.nativeHLS?.stop()
    model.nativeHLS = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
  }
}

/// Owns presentation and resource budgets. Each pane's mounted PlayerView owns
/// the same live engine, watchdog, and lifecycle behavior as a standalone player.
@MainActor
@Observable
final class MultiviewController {
  private(set) var panes: [MultiviewPane]
  private(set) var audiblePaneID: String?
  private(set) var layout = MultiviewLayout.featured
  private(set) var primaryPaneID: String?
  private(set) var expandedPaneID: String?
  private(set) var isTransitioning = false
  private(set) var restoredPaneID: String?
  private(set) var focusRestoreRequest = UUID()
  private(set) var isBrowsing = false
  @ObservationIgnored var reduceMotion = false
  @ObservationIgnored private var transitionID = UUID()
  @ObservationIgnored private let muted: Bool
  @ObservationIgnored private let controlledAuto: Bool
  @ObservationIgnored private var sleepSuspendedPaneIDs = Set<String>()

  init(channels: [FollowedChannel], muted: Bool = false,
       controlledAuto: Bool = NativeLowLatencyHLS.controlledAutoEnabled) {
    self.muted = muted
    self.controlledAuto = controlledAuto
    var seen = Set<String>()
    panes = channels.filter { seen.insert($0.channelKey).inserted }
      .prefix(multiviewPaneLimit).map(MultiviewPane.init)
    primaryPaneID = panes.first?.id
    for pane in panes { configure(pane) }
    refreshQuality()
  }

  var canAddPane: Bool { panes.count < multiviewPaneLimit }
  var primaryPane: MultiviewPane? { panes.first { $0.id == primaryPaneID } ?? panes.first }
  var expandedPane: MultiviewPane? { panes.first { $0.id == expandedPaneID } }

  func start() { refreshQuality() }

  func load(_ pane: MultiviewPane) {
    guard panes.contains(where: { $0 === pane }) else { return }
    pane.presentation.reloadID = UUID()
  }

  private func configure(_ pane: MultiviewPane) {
    pane.presentation.onClose = { [weak self] in self?.collapse() }
    pane.presentation.isBrowsing = isBrowsing
  }

  @discardableResult
  func addPane(_ channel: FollowedChannel) -> String? {
    guard canAddPane, !panes.contains(where: { $0.channel.channelKey == channel.channelKey }) else { return nil }
    let pane = MultiviewPane(channel: channel)
    configure(pane)
    panes.append(pane)
    refreshQuality()
    return pane.id
  }

  func removePane(_ id: String) {
    guard panes.count > 1, let index = panes.firstIndex(where: { $0.id == id }) else { return }
    panes[index].stop()
    panes.remove(at: index)
    if expandedPaneID == id { expandedPaneID = nil }
    if primaryPaneID == id { primaryPaneID = panes.first?.id }
    if audiblePaneID == id { setAudiblePane(panes.first?.id) }
    refreshQuality()
  }

  func makePrimary(_ id: String) {
    guard panes.contains(where: { $0.id == id }) else { return }
    primaryPaneID = id
    refreshQuality()
  }

  func spotlight(_ id: String) {
    guard panes.contains(where: { $0.id == id }) else { return }
    primaryPaneID = id
    layout = .spotlight
    refreshQuality()
  }

  func setLayout(_ layout: MultiviewLayout, focusedPaneID: String? = nil) {
    if layout.hasPrimary, let focusedPaneID, panes.contains(where: { $0.id == focusedPaneID }) {
      primaryPaneID = focusedPaneID
    }
    self.layout = layout
    refreshQuality()
  }

  func expand(_ id: String) {
    guard expandedPaneID != id, let selected = panes.first(where: { $0.id == id }) else { return }
    let request = UUID()
    transitionID = request
    isTransitioning = true
    withAnimation(.motionAware(.easeInOut(duration: 0.35), reduceMotion: reduceMotion)) {
      expandedPaneID = id
      for pane in panes { pane.presentation.isExpanded = pane.id == id }
      setAudiblePane(id)
      refreshQuality()
    } completion: {
      guard self.transitionID == request, self.expandedPaneID == id else { return }
      self.isTransitioning = false
      selected.presentation.focusRequest = UUID()
    }
  }

  func collapse() {
    guard let returning = expandedPaneID else { return }
    let request = UUID()
    transitionID = request
    isTransitioning = true
    withAnimation(.motionAware(.easeInOut(duration: 0.35), reduceMotion: reduceMotion)) {
      expandedPaneID = nil
      for pane in panes { pane.presentation.isExpanded = false }
      refreshQuality()
    } completion: {
      guard self.transitionID == request, self.expandedPaneID == nil else { return }
      self.isTransitioning = false
      self.restoredPaneID = returning
      self.focusRestoreRequest = UUID()
    }
  }

  private func refreshQuality() {
    for pane in panes {
      pane.presentation.videoIsVisible = !isBrowsing && (expandedPaneID == nil || pane.id == expandedPaneID)
      if let expandedPaneID {
        pane.presentation.qualityTier = pane.id == expandedPaneID ? .source : .hidden
      } else if layout == .spotlight {
        pane.presentation.qualityTier = pane.id == primaryPane?.id ? .source : .thumbnail
      } else {
        pane.presentation.qualityTier = controlledAuto ? (panes.count <= 4 ? .grid1080 : .grid720) : .grid
      }
    }
  }

  func setBrowsing(_ browsing: Bool) {
    guard isBrowsing != browsing else { return }
    isBrowsing = browsing
    for pane in panes {
      pane.presentation.isBrowsing = browsing
      if browsing { pane.player.pause() }
    }
    refreshQuality()
    if !browsing {
      restoredPaneID = audiblePaneID ?? panes.first?.id
      focusRestoreRequest = UUID()
    }
  }

  func setAudiblePane(_ id: String?) {
    let next = panes.contains(where: { $0.id == id }) ? id : nil
    guard audiblePaneID != next else { return }
    audiblePaneID = next
    for pane in panes {
      pane.isAudible = pane.id == next
      pane.player.isMuted = muted || !pane.isAudible
    }
  }

  struct AudioState {
    let paneID: String?
    let wasMuted: Bool
  }

  func suspendAudio() -> AudioState {
    let state = AudioState(paneID: audiblePaneID,
      wasMuted: panes.first(where: { $0.id == audiblePaneID })?.player.isMuted ?? true)
    setAudiblePane(nil)
    return state
  }

  func restoreAudio(_ state: AudioState) {
    setAudiblePane(state.paneID)
    if state.wasMuted { panes.first(where: { $0.id == state.paneID })?.player.isMuted = true }
  }

  func synchronizeExpandedSleep() {
    if expandedPane?.model.isSleeping == true {
      for pane in panes where pane.id != expandedPaneID && !pane.model.isUserPaused && !pane.model.isSleeping {
        sleepSuspendedPaneIDs.insert(pane.id)
        pane.model.multiviewSleepSuspended = true
        pane.player.pause()
      }
      UIApplication.shared.isIdleTimerDisabled = false
    } else {
      for pane in panes where sleepSuspendedPaneIDs.contains(pane.id) {
        pane.model.multiviewSleepSuspended = false
        pane.presentation.reloadID = UUID()
      }
      sleepSuspendedPaneIDs.removeAll()
      UIApplication.shared.isIdleTimerDisabled = true
    }
  }

  func teardown() {
    transitionID = UUID()
    isTransitioning = false
    sleepSuspendedPaneIDs.removeAll()
    for pane in panes { pane.stop() }
  }
}

enum MultiviewGeometry {
  static let defaultAspectRatio: CGFloat = 16 / 9
  static let videoCornerRadius: CGFloat = 16
  static let maximumOutlineWidth: CGFloat = 5
  static let gap = maximumOutlineWidth * 2

  static func frames(ids: [String], size: CGSize, layout: MultiviewLayout,
                     primary: String?, expanded: String?,
                     aspectRatios: [String: CGFloat] = [:],
                     bottomClearance: CGFloat = 0) -> [String: CGRect] {
    guard !ids.isEmpty, size.width > maximumOutlineWidth * 2,
      size.height > maximumOutlineWidth * 2 else { return [:] }
    let bounds = CGRect(origin: .zero, size: size)
      .insetBy(dx: maximumOutlineWidth, dy: maximumOutlineWidth)
    let ratios = Dictionary(uniqueKeysWithValues: ids.map { ($0, aspectRatios[$0] ?? defaultAspectRatio) })
    let columns = (1...ids.count).max { lhs, rhs in
      gridHeight(ids: ids, bounds: bounds, columns: lhs, ratios: ratios)
        < gridHeight(ids: ids, bounds: bounds, columns: rhs, ratios: ratios)
    } ?? 1
    func arrangement(in bounds: CGRect) -> [String: CGRect] {
      arrangedFrames(ids: ids, bounds: bounds, layout: layout, primary: primary,
        ratios: ratios, gridColumns: columns)
    }
    var frames = arrangement(in: bounds)
    if expanded == nil, bottomClearance > 0 {
      let available = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
        height: max(1, bounds.height - bottomClearance))
      let occupied = frames.values.reduce(CGRect.null) { $0.union($1) }
      if occupied.maxY > available.maxY {
        if occupied.height <= available.height {
          // Use existing letterboxing before reducing any picture's size.
          frames = frames.mapValues { $0.offsetBy(dx: 0, dy: available.maxY - occupied.maxY) }
        } else {
          // Keep the same rows/columns and full outside-outline gaps when shrinking.
          frames = arrangement(in: available)
        }
      }
    }
    if let expanded, ids.contains(expanded) { frames[expanded] = CGRect(origin: .zero, size: size) }
    return frames
  }

  private static func gridHeight(ids: [String], bounds: CGRect, columns: Int,
                                 ratios: [String: CGFloat]) -> CGFloat {
    let rowCount = (ids.count + columns - 1) / columns
    var height = (bounds.height - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount)
    for start in stride(from: 0, to: ids.count, by: columns) {
      let row = ids[start..<min(start + columns, ids.count)]
      let totalRatio = row.reduce(CGFloat.zero) { $0 + ratios[$1, default: defaultAspectRatio] }
      height = min(height, (bounds.width - gap * CGFloat(row.count - 1)) / totalRatio)
    }
    return max(0, height)
  }

  private static func arrangedFrames(ids: [String], bounds: CGRect, layout: MultiviewLayout,
                                     primary: String?, ratios: [String: CGFloat],
                                     gridColumns: Int) -> [String: CGRect] {
    func ratio(_ id: String) -> CGFloat { ratios[id, default: defaultAspectRatio] }
    let selected = ids.first(where: { $0 == primary }) ?? ids[0]
    let others = ids.filter { $0 != selected }
    var frames: [String: CGRect] = [:]
    if layout == .spotlight && !others.isEmpty {
      let totalRatio = others.reduce(CGFloat.zero) { $0 + ratio($1) }
      let stripGaps = gap * CGFloat(others.count - 1)
      let stripHeight = max(0, min(bounds.height / 4, (bounds.width - stripGaps) / totalRatio))
      let mainHeight = max(0, min(bounds.height - stripHeight - gap, bounds.width / ratio(selected)))
      let top = bounds.midY - (mainHeight + gap + stripHeight) / 2
      let mainWidth = mainHeight * ratio(selected)
      frames[selected] = CGRect(x: bounds.midX - mainWidth / 2, y: top,
        width: mainWidth, height: mainHeight)
      var x = bounds.midX - (stripHeight * totalRatio + stripGaps) / 2
      for id in others {
        let width = stripHeight * ratio(id)
        frames[id] = CGRect(x: x, y: top + mainHeight + gap, width: width, height: stripHeight)
        x += width + gap
      }
    } else if layout == .featured && !others.isEmpty {
      let columns = others.count > 3 ? 2 : 1
      let rows = stride(from: 0, to: others.count, by: columns).map {
        Array(others[$0..<min($0 + columns, others.count)])
      }
      let rowRatios = rows.map { $0.reduce(CGFloat.zero) { $0 + ratio($1) } }
      let primaryRows = CGFloat(max(2, rows.count))
      let mainGaps = gap * (primaryRows - 1)
      let height = max(0, min((bounds.height - mainGaps) / primaryRows,
        (bounds.width - mainGaps * ratio(selected) - gap * CGFloat(columns))
          / (primaryRows * ratio(selected) + (rowRatios.max() ?? 0))))
      let mainHeight = height * primaryRows + mainGaps
      let mainWidth = mainHeight * ratio(selected)
      let sideWidth = height * (rowRatios.max() ?? 0) + gap * CGFloat(columns - 1)
      let left = bounds.midX - (mainWidth + gap + sideWidth) / 2
      frames[selected] = CGRect(x: left, y: bounds.midY - mainHeight / 2,
        width: mainWidth, height: mainHeight)
      let top = bounds.midY - (height * CGFloat(rows.count) + gap * CGFloat(rows.count - 1)) / 2
      for (index, row) in rows.enumerated() {
        var x = left + mainWidth + gap
        for id in row {
          let width = height * ratio(id)
          frames[id] = CGRect(x: x, y: top + CGFloat(index) * (height + gap), width: width, height: height)
          x += width + gap
        }
      }
    } else {
      let columns = gridColumns
      let rows = stride(from: 0, to: ids.count, by: columns).map {
        Array(ids[$0..<min($0 + columns, ids.count)])
      }
      let rowRatios = rows.map { row in row.reduce(CGFloat.zero) { $0 + ratio($1) } }
      let height = gridHeight(ids: ids, bounds: bounds, columns: columns, ratios: ratios)
      let widths = rows.enumerated().map { index, row in
        height * rowRatios[index] + gap * CGFloat(row.count - 1)
      }
      let left = bounds.midX - (widths.max() ?? 0) / 2
      let top = bounds.midY - (height * CGFloat(rows.count) + gap * CGFloat(rows.count - 1)) / 2
      for (index, row) in rows.enumerated() {
        var x = left
        for id in row {
          let width = height * ratio(id)
          frames[id] = CGRect(x: x, y: top + CGFloat(index) * (height + gap), width: width, height: height)
          x += width + gap
        }
      }
    }
    return frames
  }
}

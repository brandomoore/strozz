import AVKit
import Foundation
import Observation
import SwiftUI

let multiviewPaneLimit = 6

enum MultiviewLayout {
  case grid, spotlight
}

enum MultiviewQualityTier {
  case source, grid, thumbnail

  var targetBitrate: Int {
    switch self {
    case .source: 0
    case .grid: 3_000_000
    case .thumbnail: 800_000
    }
  }

  var maximumResolution: CGSize {
    switch self {
    case .source: .zero
    case .grid: CGSize(width: 1280, height: 720)
    case .thumbnail: CGSize(width: 854, height: 480)
    }
  }
}

/// Presentation changes must not become playback-session changes.
@MainActor
@Observable
final class MultiviewPlaybackContext {
  var isExpanded = false
  var qualityTier: MultiviewQualityTier = .grid
  var profile = LivePlaybackProfile.nativeLowLatency
  var quality = "Auto"
  var reloadID = UUID()
  var focusRequest = UUID()
  var exitRequests = 0
  var playPauseRequests = 0
  var moveRequests = 0
  var moveDirection = MoveCommandDirection.up
  @ObservationIgnored var onClose: (() -> Void)?
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

  init(channel: FollowedChannel) {
    id = channel.id
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
  private(set) var layout = MultiviewLayout.grid
  private(set) var primaryPaneID: String?
  private(set) var expandedPaneID: String?
  private(set) var isTransitioning = false
  private(set) var restoredPaneID: String?
  private(set) var focusRestoreRequest = UUID()
  @ObservationIgnored var reduceMotion = false
  @ObservationIgnored private var transitionID = UUID()
  @ObservationIgnored private let muted: Bool
  @ObservationIgnored private var sleepSuspendedPaneIDs = Set<String>()

  init(channels: [FollowedChannel], muted: Bool = false) {
    self.muted = muted
    var seen = Set<String>()
    panes = channels.filter { seen.insert($0.channelKey).inserted }
      .prefix(multiviewPaneLimit).map(MultiviewPane.init)
    primaryPaneID = panes.first?.id
    for pane in panes { configure(pane) }
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

  func toggleLayout() {
    layout = layout == .grid ? .spotlight : .grid
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
      if let expandedPaneID {
        pane.presentation.qualityTier = pane.id == expandedPaneID ? .source : .thumbnail
      } else if layout == .spotlight {
        pane.presentation.qualityTier = pane.id == primaryPane?.id ? .source : .thumbnail
      } else {
        pane.presentation.qualityTier = .grid
      }
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

  func synchronizeExpandedSleep() {
    if expandedPane?.model.isSleeping == true {
      for pane in panes where pane.id != expandedPaneID && !pane.model.isUserPaused && !pane.model.isSleeping {
        sleepSuspendedPaneIDs.insert(pane.id)
        pane.player.pause()
      }
      UIApplication.shared.isIdleTimerDisabled = false
    } else {
      for pane in panes where sleepSuspendedPaneIDs.contains(pane.id) {
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
  static func frames(ids: [String], size: CGSize, layout: MultiviewLayout,
                     primary: String?, expanded: String?) -> [String: CGRect] {
    guard !ids.isEmpty, size.width > 0, size.height > 0 else { return [:] }
    let gap: CGFloat = 16
    var frames: [String: CGRect] = [:]
    if layout == .spotlight {
      let selected = ids.first(where: { $0 == primary }) ?? ids[0]
      let others = ids.filter { $0 != selected }
      let height: CGFloat = others.isEmpty ? 0 : min(169, size.height / 4)
      frames[selected] = CGRect(x: 0, y: 0, width: size.width,
        height: size.height - (others.isEmpty ? 0 : height + gap))
      if !others.isEmpty {
        let width = min(300, (size.width - gap * CGFloat(others.count - 1)) / CGFloat(others.count))
        for (index, id) in others.enumerated() {
          frames[id] = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
        }
      }
    } else if ids.count == 1 {
      frames[ids[0]] = CGRect(origin: .zero, size: size)
    } else if ids.count == 3 {
      let width = (size.width - gap) / 2
      let height = (size.height - gap) / 2
      frames[ids[0]] = CGRect(x: 0, y: 0, width: width, height: size.height)
      for index in 1..<3 {
        frames[ids[index]] = CGRect(x: width + gap, y: CGFloat(index - 1) * (height + gap),
                                   width: width, height: height)
      }
    } else {
      let columns = ids.count > 4 ? 3 : 2
      let rows = ids.count <= 2 ? 1 : 2
      let width = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
      let height = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
      for (index, id) in ids.enumerated() {
        frames[id] = CGRect(x: CGFloat(index % columns) * (width + gap),
          y: CGFloat(index / columns) * (height + gap), width: width, height: height)
      }
    }
    if let expanded, ids.contains(expanded) { frames[expanded] = CGRect(origin: .zero, size: size) }
    return frames
  }
}

import AVKit
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class MobilePlaybackSession: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
  enum PictureInPictureState {
    case inline, starting, active, restoring, stopping
  }

  private(set) var channel: FollowedChannel?
  private(set) var model: MobilePlaybackModel
  private(set) var videoController = MobileVideoController()
  private(set) var pictureInPictureState = PictureInPictureState.inline
  var isPresented = false
  var errorMessage: String?
  let watchTracker = TwitchWatchTracker()
  @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
  @ObservationIgnored private var pendingChannel: FollowedChannel?
  @ObservationIgnored private var finishing = false
  @ObservationIgnored private var restoreCompletion: ((Bool) -> Void)?
  @ObservationIgnored private var stopAfterRestore = false
  @ObservationIgnored private var collapseAnimationFinished = false
  @ObservationIgnored private var phase = ScenePhase.active
  @ObservationIgnored private let makeModel: () -> MobilePlaybackModel
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "mobile-pip")

  init(makeModel: @escaping () -> MobilePlaybackModel = { MobilePlaybackModel() }) {
    self.makeModel = makeModel
    model = makeModel()
    super.init()
  }

  var keepsPlayingInBackground: Bool {
    pictureInPictureState == .starting || pictureInPictureState == .active
      || pictureInPictureState == .restoring
  }

  func select(_ channel: FollowedChannel) {
    guard channel.isLive else { return }
    if self.channel?.channelKey == channel.channelKey, model.isActive, !finishing {
      restore()
      return
    }
    pendingChannel = channel
    finishCurrentPlayback()
  }

  func close() {
    pendingChannel = nil
    finishCurrentPlayback()
  }

  private func finishCurrentPlayback() {
    finishing = true
    model.stop()
    watchTracker.stop()
    restoreCompletion?(false)
    restoreCompletion = nil
    stopAfterRestore = false
    switch pictureInPictureState {
    case .starting:
      // Wait for the start callback before asking AVKit to stop its transition.
      break
    case .active, .restoring:
      pictureInPictureState = .stopping
      pictureInPicture?.stopPictureInPicture()
    case .stopping:
      break
    case .inline:
      finishTransition()
    }
  }

  private func finishTransition() {
    pictureInPicture?.delegate = nil
    pictureInPicture = nil
    videoController.player = nil
    channel = nil
    pictureInPictureState = .inline
    finishing = false
    if let next = pendingChannel {
      pendingChannel = nil
      begin(next)
    } else {
      isPresented = false
    }
  }

  private func begin(_ channel: FollowedChannel) {
    self.channel = channel
    errorMessage = nil
    collapseAnimationFinished = false
    model = makeModel()
    videoController = MobileVideoController()
    videoController.player = model.player
    videoController.onReady = { [weak model] ready, player in
      model?.displayReady(ready, for: player)
    }
    videoController.onAppear = { [weak self] in self?.playerDidAppear() }
    model.onPlayerChanged = { [weak videoController] player in videoController?.player = player }
    pictureInPicture = AVPictureInPictureController(playerLayer: videoController.playerLayer)
    pictureInPicture?.delegate = self
    pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = false
    isPresented = true
    model.start(channel: channel.login)
  }

  func collapse() {
    guard channel != nil, pictureInPictureState == .inline, !finishing else { return }
    guard let pictureInPicture else {
      report(String(localized: "Picture in Picture is not supported on this device."))
      return
    }
    guard !model.isAudioOnly else {
      report(String(localized: "Picture in Picture is unavailable for audio-only playback."))
      return
    }
    guard !model.isExternalPlayback else {
      report(String(localized: "Stop AirPlay before starting Picture in Picture."))
      return
    }
    guard pictureInPicture.isPictureInPicturePossible else {
      report(String(localized: "Picture in Picture is not available yet. Wait for the video to play, then try again."))
      return
    }
    collapseAnimationFinished = false
    pictureInPictureState = .starting
    pictureInPicture.startPictureInPicture()
  }

  func collapseAnimationCompleted() {
    guard pictureInPictureState == .starting || pictureInPictureState == .active else { return }
    collapseAnimationFinished = true
    dismissCollapsedPlayerIfReady()
  }

  private func dismissCollapsedPlayerIfReady() {
    guard pictureInPictureState == .active, collapseAnimationFinished, !finishing else { return }
    // The page already slid away alongside AVKit; don't run a second modal exit.
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { isPresented = false }
  }

  private func restore() {
    guard channel != nil, !finishing else { return }
    if pictureInPictureState == .active {
      pictureInPictureState = .restoring
      stopAfterRestore = true
    }
    isPresented = true
  }

  func playerDidAppear() {
    guard pictureInPictureState == .restoring, !finishing else { return }
    let completion = restoreCompletion
    restoreCompletion = nil
    completion?(true)
    if stopAfterRestore {
      stopAfterRestore = false
      pictureInPicture?.stopPictureInPicture()
    }
  }

  func presentationDismissed() {
    if !isPresented, pictureInPictureState == .inline { close() }
  }

  func sceneChanged(_ phase: ScenePhase) {
    self.phase = phase
    if phase == .background, !keepsPlayingInBackground { model.suspend() }
    else if phase == .active { model.resume() }
  }

  func trackWatch(auth: TwitchAuthSession, rewards: TwitchWatchRewardsSession) async {
    while !Task.isCancelled, let channel {
      if auth.isAuthenticated, let userID = auth.userID, let item = model.player.currentItem {
        watchTracker.update(.init(
          target: .init(channel: channel.login, userID: userID, itemID: ObjectIdentifier(item)),
          uptime: ProcessInfo.processInfo.systemUptime, playhead: item.currentTime().seconds,
          rate: Double(model.player.rate),
          ready: item.status == .readyToPlay && !model.isLoading && model.errorMessage == nil,
          playing: model.player.timeControlStatus == .playing,
          foreground: phase == .active || pictureInPictureState == .active,
          visible: isPresented || pictureInPictureState == .active,
          userPaused: model.isPaused, muted: model.player.isMuted || model.player.volume == 0),
          session: rewards)
      } else { watchTracker.stop() }
      do { try await Task.sleep(for: .seconds(1)) } catch { break }
    }
    watchTracker.stop()
  }

  private func report(_ message: String) {
    errorMessage = message
    Self.logger.error("\(message, privacy: .public)")
  }

  func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
    guard controller === pictureInPicture else { return }
    willStartPictureInPicture()
  }

  func willStartPictureInPicture() {
    pictureInPictureState = .starting
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    guard controller === pictureInPicture else { return }
    didStartPictureInPicture()
  }

  func didStartPictureInPicture() {
    if finishing {
      pictureInPictureState = .stopping
      pictureInPicture?.stopPictureInPicture()
    } else {
      pictureInPictureState = .active
      dismissCollapsedPlayerIfReady()
    }
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
  ) {
    guard controller === pictureInPicture else { return }
    failedToStartPictureInPicture(error)
  }

  func failedToStartPictureInPicture(_ error: Error) {
    pictureInPictureState = .inline
    if finishing { finishTransition() }
    else {
      report(String(localized: "Could not start Picture in Picture. \(error.localizedDescription)"))
      if phase == .background { model.suspend() }
    }
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    guard controller === pictureInPicture else { return }
    didStopPictureInPicture()
  }

  func didStopPictureInPicture() {
    if pictureInPictureState == .restoring, !finishing {
      pictureInPictureState = .inline
      if phase == .background { model.suspend() }
    } else {
      model.stop()
      watchTracker.stop()
      finishTransition()
    }
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    guard controller === pictureInPicture else {
      completionHandler(false)
      return
    }
    restorePictureInPicture(completionHandler)
  }

  func restorePictureInPicture(_ completionHandler: @escaping (Bool) -> Void) {
    guard channel != nil, !finishing else {
      completionHandler(false)
      return
    }
    restoreCompletion = completionHandler
    pictureInPictureState = .restoring
    isPresented = true
  }
}

enum MobilePlayerCollapseGesture {
  static func shouldCollapse(translation: CGSize) -> Bool {
    translation.height >= 70 && translation.height > abs(translation.width) * 1.5
  }
}

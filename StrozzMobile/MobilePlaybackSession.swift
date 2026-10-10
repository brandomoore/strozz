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
  private(set) var isExpanded = false
  var errorMessage: String?
  let watchTracker = TwitchWatchTracker()
  @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
  @ObservationIgnored private var pendingChannel: FollowedChannel?
  @ObservationIgnored private var finishing = false
  @ObservationIgnored private var restoreCompletion: ((Bool) -> Void)?
  @ObservationIgnored private var restoreNeedsExpandedLayout = false
  @ObservationIgnored private var returnToAppWhenStarted = false
  @ObservationIgnored private var foregroundReturnTask: Task<Void, Never>?
  @ObservationIgnored private var phase = ScenePhase.active
  @ObservationIgnored private let makeModel: () -> MobilePlaybackModel
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "mobile-pip")

  init(makeModel: @escaping () -> MobilePlaybackModel = { MobilePlaybackModel() }) {
    self.makeModel = makeModel
    model = makeModel()
    super.init()
  }

  #if DEBUG
  static func layoutFixture(channel: FollowedChannel) -> MobilePlaybackSession {
    let session = MobilePlaybackSession(makeModel: { MobilePlaybackModel(muted: true) })
    session.channel = channel
    session.isExpanded = true
    session.model.activateAudioSession = {}
    session.model.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
    session.model.displayReady(true, for: session.model.player)
    session.videoController.player = session.model.player
    return session
  }
  #endif

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
    foregroundReturnTask?.cancel()
    foregroundReturnTask = nil
    finishing = true
    model.stop()
    watchTracker.stop()
    restoreCompletion?(false)
    restoreCompletion = nil
    restoreNeedsExpandedLayout = false
    returnToAppWhenStarted = false
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
      isExpanded = false
    }
  }

  private func begin(_ channel: FollowedChannel) {
    self.channel = channel
    errorMessage = nil
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
    pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = true
    isExpanded = true
    model.start(channel: channel.login)
  }

  func collapse() {
    guard channel != nil, !finishing else { return }
    isExpanded = false
  }

  func expand() {
    restore()
  }

  private func startBackgroundPictureInPicture() {
    guard channel != nil, !finishing, pictureInPictureState == .inline,
      !model.isAudioOnly, !model.isExternalPlayback, !model.isPaused,
      let pictureInPicture, pictureInPicture.isPictureInPicturePossible else {
      if model.isActive, !keepsPlayingInBackground {
        Self.logger.info("Native PiP unavailable for background playback; suspending until foreground")
        model.suspend()
      }
      return
    }
    pictureInPictureState = .starting
    pictureInPicture.startPictureInPicture()
  }

  private func restore() {
    guard channel != nil, !finishing else { return }
    isExpanded = true
    returnFromNativePictureInPicture()
  }

  private func returnFromNativePictureInPicture() {
    if pictureInPictureState == .active {
      pictureInPictureState = .restoring
      pictureInPicture?.stopPictureInPicture()
    } else if pictureInPictureState == .starting {
      returnToAppWhenStarted = true
    }
  }

  func playerDidAppear() {
    guard pictureInPictureState == .restoring, !finishing, !restoreNeedsExpandedLayout else { return }
    let completion = restoreCompletion
    restoreCompletion = nil
    completion?(true)
  }

  func playerDidLayoutExpandedSurface() {
    restoreNeedsExpandedLayout = false
    playerDidAppear()
  }

  func sceneChanged(_ phase: ScenePhase) {
    foregroundReturnTask?.cancel()
    foregroundReturnTask = nil
    self.phase = phase
    if phase == .background {
      returnToAppWhenStarted = false
      startBackgroundPictureInPicture()
    } else if phase == .active {
      model.resume()
      guard pictureInPictureState == .active || pictureInPictureState == .starting else { return }
      // App activation arrives before AVKit's cross-process restore request. Give that
      // request priority over automatically returning an ordinary app reopen to inline.
      foregroundReturnTask = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard let self, !Task.isCancelled, self.phase == .active else { return }
        self.returnFromNativePictureInPicture()
      }
    }
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
          visible: phase == .active || pictureInPictureState == .active,
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
      if returnToAppWhenStarted { returnFromNativePictureInPicture() }
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
    returnToAppWhenStarted = false
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
    foregroundReturnTask?.cancel()
    foregroundReturnTask = nil
    if pictureInPictureState == .restoring, !finishing {
      pictureInPictureState = .inline
      returnToAppWhenStarted = false
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
    foregroundReturnTask?.cancel()
    foregroundReturnTask = nil
    let returningToApp = pictureInPictureState == .restoring
    pictureInPictureState = .restoring
    restoreNeedsExpandedLayout = !returningToApp && !isExpanded
    if !returningToApp {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { isExpanded = true }
    }
    // AVKit samples the inline destination when completion runs. A mounted mini-player
    // is not ready until the expanded source's window-relative frame has committed.
    if videoController.viewIfLoaded?.window != nil { playerDidAppear() }
  }
}

enum MobilePlayerCollapseGesture {
  static func shouldCollapse(translation: CGSize) -> Bool {
    translation.height >= 70 && translation.height > abs(translation.width) * 1.5
  }
}

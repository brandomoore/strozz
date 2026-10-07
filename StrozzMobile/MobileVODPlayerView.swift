import AVKit
import OSLog
import SwiftUI

struct MobileVODPlayerView: View {
  let selection: MobileVODSelection
  @Environment(MobileVODProgressStore.self) private var progress
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var player = AVPlayer()
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var attempt = 0
  @State private var observer: Any?
  @State private var lastSaved = 0.0
  @State private var ready = false
  @State private var resumeAfterBackground = false
  @State private var itemObservation: NSKeyValueObservation?
  @State private var backgrounded = false

  var body: some View {
    NavigationStack {
      ZStack {
        VideoPlayer(player: player)
          .accessibilityIdentifier("mobile-vod-player")
        if isLoading { ProgressView("Loading broadcast").padding().background(.regularMaterial) }
        if let errorMessage {
          MobileStatusView(message: errorMessage) { attempt += 1 }
            .padding().background(.regularMaterial)
        }
      }
      .navigationTitle(selection.video.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }
    .task(id: attempt) { await load() }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .background {
        backgrounded = true
        resumeAfterBackground = isLoading || player.rate > 0
        save()
        player.pause()
      } else if phase == .active {
        backgrounded = false
        if resumeAfterBackground, ready {
          resumeAfterBackground = false
          player.play()
        }
      }
    }
    .onDisappear {
      save()
      ready = false
      player.pause()
      if let observer { player.removeTimeObserver(observer); self.observer = nil }
      itemObservation = nil
      player.currentItem?.cancelPendingSeeks()
      player.replaceCurrentItem(with: nil)
      do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
      catch { Logger(subsystem: "com.thatcube.Strozz", category: "mobile-vod").error("Could not release audio session: \(error.localizedDescription, privacy: .public)") }
    }
  }

  private func load() async {
    isLoading = true
    errorMessage = nil
    ready = false
    player.pause()
    if let observer { player.removeTimeObserver(observer); self.observer = nil }
    itemObservation = nil
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
      let url = try await PlaybackService.vodMasterURL(id: selection.video.id)
      try Task.checkCancellation()
      let item = AVPlayerItem(asset: AVURLAsset(url: url,
        options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]))
      player.replaceCurrentItem(with: item)
      itemObservation = item.observe(\.status, options: [.new]) { [weak item] _, _ in
        Task { @MainActor in
          guard let item, player.currentItem === item, item.status == .failed else { return }
          errorMessage = "This broadcast stopped responding. Try again."
          isLoading = false
          player.pause()
        }
      }
      #if targetEnvironment(simulator)
      player.isMuted = true
      #endif
      let deadline = ContinuousClock.now.advanced(by: .seconds(25))
      while item.status != .readyToPlay {
        try Task.checkCancellation()
        if item.status == .failed { throw item.error ?? URLError(.cannotDecodeContentData) }
        if ContinuousClock.now >= deadline { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(100))
      }
      let seconds = progress.progress(for: selection.id)
      if seconds > 0 {
        let timeout = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          item.cancelPendingSeeks()
        }
        let restored = await item.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                      toleranceBefore: .zero, toleranceAfter: .zero)
        timeout.cancel()
        try Task.checkCancellation()
        guard restored else { throw URLError(.cannotLoadFromNetwork) }
      }
      try Task.checkCancellation()
      ready = true
      lastSaved = player.currentTime().seconds
      observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1),
                                                queue: .main) { _ in
        MainActor.assumeIsolated {
          if abs(player.currentTime().seconds - lastSaved) >= 15 { save() }
        }
      }
      if !backgrounded { player.play() }
      else { resumeAfterBackground = true }
      isLoading = false
    } catch is CancellationError {
      player.pause()
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = "Could not play this broadcast. \(error.localizedDescription)"
      isLoading = false
    }
  }

  private func save() {
    guard ready else { return }
    let duration = player.currentItem?.duration.seconds ?? 0
    let seconds = player.currentTime().seconds
    progress.save(selection, seconds: seconds,
                  duration: duration.isFinite && duration > 0 ? duration : Double(selection.video.lengthSeconds))
    lastSaved = seconds
  }
}

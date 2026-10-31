import AVKit
import OSLog
import SwiftUI

struct ClipPlayerView: View {
  let slug: String
  let title: String
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @State private var player = AVPlayer()
  @State private var errorMessage: String?
  @State private var loading = true
  @State private var retryID = UUID()
  @State private var observation: NSKeyValueObservation?
  #if os(iOS)
  @Environment(MobilePlaybackSession.self) private var livePlayback
  @Environment(\.scenePhase) private var scenePhase
  @State private var backgrounded = false
  @State private var resumeAfterBackground = false
  #endif

  var body: some View {
    ZStack {
      LinearGradient(colors: palette.backgroundColors, startPoint: .top, endPoint: .bottom).ignoresSafeArea()
      if let errorMessage {
        VStack(spacing: 20) {
          Text(errorMessage).font(.title2)
          Button("Retry") { retryID = UUID() }
          Button("Back") { dismiss() }
        }.padding(40)
      } else if loading {
        StreamLoadingView(title: title)
      } else {
        VideoPlayer(player: player).ignoresSafeArea()
      }
    }
    #if os(tvOS)
    .onExitCommand { dismiss() }
    #else
    .overlay(alignment: .topTrailing) {
      Button("Done") { dismiss() }.buttonStyle(.borderedProminent).padding()
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .background {
        backgrounded = true
        resumeAfterBackground = loading || player.rate > 0
        player.pause()
      } else if phase == .active {
        backgrounded = false
        if resumeAfterBackground, !loading, errorMessage == nil {
          resumeAfterBackground = false
          player.play()
        }
      }
    }
    #endif
    .task(id: retryID) { await start() }
    .onDisappear {
      observation = nil
      player.pause()
      player.replaceCurrentItem(with: nil)
      #if os(iOS)
      do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
      catch {
        Logger(subsystem: "com.thatcube.Strozz", category: "clip")
          .error("Could not release clip audio session: \(error.localizedDescription)")
      }
      #endif
    }
  }

  private func start() async {
    loading = true
    errorMessage = nil
    player.pause()
    observation = nil
    do {
      #if os(iOS)
      livePlayback.close()
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
      #endif
      let url = try await (slug.hasPrefix("kick:")
        ? KickChannelContentService.clipURL(id: slug) : PlaybackService.clipSourceURL(slug: slug))
      try Task.checkCancellation()
      let item = AVPlayerItem(url: url)
      player.replaceCurrentItem(with: item)
      observation = item.observe(\.status, options: [.new]) { [weak item] _, _ in
        Task { @MainActor in
          guard let item, player.currentItem === item, item.status == .failed else { return }
          player.pause()
          errorMessage = String(localized: "This clip stopped responding. Try again.")
        }
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(25))
      while item.status != .readyToPlay {
        try Task.checkCancellation()
        if item.status == .failed { throw item.error ?? URLError(.cannotDecodeContentData) }
        if ContinuousClock.now >= deadline { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(100))
      }
      try Task.checkCancellation()
      #if targetEnvironment(simulator)
      player.isMuted = true
      #endif
      #if os(iOS)
      if !backgrounded { player.play() }
      else { resumeAfterBackground = true }
      #else
      player.play()
      #endif
      loading = false
    } catch {
      if !Task.isCancelled {
        errorMessage = String(localized: "Could not play this clip. \(error.localizedDescription)")
        loading = false
      }
    }
  }
}

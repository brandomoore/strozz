import AVFoundation
import Observation
import OSLog
import SwiftUI

enum MobilePreviewSelection {
  static func channel(frames: [String: CGRect], viewport: CGRect) -> String? {
    guard viewport.width > 0, viewport.height > 0 else { return nil }
    return frames.filter { _, frame in
      let visible = frame.intersection(viewport)
      return frame.width > 0 && frame.height > 0 && !visible.isNull
        && visible.width * visible.height >= frame.width * frame.height * 0.6
    }.min { lhs, rhs in
      let left = abs(lhs.value.midY - viewport.midY).rounded()
      let right = abs(rhs.value.midY - viewport.midY).rounded()
      if left != right { return left < right }
      if lhs.value.minX != rhs.value.minX { return lhs.value.minX < rhs.value.minX }
      return lhs.key < rhs.key
    }?.key
  }
}

@MainActor
@Observable
final class MobileHomePreview {
  private(set) var player = AVPlayer()
  private(set) var channel: String?
  private(set) var isReady = false
  @ObservationIgnored private var frames: [String: CGRect] = [:]
  @ObservationIgnored private var viewport = CGRect.zero
  @ObservationIgnored private var enabled = false
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private let resolve: (String) async throws -> URL
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "home-preview")

  init(resolve: @escaping (String) async throws -> URL = { try await PlaybackService.previewHLSURL(for: $0) }) {
    self.resolve = resolve
    player.isMuted = true
    player.allowsExternalPlayback = false
  }

  func updateFrame(_ frame: CGRect?, for channel: String) {
    frames[channel] = frame
    updateSelection()
  }

  func updateViewport(_ frame: CGRect) {
    viewport = frame
    updateSelection()
  }

  func setEnabled(_ enabled: Bool) {
    self.enabled = enabled
    updateSelection()
  }

  func stop() {
    enabled = false
    updateSelection()
  }

  private func updateSelection() {
    let next = enabled ? MobilePreviewSelection.channel(frames: frames, viewport: viewport) : nil
    guard next != channel else { return }
    generation = UUID()
    let request = generation
    task?.cancel()
    player.pause()
    player.replaceCurrentItem(with: nil)
    isReady = false
    channel = next
    guard let next else { task = nil; return }
    task = Task { [weak self] in
      do {
        // Avoid resolving every card passed during a fast flick.
        try await Task.sleep(for: .milliseconds(350))
        guard let self else { return }
        for attempt in 0..<2 {
          do {
            let url = attempt == 0 ? try await resolve(next)
              : try await PlaybackService.pinnedHLSURL(for: next, targetBitrate: 0, forceRefresh: true)
            guard isCurrent(request) else { return }
            try await play(url, request: request)
            return
          } catch {
            guard isCurrent(request) else { return }
            player.pause()
            player.replaceCurrentItem(with: nil)
            isReady = false
            if attempt == 1 { throw error }
            Self.logger.warning("Retrying muted preview with Source after \(error.localizedDescription, privacy: .public)")
          }
        }
      } catch {
        guard let self, isCurrent(request) else { return }
        Self.logger.warning("Muted preview unavailable for \(next, privacy: .public): \(error.localizedDescription, privacy: .public)")
        player.pause()
        player.replaceCurrentItem(with: nil)
        isReady = false
      }
    }
  }

  private func play(_ url: URL, request: UUID) async throws {
    let item = AVPlayerItem(asset: AVURLAsset(
      url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]))
    item.preferredForwardBufferDuration = 0.8
    if player.status == .failed { player = AVPlayer() }
    player.isMuted = true
    player.allowsExternalPlayback = false
    player.replaceCurrentItem(with: item)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(output)
    player.play()
    var lastFrame = ContinuousClock.now
    while isCurrent(request) {
      try await Task.sleep(for: .milliseconds(250))
      guard isCurrent(request) else { return }
      if item.status == .failed || player.status == .failed {
        throw item.error ?? player.error ?? URLError(.cannotDecodeContentData)
      }
      if output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil {
        isReady = true
        lastFrame = .now
      }
      if lastFrame.duration(to: .now) > .seconds(8) { throw URLError(.timedOut) }
    }
  }

  private func isCurrent(_ request: UUID) -> Bool {
    enabled && generation == request && !Task.isCancelled
  }
}

/// A controls-free surface keeps the card's tap dedicated to opening the stream.
struct MobilePreviewSurface: UIViewRepresentable {
  let player: AVPlayer

  func makeUIView(context: Context) -> MobilePreviewHost {
    let view = MobilePreviewHost()
    view.isUserInteractionEnabled = false
    view.videoLayer.videoGravity = .resizeAspectFill
    view.layer.cornerRadius = 12
    view.layer.masksToBounds = true
    view.videoLayer.player = player
    return view
  }

  func updateUIView(_ view: MobilePreviewHost, context: Context) {
    view.videoLayer.player = player
  }

  static func dismantleUIView(_ view: MobilePreviewHost, coordinator: ()) {
    view.videoLayer.player = nil
  }
}

final class MobilePreviewHost: UIView {
  let videoLayer = AVPlayerLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.addSublayer(videoLayer)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    videoLayer.frame = bounds
    CATransaction.commit()
  }
}

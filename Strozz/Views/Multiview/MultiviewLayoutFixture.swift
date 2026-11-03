#if DEBUG && targetEnvironment(simulator)
import AVKit
import SwiftUI

/// Mounts the production wall and controls with local decoded pictures.
struct MultiviewLayoutFixture: View {
  @MainActor
  @Observable
  final class Model {
    let channels: [FollowedChannel]
    let controller: MultiviewController
    let lineup: MultiviewLineup?
    var ready = false
    var failure = ""
    private var directory: URL?

    init(settings: [String: String] = ProcessInfo.processInfo.environment, existingLineup: MultiviewLineup? = nil) {
      if let existingLineup, let existingController = existingLineup.controller {
        lineup = existingLineup
        controller = existingController
        channels = existingController.panes.map(\.channel)
        return
      }
      let count = min(6, max(1, Int(settings["STROZZ_LAYOUT_COUNT"] ?? "6") ?? 6))
      channels = (0..<7).map {
        FollowedChannel(id: "layout-\($0)", login: "layoutfixture\($0)",
          displayName: "Fixture stream \($0 + 1)",
          title: "Local picture • aspect ratio and outside-edge reference",
          gameName: "", viewerCount: 123, thumbnailURL: nil, profileImageURL: nil, isLive: true)
      }
      if settings["STROZZ_LAYOUT_LINEUP"] == "1", count > 1 {
        let lineup = MultiviewLineup { _ in .live }
        for channel in channels.prefix(count) { lineup.toggle(channel) }
        lineup.startPlayback()
        self.lineup = lineup
        controller = lineup.controller!
      } else {
        lineup = nil
        controller = MultiviewController(channels: Array(channels.prefix(count)))
      }
      controller.setLayout(MultiviewLayout(rawValue: settings["STROZZ_LAYOUT_MODE"] ?? "") ?? .featured)
    }

    func prepare() async {
      do {
        let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true).appendingPathComponent("MultiviewLayoutFixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root
        let wide = try await Self.video(at: root.appendingPathComponent("wide.mp4"), width: 640, height: 360)
        let square = try await Self.video(at: root.appendingPathComponent("classic.mp4"), width: 640, height: 480)
        for (index, pane) in controller.panes.enumerated() {
          // The existing alternate-item load guard retains this local AVPlayerItem.
          // No substitute PlayerView, stage, controls, or focus implementation is used.
          pane.model.isUsingAltSource = true
          pane.model.isLoading = false
          pane.player.replaceCurrentItem(with: AVPlayerItem(url: index.isMultiple(of: 2) ? wide : square))
          pane.presentation.updateVideoAspectRatio(CGSize(width: 640, height: index.isMultiple(of: 2) ? 360 : 480))
          pane.player.play()
        }
        ready = true
      } catch { failure = String(describing: error) }
    }

    func stop() {
      controller.teardown()
      if let directory { try? FileManager.default.removeItem(at: directory) }
      directory = nil
    }

    func runRemovalProbe() async {
      guard ProcessInfo.processInfo.environment["STROZZ_LAYOUT_AUTO_REMOVE"] == "1" else { return }
      do {
        try await Task.sleep(for: .seconds(6))
        guard ready, let pane = controller.panes.last else { return }
        if let lineup { lineup.remove(pane.channel.channelKey) }
        else { controller.removePane(pane.id) }
      } catch is CancellationError {
        return
      } catch {
        failure = String(describing: error)
      }
    }

    private static func video(at url: URL, width: Int, height: Int) async throws -> URL {
      let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
      ])
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
      writer.add(input)
      guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
      writer.startSession(atSourceTime: .zero)
      var buffer: CVPixelBuffer?
      guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
        [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
          as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
        throw CocoaError(.coderInvalidValue)
      }
      CVPixelBufferLockBaseAddress(buffer, [])
      guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
        CVPixelBufferUnlockBaseAddress(buffer, [])
        throw CocoaError(.coderInvalidValue)
      }
      context.setFillColor((height == 360 ? UIColor.systemTeal : UIColor.systemOrange).cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.setStrokeColor(UIColor.white.cgColor)
      context.setLineWidth(4)
      context.stroke(CGRect(x: 12, y: 12, width: width - 24, height: height - 24))
      context.strokeEllipse(in: CGRect(x: width / 2 - 70, y: height / 2 - 70, width: 140, height: 140))
      CVPixelBufferUnlockBaseAddress(buffer, [])
      for frame in 0..<120 {
        while !input.isReadyForMoreMediaData {
          try Task.checkCancellation()
          if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
          try await Task.sleep(for: .milliseconds(10))
        }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)) else {
          throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
      }
      input.markAsFinished()
      await writer.finishWriting()
      guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
      return url
    }
  }

  @State private var model: Model
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.colorScheme) private var scheme
  @Environment(\.glassDisabled) private var inheritedGlassDisabled

  init(lineup: MultiviewLineup? = nil) {
    _model = State(initialValue: Model(existingLineup: lineup))
  }

  var body: some View {
    let settings = ProcessInfo.processInfo.environment
    let theme = AppTheme(rawValue: settings["STROZZ_LAYOUT_THEME"] ?? "dark") ?? .dark
    let palette = theme.palette(systemColorScheme: scheme)
    GeometryReader { geometry in
      let width = CGFloat(Double(settings["STROZZ_LAYOUT_WIDTH"] ?? "") ?? geometry.size.width)
      let height = CGFloat(Double(settings["STROZZ_LAYOUT_HEIGHT"] ?? "") ?? geometry.size.height)
      let scale = min(1, min(geometry.size.width / width, geometry.size.height / height))
      ZStack {
        if model.ready {
          MultiviewPlayerView(channels: Array(model.channels.prefix(model.controller.panes.count)),
            availableChannels: model.channels, auth: environment.auth, goLive: nil,
            onWatch: { _ in }, controller: model.controller)
            .opacity(model.controller.isBrowsing ? 0 : 1)
            .disabled(model.controller.isBrowsing)
            .accessibilityHidden(model.controller.isBrowsing)
          if model.controller.isBrowsing {
            Button("Return to multiview") { model.lineup?.startPlayback() }
              .accessibilityIdentifier("layout-fixture-return")
          }
          MultiviewLayoutDiagnostics(controller: model.controller, logicalSize: CGSize(width: width, height: height))
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        } else {
          Text(model.failure.isEmpty ? "Preparing local video" : model.failure)
            .accessibilityIdentifier("layout-fixture-loading")
        }
      }
      .frame(width: width, height: height)
      .clipped()
      .scaleEffect(scale)
      .frame(width: geometry.size.width, height: geometry.size.height)
      .environment(\.themePalette, palette)
      .environment(\.glassDisabled, inheritedGlassDisabled || settings["STROZZ_LAYOUT_OPAQUE"] == "1")
      .environment(\.multiviewLineup, model.lineup)
    }
    .ignoresSafeArea()
    .preferredColorScheme(theme.preferredColorScheme)
    .task { await model.prepare(); await model.runRemovalProbe() }
    .onDisappear { model.stop() }
  }
}

private struct MultiviewLayoutDiagnostics: UIViewRepresentable {
  let controller: MultiviewController
  let logicalSize: CGSize

  func makeUIView(context: Context) -> UILabel {
    let label = UILabel()
    label.isAccessibilityElement = true
    label.accessibilityIdentifier = "layout-fixture-state"
    label.accessibilityLabel = "Layout fixture diagnostics"
    context.coordinator.label = label
    context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak coordinator = context.coordinator] _ in
      MainActor.assumeIsolated { coordinator?.update() }
    }
    return label
  }

  func updateUIView(_ view: UILabel, context: Context) {
    context.coordinator.update()
  }

  func makeCoordinator() -> Coordinator { Coordinator(controller: controller, logicalSize: logicalSize) }

  static func dismantleUIView(_ uiView: UILabel, coordinator: Coordinator) { coordinator.timer?.invalidate() }

  @MainActor
  final class Coordinator {
    let controller: MultiviewController
    let logicalSize: CGSize
    weak var label: UILabel?
    var timer: Timer?
    private var removalSamples: [[String: Any]] = []

    init(controller: MultiviewController, logicalSize: CGSize) {
      self.controller = controller
      self.logicalSize = logicalSize
    }

    private func players(_ root: UIViewController) -> [AVPlayerViewController] {
      (root as? AVPlayerViewController).map { [$0] } ?? root.children.flatMap(players)
    }

    private func layers(_ root: CALayer) -> [AVPlayerLayer] {
      (root as? AVPlayerLayer).map { [$0] } ?? (root.sublayers ?? []).flatMap(layers)
    }

    func update() {
      guard let label, let window = label.window, let root = window.rootViewController else { return }
      let surfaces = players(root)
      func identity(_ value: AnyObject?) -> String { value.map { String(describing: ObjectIdentifier($0)) } ?? "nil" }
      func rect(_ value: CGRect) -> [Double] { [value.minX, value.minY, value.width, value.height].map(Double.init) }
      let panes: [[String: Any]] = controller.panes.map { pane in
        let surface = surfaces.first { $0.player === pane.player }
        let layer = surface.flatMap { layers($0.view.layer).first { $0.player === pane.player } }
        let picture = layer.map { $0.convert($0.videoRect, to: window.layer) } ?? .zero
        return ["id": pane.id, "model": identity(pane.model), "player": identity(pane.player),
          "item": identity(pane.player.currentItem), "surface": identity(surface),
          "ready": surface?.isReadyForDisplay ?? false, "muted": pane.player.isMuted,
          "rate": pane.player.rate, "playPauseRequests": pane.presentation.playPauseRequests,
          "picture": rect(picture), "aspect": pane.presentation.videoAspectRatio,
          "error": pane.model.errorMessage ?? "", "loading": pane.isLoading]
      }
      let state: [String: Any] = [
        "layout": controller.layout.rawValue, "primary": controller.primaryPaneID ?? "",
        "audio": controller.audiblePaneID ?? "", "expanded": controller.expandedPaneID ?? "",
        "browsing": controller.isBrowsing, "panes": panes,
        "logicalViewport": [logicalSize.width, logicalSize.height],
        "windowPoints": rect(window.bounds), "screenScale": window.screen.scale,
        "screenPixels": rect(window.screen.nativeBounds),
        "reduceMotion": UIAccessibility.isReduceMotionEnabled,
        "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) { label.accessibilityValue = text }
      if ProcessInfo.processInfo.environment["STROZZ_LAYOUT_AUTO_REMOVE"] == "1", removalSamples.count < 40 {
        removalSamples.append(["time": CACurrentMediaTime(), "state": state])
        do {
          let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
          try JSONSerialization.data(withJSONObject: removalSamples, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("multiview-removal-probe.json"), options: .atomic)
        } catch {
          NSLog("Cannot write multiview removal probe: %@", error.localizedDescription)
        }
      }
    }
  }
}
#endif

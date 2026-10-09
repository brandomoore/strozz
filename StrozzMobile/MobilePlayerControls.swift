import AVKit
import SwiftUI

struct MobilePlayerControls: View {
  let model: MobilePlaybackModel
  let viewerCount: Int?
  @Binding var hideChat: Bool
  let isFullscreen: Bool
  let onCollapse: () -> Void
  let onClose: () -> Void
  let onFullscreen: () -> Void
  let onQuality: () -> Void
  let onShare: () -> Void
  let onInteraction: () -> Void
  let onRoutes: (Bool) -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    ZStack {
      VStack {
        HStack(spacing: 8) {
          Button(action: onCollapse) {
            Icon(glyph: .chevronRight, size: 22).rotationEffect(.degrees(90)).frame(width: 44, height: 44)
          }
            .accessibilityLabel("Minimize player")
            .accessibilityIdentifier("mobile-minimize-player")
            .modifier(MobileControlSurface(isVideoOverlay: true))
          Spacer(minLength: 0)
          if model.presentationState == .ready {
            MobileAirPlayPicker(onPresentation: onRoutes)
              .frame(width: 44, height: 44)
              .modifier(MobileControlSurface(isVideoOverlay: true))
            Button(action: onShare) { Icon(glyph: .share, size: 22).frame(width: 44, height: 44) }
              .accessibilityLabel("Share stream")
              .modifier(MobileControlSurface(isVideoOverlay: true))
            Button(action: onQuality) { Icon(glyph: .settings, size: 22).frame(width: 44, height: 44) }
              .accessibilityLabel("Playback quality")
              .accessibilityValue(model.qualityLabel)
              .modifier(MobileControlSurface(isVideoOverlay: true))
          }
          Button(action: onClose) { Icon(glyph: .x, size: 22).frame(width: 44, height: 44) }
            .accessibilityLabel("Close player")
            .modifier(MobileControlSurface(isVideoOverlay: true))
        }
        Spacer(minLength: 12)
        if model.presentationState == .ready {
          HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              livePositionControl
              if let viewerCount {
                MobileViewerBadge(count: viewerCount, isVideoOverlay: true)
              }
            }
            Spacer(minLength: 0)
            Button {
              onInteraction()
              model.toggleMute()
            } label: {
              Icon(glyph: model.isMuted ? .volumeOff : .volume, size: 22).frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")
            .accessibilityIdentifier("mobile-mute")
            .modifier(MobileControlSurface(isVideoOverlay: true))
            Button {
              onInteraction()
              hideChat.toggle()
            } label: {
              Icon(glyph: hideChat ? .sidebarRightExpand : .sidebarRightCollapse, size: 22).frame(width: 44, height: 44)
            }
            .accessibilityLabel(hideChat ? "Show chat" : "Hide chat")
            .modifier(MobileControlSurface(isVideoOverlay: true))
            Button(action: onFullscreen) {
              Icon(glyph: isFullscreen ? .dimensions : .arrowsMaximize, size: 22).frame(width: 44, height: 44)
            }
            .accessibilityLabel(isFullscreen ? "Exit fullscreen" : "Fullscreen")
            .modifier(MobileControlSurface(isVideoOverlay: true))
          }
        }
      }
      if model.presentationState == .ready {
        Button {
          onInteraction()
          model.togglePlayPause()
        } label: {
          Icon(glyph: model.isPaused ? .playerPlayFilled : .playerPauseFilled, size: 30)
            .frame(width: 56, height: 56)
        }
        .accessibilityLabel(model.isPaused ? "Play" : "Pause")
        .accessibilityIdentifier("mobile-play-pause")
        .disabled(model.isLoading || model.errorMessage != nil)
        .modifier(MobileControlSurface(isVideoOverlay: true))
      }
    }
    .buttonStyle(.plain)
    .padding(10)
    .background {
      MobilePlayerControlScrim(hasBottomControls: model.presentationState == .ready,
                               reduceTransparency: reduceTransparency)
    }
  }

  @ViewBuilder
  private var livePositionControl: some View {
    switch model.liveStatus {
    case .live:
      Label { Text("Live").font(.caption.bold()) } icon: { Icon(glyph: .broadcast, size: 16) }
        .frame(minHeight: 44).padding(.horizontal, 8)
        .modifier(MobileControlSurface(isVideoOverlay: true))
        .accessibilityLabel("At the live edge")
        .accessibilityIdentifier("mobile-live-status")
    case .checking:
      Text("Checking live").font(.caption)
        .frame(minHeight: 44).padding(.horizontal, 8)
        .modifier(MobileControlSurface(isVideoOverlay: true))
        .accessibilityIdentifier("mobile-live-checking")
    case .paused, .behind:
      VStack(alignment: .leading, spacing: 2) {
        if case .behind(let seconds) = model.liveStatus {
          Text("\(seconds, format: .number.precision(.fractionLength(0)))s behind")
            .font(.caption)
            .accessibilityIdentifier("mobile-live-delay")
        } else {
          Text("Paused").font(.caption)
            .accessibilityIdentifier("mobile-live-paused")
        }
        Button {
          onInteraction()
          model.goLive()
        } label: {
          Label { Text("Back to live").font(.caption.bold()) } icon: {
            Icon(glyph: .broadcast, size: 16)
          }
          .frame(minHeight: 44).padding(.horizontal, 8)
        }
        .accessibilityIdentifier("mobile-go-live")
      }
      .modifier(MobileControlSurface(isVideoOverlay: true))
    }
  }
}

struct MobileControlSurface: ViewModifier {
  var isVideoOverlay = false
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content
      .foregroundStyle(isVideoOverlay ? palette.videoControlForeground : palette.chromeOnOpaque)
      .contentShape(RoundedRectangle(cornerRadius: 12))
      .background(
        palette.chromeOpaqueSurface.opacity(isVideoOverlay ? 0 : reduceTransparency ? 1 : 0.88),
        in: RoundedRectangle(cornerRadius: 12))
  }
}

struct MobilePlayerControlScrim: View {
  let hasBottomControls: Bool
  let reduceTransparency: Bool
  @Environment(\.themePalette) private var palette

  var body: some View {
    let strength = reduceTransparency ? 1.25 : 1.0
    LinearGradient(stops: [
      .init(color: palette.videoControlScrim.opacity(0.60 * strength), location: 0),
      .init(color: palette.videoControlScrim.opacity(0.54 * strength), location: 0.45),
      .init(color: palette.videoControlScrim.opacity(0.54 * strength), location: 0.55),
      .init(color: palette.videoControlScrim.opacity((hasBottomControls ? 0.64 : 0.50) * strength), location: 1),
    ], startPoint: .top, endPoint: .bottom)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct MobileMiniPlayerControlScrim: View {
  let hasError: Bool
  let reduceTransparency: Bool
  @Environment(\.themePalette) private var palette

  var body: some View {
    let strength = reduceTransparency ? 1.25 : 1.0
    let stops: [Gradient.Stop] = [
      .init(color: palette.videoControlScrim.opacity(0.64 * strength), location: 0),
      .init(color: palette.videoControlScrim.opacity(0), location: 1),
    ]
    GeometryReader { geometry in
      let inset: CGFloat = 28
      let x = inset / max(1, geometry.size.width)
      let y = inset / max(1, geometry.size.height)
      let radius = min(52, max(0, geometry.size.width / 2 - inset))
      ZStack {
        RadialGradient(stops: stops, center: .init(x: x, y: y), startRadius: 0, endRadius: radius)
        RadialGradient(stops: stops, center: .init(x: 1 - x, y: y), startRadius: 0, endRadius: radius)
        if hasError {
          LinearGradient(stops: [
            .init(color: palette.videoControlScrim.opacity(0.64 * strength), location: 0),
            .init(color: palette.videoControlScrim.opacity(0.58 * strength), location: 0.6),
            .init(color: palette.videoControlScrim.opacity(0), location: 1),
          ], startPoint: .bottom, endPoint: .top)
          .frame(height: min(72, geometry.size.height))
          .frame(maxHeight: .infinity, alignment: .bottom)
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct MobileQualitySheet: View {
  let model: MobilePlaybackModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if model.nativeFailure == nil && !model.isExternalPlayback {
          qualityRow("Auto - Native Low Latency", quality: .native)
        }
        qualityRow("Auto - Standard", quality: .automatic)
        ForEach(model.qualities) { quality in
          qualityRow(quality.name, quality: .fixed(quality.id))
        }
        if let reason = model.nativeFailure {
          Text(reason).font(.footnote).foregroundStyle(.secondary)
        }
        Text("AirPlay uses standard playback. Keep Strozz open while using AirPlay.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .disabled(model.isLoading)
      .navigationTitle("Playback quality")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }

  private func qualityRow(_ title: String, quality: MobileQuality) -> some View {
    Button {
      model.select(quality)
      dismiss()
    } label: {
      HStack {
        Text(title)
        Spacer()
        if model.selection == quality { Icon(glyph: .check, size: 20) }
      }
    }
    .accessibilityAddTraits(model.selection == quality ? .isSelected : [])
  }
}

struct MobileAirPlayPicker: UIViewRepresentable {
  let onPresentation: (Bool) -> Void
  @Environment(\.themePalette) private var palette

  func makeCoordinator() -> Coordinator { Coordinator(onPresentation: onPresentation) }

  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.prioritizesVideoDevices = true
    view.delegate = context.coordinator
    view.accessibilityLabel = "AirPlay"
    view.tintColor = UIColor(palette.videoControlForeground)
    view.activeTintColor = UIColor(palette.videoControlForeground)
    return view
  }

  func updateUIView(_ view: AVRoutePickerView, context: Context) {
    view.tintColor = UIColor(palette.videoControlForeground)
    view.activeTintColor = UIColor(palette.videoControlForeground)
    context.coordinator.onPresentation = onPresentation
  }

  final class Coordinator: NSObject, AVRoutePickerViewDelegate {
    var onPresentation: (Bool) -> Void
    init(onPresentation: @escaping (Bool) -> Void) { self.onPresentation = onPresentation }
    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { onPresentation(true) }
    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { onPresentation(false) }
  }
}

struct MobileShareSheet: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

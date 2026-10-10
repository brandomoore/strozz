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
  var showsChatToggle = false
  var landscapeChannel: FollowedChannel? = nil
  var onModePresentation: (Bool) -> Void = { _ in }
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @AppStorage(PersistenceKey.showStreamDuration) private var showStreamDuration = true

  var body: some View {
    ZStack {
      VStack(spacing: landscapeChannel == nil ? 8 : 4) {
        HStack(spacing: 4) {
          Button(action: onCollapse) {
            Icon(glyph: .chevronRight, size: 22).rotationEffect(.degrees(90)).frame(width: 44, height: 44)
          }
            .accessibilityLabel("Minimize player")
            .accessibilityIdentifier("mobile-minimize-player")
            .modifier(MobileControlSurface(isVideoOverlay: true))
          Spacer(minLength: 0)
          MobilePlaybackModeButton(model: model, onVideoSelection: { hideChat = false },
            onPresentation: onModePresentation)
            .modifier(MobileControlSurface(isVideoOverlay: true))
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
        Color.clear
          .frame(minHeight: 56, maxHeight: .infinity)
          .overlay {
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
        if model.presentationState == .ready {
          HStack(spacing: 8) {
            MobileStreamReadouts(state: model.liveStatus, startedAt: model.streamStartedAt,
              viewerCount: viewerCount, showDuration: showStreamDuration) {
                onInteraction()
                model.goLive()
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
            if showsChatToggle {
              Button {
                onInteraction()
                hideChat.toggle()
              } label: {
                Icon(glyph: hideChat ? .sidebarRightExpand : .sidebarRightCollapse, size: 22).frame(
                  width: 44, height: 44)
              }
              .accessibilityLabel(hideChat ? "Show chat" : "Hide chat")
              .accessibilityIdentifier("mobile-toggle-chat")
              .modifier(MobileControlSurface(isVideoOverlay: true))
            }
            Button(action: onFullscreen) {
              Icon(
                glyph: UIDevice.current.userInterfaceIdiom == .phone
                  ? .rotateRectangle
                  : isFullscreen ? .dimensions : .arrowsMaximize, size: 22
              ).frame(width: 44, height: 44)
            }
            .accessibilityLabel(
              UIDevice.current.userInterfaceIdiom == .phone
                ? (isFullscreen ? "Rotate to portrait" : "Rotate to landscape")
                : (isFullscreen ? "Exit fullscreen" : "Fullscreen")
            )
            .accessibilityIdentifier("mobile-rotate-player")
            .modifier(MobileControlSurface(isVideoOverlay: true))
          }
          if let landscapeChannel {
            MobileStreamDetails(channel: landscapeChannel, model: model, isVideoOverlay: true)
              .allowsHitTesting(false)
          }
        }
      }
    }
    .buttonStyle(.plain)
    .padding(landscapeChannel == nil ? 10 : 6)
    .background {
      MobilePlayerControlScrim(hasBottomControls: model.presentationState == .ready,
                               reduceTransparency: reduceTransparency)
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
    GeometryReader { geometry in
      ZStack {
        LinearGradient(stops: [
          .init(color: palette.videoControlScrim.opacity(0.66 * strength), location: 0),
          .init(color: palette.videoControlScrim.opacity(0.60 * strength), location: 0.25),
          .init(color: palette.videoControlScrim.opacity(0.40 * strength), location: 0.55),
          .init(color: palette.videoControlScrim.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .frame(height: min(geometry.size.height, max(96, geometry.size.height * 0.5)))
        .frame(maxHeight: .infinity, alignment: .top)
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
          qualityRow(quality.name, quality: quality.isAudioOnly ? .audioOnly : .fixed(quality.id))
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

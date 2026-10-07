import AVKit
import SwiftUI

struct MobilePlayerControls: View {
  let model: MobilePlaybackModel
  let viewerCount: Int?
  @Binding var hideChat: Bool
  let isFullscreen: Bool
  let onClose: () -> Void
  let onFullscreen: () -> Void
  let onQuality: () -> Void
  let onShare: () -> Void
  let onInteraction: () -> Void
  let onRoutes: (Bool) -> Void

  var body: some View {
    ZStack {
      VStack {
        HStack(spacing: 8) {
          Button(action: onClose) { Icon(glyph: .x, size: 22).frame(width: 44, height: 44) }
            .accessibilityLabel("Close player")
            .modifier(MobileControlSurface())
          Spacer(minLength: 0)
          if model.presentationState == .ready {
            MobileAirPlayPicker(onPresentation: onRoutes)
              .frame(width: 44, height: 44)
              .modifier(MobileControlSurface())
            Button(action: onShare) { Icon(glyph: .share, size: 22).frame(width: 44, height: 44) }
              .accessibilityLabel("Share stream")
              .modifier(MobileControlSurface())
            Button(action: onQuality) { Icon(glyph: .settings, size: 22).frame(width: 44, height: 44) }
              .accessibilityLabel("Playback quality")
              .accessibilityValue(model.qualityLabel)
              .modifier(MobileControlSurface())
          }
        }
        Spacer(minLength: 12)
        if model.presentationState == .ready {
          HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              livePositionControl
              if let viewerCount {
                MobileViewerBadge(count: viewerCount)
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
            .modifier(MobileControlSurface())
            Button {
              onInteraction()
              hideChat.toggle()
            } label: {
              Icon(glyph: hideChat ? .sidebarRightExpand : .sidebarRightCollapse, size: 22).frame(width: 44, height: 44)
            }
            .accessibilityLabel(hideChat ? "Show chat" : "Hide chat")
            .modifier(MobileControlSurface())
            Button(action: onFullscreen) {
              Icon(glyph: isFullscreen ? .dimensions : .arrowsMaximize, size: 22).frame(width: 44, height: 44)
            }
            .accessibilityLabel(isFullscreen ? "Exit fullscreen" : "Fullscreen")
            .modifier(MobileControlSurface())
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
        .modifier(MobileControlSurface())
      }
    }
    .buttonStyle(.plain)
    .padding(10)
  }

  @ViewBuilder
  private var livePositionControl: some View {
    switch model.liveStatus {
    case .live:
      Label { Text("Live").font(.caption.bold()) } icon: { Icon(glyph: .broadcast, size: 16) }
        .frame(minHeight: 44).padding(.horizontal, 8)
        .modifier(MobileControlSurface())
        .accessibilityLabel("At the live edge")
        .accessibilityIdentifier("mobile-live-status")
    case .checking:
      Text("Checking live").font(.caption)
        .frame(minHeight: 44).padding(.horizontal, 8)
        .modifier(MobileControlSurface())
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
      .modifier(MobileControlSurface())
    }
  }
}

struct MobileControlSurface: ViewModifier {
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content
      .foregroundStyle(palette.chromeOnOpaque)
      .contentShape(RoundedRectangle(cornerRadius: 12))
      .background(
        palette.chromeOpaqueSurface.opacity(reduceTransparency ? 1 : 0.88),
        in: RoundedRectangle(cornerRadius: 12))
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
    view.tintColor = UIColor(palette.chromeOnOpaque)
    return view
  }

  func updateUIView(_ view: AVRoutePickerView, context: Context) {
    view.tintColor = UIColor(palette.chromeOnOpaque)
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

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
  var onVolumeInteraction: (Bool) -> Void = { _ in }
  var showsScrim = true
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @AppStorage(PersistenceKey.showStreamDuration) private var showStreamDuration = true

  var body: some View {
    MobilePlayerGlassContainer {
      VStack(spacing: landscapeChannel == nil ? 8 : 4) {
        HStack(spacing: 4) {
          Button(action: onCollapse) {
            Icon(glyph: .chevronRight, size: 22).rotationEffect(.degrees(90)).frame(width: 44, height: 44)
          }
            .accessibilityLabel("Minimize player")
            .accessibilityIdentifier("mobile-minimize-player")
            .modifier(MobilePlayerButtonSurface())
          Spacer(minLength: 0)
          HStack(spacing: 4) {
            MobilePlaybackModeButton(model: model, onVideoSelection: { hideChat = false },
              onPresentation: onModePresentation)
            if model.presentationState == .ready {
              MobileAirPlayPicker(onPresentation: onRoutes)
                .frame(width: 44, height: 44)
              Button(action: onShare) {
                Icon(glyph: .share, size: 22).frame(width: 44, height: 44).contentShape(Rectangle())
              }
              .accessibilityLabel("Share stream")
              Button(action: onQuality) {
                Icon(glyph: .settings, size: 22).frame(width: 44, height: 44).contentShape(Rectangle())
              }
              .accessibilityLabel("Playback quality")
              .accessibilityValue(model.qualityLabel)
            }
            Button(action: onClose) {
              Icon(glyph: .x, size: 22).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Close player")
          }
          .modifier(MobilePlayerGroupSurface())
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("mobile-player-top-actions")
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
              .modifier(MobilePlayerButtonSurface())
            }
          }
        if model.presentationState == .ready {
          HStack(spacing: 8) {
            MobileStreamReadouts(state: model.liveStatus, startedAt: model.streamStartedAt,
            viewerCount: viewerCount, showDuration: showStreamDuration, viewerCounts: model.viewerCounts) {
                onInteraction()
                model.goLive()
              }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
              if MobilePlaybackModel.supportsVolumeAdjustment {
                MobilePlayerAudioControl(model: model, onInteraction: onInteraction,
                  onInteractionChanged: onVolumeInteraction)
              }
              HStack(spacing: 8) {
                if !MobilePlaybackModel.supportsVolumeAdjustment {
                  MobilePlayerAudioControl(model: model, onInteraction: onInteraction)
                }
                if showsChatToggle {
                  Button {
                    onInteraction()
                    hideChat.toggle()
                  } label: {
                    Icon(glyph: hideChat ? .messages : .messagesOff, size: 22).frame(
                      width: 44, height: 44)
                      .contentShape(Rectangle())
                  }
                  .accessibilityLabel(hideChat ? "Show chat" : "Hide chat")
                  .accessibilityIdentifier("mobile-toggle-chat")
                }
                Button(action: onFullscreen) {
                  Icon(glyph: isFullscreen ? .arrowsDiagonalMinimize : .arrowsDiagonal2, size: 22)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(
                  UIDevice.current.userInterfaceIdiom == .phone
                    ? (isFullscreen ? "Rotate to portrait" : "Rotate to landscape")
                    : (isFullscreen ? "Exit fullscreen" : "Fullscreen")
                )
                .accessibilityIdentifier("mobile-rotate-player")
              }
              .modifier(MobilePlayerGroupSurface())
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("mobile-player-bottom-actions")
            }
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
      if showsScrim {
        MobilePlayerControlScrim(hasBottomControls: model.presentationState == .ready,
                                 reduceTransparency: reduceTransparency)
      }
    }
  }
}

struct MobilePlayerAudioControl: View {
  let model: MobilePlaybackModel
  var onInteraction: () -> Void = {}
  var onInteractionChanged: (Bool) -> Void = { _ in }
  @State private var isEditing = false
  @State private var isHovered = false
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    if MobilePlaybackModel.supportsVolumeAdjustment {
      HStack(spacing: 8) {
        MobilePlayerVolumeSlider(value: Binding(
          get: { model.isMuted ? 0 : model.volume },
          set: { model.setVolume($0); onInteraction() }),
          foreground: reduceTransparency ? palette.chromeOnOpaque : palette.videoControlForeground
        ) { editing in
            isEditing = editing
            onInteraction()
          }
          .frame(minWidth: 80, idealWidth: 140, maxWidth: 140)
          .frame(height: 44)
        Button {
          onInteraction()
          model.toggleMute()
        } label: {
          Icon(glyph: model.isMuted ? .volumeOff : .volume, size: 22)
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")
        .accessibilityIdentifier("mobile-volume-mute")
      }
      .padding(.leading, 12)
      .padding(.trailing, 4)
      .frame(height: 44)
      .modifier(MobilePlayerGroupSurface())
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("mobile-volume-control")
      .onHover { isHovered = $0 }
      .onChange(of: isEditing || isHovered) { _, interacting in onInteractionChanged(interacting) }
      .onDisappear { onInteractionChanged(false) }
    } else {
      Button {
        onInteraction()
        model.toggleMute()
      } label: {
        Icon(glyph: model.isMuted ? .volumeOff : .volume, size: 22)
          .frame(width: 44, height: 44).contentShape(Rectangle())
      }
      .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")
      .accessibilityIdentifier("mobile-mute")
    }
  }
}

// Keep native tracking and accessibility, with a compact round thumb rather than
// SwiftUI's large slider thumb. Touch-down also holds controls before a drag starts.
private struct MobilePlayerVolumeSlider: UIViewRepresentable {
  @Binding var value: Float
  let foreground: Color
  let onEditingChanged: (Bool) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> UISlider {
    let slider = UISlider()
    slider.minimumValue = 0
    slider.maximumValue = 1
    slider.isContinuous = true
    slider.accessibilityLabel = String(localized: "Volume")
    slider.accessibilityIdentifier = "mobile-volume-slider"
    slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
    slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
    slider.addTarget(context.coordinator, action: #selector(Coordinator.ended),
      for: [.touchUpInside, .touchUpOutside, .touchCancel])
    // Taps cancel native tracking; drags fail this recognizer and continue normally.
    let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
    slider.addGestureRecognizer(tap)
    return slider
  }

  func updateUIView(_ slider: UISlider, context: Context) {
    context.coordinator.parent = self
    slider.value = value
    slider.accessibilityValue = Double(value).formatted(.percent.precision(.fractionLength(0)))
    let color = UIColor(foreground)
    slider.minimumTrackTintColor = color
    slider.maximumTrackTintColor = color.withAlphaComponent(0.25)
    if context.coordinator.thumbColor != color {
      let thumb = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
        color.setFill()
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 20, height: 20)).fill()
      }
      slider.setThumbImage(thumb, for: .normal)
      slider.setThumbImage(thumb, for: .highlighted)
      context.coordinator.thumbColor = color
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: MobilePlayerVolumeSlider
    var thumbColor: UIColor?

    init(_ parent: MobilePlayerVolumeSlider) { self.parent = parent }
    @objc func changed(_ slider: UISlider) { parent.value = slider.value }
    @objc func began() { parent.onEditingChanged(true) }
    @objc func ended() { parent.onEditingChanged(false) }

    @objc func tapped(_ gesture: UITapGestureRecognizer) {
      guard let slider = gesture.view as? UISlider, slider.isEnabled else { return }
      let track = slider.trackRect(forBounds: slider.bounds)
      let start = slider.thumbRect(forBounds: slider.bounds, trackRect: track,
        value: slider.minimumValue).midX
      let end = slider.thumbRect(forBounds: slider.bounds, trackRect: track,
        value: slider.maximumValue).midX
      guard start != end else { return }
      let fraction = Float(min(1, max(0, (gesture.location(in: slider).x - start) / (end - start))))
      slider.value = slider.minimumValue + fraction * (slider.maximumValue - slider.minimumValue)
      slider.sendActions(for: .valueChanged)
    }
  }
}

struct MobilePlayerGlassContainer<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 8) { content }
    } else {
      content
    }
  }
}

struct MobilePlayerButtonSurface: ViewModifier {
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content
      .foregroundStyle(reduceTransparency ? palette.chromeOnOpaque : palette.videoControlForeground)
      .contentShape(Capsule())
      .modifier(MobilePlayerButtonAppearance(palette: palette, opaque: reduceTransparency))
      .environment(\.colorScheme, reduceTransparency ? palette.chromeColorScheme : .dark)
  }
}

struct MobilePlayerGroupSurface: ViewModifier {
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content
      .foregroundStyle(reduceTransparency ? palette.chromeOnOpaque : palette.videoControlForeground)
      // Keep individual button hit shapes; a group contentShape also expands VoiceOver frames.
      .modifier(MobilePlayerButtonAppearance(palette: palette, opaque: reduceTransparency))
      .environment(\.colorScheme, reduceTransparency ? palette.chromeColorScheme : .dark)
  }
}

struct MobilePlayerButtonAppearance: ViewModifier {
  let palette: ThemePalette
  let opaque: Bool

  func body(content: Content) -> some View {
    if opaque {
      content
        .background(palette.chromeOpaqueSurface, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.chromeOpaqueBorder, lineWidth: 0.5).allowsHitTesting(false) }
    } else if #available(iOS 26.0, *) {
      content.glassEffect(.regular.tint(palette.videoControlScrim.opacity(0.55)).interactive(), in: Capsule())
    } else {
      content.background(.regularMaterial, in: Capsule())
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

final class MobilePlayerSurfaceScrim {
  enum Style: Equatable {
    case minimized(hasError: Bool)
    case expanded(hasBottomControls: Bool)
  }

  struct Configuration: Equatable {
    let color: UIColor
    let style: Style
    let reduceTransparency: Bool
  }

  let layer = CALayer()
  private let expanded = CAGradientLayer()
  private let top = CAGradientLayer()
  private let bottom = CAGradientLayer()
  private var configuration: Configuration?

  init() {
    layer.masksToBounds = true
    layer.opacity = 0
    layer.addSublayer(expanded)
    layer.addSublayer(top)
    layer.addSublayer(bottom)
    expanded.locations = [0, 0.45, 0.55, 1]
    top.locations = [0, 0.25, 0.55, 1]
    bottom.locations = [0, 0.6, 1]
  }

  func update(_ configuration: Configuration?, animated: Bool) {
    guard configuration != self.configuration else { return }
    let wasVisible = self.configuration != nil
    let opacity = layer.presentation()?.opacity ?? layer.opacity
    self.configuration = configuration
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let configuration {
      let strength = configuration.reduceTransparency ? 1.25 : 1.0
      switch configuration.style {
      case .minimized(let hasError):
        expanded.isHidden = true
        top.isHidden = false
        bottom.isHidden = !hasError
        top.colors = [0.66, 0.60, 0.40, 0].map { configuration.color.withAlphaComponent($0 * strength).cgColor }
        bottom.colors = [0.64, 0.58, 0].map { configuration.color.withAlphaComponent($0 * strength).cgColor }
      case .expanded(let hasBottomControls):
        expanded.isHidden = false
        top.isHidden = true
        bottom.isHidden = true
        expanded.colors = [0.60, 0.54, 0.54, hasBottomControls ? 0.64 : 0.50]
          .map { configuration.color.withAlphaComponent($0 * strength).cgColor }
      }
    }
    layer.opacity = configuration == nil ? 0 : 1
    if wasVisible != (configuration != nil) {
      layer.removeAnimation(forKey: "visibility")
      if animated {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = layer.opacity
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "visibility")
      }
    }
    CATransaction.commit()
  }

  // Called in the same no-actions transaction as AVPlayerLayer layout. Only
  // visibility fades; geometry never starts a second, lagging animation.
  func layout(in bounds: CGRect, scale: CGFloat) {
    layer.frame = bounds
    let scale = max(1, scale)
    layer.contentsScale = scale
    expanded.contentsScale = scale
    top.contentsScale = scale
    bottom.contentsScale = scale
    let bleed = 2 / scale
    expanded.frame = layer.bounds.insetBy(dx: -bleed, dy: -bleed)
    expanded.startPoint = CGPoint(x: 0.5, y: bleed / expanded.frame.height)
    expanded.endPoint = CGPoint(x: 0.5, y: (bleed + bounds.height) / expanded.frame.height)
    let topHeight = min(bounds.height, max(96, bounds.height * 0.5))
    let bottomHeight = min(72, bounds.height)
    top.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topHeight).insetBy(dx: -bleed, dy: -bleed)
    bottom.frame = CGRect(x: 0, y: bounds.height - bottomHeight, width: bounds.width, height: bottomHeight)
      .insetBy(dx: -bleed, dy: -bleed)
    // Keep the original fade positions inside the clipped two-pixel overscan.
    top.startPoint = CGPoint(x: 0.5, y: bleed / top.frame.height)
    top.endPoint = CGPoint(x: 0.5, y: (bleed + topHeight) / top.frame.height)
    bottom.startPoint = CGPoint(x: 0.5, y: (bleed + bottomHeight) / bottom.frame.height)
    bottom.endPoint = CGPoint(x: 0.5, y: bleed / bottom.frame.height)
  }
}

struct MobileQualitySheet: View {
  let model: MobilePlaybackModel
  @State private var draftPlatform = LivePlatform.kick
  @State private var draftChannel = ""
  @State private var sourceError: String?
  @State private var showCreatorChannels = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("Stream source") {
          Button("Linked creator channels") { showCreatorChannels = true }
          ForEach(model.sources) { source in
            Button("\(source.platform.title): \(source.channel)") {
              model.switchSource(source)
              dismiss()
            }
          }
          Picker("Platform", selection: $draftPlatform) {
            ForEach(LivePlatform.allCases.filter {
              StreamPlatformPreferences.shared.selection.includes($0)
            }, id: \.self) { Text($0.title).tag($0) }
          }
          .accessibilityIdentifier("player-source-platform")
          TextField("Channel name or URL", text: $draftChannel).autocorrectionDisabled()
            .accessibilityIdentifier("player-source-target")
          Button("Switch source") {
            do {
              let target = try PlatformLiveTarget.validated(platform: draftPlatform, input: draftChannel)
              model.switchSource(target)
              dismiss()
            } catch { sourceError = error.localizedDescription }
          }
          .accessibilityIdentifier("player-source-switch")
          if let sourceError { Text(sourceError).foregroundStyle(.secondary) }
        }
        if !model.isExternalPlayback {
          qualityRow(model.source.platform == .youtube ? "Auto" : "Auto - Native Low Latency", quality: .native)
        }
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
    .onAppear {
      draftPlatform = model.source.platform
      draftChannel = model.source.channel
    }
    .sheet(isPresented: $showCreatorChannels) {
      CreatorChannelsView(session: model.creatorSession)
    }
    .onChange(of: draftPlatform) { _, platform in
      if let previous = model.sources.first(where: { $0.platform == platform }) { draftChannel = previous.channel }
      else if platform == .kick, model.source.platform == .twitch {
        draftChannel = KickAliasService().kickSlug(forTwitchLogin: model.source.channel) ?? model.source.channel
      }
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
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private var foreground: UIColor {
    UIColor(reduceTransparency ? palette.chromeOnOpaque : palette.videoControlForeground)
  }

  func makeCoordinator() -> Coordinator { Coordinator(onPresentation: onPresentation) }

  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.prioritizesVideoDevices = true
    view.delegate = context.coordinator
    view.accessibilityLabel = "AirPlay"
    view.tintColor = foreground
    view.activeTintColor = foreground
    return view
  }

  func updateUIView(_ view: AVRoutePickerView, context: Context) {
    view.tintColor = foreground
    view.activeTintColor = foreground
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

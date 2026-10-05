import AVKit
import SwiftUI

enum MobilePlayerLayout: Equatable {
  case portrait, sideBySide, videoOnly

  static func resolve(size: CGSize, isPhone: Bool, hideChat: Bool, phoneLandscape: Bool = false) -> Self {
    if hideChat || (isPhone && phoneLandscape) { return .videoOnly }
    return size.width >= 800 && size.width > size.height ? .sideBySide : .portrait
  }
}

struct MobilePlayerView: View {
  let channel: FollowedChannel
  @State private var model: MobilePlaybackModel
  @State private var hideChat = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.themePalette) private var palette
  @Environment(\.verticalSizeClass) private var verticalSizeClass

  init(channel: FollowedChannel, model: MobilePlaybackModel = MobilePlaybackModel()) {
    self.channel = channel
    _model = State(initialValue: model)
  }

  var body: some View {
    GeometryReader { geometry in
      let layout = MobilePlayerLayout.resolve(
        size: CGSize(width: geometry.size.width, height: geometry.size.height + geometry.safeAreaInsets.bottom),
        isPhone: UIDevice.current.userInterfaceIdiom == .phone, hideChat: hideChat,
        phoneLandscape: verticalSizeClass == .compact)
      VStack(spacing: 0) {
        MobilePlayerToolbar(model: model, hideChat: $hideChat, onClose: { dismiss() })
        if layout == .sideBySide {
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              MobileVideoView(model: model)
              MobileStreamDetails(channel: channel, model: model)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            Divider()
            MobileChatView(service: model.chat, channel: channel.login)
              .frame(width: min(380, geometry.size.width * 0.36))
          }
        } else {
          MobileVideoView(model: model)
            .frame(maxHeight: layout == .videoOnly ? .infinity
                   : min(geometry.size.width * 9 / 16, geometry.size.height * 0.42))
          if layout == .portrait {
            MobileStreamDetails(channel: channel, model: model)
            Divider()
            MobileChatView(service: model.chat, channel: channel.login)
          }
        }
      }
    }
    .background(palette.chatSideSurface)
    .task { model.start(channel: channel.login) }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { model.suspend() }
      else if phase == .active { model.resume() }
    }
  }
}

struct MobilePlayerToolbar: View {
  let model: MobilePlaybackModel
  @Binding var hideChat: Bool
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onClose) { Icon(glyph: .x, size: 22).frame(width: 44, height: 44) }
        .accessibilityLabel("Close player")
      Menu {
        if model.nativeFailure == nil {
          Button { model.select(.native) } label: {
            MobileQualityLabel(title: "Auto - Native Low Latency", selected: model.selection == .native)
          }
        }
        Button { model.select(.automatic) } label: {
          MobileQualityLabel(title: "Auto - Standard", selected: model.selection == .automatic)
        }
        ForEach(model.qualities) { quality in
          Button { model.select(.fixed(quality.id)) } label: {
            MobileQualityLabel(title: quality.name, selected: model.selection == .fixed(quality.id))
          }
        }
      } label: {
        Icon(glyph: .adjustmentsHorizontal, size: 22).frame(width: 44, height: 44)
      }
      .accessibilityLabel("Playback quality")
      .accessibilityValue(model.qualityLabel)
      .disabled(model.isLoading)
      Spacer(minLength: 0)
      Button("Go live") { model.goLive() }.disabled(model.isLoading)
      Button { hideChat.toggle() } label: {
        Icon(glyph: hideChat ? .sidebarRightExpand : .sidebarRightCollapse, size: 22)
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel(hideChat ? "Show chat" : "Hide chat")
    }
    .padding(.horizontal, 8)
  }
}

struct MobileQualityLabel: View {
  let title: String
  let selected: Bool

  var body: some View {
    Label {
      Text(title)
    } icon: {
      if selected { Image("tb-check") }
    }
  }
}

struct MobileVideoView: View {
  let model: MobilePlaybackModel
  @Environment(\.themePalette) private var palette

  var body: some View {
    ZStack {
      palette.playerBackdrop
      MobilePlayerSurface(player: model.player) { ready, player in
        model.displayReady(ready, for: player)
      }
        .id(ObjectIdentifier(model.player))
        .accessibilityIdentifier("mobile-video-surface")
        .allowsHitTesting(!model.isLoading)
      if model.isAudioOnly && !model.isLoading {
        Label { Text("Audio only") } icon: { Icon(glyph: .volume, size: 24) }
          .padding().background(palette.chromeOpaqueSurface, in: RoundedRectangle(cornerRadius: 12))
          .allowsHitTesting(false)
      }
      if model.isLoading || (!model.isReadyForDisplay && !model.isAudioOnly && !model.isPaused && model.errorMessage == nil) {
        ProgressView("Loading stream")
          .accessibilityIdentifier("mobile-video-loading")
          .padding().background(palette.chromeOpaqueSurface, in: RoundedRectangle(cornerRadius: 12))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      if let error = model.errorMessage {
        MobileStatusView(message: error) { model.retry() }
          .background(palette.chromeOpaqueSurface)
      }
    }
  }
}

struct MobilePlayerSurface: UIViewControllerRepresentable {
  let player: AVPlayer
  let onReady: (Bool, AVPlayer) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady) }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = true
    controller.allowsPictureInPicturePlayback = false
    context.coordinator.observe(controller)
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    context.coordinator.onReady = onReady
    if controller.player !== player { controller.player = player }
  }

  static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
    // Layout transitions can replace the surface without ending the stream.
    coordinator.observation = nil
    controller.player = nil
  }

  @MainActor
  final class Coordinator {
    var onReady: (Bool, AVPlayer) -> Void
    var observation: NSKeyValueObservation?

    init(onReady: @escaping (Bool, AVPlayer) -> Void) { self.onReady = onReady }

    func observe(_ controller: AVPlayerViewController) {
      observation = controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] controller, _ in
        Task { @MainActor [weak self, weak controller] in
          guard let controller, let player = controller.player else { return }
          self?.onReady(controller.isReadyForDisplay, player)
        }
      }
    }
  }
}

struct MobileStreamDetails: View {
  let channel: FollowedChannel
  let model: MobilePlaybackModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(channel.displayName).font(.headline)
        Spacer()
        if let count = channel.viewerCount {
          Text("\(count.formatted(.number.notation(.compactName))) watching").font(.caption)
        }
      }
      Text(channel.title).font(.subheadline).lineLimit(2)
      Text(model.qualityLabel).font(.caption).foregroundStyle(.secondary)
      if let notice = model.recoveryNotice {
        Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      } else if let failure = model.nativeFailure {
        Text("Using standard playback: \(failure)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

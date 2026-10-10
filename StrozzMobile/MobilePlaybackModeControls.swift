import SwiftUI

struct MobilePlaybackModeButton: View {
  let model: MobilePlaybackModel
  var onVideoSelection: () -> Void = {}
  var onPresentation: (Bool) -> Void = { _ in }
  @State private var isPresented = false
  @Environment(\.themePalette) private var palette

  var body: some View {
    Button { isPresented = true } label: {
      Icon(glyph: .layoutGrid, size: 22).frame(width: 44, height: 44)
    }
    .accessibilityLabel("Playback mode")
    .accessibilityValue(Text(model.mode.title))
    .accessibilityIdentifier("mobile-playback-mode")
    .onChange(of: isPresented) { _, showing in onPresentation(showing) }
    .sheet(isPresented: $isPresented) {
      NavigationStack {
        List {
          ForEach(MobilePlaybackMode.allCases, id: \.self) { mode in
            Button {
              isPresented = false
              onPresentation(false)
              model.selectMode(mode)
              if mode == .video { onVideoSelection() }
            } label: {
              HStack {
                Text(mode.title)
                Spacer()
                if model.mode == mode { Icon(glyph: .check, size: 20) }
              }
            }
            .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
          }
        }
        .scrollContentBackground(.hidden)
        .background(palette.chatSideSurface)
        .navigationTitle("Playback mode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isPresented = false } } }
      }
      .environment(\.themePalette, palette)
      .foregroundStyle(palette.chatSidePrimaryText)
      .presentationDetents([.medium])
    }
  }
}

struct MobileChatOnlyControls: View {
  let channel: FollowedChannel
  let model: MobilePlaybackModel
  let onClose: () -> Void
  @Environment(\.themePalette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Button(action: onClose) { Icon(glyph: .x, size: 22).frame(width: 44, height: 44) }
          .accessibilityLabel("Close player")
        Text(channel.displayName).font(.headline).lineLimit(1)
        Spacer(minLength: 0)
        if model.mode == .audioOnly {
          if model.isLoading {
            ProgressView().accessibilityLabel("Loading audio")
          } else {
            Button { model.togglePlayPause() } label: {
              Icon(glyph: model.isPaused ? .playerPlayFilled : .playerPauseFilled, size: 22)
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.isPaused ? "Play audio" : "Pause audio")
            .accessibilityIdentifier("mobile-audio-play-pause")
            .disabled(model.errorMessage != nil)
            Button { model.toggleMute() } label: {
              Icon(glyph: model.isMuted ? .volumeOff : .volume, size: 22).frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.isMuted ? "Unmute audio" : "Mute audio")
          }
        }
        MobilePlaybackModeButton(model: model)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      if let error = model.errorMessage {
        VStack(spacing: 8) {
          Text(error).font(.callout)
          Button("Retry") { model.retry() }
        }
        .padding()
      }
      Divider()
    }
    .buttonStyle(.plain)
    .foregroundStyle(palette.chatSidePrimaryText)
    .background(palette.chatSideSurface)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mobile-chat-only-controls")
  }
}

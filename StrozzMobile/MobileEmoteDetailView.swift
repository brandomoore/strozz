import SDWebImageSwiftUI
import SwiftUI

struct MobileChatEmote: Hashable, Identifiable {
  let name: String
  let url: URL
  var id: Self { self }

  var provider: String? {
    switch url.host?.lowercased() {
    case "static-cdn.jtvnw.net": return "Twitch"
    case "cdn.7tv.app": return "7TV"
    case "cdn.betterttv.net": return "BetterTTV"
    case "cdn.frankerfacez.com": return "FrankerFaceZ"
    case "files.kick.com": return "Kick"
    case "yt3.ggpht.com", "yt4.ggpht.com", "yt3.googleusercontent.com": return "YouTube"
    default: return nil
    }
  }

  var previewURL: URL {
    guard url.scheme == "https", var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    let parts = url.pathComponents
    let replacement: String
    switch url.host?.lowercased() {
    case "static-cdn.jtvnw.net" where parts.count == 7 && parts[1] == "emoticons" && parts[2] == "v2"
      && ["1.0", "2.0", "3.0"].contains(parts[6]):
      replacement = "3.0"
    case "cdn.7tv.app" where parts.count == 4 && parts[1] == "emote"
      && ["1x.webp", "2x.webp", "3x.webp", "4x.webp"].contains(parts[3]):
      replacement = "4x.webp"
    case "cdn.betterttv.net" where parts.count == 4 && parts[1] == "emote"
      && ["1x", "2x", "3x"].contains(parts[3]):
      replacement = "3x"
    default:
      return url
    }
    components.path = components.path.components(separatedBy: "/").dropLast()
      .joined(separator: "/") + "/" + replacement
    return components.url ?? url
  }
}

struct MobileEmoteDetailView: View {
  let emote: MobileChatEmote
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          MobileEmoteArtwork(emote: emote)
            .id(emote.id)
          Text(emote.name)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .accessibilityIdentifier("emote-detail-name")
          if let provider = emote.provider {
            Text(provider)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("emote-detail-provider")
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
      }
      .background(palette.chatSideSurface)
      .foregroundStyle(palette.chatSidePrimaryText)
      .navigationTitle("Emote")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("emote-detail-done")
        }
      }
    }
    .presentationDetents([.height(460), .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(palette.chatSideSurface)
    .accessibilityIdentifier("emote-detail")
  }
}

private struct MobileEmoteArtwork: View {
  let emote: MobileChatEmote
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themePalette) private var palette
  @State private var useOriginal = false
  @State private var failed = false
  @State private var loaded = false
  @State private var requestID = UUID()

  var body: some View {
    let url = useOriginal ? emote.url : emote.previewURL
    let request = requestID
    VStack(spacing: 12) {
      ZStack {
        if failed {
          VStack(spacing: 12) {
            Icon(glyph: .alertCircle, size: 32)
            Text("Couldn't load emote")
            Button("Try again") {
              requestID = UUID()
              failed = false
              loaded = false
              useOriginal = false
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("emote-detail-retry")
          }
          .multilineTextAlignment(.center)
        } else {
          WebImage(url: url, isAnimating: .constant(!reduceMotion)) { image in
            image.resizable().scaledToFit()
          } placeholder: {
            ProgressView("Loading emote")
          }
          .onSuccess { _, _, _ in
            DispatchQueue.main.async {
              guard request == requestID, url == (useOriginal ? emote.url : emote.previewURL) else { return }
              loaded = true
            }
          }
          .onFailure { _ in
            // Image cancellation can call back during a SwiftUI update.
            DispatchQueue.main.async {
              guard request == requestID, url == (useOriginal ? emote.url : emote.previewURL) else { return }
              if url != emote.url { useOriginal = true }
              else { failed = true }
            }
          }
          .id(request)
        }
      }
      .frame(width: 220, height: 220)
      .padding(12)
      .background(palette.cardOpaqueSurface, in: RoundedRectangle(cornerRadius: 16))
      .accessibilityElement(children: failed ? .contain : .ignore)
      .accessibilityLabel("Preview of \(emote.name)")
      .accessibilityValue(failed ? Text("Unavailable") : (loaded ? Text("Loaded") : Text("Loading")))
      .accessibilityIdentifier("emote-detail-artwork")
      if useOriginal, !failed {
        Text("Full-size image unavailable. Showing the chat image.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
  }
}

import SwiftUI
import UIKit

/// A scroll instruction for the chat list. The nonce ensures repeated scrolls to
/// the same message still register as a change through `onChange`.
struct ChatScrollTarget: Equatable {
  var id: ChatMessage.ID
  var anchor: UnitPoint
  var nonce: Int
  /// Continuous gesture scrolling sends un-animated targets so the rapid 60 Hz
  /// updates read as a smooth drag rather than a stutter of spring animations.
  var animated: Bool = true
}

/// A read-only chat panel that auto-scrolls to the newest message.
/// Designed as a translucent overlay on top of the video player.
struct ChatView: View {
  let channel: String
  let messages: [ChatMessage]
  var textSize: CGFloat = ChatAppearance.defaultTextSize
  var emoteSize: CGFloat = ChatAppearance.defaultEmoteSize
  var messageSpacing: CGFloat = ChatAppearance.defaultMessageSpacing
  var lineHeight: CGFloat = ChatAppearance.defaultLineHeight
  var letterSpacing: CGFloat = ChatAppearance.defaultLetterSpacing
  var animatedEmotes: Bool = true
  var fontStyle: ChatFontStyle = ChatAppearance.defaultFontStyle
  var showBadges: Bool = ChatAppearance.defaultShowBadges
  var showPlatformBadges: Bool = ChatAppearance.defaultShowPlatformBadges
  /// Master on/off for mention highlighting.
  var highlightEnabled: Bool = true
  /// Signed-in user's Twitch login (lowercase) and display name, used to detect
  /// lines that mention the viewer. Both nil when signed out.
  var viewerLogin: String? = nil
  var viewerDisplayName: String? = nil
  /// Extra user-defined highlight keywords (already normalized/lowercased).
  var highlightKeywords: [String] = []
  var isConnected: Bool = false
  var isReconnecting: Bool = false
  var emoteURLs: [String: URL] = [:]
  var badgeURLs: [String: URL] = [:]
  /// Channel + global cheermotes, used to render bits cheers (e.g. `Cheer100`).
  var cheermotes: [Cheermote] = []
  /// When true, cheermote tokens are matched without an accompanying bits count
  /// (VOD replay, where comments carry no `bits` tag). Live chat leaves this
  /// false so only real cheers (with bits) render as cheermotes.
  var matchCheersWithoutBits: Bool = false
  /// When true, the message list draws a light scrim instead of a solid
  /// background so an underlying Liquid Glass panel can show through.
  var useGlassBackground: Bool = false
  /// When true, use a lighter non-glass background for overlay mode.
  var useLighterOverlayBackground: Bool = false
  /// When false, the list stops pinning to the newest message so the viewer can
  /// scroll back through history without the view yanking to the bottom.
  var autoScroll: Bool = true
  /// When non-nil, chat is in the lightweight "soft pause" read mode and this is
  /// the seconds remaining before it auto-resumes. Drives the countdown pill.
  var softPauseRemaining: Int? = nil
  /// Total soft-pause duration in seconds, used to draw the countdown ring.
  var softPauseTotal: Int = 10
  /// A scroll instruction from the player (manual scroll mode). Changing its
  /// nonce scrolls the list to the given message; the player keeps focus on the
  /// composer because tvOS won't reliably keep focus on the chat ScrollView.
  var scrollTarget: ChatScrollTarget? = nil
  @Environment(\.themePalette) var palette
  @Environment(\.glassDisabled) var glassDisabled
  /// Drives the swipe-up hint chevron: it fades + drifts up once, slightly after
  /// the pill animates in. Reset to false on disappear so it replays on reopen.
  @State var hintShown = false
  private enum ScrollAnchor: Hashable { case liveEdge }

  /// Side layout is the only non-glass, non-overlay mode; it follows the
  /// app theme so light mode paints a light chat panel with dark text.
  var isSideLayout: Bool {
    !useGlassBackground && !useLighterOverlayBackground
  }

  /// The nominal surface colored chat text is drawn on, used to keep name colors
  /// and accents at a readable contrast. Overlay/glass modes sit on the dark,
  /// translucent player; only the light-theme side panel is a light surface.
  var chatSurfaceColor: Color {
    if isSideLayout { return palette.chatSideSurface }
    // Reduce-transparency / disable-glass: the pane paints an opaque, theme-aware
    // chrome surface (light in Light theme), so resolve text contrast against it.
    if glassDisabled { return palette.chromeOpaqueSurface }
    // Light theme: the translucent overlay/glass chat now sits on light chrome
    // (the player tree renders in the light color scheme), so resolve text and
    // accent contrast against a light surface instead of the dark video.
    if palette.isLight { return Color(white: 0.97) }
    if useLighterOverlayBackground { return Color(white: 0.13) }
    return Color(white: 0.12)
  }

  var isLightChatSurface: Bool {
    // Bridging to UIColor and reading its luminance isn't free, and this is hit
    // multiple times per chat line (name color + body color override). The result
    // only depends on the surface inputs, not the message, so memoize it in a
    // single-entry cache keyed by those inputs — N bridges per render collapse to
    // one when the signature is unchanged.
    let signature = LightSurfaceSignature(
      palette: palette,
      glassDisabled: glassDisabled,
      isSideLayout: isSideLayout,
      useLighterOverlayBackground: useLighterOverlayBackground
    )
    if let memo = Self.lightSurfaceMemo, memo.signature == signature {
      return memo.value
    }
    var white: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(chatSurfaceColor).getWhite(&white, alpha: &alpha)
    let value = white > 0.5
    Self.lightSurfaceMemo = (signature, value)
    return value
  }

  struct LightSurfaceSignature: Equatable {
    let palette: ThemePalette
    let glassDisabled: Bool
    let isSideLayout: Bool
    let useLighterOverlayBackground: Bool
  }

  static var lightSurfaceMemo: (signature: LightSurfaceSignature, value: Bool)?

  private var messageSpacingValue: CGFloat {
    messageSpacing
  }

  var horizontalPadding: CGFloat {
    ChatAppearance.horizontalPadding(forTextSize: textSize)
  }

  var verticalPadding: CGFloat {
    ChatAppearance.verticalPadding(forMessageSpacing: messageSpacing)
  }

  var body: some View {
    GeometryReader { geometry in
      messageList(viewportHeight: geometry.size.height)
    }
      .background(
        isSideLayout
          ? AnyShapeStyle(palette.chatSideSurface)
          : (useGlassBackground
            ? (glassDisabled
              ? AnyShapeStyle(Color.clear)
              : AnyShapeStyle(palette.chromeGlassTint(0.22)))
            : (useLighterOverlayBackground
              ? (glassDisabled
                ? AnyShapeStyle(palette.chromeOpaqueSurface)
                : AnyShapeStyle(palette.isLight ? Color(white: 0.97).opacity(0.92) : Color(white: 0.13).opacity(0.90)))
              : AnyShapeStyle(palette.chatSideSurface))))
  }

  private func messageList(viewportHeight: CGFloat) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          Group {
            if autoScroll {
              // Lazy row-height estimates can strand the viewport in empty
              // space when emotes resize. Live needs only a viewport-sized
              // tail; measure those rows eagerly and retain full scrollback.
              VStack(alignment: .leading, spacing: messageSpacingValue) {
                messageRows(messages.suffix(liveMessageLimit(viewportHeight: viewportHeight)))
              }
            } else {
              LazyVStack(alignment: .leading, spacing: messageSpacingValue) {
                messageRows(messages[...])
              }
            }
          }
          .padding(.horizontal, horizontalPadding)
          .padding(.vertical, verticalPadding)
          Color.clear
            .frame(height: 1)
            .id(ScrollAnchor.liveEdge)
            .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
          if autoScroll { scrollToLiveEdge(proxy) }
        }
      }
      .scrollIndicators(.hidden)
      .defaultScrollAnchor(.bottom)
      .onChange(of: messages.last?.id, initial: true) { _, _ in
        if autoScroll { scrollToLiveEdge(proxy) }
      }
      .onChange(of: scrollTarget, initial: true) { _, target in
        guard !autoScroll, let target, messages.contains(where: { $0.id == target.id }) else { return }
        if target.animated {
          withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            proxy.scrollTo(target.id, anchor: target.anchor)
          }
        } else {
          proxy.scrollTo(target.id, anchor: target.anchor)
        }
      }
      .onChange(of: autoScroll) { _, isOn in
        if isOn { scrollToLiveEdge(proxy) }
      }
      .overlay(alignment: .bottom) {
        ZStack {
          if !autoScroll {
            pausedPill
          }
        }
        .animation(.easeInOut(duration: 0.2), value: autoScroll)
        .animation(.easeInOut(duration: 0.2), value: softPauseRemaining)
      }
      .overlay {
        if messages.isEmpty {
          Text(isConnected ? "Waiting for messages…" : "Connecting to chat…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      // Live-tail and full-history offsets use different coordinate spaces.
      // Reset only on a reading-mode change, never on incoming messages.
      .id(autoScroll)
      .overlay(alignment: .top) {
        if isReconnecting, !messages.isEmpty {
          Text("Reconnecting Twitch chat…")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
      }
    }
  }

  private func messageRows(_ displayed: ArraySlice<ChatMessage>) -> some View {
    ForEach(displayed) { message in
      line(for: message)
        .id(message.id)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  func liveMessageLimit(viewportHeight: CGFloat) -> Int {
    // Every row contains at least one username line. Font point size is a
    // conservative lower bound on its line box; add two rows of overscan.
    max(1, Int(ceil(viewportHeight / max(textSize, 1))) + 2)
  }

  private func scrollToLiveEdge(_ proxy: ScrollViewProxy) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      proxy.scrollTo(ScrollAnchor.liveEdge, anchor: .bottom)
    }
  }
}

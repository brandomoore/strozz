#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct HomeFollowingErrorFixture: View {
  @State private var channels = Self.following
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var request: Task<Void, Never>?
  @State private var retries = 0
  @State private var toast: RefreshToastState?
  @State private var showingDirectory = false
  @State private var awaitingFailure = false
  @FocusState private var focus: String?
  @Environment(\.colorScheme) private var systemColorScheme
  private let settings = ProcessInfo.processInfo.environment
  private let detail = "Secure credential storage is unavailable (-25308)."

  private static let following = makeChannels("Following")
  private static let recommended = makeChannels("Recommended")

  private static func makeChannels(_ name: String) -> [FollowedChannel] {
    (1...3).map { index in
      FollowedChannel(id: "\(name)-\(index)", login: "\(name.lowercased())\(index)",
        displayName: "\(name) \(index)", title: "Fixture stream", gameName: "Fixture",
        viewerCount: 100, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    }
  }

  var body: some View {
    let theme = AppTheme(rawValue: settings["STROZZ_HOME_ERROR_THEME"] ?? "dark") ?? .dark
    let palette = theme.palette(systemColorScheme: systemColorScheme)
    let style = HomeRailStyle(focusHorizontalInset: CardMetrics.cardInset,
      focusVerticalInset: CardMetrics.cardInset, cardCornerRadius: CardMetrics.cardCornerRadius,
      mediaCornerRadius: CardMetrics.mediaCornerRadius)
    ZStack {
      AppBackground(palette: palette)
      GeometryReader { proxy in
        let rail = ChannelRailLayout.metrics(availableWidth: proxy.size.width, visibleCardCount: 3)
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 72) {
            HomeFollowingSection(channels: channels, rail: rail, style: style,
              isLoading: isLoading, isRestoringAccount: false, isUsingDemoData: false,
              errorMessage: errorMessage, showingFollowingDirectory: $showingDirectory,
              onRefresh: retry, onWatch: { _ in }, onGoToChannel: { _ in }, focusedItemID: $focus)
            VStack(alignment: .leading, spacing: 2) {
              Text("Recommended for you").font(.system(size: 32, weight: .bold))
                .accessibilityIdentifier("recommended-title")
              HomeRailScrollView(rail: rail, style: style) {
                ForEach(Self.recommended, id: \.channelKey) { channel in
                  HomeRailStreamCard(channel: channel, itemID: "recommended-\(channel.channelKey)",
                    layout: style.cardLayout(for: rail), onTap: {}, focusedItemID: $focus)
                }
              }
            }
          }
          .padding(.horizontal, AppLayout.horizontalPadding)
          .padding(.top, 32)
          .padding(.bottom, 12)
        }
        .scrollClipDisabled()
      }
    }
    .overlay(alignment: .top) {
      if let toast { RefreshToastView(state: toast).padding(.top, 20) }
    }
    .environment(\.themePalette, palette)
    .environment(\.glassDisabled, settings["STROZZ_HOME_ERROR_OPAQUE"] == "1")
    .preferredColorScheme(theme.preferredColorScheme)
    .onPlayPauseCommand { fail() }
    .task {
      await Task.yield()
      focus = HomeFollowingFocus.card(Self.following[0].channelKey)
    }
    .onDisappear { request?.cancel() }
  }

  private func fail() {
    if awaitingFailure {
      awaitingFailure = false
      errorMessage = detail
      isLoading = false
      return
    }
    request?.cancel()
    isLoading = true
    errorMessage = nil
    if settings["STROZZ_HOME_ERROR_KEEP_CHANNELS"] != "1" { channels = [] }
    if settings["STROZZ_HOME_ERROR_GATE"] == "1" {
      awaitingFailure = true
      return
    }
    request = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      errorMessage = detail
      isLoading = false
    }
  }

  private func retry() {
    request?.cancel()
    awaitingFailure = false
    retries += 1
    isLoading = true
    errorMessage = nil
    toast = .refreshing
    request = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      if retries < 2 { errorMessage = detail }
      else { channels = Self.following }
      isLoading = false
      toast = .finished(hadError: errorMessage != nil)
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      toast = nil
    }
  }
}
#endif

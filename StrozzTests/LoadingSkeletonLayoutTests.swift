import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class LoadingSkeletonLayoutTests: XCTestCase {
  func testStreamSkeletonsMatchCardsAcrossSizesAndPresentations() throws {
    let suiteName = "skeleton-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    for presentation in CardPresentation.allCases {
      defaults.set(presentation.rawValue, forKey: CardPresentation.storageKey)
      for count in [2, 4, 6] {
        let rail = ChannelRailLayout.metrics(availableWidth: 1920, visibleCardCount: count)
        let style = HomeRailStyle(focusHorizontalInset: CardMetrics.cardInset,
          focusVerticalInset: CardMetrics.cardInset, cardCornerRadius: CardMetrics.cardCornerRadius,
          mediaCornerRadius: CardMetrics.mediaCornerRadius)
        let sample = LoadingSkeleton.channels[0]
        let loaded = FollowedChannel(id: "loaded", login: "loaded", displayName: "Streamer",
          title: "A stream", gameName: "Game", viewerCount: 10,
          thumbnailURL: nil, profileImageURL: nil, isLive: true)
        for theme in [AppTheme.system, .dark, .oled, .light] {
          for opaque in [false, true] {
            let palette = theme.palette(systemColorScheme: .light)
            let skeleton = UIHostingController(rootView:
              StreamChannelCard(channel: sample, isFocused: false, layout: style.cardLayout(for: rail), showsGameName: true)
                .modifier(LoadingSkeletonStyle()).defaultAppStorage(defaults)
                .environment(\.themePalette, palette).environment(\.glassDisabled, opaque))
            let card = UIHostingController(rootView:
              StreamChannelCard(channel: loaded, isFocused: false, layout: style.cardLayout(for: rail), showsGameName: true)
                .defaultAppStorage(defaults)
                .environment(\.themePalette, palette).environment(\.glassDisabled, opaque))
            let proposal = CGSize(width: rail.outerCardWidth, height: UIView.layoutFittingExpandedSize.height)
            XCTAssertEqual(skeleton.sizeThatFits(in: proposal).height, card.sizeThatFits(in: proposal).height, accuracy: 1)
          }
        }
      }
    }
  }

  func testEmptyRailKeepsLoadingFootprint() {
    let rail = ChannelRailLayout.metrics(availableWidth: 1920, visibleCardCount: 4)
    let style = HomeRailStyle(focusHorizontalInset: CardMetrics.cardInset,
      focusVerticalInset: CardMetrics.cardInset, cardCornerRadius: CardMetrics.cardCornerRadius,
      mediaCornerRadius: CardMetrics.mediaCornerRadius)
    let loading = UIHostingController(rootView:
      HomeStreamRailPlaceholder(rail: rail, style: style, isLoading: true, emptyMessage: "No streams"))
    let empty = UIHostingController(rootView:
      HomeStreamRailPlaceholder(rail: rail, style: style, isLoading: false, emptyMessage: "No streams"))
    let proposal = CGSize(width: 1800, height: UIView.layoutFittingExpandedSize.height)
    XCTAssertEqual(loading.sizeThatFits(in: proposal).height, empty.sizeThatFits(in: proposal).height, accuracy: 1)
  }
}

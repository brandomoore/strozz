import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class MultiviewLineupLayoutTests: XCTestCase {
  func testEmptyToFullLineupKeepsHomeAndOtherHeaderGeometryStable() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let channels = (0..<6).map { index in
      FollowedChannel(id: "stable-\(index)", login: "stable\(index)", displayName: "Stream \(index)",
        title: "Example stream", gameName: "Example", viewerCount: 100,
        thumbnailURL: nil, profileImageURL: nil, isLive: true)
    }

    for theme in [AppTheme.dark, .light] {
      for opaque in [false, true] {
        let lineup = MultiviewLineup { _ in .live }
        let measurements = LineupLayoutMeasurements()
        let host = UIHostingController(rootView: LineupHeaderStabilityFixture(
          lineup: lineup, channels: channels, measurements: measurements)
          .environment(\.themePalette, theme.palette(systemColorScheme: .dark))
          .environment(\.glassDisabled, opaque)
          .environment(\.streamPreviewsEnabled, false)
          .preferredColorScheme(theme.preferredColorScheme))
        window.rootViewController = host
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let baseline = measurements.frames
        XCTAssertEqual(baseline.count, 3)

        for channel in channels + channels.reversed() {
          lineup.toggle(channel)
          try await Task.sleep(for: .milliseconds(350))
          for (name, initial) in baseline {
            let current = try XCTUnwrap(measurements.frames[name])
            XCTAssertEqual(current.minY, initial.minY, accuracy: 0.01,
              "\(name) moved: \(theme), opaque=\(opaque), count=\(lineup.entries.count)")
            XCTAssertEqual(current.height, initial.height, accuracy: 0.01,
              "\(name) grew: \(theme), opaque=\(opaque), count=\(lineup.entries.count)")
          }
          if [0, 1, 6].contains(lineup.entries.count) {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
              host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Stable headers \(theme) opaque-\(opaque) count-\(lineup.entries.count)"
            attachment.lifetime = .keepAlways
            add(attachment)
          }
        }
        lineup.clear()
      }
    }
  }
}

@MainActor
private final class LineupLayoutMeasurements {
  var frames: [String: CGRect] = [:]
}

private struct LineupHeaderStabilityFixture: View {
  let lineup: MultiviewLineup
  let channels: [FollowedChannel]
  let measurements: LineupLayoutMeasurements
  @State private var showingDirectory = false
  @FocusState private var focus: String?

  var body: some View {
    GeometryReader { geometry in
      let rail = ChannelRailLayout.metrics(availableWidth: geometry.size.width, visibleCardCount: 3)
      let style = HomeRailStyle(focusHorizontalInset: CardMetrics.cardInset,
        focusVerticalInset: CardMetrics.cardInset, cardCornerRadius: CardMetrics.cardCornerRadius,
        mediaCornerRadius: CardMetrics.mediaCornerRadius)
      ScrollView {
        VStack(spacing: 32) {
          HomeFollowingSection(channels: Array(channels.prefix(3)), rail: rail, style: style,
            isLoading: false, isRestoringAccount: false, isUsingDemoData: false,
            errorMessage: nil, showingFollowingDirectory: $showingDirectory,
            onRefresh: {}, onWatch: { _ in }, onGoToChannel: { _ in }, focusedItemID: $focus)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
              measurements.frames["home"] = $0
            }
          HStack {
            Text("Channels").font(.title3.bold())
            Spacer()
            MultiviewLineupButton()
          }
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            measurements.frames["header"] = $0
          }
          Text("Content below the controls")
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
              measurements.frames["below"] = $0
            }
        }
        .padding(60)
      }
    }
    .environment(\.multiviewLineup, lineup)
  }
}

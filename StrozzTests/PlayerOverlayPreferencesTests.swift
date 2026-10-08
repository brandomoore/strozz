import XCTest
@testable import Strozz

@MainActor
final class PlayerOverlayPreferencesTests: XCTestCase {
  func testStreamDurationDefaultsOnAndPersistsIndependently() {
    let defaults = UserDefaults.standard
    let key = PersistenceKey.showStreamDuration
    let saved = defaults.object(forKey: key)
    defer {
      if let saved { defaults.set(saved, forKey: key) }
      else { defaults.removeObject(forKey: key) }
    }
    defaults.removeObject(forKey: key)
    let first = PlayerView(channel: "fixture", auth: TwitchAuthSession())
    XCTAssertTrue(first.showStreamDuration)
    let viewerCount = first.showViewerCount
    first.showStreamDuration = false
    let reopened = PlayerView(channel: "fixture", auth: TwitchAuthSession())
    XCTAssertFalse(reopened.showStreamDuration)
    XCTAssertEqual(reopened.showViewerCount, viewerCount)
  }

  func testNativeMenuEqualityIncludesStreamDurationVisibility() {
    XCTAssertEqual(menu(duration: true), menu(duration: true))
    XCTAssertNotEqual(menu(duration: true), menu(duration: false))
  }

  private func menu(duration: Bool) -> QualityMenu {
    QualityMenu(
      options: ["Auto"], selectedOption: "Auto", engineStatus: nil, buttonLabel: "Auto",
      reservedWidthLabels: ["Auto"], displayLabel: { $0 }, onSelect: { _ in },
      onMenuPresented: {}, onMenuDismissed: {},
      sourceAvailable: false, sourceOptions: [], sourceSelectedIndex: 0, onSelectSource: { _ in },
      sleepOptions: ["Off"], sleepSelectedIndex: 0, sleepIsArmed: false, onSelectSleep: { _ in },
      rewindEnabled: true, onToggleRewind: {}, viewerCountEnabled: true, onToggleViewerCount: {},
      streamDurationEnabled: duration, onToggleStreamDuration: {},
      captionsSupported: false, captionsEnabled: false, onToggleCaptions: {}, onOpenCaptionOptions: {},
      latencyBadgeEnabled: false, onToggleLatencyBadge: {}, diagnosticsEnabled: false, onToggleDiagnostics: {},
      prefetchProxyEnabled: true, onTogglePrefetchProxy: {}, onSimulateOutgoingRaid: {},
      onSimulateIncomingRaid: {}, onSimulateOffline: {}, onSimulateMoment: {}, onSimulateGoLive: {})
  }
}

import Foundation
import Sentry
import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class PlaybackTelemetrySentryTests: XCTestCase {
  func testSDKEventScrubbingRemovesViewerRequestAndUncontrolledBreadcrumbs() {
    let event = Event(level: .error)
    let viewer = User(userId: "private-viewer")
    viewer.email = "viewer@example.com"
    event.user = viewer
    let request = SentryRequest()
    request.headers = ["Authorization": "Bearer private-token"]
    event.request = request
    event.context = [
      "device": ["name": "Private TV", "id": "private-device", "model": "AppleTV"],
      "app": ["device_app_hash": "private-installation", "app_id": "private-id", "view_names": ["private-view"]],
      "culture": ["timezone": "private-timezone"],
    ]
    event.tags = ["app.device": "private-installation"]
    let network = Breadcrumb(level: .error, category: "http")
    network.message = "https://example.test/?token=private-token"
    event.breadcrumbs = [network, Breadcrumb(level: .info, category: "strozz.playback")]
    let sanitized = PlaybackTelemetrySentry.scrub(event)
    XCTAssertNil(sanitized.user)
    XCTAssertNil(sanitized.request)
    XCTAssertNil(sanitized.context?["device"]?["name"])
    XCTAssertNil(sanitized.context?["device"]?["id"])
    XCTAssertEqual(sanitized.context?["device"]?["model"] as? String, "AppleTV")
    XCTAssertNil(sanitized.context?["app"]?["device_app_hash"])
    XCTAssertNil(sanitized.context?["app"]?["app_id"])
    XCTAssertNil(sanitized.context?["app"]?["view_names"])
    XCTAssertNil(sanitized.context?["culture"])
    XCTAssertNil(sanitized.tags?["app.device"])
    XCTAssertEqual(sanitized.breadcrumbs?.map(\.category), ["strozz.playback"])
  }

  func testOptInSyntheticDeliveryToDedicatedStrozzProject() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_SENTRY_VERIFICATION"] == "1" else {
      throw XCTSkip("Requires an explicitly requested Sentry delivery verification")
    }
    PlaybackTelemetrySentry.start()
    XCTAssertTrue(SentrySDK.isEnabled)
    XCTAssertEqual(PlaybackTelemetrySentry.projectID, "4512286970675200")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorders = (0..<8).map { pane in
      PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
        directory: directory.appendingPathComponent("pane-\(pane)"), mirrorToSystemLog: false))
    }
    for (pane, recorder) in recorders.enumerated() {
      recorder.beginSession(channel: "diagnostics_fixture_\(pane)", playbackMode: "verification")
    }
    let sessions = try recorders.map { try XCTUnwrap($0.sessionID) }
    XCTAssertEqual(Set(sessions).count, 8)
    for (pane, recorder) in recorders.enumerated() {
      recorder.recordEvent("sentry_delivery_verification", level: .error,
        attributes: ["reason": "Synthetic playback diagnostic delivery verification"],
        metrics: ["buffer_ahead_seconds": 3], counters: ["fixture_panes": 8, "fixture_pane": pane])
      recorder.endSession(reason: "verification_complete")
    }
    for recorder in recorders { await recorder.flush() }
    await Task.detached(priority: .utility) { SentrySDK.flush(timeout: 10) }.value
    print("SENTRY_DELIVERY_SESSIONS=\(sessions.joined(separator: ","))")
  }
}

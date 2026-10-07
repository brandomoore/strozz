import XCTest
import SwiftUI
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class BroadcastUptimeTests: XCTestCase {
  func testUptimeUsesBroadcastStartAndWholeMinutes() {
    let start = Date(timeIntervalSince1970: 1000)
    XCTAssertEqual(BroadcastUptime.duration(since: start, now: start.addingTimeInterval(59)), .seconds(0))
    XCTAssertEqual(BroadcastUptime.duration(since: start, now: start.addingTimeInterval(60)), .seconds(60))
    XCTAssertEqual(BroadcastUptime.duration(since: start, now: start.addingTimeInterval(8_099)), .seconds(8_040))
    XCTAssertEqual(BroadcastUptime.duration(since: start, now: start.addingTimeInterval(93_600)), .seconds(93_600))
    XCTAssertNil(BroadcastUptime.duration(since: start, now: start.addingTimeInterval(-1)))
  }

  func testMetadataUsesStreamCreationNotAccountCreation() throws {
    let data = Data("""
      {"data":{"user":{"displayName":"Example","createdAt":"2014-01-01T00:00:00Z",
      "stream":{"title":"A live broadcast","viewersCount":42,"createdAt":"2026-10-07T10:00:00.123Z"}}}}
      """.utf8)
    let metadata = try XCTUnwrap(PlaybackService.parseChannelMetadata(data, for: "example"))
    let expected = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-10-07T10:00:00.123Z")
    XCTAssertEqual(try XCTUnwrap(metadata.streamStartedAt).timeIntervalSince(expected), 0, accuracy: 0.001)
    XCTAssertEqual(metadata.viewersCount, 42)
    XCTAssertEqual(metadata.title, "A live broadcast")
  }

  func testPlainDatesAreAcceptedAndUnknownOfflineDatesAreNotInvented() throws {
    let online = Data(#"{"data":{"user":{"stream":{"createdAt":"2026-10-07T10:00:00Z"}}}}"#.utf8)
    XCTAssertNotNil(try XCTUnwrap(PlaybackService.parseChannelMetadata(online, for: "example")).streamStartedAt)
    for payload in [
      #"{"data":{"user":{"stream":null}}}"#,
      #"{"data":{"user":{"stream":{"createdAt":"not a date"}}}}"#,
      #"{"data":{"user":{"stream":{}}}}"#,
    ] {
      XCTAssertNil(try XCTUnwrap(PlaybackService.parseChannelMetadata(Data(payload.utf8), for: "example")).streamStartedAt)
    }
    let failed = Data(#"{"errors":[{"message":"unavailable"}],"data":{"user":{"stream":{}}}}"#.utf8)
    XCTAssertNil(PlaybackService.parseChannelMetadata(failed, for: "example"))
  }

  @MainActor
  func testUptimeRendersWithStreamStatisticsAcrossThemes() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    for theme in AppTheme.allCases {
      let palette = theme.palette(systemColorScheme: .light)
      let content = VStack(alignment: .leading, spacing: 12) {
        Text("Stream information").font(.headline)
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          Text("2,374 watching")
          BroadcastUptimeView(startedAt: Date().addingTimeInterval(-8_040))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.chatSideSurface)
      .preferredColorScheme(theme.preferredColorScheme)
      let host = UIHostingController(rootView: content)
      window.rootViewController = host
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = "Broadcast uptime \(theme.rawValue)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }
}

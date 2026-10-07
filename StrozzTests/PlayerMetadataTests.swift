import XCTest

@testable import Strozz

@MainActor
final class PlayerMetadataTests: XCTestCase {
  func testMetadataArrivingBeforeDelayedSourceSelectionSurvivesPlaybackLoad() {
    let model = PlayerModel()
    model.activeChannel = "example"
    model.channelDisplayName = "Example"
    model.streamTitle = "Today's live broadcast"
    model.channelAvatarURL = URL(string: "https://example.com/avatar.png")
    model.channelStreamStartedAt = Date(timeIntervalSince1970: 1000)
    model.errorMessage = "Previous load failed"
    model.isOffline = true
    model.isLoading = false

    model.beginPlaybackLoad()

    XCTAssertEqual(model.streamTitle, "Today's live broadcast")
    XCTAssertEqual(model.channelDisplayName, "Example")
    XCTAssertEqual(model.channelAvatarURL, URL(string: "https://example.com/avatar.png"))
    XCTAssertEqual(model.channelStreamStartedAt, Date(timeIntervalSince1970: 1000))
    XCTAssertTrue(model.isLoading)
    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.isOffline)
  }

  func testMetadataArrivingAfterPlaybackLoadSurvivesYouTubeFallbackAndRetries() {
    let model = PlayerModel()
    model.activeChannel = "example"
    model.beginPlaybackLoad()
    XCTAssertTrue(model.streamTitle.isEmpty)

    model.isUsingAltSource = true
    model.streamTitle = "The actual stream title"
    model.channelDisplayName = "Example"
    model.isLoading = false

    model.isUsingAltSource = false
    model.beginPlaybackLoad()
    XCTAssertEqual(model.streamTitle, "The actual stream title")
    model.isLoading = false
    model.beginPlaybackLoad()
    XCTAssertEqual(model.streamTitle, "The actual stream title")
    XCTAssertEqual(model.channelDisplayName, "Example")
  }

  func testNewPlayerDoesNotInheritPreviousChannelMetadata() {
    let model = PlayerModel()
    model.beginPlaybackLoad()
    XCTAssertTrue(model.streamTitle.isEmpty)
    XCTAssertTrue(model.channelDisplayName.isEmpty)
    XCTAssertNil(model.channelAvatarURL)
    XCTAssertNil(model.channelStreamStartedAt)
  }

  func testReloadPreservesBroadcastTitleDuringRewindHandoff() {
    let model = PlayerModel()
    model.streamTitle = "Recorded broadcast title"
    model.beginPlaybackLoad()
    XCTAssertEqual(model.streamTitle, "Recorded broadcast title")
  }
}

import XCTest
@testable import Strozz

@MainActor
final class HomeFollowingFocusTests: XCTestCase {
  func testRemovedFollowingCardKeepsFocusInItsLoadingSection() {
    XCTAssertEqual(HomeFollowingFocus.replacement(focused: "following-second",
      previous: ["first", "second"], current: [], isLoading: true), HomeFollowingFocus.status)
  }

  func testRemovedFollowingCardMovesToRecoveryInsteadOfRecommendations() {
    XCTAssertEqual(HomeFollowingFocus.replacement(focused: "following-second",
      previous: ["first", "second"], current: [], isLoading: false), HomeFollowingFocus.retry)
  }

  func testSurvivingFollowingCardKeepsItsIdentity() {
    XCTAssertNil(HomeFollowingFocus.replacement(focused: "following-second",
      previous: ["first", "second"], current: ["second", "third"], isLoading: false))
  }

  func testRemovedCardChoosesTheNearestRemainingFollowingCard() {
    XCTAssertEqual(HomeFollowingFocus.replacement(focused: "following-second",
      previous: ["first", "second", "third"], current: ["first", "third"], isLoading: false),
      "following-third")
  }

  func testBackgroundFailureDoesNotStealRecommendedOrHeaderFocus() {
    for focus in ["recommended-first", HomeFollowingFocus.refresh, HomeFollowingFocus.directory] {
      XCTAssertNil(HomeFollowingFocus.replacement(focused: focus,
        previous: ["first", "second"], current: [], isLoading: false))
    }
    XCTAssertNil(HomeFollowingFocus.replacement(focused: nil,
      previous: ["first"], current: [], isLoading: false))
  }

  func testRefreshCompletionNeverReportsSuccessForAnError() {
    XCTAssertEqual(RefreshToastState.finished(hadError: true), .failed)
    XCTAssertEqual(RefreshToastState.finished(hadError: false), .done)
  }
}

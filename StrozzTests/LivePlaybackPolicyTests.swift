import XCTest
@testable import Strozz

final class LivePlaybackPolicyTests: XCTestCase {
  func testNativeIsTheOnlySelectableLiveProfile() {
    XCTAssertEqual(LivePlaybackProfile.allCases, [.nativeLowLatency])
    XCTAssertEqual(LivePlaybackProfile.default, .nativeLowLatency)
    XCTAssertEqual(LivePlaybackProfile.nativeLowLatency.pickerLabel, "Auto · Native Low Latency")
  }

  func testSavedLegacyAndUnknownProfilesRestoreAsNative() {
    for raw in ["lowerLatency", "higherQuality", "unknown", "nativeLowLatency"] {
      XCTAssertEqual(LivePlaybackProfile.restored(rawValue: raw), .nativeLowLatency)
    }
    XCTAssertNil(LivePlaybackProfile(rawValue: "lowerLatency"))
    XCTAssertNil(LivePlaybackProfile(rawValue: "higherQuality"))
  }

  func testNativeKeepsItsBufferAndOwnsPlaybackRate() {
    let policy = LivePlaybackPolicy.live(profile: .nativeLowLatency, isPinned: false)
    XCTAssertEqual(policy.preferredForwardBufferDuration, 3)
    XCTAssertFalse(policy.enablesGentleCatchUp)
    XCTAssertEqual(policy.minPlaybackRate, 1)
    XCTAssertEqual(policy.maxCatchUpRate, 1)
  }

  func testNativePinnedAndAdaptiveVideoUseTheSamePolicy() {
    XCTAssertEqual(
      LivePlaybackPolicy.live(profile: .nativeLowLatency, isPinned: true),
      LivePlaybackPolicy.live(profile: .nativeLowLatency, isPinned: false))
  }

  func testExplicitStandardTransportPreservesItsExistingPolicy() {
    let policy = LivePlaybackPolicy.standard(isPinned: false)
    XCTAssertEqual(policy.preferredForwardBufferDuration, 3)
    XCTAssertTrue(policy.enablesGentleCatchUp)
    XCTAssertEqual(policy.catchUpThresholdSeconds, 2)
    XCTAssertEqual(policy.maxCatchUpRate, 1.12, accuracy: 0.0001)
    XCTAssertEqual(policy.minPlaybackRate, 0.90, accuracy: 0.0001)
    XCTAssertGreaterThan(policy.catchUpHealthyBufferSeconds, policy.slowdownBufferFloorSeconds)
  }

  func testExplicitPinnedStandardTransportDoesNotChangeRate() {
    let policy = LivePlaybackPolicy.standard(isPinned: true)
    XCTAssertEqual(policy.preferredForwardBufferDuration, 8)
    XCTAssertFalse(policy.enablesGentleCatchUp)
    XCTAssertEqual(policy.minPlaybackRate, 1)
    XCTAssertEqual(policy.maxCatchUpRate, 1)
  }

  func testNativeDoesNotDependOnTheLegacyProxyPreference() {
    XCTAssertTrue(LivePlaybackProfile.nativeLowLatency.requestsNativePlayback)
    XCTAssertTrue(LivePlaybackProfile.nativeLowLatency.promotesPrefetch(legacyEnabled: false, unstable: false))
    XCTAssertFalse(LivePlaybackProfile.nativeLowLatency.promotesPrefetch(legacyEnabled: true, unstable: true))
  }
}

import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeAdaptiveRenditionPolicyTests: XCTestCase {
  private var variants: [NativeAdaptiveRenditionPolicy.Variant] {
    [
      .init(id: 0, bitrate: 230_000, width: 284, height: 160),
      .init(id: 1, bitrate: 630_000, width: 640, height: 360),
      .init(id: 2, bitrate: 1_427_999, width: 852, height: 480),
      .init(id: 3, bitrate: 3_422_999, width: 1280, height: 720),
      .init(id: 4, bitrate: 9_000_000, width: 1920, height: 1080),
    ]
  }

  private func record(_ mbps: Double, policy: inout NativeAdaptiveRenditionPolicy,
                      at now: TimeInterval) throws {
    XCTAssertTrue(try policy.recordCompletedTransfer(bytes: 65_536,
      seconds: Double(65_536 * 8) / (mbps * 1_000_000), at: now))
  }

  func testStartupUsesMeasuredCapacityAndRetainsEveryQuality() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    XCTAssertEqual(try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 0).variant.id, 2)
    try record(20, policy: &policy, at: 1)
    let full = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 1)
    XCTAssertEqual(full.variant.id, 4)
    XCTAssertEqual(full.reason, .measuredCapacity)
    XCTAssertEqual(policy.variants.count, 5)
  }

  func testCapacitySweepCanSelectEveryQualityRatherThanPinningSource() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    var now = 0.0
    var selected = Set<Int>()
    for (capacity, expected) in [(0.4, 0), (1.0, 1), (2.2, 2), (5.0, 3), (20.0, 4)] {
      for _ in 0..<30 {
        now += 2
        try record(capacity, policy: &policy, at: now)
        _ = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: now)
      }
      XCTAssertEqual(policy.selected?.id, expected)
      if let id = policy.selected?.id { selected.insert(id) }
    }
    XCTAssertEqual(selected, Set(variants.map(\.id)))
  }

  func testHealthyCapacityDoesNotCycleAwayFromSustainedSource() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    try record(20, policy: &policy, at: 0)
    _ = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 0)
    for tick in 1...100 {
      try record([17.0, 24.0, 18.0, 21.0, 20.0][tick % 5], policy: &policy, at: Double(tick))
      let result = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: Double(tick))
      XCTAssertEqual(result.variant.id, 4)
      XCTAssertFalse(result.changed)
    }
  }

  func testOneBadSampleDownshiftsButRepeatedPollingCannotCascadeThroughQualities() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    try record(20, policy: &policy, at: 0)
    _ = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 0)
    try record(1, policy: &policy, at: 1)
    for tick in 0...10 {
      let result = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 1 + Double(tick) / 10)
      XCTAssertEqual(result.variant.id, 1)
    }
    try record(1, policy: &policy, at: 3)
    let result = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 3)
    XCTAssertEqual(result.variant.id, 1)
    XCTAssertFalse(result.changed)
  }

  func testLateDeliveryCanDownshiftImmediatelyWithoutWaitingForAnotherProbe() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    try record(20, policy: &policy, at: 0)
    _ = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 0)
    try record(1, policy: &policy, at: 5)
    let result = try policy.select(budget: .init(), buffer: 0.5, deliveryLate: true, at: 5)
    XCTAssertEqual(result.variant.id, 1)
    XCTAssertEqual(result.reason, .lateDelivery)
    let pending = try policy.select(budget: .init(), buffer: 0.5, deliveryLate: true, at: 5.01)
    XCTAssertEqual(pending.variant.id, 1, "Old-renderer feedback must not punish the just-requested quality again")
  }

  func testDownshiftPreservesTheCapacityReserveBeforeSelectedBitrateBecomesUnsustainable() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    try record(20, policy: &policy, at: 0)
    _ = try policy.select(budget: .init(), buffer: 2.5, deliveryLate: false, at: 0)
    try record(11, policy: &policy, at: 2)
    XCTAssertEqual(try policy.select(budget: .init(), buffer: 2.5, deliveryLate: false, at: 2).variant.id, 3)
    try record(11, policy: &policy, at: 4)
    XCTAssertEqual(try policy.select(budget: .init(), buffer: 2.5, deliveryLate: false, at: 4).variant.id, 3)
  }

  func testLowReserveActsOnOneActualCapacitySampleInsteadOfWaitingUntilBufferIsAlmostEmpty() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    try record(20, policy: &policy, at: 0)
    _ = try policy.select(budget: .init(), buffer: 2.5, deliveryLate: false, at: 0)
    try record(2, policy: &policy, at: 2)
    XCTAssertEqual(try policy.select(budget: .init(), buffer: 1.4, deliveryLate: false, at: 2).variant.id, 2)
  }

  func testMultiviewBudgetChangesAreImmediateButExpansionUpgradeNeedsFreshEvidence() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    try record(20, policy: &policy, at: 0)
    _ = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 0)
    let thumbnail = NativeAdaptiveRenditionPolicy.Budget(
      maximumWidth: 854, maximumHeight: 480, maximumBitrate: 800_000)
    XCTAssertEqual(try policy.select(budget: thumbnail, buffer: 1.5, deliveryLate: false, at: 1).variant.id, 1)
    try record(20, policy: &policy, at: 2)
    XCTAssertEqual(try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 2).variant.id, 1)
    XCTAssertEqual(try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 6).variant.id, 1)
    try record(20, policy: &policy, at: 7)
    XCTAssertEqual(try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 7).variant.id, 4)
  }

  func testStaleCapacityCannotTriggerUpgradeAndLateDeliveryStillHasAnEscape() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    try record(20, policy: &policy, at: 0)
    _ = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 0)
    let stable = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 20)
    XCTAssertEqual(stable.variant.id, 4)
    let lower = try policy.select(budget: .init(), buffer: 0.5, deliveryLate: true, at: 21)
    XCTAssertEqual(lower.variant.id, 3)
  }

  func testLiveBufferOscillationIsNotNetworkFailureAndDoesNotCauseQualityCycling() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    try record(20, policy: &policy, at: 0)
    _ = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 0)
    for tick in 1...20 {
      try record(20, policy: &policy, at: Double(tick))
      let selection = try policy.select(budget: .init(), buffer: tick.isMultiple(of: 2) ? 0.4 : 1.5,
        deliveryLate: false, at: Double(tick))
      XCTAssertEqual(selection.variant.id, 4)
      XCTAssertFalse(selection.changed)
    }
  }

  func testStrongCapacityCanUpgradeWithOneLivePartInsteadOfWaitingForAnUnreachableBuffer() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    let budget = NativeAdaptiveRenditionPolicy.Budget(
      maximumWidth: 854, maximumHeight: 480, maximumBitrate: 800_000)
    try record(20, policy: &policy, at: 0)
    XCTAssertEqual(try policy.select(budget: budget, buffer: 1.5, deliveryLate: false, at: 0).variant.id, 1)
    try record(20, policy: &policy, at: 2)
    _ = try policy.select(budget: .init(), buffer: 0.4, deliveryLate: false, at: 2)
    try record(20, policy: &policy, at: 6)
    XCTAssertEqual(try policy.select(budget: .init(), buffer: 0.4, deliveryLate: false, at: 6).variant.id, 4)
  }

  func testInvalidInputAndUnsupportedBudgetsFailExplicitly() throws {
    XCTAssertThrowsError(try NativeAdaptiveRenditionPolicy(variants: []))
    XCTAssertThrowsError(try NativeAdaptiveRenditionPolicy(variants: [variants[0], variants[0]]))
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    XCTAssertThrowsError(try policy.recordCompletedTransfer(bytes: 0, seconds: 1, at: 0))
    XCTAssertThrowsError(try policy.recordCompletedTransfer(bytes: 65_536, seconds: 0, at: 0))
    try record(20, policy: &policy, at: 2)
    XCTAssertThrowsError(try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 1))
    XCTAssertThrowsError(try policy.recordCompletedTransfer(bytes: 65_536, seconds: 1, at: 1))
    XCTAssertThrowsError(try policy.select(budget: .init(), buffer: .nan, deliveryLate: false, at: 3))
    XCTAssertThrowsError(try policy.select(budget: .init(maximumWidth: 1), buffer: 1.5, deliveryLate: false, at: 3))
  }

  func testUpstreamFormatChangeRetainsCapacityAndIdentityButRefreshesBudgetEligibility() throws {
    var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
    try record(20, policy: &policy, at: 0)
    _ = try policy.select(budget: .init(), buffer: 1.5, deliveryLate: false, at: 0)
    let changed = variants.map {
      NativeAdaptiveRenditionPolicy.Variant(id: $0.id, bitrate: $0.bitrate, width: 640, height: 360)
    }
    try policy.updateFormats(changed)
    XCTAssertEqual(policy.selected?.id, 4)
    XCTAssertEqual(policy.selected?.height, 360)
    XCTAssertEqual(try XCTUnwrap(policy.capacity), 20_000_000, accuracy: 0.01)
    XCTAssertThrowsError(try policy.updateFormats(Array(changed.dropLast())))
  }
}

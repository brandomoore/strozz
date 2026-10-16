import Foundation

struct NativeAdaptiveRenditionPolicy: Sendable {
  struct Variant: Equatable, Sendable {
    let id: Int
    let bitrate: Int
    let width: Int
    let height: Int
  }

  struct Budget: Equatable, Sendable {
    var maximumWidth = 0
    var maximumHeight = 0
    var maximumBitrate = 0

    func allows(_ variant: Variant) -> Bool {
      (maximumWidth == 0 || variant.width <= maximumWidth)
        && (maximumHeight == 0 || variant.height <= maximumHeight)
        && (maximumBitrate == 0 || variant.bitrate <= maximumBitrate)
    }
  }

  enum Reason: String, Sendable {
    case startup, measuredCapacity, budget, lateDelivery, retained
  }

  struct Selection: Sendable {
    let variant: Variant
    let changed: Bool
    let reason: Reason
  }

  private(set) var variants: [Variant]
  private(set) var selected: Variant?
  private(set) var capacity: Double?
  private var fastCapacity: Double?
  private var slowCapacity: Double?
  private var lastSampleAt: TimeInterval?
  private var sampleSerial = 0
  private var evaluatedSampleSerial = 0
  private var lastSelectionAt: TimeInterval?
  private var lastEvaluationAt: TimeInterval?
  private var lastBudget = Budget()
  private var usedMeasuredCapacity = false
  private var upgradeCandidate: Int?
  private var upgradeVotes = 0

  init(variants: [Variant]) throws {
    guard !variants.isEmpty, Set(variants.map(\.id)).count == variants.count,
      variants.allSatisfy({ $0.bitrate > 0 && $0.width > 0 && $0.height > 0 }) else {
      throw NativeHLSError.unsupported
    }
    self.variants = variants.sorted {
      if $0.bitrate != $1.bitrate { return $0.bitrate < $1.bitrate }
      return $0.id < $1.id
    }
  }

  mutating func updateFormats(_ values: [Variant]) throws {
    let checked = try Self(variants: values)
    guard Set(values.map(\.id)) == Set(variants.map(\.id)) else { throw NativeHLSError.transition }
    variants = checked.variants
    if let selected {
      self.selected = variants.first(where: { $0.id == selected.id })
    }
    upgradeCandidate = nil
    upgradeVotes = 0
  }

  /// Only completed upstream media transfers qualify; loopback delivery and
  /// encoder-paced prefetch bodies are not measurements of available bandwidth.
  @discardableResult
  mutating func recordCompletedTransfer(bytes: Int, seconds: TimeInterval, at now: TimeInterval) throws -> Bool {
    guard bytes > 0, seconds.isFinite, seconds > 0, now.isFinite,
      lastSampleAt.map({ now >= $0 }) ?? true else { throw NativeHLSError.invalidMedia }
    guard bytes >= 16 * 1024 else { return false }
    let measured = Double(bytes) * 8 / seconds
    guard measured.isFinite, measured > 0 else { throw NativeHLSError.invalidMedia }
    if let fastCapacity, let slowCapacity {
      self.fastCapacity = measured < fastCapacity ? measured : fastCapacity * 0.5 + measured * 0.5
      self.slowCapacity = slowCapacity * 0.85 + measured * 0.15
    } else {
      fastCapacity = measured
      slowCapacity = measured
    }
    capacity = min(fastCapacity ?? measured, slowCapacity ?? measured)
    lastSampleAt = now
    sampleSerial += 1
    return true
  }

  mutating func select(budget: Budget, buffer: TimeInterval, deliveryLate: Bool,
                       at now: TimeInterval) throws -> Selection {
    guard buffer.isFinite, buffer >= 0, now.isFinite,
      budget.maximumWidth >= 0, budget.maximumHeight >= 0, budget.maximumBitrate >= 0,
      lastSampleAt.map({ now >= $0 }) ?? true,
      lastEvaluationAt.map({ now >= $0 }) ?? true else { throw NativeHLSError.invalidMedia }
    lastEvaluationAt = now
    let eligible = variants.filter { budget.allows($0) }
    guard let lowest = eligible.first else { throw NativeHLSError.unsupported }
    let freshSample = evaluatedSampleSerial != sampleSerial
    evaluatedSampleSerial = sampleSerial
    let freshCapacity = lastSampleAt.map { now - $0 <= 10 } == true ? capacity : nil
    let proposed = freshCapacity.flatMap { capacity in
      eligible.last(where: { Double($0.bitrate) <= capacity * 0.75 })
    } ?? lowest
    let previousBudget = lastBudget
    lastBudget = budget

    func selection(_ variant: Variant, _ reason: Reason, changed: Bool) -> Selection {
      Selection(variant: variant, changed: changed, reason: reason)
    }
    guard let selected else {
      let initial = freshCapacity == nil ? (eligible.last(where: { $0.bitrate <= 3_000_000 }) ?? lowest) : proposed
      self.selected = initial
      usedMeasuredCapacity = freshCapacity != nil
      lastSelectionAt = now
      return selection(initial, .startup, changed: true)
    }
    var next = selected
    var reason = Reason.retained
    if !budget.allows(selected) {
      next = freshCapacity == nil ? (eligible.last ?? lowest) : proposed
      reason = .budget
    } else if !usedMeasuredCapacity, freshCapacity != nil {
      next = proposed
      reason = .measuredCapacity
      usedMeasuredCapacity = true
    } else if deliveryLate, now - (lastSelectionAt ?? now) >= 4 {
      next = freshCapacity == nil
        ? (eligible.last(where: { $0.bitrate < selected.bitrate }) ?? lowest)
        : (proposed.bitrate < selected.bitrate ? proposed
           : eligible.last(where: { $0.bitrate < selected.bitrate }) ?? lowest)
      reason = .lateDelivery
    } else if proposed.bitrate > selected.bitrate, freshCapacity != nil {
      if previousBudget != budget { upgradeCandidate = nil; upgradeVotes = 0 }
      if freshSample {
        if upgradeCandidate == proposed.id { upgradeVotes += 1 }
        else { upgradeCandidate = proposed.id; upgradeVotes = 1 }
      }
      let hasHeadroom = buffer >= 1 || (buffer >= 0.35 && (freshCapacity ?? 0) >= Double(proposed.bitrate) * 1.5)
      if upgradeVotes >= 2, hasHeadroom, now - (lastSelectionAt ?? now) >= 5 {
        next = proposed
        reason = .measuredCapacity
      }
    } else if freshSample, freshCapacity != nil, proposed.bitrate < selected.bitrate {
      next = proposed
      reason = .measuredCapacity
    } else {
      upgradeCandidate = nil
      upgradeVotes = 0
    }
    if next.id != selected.id {
      self.selected = next
      lastSelectionAt = now
      upgradeCandidate = nil
      upgradeVotes = 0
      return selection(next, reason, changed: true)
    }
    return selection(selected, .retained, changed: false)
  }
}

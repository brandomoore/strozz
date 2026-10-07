struct LivePlaybackPosition: Equatable {
  enum State: Equatable {
    case checking
    case live
    case behind(seconds: Double)
    case paused
  }

  private(set) var state: State = .checking

  mutating func observe(extraDelay: Double?) {
    guard let extraDelay, extraDelay.isFinite else {
      state = .checking
      return
    }
    let wasBehind: Bool
    if case .behind = state { wasBehind = true } else { wasBehind = false }
    let behind = wasBehind
      ? extraDelay > NativeLiveCatchUp.startupToleranceSeconds
      : extraDelay >= NativeLiveCatchUp.minimumExcessSeconds
    state = behind ? .behind(seconds: max(1, extraDelay.rounded())) : .live
  }
}

enum PlaybackPresentationState: Equatable {
  case loading
  case ready
  case unavailable

  init(isLoading: Bool, awaitingVideo: Bool = false, isUnavailable: Bool) {
    if isUnavailable { self = .unavailable }
    else if isLoading || awaitingVideo { self = .loading }
    else { self = .ready }
  }
}

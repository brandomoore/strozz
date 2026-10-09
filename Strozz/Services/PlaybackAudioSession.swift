import AVFoundation

@MainActor
enum PlaybackAudioSession {
  static let audiblePlayerActivated = Notification.Name("StrozzAudiblePlayerActivated")

  static func isMediaServicesReset(_ error: Error?) -> Bool {
    guard let error = error as NSError? else { return false }
    return error.domain == AVFoundationErrorDomain && error.code == AVError.mediaServicesWereReset.rawValue
  }

  static func activate() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .moviePlayback)
    try session.setActive(true)
  }
}

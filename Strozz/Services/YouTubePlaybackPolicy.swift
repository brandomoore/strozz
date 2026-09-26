import AVFoundation

enum YouTubePlaybackPolicy {
  static let forwardBufferSeconds: TimeInterval = 8

  static func liveOffsetSeconds(isRecovery: Bool) -> TimeInterval {
    isRecovery ? 8 : 6
  }

  static func makeItem(url: URL, isRecovery: Bool = false) -> AVPlayerItem {
    let asset = AVURLAsset(
      url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": AltSourceService.mediaHTTPHeaders])
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = forwardBufferSeconds
    // A buffer preference cannot create media ahead of the live edge. Start
    // with a small real margin; only a recovery attempt gets two more seconds.
    item.configuredTimeOffsetFromLive = CMTime(
      seconds: liveOffsetSeconds(isRecovery: isRecovery), preferredTimescale: 600)
    // Let a native buffering wait add headroom instead of seeking it away.
    item.automaticallyPreservesTimeOffsetFromLive = false
    return item
  }
}

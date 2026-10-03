import AVFoundation
import CoreImage
import Foundation

// Link the shipping proxy without importing the application's unrelated services.
enum PersistenceKey {
  static let lowLatencyProxyEnabled = "probe.unused.proxy"
  static let streamRewindEnabled = "probe.unused.rewind"
}

enum PlaybackError: Error {
  case http(Int)
  case badResponse
}

struct ProbeConfiguration: Decodable {
  let baseline: URL
  let candidate: URL
  let headers: [String: String]
  let seconds: Int
}

@MainActor
final class ProbePlayer {
  let player: AVPlayer
  let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
  let context = CIContext(options: [.cacheIntermediates: false])
  let policy = LivePlaybackPolicy.live(profile: .lowerLatency, isPinned: false)
  let isBaseline: Bool
  private var lastClock: Double?
  private var advancingSamples = 0

  init(url: URL, headers: [String: String], proxy: LowLatencyHLSProxy? = nil) {
    isBaseline = proxy != nil
    let asset = AVURLAsset(
      url: proxy?.proxyURL(for: url) ?? url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    if let proxy {
      asset.resourceLoader.setDelegate(proxy, queue: proxy.callbackQueue)
    }
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = policy.preferredForwardBufferDuration
    item.audioTimePitchAlgorithm = .timeDomain
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    item.add(output)
    player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    player.isMuted = true
  }

  func sample() -> [String: Any] {
    guard let item = player.currentItem else { return ["error": "Missing player item"] }
    let clock = item.currentTime().seconds
    var row: [String: Any] = [
      "state": player.timeControlStatus == .playing ? "playing"
        : (player.timeControlStatus == .paused ? "paused" : "waiting"),
      "rate": player.rate,
    ]
    if clock.isFinite { row["clock"] = clock }
    if let error = item.error as NSError? {
      row["error"] = "\(error.domain):\(error.code)"
      if !isBaseline {
        row["error_detail"] = error.localizedDescription
        row["error_comments"] = item.errorLog()?.events.map(\.errorComment).compactMap { $0 } ?? []
      }
    }
    var buffer: Double?
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      if clock >= range.start.seconds, clock <= range.end.seconds {
        buffer = max(0, range.end.seconds - clock)
      }
    }
    row["buffer"] = buffer
    let end = item.seekableTimeRanges.last?.timeRangeValue.end.seconds
    let gap = end.flatMap { $0.isFinite && clock.isFinite ? max(0, $0 - clock) : nil }
    row["edge_gap"] = gap
    let offset = item.configuredTimeOffsetFromLive.seconds
    if offset.isFinite { row["configured_live_offset"] = offset }
    if let date = item.currentDate() {
      row["program_date_age"] = Date().timeIntervalSince(date)
    }
    if output.hasNewPixelBuffer(forItemTime: item.currentTime()),
      let pixelBuffer = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) {
      let image = CIImage(cvPixelBuffer: pixelBuffer)
      let scaled = image.transformed(by: CGAffineTransform(
        scaleX: 16 / image.extent.width, y: 9 / image.extent.height))
      var pixels = [UInt8](repeating: 0, count: 16 * 9)
      context.render(scaled, toBitmap: &pixels, rowBytes: 16,
        bounds: CGRect(x: 0, y: 0, width: 16, height: 9),
        format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
      row["fingerprint"] = Data(pixels).base64EncodedString()
    }
    if let lastClock, clock > lastClock, clock - lastClock < 0.5 {
      advancingSamples += 1
    }
    lastClock = clock
    // Reproduce the live policy's two rate arms, without app recovery or DVR seeks.
    if isBaseline, advancingSamples >= 3, player.timeControlStatus == .playing {
      var rate: Float = 1
      if let buffer, buffer < policy.slowdownBufferFloorSeconds {
        let fraction = Float(max(0, buffer / policy.slowdownBufferFloorSeconds))
        rate = policy.minPlaybackRate + (1 - policy.minPlaybackRate) * fraction
      } else if let buffer, let gap, buffer > policy.catchUpHealthyBufferSeconds,
        gap > policy.catchUpThresholdSeconds {
        rate = min(policy.maxCatchUpRate,
          1 + policy.catchUpRampPerSecond * Float(gap - policy.catchUpThresholdSeconds))
      }
      if abs(player.rate - rate) > 0.01 { player.rate = rate }
    }
    return row
  }
}

@main
struct LLHLSPlayerProbe {
  @MainActor
  static func main() async {
    do {
      let config = try JSONDecoder().decode(
        ProbeConfiguration.self, from: FileHandle.standardInput.readDataToEndOfFile())
      let proxy = LowLatencyHLSProxy(headers: config.headers)
      proxy.configure(promotePrefetch: true, retainHistory: true, windowSeconds: 1800)
      let baseline = ProbePlayer(url: config.baseline, headers: config.headers, proxy: proxy)
      let candidate = ProbePlayer(url: config.candidate, headers: [:])
      defer {
        for probe in [baseline, candidate] {
          probe.player.pause()
          probe.player.replaceCurrentItem(with: nil)
        }
      }
      let start = ProcessInfo.processInfo.systemUptime
      baseline.player.play()
      candidate.player.play()
      for index in 0..<(config.seconds * 4) {
        let target = start + Double(index) * 0.25
        let wait = target - ProcessInfo.processInfo.systemUptime
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        let baselineSample = baseline.sample()
        let candidateSample = candidate.sample()
        let row: [String: Any] = [
          "t": ProcessInfo.processInfo.systemUptime - start,
          "baseline": baselineSample, "candidate": candidateSample,
        ]
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
        if baselineSample["error"] != nil || candidateSample["error"] != nil { break }
      }
    } catch {
      let error = error as NSError
      FileHandle.standardError.write(Data("Probe failed: \(error.domain):\(error.code)\n".utf8))
      exit(1)
    }
  }
}

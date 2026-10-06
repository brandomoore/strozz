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
  let candidateUsesProxy: Bool?
  let candidateLiveOffset: Double?
  let candidateForwardBuffer: Double?
  let candidateResourceLoader: Bool?
  let candidateNativeApp: Bool?
}

final class ProbeResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  let origin: URL
  let queue = DispatchQueue(label: "strozz.probe.resource-loader")
  let session: URLSession
  let assetURL: URL
  private var requests: [ObjectIdentifier: URLSessionDataTask] = [:]

  init(origin: URL) throws {
    guard origin.host == "127.0.0.1", origin.port != nil,
      origin.scheme == "http" || origin.scheme == "https",
      var url = URLComponents(url: origin, resolvingAgainstBaseURL: false)
    else { throw PlaybackError.badResponse }
    url.scheme = "strozz-probe"
    guard let assetURL = url.url else { throw PlaybackError.badResponse }
    self.origin = origin
    self.assetURL = assetURL
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 12
    session = URLSession(configuration: configuration)
    super.init()
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let source = request.request.url,
      source.scheme == "strozz-probe", source.host == origin.host, source.port == origin.port,
      var url = URLComponents(url: source, resolvingAgainstBaseURL: false)
    else { return false }
    url.scheme = origin.scheme
    guard let target = url.url else {
      request.finishLoading(with: PlaybackError.badResponse)
      return true
    }
    let id = ObjectIdentifier(request)
    let task = session.dataTask(with: target) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.requests.removeValue(forKey: id)
        guard !request.isCancelled && !request.isFinished else { return }
        if let error {
          request.finishLoading(with: error)
          return
        }
        guard let data, let http = response as? HTTPURLResponse else {
          request.finishLoading(with: PlaybackError.badResponse)
          return
        }
        guard (200...299).contains(http.statusCode) else {
          request.finishLoading(with: PlaybackError.http(http.statusCode))
          return
        }
        if http.mimeType == "application/json" {
          struct Redirect: Decodable { let url: URL; let offset: Int; let length: Int }
          do {
            let redirect = try JSONDecoder().decode(Redirect.self, from: data)
            guard redirect.url.scheme == "https", redirect.offset >= 0,
              redirect.length > 0, redirect.length <= 32 * 1024 * 1024,
              redirect.offset <= Int.max - redirect.length else {
              throw PlaybackError.badResponse
            }
            var next = URLRequest(url: redirect.url)
            next.setValue("bytes=\(redirect.offset)-\(redirect.offset + redirect.length - 1)",
                          forHTTPHeaderField: "Range")
            request.redirect = next
            request.response = HTTPURLResponse(url: source, statusCode: 302,
              httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.url.absoluteString])
            request.finishLoading()
          } catch {
            request.finishLoading(with: PlaybackError.badResponse)
          }
          return
        }
        let isPlaylist = target.pathExtension == "m3u8"
        if let info = request.contentInformationRequest {
          info.contentType = isPlaylist ? "public.m3u-playlist" : "public.mpeg-4"
          info.contentLength = Int64(data.count)
          info.isByteRangeAccessSupported = !isPlaylist
        }
        if let body = request.dataRequest {
          let offset = max(body.requestedOffset, body.currentOffset)
          guard offset >= 0, offset <= data.count else {
            request.finishLoading(with: PlaybackError.badResponse)
            return
          }
          guard body.requestedOffset >= 0, body.requestedOffset <= data.count,
            body.requestedLength >= 0 else {
            request.finishLoading(with: PlaybackError.badResponse)
            return
          }
          let requestedEnd = Int(body.requestedOffset)
            + min(data.count - Int(body.requestedOffset), body.requestedLength)
          let end = body.requestsAllDataToEndOfResource ? data.count : requestedEnd
          guard end >= offset else {
            request.finishLoading(with: PlaybackError.badResponse)
            return
          }
          body.respond(with: data.subdata(in: Int(offset)..<end))
        }
        request.finishLoading()
      }
    }
    requests[id] = task
    task.resume()
    return true
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
    didCancel request: AVAssetResourceLoadingRequest
  ) {
    requests.removeValue(forKey: ObjectIdentifier(request))?.cancel()
  }

  func stop() { session.invalidateAndCancel() }
}

@MainActor
final class ProbePlayer {
  let player: AVPlayer
  let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
  let context = CIContext(options: [.cacheIntermediates: false])
  let policy = LivePlaybackPolicy.live(profile: .lowerLatency, isPinned: false)
  let usesProxyRatePolicy: Bool
  let requestedLiveOffset: Double?
  private var lastClock: Double?
  private var advancingSamples = 0
  private var appliedLiveOffset = false
  private var acceptedLiveOffset: Double?
  private var metricTask: Task<Void, Never>?
  private var metricPartRequests = 0
  private var metricPartWindows: [String: Int] = [:]
  private var metricHTTP2Requests = 0
  private var metricErrors = 0
  private var metricErrorMessages: [String] = []
  private var metricRangeRequests = 0
  private var metricRangeWindows: [String: Int] = [:]
  private var metricDurations: [String: Int] = [:]

  init(url: URL, headers: [String: String], proxy: LowLatencyHLSProxy? = nil,
       liveOffset: Double? = nil, forwardBuffer: Double? = nil,
       resourceLoader: ProbeResourceLoader? = nil, nativeEngine: NativeLowLatencyHLS? = nil) {
    usesProxyRatePolicy = proxy != nil
    requestedLiveOffset = liveOffset
    let asset = AVURLAsset(
      url: nativeEngine?.assetURL ?? resourceLoader?.assetURL ?? proxy?.proxyURL(for: url) ?? url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    if let nativeEngine {
      asset.resourceLoader.setDelegate(nativeEngine, queue: nativeEngine.queue)
    } else if let proxy {
      asset.resourceLoader.setDelegate(proxy, queue: proxy.callbackQueue)
    } else if let resourceLoader {
      asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.queue)
    }
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = forwardBuffer ?? policy.preferredForwardBufferDuration
    if let liveOffset {
      item.configuredTimeOffsetFromLive = CMTime(seconds: liveOffset, preferredTimescale: 600)
    }
    item.audioTimePitchAlgorithm = .timeDomain
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    item.add(output)
    player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    player.isMuted = true
    if #available(macOS 15, tvOS 18, *) {
      let start = ProcessInfo.processInfo.systemUptime
      metricTask = Task { @MainActor [weak self] in
        do {
          for try await event in item.metrics(forType: AVMetricHLSMediaSegmentRequestEvent.self) {
            guard let self else { break }
            if let error = event.mediaResourceRequestEvent?.errorEvent {
              self.metricErrors += 1
              if self.metricErrorMessages.count < 8 {
                self.metricErrorMessages.append(error.error.localizedDescription.replacingOccurrences(
                  of: #"https?://[^\s"]+"#, with: "[redacted URL]", options: .regularExpression))
              }
            } else if !event.isMapSegment {
              let window = String(Int((ProcessInfo.processInfo.systemUptime - start) / 10))
              let duration = String(format: "%.2f", event.segmentDuration)
              self.metricDurations[duration, default: 0] += 1
              if event.segmentDuration > 0, event.segmentDuration < 1 {
                self.metricPartRequests += 1
                self.metricPartWindows[window, default: 0] += 1
              }
              if event.byteRange.length > 0 {
                self.metricRangeRequests += 1
                self.metricRangeWindows[window, default: 0] += 1
              }
            }
            if event.mediaResourceRequestEvent?.networkTransactionMetrics?.transactionMetrics
              .contains(where: { $0.networkProtocolName == "h2" }) == true {
              self.metricHTTP2Requests += 1
            }
          }
        } catch {
          if !Task.isCancelled { self?.metricErrors += 1 }
        }
      }
    }
  }

  func sample() -> [String: Any] {
    guard let item = player.currentItem else { return ["error": "Missing player item"] }
    if !appliedLiveOffset, item.status == .readyToPlay, let requestedLiveOffset {
      appliedLiveOffset = true
      item.configuredTimeOffsetFromLive = CMTime(seconds: requestedLiveOffset, preferredTimescale: 600)
      acceptedLiveOffset = item.configuredTimeOffsetFromLive.seconds
      player.seek(to: .positiveInfinity)
    }
    let clock = item.currentTime().seconds
    var row: [String: Any] = [
      "state": player.timeControlStatus == .playing ? "playing"
        : (player.timeControlStatus == .paused ? "paused" : "waiting"),
      "rate": player.rate,
      "presentation_width": item.presentationSize.width,
      "presentation_height": item.presentationSize.height,
      "metric_part_requests": metricPartRequests,
      "metric_part_windows": metricPartWindows,
      "metric_http2_requests": metricHTTP2Requests,
      "metric_errors": metricErrors,
      "metric_error_messages": metricErrorMessages,
      "metric_range_requests": metricRangeRequests,
      "metric_range_windows": metricRangeWindows,
      "metric_segment_durations": metricDurations,
    ]
    if clock.isFinite { row["clock"] = clock }
    row["native_error_events"] = item.errorLog()?.events.suffix(6).map {
      "\($0.errorDomain):\($0.errorStatusCode) " + ($0.errorComment ?? "").replacingOccurrences(
        of: #"https?://[^\s"]+"#, with: "[redacted URL]", options: .regularExpression)
    } ?? []
    if let error = item.error as NSError? {
      row["error"] = "\(error.domain):\(error.code)"
      row["error_comments"] = item.errorLog()?.events.compactMap(\.errorComment).map {
        $0.replacingOccurrences(of: #"https?://[^\s"]+"#, with: "[redacted URL]", options: .regularExpression)
      } ?? []
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
    row["requested_live_offset"] = requestedLiveOffset
    row["accepted_live_offset"] = acceptedLiveOffset
    let recommendation = item.recommendedTimeOffsetFromLive.seconds
    if recommendation.isFinite { row["recommended_live_offset"] = recommendation }
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
    if usesProxyRatePolicy, advancingSamples >= 3, player.timeControlStatus == .playing {
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

  func stop() {
    metricTask?.cancel()
    player.pause()
    player.replaceCurrentItem(with: nil)
  }
}

@main
struct LLHLSPlayerProbe {
  @MainActor
  static func main() async {
    do {
      let config = try JSONDecoder().decode(
        ProbeConfiguration.self, from: FileHandle.standardInput.readDataToEndOfFile())
      guard (30...300).contains(config.seconds),
        config.candidateLiveOffset.map({ $0.isFinite && (0.5...30).contains($0) }) ?? true,
        config.candidateForwardBuffer.map({ $0.isFinite && (0...30).contains($0) }) ?? true
      else { throw PlaybackError.badResponse }
      let proxy = LowLatencyHLSProxy(headers: config.headers)
      proxy.configure(promotePrefetch: true, retainHistory: true, windowSeconds: 1800)
      let baseline = ProbePlayer(url: config.baseline, headers: config.headers, proxy: proxy)
      let candidateProxy = config.candidateUsesProxy == true
        ? LowLatencyHLSProxy(headers: config.headers) : nil
      candidateProxy?.configure(promotePrefetch: true, retainHistory: true, windowSeconds: 1800)
      let resourceLoader = config.candidateResourceLoader == true
        ? try ProbeResourceLoader(origin: config.candidate) : nil
      let nativeEngine = config.candidateNativeApp == true
        ? NativeLowLatencyHLS(sourceURL: config.candidate, headers: config.headers, history: 1800) { error in
          FileHandle.standardError.write(Data("Native engine failed: \(error.rawValue)\n".utf8))
        } : nil
      let candidate = ProbePlayer(
        url: config.candidate, headers: config.headers,
        proxy: candidateProxy, liveOffset: config.candidateLiveOffset,
        forwardBuffer: config.candidateForwardBuffer, resourceLoader: resourceLoader, nativeEngine: nativeEngine)
      defer {
        for probe in [baseline, candidate] {
          probe.stop()
        }
        resourceLoader?.stop()
        nativeEngine?.stop()
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

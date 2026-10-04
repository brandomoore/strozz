import AVFoundation
import Foundation

/// Delegate state is lock-protected; all playlist/index state lives on the origin actor.
final class NativeLowLatencyHLS: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  static let scheme = "strozz-native-ll"
  let id = UUID()
  let sourceURL: URL
  let origin: NativeHLSOrigin
  private let lock = NSLock()
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var stopped = false
  let queue = DispatchQueue(label: "strozz.native-hls.requests")

  init(sourceURL: URL, headers: [String: String], history: Double,
       failure: @escaping @Sendable (NativeHLSError) -> Void) {
    self.sourceURL = sourceURL
    origin = NativeHLSOrigin(root: sourceURL, headers: headers, history: history, failure: failure)
    super.init()
  }

  var assetURL: URL { URL(string: "\(Self.scheme)://\(id.uuidString)/root.m3u8")! }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let url = request.request.url, url.scheme == Self.scheme else { return false }
    let key = ObjectIdentifier(request)
    lock.lock()
    guard !stopped else { lock.unlock(); request.finishLoading(with: URLError(.cancelled)); return true }
    let task = Task { [weak self, origin] in
      do {
        let response = try await origin.response(url)
        guard !Task.isCancelled else { return }
        self?.queue.async { [weak self] in
          guard !request.isCancelled, !request.isFinished else { return }
          switch response {
          case .playlist(let data):
            request.contentInformationRequest?.contentType = "public.m3u-playlist"
            request.contentInformationRequest?.contentLength = Int64(data.count)
            request.contentInformationRequest?.isByteRangeAccessSupported = false
            if let body = request.dataRequest {
              let offset = max(body.requestedOffset, body.currentOffset)
              guard offset >= 0, offset <= data.count, body.requestedLength >= 0 else {
                request.finishLoading(with: NativeHLSError.invalidMedia); self?.remove(key); return
              }
              let end = body.requestsAllDataToEndOfResource ? data.count
                : Int(offset) + min(data.count - Int(offset), body.requestedLength)
              body.respond(with: data.subdata(in: Int(offset)..<end))
            }
          case .redirect(let url, let offset, let length):
            var next = URLRequest(url: url)
            next.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
            request.redirect = next
            request.response = HTTPURLResponse(url: request.request.url!, statusCode: 302,
              httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString])
          }
          request.finishLoading()
          self?.remove(key)
        }
      } catch {
        guard !Task.isCancelled else { return }
        self?.queue.async { [weak self] in
          if !request.isCancelled, !request.isFinished { request.finishLoading(with: error) }
          self?.remove(key)
        }
      }
    }
    tasks[key] = task
    lock.unlock()
    return true
  }

  private func remove(_ key: ObjectIdentifier) {
    lock.lock(); tasks.removeValue(forKey: key); lock.unlock()
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
    lock.lock(); let task = tasks.removeValue(forKey: ObjectIdentifier(request)); lock.unlock()
    task?.cancel()
  }

  func stop() {
    lock.lock()
    stopped = true
    let pending = Array(tasks.values)
    tasks.removeAll()
    lock.unlock()
    pending.forEach { $0.cancel() }
    Task { await origin.stop() }
  }
}

actor NativeHLSOrigin {
  enum Response: Sendable {
    case playlist(Data)
    case redirect(URL, Int, Int)
  }
  struct Part: Sendable {
    let offset: Int
    let length: Int
    let duration: Double
    let independent: Bool
  }
  struct Segment: Sendable {
    let sequence: Int
    let url: URL
    let date: Date
    var parts: [Part] = []
    var complete = false
    var duration: Double { parts.reduce(0) { $0 + $1.duration } }
  }
  struct Rendition {
    let url: URL
    var segments: [Segment] = []
    var initialization: URL?
    var target = 2
    var task: Task<Void, Never>?
    var lastRequest = Date()
  }
  let root: URL
  let headers: [String: String]
  let history: Double
  let failure: @Sendable (NativeHLSError) -> Void
  let session: URLSession
  private var master: String?
  private var sources: [Int: Rendition] = [:]
  private var lastActive = 0
  private var stopped = false
  private var error: NativeHLSError?
  private var publishedParts = 0

  init(root: URL, headers: [String: String], history: Double,
       failure: @escaping @Sendable (NativeHLSError) -> Void) {
    self.root = root; self.headers = headers; self.history = max(12, min(history, 1800))
    self.failure = failure
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 12
    session = URLSession(configuration: config)
  }

  func stop() {
    stopped = true
    for source in sources.values { source.task?.cancel() }
    sources.removeAll()
    session.invalidateAndCancel()
  }

  func snapshot() -> (parts: Int, renditions: Int) { (publishedParts, sources.count) }

  private func request(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    return request
  }

  private func data(_ url: URL) async throws -> Data {
    let (data, response) = try await session.data(for: request(url))
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4 * 1024 * 1024 else {
      throw NativeHLSError.unavailable
    }
    return data
  }

  private func fail(_ error: Error) {
    guard !stopped, !Task.isCancelled, self.error == nil, !(error is CancellationError) else { return }
    let reason = error as? NativeHLSError ?? .unavailable
    self.error = reason
    sources.values.forEach { $0.task?.cancel() }
    failure(reason)
  }

  private func prepare() async throws {
    guard master == nil else { return }
    let text = String(decoding: try await data(root), as: UTF8.self)
    guard !stopped else { throw CancellationError() }
    guard master == nil else { return }
    if !text.contains("#EXT-X-STREAM-INF:") {
      sources[0] = Rendition(url: root)
      master = ""
      return
    }
    var output: [String] = []
    var awaitingVariant = false
    for line in text.components(separatedBy: .newlines) {
      if line.hasPrefix("#EXT-X-STREAM-INF:") { awaitingVariant = true; output.append(line) }
      else if awaitingVariant, !line.isEmpty, !line.hasPrefix("#") {
        guard let url = URL(string: line, relativeTo: root)?.absoluteURL, url.scheme == "https",
          sources.count < 16 else { throw NativeHLSError.unsupported }
        let index = sources.count
        sources[index] = Rendition(url: url)
        output.append("media/\(index).m3u8")
        awaitingVariant = false
      } else { output.append(line) }
    }
    guard !sources.isEmpty else { throw NativeHLSError.unsupported }
    master = output.joined(separator: "\n")
  }

  func response(_ url: URL) async throws -> Response {
    do {
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      try await prepare()
      guard !stopped else { throw CancellationError() }
      if let error { throw error }
      if url.path == "/root.m3u8", let master, !master.isEmpty { return .playlist(Data(master.utf8)) }
      let components = url.path.split(separator: "/").map(String.init)
      let index = url.path == "/root.m3u8" ? 0 : Int(components.dropFirst().first?.split(separator: ".").first ?? "")
      guard let index, sources[index] != nil else { throw NativeHLSError.invalidMedia }
      if components.first != "part" {
        lastActive = index
        sources[index]?.lastRequest = Date()
        if sources[index]?.task == nil {
          sources[index]?.segments.removeAll()
          sources[index]?.task = Task { [weak self] in await self?.run(index) }
        }
      }
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let msn = query.first { $0.name == "_HLS_msn" }?.value.flatMap(Int.init)
      let part = query.first { $0.name == "_HLS_part" }?.value.flatMap(Int.init)
      guard (msn == nil || msn! >= 0), (part == nil || (msn != nil && part! >= 0 && part! < 128))
      else { throw NativeHLSError.invalidMedia }
      let deadline = Date().addingTimeInterval(components.first == "part" ? 4 : 12)
      while !stopped {
        try Task.checkCancellation()
        if let error { throw error }
        guard let source = sources[index] else { throw CancellationError() }
        if components.first == "part", components.count == 4,
          let sequence = Int(components[2]), let number = Int(components[3].split(separator: ".")[0]),
          number >= 0, let segment = source.segments.first(where: { $0.sequence == sequence }),
          segment.parts.indices.contains(number) {
          let part = segment.parts[number]
          return .redirect(segment.url, part.offset, part.length)
        }
        if components.first != "part",
          source.segments.filter(\.complete).reduce(0, { $0 + $1.duration }) >= Double(source.target * 3),
          let tail = source.segments.last {
          let ready = msn == nil || tail.sequence > msn! ||
            (tail.sequence == msn! && (part.map { tail.parts.count > $0 } ?? tail.complete))
          if ready || Date() >= deadline { return .playlist(try playlist(index, base: url)) }
        }
        if Date() >= deadline { throw NativeHLSError.timeout }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw CancellationError()
    } catch {
      if !(error is CancellationError) { fail(error) }
      throw error
    }
  }

  private func playlist(_ index: Int, base: URL) throws -> Data {
    guard let source = sources[index], let initURL = source.initialization,
      let first = source.segments.first, let last = source.segments.last else { throw NativeHLSError.unavailable }
    var lines = ["#EXTM3U", "#EXT-X-VERSION:9", "#EXT-X-INDEPENDENT-SEGMENTS",
      "#EXT-X-TARGETDURATION:\(source.target)", "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)",
      "#EXT-X-MAP:URI=\"\(initURL.absoluteString)\"",
      "#EXT-X-PART-INF:PART-TARGET=0.45",
      "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.5"]
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var remaining = source.segments.reduce(0) { $0 + $1.duration }
    for segment in source.segments {
      lines.append("#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: segment.date))")
      if remaining <= Double(source.target * 3) {
        for part in segment.parts {
          let independent = part.independent ? ",INDEPENDENT=YES" : ""
          lines.append("#EXT-X-PART:DURATION=\(String(format: "%.6f", part.duration)),URI=\"\(segment.url.absoluteString)\",BYTERANGE=\"\(part.length)@\(part.offset)\"\(independent)")
        }
      }
      if segment.complete { lines += ["#EXTINF:\(String(format: "%.6f", segment.duration)),", segment.url.absoluteString] }
      remaining -= segment.duration
    }
    let sequence = last.complete ? last.sequence + 1 : last.sequence
    let number = last.complete ? 0 : last.parts.count
    let prefix = "\(NativeLowLatencyHLS.scheme)://\(base.host ?? "")"
    lines.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(prefix)/part/\(index)/\(sequence)/\(number).mp4\"")
    for (otherID, other) in sources where otherID != index {
      // A cold rendition can satisfy this complete source sequence on its first request.
      let tail = other.segments.last
      let msn = tail?.sequence ?? max(first.sequence, last.sequence - 1)
      let part = tail.map { max(0, $0.parts.count - 1) } ?? 0
      lines.append("#EXT-X-RENDITION-REPORT:URI=\"\(prefix)/media/\(otherID).m3u8\",LAST-MSN=\(msn),LAST-PART=\(part)")
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  private func run(_ index: Int) async {
    do {
      guard let url = sources[index]?.url else { return }
      var next: Int?
      var map: URL?
      var disc: Int?
      var track: NativeCMAF.Track?
      var endClock: Double?
      while !stopped {
        try Task.checkCancellation()
        if index != lastActive, let last = sources[index]?.lastRequest, Date().timeIntervalSince(last) > 8 { break }
        let manifest = try NativeCMAF.manifest(String(decoding: try await data(url), as: UTF8.self), url: url)
        if let map, map != manifest.initialization || disc != manifest.discontinuity { throw NativeHLSError.transition }
        if track == nil {
          map = manifest.initialization; disc = manifest.discontinuity
          track = try NativeCMAF.videoTrack(await data(manifest.initialization))
          sources[index]?.initialization = map
        }
        if next == nil {
          let completed = manifest.entries.filter { $0.duration != nil && $0.date != nil }
          guard let first = completed.suffix(4).first else { throw NativeHLSError.unsupported }
          next = first.sequence
        }
        guard let expected = next, let first = manifest.entries.first, first.sequence <= expected else { throw NativeHLSError.transition }
        guard let entry = manifest.entries.first(where: { $0.sequence == expected }) else {
          try await Task.sleep(for: .milliseconds(120)); continue
        }
        let previous = sources[index]?.segments.last
        let date = entry.date ?? previous.map { $0.date.addingTimeInterval($0.duration) }
        guard let date, let track else { throw NativeHLSError.invalidMedia }
        if let previous, abs(date.timeIntervalSince(previous.date.addingTimeInterval(previous.duration))) > 0.2 {
          throw NativeHLSError.transition
        }
        sources[index]?.segments.append(Segment(sequence: entry.sequence, url: entry.url, date: date))
        let (bytes, response) = try await session.bytes(for: request(entry.url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NativeHLSError.unavailable }
        var buffer = Data()
        var offset = 0
        var boxLength = 0
        var fragmentOffset = 0
        var timing: NativeCMAF.Timing?
        var partOffset = 0
        var partDuration = 0.0
        var independent = false
        for try await byte in bytes {
          try Task.checkCancellation()
          buffer.append(byte)
          if buffer.count == 8 {
            let length = try NativeCMAF.integer(buffer, 0)
            guard length == 1 || (length >= 8 && length <= 32 * 1024 * 1024) else { throw NativeHLSError.invalidMedia }
            if length != 1 { boxLength = Int(length) }
          }
          if buffer.count == 16, try NativeCMAF.integer(buffer, 0) == 1 {
            let length = try NativeCMAF.integer(buffer, 8, 8)
            guard length <= 32 * 1024 * 1024 else { throw NativeHLSError.invalidMedia }
            boxLength = Int(length)
          }
          guard buffer.count < 32 * 1024 * 1024 else { throw NativeHLSError.invalidMedia }
          if boxLength == 0 || buffer.count < boxLength { continue }
          guard boxLength >= 8, let box = try NativeCMAF.boxes(buffer).first else { throw NativeHLSError.invalidMedia }
          if box.type == "moof" {
            guard timing == nil else { throw NativeHLSError.invalidMedia }
            timing = try NativeCMAF.timing(box.payload, track: track)
            fragmentOffset = offset
          } else if box.type == "mdat" {
            guard let frame = timing else { throw NativeHLSError.invalidMedia }
            if let endClock, abs(frame.start - endClock) > 0.002 { throw NativeHLSError.transition }
            endClock = frame.start + frame.duration
            if partDuration == 0 { partOffset = fragmentOffset; independent = frame.independent }
            partDuration += frame.duration
            guard partDuration <= 0.45 else { throw NativeHLSError.unsupported }
            if partDuration >= 0.3825 {
              try publish(index, Part(offset: partOffset, length: offset + boxLength - partOffset,
                                      duration: partDuration, independent: independent))
              partDuration = 0
            }
            timing = nil
          } else if !["emsg", "styp", "sidx", "free", "prft"].contains(box.type) { throw NativeHLSError.unsupported }
          offset += boxLength
          buffer.removeAll(keepingCapacity: true)
          boxLength = 0
        }
        guard buffer.isEmpty, timing == nil else { throw NativeHLSError.invalidMedia }
        if partDuration > 0 {
          try publish(index, Part(offset: partOffset, length: offset - partOffset, duration: partDuration, independent: independent))
        }
        if var source = sources[index], !source.segments.isEmpty {
          let last = source.segments.count - 1
          source.segments[last].complete = true
          let duration = source.segments[last].duration
          guard duration > 0, duration.rounded() <= Double(source.target) else { throw NativeHLSError.unsupported }
          var retained = source.segments.reduce(0) { $0 + $1.duration }
          while source.segments.count > 6 && (retained > history || source.segments.count > 1000) {
            retained -= source.segments.removeFirst().duration
          }
          sources[index] = source
        }
        next = expected + 1
      }
      sources[index]?.task = nil
    } catch {
      sources[index]?.task = nil
      fail(error)
    }
  }

  private func publish(_ index: Int, _ part: Part) throws {
    guard var source = sources[index], !source.segments.isEmpty else { throw CancellationError() }
    let last = source.segments.count - 1
    if source.segments[last].parts.isEmpty, !part.independent { throw NativeHLSError.invalidMedia }
    source.segments[last].parts.append(part)
    sources[index] = source
    publishedParts += 1
  }
}

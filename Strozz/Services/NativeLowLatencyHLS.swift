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
    var media: Data? = nil
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
    var initializationLength: Int?
    var localMedia = false
    var target = 2
    var task: Task<Void, Never>?
    var lastRequest = Date()
    var reachedLiveEdge = false
    var indexingPrefetch = false
    var nextURL: URL?
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
  private var mediaServer: NativeHLSMediaServer?
  private var mediaBase: URL?
  private var cachedMediaBytes = 0

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
    cachedMediaBytes = 0
    session.invalidateAndCancel()
    mediaServer?.stop()
  }

  func snapshot() -> (parts: Int, renditions: Int, edgeAge: Double?) {
    let tail = sources[lastActive]?.segments.last
    return (publishedParts, sources.count, tail.map { Date().timeIntervalSince($0.date.addingTimeInterval($0.duration)) })
  }

  private func media(_ path: String) async -> Data? {
    let fields = path.split(separator: "/")
    guard fields.count == 4, fields[0] == "part", let index = Int(fields[1]),
      let sequence = Int(fields[2]), let number = Int(fields[3].split(separator: ".")[0]),
      number >= 0 else { return nil }
    let deadline = Date().addingTimeInterval(4)
    while !stopped, error == nil, !Task.isCancelled {
      if let segment = sources[index]?.segments.first(where: { $0.sequence == sequence }) {
        if segment.parts.indices.contains(number) { return segment.parts[number].media }
        if segment.complete { return nil }
      }
      if Date() >= deadline { return nil }
      do { try await Task.sleep(for: .milliseconds(25)) } catch { return nil }
    }
    return nil
  }

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
    var audioOnly = false
    for line in text.components(separatedBy: .newlines) {
      if line.hasPrefix("#EXT-X-STREAM-INF:") {
        awaitingVariant = true
        audioOnly = line.contains("VIDEO=\"audio_only\"")
        output.append(line)
      }
      else if awaitingVariant, !line.isEmpty, !line.hasPrefix("#") {
        guard let url = URL(string: line, relativeTo: root)?.absoluteURL, url.scheme == "https",
          sources.count < 16 else { throw NativeHLSError.unsupported }
        if audioOnly {
          output.append(url.absoluteString)
        } else {
          let index = sources.count
          sources[index] = Rendition(url: url)
          output.append("media/\(index).m3u8")
        }
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
          if let segments = sources[index]?.segments {
            cachedMediaBytes -= segments.reduce(0) { $0 + $1.parts.reduce(0) { $0 + ($1.media?.count ?? 0) } }
          }
          sources[index]?.segments.removeAll()
          sources[index]?.reachedLiveEdge = false
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
          source.reachedLiveEdge,
          source.segments.filter(\.complete).reduce(0, { $0 + $1.duration }) >= Double(source.target * 3),
          let tail = source.segments.last {
          let ready = msn == nil || tail.sequence > msn! ||
            (tail.sequence == msn! && (part.map { tail.parts.count > $0 } ?? tail.complete))
          if ready || Date() >= deadline { return .playlist(try playlist(index, base: url)) }
        }
        if Date() >= deadline {
          if components.first == "part" {
            throw URLError(.resourceUnavailable)
          }
          throw NativeHLSError.timeout
        }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw CancellationError()
    } catch {
      if !(error is CancellationError), (error as? URLError)?.code != .resourceUnavailable { fail(error) }
      throw error
    }
  }

  private func playlist(_ index: Int, base: URL) throws -> Data {
    guard let source = sources[index],
      let first = source.segments.first, let last = source.segments.last else { throw NativeHLSError.unavailable }
    var lines = ["#EXTM3U", "#EXT-X-VERSION:9", "#EXT-X-INDEPENDENT-SEGMENTS",
      "#EXT-X-TARGETDURATION:\(source.target)", "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)",
      "#EXT-X-PART-INF:PART-TARGET=0.45",
      "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.5"]
    if let initURL = source.initialization, source.initializationLength == nil {
      let range = source.initializationLength.map { ",BYTERANGE=\"\($0)@0\"" } ?? ""
      lines.insert("#EXT-X-MAP:URI=\"\(initURL.absoluteString)\"\(range)", at: 4)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var remaining = source.segments.reduce(0) { $0 + $1.duration }
    for segment in source.segments {
      lines.append("#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: segment.date))")
      if remaining <= Double(source.target * 3) {
        for (number, part) in segment.parts.enumerated() {
          let independent = part.independent ? ",INDEPENDENT=YES" : ""
          if source.localMedia, let mediaBase {
            let suffix = source.initialization == nil ? "ts" : "mp4"
            lines.append("#EXT-X-PART:DURATION=\(String(format: "%.6f", part.duration)),URI=\"\(mediaBase.absoluteString)/part/\(index)/\(segment.sequence)/\(number).\(suffix)\"\(independent)")
          } else {
            lines.append("#EXT-X-PART:DURATION=\(String(format: "%.6f", part.duration)),URI=\"\(segment.url.absoluteString)\",BYTERANGE=\"\(part.length)@\(part.offset)\"\(independent)")
          }
        }
      }
      if segment.complete { lines += ["#EXTINF:\(String(format: "%.6f", segment.duration)),", segment.url.absoluteString] }
      remaining -= segment.duration
    }
    let sequence = last.complete ? last.sequence + 1 : last.sequence
    let number = last.complete ? 0 : last.parts.count
    let prefix = "\(NativeLowLatencyHLS.scheme)://\(base.host ?? "")"
    if source.localMedia, let mediaBase {
      let suffix = source.initialization == nil ? "ts" : "mp4"
      lines.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(mediaBase.absoluteString)/part/\(index)/\(sequence)/\(number).\(suffix)\"")
    } else if let next = source.nextURL, last.complete {
      lines.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(next.absoluteString)\",BYTERANGE-START=0")
    } else if !last.complete, let part = last.parts.last {
      lines.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(last.url.absoluteString)\",BYTERANGE-START=\(part.offset + part.length)")
    } else {
      lines.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(prefix)/part/\(index)/\(sequence)/\(number).mp4\"")
    }
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
        if disc != nil, map != manifest.initialization || disc != manifest.discontinuity { throw NativeHLSError.transition }
        if disc == nil {
          map = manifest.initialization; disc = manifest.discontinuity
          if let initialization = manifest.initialization {
            track = try NativeCMAF.videoTrack(await data(initialization))
          }
          sources[index]?.initialization = map
          sources[index]?.target = manifest.targetDuration
          sources[index]?.localMedia = true
          if mediaServer == nil {
            let server = try NativeHLSMediaServer { [weak self] path in await self?.media(path) }
            mediaServer = server
            mediaBase = try await server.start()
          }
        }
        if next == nil {
          let completed = manifest.entries.filter { $0.duration != nil && $0.date != nil }
          var seconds = 0.0
          var backfill: [NativeCMAF.Entry] = []
          for candidate in completed.reversed() {
            backfill.append(candidate)
            seconds += candidate.duration ?? 0
            if seconds >= Double(manifest.targetDuration * 3) { break }
          }
          guard let first = backfill.last else { throw NativeHLSError.unsupported }
          next = first.sequence
        }
        guard let expected = next, let first = manifest.entries.first, first.sequence <= expected else { throw NativeHLSError.transition }
        guard let entry = manifest.entries.first(where: { $0.sequence == expected }) else {
          try await Task.sleep(for: .milliseconds(120)); continue
        }
        sources[index]?.nextURL = manifest.entries.first(where: { $0.sequence == expected + 1 })?.url
        let previous = sources[index]?.segments.last
        let date = entry.date ?? previous.map { $0.date.addingTimeInterval($0.duration) }
        guard let date else { throw NativeHLSError.invalidMedia }
        if let previous, abs(date.timeIntervalSince(previous.date.addingTimeInterval(previous.duration))) > 0.2 {
          throw NativeHLSError.transition
        }
        sources[index]?.segments.append(Segment(sequence: entry.sequence, url: entry.url, date: date))
        let reader = NativeHLSChunkReader()
        let chunks = reader.stream(request(entry.url))
        defer { reader.stop() }
        sources[index]?.indexingPrefetch = entry.duration == nil
        var buffer = Data()
        var offset = 0
        var fragmentOffset = 0
        var timing: NativeCMAF.Timing?
        var partOffset = 0
        var partDuration = 0.0
        var independent = false
        var transportStream = NativeTransportStream()
        var tsPending = Data()
        var tsInitialization = Data()
        var cmafPending = Data()
        for try await chunk in chunks {
          defer { reader.consumedChunk() }
          try Task.checkCancellation()
          buffer.append(chunk)
          guard buffer.count < 32 * 1024 * 1024 else { throw NativeHLSError.invalidMedia }
          while !buffer.isEmpty {
            if track == nil {
              guard buffer.count >= 188 else { break }
              let packet = Data(buffer.prefix(188))
              buffer.removeFirst(188)
              tsPending.append(packet)
              if let range = try transportStream.append(packet) {
                if tsInitialization.isEmpty {
                  tsInitialization = Data(tsPending.prefix(transportStream.initializationLength))
                }
                var bytes = Data(tsPending.prefix(range.length))
                if range.offset != 0 { bytes = tsInitialization + bytes }
                try publish(index, Part(offset: range.offset, length: range.length,
                                        duration: range.duration, independent: range.independent, media: bytes))
                tsPending.removeFirst(range.length)
              }
              continue
            }
            guard buffer.count >= 8 else { break }
            let length = try NativeCMAF.integer(buffer, 0)
            guard length == 1 || (length >= 8 && length <= 32 * 1024 * 1024) else { throw NativeHLSError.invalidMedia }
            if length == 1, buffer.count < 16 { break }
            let size = length == 1 ? try NativeCMAF.integer(buffer, 8, 8) : length
            guard size >= (length == 1 ? 16 : 8), size <= 32 * 1024 * 1024 else { throw NativeHLSError.invalidMedia }
            let boxLength = Int(size)
            guard buffer.count >= boxLength else { break }
            let boxData = Data(buffer.prefix(boxLength))
            buffer.removeFirst(boxLength)
          guard let box = try NativeCMAF.boxes(boxData).first else { throw NativeHLSError.invalidMedia }
          if box.type == "moof" {
            guard timing == nil else { throw NativeHLSError.invalidMedia }
            guard let track else { throw NativeHLSError.invalidMedia }
            timing = try NativeCMAF.timing(box.payload, track: track)
            fragmentOffset = offset
            cmafPending.append(boxData)
          } else if box.type == "mdat" {
            cmafPending.append(boxData)
            guard let frame = timing else { throw NativeHLSError.invalidMedia }
            if let endClock, abs(frame.start - endClock) > 0.002 { throw NativeHLSError.transition }
            endClock = frame.start + frame.duration
            if partDuration == 0 { partOffset = fragmentOffset; independent = frame.independent }
            partDuration += frame.duration
            guard partDuration <= 0.45 else { throw NativeHLSError.unsupported }
            if partDuration >= 0.3825 {
              try publish(index, Part(offset: partOffset, length: offset + boxLength - partOffset,
                                      duration: partDuration, independent: independent, media: cmafPending))
              cmafPending.removeAll(keepingCapacity: true)
              partDuration = 0
            }
            timing = nil
          } else if !["emsg", "styp", "sidx", "free", "prft"].contains(box.type) { throw NativeHLSError.unsupported }
          offset += boxLength
          }
        }
        guard buffer.isEmpty, timing == nil else { throw NativeHLSError.invalidMedia }
        if track == nil {
          let range = try transportStream.finish(expectedDuration: entry.duration)
          let bytes = range.offset == 0 ? tsPending : tsInitialization + tsPending
          try publish(index, Part(offset: range.offset, length: range.length,
                                  duration: range.duration, independent: range.independent, media: bytes))
        }
        if partDuration > 0 {
          try publish(index, Part(offset: partOffset, length: offset - partOffset, duration: partDuration, independent: independent, media: cmafPending))
        }
        if var source = sources[index], !source.segments.isEmpty {
          let last = source.segments.count - 1
          source.segments[last].complete = true
          let duration = source.segments[last].duration
          guard duration > 0, duration.rounded() <= Double(source.target) else { throw NativeHLSError.unsupported }
          var retained = source.segments.reduce(0) { $0 + $1.duration }
          while source.segments.count > 6 && (retained > history || source.segments.count > 1000) {
            let removed = source.segments.removeFirst()
            retained -= removed.duration
            cachedMediaBytes -= removed.parts.reduce(0) { $0 + ($1.media?.count ?? 0) }
          }
          var age = 0.0
          for i in source.segments.indices.reversed() {
            if age > Double(source.target * 3 + 8) {
              for p in source.segments[i].parts.indices {
                cachedMediaBytes -= source.segments[i].parts[p].media?.count ?? 0
                source.segments[i].parts[p].media = nil
              }
            }
            age += source.segments[i].duration
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
    guard cachedMediaBytes + (part.media?.count ?? 0) <= 96 * 1024 * 1024 else { throw NativeHLSError.unavailable }
    if source.segments[last].parts.isEmpty, !part.independent { throw NativeHLSError.invalidMedia }
    source.segments[last].parts.append(part)
    if source.indexingPrefetch { source.reachedLiveEdge = true }
    cachedMediaBytes += part.media?.count ?? 0
    sources[index] = source
    publishedParts += 1
  }
}

import Foundation
import OSLog

actor NativeControlledHLSOrigin {
  private final class TransferMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var measuredSeconds: TimeInterval?

    var seconds: TimeInterval? { lock.withLock { measuredSeconds } }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
      guard let transaction = metrics.transactionMetrics.last,
        let start = transaction.responseStartDate, let end = transaction.responseEndDate else { return }
      let seconds = end.timeIntervalSince(start)
      guard seconds.isFinite, seconds > 0 else { return }
      lock.withLock { measuredSeconds = seconds }
    }
  }

  struct Variant: Sendable {
    let id: Int
    let url: URL
    let bitrate: Int
    let manifest: NativeCMAF.Manifest
  }

  private struct Segment {
    let sequence: Int
    let variant: Int
    let entry: NativeCMAF.Entry
    let date: Date
    let firstMovieSequence: UInt32
    var parts: [NativeTransportRemuxer.Part] = []
    var complete = false
    var declaredDuration: Double?
    var duration: Double { parts.isEmpty ? (declaredDuration ?? 0) : parts.reduce(0) { $0 + $1.duration } }
  }

  private struct Bootstrap: Sendable {
    let variant: Variant
    let entry: NativeCMAF.Entry
    let bytes: Data
  }

  private struct Movie: Sendable {
    let initialization: Data
    let configurations: [Int: NativeFragmentedMP4.Configuration]
  }

  private let variants: [Variant]
  private let headers: [String: String]
  private let history: Double
  private let target: Int
  private let namespace: String
  private let loadData: NativeHLSOrigin.DataLoader?
  private let diagnostic: @Sendable (NativeHLSFailureDiagnostic) -> Void
  private let trace: (@Sendable (NativeHLSPlaybackDiagnostic) -> Void)?
  private let failure: @Sendable (NativeHLSError) -> Void
  private let session: URLSession
  private var setupTask: Task<Void, Error>?
  private var producer: Task<Void, Never>?
  private var probe: Task<Void, Never>?
  private var server: NativeHLSMediaServer?
  private var mediaBase: URL?
  private var initialization = Data()
  private var configurations: [Int: NativeFragmentedMP4.Configuration] = [:]
  private var movies: [Int: Movie] = [:]
  private var movieLoads: [Int: Task<Movie, Error>] = [:]
  private var currentMoviePeriod: Int?
  private var manifests: [Int: NativeCMAF.Manifest] = [:]
  private var bootstraps: [Int: Bootstrap] = [:]
  private var segments: [Segment] = []
  private var policy: NativeAdaptiveRenditionPolicy?
  private var budget: NativeAdaptiveRenditionPolicy.Budget
  private var forwardBuffer = 0.0
  private var lastClampedBudget: NativeAdaptiveRenditionPolicy.Budget?
  private var nextMovieSequence: UInt32 = 1
  private var publishedParts = 0
  private var error: NativeHLSError?
  private var stopped = false
  private var reachedLive = false
  private var ended = false
  private var hasPrefetch = true
  private var publicationDuration = 2.0
  private var mediaClock = NativeMediaClock()
  private var historyLoads: [Int: Task<Data, Error>] = [:]
  #if DEBUG
  private var capturesRequests = false
  private var requests: [[String: String]] = []
  private var traceRequests: [NativeHLSPlaybackDiagnostic] = []

  func enableRequestDiagnostics() { capturesRequests = true }
  func requestDiagnostics() -> [[String: String]] { requests }
  func timelineDiagnostics() -> [[String: String]] {
    let values = publishedSegments
    return (Array(values.prefix(2)) + Array(values.dropFirst(2).suffix(4))).map { segment in
      ["rendition": "0", "source_rendition": String(segment.variant), "active": "true",
       "running": String(producer != nil), "reached_live": String(reachedLive),
       "target_duration": String(target), "upstream_target_duration": String(target),
       "sequence": String(segment.sequence), "date": segment.date.ISO8601Format(),
       "duration": String(segment.duration), "period": String(segment.entry.discontinuity),
       "format": "cmaf", "complete": String(segment.complete),
       "parts": segment.parts.map { String($0.duration) }.joined(separator: ","),
       "history_count": String(values.count),
       "history_duration": String(values.reduce(0) { $0 + $1.duration })]
    }
  }

  private func record(_ path: String, started: Date, bytes: Int?, query: [URLQueryItem] = []) {
    let end = Date()
    let seconds = max(0, end.timeIntervalSince(started))
    var counters = ["active_rendition": policy?.selected?.id ?? 0]
    counters["bytes"] = bytes
    for key in ["_HLS_msn", "_HLS_part"] {
      counters[key] = query.first(where: { $0.name == key })?.value.flatMap(Int.init)
    }
    if trace != nil {
      traceRequests.append(.init(event: .request,
        attributes: ["path": path, "served": String(bytes != nil), "pipeline": "controlled_cmaf"],
        metrics: ["duration_seconds": seconds, "ended_uptime_seconds": ProcessInfo.processInfo.systemUptime],
        counters: counters))
      if traceRequests.count > 16 { traceRequests.removeFirst(traceRequests.count - 16) }
    }
    guard capturesRequests else { return }
    var row = ["path": path, "served": String(bytes != nil), "seconds": String(seconds),
      "started_epoch": String(started.timeIntervalSince1970), "ended_epoch": String(end.timeIntervalSince1970),
      "start": started.ISO8601Format(), "end": end.ISO8601Format()]
    if let bytes { row["bytes"] = String(bytes) }
    requests.append(row)
    if requests.count > 512 { requests.removeFirst(requests.count - 512) }
  }
  #endif
  private static let maximumMediaBytes = 96 * 1024 * 1024
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "native-controlled-hls")

  init(variants: [Variant], headers: [String: String], history: Double, target: Int,
       namespace: String, budget: NativeAdaptiveRenditionPolicy.Budget,
       loadData: NativeHLSOrigin.DataLoader? = nil,
       diagnostic: @escaping @Sendable (NativeHLSFailureDiagnostic) -> Void,
       trace: (@Sendable (NativeHLSPlaybackDiagnostic) -> Void)?,
       failure: @escaping @Sendable (NativeHLSError) -> Void) {
    self.variants = variants
    self.headers = headers
    self.history = max(history, Double(target * 3 + 4))
    self.target = target
    self.namespace = namespace
    self.budget = budget
    self.loadData = loadData
    self.diagnostic = diagnostic
    self.trace = trace
    self.failure = failure
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 12
    session = URLSession(configuration: configuration)
    manifests = Dictionary(uniqueKeysWithValues: variants.map { ($0.id, $0.manifest) })
  }

  func update(buffer: Double, budget: NativeAdaptiveRenditionPolicy.Budget) throws {
    try checkRunning()
    guard buffer.isFinite, buffer >= 0 else { throw NativeHLSError.invalidMedia }
    forwardBuffer = buffer
    self.budget = budget
  }

  func snapshot() -> NativeHLSOrigin.Snapshot {
    let tail = publishedSegments.last
    return (publishedParts, variants.count,
      tail.map { Date().timeIntervalSince($0.date.addingTimeInterval($0.duration)) },
      holdBack, hasPrefetch, max(3, holdBack), nil, nil, segments.last?.entry.discontinuity ?? 0, cachedBytes)
  }

  func liveEdgeDate() -> Date? {
    guard reachedLive, let last = publishedSegments.last(where: { $0.duration > 0 }) else { return nil }
    return last.date.addingTimeInterval(last.duration)
  }

  func liveTargetDate() -> Date? { liveEdgeDate()?.addingTimeInterval(-holdBack) }

  private var holdBack: Double { hasPrefetch ? 1.5 : publicationDuration + 1.5 }

  func response(_ url: URL) async throws -> NativeHLSOrigin.Response {
    #if DEBUG
    let started = Date()
    var servedBytes: Int?
    defer {
      record(url.path, started: started, bytes: servedBytes,
        query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    }
    #endif
    do {
      try await prepare()
      try checkRunning()
      if url.path == "/root.m3u8" {
        guard let maximum = variants.map(\.bitrate).max() else { throw NativeHLSError.unsupported }
        let text = "#EXTM3U\n#EXT-X-VERSION:9\n#EXT-X-STREAM-INF:BANDWIDTH=\(maximum),STABLE-VARIANT-ID=\"\(namespace)-controlled\"\nmedia/0.m3u8\n"
        let bytes = Data(text.utf8)
        #if DEBUG
        servedBytes = bytes.count
        #endif
        return .playlist(bytes)
      }
      guard url.path == "/media/0.m3u8" else { throw NativeHLSError.invalidMedia }
      if producer == nil { producer = Task { [weak self] in await self?.run() } }
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let msn = query.first(where: { $0.name == "_HLS_msn" })?.value.flatMap(Int.init)
      let part = query.first(where: { $0.name == "_HLS_part" })?.value.flatMap(Int.init)
      guard msn.map({ $0 >= 0 }) ?? true, part.map({ msn != nil && $0 >= 0 && $0 < 128 }) ?? true else {
        throw NativeHLSError.invalidMedia
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(12))
      while true {
        try checkRunning()
        let published = publishedSegments
        if reachedLive, let tail = published.last, published.contains(where: { !$0.parts.isEmpty }),
          published.filter(\.complete).reduce(0, { $0 + $1.duration }) >= Double(target * 3) {
          let ready = msn == nil || tail.sequence > msn!
            || (tail.sequence == msn! && (part.map { tail.parts.count > $0 } ?? tail.complete))
          if ready || ended || ContinuousClock.now >= deadline {
            let bytes = try playlist(published)
            #if DEBUG
            servedBytes = bytes.count
            #endif
            return .playlist(bytes)
          }
        }
        guard ContinuousClock.now < deadline else { throw NativeHLSError.timeout }
        try await Task.sleep(for: .milliseconds(25))
      }
    } catch {
      fail(error, operation: "playlist")
      throw error
    }
  }

  private var cachedBytes: Int {
    segments.reduce(0) { total, segment in total + segment.parts.reduce(0) { $0 + $1.bytes.count } }
  }

  private var publishedSegments: [Segment] {
    guard !ended, let last = segments.lastIndex(where: { !$0.parts.isEmpty }) else { return segments }
    var result = Array(segments[...last])
    result[last].parts.removeLast()
    result[last].complete = false
    result[last].declaredDuration = nil
    return result
  }

  private func checkRunning() throws {
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    if let error { throw error }
  }

  private func prepare() async throws {
    if !initialization.isEmpty { return }
    if let setupTask { return try await setupTask.value }
    let task = Task { [weak self] in
      guard let self else { throw CancellationError() }
      try await self.setup()
    }
    setupTask = task
    defer { setupTask = nil }
    try await task.value
  }

  private func setup() async throws {
    let began = ProcessInfo.processInfo.systemUptime
    let samples = try await withThrowingTaskGroup(of: Bootstrap.self) { group in
      for variant in variants {
        group.addTask {
          guard let entry = variant.manifest.entries.last(where: { $0.duration != nil && $0.date != nil }) else {
            throw NativeHLSError.unsupported
          }
          return Bootstrap(variant: variant, entry: entry, bytes: try await self.data(entry.url, media: true))
        }
      }
      var values: [Bootstrap] = []
      for try await value in group { values.append(value) }
      return values
    }
    let ended = ProcessInfo.processInfo.systemUptime
    try checkRunning()
    guard let period = samples.first?.entry.discontinuity,
      samples.allSatisfy({ $0.entry.discontinuity == period }),
      samples.reduce(0, { $0 + $1.bytes.count }) <= Self.maximumMediaBytes else {
      throw NativeHLSError.transition
    }
    var prepared: [Int: NativeFragmentedMP4.Configuration] = [:]
    for sample in samples {
      let converted = try remux(sample.bytes, variant: sample.variant.id, date: sample.entry.date!,
        period: sample.entry.discontinuity,
        expectedDuration: sample.entry.duration, firstSequence: 1, expectedConfiguration: nil)
      prepared[sample.variant.id] = converted.configuration
      bootstraps[sample.variant.id] = sample
    }
    let values = try variants.map { variant -> NativeAdaptiveRenditionPolicy.Variant in
      guard let configuration = prepared[variant.id], variant.bitrate > 0 else { throw NativeHLSError.invalidMedia }
      return .init(id: variant.id, bitrate: variant.bitrate, width: configuration.width, height: configuration.height)
    }
    var selection = try NativeAdaptiveRenditionPolicy(variants: values)
    try selection.recordCompletedTransfer(bytes: samples.reduce(0) { $0 + $1.bytes.count },
      seconds: max(0.000001, ended - began), at: ended)
    let inits = try variants.map { variant -> Data in
      guard let configuration = prepared[variant.id] else { throw NativeHLSError.invalidMedia }
      return NativeFragmentedMP4.initialization(configuration)
    }
    guard let largest = values.max(by: { $0.width * $0.height < $1.width * $1.height }),
      let largestIndex = variants.firstIndex(where: { $0.id == largest.id }) else { throw NativeHLSError.invalidMedia }
    let movie = try NativeFragmentedMP4.switchingInitialization(inits, maximumResolutionIndex: largestIndex)
    let listener = try NativeHLSMediaServer { [weak self] path in await self?.media(path) }
    server = listener
    let base = try await listener.start()
    try checkRunning()
    configurations = prepared
    policy = selection
    server = listener
    mediaBase = base
    initialization = movie
    movies[period] = Movie(initialization: movie, configurations: prepared)
    currentMoviePeriod = period
    probe = Task { [weak self] in await self?.probeCapacity() }
  }

  private func data(_ url: URL, media: Bool = false, timeout: TimeInterval? = nil) async throws -> Data {
    try await download(url, media: media, timeout: timeout).bytes
  }

  private nonisolated func transfer(_ request: URLRequest) async throws -> (Data, URLResponse, TimeInterval?) {
    if let loadData {
      let start = ProcessInfo.processInfo.systemUptime
      let result = try await loadData(request)
      return (result.0, result.1, ProcessInfo.processInfo.systemUptime - start)
    }
    // RTT, CDN cache warm-up and queued remux work are not payload throughput.
    let metrics = TransferMetrics()
    let result = try await session.data(for: request, delegate: metrics)
    return (result.0, result.1, metrics.seconds)
  }

  private func download(_ url: URL, media: Bool = false, probeBytes: Int? = nil,
                        timeout: TimeInterval? = nil) async throws -> (bytes: Data, seconds: TimeInterval?) {
    try checkRunning()
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    if let probeBytes { request.setValue("bytes=0-\(probeBytes - 1)", forHTTPHeaderField: "Range") }
    if let timeout { request.timeoutInterval = timeout }
    let result = try await transfer(request)
    try checkRunning()
    let status = (result.1 as? HTTPURLResponse)?.statusCode ?? -1
    guard status == 200 || (probeBytes != nil && status == 206) else { throw NativeHLSFailureDetail.httpStatus(status) }
    guard result.0.count < (media ? 32 * 1024 * 1024 : 4 * 1024 * 1024) else {
      throw NativeHLSError.invalidMedia
    }
    if status == 206 {
      guard (result.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-") == true else {
        throw NativeHLSError.invalidMedia
      }
    }
    return (result.0, result.2)
  }

  private func manifest(_ variant: Variant) async throws -> NativeCMAF.Manifest {
    let bytes: Data
    do { bytes = try await data(variant.url) }
    catch {
      guard !segments.isEmpty, let network = error as? URLError,
        network.code == .timedOut || network.code == .networkConnectionLost else { throw error }
      diagnostic(.init(error: error, operation: "manifest_retry", rendition: variant.id,
        active: policy?.selected?.id ?? variant.id, fatal: false))
      bytes = try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask { try await self.data(variant.url, timeout: 4) }
        group.addTask { try await Task.sleep(for: .seconds(4)); throw URLError(.timedOut) }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
      }
    }
    let result = try NativeCMAF.manifest(String(decoding: bytes, as: UTF8.self), url: variant.url)
    guard result.initialization == nil else { throw NativeHLSError.transition }
    manifests[variant.id] = result
    return result
  }

  private func probeCapacity() async {
    var next = ContinuousClock.now.advanced(by: .seconds(2))
    while !Task.isCancelled, !stopped {
      do {
        try await Task.sleep(until: next, clock: .continuous)
        next = ContinuousClock.now.advanced(by: .seconds(2))
        try checkRunning()
        let limit = try effectiveBudget()
        guard let variant = variants.filter({ value in
          guard let configuration = configurations[value.id] else { return false }
          return limit.allows(.init(id: value.id, bitrate: value.bitrate,
            width: configuration.width, height: configuration.height))
        }).max(by: { $0.bitrate < $1.bitrate }) else { throw NativeHLSError.unsupported }
        let latest = try await manifest(variant)
        guard let entry = latest.entries.last(where: { $0.duration != nil }) else { throw NativeHLSError.invalidMedia }
        let probeBytes = Int(max(16_384, min(262_144, (policy?.capacity ?? 20_000_000) * 0.025)))
        var sample = try await download(entry.url, media: true, probeBytes: probeBytes)
        guard let firstSeconds = sample.seconds else { throw NativeHLSError.invalidMedia }
        let firstCapacity = Double(sample.bytes.count * 8) / firstSeconds
        if let selected = policy?.selected, let previousCapacity = policy?.capacity,
          firstCapacity < previousCapacity * 0.8, firstCapacity * 0.75 < Double(selected.bitrate) {
          do {
            sample = try await download(entry.url, media: true, probeBytes: min(probeBytes, 65_536))
          } catch {
            if Task.isCancelled || stopped { return }
            Self.logger.warning("Capacity confirmation unavailable: \((error as NSError).domain) \((error as NSError).code)")
            diagnostic(.init(error: error, operation: "capacity_probe", rendition: variant.id,
              active: policy?.selected?.id ?? 0, fatal: false))
          }
        }
        guard let seconds = sample.seconds else { throw NativeHLSError.invalidMedia }
        let end = ProcessInfo.processInfo.systemUptime
        try policy?.recordCompletedTransfer(bytes: sample.bytes.count, seconds: seconds, at: end)
        trace?(.init(event: .state, attributes: ["pipeline": "controlled_cmaf", "reason": "capacity_sample"],
          metrics: ["transfer_seconds": seconds,
            "initial_capacity_bps": firstCapacity,
            "measured_capacity_bps": Double(sample.bytes.count * 8) / seconds,
            "estimated_capacity_bps": policy?.capacity ?? 0],
          counters: ["rendition": variant.id, "bytes": sample.bytes.count]))
      } catch {
        if Task.isCancelled || stopped { return }
        Self.logger.warning("Capacity probe unavailable: \((error as NSError).domain) \((error as NSError).code)")
        diagnostic(.init(error: error, operation: "capacity_probe", rendition: nil,
          active: policy?.selected?.id ?? 0, fatal: false))
      }
    }
  }

  private func run() async {
    var readers: [Int: NativeHLSChunkReader] = [:]
    defer { readers.values.forEach { $0.stop() } }
    do {
      var nextDate: Date?
      var nextVirtual: Int?
      while true {
        try checkRunning()
        let limit = try effectiveBudget()
        guard let chosen = try policy?.select(budget: limit, buffer: forwardBuffer,
          deliveryLate: false, at: ProcessInfo.processInfo.systemUptime),
          let variant = variants.first(where: { $0.id == chosen.variant.id }),
          let description = variants.firstIndex(where: { $0.id == variant.id }) else {
          throw NativeHLSError.invalidMedia
        }
        if chosen.changed {
          trace?(.init(event: .rendition,
            attributes: ["reason": chosen.reason.rawValue, "pipeline": "controlled_cmaf"],
            metrics: ["capacity_bps": policy?.capacity ?? 0],
            counters: ["rendition": variant.id, "height": chosen.variant.height]))
        }
        let current = try await manifest(variant)
        hasPrefetch = current.hasPrefetch
        publicationDuration = current.entries.compactMap(\.duration).max() ?? Double(current.targetDuration)
        let entries = dated(current.entries)
        let entry: NativeCMAF.Entry
        let date: Date
        if let nextDate {
          guard let previous = segments.last else { throw NativeHLSError.invalidMedia }
          let successor = Self.successor(in: entries, previousSequence: previous.entry.sequence,
            previousVariant: previous.variant, previousPeriod: previous.entry.discontinuity,
            previousDate: previous.date, variant: variant.id, nextDate: nextDate)
          guard let found = successor else {
            if current.ended {
              if previous.variant == variant.id, entries.contains(where: { $0.0.sequence > previous.entry.sequence }) {
                throw NativeHLSError.transition
              }
              ended = true
              return
            }
            if let first = entries.first, first.1.timeIntervalSince(nextDate) > 0.2 {
              throw NativeHLSError.transition
            }
            try await Task.sleep(for: .milliseconds(100))
            continue
          }
          (entry, date) = found
        } else {
          guard let found = entries.last(where: { $0.0.duration != nil }) else { throw NativeHLSError.unsupported }
          (entry, date) = found
          let prefix = entries.filter { $0.1 < date && $0.0.duration != nil }
          segments = prefix.map { value in
            Segment(sequence: value.0.sequence, variant: variant.id, entry: value.0, date: value.1,
              firstMovieSequence: UInt32(value.0.sequence % 1_000_000) * 128 + 1,
              complete: true, declaredDuration: value.0.duration)
          }
          nextVirtual = entry.sequence
        }
        guard let sequence = nextVirtual else { throw NativeHLSError.invalidMedia }
        let movie = try await movie(for: entry.discontinuity)
        guard let configuration = movie.configurations[variant.id] else { throw NativeHLSError.invalidMedia }
        if currentMoviePeriod != entry.discontinuity {
          configurations = movie.configurations
          let values = try variants.map { variant -> NativeAdaptiveRenditionPolicy.Variant in
            guard let configuration = movie.configurations[variant.id] else { throw NativeHLSError.invalidMedia }
            return .init(id: variant.id, bitrate: variant.bitrate,
              width: configuration.width, height: configuration.height)
          }
          try policy?.updateFormats(values)
          currentMoviePeriod = entry.discontinuity
        }
        let startSequence = nextMovieSequence
        segments.append(Segment(sequence: sequence, variant: variant.id, entry: entry, date: date,
          firstMovieSequence: startSequence))
        var remuxer = try NativeTransportRemuxer(configuration: configuration,
          videoDescriptionIndex: UInt32(description + 1), firstSequence: startSequence,
          presentationEpoch: NativeMediaClock.wrap,
          presentationReference: mediaClock.reference(period: entry.discontinuity, date: date))
        if let cached = bootstraps[variant.id], cached.entry.sequence == entry.sequence {
          try consume(cached.bytes, remuxer: &remuxer, sequence: sequence)
          bootstraps.removeValue(forKey: variant.id)
        } else if loadData != nil {
          try consume(await data(entry.url, media: true), remuxer: &remuxer, sequence: sequence)
        } else {
          let reader = readers[variant.id] ?? NativeHLSChunkReader()
          readers[variant.id] = reader
          var request = URLRequest(url: entry.url)
          headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
          var pending = Data()
          var total = 0
          for try await chunk in reader.stream(request) {
            defer { reader.consumedChunk(chunk) }
            try checkRunning()
            total += chunk.data.count
            guard total < 32 * 1024 * 1024 else { throw NativeHLSError.invalidMedia }
            pending.append(chunk.data)
            while pending.count >= 188 {
              let packet = Data(pending.prefix(188))
              pending.removeFirst(188)
              try publish(remuxer.append(packet), sequence: sequence)
            }
          }
          guard pending.isEmpty else { throw NativeHLSError.invalidMedia }
        }
        try publish(remuxer.finish(expectedDuration: entry.duration), sequence: sequence)
        bootstraps.removeAll()
        guard let last = segments.indices.last else { throw NativeHLSError.invalidMedia }
        segments[last].complete = true
        nextMovieSequence = remuxer.nextSequence
        nextDate = date.addingTimeInterval(segments[last].duration)
        guard sequence < Int.max else { throw NativeHLSError.invalidMedia }
        nextVirtual = sequence + 1
        reachedLive = current.hasPrefetch || reachedLive
        trim()
      }
    } catch {
      fail(error, operation: "indexing")
    }
  }

  static func successor(in entries: [(NativeCMAF.Entry, Date)], previousSequence: Int,
                        previousVariant: Int, previousPeriod: Int, previousDate: Date,
                        variant: Int, nextDate: Date) -> (NativeCMAF.Entry, Date)? {
    if let matching = entries.first(where: { abs($0.1.timeIntervalSince(nextDate)) < 0.1 }) { return matching }
    return entries.first { candidate in
      guard candidate.0.discontinuity > previousPeriod else { return false }
      if previousVariant == variant { return previousSequence < Int.max && candidate.0.sequence == previousSequence + 1 }
      return candidate.1 >= previousDate
    }
  }

  private func effectiveBudget() throws -> NativeAdaptiveRenditionPolicy.Budget {
    guard let policy else { throw NativeHLSError.invalidMedia }
    if policy.variants.contains(where: { budget.allows($0) }) {
      lastClampedBudget = nil
      return budget
    }
    guard budget.maximumWidth >= 0, budget.maximumHeight >= 0, budget.maximumBitrate >= 0,
      let lowest = policy.variants.first else { throw NativeHLSError.invalidMedia }
    if lastClampedBudget != budget {
      Self.logger.warning("Requested playback budget is below every available rendition; using the lowest available")
      trace?(.init(event: .state, attributes: ["pipeline": "controlled_cmaf", "reason": "budget_below_available"],
        metrics: [:],
        counters: ["rendition": lowest.id, "height": lowest.height, "bandwidth_bps": lowest.bitrate]))
      lastClampedBudget = budget
    }
    return .init(maximumWidth: lowest.width, maximumHeight: lowest.height, maximumBitrate: lowest.bitrate)
  }

  private func movie(for period: Int) async throws -> Movie {
    guard period >= 0 else { throw NativeHLSError.invalidMedia }
    if let movie = movies[period] { return movie }
    if let loading = movieLoads[period] { return try await loading.value }
    let loading = Task { [weak self] in
      guard let self else { throw CancellationError() }
      return try await self.loadMovie(period: period)
    }
    movieLoads[period] = loading
    defer { movieLoads.removeValue(forKey: period) }
    let movie = try await loading.value
    try checkRunning()
    movies[period] = movie
    return movie
  }

  private func loadMovie(period: Int) async throws -> Movie {
    let samples = try await withThrowingTaskGroup(of: Bootstrap.self) { group in
      for variant in variants {
        group.addTask {
          let cached = await self.manifests[variant.id]?.entries.last(where: {
            $0.discontinuity == period && $0.duration != nil && $0.date != nil
          }) ?? variant.manifest.entries.last(where: {
            $0.discontinuity == period && $0.duration != nil && $0.date != nil
          })
          let entry: NativeCMAF.Entry
          if let cached { entry = cached }
          else {
            let current = try await self.manifest(variant)
            guard let found = await self.dated(current.entries).last(where: { $0.0.discontinuity == period }) else {
              throw URLError(.resourceUnavailable)
            }
            entry = NativeCMAF.Entry(sequence: found.0.sequence, url: found.0.url,
              duration: found.0.duration, date: found.1, initialization: found.0.initialization,
              discontinuity: found.0.discontinuity, tags: found.0.tags)
          }
          return Bootstrap(variant: variant, entry: entry, bytes: try await self.data(entry.url, media: true))
        }
      }
      var values: [Bootstrap] = []
      for try await value in group { values.append(value) }
      return values
    }
    guard samples.reduce(0, { $0 + $1.bytes.count }) <= Self.maximumMediaBytes else {
      throw NativeHLSError.invalidMedia
    }
    var prepared: [Int: NativeFragmentedMP4.Configuration] = [:]
    for sample in samples {
      try checkRunning()
      guard let date = sample.entry.date else { throw NativeHLSError.invalidMedia }
      prepared[sample.variant.id] = try remux(sample.bytes, variant: sample.variant.id, date: date, period: period,
        expectedDuration: sample.entry.duration, firstSequence: 1, expectedConfiguration: nil).configuration
      bootstraps[sample.variant.id] = sample
    }
    let initializations = try variants.map { variant -> Data in
      guard let configuration = prepared[variant.id] else { throw NativeHLSError.invalidMedia }
      return NativeFragmentedMP4.initialization(configuration)
    }
    guard let maximum = variants.indices.max(by: { a, b in
      let left = prepared[variants[a].id]
      let right = prepared[variants[b].id]
      return (left.map { $0.width * $0.height } ?? 0) < (right.map { $0.width * $0.height } ?? 0)
    }) else { throw NativeHLSError.invalidMedia }
    return Movie(initialization: try NativeFragmentedMP4.switchingInitialization(initializations,
      maximumResolutionIndex: maximum), configurations: prepared)
  }

  private func consume(_ data: Data, remuxer: inout NativeTransportRemuxer, sequence: Int) throws {
    guard !data.isEmpty, data.count.isMultiple(of: 188) else { throw NativeHLSError.invalidMedia }
    for offset in stride(from: 0, to: data.count, by: 188) {
      try publish(remuxer.append(data.subdata(in: offset..<(offset + 188))), sequence: sequence)
    }
  }

  private func publish(_ parts: [NativeTransportRemuxer.Part], sequence: Int) throws {
    guard !parts.isEmpty else { return }
    for part in parts {
      trim()
      guard let index = segments.firstIndex(where: { $0.sequence == sequence }) else { throw CancellationError() }
      guard cachedBytes + part.bytes.count <= Self.maximumMediaBytes else {
        throw NativeHLSFailureDetail.cacheCapacity(cachedBytes)
      }
      if segments[index].parts.isEmpty, !part.independent { throw NativeHLSError.invalidMedia }
      segments[index].parts.append(part)
      if segments[index].parts.count == 1 { traceSegment(segments[index], part: part, event: .segment) }
      publishedParts += 1
      reachedLive = true
      try mediaClock.observe(period: segments[index].entry.discontinuity,
        date: segments[index].date, presentationTime: part.decodeTime)
    }
  }

  private func trim() {
    guard let last = segments.last else { return }
    let edge = last.date.addingTimeInterval(last.duration)
    while segments.count > 10, let first = segments.first,
      edge.timeIntervalSince(first.date.addingTimeInterval(first.duration)) > history {
      segments.removeFirst()
    }
    for index in segments.indices where edge.timeIntervalSince(segments[index].date) > Double(target * 3 + 8) {
      if segments[index].complete {
        segments[index].declaredDuration = segments[index].duration
        segments[index].parts.removeAll()
      }
    }
  }

  private func dated(_ entries: [NativeCMAF.Entry]) -> [(NativeCMAF.Entry, Date)] {
    var next: Date?
    return entries.compactMap { entry in
      guard let date = entry.date ?? next else { return nil }
      next = entry.duration.map { date.addingTimeInterval($0) }
      return (entry, date)
    }
  }

  private func remux(_ data: Data, variant: Int, date: Date, period: Int, expectedDuration: Double?,
                     firstSequence: UInt32, expectedConfiguration: NativeFragmentedMP4.Configuration?) throws
    -> (configuration: NativeFragmentedMP4.Configuration, parts: [NativeTransportRemuxer.Part]) {
    guard !data.isEmpty, data.count.isMultiple(of: 188),
      let description = variants.firstIndex(where: { $0.id == variant }) else { throw NativeHLSError.invalidMedia }
    var remuxer = try NativeTransportRemuxer(configuration: expectedConfiguration,
      videoDescriptionIndex: UInt32(description + 1), firstSequence: firstSequence,
      presentationEpoch: NativeMediaClock.wrap,
      presentationReference: mediaClock.reference(period: period, date: date))
    var parts: [NativeTransportRemuxer.Part] = []
    for offset in stride(from: 0, to: data.count, by: 188) {
      parts += try remuxer.append(data.subdata(in: offset..<(offset + 188)))
    }
    parts += try remuxer.finish(expectedDuration: expectedDuration)
    guard let configuration = remuxer.configuration else { throw NativeHLSError.transportCodec }
    return (configuration, parts)
  }

  func media(_ path: String) async -> Data? {
    let historical = path.hasPrefix("/segment/0/")
    let initRequest = path.hasPrefix("/init/0/")
    #if DEBUG
    let started = Date()
    var servedBytes: Int?
    defer { record(path, started: started, bytes: servedBytes) }
    #endif
    do {
      try checkRunning()
      let fields = path.split(separator: "/")
      if fields.count == 3, fields[0] == "init", fields[1] == "0",
        let period = Int(fields[2].split(separator: ".").first ?? "") {
        let movie = try await movie(for: period)
        #if DEBUG
        servedBytes = movie.initialization.count
        #endif
        return movie.initialization
      }
      if fields.count == 3, fields[0] == "segment", fields[1] == "0",
        let sequence = Int(fields[2].split(separator: ".").first ?? "") {
        let bytes = try await fullSegment(sequence)
        #if DEBUG
        servedBytes = bytes.count
        #endif
        return bytes
      }
      guard fields.count == 4, fields[1] == "0", let sequence = Int(fields[2]),
        let number = Int(fields[3].split(separator: ".").first ?? ""),
        number >= 0, fields[0] == "part" else {
        Self.logger.warning("Rejected an invalid local media resource path")
        return nil
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while true {
        try checkRunning()
        if let segment = segments.first(where: { $0.sequence == sequence }) {
          if segment.parts.indices.contains(number) {
            let bytes = segment.parts[number].bytes
            #if DEBUG
            servedBytes = bytes.count
            #endif
            return bytes
          }
          if segment.complete { return nil }
        }
        if ContinuousClock.now >= deadline { return nil }
        try await Task.sleep(for: .milliseconds(25))
      }
    } catch {
      if historical || initRequest {
        if !stopped, !(error is CancellationError) {
          Self.logger.warning("Historical media unavailable: \((error as NSError).domain) \((error as NSError).code)")
          diagnostic(.init(error: error, operation: historical ? "history_media" : "initialization_media", rendition: nil,
            active: policy?.selected?.id ?? 0, fatal: false))
        }
        return nil
      }
      fail(error, operation: "local_media")
      return nil
    }
  }

  private func fullSegment(_ sequence: Int) async throws -> Data {
    guard let segment = segments.first(where: { $0.sequence == sequence }), segment.complete else {
      throw URLError(.resourceUnavailable)
    }
    if !segment.parts.isEmpty { return segment.parts.reduce(into: Data()) { $0.append($1.bytes) } }
    if let load = historyLoads[sequence] { return try await load.value }
    let task = Task { [weak self] in
      guard let self else { throw CancellationError() }
      let movie = try await self.movie(for: segment.entry.discontinuity)
      let bytes = try await self.data(segment.entry.url, media: true)
      let converted = try await self.remux(bytes, variant: segment.variant, date: segment.date,
        period: segment.entry.discontinuity,
        expectedDuration: segment.entry.duration, firstSequence: segment.firstMovieSequence,
        expectedConfiguration: movie.configurations[segment.variant])
      return converted.parts.reduce(into: Data()) { $0.append($1.bytes) }
    }
    historyLoads[sequence] = task
    defer { historyLoads.removeValue(forKey: sequence) }
    return try await task.value
  }

  private func playlist(_ values: [Segment]) throws -> Data {
    guard let first = values.first, let last = values.last, let mediaBase else { throw NativeHLSError.unavailable }
    var lines = ["#EXTM3U", "#EXT-X-VERSION:9", "#EXT-X-INDEPENDENT-SEGMENTS",
      "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)",
      "#EXT-X-DISCONTINUITY-SEQUENCE:\(first.entry.discontinuity)",
      "#EXT-X-MAP:URI=\"\(mediaBase.absoluteString)/init/0/\(first.entry.discontinuity).mp4\"",
      "#EXT-X-PART-INF:PART-TARGET=0.45",
      "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=\(holdBack)"]
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var remaining = values.reduce(0) { $0 + $1.duration }
    var period = first.entry.discontinuity
    for segment in values {
      if segment.entry.discontinuity != period {
        guard segment.entry.discontinuity > period, segment.entry.discontinuity - period <= 16 else {
          throw NativeHLSError.invalidMedia
        }
        for _ in period..<segment.entry.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
        lines.append("#EXT-X-MAP:URI=\"\(mediaBase.absoluteString)/init/0/\(segment.entry.discontinuity).mp4\"")
        period = segment.entry.discontinuity
      }
      lines += segment.entry.tags
      lines.append("#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: segment.date))")
      if remaining <= Double(target * 3) {
        for (index, part) in segment.parts.enumerated() {
          lines.append("#EXT-X-PART:DURATION=\(String(format: "%.6f", part.duration)),URI=\"\(mediaBase.absoluteString)/part/0/\(segment.sequence)/\(index).mp4\"\(part.independent ? ",INDEPENDENT=YES" : "")")
        }
      }
      if segment.complete {
        lines += ["#EXTINF:\(String(format: "%.6f", segment.duration)),",
          "\(mediaBase.absoluteString)/segment/0/\(segment.sequence).mp4"]
      }
      remaining -= segment.duration
    }
    if ended { lines.append("#EXT-X-ENDLIST") }
    else {
      lines.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(mediaBase.absoluteString)/part/0/\(last.sequence)/\(last.parts.count).mp4\"")
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  private func fail(_ value: Error, operation: String) {
    guard !stopped, error == nil, !(value is CancellationError), !Task.isCancelled,
      (value as? URLError)?.code != .cancelled else { return }
    error = NativeHLSError.classify(value)
    Self.logger.error("Controlled Native failure in \(operation): \((value as NSError).domain) \((value as NSError).code)")
    diagnostic(.init(error: value, operation: operation, rendition: policy?.selected?.id,
      active: policy?.selected?.id ?? 0, fatal: true))
    producer?.cancel()
    probe?.cancel()
    if let error { failure(error) }
  }

  private func traceSegment(_ segment: Segment, part: NativeTransportRemuxer.Part,
                            event: NativeHLSPlaybackDiagnostic.Event) {
    guard let configuration = movies[segment.entry.discontinuity]?.configurations[segment.variant] else { return }
    var metrics = ["video_decode_start_seconds": Double(part.decodeTime) / 90_000,
      "video_presentation_start_seconds": Double(part.presentationTime) / 90_000,
      "program_date_seconds": segment.date.timeIntervalSince1970,
      "part_duration_seconds": part.duration, "hold_back_seconds": holdBack]
    metrics["audio_first_presentation_seconds"] = part.audioDecodeTime.map { Double($0) / Double(configuration.audioRate) }
    trace?(.init(event: event,
      attributes: ["pipeline": "controlled_cmaf", "format": "cmaf",
        "resolution": "\(configuration.width)x\(configuration.height)"],
      metrics: metrics, counters: ["rendition": segment.variant, "sequence": segment.sequence,
        "video_samples": part.videoSamples, "audio_samples": part.audioSamples,
        "part_bytes": part.bytes.count, "cached_media_bytes": cachedBytes]))
  }

  func stop() async {
    guard !stopped else { return }
    stopped = true
    for segment in segments.suffix(2) {
      if let part = segment.parts.first { traceSegment(segment, part: part, event: .state) }
    }
    #if DEBUG
    for request in traceRequests { trace?(request) }
    #endif
    setupTask?.cancel()
    producer?.cancel()
    probe?.cancel()
    let histories = Array(historyLoads.values)
    let pendingMovies = Array(movieLoads.values)
    histories.forEach { $0.cancel() }
    pendingMovies.forEach { $0.cancel() }
    session.invalidateAndCancel()
    server?.stop()
    _ = await setupTask?.result
    _ = await producer?.result
    _ = await probe?.result
    for load in histories { _ = await load.result }
    for movie in pendingMovies { _ = await movie.result }
    historyLoads.removeAll()
    bootstraps.removeAll()
    segments.removeAll()
    movies.removeAll()
    movieLoads.removeAll()
  }
}

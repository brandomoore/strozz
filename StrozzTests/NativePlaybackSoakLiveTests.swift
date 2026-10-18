import AVKit
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class NativePlaybackSoakLiveTests: XCTestCase {
  private struct Input: Codable, Sendable {
    let channel: String
    let format: String
    let frameRate: String
    let resolution: String
    let bitrate: Int
    let codecs: String
    let targetDuration: Int
    let incrementalPrefetch: Bool
    let playlistFetchSeconds: Double
    let playlistTailDateAgeSeconds: Double?
    let deliveryHost: String
  }

  private struct Evidence: Codable, Sendable {
    var channel: String
    var phase: String
    var status = "running"
    var plannedSeconds = 0
    var observedSeconds = 0.0
    var samples = 0
    var stallNotifications = 0
    var failedToEnd = 0
    var itemReplacements = 0
    var playerReplacements = 0
    var frozenClockEpisodes = 0
    var frozenClockSeconds = 0.0
    var samplingGaps = 0
    var maximumSamplingGap = 0.0
    var waitingSeconds = 0.0
    var unavailableSeconds = 0.0
    var staleVideoSeconds = 0.0
    var visibleVideoSeconds = 0.0
    var hiddenVideoSeconds = 0.0
    var decodeRecoveryObserved = false
    var nativeOnly = true
    var controlledAutoOnly = true
    var decodedSizes: [String: Int] = [:]
    var errors: [String: Int] = [:]

    var completeSampling: Bool {
      plannedSeconds > 0 && observedSeconds >= Double(plannedSeconds)
        && visibleVideoSeconds + hiddenVideoSeconds >= Double(plannedSeconds)
        && samples >= plannedSeconds * 3 && (!decodedSizes.isEmpty || visibleVideoSeconds == 0)
        && samplingGaps == 0
    }

    var playbackIssue: Bool {
      stallNotifications > 0 || failedToEnd > 0 || itemReplacements > 0 || playerReplacements > 0
        || frozenClockEpisodes > 0 || waitingSeconds >= 0.5 || unavailableSeconds >= 0.5
        || staleVideoSeconds >= 0.5 || decodeRecoveryObserved || !nativeOnly || !controlledAutoOnly
    }

    var clean: Bool { completeSampling && !playbackIssue }
    var verdict: String { playbackIssue ? "failed_playback" : (completeSampling ? "passed" : "incomplete_sampling") }
  }

  private actor Sink {
    let directory: URL
    let diagnosticsDirectory: URL

    init(directory: URL, diagnosticsDirectory: URL) {
      self.directory = directory
      self.diagnosticsDirectory = diagnosticsDirectory
    }

    func save<T: Encodable & Sendable>(_ value: T, name: String) throws {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      try encoder.encode(value).write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    func archive(session: String, folder: String) throws {
      let destination = directory.appendingPathComponent("diagnostics/" + folder, isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let files = try FileManager.default.contentsOfDirectory(at: diagnosticsDirectory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("playback-\(session)-") && $0.pathExtension == "jsonl" }
      guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
      for file in files {
        try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
      }
    }
  }

  @MainActor
  private final class Watch {
    let model: PlayerModel
    var evidence: Evidence
    private var observers: [NSObjectProtocol] = []
    private var previousClock: Double?
    private var previousItem: ObjectIdentifier?
    private var previousPlayer: ObjectIdentifier?
    private var stagnantSeconds = 0.0
    private var clockFrozen = false
    private var knownItems = Set<ObjectIdentifier>()

    init(model: PlayerModel, channel: String, phase: String, seconds: Int) {
      self.model = model
      evidence = Evidence(channel: channel, phase: phase)
      evidence.plannedSeconds = seconds
      if let item = model.player.currentItem { knownItems.insert(ObjectIdentifier(item)) }
      for name in [Notification.Name.AVPlayerItemPlaybackStalled, .AVPlayerItemFailedToPlayToEndTime] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] notification in
          let itemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
          let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
          let errorKey = error.map { "\($0.domain):\($0.code)" }
          MainActor.assumeIsolated {
            guard let self, let itemID,
              self.knownItems.contains(itemID)
                || self.model.player.currentItem.map(ObjectIdentifier.init) == itemID else { return }
            if name == .AVPlayerItemPlaybackStalled { self.evidence.stallNotifications += 1 }
            else { self.evidence.failedToEnd += 1 }
            if let errorKey { self.evidence.errors[errorKey, default: 0] += 1 }
          }
        })
      }
    }

    func stop() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers.removeAll()
    }

    func sample(interval: Double) {
      let player = model.player
      let item = player.currentItem
      let clock = item?.currentTime().seconds
      let playerID = ObjectIdentifier(player)
      let itemID = item.map(ObjectIdentifier.init)
      if let itemID { knownItems.insert(itemID) }
      evidence.samples += 1
      evidence.observedSeconds += interval
      if interval > 0.75 {
        evidence.samplingGaps += 1
        evidence.maximumSamplingGap = max(evidence.maximumSamplingGap, interval)
      }
      if let previousPlayer, previousPlayer != playerID { evidence.playerReplacements += 1 }
      if let previousItem, previousItem != itemID { evidence.itemReplacements += 1 }
      previousPlayer = playerID
      previousItem = itemID
      evidence.decodeRecoveryObserved = evidence.decodeRecoveryObserved
        || model.decodeRecoveryQualityID != nil || model.triedDecodeRecovery
      evidence.nativeOnly = evidence.nativeOnly && model.isUsingNativeHLS && model.nativeFallbackReason == nil
      evidence.controlledAutoOnly = evidence.controlledAutoOnly && model.nativeControlledAuto
      if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { evidence.waitingSeconds += interval }
      if model.isLoading || model.errorMessage != nil || item == nil {
        evidence.unavailableSeconds += interval
      }
      if model.isVideoPresentationVisible {
        evidence.visibleVideoSeconds += interval
        if model.playbackTelemetry.videoFrameAge.map({ $0 >= 4 }) ?? true {
          evidence.staleVideoSeconds += interval
        }
        if let size = model.playbackTelemetry.decodedVideoSize,
          model.playbackTelemetry.videoFrameAge.map({ $0 < 4 }) == true {
          evidence.decodedSizes["\(Int(size.width))x\(Int(size.height))", default: 0] += 1
        }
      } else {
        evidence.hiddenVideoSeconds += interval
      }
      // A sampling gap is missing evidence, not proof the clock froze.
      if interval <= 0.75, let clock, clock.isFinite, let previousClock, clock - previousClock < 0.02 {
        stagnantSeconds += interval
        if stagnantSeconds >= 0.5 {
          if !clockFrozen {
            evidence.frozenClockEpisodes += 1
            evidence.frozenClockSeconds += stagnantSeconds
            clockFrozen = true
          } else { evidence.frozenClockSeconds += interval }
        }
      } else {
        stagnantSeconds = 0
        clockFrozen = false
      }
      previousClock = clock
    }
  }

  func testRecoveredStallsAndMissingEvidenceCannotPassASoak() {
    var evidence = Evidence(channel: "fixture", phase: "steady")
    XCTAssertFalse(evidence.clean)
    evidence.plannedSeconds = 2
    evidence.observedSeconds = 2
    evidence.samples = 8
    evidence.visibleVideoSeconds = 2
    evidence.decodedSizes = ["1920x1080": 8]
    XCTAssertTrue(evidence.clean)
    evidence.stallNotifications = 1
    XCTAssertFalse(evidence.clean)
    evidence.stallNotifications = 0
    evidence.failedToEnd = 1
    XCTAssertFalse(evidence.clean)
    evidence.failedToEnd = 0
    evidence.samplingGaps = 1
    XCTAssertFalse(evidence.clean)
    XCTAssertEqual(evidence.verdict, "incomplete_sampling")
    evidence.samplingGaps = 0
    evidence.decodeRecoveryObserved = true
    XCTAssertFalse(evidence.clean)
  }

  func testOnlyIntentionallyHiddenVideoIsExemptFromVisibleFrameEvidence() {
    var evidence = Evidence(channel: "fixture", phase: "expanded", plannedSeconds: 2,
      observedSeconds: 2, samples: 8)
    XCTAssertFalse(evidence.clean, "Unaccounted visibility is missing evidence")
    evidence.hiddenVideoSeconds = 2
    XCTAssertTrue(evidence.clean)
    evidence.frozenClockEpisodes = 1
    XCTAssertFalse(evidence.clean, "Hidden playback still owes clock progress")
    evidence.frozenClockEpisodes = 0
    evidence.hiddenVideoSeconds = 0
    evidence.visibleVideoSeconds = 2
    XCTAssertFalse(evidence.clean, "Visible playback still owes fresh decoded frames")
    evidence.decodedSizes = ["1920x1080": 8]
    XCTAssertTrue(evidence.clean)
    evidence.decodeRecoveryObserved = true
    XCTAssertFalse(evidence.clean, "A fixed-quality override is never an Auto pass")
  }

  func testProgressCheckpointsOverwriteOnlyProgressAndArchiveOnceAtCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnostics = root.appendingPathComponent("source")
    let output = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
    let name = "playback-fixture-0001.jsonl"
    try Data("fixture\n".utf8).write(to: diagnostics.appendingPathComponent(name))
    let sink = Sink(directory: output, diagnosticsDirectory: diagnostics)
    var evidence = Evidence(channel: "fixture", phase: "single")
    for elapsed in [30.0, 60.0, 90.0] {
      evidence.observedSeconds = elapsed
      try await sink.save(evidence, name: "fixture-single")
    }
    evidence.status = "failed"
    try await sink.save(evidence, name: "fixture-single")
    try await sink.archive(session: "fixture", folder: "fixture-single-complete")
    let saved = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: output.appendingPathComponent("fixture-single.json")))
    XCTAssertEqual(saved.observedSeconds, 90)
    XCTAssertEqual(saved.status, "failed")
    XCTAssertTrue(FileManager.default.fileExists(atPath:
      output.appendingPathComponent("diagnostics/fixture-single-complete/" + name).path))
  }

  func testOptInLongVariedLivePlaybackSoak() async throws {
    #if targetEnvironment(simulator)
    executionTimeAllowance = 18_000
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_LONG_SOAK"] == "1",
      let names = settings["STROZZ_SOAK_CANDIDATES"] else {
      throw XCTSkip("Explicitly enable STROZZ_LONG_SOAK and choose live candidate logins on an isolated simulator.")
    }
    do { try await Self.runLongSoak(settings: settings, names: names) }
    catch {
      let failure = error as NSError
      XCTFail("Soak failed: \(failure.domain):\(failure.code); task_cancelled=\(Task.isCancelled)")
      throw error
    }
    #else
    throw XCTSkip("The long soak must never take over a physical TV.")
    #endif
  }

  private static func runLongSoak(settings: [String: String], names: String) async throws {
    let candidates = names.split(separator: ",").map(String.init)
    let mode = settings["STROZZ_SOAK_MODE"] ?? "all"
    guard (6...16).contains(candidates.count), Set(candidates).count == candidates.count,
      ["all", "followup", "multiview"].contains(mode),
      candidates.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }),
      let seconds = Int(settings["STROZZ_SOAK_SECONDS"] ?? "1800"), (1800...3600).contains(seconds),
      let multiviewSeconds = Int(settings["STROZZ_SOAK_MULTIVIEW_SECONDS"] ?? "900"),
      (900...1800).contains(multiviewSeconds),
      let paneCount = Int(settings["STROZZ_SOAK_MULTIVIEW_PANES"] ?? "4"), (2...4).contains(paneCount) else {
      return XCTFail("Use 6...16 distinct logins, 1800...3600-second single stages, 900...1800-second multiview stages and 2...4 panes.")
    }
    let directory = URL.cachesDirectory.appendingPathComponent("PlaybackSoak/\(UUID().uuidString)", isDirectory: true)
    let sink = Sink(directory: directory,
      diagnosticsDirectory: URL.cachesDirectory.appendingPathComponent(PlaybackTelemetryRecorder.directoryName))
    print("SOAK_OUTPUT \(directory.path)")
    print("SOAK_TIME_ALLOWANCE 18000")
    var inputs: [Input] = []
    var unavailable: [String: String] = [:]
    for channel in candidates {
      do { inputs.append(try await describe(channel)) }
      catch {
        let error = error as NSError
        unavailable[channel] = "\(error.domain):\(error.code)"
      }
    }
    try await sink.save(inputs, name: "available-inputs")
    try await sink.save(unavailable, name: "unavailable-candidates")
    let completed = Set((settings["STROZZ_SOAK_COMPLETED_CHANNELS"] ?? "").split(separator: ",").map(String.init))
    let required = mode == "all" ? 6 : paneCount
    var selected: [Input] = []
    let replacement = mode == "followup" ? inputs.first(where: { !completed.contains($0.channel) }) : inputs.first
    if let replacement { selected.append(replacement) }
    for input in inputs where selected.count < required {
      if !selected.contains(where: { $0.channel == input.channel }),
        !selected.contains(where: { $0.format == input.format && $0.frameRate == input.frameRate }) {
        selected.append(input)
      }
    }
    for input in inputs where selected.count < required && !selected.contains(where: { $0.channel == input.channel }) {
      selected.append(input)
    }
    try await sink.save(selected, name: "selected-inputs")
    guard selected.count == required else { return XCTFail("Insufficient live inputs; coverage is incomplete") }
    if Set(selected.map(\.format)).count < 2 {
      XCTFail("Only one input container is currently available; TS/CMAF coverage is incomplete")
    }
    let singles = mode == "multiview" ? [] : (mode == "followup" ? replacement.map { [$0] } ?? [] : selected)
    if mode == "followup", replacement == nil { XCTFail("No new live single-stream replacement is available") }
    for input in singles {
      try Task.checkCancellation()
      try await single(input, seconds: seconds, sink: sink)
    }
    try await multiview(Array(selected.prefix(paneCount)), seconds: multiviewSeconds, sink: sink)
  }

  private static func describe(_ channel: String) async throws -> Input {
    let playback = try await PlaybackService.resolve(for: channel)
    guard let highest = playback.qualities.filter({ !$0.isAudioOnly }).max(by: { $0.bitrate < $1.bitrate }) else {
      throw URLError(.resourceUnavailable)
    }
    func fetch(_ url: URL) async throws -> Data {
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      PlaybackService.streamHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
      let (bytes, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
      return bytes
    }
    let master = String(decoding: try await fetch(playback.master), as: UTF8.self)
    let descriptions = master.components(separatedBy: .newlines)
      .filter { $0.hasPrefix("#EXT-X-STREAM-INF:") && !NativeCMAF.isAudioOnlyVariant($0) }
      .map { NativeCMAF.attributes(String($0.dropFirst("#EXT-X-STREAM-INF:".count))) }
    guard let description = descriptions.max(by: {
      (Int($0["BANDWIDTH"] ?? "") ?? 0) < (Int($1["BANDWIDTH"] ?? "") ?? 0)
    }) else { throw URLError(.cannotParseResponse) }
    let began = ProcessInfo.processInfo.systemUptime
    let bytes = try await fetch(highest.url)
    let elapsed = ProcessInfo.processInfo.systemUptime - began
    let manifest = try NativeCMAF.manifest(String(decoding: bytes, as: UTF8.self), url: highest.url)
    let tail = manifest.entries.last { $0.date != nil && $0.duration != nil }
    let dateAge = tail.flatMap { entry in
      entry.date.flatMap { date in entry.duration.map { Date().timeIntervalSince(date.addingTimeInterval($0)) } }
    }
    return Input(channel: channel, format: manifest.initialization == nil ? "ts" : "cmaf",
      frameRate: description["FRAME-RATE"] ?? "unknown", resolution: description["RESOLUTION"] ?? "unknown",
      bitrate: highest.bitrate, codecs: description["CODECS"] ?? "unknown",
      targetDuration: manifest.targetDuration, incrementalPrefetch: manifest.hasPrefetch,
      playlistFetchSeconds: elapsed, playlistTailDateAgeSeconds: dateAge,
      deliveryHost: PlaybackTelemetryRecorder.host(highest.url.absoluteString))
  }

  private static func single(_ input: Input, seconds: Int, sink: Sink) async throws {
    let environment = AppEnvironment()
    let model = PlayerModel()
    model.player.isMuted = true
    let suite = "PlaybackSoak.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    let window = try keyWindow()
    let previous = window.rootViewController
    let view = PlayerView(channel: input.channel, auth: environment.auth, model: model)
    let host = UIHostingController(rootView: view.environment(environment).defaultAppStorage(defaults))
    window.rootViewController = host
    defer {
      window.rootViewController = previous
      model.nativeRefreshTask?.cancel()
      model.fallbackRestoreTask?.cancel()
      model.channelMetadataTask?.cancel()
      view.cancelNativeStartup()
      view.stopLatencyMonitor()
      view.stopPlaybackWatchdog()
      model.nativeHLS?.stop()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
      defaults.removePersistentDomain(forName: suite)
    }
    guard await ready([model]) else {
      try await sink.save(Evidence(channel: input.channel, phase: "startup", status: "incomplete_startup"),
        name: input.channel + "-startup")
      XCTFail("\(input.channel): startup did not become native with fresh video")
      return
    }
    try await observe([model], channels: [input.channel], phase: "single", seconds: seconds, sink: sink)
  }

  private static func multiview(_ inputs: [Input], seconds: Int, sink: Sink) async throws {
    let environment = AppEnvironment()
    let channels = inputs.map {
      FollowedChannel(id: $0.channel, login: $0.channel, displayName: $0.channel, title: "",
        gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    }
    let controller = MultiviewController(channels: channels, muted: true)
    let window = try keyWindow()
    let previous = window.rootViewController
    let host = UIHostingController(rootView: MultiviewPlayerView(channels: channels,
      availableChannels: channels, auth: environment.auth, goLive: nil, onWatch: { _ in }, controller: controller)
      .environment(environment).environment(\.themePalette, ThemePalette.dark))
    window.rootViewController = host
    defer { controller.teardown(); window.rootViewController = previous }
    let models = controller.panes.map(\.model)
    guard await ready(models) else { return XCTFail("Multiview startup incomplete") }
    let logins = controller.panes.map(\.channel.login)
    try await observe(models, channels: logins, phase: "grid", seconds: seconds, sink: sink)
    let players = models.map(\.player)
    let items = players.map(\.currentItem)
    controller.expand(controller.panes[0].id)
    try await observe(models, channels: logins, phase: "expanded", seconds: seconds, sink: sink)
    controller.collapse()
    try await observe(models, channels: logins, phase: "returned_grid", seconds: seconds, sink: sink)
    for (index, model) in models.enumerated() {
      XCTAssertTrue(model.player === players[index], "Expansion must retain player ownership")
      XCTAssertTrue(model.player.currentItem === items[index], "Expansion must retain item ownership")
    }
  }

  private static func observe(_ models: [PlayerModel], channels: [String], phase: String,
                       seconds: Int, sink: Sink) async throws {
    let watches = zip(models, channels).map { Watch(model: $0.0, channel: $0.1, phase: phase, seconds: seconds) }
    defer { watches.forEach { $0.stop() } }
    let began = ProcessInfo.processInfo.systemUptime
    var previous = began
    var savedAt = began
    var archived = Array(repeating: 0, count: watches.count)
    var incidentCounts = Array(repeating: 0, count: watches.count)
    print("SOAK_BEGIN \(channels.joined(separator: ",")) \(phase) \(seconds)s")
    while ProcessInfo.processInfo.systemUptime - began < Double(seconds) {
      do { try await Task.sleep(for: .milliseconds(250)) }
      catch {
        print("SOAK_CANCELLED \(phase) after=\(ProcessInfo.processInfo.systemUptime - began) cancelled=\(Task.isCancelled)")
        throw error
      }
      let now = ProcessInfo.processInfo.systemUptime
      watches.forEach { $0.sample(interval: now - previous) }
      previous = now
      for (index, watch) in watches.enumerated() {
        let incidents = watch.evidence.stallNotifications + watch.evidence.failedToEnd
          + watch.evidence.itemReplacements + watch.evidence.playerReplacements
        if incidents > incidentCounts[index], archived[index] < 4 {
          incidentCounts[index] = incidents
          archived[index] += 1
          await watch.model.playbackTelemetry.flush()
          if let session = watch.model.playbackTelemetry.sessionID {
            try await sink.archive(session: session,
              folder: "\(watch.evidence.channel)-\(phase)-incident\(archived[index])")
          } else { XCTFail("Missing telemetry session while preserving an incident") }
        }
      }
      if now - savedAt >= 30 {
        for watch in watches {
          try await sink.save(watch.evidence, name: watch.evidence.channel + "-" + phase)
        }
        print("SOAK_PROGRESS \(phase) \(Int(now - began))/\(seconds)")
        savedAt = now
      }
      if models.contains(where: { $0.isOffline || $0.isUserPaused || $0.isSleeping }) {
        for watch in watches {
          watch.evidence.status = "incomplete_ended_or_interfered"
          try await sink.save(watch.evidence, name: watch.evidence.channel + "-" + phase)
        }
        XCTFail("\(phase): input ended or viewing intent changed; not a completed soak")
        return
      }
    }
    for watch in watches {
      watch.evidence.status = watch.evidence.verdict
      try await sink.save(watch.evidence, name: watch.evidence.channel + "-" + phase)
      await watch.model.playbackTelemetry.flush()
      if let session = watch.model.playbackTelemetry.sessionID {
        try await sink.archive(session: session, folder: watch.evidence.channel + "-" + phase + "-complete")
      } else { XCTFail("Missing telemetry session at the end of a stage") }
      print("SOAK_END \(watch.evidence.channel) \(phase) \(watch.evidence.status) stalls=\(watch.evidence.stallNotifications) failures=\(watch.evidence.failedToEnd)")
      XCTAssertTrue(watch.evidence.clean, "\(watch.evidence.channel) \(phase): interruptions or missing evidence; see persisted soak report")
    }
  }

  private static func ready(_ models: [PlayerModel]) async -> Bool {
    for _ in 0..<450 {
      if models.allSatisfy({ $0.nativeStartupComplete && $0.nativeControlledAuto && !$0.isLoading
        && $0.player.timeControlStatus == .playing && $0.playbackTelemetry.videoFrameAge.map({ $0 < 3 }) == true }) {
        return true
      }
      if models.contains(where: { $0.isOffline || $0.errorMessage != nil }) { return false }
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
    }
    return false
  }

  private static func keyWindow() throws -> UIWindow {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    return try XCTUnwrap(scene.keyWindow)
  }
}

import Foundation
import Observation
import OSLog

struct CreatorLiveSources: Equatable, Codable, Sendable {
  let root: PlatformLiveTarget
  var twitch: String?
  var kick: String?
  var youtube: String?

  init(root: PlatformLiveTarget) {
    self.root = root
    set(root)
  }

  var targets: [PlatformLiveTarget] {
    [twitch.map { .init(platform: .twitch, channel: $0) },
     kick.map { .init(platform: .kick, channel: $0) },
     youtube.map { .init(platform: .youtube, channel: $0) }].compactMap { $0 }
  }

  func contains(_ target: PlatformLiveTarget) -> Bool {
    targets.contains { $0.platform == target.platform && Self.key($0) == Self.key(target) }
  }

  mutating func set(_ target: PlatformLiveTarget) {
    switch target.platform {
    case .twitch: twitch = target.channel.lowercased()
    case .kick: kick = target.channel.lowercased()
    case .youtube: youtube = target.channel
    }
  }

  static func key(_ target: PlatformLiveTarget) -> String {
    switch target.platform {
    case .twitch, .kick: return target.channel.lowercased()
    case .youtube: return CreatorSourceResolver.youtubeTarget(target.channel) ?? target.channel
    }
  }
}

@MainActor
enum CreatorSourceResolver {
  static func resolve(_ root: PlatformLiveTarget) async throws -> CreatorLiveSources {
    let kickAliases = KickAliasService()
    let youtubeAliases = TwitchYouTubeAliasService()
    await kickAliases.refreshIfNeeded()
    await youtubeAliases.refreshIfNeeded()
    try Task.checkCancellation()
    var result = CreatorLiveSources(root: root)
    switch root.platform {
    case .twitch:
      result.kick = kickAliases.kickSlug(forTwitchLogin: root.channel)
      result.youtube = youtubeAliases.youtubeChannelID(forTwitchLogin: root.channel)
    case .kick:
      let channel = try await KickPlaybackService.channel(root.channel)
      result.youtube = channel.youtubeTarget
      result.twitch = uniqueKey(for: root.channel, in: kickAliases.aliases)
      if result.twitch == nil, let youtube = channel.youtubeTarget {
        result.twitch = uniqueKey(for: youtube, in: youtubeAliases.aliases, youtube: true)
      }
      if result.twitch == nil {
        // A same-name account is only a candidate: require an explicit reciprocal
        // link or a shared, explicitly published YouTube identity before joining it.
        if let profile = await ChannelProfileService.fetch(login: root.channel),
          provesKickIdentity(profile, kick: root.channel, youtube: channel.youtubeTarget) {
          result.twitch = root.channel
        }
      }
    case .youtube:
      result.twitch = uniqueKey(for: root.channel, in: youtubeAliases.aliases, youtube: true)
    }
    try Task.checkCancellation()
    if let twitch = result.twitch {
      if let alias = kickAliases.kickSlug(forTwitchLogin: twitch), result.kick == nil {
        result.kick = alias
      }
      if let alias = youtubeAliases.youtubeChannelID(forTwitchLogin: twitch), result.youtube == nil {
        result.youtube = alias
      }
      if let profile = await ChannelProfileService.fetch(login: twitch) {
        if result.kick == nil {
          let links = Set(profile.socialLinks.compactMap { kickTarget($0.url) })
          if links.count == 1 { result.kick = links.first }
        }
        if result.youtube == nil {
          let links = Set(profile.socialLinks.compactMap { youtubeTarget($0.url) })
          if links.count == 1 { result.youtube = links.first }
        }
      }
    }
    try Task.checkCancellation()
    return result
  }

  static func uniqueKey(for value: String, in aliases: [String: String], youtube: Bool = false) -> String? {
    guard let expected = youtube ? youtubeTarget(value) : value.lowercased() else { return nil }
    let matches = aliases.filter {
      (youtube ? youtubeTarget($0.value) : $0.value.lowercased()) == expected
    }.keys
    return matches.count == 1 ? matches.first : nil
  }

  static func kickTarget(_ input: String) -> String? {
    guard input.lowercased().contains("kick.com/") else { return nil }
    return try? KickPlaybackService.slug(from: input)
  }

  nonisolated static func youtubeTarget(_ input: String) -> String? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("@"), value.range(of: #"^@[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil {
      return value.lowercased()
    }
    if value.hasPrefix("UC"), value.range(of: #"^UC[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
      return value
    }
    let full = value.contains("://") ? value : "https://www.youtube.com/\(value)"
    guard let url = URL(string: full), url.scheme == "https", url.user == nil, url.password == nil,
      ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(url.host?.lowercased() ?? "")
    else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    if let handle = parts.first, handle.hasPrefix("@") { return handle.lowercased() }
    if parts.count >= 2, parts[0] == "channel", parts[1].hasPrefix("UC") { return parts[1] }
    return nil
  }

  private static func provesKickIdentity(_ profile: ChannelProfile, kick: String, youtube: String?) -> Bool {
    if profile.socialLinks.contains(where: { kickTarget($0.url) == kick }) { return true }
    guard let youtube, let key = youtubeTarget(youtube) else { return false }
    return profile.socialLinks.contains { youtubeTarget($0.url) == key }
  }
}

enum CreatorViewerSnapshot: Equatable, Sendable {
  case live(Int?), offline, unknown
}

/// Chat and statistics belong to the creator. Video items/qualities never own
/// or restart this session.
@MainActor
@Observable
final class CreatorLiveSession {
  let chat: ChatService
  let hermes: HermesEventService
  private(set) var sources: CreatorLiveSources?
  private(set) var videoTarget: PlatformLiveTarget?
  private(set) var identityError: String?
  private(set) var generation = UUID()
  @ObservationIgnored private var resolveTask: Task<Void, Never>?
  @ObservationIgnored private var statisticsTask: Task<Void, Never>?
  private var statisticsTwitch: String?
  private var statisticsKick: String?
  private var statisticsYoutube: String?
  private var kickChatEnabled = true
  private var youtubeChatEnabled = true
  private var suspended = false
  private var twitchSnapshot = CreatorViewerSnapshot.unknown
  private var kickSnapshot = CreatorViewerSnapshot.unknown
  private var twitchObservedAt: Date?
  private var kickObservedAt: Date?
  private var youtubeCount: Int?
  private var youtubeObservedAt: Date?
  private var youtubeAttemptedAt: Date?
  private var statisticsRevision = 0
  private var statisticsFlight: UUID?
  private var statisticsRefreshPending = false
  private let resolve: (PlatformLiveTarget) async throws -> CreatorLiveSources
  private let loadTwitch: (String) async -> CreatorViewerSnapshot
  private let loadKick: (String) async throws -> KickChannel
  private let loadYouTube: (String) async -> CreatorViewerSnapshot
  private let wait: () async throws -> Void
  private let now: () -> Date
  private let defaults: UserDefaults?
  private static let savedLinksKey = "creatorLinkedChannels.v1"
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "creator-session")

  init(chat: ChatService = ChatService(), hermes: HermesEventService = HermesEventService(),
       resolve: @escaping (PlatformLiveTarget) async throws -> CreatorLiveSources = CreatorSourceResolver.resolve,
       loadTwitch: @escaping (String) async -> CreatorViewerSnapshot = CreatorLiveSession.twitchViewers,
       loadKick: @escaping (String) async throws -> KickChannel = { try await KickPlaybackService.channel($0) },
       loadYouTube: @escaping (String) async -> CreatorViewerSnapshot = CreatorLiveSession.youtubeViewers,
       wait: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(30)) },
       now: @escaping () -> Date = Date.init, defaults: UserDefaults? = .standard) {
    self.chat = chat
    self.hermes = hermes
    self.resolve = resolve
    self.loadTwitch = loadTwitch
    self.loadKick = loadKick
    self.loadYouTube = loadYouTube
    self.wait = wait
    self.now = now
    self.defaults = defaults
  }

  var twitchChannel: String? { sources?.twitch }
  var isActive: Bool { sources != nil && !suspended }
  var chatPlatform: LivePlatform { twitchChannel == nil ? sources?.root.platform ?? .twitch : .twitch }
  var targets: [PlatformLiveTarget] { sources?.targets ?? [] }

  var viewerCounts: [PlatformViewerCount] {
    _ = statisticsRevision
    var values: [PlatformViewerCount] = []
    if let date = twitchObservedAt, (0..<90).contains(now().timeIntervalSince(date)),
      case .live(let snapshot) = twitchSnapshot,
      let count = hermes.viewerCountUpdatedAt.map({ (0..<90).contains(now().timeIntervalSince($0)) }) == true
        ? hermes.viewerCount ?? snapshot : snapshot {
      values.append(.init(platform: .twitch, count: count))
    }
    if let date = kickObservedAt, (0..<90).contains(now().timeIntervalSince(date)),
      case .live(let count?) = kickSnapshot {
      values.append(.init(platform: .kick, count: count))
    }
    if sources?.youtube != nil, let date = youtubeObservedAt,
      (0..<120).contains(now().timeIntervalSince(date)), let count = youtubeCount {
      values.append(.init(platform: .youtube, count: count))
    }
    return values
  }

  deinit {
    resolveTask?.cancel()
    statisticsTask?.cancel()
    let chat = chat
    let hermes = hermes
    Task { @MainActor in chat.disconnect(); hermes.stop() }
  }

  func start(_ root: PlatformLiveTarget) {
    if sources?.contains(root) == true { return }
    stop()
    let saved = Self.savedSources(for: root, defaults: defaults)
    sources = saved ?? CreatorLiveSources(root: root)
    videoTarget = root
    suspended = false
    identityError = nil
    apply()
    if saved == nil { resolveLinks() }
    startStatistics()
  }

  /// A channel entered through Stream Source is an explicit creator link. A
  /// different channel on the creator's root platform is a different creator.
  func selectVideo(_ target: PlatformLiveTarget) {
    guard var links = sources else { start(target); return }
    if links.contains(target) { videoTarget = target; return }
    if links.targets.contains(where: { $0.platform == target.platform }) { start(target); return }
    links.set(target)
    sources = links
    videoTarget = target
    apply()
    saveSources()
  }

  func updateLinkedTarget(_ target: PlatformLiveTarget) {
    guard var links = sources else { return }
    guard !links.contains(target) else { identityError = nil; return }
    guard links.root.platform != target.platform else {
      identityError = String(localized: "Open a different channel to change the creator's primary account.")
      return
    }
    links.set(target)
    updateLinks(links.targets)
  }

  func updateLinks(_ targets: [PlatformLiveTarget]) {
    guard let previous = sources else { return }
    do {
      var changed = CreatorLiveSources(root: previous.root)
      for target in targets {
        let valid = try PlatformLiveTarget.validated(platform: target.platform, input: target.channel)
        if valid.platform == previous.root.platform,
          CreatorLiveSources.key(valid) != CreatorLiveSources.key(previous.root) {
          throw PlatformLiveTarget.Failure.invalidChannel(valid.platform)
        }
        changed.set(valid)
      }
      if let videoTarget, !changed.contains(videoTarget) {
        identityError = String(localized: "Keep the currently playing channel linked, or switch video first.")
        return
      }
      identityError = nil
      resolveTask?.cancel()
      resolveTask = nil
      guard changed != previous else { saveSources(); return }
      generation = UUID()
      resolveTask?.cancel()
      statisticsTask?.cancel()
      statisticsFlight = nil
      statisticsRefreshPending = false
      chat.disconnect()
      sources = changed
      identityError = nil
      apply()
      startStatistics()
      saveSources()
    } catch {
      identityError = error.localizedDescription
    }
  }

  func configureChat(kickEnabled: Bool, youtubeEnabled: Bool) {
    kickChatEnabled = kickEnabled
    youtubeChatEnabled = youtubeEnabled
    apply()
  }

  func suspend() {
    guard sources != nil, !suspended else { return }
    suspended = true
    chat.disconnect()
    hermes.stop()
    statisticsTwitch = nil
    statisticsKick = nil
    statisticsYoutube = nil
    statisticsTask?.cancel()
  }

  func resume() {
    guard suspended else { return }
    suspended = false
    apply()
    startStatistics()
  }

  func stop() {
    generation = UUID()
    resolveTask?.cancel()
    statisticsTask?.cancel()
    resolveTask = nil
    statisticsTask = nil
    chat.disconnect()
    hermes.stop()
    statisticsTwitch = nil
    statisticsKick = nil
    statisticsYoutube = nil
    sources = nil
    videoTarget = nil
    twitchSnapshot = .unknown
    kickSnapshot = .unknown
    twitchObservedAt = nil
    kickObservedAt = nil
    youtubeCount = nil
    youtubeObservedAt = nil
    youtubeAttemptedAt = nil
    statisticsRefreshPending = false
    statisticsFlight = nil
    suspended = false
  }

  private func resolveLinks() {
    guard let initial = sources else { return }
    let epoch = generation
    let resolve = resolve
    resolveTask = Task { [weak self] in
      do {
        let resolved = try await resolve(initial.root)
        guard let self, !Task.isCancelled, generation == epoch, var current = sources,
          current.root == initial.root else { return }
        for target in resolved.targets {
          if current.targets.contains(where: { $0.platform == target.platform }) { continue }
          current.set(target)
        }
        sources = current
        apply()
        await refreshStatistics(epoch: epoch)
      } catch {
        guard let self, !Task.isCancelled, generation == epoch else { return }
        identityError = String(localized: "Some linked channels could not be resolved.")
        Self.logger.warning("Creator links unavailable: \((error as NSError).domain) \((error as NSError).code)")
      }
    }
  }

  private func apply() {
    guard let sources, !suspended else { return }
    chat.configureCreator(twitch: sources.twitch, kick: sources.kick, youtube: sources.youtube,
      kickEnabled: kickChatEnabled, youtubeEnabled: youtubeChatEnabled)
    if statisticsTwitch != sources.twitch {
      hermes.stop()
      statisticsTwitch = sources.twitch
      twitchSnapshot = .unknown
      twitchObservedAt = nil
      if let twitch = sources.twitch { hermes.start(forChannel: twitch) }
    }
    if statisticsKick != sources.kick {
      statisticsKick = sources.kick
      kickSnapshot = .unknown
      kickObservedAt = nil
    }
    if statisticsYoutube != sources.youtube {
      statisticsYoutube = sources.youtube
      youtubeCount = nil
      youtubeObservedAt = nil
      youtubeAttemptedAt = nil
    }
  }

  private func startStatistics() {
    statisticsTask?.cancel()
    guard !suspended else { return }
    let epoch = generation
    let wait = wait
    statisticsTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshStatistics(epoch: epoch)
        do { try await wait() } catch { return }
        guard self?.generation == epoch else { return }
      }
    }
  }

  func refreshStatistics(epoch: UUID) async {
    guard epoch == generation, let links = sources, !suspended else { return }
    guard statisticsFlight == nil else { statisticsRefreshPending = true; return }
    let flight = UUID()
    statisticsFlight = flight
    defer {
      if statisticsFlight == flight {
        statisticsFlight = nil
        statisticsRevision += 1
        if statisticsRefreshPending {
          statisticsRefreshPending = false
          Task { [weak self] in
            guard let self else { return }
            await refreshStatistics(epoch: generation)
          }
        }
      }
    }
    if let twitch = links.twitch {
      let result = await loadTwitch(twitch)
      guard epoch == generation, sources?.twitch == twitch, !Task.isCancelled, !suspended else { return }
      if result != .unknown {
        twitchSnapshot = result
        twitchObservedAt = now()
        if case .live(let count) = result { hermes.seedViewerCount(count) }
      }
    }
    if let kick = links.kick {
      do {
        let channel = try await loadKick(kick)
        guard epoch == generation, sources?.kick == kick, !Task.isCancelled, !suspended else { return }
        kickSnapshot = channel.isLive ? .live(channel.viewerCount) : .offline
        kickObservedAt = now()
      } catch {
        guard !Task.isCancelled else { return }
        Self.logger.warning("Creator Kick statistics unavailable: \((error as NSError).domain) \((error as NSError).code)")
      }
    }
    if let youtube = links.youtube {
      if youtubeAttemptedAt.map({ now().timeIntervalSince($0) >= 90 }) ?? true {
        youtubeAttemptedAt = now()
        let result = await loadYouTube(youtube)
        guard epoch == generation, sources?.youtube == youtube,
          !Task.isCancelled, !suspended else { return }
        if result != .unknown {
          if case .live(let count) = result { youtubeCount = count } else { youtubeCount = nil }
          youtubeObservedAt = now()
        }
      }
    }
  }

  static func twitchViewers(_ channel: String) async -> CreatorViewerSnapshot {
    async let status = PlaybackService.streamLiveStatus(for: channel)
    async let metadata = PlaybackService.channelMetadata(for: channel)
    switch await status {
    case .offline: return .offline
    case .live: return .live(await metadata?.viewersCount)
    case .unknown: return .unknown
    }
  }

  static func youtubeViewers(_ channel: String) async -> CreatorViewerSnapshot {
    do {
      let videoID = try await AltSourceService.resolveLiveVideoID(from: channel)
      if let count = await YouTubeConcurrentViewersService.fetchConcurrentViewers(videoID: videoID) {
        return .live(count)
      }
    } catch AltSourceService.ResolutionError.noLiveVideo {
      return .offline
    } catch {
      if !Task.isCancelled {
        logger.warning("Creator YouTube statistics unavailable: \((error as NSError).domain) \((error as NSError).code)")
      }
    }
    return .unknown
  }

  static func savedSources(for root: PlatformLiveTarget, defaults: UserDefaults? = .standard) -> CreatorLiveSources? {
    guard let data = defaults?.data(forKey: Self.savedLinksKey) else { return nil }
    do {
      let saved = try JSONDecoder().decode([CreatorLiveSources].self, from: data)
      let matches = saved.filter { $0.contains(root) }
      let exact = matches.filter { $0.root == root }
      guard let selected = exact.count == 1 ? exact.first : matches.count == 1 ? matches.first : nil else { return nil }
      var result = CreatorLiveSources(root: root)
      for target in selected.targets {
        result.set(try PlatformLiveTarget.validated(platform: target.platform, input: target.channel))
      }
      return result
    } catch {
      Self.logger.error("Saved creator links invalid: \((error as NSError).domain) \((error as NSError).code)")
      return nil
    }
  }

  private func saveSources() {
    guard let defaults, let sources else { return }
    do {
      var saved: [CreatorLiveSources] = []
      if let data = defaults.data(forKey: Self.savedLinksKey) {
        saved = try JSONDecoder().decode([CreatorLiveSources].self, from: data)
      }
      saved.removeAll { saved in sources.targets.contains(where: saved.contains) }
      saved.append(sources)
      defaults.set(try JSONEncoder().encode(Array(saved.suffix(120))), forKey: Self.savedLinksKey)
    } catch {
      identityError = String(localized: "Creator channel links could not be saved.")
      Self.logger.error("Creator links save failed: \((error as NSError).domain) \((error as NSError).code)")
    }
  }
}

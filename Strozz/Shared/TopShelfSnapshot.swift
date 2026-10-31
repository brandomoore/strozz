import Foundation

/// A lightweight, `Codable` snapshot of the channels Strozz wants to surface in
/// the tvOS Top Shelf. The main app writes this into the shared App Group
/// container; the Top Shelf extension (a separate process) reads it back.
///
/// Keeping this intentionally small and dependency-free means it can be
/// compiled into both the app and the extension without dragging the rest of
/// the app's networking/UI stack into the extension's tight memory budget.
struct TopShelfSnapshot: Codable, Equatable {
    /// When the snapshot was produced. Used purely for debugging/freshness.
    var generatedAt: Date

    /// Ordered list of carousels to render in the Top Shelf.
    var sections: [Section]

    struct Section: Codable, Equatable, Identifiable {
        /// Stable identifier for the section (e.g. "following", "trending").
        var id: String
        /// User-facing carousel title (e.g. "Following · Live now").
        var title: String
        var items: [Item]
    }

    struct Item: Codable, Equatable, Identifiable {
        /// Stable provider-qualified channel key; older snapshots contain Twitch IDs.
        var id: String
        /// Provider-native channel login used to launch playback via deep link.
        var login: String
        var displayName: String
        var title: String
        var gameName: String
        var thumbnailURL: URL?
        var viewerCount: Int?
        var sourcePlatform: String? = nil
        /// Confirmed Twitch identity shared by linked sources, never inferred from a handle.
        var creatorKey: String? = nil
        /// Individual live sources retain their own counts for independent refresh.
        var sources: [Item]? = nil
        var channelKey: String {
            sourcePlatform == "kick" ? "kick:\(login.lowercased())" : login.lowercased()
        }
        var identityKey: String { creatorKey ?? channelKey }
    }

    init(generatedAt: Date = Date(), sections: [Section]) {
        self.generatedAt = generatedAt
        self.sections = sections
    }

    static func sourceItems(in items: [Item]) -> [Item] {
        items.flatMap { $0.sources ?? [$0] }
    }

    static func mergingCreators(_ items: [Item], knownItems: [Item] = []) -> [Item] {
        let knownCreators = Set(sourceItems(in: knownItems + items).compactMap(\.creatorKey))
        var groups: [String: [Item]] = [:]
        var order: [String] = []
        var seen = Set<String>()
        for var item in sourceItems(in: items) where seen.insert(item.channelKey).inserted {
            item.sources = nil
            if item.sourcePlatform != "kick", knownCreators.contains(item.channelKey) {
                item.creatorKey = item.channelKey
            }
            if groups[item.identityKey] == nil { order.append(item.identityKey) }
            groups[item.identityKey, default: []].append(item)
        }
        return order.compactMap { key in
            guard let sources = groups[key],
                  var primary = sources.first(where: { $0.sourcePlatform != "kick" }) ?? sources.first else { return nil }
            let counts = sources.compactMap(\.viewerCount)
            primary.viewerCount = counts.isEmpty ? nil : counts.reduce(0, +)
            primary.sources = sources.count > 1 ? sources : nil
            return primary
        }
    }
}

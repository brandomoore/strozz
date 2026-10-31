import Foundation
import TVServices

/// Bridges the app's live channel data into the shared Top Shelf snapshot.
///
/// The Top Shelf extension is a separate process that cannot see the app's
/// in-memory state, so the app publishes a small JSON snapshot into the shared
/// App Group container whenever its data refreshes. The extension just renders
/// the snapshot and refreshes live status through the provider's public or
/// authorized API without sharing credentials between providers.
@MainActor
enum TopShelfPublisher {
    /// Maximum items per carousel. The Top Shelf has limited horizontal space
    /// and the system only shows a handful before "see all".
    private static let maxItemsPerSection = 12

    /// Builds and persists a snapshot from the current Following + Trending
    /// data. `isUsingDemoData` flips the primary section's title between a
    /// personalised "Following" feed and an anonymous "Trending" feed.
    static func publish(
        followed: [FollowedChannel],
        isUsingDemoData: Bool,
        recommended: [FollowedChannel]
    ) {
        var sections: [TopShelfSnapshot.Section] = []

        let links = KickUnifiedFeed.confirmedLinks(for: followed + recommended)
        let primaryItems = makeItems(from: followed.filter(\.isLive), links: links)
        if !primaryItems.isEmpty {
            sections.append(
                TopShelfSnapshot.Section(
                    id: isUsingDemoData ? "trending" : "following",
                    title: isUsingDemoData ? "Trending now" : "Following · Live now",
                    items: primaryItems
                )
            )
        }

        // Avoid duplicating channels already shown in the primary section.
        let primaryLogins = Set(primaryItems.map(\.identityKey))
        let recommendedItems = makeItems(from: recommended.filter {
            $0.isLive && KickUnifiedFeed.identityKeys(for: $0, links: links).isDisjoint(with: primaryLogins)
        }, links: links)
        if !recommendedItems.isEmpty {
            sections.append(
                TopShelfSnapshot.Section(
                    id: "recommended",
                    title: "Recommended",
                    items: recommendedItems
                )
            )
        }

        // If nothing live is available, clear the snapshot so the Top Shelf
        // falls back to the app's default banner instead of stale content.
        guard !sections.isEmpty else {
            persist(TopShelfSnapshot(sections: []))
            return
        }

        persist(TopShelfSnapshot(sections: sections))
    }

    /// Saves the snapshot and tells tvOS its Top Shelf content changed.
    ///
    /// Writing the snapshot alone is not enough: the system caches whatever the
    /// extension returned the last time it queried it (often empty, captured at
    /// install time before the app had published anything). Without this
    /// notification tvOS never re-invokes the extension, so the shelf stays
    /// stale. This call forces a reload from the freshly written snapshot.
    private static func persist(_ snapshot: TopShelfSnapshot) {
        TopShelfStore.save(snapshot)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func makeItems(from channels: [FollowedChannel], links: [String: String]) -> [TopShelfSnapshot.Item] {
        func item(_ channel: FollowedChannel, creatorKey: String?) -> TopShelfSnapshot.Item {
            TopShelfSnapshot.Item(
                id: channel.channelKey,
                login: channel.login.lowercased(),
                displayName: channel.displayName,
                title: channel.title,
                gameName: channel.gameName,
                thumbnailURL: channel.thumbnailURL,
                viewerCount: channel.viewerCount,
                sourcePlatform: channel.platform.rawValue,
                creatorKey: creatorKey
            )
        }
        let sources = channels.flatMap { channel -> [TopShelfSnapshot.Item] in
            let keys = KickUnifiedFeed.identityKeys(for: channel, links: links)
            let creatorKey = keys.count > 1 ? keys.first { !$0.hasPrefix("kick:") } : nil
            var result = [item(channel, creatorKey: creatorKey)]
            if channel.platform == .twitch, let kick = channel.kick, kick.isLive,
               keys.contains("kick:\(kick.slug)") {
                result.append(item(kick.followedChannel, creatorKey: creatorKey))
            }
            return result
        }
        return Array(TopShelfSnapshot.mergingCreators(sources).prefix(maxItemsPerSection))
    }
}

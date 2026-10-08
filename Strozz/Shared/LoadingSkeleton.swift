import SwiftUI

/// Reuse the real card layout without fetching artwork or exposing fake content.
enum LoadingSkeleton {
  static let channels: [FollowedChannel] = (0..<8).map { index in
    FollowedChannel(id: "loading-\(index)", login: "loading-\(index)",
      displayName: "Channel name", title: "A live stream title",
      gameName: "Category name", viewerCount: 1000,
      thumbnailURL: nil, profileImageURL: nil, isLive: true)
  }

  static let categories: [TwitchCategory] = (0..<12).map { index in
    TwitchCategory(id: "loading-\(index)", name: "Category name", boxArtURL: nil, viewerCount: 1000)
  }
}

struct LoadingSkeletonStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .redacted(reason: .placeholder)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

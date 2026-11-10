import Foundation

/// Shared decoding for public YouTube metadata.
enum YouTubeConfig {
  /// A single reused decoder for public snapshot responses. Mirrors
  /// `TwitchAPIClient.sharedDecoder`: the YouTube services check the HTTP status
  /// themselves and then decode the body, so they can reuse one decoder instead
  /// of allocating a fresh `JSONDecoder()` per response. Holds only immutable
  /// configuration and is safe to read concurrently while decoding value types.
  nonisolated(unsafe) static let sharedDecoder = JSONDecoder()
}

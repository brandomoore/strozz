import Foundation
import Observation

/// Routes incoming deep links (e.g. from the Top Shelf) into the app's UI.
///
/// `StrozzApp` populates this from `onOpenURL`; `HomeView` observes the pending
/// login and presents the player. Modeled as `@Observable` so SwiftUI can react
/// to changes via `onChange`.
@MainActor
@Observable
final class DeepLinkRouter {
    /// Platform-qualified channel key requested by an incoming deep link.
    var pendingChannelLogin: String?

    /// Handles a deep-link URL. Returns `true` if it was a recognised link.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let login = TopShelf.channelKey(from: url) else { return false }
        pendingChannelLogin = login
        return true
    }
}

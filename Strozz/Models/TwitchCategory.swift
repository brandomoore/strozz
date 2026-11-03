import Foundation

struct TwitchCategory: Identifiable, Hashable {
    let sourceID: String
    let platform: LivePlatform
    var id: String { platform == .twitch ? sourceID : "\(platform.rawValue):\(sourceID)" }
    let name: String
    let boxArtURL: URL?
    let viewerCount: Int?
    let isMature: Bool

    init(
        id: String,
        name: String,
        boxArtURL: URL?,
        viewerCount: Int?,
        isMature: Bool = false,
        platform: LivePlatform = .twitch
    ) {
        self.sourceID = id
        self.platform = platform
        self.name = name
        self.boxArtURL = boxArtURL
        self.viewerCount = viewerCount
        self.isMature = isMature
    }
}

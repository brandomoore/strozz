import SDWebImage
import SDWebImageWebPCoder
import SwiftUI

@main
struct StrozzApp: App {
  @State private var deepLinkRouter = DeepLinkRouter()
  /// App-level composition root. Owns the app-global services once for the whole
  /// app and injects them into the view tree via `.environment(_:)`.
  @State private var environment = AppEnvironment()

  init() {
    PlaybackTelemetrySentry.start()
    SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    ImageCacheConfigurator.configure()
    ChatAppearanceMigration.runIfNeeded()
    ChatSyncDefaultsMigration.runIfNeeded()
  }

  var body: some Scene {
    WindowGroup {
      Group {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["STROZZ_KICK_UI_FIXTURE"] == "1" {
          KickDirectoryView(initialQuery: ProcessInfo.processInfo.environment["STROZZ_KICK_CHANNEL"] ?? "xqc")
        } else if ProcessInfo.processInfo.environment["STROZZ_FOLLOW_FIXTURE"] == "1" {
          ChannelFollowFixture()
        } else if ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_STATUS_FIXTURE"] == "1" {
          MultiviewStatusFixture()
        } else if ProcessInfo.processInfo.environment["STROZZ_MULTIVIEW_SELECTION_FIXTURE"] == "1" {
          MultiviewSelectionFixture()
        } else if ProcessInfo.processInfo.environment["STROZZ_SIGN_IN_FIXTURE"] == "1" {
          TwitchSignInFixture()
        } else if ProcessInfo.processInfo.environment["STROZZ_HOME_ERROR_FIXTURE"] == "1" {
          HomeFollowingErrorFixture()
        } else {
          HomeView(deepLinkRouter: deepLinkRouter)
        }
        #else
        HomeView(deepLinkRouter: deepLinkRouter)
        #endif
      }
        .environment(environment)
        #if DEBUG
        .onAppear { AppEnvironment.playbackTestEnvironment = environment }
        .task { await TwitchCloudProbe.runIfRequested() }
        #endif
        .onChange(of: environment.auth.userID) { _, userID in
          environment.watchRewards.accountChanged(to: userID)
        }
        .onOpenURL { url in
          deepLinkRouter.handle(url)
        }
        .resolveGlassDisabled()
        .installNightShiftOverlay(environment.nightShift)
    }
  }
}

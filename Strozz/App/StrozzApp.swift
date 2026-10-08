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
    SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    ImageCacheConfigurator.configure()
    ChatAppearanceMigration.runIfNeeded()
    ChatSyncDefaultsMigration.runIfNeeded()
  }

  var body: some Scene {
    WindowGroup {
      HomeView(deepLinkRouter: deepLinkRouter)
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

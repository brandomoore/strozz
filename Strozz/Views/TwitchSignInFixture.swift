#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct TwitchSignInFixture: View {
  @State private var fixture = TwitchSignInFixtureModel()
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let settings = ProcessInfo.processInfo.environment
    let theme = AppTheme(rawValue: settings["STROZZ_SIGN_IN_THEME"] ?? "dark") ?? .dark
    SignInView(auth: fixture.auth, isEmbedded: true)
      .environment(\.themePalette, theme.palette(systemColorScheme: scheme))
      .environment(\.glassDisabled, settings["STROZZ_SIGN_IN_OPAQUE"] == "1")
      .preferredColorScheme(theme.preferredColorScheme)
      .onDisappear { fixture.stop() }
  }
}

@MainActor
private final class TwitchSignInFixtureModel {
  let auth: TwitchAuthSession
  private let prefix = "StrozzSignInFixture.\(UUID())"
  private let defaults: UserDefaults

  init() {
    guard let defaults = UserDefaults(suiteName: prefix) else {
      preconditionFailure("Cannot create isolated sign-in fixture preferences")
    }
    self.defaults = defaults
    let network = TwitchSignInFixtureNetwork()
    auth = TwitchAuthSession(userDefaults: defaults, secureService: prefix, saveTopShelf: { _ in },
      loadAuthData: { try await network.load($0) })
  }

  func stop() {
    auth.cancelSignIn()
    defaults.removePersistentDomain(forName: prefix)
  }
}

private actor TwitchSignInFixtureNetwork {
  private var requestedCode = false

  func load(_ request: URLRequest) throws -> (Data, URLResponse) {
    guard let url = request.url else { throw URLError(.badURL) }
    let device = url.path == "/oauth2/device"
    if device, !requestedCode, ProcessInfo.processInfo.environment["STROZZ_SIGN_IN_BLOCKED"] == "1" {
      requestedCode = true
      throw TwitchSyncError.refreshPending
    }
    let body: [String: Any] = device
      ? ["device_code": "synthetic-device", "user_code": "TEST-CODE",
         "verification_uri": "https://www.twitch.tv/activate", "expires_in": 600, "interval": 2]
      : ["error": "authorization_pending", "message": "authorization_pending"]
    guard let response = HTTPURLResponse(url: url, statusCode: device ? 200 : 400,
      httpVersion: nil, headerFields: nil) else { throw URLError(.badServerResponse) }
    return (try JSONSerialization.data(withJSONObject: body), response)
  }
}
#endif

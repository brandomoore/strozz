import SwiftUI
import WebKit
import OSLog

@MainActor
@Observable
final class MobileKickSignIn: NSObject, WKNavigationDelegate, WKUIDelegate {
  var isPresented = false
  private(set) var isPreparing = false
  private(set) var isImporting = false
  private(set) var errorMessage: String?
  @ObservationIgnored private var installedWebView: WKWebView?
  @ObservationIgnored private let websiteDataStore = WKWebsiteDataStore(
    forIdentifier: UUID(uuidString: "494DF59F-C7E7-4732-98E3-8E0C3FB42941")!)
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var loadContinuation: CheckedContinuation<Void, Error>?
  @ObservationIgnored private var loadTimeout: Task<Void, Never>?
  @ObservationIgnored private var preparationTimeoutTask: Task<Void, Never>?
  @ObservationIgnored private var importTask: Task<Void, Never>?
  @ObservationIgnored private var cookieObserver: CookieObserver?
  @ObservationIgnored private weak var store: KickFollowingStore?
  @ObservationIgnored private var pendingNavigation: WKNavigation?
  @ObservationIgnored private var websitePrepared = false
  private let preparationTimeout: Duration
  private var loadID = UUID()
  private var lastAttemptAt: Date?
  private var generation = UUID()
  private static let ownerKey = "kickWebsite.owner.v1"
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "kick-sign-in")

  init(defaults: UserDefaults = .standard, preparationTimeout: Duration = .seconds(25)) {
    self.defaults = defaults
    self.preparationTimeout = preparationTimeout
    super.init()
  }

  var webView: WKWebView {
    if let installedWebView { return installedWebView }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = websiteDataStore
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    let observer = CookieObserver(owner: self)
    cookieObserver = observer
    configuration.websiteDataStore.httpCookieStore.add(observer)
    installedWebView = webView
    return webView
  }

  func connect(using store: KickFollowingStore) {
    Self.logger.info("Kick sign-in requested")
    cancel()
    self.store = store
    errorMessage = nil
    lastAttemptAt = nil
    isPresented = true
    isPreparing = true
    websitePrepared = false
    let request = generation
    importTask = Task {
      defer {
        if generation == request {
          isPreparing = false
          preparationTimeoutTask?.cancel()
          preparationTimeoutTask = nil
        }
      }
      await store.synchronize()
      guard generation == request, !Task.isCancelled else { return }
      Self.logger.info("Kick sign-in account check finished")
      if store.cloudOwner == nil || defaults.string(forKey: Self.ownerKey) != store.cloudOwner {
        await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        guard generation == request, !Task.isCancelled else { return }
      }
      if let owner = store.cloudOwner { defaults.set(owner, forKey: Self.ownerKey) }
      else { defaults.removeObject(forKey: Self.ownerKey) }
      websitePrepared = true
      Self.logger.info("Kick sign-in website loading")
      webView.load(URLRequest(url: URL(string: "https://kick.com/login")!))
    }
    preparationTimeoutTask = Task { [weak self, timeout = preparationTimeout] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard let self, generation == request, isPreparing else { return }
      cancel()
      let error = URLError(.timedOut)
      errorMessage = String(localized: "Couldn't prepare Kick sign-in. Please try again.")
      store.report(error)
    }
  }

  func cancel() {
    generation = UUID()
    importTask?.cancel()
    importTask = nil
    preparationTimeoutTask?.cancel()
    preparationTimeoutTask = nil
    isImporting = false
    isPreparing = false
    installedWebView?.stopLoading()
    finishLoad(.failure(CancellationError()))
    unload()
  }

  func dismiss() {
    Self.logger.info("Kick sign-in dismissed")
    isPresented = false
    cancel()
  }

  func reloadWebsite() {
    guard let store, isPresented, !isPreparing, !isImporting else { return }
    guard websitePrepared else { connect(using: store); return }
    errorMessage = nil
    lastAttemptAt = nil
    Self.logger.info("Kick sign-in website reloading")
    webView.load(URLRequest(url: URL(string: "https://kick.com/login")!))
  }

  func importNow() {
    guard !isImporting, !isPreparing else { return }
    importTask = Task { await importFollows(interactive: true) }
  }

  func refreshIfNeeded(using store: KickFollowingStore, force: Bool = false) async {
    guard store.isImporter, !isPresented, !isImporting,
      force || Date().timeIntervalSince(max(lastAttemptAt ?? .distantPast,
        store.document?.importedAt ?? .distantPast)) >= 300 else { return }
    self.store = store
    guard defaults.string(forKey: Self.ownerKey) == store.cloudOwner else {
      errorMessage = KickFollowingError.signInRequired.localizedDescription
      return
    }
    await importFollows(interactive: false)
  }

  func clearWebsiteSession() async {
    isPresented = false
    cancel()
    store = nil
    websitePrepared = false
    lastAttemptAt = nil
    errorMessage = nil
    defaults.removeObject(forKey: Self.ownerKey)
    await websiteDataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
  }

  private func importFollows(interactive: Bool) async {
    guard let store, !isImporting else { return }
    let request = generation
    isImporting = true
    lastAttemptAt = Date()
    errorMessage = nil
    defer {
      if generation == request {
        isImporting = false
        if !isPresented { unload() }
      }
    }
    do {
      if !interactive {
        // A same-origin text document avoids running Kick's home-page players
        // and recommendation UI just to refresh an account's follow roster.
        try await loadImportPage()
      }
      let imported = try await KickFollowImport.read { [self] path in try await get(path) }
      guard generation == request, !Task.isCancelled else { throw CancellationError() }
      try await store.publish(imported, interactive: interactive)
      guard generation == request else { return }
      if let owner = store.cloudOwner { defaults.set(owner, forKey: Self.ownerKey) }
      if interactive { isPresented = false }
    } catch {
      guard generation == request, !(error is CancellationError) else { return }
      errorMessage = Self.message(for: error)
      store.report(error)
    }
  }

  private func loadImportPage() async throws {
    try Task.checkCancellation()
    let request = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        finishLoad(.failure(CancellationError()))
        loadID = request
        loadContinuation = continuation
        pendingNavigation = webView.load(URLRequest(url: URL(string: "https://kick.com/robots.txt")!))
        loadTimeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(25)) } catch { return }
          guard self?.loadID == request else { return }
          self?.webView.stopLoading()
          self?.finishLoad(.failure(URLError(.timedOut)))
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.loadID == request else { return }
        self?.webView.stopLoading()
        self?.finishLoad(.failure(CancellationError()))
      }
    }
  }

  private func get(_ path: String) async throws -> Data {
    guard webView.url?.scheme == "https", webView.url?.host == "kick.com",
      path == "/api/v1/user" || path.range(
        of: #"^/api/v2/channels/followed\?cursor=[0-9]+$"#, options: .regularExpression) != nil
    else { throw KickFollowingError.signInRequired }
    // The website session never leaves this WebKit profile. Only public account
    // identity and followed-channel metadata are returned to native code.
    let result = try await webView.callAsyncJavaScript("""
      if (location.origin !== "https://kick.com") throw new Error("Wrong origin");
      const headers = { Accept: "application/json" };
      const entry = document.cookie.split(";").map(s => s.trim())
        .find(s => s.startsWith("session_token="));
      if (entry) headers.Authorization = "Bearer " + decodeURIComponent(entry.slice(14));
      const response = await fetch(path, {
        method: "GET", credentials: "include", cache: "no-store",
        headers, redirect: "error", signal: AbortSignal.timeout(15000)
      });
      if (!response.ok) return JSON.stringify({ status: response.status });
      const body = await response.json();
      const value = path === "/api/v1/user"
        ? { id: body.id, username: body.username }
        : { channels: Array.isArray(body.channels) ? body.channels.map(row => ({
            channel_slug: row.channel_slug, user_username: row.user_username,
            profile_picture: row.profile_picture, is_live: row.is_live,
            session_title: row.session_title, category_name: row.category_name,
            viewer_count: row.viewer_count
          })) : null, nextCursor: body.nextCursor };
      return JSON.stringify({ status: response.status, value });
      """, arguments: ["path": path], in: nil, contentWorld: .defaultClient)
    try Task.checkCancellation()
    guard let text = result as? String, text.utf8.count <= 4_000_000,
      let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let status = object["status"] as? Int else { throw KickFollowingError.invalidResponse }
    if status == 401 { throw KickFollowingError.signInRequired }
    if status == 403 { throw KickFollowingError.restricted }
    guard status == 200 else { throw KickPlaybackService.Failure.http(status) }
    guard let value = object["value"] as? [String: Any] else { throw KickFollowingError.invalidResponse }
    return try JSONSerialization.data(withJSONObject: value)
  }

  fileprivate func cookiesChanged() {
    guard isPresented, !isPreparing, !isImporting,
      Date().timeIntervalSince(lastAttemptAt ?? .distantPast) >= 10 else { return }
    let request = generation
    importTask?.cancel()
    importTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let self, generation == request, isPresented, !isImporting else { return }
      let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
      guard generation == request, cookies.contains(where: {
        $0.name == "session_token" && ["kick.com", ".kick.com"].contains($0.domain)
      }), webView.url?.host == "kick.com" else { return }
      await importFollows(interactive: true)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if pendingNavigation === navigation { finishLoad(.success(())) }
    cookiesChanged()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if pendingNavigation === navigation { finishLoad(.failure(error)) }
    navigationFailed(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    if pendingNavigation === navigation { finishLoad(.failure(error)) }
    navigationFailed(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finishLoad(.failure(URLError(.networkConnectionLost)))
    navigationFailed(URLError(.networkConnectionLost))
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
    let url = navigationAction.request.url
    return url?.scheme == "https" || url?.absoluteString == "about:blank" ? .allow : .cancel
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" {
      webView.load(navigationAction.request)
    }
    return nil
  }

  private func navigationFailed(_ error: Error) {
    if (error as NSError).code != NSURLErrorCancelled { errorMessage = Self.message(for: error) }
  }

  static func message(for error: Error) -> String {
    if let error = error as? URLError {
      switch error.code {
      case .notConnectedToInternet:
        return String(localized: "You're offline. Connect to the internet, then reload Kick sign-in.")
      case .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
        return String(localized: "Couldn't load Kick. Check your connection and try again.")
      case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
           .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
        return String(localized: "A secure connection to Kick couldn't be established. Try again later.")
      default: break
      }
    }
    if (error as NSError).domain == WKError.errorDomain {
      return String(localized: "Kick's page couldn't be read. Reload sign-in and try again.")
    }
    return error.localizedDescription
  }

  private func finishLoad(_ result: Result<Void, Error>) {
    loadTimeout?.cancel()
    loadTimeout = nil
    pendingNavigation = nil
    loadID = UUID()
    let continuation = loadContinuation
    loadContinuation = nil
    continuation?.resume(with: result)
  }

  private func unload() {
    installedWebView?.stopLoading()
    installedWebView?.loadHTMLString("", baseURL: nil)
  }

  private final class CookieObserver: NSObject, WKHTTPCookieStoreObserver {
    weak var owner: MobileKickSignIn?
    init(owner: MobileKickSignIn) { self.owner = owner }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { owner?.cookiesChanged() }
  }
}

struct MobileKickSignInSheet: View {
  let signIn: MobileKickSignIn

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        KickWebsiteView(webView: signIn.webView)
        VStack(alignment: .leading, spacing: 8) {
          if signIn.isPreparing { ProgressView("Preparing sign-in") }
          if signIn.isImporting { ProgressView("Importing your follows") }
          if let error = signIn.errorMessage {
            Text(error).font(.callout).foregroundStyle(.secondary)
            Button("Reload Kick sign-in") { signIn.reloadWebsite() }
              .disabled(signIn.isPreparing || signIn.isImporting)
              .accessibilityIdentifier("kick-reload-sign-in")
          }
          Text("Sign in on Kick. Strozz shares your followed channels through iCloud, not your password or website session.")
            .font(.footnote).foregroundStyle(.secondary)
          Button("I'm signed in — import follows") { signIn.importNow() }
            .disabled(signIn.isPreparing || signIn.isImporting)
            .accessibilityIdentifier("kick-import-follows")
        }
        .padding()
      }
      .navigationTitle("Connect Kick")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { signIn.dismiss() } } }
    }
    .interactiveDismissDisabled(signIn.isImporting)
    .onDisappear { if !signIn.isPresented { signIn.cancel() } }
  }
}

private struct KickWebsiteView: UIViewRepresentable {
  let webView: WKWebView
  func makeUIView(context: Context) -> WKWebView { webView }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
}

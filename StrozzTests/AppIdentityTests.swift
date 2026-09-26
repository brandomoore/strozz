import XCTest
import SwiftUI
@testable import Strozz

@MainActor
final class AppIdentityTests: XCTestCase {
  func testRenamedAppKeepsItsShippingIdentity() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.thatcube.Twozz")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Strozz")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Strozz")
    XCTAssertEqual(TopShelf.appGroupID, "group.com.thatcube.Twozz")
  }

  func testNewLinksUseStrozzAndLegacyLinksStillOpen() throws {
    XCTAssertEqual(TopShelf.channelDeepLink(login: "burn").absoluteString, "strozz://channel/burn")
    for scheme in ["strozz", "twozz", "twizz", "STROZZ", "TWOZZ"] {
      let url = try XCTUnwrap(URL(string: "\(scheme)://channel/burn"))
      XCTAssertEqual(TopShelf.channelLogin(from: url), "burn")
    }
    XCTAssertNil(TopShelf.channelLogin(from: try XCTUnwrap(URL(string: "https://channel/burn"))))
    XCTAssertNil(TopShelf.channelLogin(from: try XCTUnwrap(URL(string: "strozz://settings/burn"))))
  }

  func testSystemRegistersCurrentAndLegacyLinkSchemes() throws {
    let types = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
    let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    XCTAssertTrue(Set(["strozz", "twozz", "twizz"]).isSubset(of: Set(schemes)))
  }

  func testRenamedLogoAndAboutPanelRenderAcrossThemes() async throws {
    XCTAssertNotNil(UIImage(named: "StrozzPixelLogo"))
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.keyWindow
    defer { previousKeyWindow?.makeKey() }
    for theme in AppTheme.allCases {
      for opaque in [false, true] {
        let palette = theme.palette(systemColorScheme: .dark)
        let host = UIHostingController(rootView:
          SettingsAboutSection()
            .frame(width: 1400)
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, palette.chromeColorScheme)
            .environment(\.glassDisabled, opaque)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.playerBackdrop)
            .ignoresSafeArea())
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
          window.isHidden = true
          window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
          host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Strozz-About-\(theme.rawValue)-opaque-\(opaque)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
  }
}

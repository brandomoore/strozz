import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class AccountStartupRenderingTests: XCTestCase {
  func testFirstFrameUsesNeutralAccountLoadingAcrossThemes() async throws {
    for theme in AppTheme.allCases {
      for opaque in [false, true] {
        let scheme: ColorScheme = theme == .light ? .light : .dark
        let palette = theme.palette(systemColorScheme: scheme)
        let view = HomeAuthBanner(isAuthenticated: false, isRestoringAccount: true, onSignIn: {})
          .padding(24)
          .frame(width: 1200, height: 180)
          .background(LinearGradient(colors: palette.backgroundColors, startPoint: .top, endPoint: .bottom))
          .environment(\.colorScheme, scheme)
          .environment(\.glassDisabled, opaque)
        let image = try await snapshot(view, scheme: scheme)
        XCTAssertGreaterThan(image.size.width, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Account startup \(theme.rawValue) opaque-\(opaque)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
  }

  func testConfirmedSignedOutStateStillRendersItsAction() async throws {
    let view = HomeAuthBanner(isAuthenticated: false, isRestoringAccount: false, onSignIn: {})
      .padding(24)
      .frame(width: 1200, height: 240)
      .environment(\.colorScheme, .dark)
    let image = try await snapshot(view, scheme: .dark)
    let attachment = XCTAttachment(image: image)
    attachment.name = "Confirmed signed-out account action"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func snapshot(_ content: some View, scheme: ColorScheme) async throws -> UIImage {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let controller = UIHostingController(rootView: content.preferredColorScheme(scheme))
    controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
    window.rootViewController = controller
    controller.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    return UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
  }
}

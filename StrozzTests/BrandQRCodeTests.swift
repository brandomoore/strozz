import CoreImage
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class BrandQRCodeTests: XCTestCase {
  func testRewardsCodeScansInEveryThemeAndTransparencySetting() throws {
    let payload = "https://www.twitch.tv/activate?device-code=TESTCODE"
    let detector = try XCTUnwrap(CIDetector(
      ofType: CIDetectorTypeQRCode,
      context: CIContext(options: [.useSoftwareRenderer: true]),
      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    for theme in AppTheme.allCases {
      for systemScheme in [ColorScheme.dark, .light] {
        let palette = theme.palette(systemColorScheme: systemScheme)
        for glassDisabled in [false, true] {
          let appearance = "\(theme.rawValue)-\(systemScheme)-opaque-\(glassDisabled)"
          let renderer = ImageRenderer(content:
            BrandQRCodeView(
              payload: payload, logoName: "twitch-logo",
              moduleColor: palette.liftPrimaryText,
              backgroundColor: palette.liftSurface, size: 330)
              .environment(\.themePalette, palette)
              .environment(\.colorScheme, theme.preferredColorScheme ?? systemScheme)
              .environment(\.glassDisabled, glassDisabled))
          renderer.scale = 2
          let image = try XCTUnwrap(renderer.uiImage, appearance)
          let attachment = XCTAttachment(image: image)
          attachment.name = appearance
          attachment.lifetime = .keepAlways
          add(attachment)

          let features = detector.features(in: try XCTUnwrap(CIImage(image: image)))
          let decoded = features.compactMap {
            ($0 as? CIQRCodeFeature)?.messageString
          }
          XCTAssertEqual(decoded, [payload], appearance)
        }
      }
    }
  }

  func testRewardsCodeHasOpaqueBackgroundAndHighContrast() {
    for theme in AppTheme.allCases {
      for scheme in [ColorScheme.dark, .light] {
        let palette = theme.palette(systemColorScheme: scheme)
        let background = components(palette.liftSurface)
        let foreground = components(palette.liftPrimaryText)
        XCTAssertEqual(background.alpha, 1)
        let ink = zip(foreground.rgb, background.rgb).map {
          $0 * foreground.alpha + $1 * (1 - foreground.alpha)
        }
        let paper = luminance(background.rgb)
        let modules = luminance(ink)
        let contrast = (max(paper, modules) + 0.05) / (min(paper, modules) + 0.05)
        XCTAssertGreaterThanOrEqual(contrast, 15, theme.rawValue)
      }
    }
  }

  private func components(_ color: Color) -> (rgb: [Double], alpha: Double) {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    XCTAssertTrue(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    return ([Double(red), Double(green), Double(blue)], Double(alpha))
  }

  private func luminance(_ components: [Double]) -> Double {
    let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
  }
}

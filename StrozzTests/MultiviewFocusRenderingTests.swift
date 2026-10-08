import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class MultiviewFocusRenderingTests: XCTestCase {
  func testFocusedPaneLeavesUnderlyingPictureUntintedAcrossThemes() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }

    for theme in AppTheme.allCases {
      for opaque in [false, true] {
        let scheme: ColorScheme = theme == .light ? .light : .dark
        let focus = FocusObservation()
        let host = UIHostingController(rootView: FocusFixture(focus: focus)
          .environment(\.themePalette, theme.palette(systemColorScheme: scheme))
          .environment(\.glassDisabled, opaque)
          .preferredColorScheme(scheme))
        window.rootViewController = host
        host.view.layoutIfNeeded()
        for _ in 0..<30 {
          if focus.isFocused { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(focus.isFocused, "The native pane Button must actually hold focus")
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
          host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Focused pane \(theme.rawValue) opaque-\(opaque)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let cgImage = try XCTUnwrap(image.cgImage)
        for (offset, expected) in [
          (CGSize(width: -150, height: -90), [255, 0, 0]),
          (CGSize(width: 150, height: -90), [0, 255, 0]),
          (CGSize(width: -150, height: 90), [0, 0, 255]),
          (CGSize(width: 150, height: 90), [0, 0, 0]),
        ] {
          let rect = CGRect(
            x: (host.view.bounds.midX + offset.width) * image.scale,
            y: (host.view.bounds.midY + offset.height) * image.scale,
            width: 1, height: 1)
          let pixel = try XCTUnwrap(cgImage.cropping(to: rect))
          var rgba = [UInt8](repeating: 0, count: 4)
          let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
          context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
          for channel in 0..<3 {
            XCTAssertEqual(Int(rgba[channel]), expected[channel], accuracy: 3,
              "Focused overlay must not tint the picture: \(theme.rawValue), opaque=\(opaque), \(offset)")
          }
        }
      }
    }
  }
}

@MainActor
private final class FocusObservation {
  var isFocused = false
}

private struct FocusFixture: View {
  let focus: FocusObservation
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Color(red: 1, green: 0, blue: 0)
        Color(red: 0, green: 1, blue: 0)
      }
      HStack(spacing: 0) {
        Color(red: 0, green: 0, blue: 1)
        Color(red: 0, green: 0, blue: 0)
      }
    }
    .frame(width: 600, height: 360)
    .overlay {
      MultiviewPaneButton {}
        .focused($isFocused)
        .contextMenu { Button("Watch Stream") {} }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { isFocused = true }
    .onChange(of: isFocused) { _, value in focus.isFocused = value }
  }
}

import SwiftUI
import XCTest

@testable import StrozzMobile

@MainActor
final class MobileLoadingPresentationTests: XCTestCase {
  func testVideoOverlayGlyphsAreWhiteWithoutIndividualBackplates() throws {
    for theme in AppTheme.allCases {
      let image = try render(
        Icon(glyph: .x, size: 22).frame(width: 44, height: 44)
          .modifier(MobileControlSurface(isVideoOverlay: true))
          .background(Color.black)
          .environment(\.themePalette, theme.palette(systemColorScheme: .light)))
      XCTAssertLessThan(try luminance(image, x: 4, y: 22), 0.002, "No button backplate in \(theme)")
      XCTAssertGreaterThan(try luminance(image, x: 22, y: 22), 0.8, "White glyph in \(theme)")
    }
    let directorySurface = try render(
      Icon(glyph: .x, size: 22).frame(width: 44, height: 44)
        .modifier(MobileControlSurface())
        .background(Color.black)
        .environment(\.themePalette, .light))
    XCTAssertGreaterThan(try luminance(directorySurface, x: 4, y: 22), 0.7,
                         "Directory badges must retain their theme-aware surfaces")
  }

  func testVideoScrimIsUniformWithGentleEdgeContrast() throws {
    for theme in AppTheme.allCases {
      for reduceTransparency in [false, true] {
        for size in [CGSize(width: 390, height: 220), .init(width: 844, height: 390),
                     .init(width: 820, height: 500), .init(width: 820, height: 1180),
                     .init(width: 160, height: 90), .init(width: 240, height: 135),
                     .init(width: 320, height: 180)] {
          let mini = size.width <= 320
          let image = try render(
            MobilePlayerControlScrim(hasBottomControls: !mini,
                                     reduceTransparency: reduceTransparency)
              .frame(width: size.width, height: size.height)
              .background(Color.white)
              .environment(\.themePalette, theme.palette(systemColorScheme: .light)))
          var iconCenters = [CGPoint(x: mini ? 28 : 32, y: mini ? 28 : 32),
                             CGPoint(x: size.width - (mini ? 28 : 32), y: mini ? 28 : 32)]
          if !mini {
            iconCenters += [.init(x: size.width / 2, y: size.height / 2),
                            .init(x: size.width - 32, y: size.height - 32)]
            let liveLabel = try luminance(image, x: 40, y: Int(size.height) - 60)
            XCTAssertGreaterThanOrEqual(1.05 / (liveLabel + 0.05), 4.5, "Live text contrast over white")
          }
          for point in iconCenters {
            let background = try luminance(image, x: Int(point.x), y: Int(point.y))
            XCTAssertGreaterThanOrEqual(1.05 / (background + 0.05), 3,
                                       "Icon contrast: \(theme), \(size), reduced transparency \(reduceTransparency)")
          }
          var rowLuminances: [Double] = []
          for row in 0...10 {
            let y = (image.height - 1) * row / 10
            let middle = try luminance(image, x: image.width / 2, y: y)
            for column in 0...4 {
              // Allow one 8-bit shade of gradient dithering, not visible patches.
              XCTAssertEqual(try luminance(image, x: (image.width - 1) * column / 4, y: y),
                             middle, accuracy: 0.004, "No spotlight or horizontal brightness patches")
            }
            if let previous = rowLuminances.last {
              XCTAssertLessThan(abs(middle - previous), 0.025, "The vertical fade must remain gradual")
            }
            rowLuminances.append(middle)
          }
          let darkest = try XCTUnwrap(rowLuminances.min())
          let lightest = try XCTUnwrap(rowLuminances.max())
          XCTAssertLessThan(lightest - darkest, 0.10, "Only gentle edge darkening across the full picture")
          XCTAssertGreaterThan(darkest, reduceTransparency ? 0.025 : 0.10,
                               "The scrim must not obscure the video with an opaque fill")
        }
      }
    }
  }

  func testMiniPlayerRendersAcrossThemes() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let channel = FollowedChannel(
      id: "fixture", login: "fixture", displayName: "Live channel", title: "Fixture stream",
      gameName: "", viewerCount: 1200, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    for theme in AppTheme.allCases {
      let model = MobilePlaybackModel(muted: true)
      defer { model.stop() }
      model.displayReady(true, for: model.player)
      let content = MobileVideoView(
        model: model, channel: channel, hideChat: .constant(false), isFullscreen: false,
        isMinimized: true, videoController: MobileVideoController(), onCollapse: {},
        onClose: {}, onExpand: {}, onCollapseDragChanged: { _ in }, onCollapseDragEnded: { _ in },
        onFullscreen: {}, onScene: { _ in }, onLayout: { _ in })
        .frame(width: 240, height: 135)
        .environment(\.themePalette, theme.palette(systemColorScheme: .light))
        .preferredColorScheme(theme.preferredColorScheme)
      let host = UIHostingController(rootView: content)
      window.rootViewController = host
      await layout(host)
      capture(host, name: "mini-\(theme.rawValue)")
    }
  }

  func testLoadingReadyAndErrorRenderAcrossThemes() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let channel = FollowedChannel(
      id: "fixture", login: "fixture", displayName: "Live channel",
      title: "Fixture stream", gameName: "", viewerCount: 1200,
      thumbnailURL: nil, profileImageURL: nil, isLive: true)
    for theme in AppTheme.allCases {
      let model = MobilePlaybackModel(muted: true)
      defer { model.stop() }
      let palette = theme.palette(systemColorScheme: .light)
      let content = MobileVideoView(
        model: model, channel: channel, hideChat: .constant(false),
        isFullscreen: false, isMinimized: false, videoController: MobileVideoController(), onCollapse: {},
        onClose: {}, onExpand: {}, onCollapseDragChanged: { _ in }, onCollapseDragEnded: { _ in },
        onFullscreen: {}, onScene: { _ in }, onLayout: { _ in }
      )
      .frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 500 : 220)
      .environment(\.themePalette, palette)
      .preferredColorScheme(theme.preferredColorScheme)
      let host = UIHostingController(rootView: content)
      window.rootViewController = host
      await layout(host)
      XCTAssertEqual(model.presentationState, .loading)
      capture(host, name: "loading-\(theme.rawValue)")

      model.displayReady(true, for: model.player)
      await layout(host)
      XCTAssertEqual(model.presentationState, .ready)
      capture(host, name: "ready-\(theme.rawValue)")

      model.displayReady(false, for: model.player)
      await layout(host)
      XCTAssertEqual(model.presentationState, .loading)

      model.activateAudioSession = { throw NSError(domain: "AudioFixture", code: 1) }
      model.start(channel: "fixture")
      await layout(host)
      XCTAssertEqual(model.presentationState, .unavailable)
      capture(host, name: "error-\(theme.rawValue)")
    }
  }

  private func layout(_ host: UIViewController) async {
    host.view.layoutIfNeeded()
    try? await Task.sleep(for: .milliseconds(200))
    host.view.layoutIfNeeded()
  }

  private func render(_ content: some View) throws -> CGImage {
    let renderer = ImageRenderer(content: content)
    renderer.scale = 1
    return try XCTUnwrap(renderer.cgImage)
  }

  private func luminance(_ image: CGImage, x: Int, y: Int) throws -> Double {
    let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    var rgba = [UInt8](repeating: 0, count: 4)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(
        data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    let linear = rgba.prefix(3).map { channel -> Double in
      let value = Double(channel) / 255
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
  }

  private func capture(_ host: UIViewController, name: String) {
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

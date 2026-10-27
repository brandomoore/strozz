import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class MultiviewFocusRenderingTests: XCTestCase {
  func testChromeTimeoutCanBeRestartedAndCancelled() async throws {
    XCTAssertEqual(MultiviewChrome.idleDelay, .seconds(10))
    let started = (0..<3).map { expectation(description: "Timer \($0) started") }
    let finished = (0..<3).map { expectation(description: "Timer \($0) resumed") }
    var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    var count = 0
    let chrome = MultiviewChrome { duration in
      XCTAssertEqual(duration, .seconds(10))
      let index = count
      count += 1
      await withCheckedContinuation { continuation in
        pending[index] = continuation
        started[index].fulfill()
      }
      finished[index].fulfill()
    }
    defer {
      chrome.cancel()
      for continuation in pending.values { continuation.resume() }
    }
    chrome.reveal()
    await fulfillment(of: [started[0]], timeout: 2)
    chrome.reveal()
    await fulfillment(of: [started[1]], timeout: 2)
    try XCTUnwrap(pending.removeValue(forKey: 0)).resume()
    await fulfillment(of: [finished[0]], timeout: 2)
    XCTAssertTrue(chrome.isVisible, "The old timer must not hide a new interaction")
    try XCTUnwrap(pending.removeValue(forKey: 1)).resume()
    await fulfillment(of: [finished[1]], timeout: 2)
    XCTAssertFalse(chrome.isVisible)
    chrome.reveal()
    await fulfillment(of: [started[2]], timeout: 2)
    chrome.cancel()
    try XCTUnwrap(pending.removeValue(forKey: 2)).resume()
    await fulfillment(of: [finished[2]], timeout: 2)
    XCTAssertTrue(chrome.isVisible)
  }

  func testOutlinePixelsStayOutsideVideoAndDisappearWithChrome() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let pane = MultiviewPane(channel: .init(id: "outline", login: "outline", displayName: "Outline",
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true))
    pane.model.isLoading = false
    pane.isAudible = true
    defer { pane.stop() }

    for theme in AppTheme.allCases {
      for opaque in [false, true] {
        for compact in [false, true] {
          let palette = theme.palette(systemColorScheme: theme == .light ? .light : .dark)
          let size = CGSize(width: compact ? 300 : 600, height: compact ? 169 : 360)
          for visible in [true, false] {
            let host = UIHostingController(rootView:
              Color(red: 1, green: 0, blue: 0).frame(width: size.width, height: size.height)
                .overlay {
                  MultiviewPaneTile(pane: pane, isFocused: true, isPrimary: false,
                    showsMetadata: false, showsChrome: visible, style: compact ? .compact : .full,
                    palette: palette, glassDisabled: opaque)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black))
            window.rootViewController = host
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
              host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let center = CGPoint(x: host.view.bounds.midX, y: host.view.bounds.midY)
            for point in [
              CGPoint(x: center.x - size.width / 2 + 1, y: center.y),
              CGPoint(x: center.x - size.width / 2 + 1, y: center.y - size.height / 2 + 1),
            ] {
              XCTAssertEqual(try pixel(image, at: point), [255, 0, 0],
                "The outline cannot cover any video pixels: \(theme), opaque=\(opaque), compact=\(compact)")
            }
            XCTAssertEqual(try pixel(image, at: .init(x: center.x - size.width / 2 - 2, y: center.y)),
              visible ? [255, 255, 255] : [0, 0, 0])
            if !visible {
              XCTAssertEqual(try pixel(image, at: .init(x: center.x + size.width / 2 - 35,
                y: center.y - size.height / 2 + 25)), [255, 0, 0], "The audio badge must also disappear")
            }
          }
        }
      }
    }
  }

  func testFocusOutlineReachesFinalPixelsOnFirstUpdate() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let pane = MultiviewPane(channel: .init(id: "snap", login: "snap", displayName: "Snap",
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true))
    pane.model.isLoading = false
    defer { pane.stop() }

    func tile(focused: Bool, visible: Bool = true, onUpdate: @escaping () -> Void = {}) -> some View {
      Color.red.frame(width: 600, height: 360)
        .overlay {
          MultiviewPaneTile(pane: pane, isFocused: focused, isPrimary: false,
            showsMetadata: focused && visible, showsChrome: visible,
            style: .full, palette: .dark, glassDisabled: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onChange(of: [focused, pane.isAudible, visible], initial: true) { _, _ in onUpdate() }
    }

    let host = UIHostingController(rootView: tile(focused: false))
    window.rootViewController = host
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    for (focused, audible, visible) in [
      (true, true, true), (false, true, true), (false, false, true),
      (true, false, true), (false, false, false), (true, true, true),
    ] {
      let updated = expectation(description: "Focus \(focused), audio \(audible) rendered")
      pane.isAudible = audible
      host.rootView = tile(focused: focused, visible: visible, onUpdate: { updated.fulfill() })
      host.view.setNeedsLayout()
      host.view.layoutIfNeeded()
      await fulfillment(of: [updated], timeout: 2)
      await NextDisplayFrame().wait()
      let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let center = CGPoint(x: host.view.bounds.midX, y: host.view.bounds.midY)
      XCTAssertEqual(try pixel(image, at: .init(x: center.x - 304, y: center.y)),
        focused && visible ? [255, 255, 255] : [0, 0, 0],
        "Outline must reach its final width on update: focus=\(focused), audio=\(audible)")
      let inner = try pixel(image, at: .init(x: center.x - 302, y: center.y))
      if visible && (focused || audible) {
        XCTAssertGreaterThan(inner.min() ?? 0, 80)
      } else {
        XCTAssertEqual(inner, [0, 0, 0], "The previous audio outline must not linger")
      }
    }
  }

  private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
    let cropped = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
      x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1)))
    var rgba = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1,
      bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return rgba.prefix(3).map(Int.init)
  }

  func testOfflineActionsRemainVisibleOnDarkVideoInLightTheme() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    for compact in [false, true] {
      let size = CGSize(width: compact ? 300 : 800, height: compact ? 169 : 450)
      let host = UIHostingController(rootView: OfflineActionsFixture(compact: compact)
        .preferredColorScheme(.light))
      window.rootViewController = host
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(300))
      let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = "Light offline actions compact-\(compact)"
      attachment.lifetime = .keepAlways
      add(attachment)
      let center = CGPoint(x: host.view.bounds.midX, y: host.view.bounds.midY)
      for side in [-1, 1] {
        var visiblePixels = 0
        let start = side < 0 ? center.x - size.width / 2 + 20 : center.x
        let end = side < 0 ? center.x : center.x + size.width / 2 - 20
        for x in stride(from: start, to: end, by: 2) {
          for y in stride(from: center.y + size.height / 2 - 65, to: center.y + size.height / 2 - 25, by: 2) {
            if try pixel(image, at: CGPoint(x: x, y: y)).max() ?? 0 > 80 { visiblePixels += 1 }
          }
        }
        XCTAssertGreaterThan(visiblePixels, 20,
          "Each action must remain visible: compact=\(compact), side=\(side)")
      }
    }
  }

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

@MainActor
private final class NextDisplayFrame: NSObject {
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      CADisplayLink(target: self, selector: #selector(frame(_:)))
        .add(to: .main, forMode: .common)
    }
  }

  @objc private func frame(_ link: CADisplayLink) {
    link.invalidate()
    continuation?.resume()
    continuation = nil
  }
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

private struct OfflineActionsFixture: View {
  let compact: Bool
  @FocusState private var focus: MultiviewFocusTarget?

  var body: some View {
    ZStack {
      Color.black
      MultiviewPaneButton {}
        .padding(.bottom, MultiviewOfflineActions.reservedHeight(for: compact ? .compact : .full))
        .focused($focus, equals: .pane("fixture"))
      MultiviewOfflineActions(style: compact ? .compact : .full,
        onProfile: {}, onRemove: {}, profileFocus: $focus, paneID: "fixture")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(compact ? 8 : 20)
    }
    .frame(width: compact ? 300 : 800, height: compact ? 169 : 450)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { focus = .pane("fixture") }
  }
}

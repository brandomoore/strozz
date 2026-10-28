import AVKit
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

  func testLineupButtonAnimatesGrowingWidthWithoutChangingHeight() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }

    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    let lineup = MultiviewLineup { _ in .live }
    defer { lineup.clear() }
    func add(_ index: Int) {
      lineup.toggle(FollowedChannel(id: "\(index)", login: "grow\(index)", displayName: "Grow \(index)",
        title: "", gameName: "", viewerCount: nil, thumbnailURL: nil,
        profileImageURL: nil, isLive: true))
    }
    add(0)
    let focus = FocusObservation()
    let host = UIHostingController(rootView: LineupButtonRenderingFixture(lineup: lineup, focus: focus))
    window.rootViewController = host
    host.view.layoutIfNeeded()
    for _ in 0..<30 {
      if focus.isFocused { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(focus.isFocused)
    try await Task.sleep(for: .milliseconds(300))

    func snapshot() -> UIImage {
      UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
      }
    }
    func extent(_ image: UIImage) throws -> CGSize {
      let center = CGPoint(x: host.view.bounds.midX, y: host.view.bounds.midY)
      var xs: [CGFloat] = []
      var ys: [CGFloat] = []
      // Native focused glass is gray; a white-only threshold measures the avatar glyphs instead.
      for x in stride(from: CGFloat(0), to: host.view.bounds.width, by: 1) {
        if try pixel(image, at: CGPoint(x: x, y: center.y)).min() ?? 0 > 100 { xs.append(x) }
      }
      for y in stride(from: CGFloat(0), to: host.view.bounds.height, by: 1) {
        if try pixel(image, at: CGPoint(x: center.x, y: y)).min() ?? 0 > 100 { ys.append(y) }
      }
      return CGSize(width: try XCTUnwrap(xs.last) - XCTUnwrap(xs.first) + 1,
        height: try XCTUnwrap(ys.last) - XCTUnwrap(ys.first) + 1)
    }
    let initial = try extent(snapshot())
    var previousSize = initial
    for count in 2...6 {
      add(count - 1)
      await NextDisplayFrame().wait()
      let first = snapshot()
      try await Task.sleep(for: .milliseconds(80))
      let middle = snapshot()
      try await Task.sleep(for: .milliseconds(300))
      let final = snapshot()
      let firstSize = try extent(first)
      let middleSize = try extent(middle)
      let finalSize = try extent(final)
      XCTAssertGreaterThan(finalSize.width, previousSize.width + 20, "Every avatar must grow the native button")
      XCTAssertEqual(finalSize.height, initial.height, accuracy: 2, "Larger avatars must not make a taller button")
      if reduceMotion {
        XCTAssertEqual(middleSize.width, finalSize.width, accuracy: 2)
      } else {
        XCTAssertTrue([firstSize.width, middleSize.width].contains {
          $0 > previousSize.width + 2 && $0 < finalSize.width - 2
        }, "The rendered native button must visibly interpolate its width, not jump or reserve six slots")
      }
      for (phase, image) in [("first", first), ("middle", middle), ("final", final)] {
        let attachment = XCTAttachment(image: image)
        attachment.name = "Lineup \(count) avatars \(phase) reduced-motion-\(reduceMotion)"
        attachment.lifetime = .keepAlways
        self.add(attachment)
      }
      previousSize = finalSize
    }
  }

  func testOutlinePixelsStayOutsideVideoAndDimWithChrome() async throws {
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
            let outline = try pixel(image, at: .init(x: center.x - size.width / 2 - 2, y: center.y))
            for component in outline {
              XCTAssertEqual(component, visible ? 255 : 89, accuracy: 2,
                "The active outline must dim to 35%, never disappear")
            }
            if !visible {
              XCTAssertEqual(try pixel(image, at: .init(x: center.x + size.width / 2 - 35,
                y: center.y - size.height / 2 + 25)), [255, 0, 0], "The audio badge must also disappear")
            }
          }
        }
      }
    }
  }

  func testPackedOutlinesFollowActualAVKitPicturesAcrossLayouts() async throws {
    let videos = [
      try await makePictureVideo(width: 640, height: 360),
      try await makePictureVideo(width: 640, height: 480),
    ]
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let environment = AppEnvironment()

    func videoControllers(_ root: UIViewController) -> [AVPlayerViewController] {
      (root as? AVPlayerViewController).map { [$0] } ?? root.children.flatMap(videoControllers)
    }
    func videoLayers(_ root: CALayer) -> [AVPlayerLayer] {
      (root as? AVPlayerLayer).map { [$0] } ?? (root.sublayers ?? []).flatMap(videoLayers)
    }

    for count in 1...6 {
      let controller = MultiviewController(channels: (0..<count).map {
        FollowedChannel(id: "picture-\($0)", login: "picture\($0)", displayName: "Picture \($0)",
          title: "", gameName: "", viewerCount: nil, thumbnailURL: nil,
          profileImageURL: nil, isLive: true)
      }, muted: true)
      defer { controller.teardown() }
      for (index, pane) in controller.panes.enumerated() {
        pane.model.isLoading = false
        pane.player.replaceCurrentItem(with: AVPlayerItem(url: videos[index % videos.count]))
        pane.player.play()
      }
      let host = UIHostingController(rootView: MultiviewPictureRenderingFixture(controller: controller)
        .environment(environment))
      window.rootViewController = host
      host.view.layoutIfNeeded()
      for _ in 0..<100 {
        let surfaces = videoControllers(host)
        if surfaces.count == count && surfaces.allSatisfy(\.isReadyForDisplay)
          && controller.panes.allSatisfy({ ($0.player.currentItem?.presentationSize.height ?? 0) > 0 }) { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertEqual(videoControllers(host).count, count)
      XCTAssertTrue(videoControllers(host).allSatisfy(\.isReadyForDisplay),
        "Alignment must use actual decoded pictures, not unloaded video containers")
      for (index, pane) in controller.panes.enumerated() {
        PlayerView(channel: pane.channel.login, auth: TwitchAuthSession(), model: pane.model)
          .updateResolvedQuality()
        XCTAssertEqual(pane.presentation.videoAspectRatio, index.isMultiple(of: 2) ? 16 / 9 : 4 / 3,
          accuracy: 0.0001, "The layout must receive the loaded item's presentation aspect ratio")
        pane.player.pause()
      }
      for layout in MultiviewLayout.allCases {
        controller.makePrimary(controller.panes.last!.id)
        controller.setLayout(layout)
        try await Task.sleep(for: .milliseconds(500))
        let expected = MultiviewGeometry.frames(ids: controller.panes.map(\.id),
          size: host.view.bounds.size, layout: layout, primary: controller.primaryPaneID, expanded: nil,
          aspectRatios: Dictionary(uniqueKeysWithValues: controller.panes.map {
            ($0.id, $0.presentation.videoAspectRatio)
          }))
        let surfaces = videoControllers(host)
        for pane in controller.panes {
          let surface = try XCTUnwrap(surfaces.first { $0.player === pane.player })
          let layer = try XCTUnwrap(videoLayers(surface.view.layer).first { $0.player === pane.player })
          let picture = layer.convert(layer.videoRect, to: host.view.layer)
          let frame = try XCTUnwrap(expected[pane.id])
          let description = "\(count) \(layout) \(pane.id)"
          XCTAssertEqual(picture.minX, frame.minX, accuracy: 1, description)
          XCTAssertEqual(picture.maxX, frame.maxX, accuracy: 1, description)
          XCTAssertEqual(picture.minY, frame.minY, accuracy: 1, description)
          XCTAssertEqual(picture.maxY, frame.maxY, accuracy: 1, description)
        }
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
          host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let active = try XCTUnwrap(expected[controller.panes[0].id])
        for point in [
          CGPoint(x: active.minX - 2, y: active.midY),
          CGPoint(x: active.maxX + 2, y: active.midY),
          CGPoint(x: active.midX, y: active.minY - 2),
          CGPoint(x: active.midX, y: active.maxY + 2),
        ] {
          XCTAssertGreaterThan(try pixel(image, at: point).min() ?? 0, 230,
            "The outside outline must track all four native picture edges")
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Packed AVKit pictures \(count) \(layout)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
  }

  private func makePictureVideo(width: Int, height: Int) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    addTeardownBlock {
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
      [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        as CFDictionary, &buffer), kCVReturnSuccess)
    let pixels = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels),
      width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
    context.setFillColor(UIColor.red.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    CVPixelBufferUnlockBaseAddress(pixels, [])
    for frame in 0..<30 {
      for _ in 0..<200 {
        if input.isReadyForMoreMediaData { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertTrue(input.isReadyForMoreMediaData)
      XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    return url
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
      (true, false, true), (true, true, false), (false, true, false),
      (false, false, false), (true, true, true),
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
      let outer = try pixel(image, at: .init(x: center.x - 304, y: center.y))
      for component in outer {
        XCTAssertEqual(component, focused ? (visible ? 255 : 89) : 0, accuracy: 2,
          "Outline must reach its final width on update: focus=\(focused), audio=\(audible)")
      }
      let inner = try pixel(image, at: .init(x: center.x - 302, y: center.y))
      if visible && (focused || audible) {
        XCTAssertGreaterThan(inner.min() ?? 0, 80)
      } else if focused || audible {
        XCTAssertGreaterThan(inner.min() ?? 0, 20, "Idle active outlines must remain visible")
        XCTAssertLessThan(inner.max() ?? 255, 120, "Idle active outlines must be dim")
      } else {
        XCTAssertEqual(inner, [0, 0, 0], "The previous audio outline must not linger")
      }
    }
  }

  func testGlassOverlaysRemainReadableAcrossThemesAndTileSizes() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let pane = MultiviewPane(channel: .init(id: "glass", login: "glass", displayName: "Channel",
      title: "Live stream title", gameName: "Category", viewerCount: 1234,
      thumbnailURL: nil, profileImageURL: nil, isLive: true))
    pane.model.isLoading = false
    pane.isAudible = true
    defer { pane.stop() }

    for theme in AppTheme.allCases {
      for opaque in [false, true] {
        for compact in [false, true] {
          let palette = theme.palette(systemColorScheme: theme == .light ? .light : .dark)
          let size = CGSize(width: compact ? 300 : 800, height: compact ? 169 : 450)
          let host = UIHostingController(rootView:
            LinearGradient(colors: [.red, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
              .frame(width: size.width, height: size.height)
              .overlay {
                MultiviewPaneTile(pane: pane, isFocused: true, isPrimary: false,
                  showsMetadata: true, style: compact ? .compact : .full,
                  palette: palette, glassDisabled: opaque)
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(palette.backgroundColors.last ?? palette.cardOpaqueSurface)
              .preferredColorScheme(theme.preferredColorScheme))
          window.rootViewController = host
          host.view.layoutIfNeeded()
          try await Task.sleep(for: .milliseconds(300))
          let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
          }
          let attachment = XCTAttachment(image: image)
          attachment.name = "Multiview glass \(theme.rawValue) opaque-\(opaque) compact-\(compact)"
          attachment.lifetime = .keepAlways
          add(attachment)
          if opaque {
            let x = host.view.bounds.midX + size.width / 2 - (compact ? 8 : 12) - (compact ? 18 : 22)
            let y = host.view.bounds.midY - size.height / 2 + (compact ? 8 : 12) + 7
            let background = try pixel(image, at: CGPoint(x: x, y: y))
            if theme == .light {
              XCTAssertGreaterThan(background.min() ?? 0, 230, "Light opaque audio surface must stay light")
              let left = host.view.bounds.midX - size.width / 2
              let bottom = host.view.bounds.midY + size.height / 2
              var badgeTextPixels = 0
              for x in stride(from: left + (compact ? 65 : 100),
                to: left + (compact ? 240 : 350), by: 2) {
                for y in stride(from: bottom - (compact ? 38 : 50),
                  to: bottom - (compact ? 15 : 22), by: 2) {
                  if try pixel(image, at: CGPoint(x: x, y: y)).max() ?? 255 < 120 {
                    badgeTextPixels += 1
                  }
                }
              }
              XCTAssertGreaterThan(badgeTextPixels, 20, "LIVE/viewer text must be dark on Light opaque metadata")
            } else {
              XCTAssertLessThan(background.max() ?? 255, 50, "Dark opaque audio surface must stay dark")
            }
          }
        }
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

private struct LineupButtonRenderingFixture: View {
  let lineup: MultiviewLineup
  let focus: FocusObservation
  @FocusState private var isFocused: Bool

  var body: some View {
    MultiviewLineupButton()
      .focused($isFocused)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
      .environment(\.multiviewLineup, lineup)
      .environment(\.themePalette, ThemePalette.dark)
      .preferredColorScheme(.dark)
      .onAppear { isFocused = true }
      .onChange(of: isFocused) { _, value in focus.isFocused = value }
  }
}

private struct MultiviewPictureRenderingFixture: View {
  let controller: MultiviewController

  var body: some View {
    MultiviewVideoStage(controller: controller) { pane in
      MultiviewPicturePaneFixture(pane: pane, isFocused: pane.id == controller.panes.first?.id)
    }
    .background(Color.black)
    .ignoresSafeArea()
  }
}

private struct MultiviewPicturePaneFixture: View {
  let pane: MultiviewPane
  let isFocused: Bool

  var body: some View {
    var player = PlayerView(channel: pane.channel.login, auth: TwitchAuthSession(), model: pane.model)
    player.inputTestContent = { AnyView($0.playerStack) }
    return player.overlay {
      MultiviewPaneTile(pane: pane, isFocused: isFocused, isPrimary: false,
        showsMetadata: false, showsChrome: true, style: .full, palette: .dark, glassDisabled: true)
    }
  }
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

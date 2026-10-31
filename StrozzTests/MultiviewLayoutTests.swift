import AVFoundation
import XCTest
@testable import Strozz

@MainActor
final class MultiviewLayoutTests: XCTestCase {
  func testSmallPanesUseCompactChromeRegardlessOfQualityTier() {
    for size in [CGSize(width: 124, height: 93), .init(width: 294, height: 221),
      .init(width: 600, height: 200), .init(width: 400, height: 300)] {
      XCTAssertEqual(MultiviewPaneTile.Style.fitting(size, preferred: .full), .compact)
    }
    XCTAssertEqual(MultiviewPaneTile.Style.fitting(.init(width: 420, height: 260), preferred: .full), .full)
    XCTAssertEqual(MultiviewPaneTile.Style.fitting(.init(width: 800, height: 450), preferred: .compact), .compact)
  }

  func testPrimaryAndLayoutNeverFollowAudioOrReplacePlayers() throws {
    let controller = MultiviewController(channels: (0..<6).map(channel))
    defer { controller.teardown() }
    let players = controller.panes.map(\.player)
    let reloads = controller.panes.map(\.presentation.reloadID)
    let items = controller.panes.map { pane in
      let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
      pane.player.replaceCurrentItem(with: item)
      return item
    }
    XCTAssertEqual(controller.layout, .featured)
    for layout in MultiviewLayout.allCases {
      controller.setLayout(layout)
      controller.makePrimary(controller.panes[4].id)
      for pane in controller.panes {
        controller.setAudiblePane(pane.id)
        XCTAssertEqual(controller.primaryPaneID, controller.panes[4].id)
        XCTAssertEqual(controller.layout, layout)
      }
      XCTAssertEqual(controller.audiblePaneID, controller.panes[5].id)
      controller.makePrimary(controller.panes[2].id)
      XCTAssertEqual(controller.audiblePaneID, controller.panes[5].id)
      for (index, pane) in controller.panes.enumerated() {
        XCTAssertTrue(pane.player === players[index])
        XCTAssertTrue(pane.player.currentItem === items[index])
        XCTAssertEqual(pane.presentation.reloadID, reloads[index])
      }
    }
    controller.removePane(controller.panes[2].id)
    XCTAssertEqual(controller.primaryPaneID, controller.panes[0].id)
    XCTAssertEqual(controller.audiblePaneID, controller.panes.last?.id)
  }

  func testEveryPaneCanOccupyThePrimaryFrameWithoutReorderingTheLineup() throws {
    for count in 2...6 {
      let ids = (0..<count).map(String.init)
      for layout in [MultiviewLayout.featured, .spotlight] {
        let baseline = MultiviewGeometry.frames(ids: ids, size: .init(width: 1920, height: 1080),
          layout: layout, primary: ids[0], expanded: nil)
        for primary in ids {
          let frames = MultiviewGeometry.frames(ids: ids, size: .init(width: 1920, height: 1080),
            layout: layout, primary: primary, expanded: nil)
          XCTAssertEqual(frames[primary], baseline[ids[0]])
          let main = try XCTUnwrap(frames[primary])
          for id in ids where id != primary {
            let secondary = try XCTUnwrap(frames[id])
            XCTAssertGreaterThan(main.width * main.height, secondary.width * secondary.height)
          }
        }
      }
    }
  }

  func testSelectingPrimaryLayoutsPromotesFocusedPaneWithoutChangingPlayback() {
    let controller = MultiviewController(channels: (0..<4).map(channel))
    defer { controller.teardown() }
    let panes = controller.panes
    let players = panes.map(\.player)
    let reloads = panes.map(\.presentation.reloadID)
    let items = panes.map { pane in
      let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
      pane.player.replaceCurrentItem(with: item)
      return item
    }
    controller.setAudiblePane(panes[1].id)
    for layout in [MultiviewLayout.spotlight, .featured] {
      controller.setLayout(.grid)
      controller.setLayout(layout, focusedPaneID: panes[2].id)
      XCTAssertEqual(controller.primaryPaneID, panes[2].id)
      XCTAssertEqual(controller.layout, layout)
      XCTAssertEqual(controller.audiblePaneID, panes[1].id)
      controller.setAudiblePane(panes[3].id)
      XCTAssertEqual(controller.primaryPaneID, panes[2].id, "Later focus changes must not move the primary")
      controller.setLayout(layout, focusedPaneID: panes[3].id)
      XCTAssertEqual(controller.primaryPaneID, panes[3].id)
      controller.setLayout(.grid, focusedPaneID: panes[0].id)
      XCTAssertEqual(controller.primaryPaneID, panes[3].id, "Equal must not change the remembered primary")
      controller.setLayout(layout, focusedPaneID: "removed-pane")
      XCTAssertEqual(controller.primaryPaneID, panes[3].id)
      controller.setLayout(layout)
      XCTAssertEqual(controller.primaryPaneID, panes[3].id, "Programmatic restoration preserves the primary")
      for (index, pane) in controller.panes.enumerated() {
        XCTAssertTrue(pane === panes[index])
        XCTAssertTrue(pane.player === players[index])
        XCTAssertTrue(pane.player.currentItem === items[index])
        XCTAssertEqual(pane.presentation.reloadID, reloads[index])
      }
      controller.setAudiblePane(panes[1].id)
    }
  }

  func testVideoCornerRadiusIsSixteenPoints() {
    XCTAssertEqual(MultiviewGeometry.videoCornerRadius, 16)
  }

  func testRemovalRetainsSurvivorsAndReaddingCreatesANewViewLifetime() throws {
    let controller = MultiviewController(channels: (0..<4).map(channel))
    defer { controller.teardown() }
    let panes = controller.panes
    let items = panes.map { pane in
      let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
      pane.player.replaceCurrentItem(with: item)
      return item
    }
    let reloads = panes.map(\.presentation.reloadID)
    controller.setAudiblePane(panes[2].id)
    controller.makePrimary(panes[2].id)
    controller.removePane(panes[2].id)
    XCTAssertFalse(controller.panes.contains { $0 === panes[2] })
    XCTAssertTrue(panes[2].player.isMuted, "Outgoing video must become silent immediately")
    XCTAssertEqual(controller.primaryPaneID, panes[0].id)
    XCTAssertEqual(controller.audiblePaneID, panes[0].id)
    for index in [0, 1, 3] {
      let survivor = try XCTUnwrap(controller.panes.first { $0 === panes[index] })
      XCTAssertTrue(survivor.player.currentItem === items[index])
      XCTAssertEqual(survivor.presentation.reloadID, reloads[index])
    }
    XCTAssertEqual(controller.addPane(channel(2)), panes[2].id)
    let readded = try XCTUnwrap(controller.panes.last)
    XCTAssertNotEqual(readded.viewID, panes[2].viewID,
      "A quick re-add must not reuse an outgoing PlayerView's state")
    controller.teardown()
    XCTAssertNil(panes[2].player.currentItem, "Teardown also stops any outgoing transition")
    XCTAssertTrue(controller.panes.allSatisfy { $0.player.currentItem == nil })
  }

  func testRetiringCleanupDoesNotStopAQuicklyReaddedChannel() async throws {
    let controller = MultiviewController(channels: (0..<4).map(channel))
    defer { controller.teardown() }
    let outgoing = controller.panes[3]
    outgoing.player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")))
    controller.removePane(outgoing.id)
    controller.addPane(outgoing.channel)
    let replacement = try XCTUnwrap(controller.panes.last)
    let replacementItem = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
    replacement.player.replaceCurrentItem(with: replacementItem)
    for _ in 0..<100 {
      if outgoing.player.currentItem == nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(outgoing.player.currentItem, "A removed player must be released even without a mounted stage")
    XCTAssertTrue(replacement.player.currentItem === replacementItem)
    XCTAssertTrue(controller.panes.contains { $0 === replacement })
  }

  func testReducedMotionDisablesPaneReflow() {
    XCTAssertNil(MultiviewMotion.reflow(reduceMotion: true))
    XCTAssertNotNil(MultiviewMotion.reflow(reduceMotion: false))
  }

  func testRemovalPivotTracksEachPictureRatherThanTheWallCenter() {
    let size = CGSize(width: 1920, height: 1080)
    for layout in MultiviewLayout.allCases {
      let frames = MultiviewGeometry.frames(ids: ["one", "two", "three", "four"],
        size: size, layout: layout, primary: "two", expanded: nil)
      for frame in frames.values {
        let anchor = MultiviewMotion.anchor(for: frame, in: size)
        let pivot = CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
        for scale in [CGFloat(0.94), 0.5, 0.05] {
          XCTAssertEqual(pivot.x + (frame.midX - pivot.x) * scale, frame.midX, accuracy: 0.001)
          XCTAssertEqual(pivot.y + (frame.midY - pivot.y) * scale, frame.midY, accuracy: 0.001)
        }
      }
    }
  }

  func testEqualLayoutDoesNotFeatureOneOfThreeStreams() throws {
    for size in [CGSize(width: 854, height: 480), .init(width: 1280, height: 720),
      .init(width: 1920, height: 1080), .init(width: 3840, height: 2160), .init(width: 1440, height: 1080)] {
      for count in 2...6 {
        let ids = (0..<count).map(String.init)
        let frames = MultiviewGeometry.frames(ids: ids, size: size, layout: .grid,
          primary: ids.last, expanded: nil)
        let first = try XCTUnwrap(frames[ids[0]])
        XCTAssertTrue(frames.values.allSatisfy { $0.size == first.size })
      }
    }
  }

  func testToolbarUsesExistingBottomSpaceThenTranslationBeforeScaling() throws {
    let ids = ["a", "b", "c"]
    let size = CGSize(width: 1920, height: 1080)
    let baseline = MultiviewGeometry.frames(ids: ids, size: size, layout: .featured,
      primary: "b", expanded: nil)
    let room = size.height - (try XCTUnwrap(baseline.values.map(\.maxY).max())) - 5
    XCTAssertGreaterThan(room, 100, "The three-pane screenshot already has room for a toolbar")
    let unchanged = MultiviewGeometry.frames(ids: ids, size: size, layout: .featured,
      primary: "b", expanded: nil, bottomClearance: room - 1)
    XCTAssertEqual(unchanged, baseline)
    let translated = MultiviewGeometry.frames(ids: ids, size: size, layout: .featured,
      primary: "b", expanded: nil, bottomClearance: room + 50)
    for id in ids {
      XCTAssertEqual(translated[id]?.size, baseline[id]?.size)
      XCTAssertEqual(try XCTUnwrap(translated[id]).minY, try XCTUnwrap(baseline[id]).minY - 50, accuracy: 0.001)
    }
  }

  func testToolbarAndPickerNeverCoverPicturesOrOutsideOutlines() throws {
    for size in [CGSize(width: 854, height: 480), .init(width: 1280, height: 720),
      .init(width: 1920, height: 1080), .init(width: 3840, height: 2160),
      .init(width: 1440, height: 1080), .init(width: 2560, height: 1080)] {
      for count in 1...6 {
        let ids = (0..<count).map(String.init)
        for layout in MultiviewLayout.allCases {
          for clearance in [CGFloat(140), 260] {
            let frames = MultiviewGeometry.frames(ids: ids, size: size, layout: layout,
              primary: ids.last, expanded: nil, bottomClearance: clearance)
            XCTAssertEqual(Set(frames.keys), Set(ids))
            for (id, frame) in frames {
              XCTAssertGreaterThan(frame.width, 0)
              XCTAssertGreaterThan(frame.height, 0)
              XCTAssertEqual(frame.width / frame.height, 16 / 9, accuracy: 0.0001)
              XCTAssertGreaterThanOrEqual(frame.minY, 4.999)
              XCTAssertGreaterThanOrEqual(frame.minX, 4.999)
              XCTAssertLessThanOrEqual(frame.maxX + 5, size.width + 0.001)
              XCTAssertLessThanOrEqual(frame.maxY + 5, size.height - clearance + 0.001)
              for (otherID, other) in frames where id != otherID {
                let dx = max(0, frame.minX - other.maxX, other.minX - frame.maxX)
                let dy = max(0, frame.minY - other.maxY, other.minY - frame.maxY)
                XCTAssertGreaterThanOrEqual(max(dx, dy), 9.999)
              }
            }
            let expanded = MultiviewGeometry.frames(ids: ids, size: size, layout: layout,
              primary: ids.last, expanded: ids[0], bottomClearance: clearance)
            XCTAssertEqual(expanded[ids[0]], CGRect(origin: .zero, size: size))
          }
        }
      }
    }
  }

  private func channel(_ index: Int) -> FollowedChannel {
    .init(id: "\(index)", login: "layout\(index)", displayName: "Stream \(index)",
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
  }
}

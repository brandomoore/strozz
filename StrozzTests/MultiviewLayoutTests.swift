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

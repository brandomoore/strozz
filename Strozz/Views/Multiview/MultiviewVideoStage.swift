import SwiftUI

enum MultiviewMotion {
  static func reflow(reduceMotion: Bool) -> Animation? {
    .motionAware(.smooth(duration: 0.35), reduceMotion: reduceMotion)
  }

  static func anchor(for frame: CGRect, in size: CGSize) -> UnitPoint {
    UnitPoint(x: frame.midX / size.width, y: frame.midY / size.height)
  }

  static func transition(anchor: UnitPoint, reduceMotion: Bool) -> AnyTransition {
    .asymmetric(
      insertion: .motionAware(.scale(scale: 0.94, anchor: anchor).combined(with: .opacity), reduceMotion: reduceMotion),
      removal: .motionAware(.scale(scale: 0.05, anchor: anchor).combined(with: .opacity), reduceMotion: reduceMotion))
      .animation(.easeInOut(duration: reduceMotion ? 0.18 : 0.25))
  }
}

/// Layout changes only the bounds of identity-stable player subtrees.
struct MultiviewVideoStage<Content: View>: View {
  let controller: MultiviewController
  var bottomClearance: CGFloat = 0
  @ViewBuilder var content: (MultiviewPane) -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let frames = MultiviewGeometry.frames(ids: controller.panes.map(\.id), size: geometry.size,
        layout: controller.layout, primary: controller.primaryPaneID, expanded: controller.expandedPaneID,
        aspectRatios: Dictionary(uniqueKeysWithValues: controller.panes.map {
          ($0.id, $0.presentation.videoAspectRatio)
        }), bottomClearance: bottomClearance)
      ZStack(alignment: .topLeading) {
        ForEach(controller.panes, id: \.viewID) { pane in
          if let frame = frames[pane.id] {
            content(pane)
              .frame(width: frame.width, height: frame.height)
              .position(x: frame.midX, y: frame.midY)
              // Position fills the stage; normalize the pivot to the picture, not the wall.
              .transition(MultiviewMotion.transition(
                anchor: MultiviewMotion.anchor(for: frame, in: geometry.size), reduceMotion: reduceMotion))
              .opacity(pane.presentation.videoIsVisible ? 1 : 0)
              .allowsHitTesting(pane.presentation.videoIsVisible)
              .accessibilityHidden(!pane.presentation.videoIsVisible)
              .zIndex(pane.presentation.isExpanded ? 2 : 0)
          }
        }
      }
      .animation(MultiviewMotion.reflow(reduceMotion: reduceMotion), value: frames)
    }
  }
}

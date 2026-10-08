import SwiftUI

/// Layout changes only the bounds of identity-stable player subtrees.
struct MultiviewVideoStage<Content: View>: View {
  let controller: MultiviewController
  @ViewBuilder var content: (MultiviewPane) -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let frames = MultiviewGeometry.frames(ids: controller.panes.map(\.id), size: geometry.size,
        layout: controller.layout, primary: controller.primaryPaneID, expanded: controller.expandedPaneID)
      ZStack(alignment: .topLeading) {
        ForEach(controller.panes) { pane in
          if let frame = frames[pane.id] {
            content(pane)
              .frame(width: frame.width, height: frame.height)
              .position(x: frame.midX, y: frame.midY)
              .opacity(controller.expandedPaneID == nil || pane.presentation.isExpanded ? 1 : 0)
              .allowsHitTesting(controller.expandedPaneID == nil || pane.presentation.isExpanded)
              .accessibilityHidden(controller.expandedPaneID != nil && !pane.presentation.isExpanded)
              .zIndex(pane.presentation.isExpanded ? 2 : 0)
          }
        }
      }
      .animation(.motionAware(.easeInOut(duration: 0.35), reduceMotion: reduceMotion), value: controller.expandedPaneID)
      .animation(.motionAware(.easeInOut(duration: 0.35), reduceMotion: reduceMotion), value: controller.layout)
      .animation(.motionAware(.easeInOut(duration: 0.35), reduceMotion: reduceMotion), value: controller.primaryPaneID)
    }
  }
}

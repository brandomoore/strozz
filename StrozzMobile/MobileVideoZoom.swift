import AVFoundation
import SwiftUI

struct MobileVideoZoom: Equatable {
  static let maximumScale: CGFloat = 4
  var scale: CGFloat = 1
  var offset: CGSize = .zero

  var isZoomed: Bool { scale > 1 }

  func magnified(_ magnification: CGFloat, from anchor: CGPoint, to location: CGPoint,
                 viewport: CGSize, videoSize: CGSize) -> Self {
    let nextScale = min(Self.maximumScale, max(1, scale * magnification))
    let ratio = nextScale / scale
    let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
    return Self(scale: nextScale, offset: CGSize(
      width: location.x - center.x - (anchor.x - center.x - offset.width) * ratio,
      height: location.y - center.y - (anchor.y - center.y - offset.height) * ratio))
      .clamped(viewport: viewport, videoSize: videoSize)
  }

  func panned(_ translation: CGSize, viewport: CGSize, videoSize: CGSize) -> Self {
    Self(scale: scale, offset: CGSize(width: offset.width + translation.width,
      height: offset.height + translation.height))
      .clamped(viewport: viewport, videoSize: videoSize)
  }

  func clamped(viewport: CGSize, videoSize: CGSize) -> Self {
    guard isZoomed else { return Self() }
    let aspect = videoSize.width > 0 && videoSize.height > 0 ? videoSize : CGSize(width: 16, height: 9)
    let fitted = AVMakeRect(aspectRatio: aspect, insideRect: CGRect(origin: .zero, size: viewport))
    let horizontal = max(0, (fitted.width * scale - viewport.width) / 2)
    let vertical = max(0, (fitted.height * scale - viewport.height) / 2)
    return Self(scale: scale, offset: CGSize(
      width: min(horizontal, max(-horizontal, offset.width)),
      height: min(vertical, max(-vertical, offset.height))))
  }
}

struct MobileVideoPinchGesture: UIGestureRecognizerRepresentable {
  let enabled: Bool
  let onChange: (UIGestureRecognizer.State, CGFloat, CGPoint) -> Void

  func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
    let recognizer = UIPinchGestureRecognizer()
    recognizer.isEnabled = enabled
    return recognizer
  }

  func updateUIGestureRecognizer(_ recognizer: UIPinchGestureRecognizer, context: Context) {
    recognizer.isEnabled = enabled
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
    onChange(recognizer.state, recognizer.scale, context.converter.localLocation)
  }
}

struct MobileVideoDragGesture: UIGestureRecognizerRepresentable {
  let enabled: Bool
  let onChange: (UIGestureRecognizer.State, CGSize, CGSize) -> Void

  func makeUIGestureRecognizer(context: Context) -> MobileVideoPanGestureRecognizer {
    let recognizer = MobileVideoPanGestureRecognizer()
    // A two-finger pinch must never become the existing swipe-to-minimize gesture.
    recognizer.maximumNumberOfTouches = 1
    recognizer.isEnabled = enabled
    return recognizer
  }

  func updateUIGestureRecognizer(_ recognizer: MobileVideoPanGestureRecognizer, context: Context) {
    recognizer.isEnabled = enabled
  }

  func handleUIGestureRecognizerAction(_ recognizer: MobileVideoPanGestureRecognizer, context: Context) {
    // SwiftUI's converter is reprojected while collapse moves the gesture's
    // view. Measure in the fixed window so resizing cannot consume finger travel.
    let translation = recognizer.touchTranslation
    let velocity = recognizer.velocity(in: nil)
    onChange(recognizer.state, CGSize(width: translation.x, height: translation.y),
             CGSize(width: velocity.x, height: velocity.y))
  }
}

final class MobileVideoPanGestureRecognizer: UIPanGestureRecognizer {
  // Preserve travel before UIPan recognizes the drag, including short flicks.
  private var touchOrigin: CGPoint?

  var touchTranslation: CGPoint {
    guard let touchOrigin else { return translation(in: nil) }
    let current = location(in: nil)
    return CGPoint(x: current.x - touchOrigin.x, y: current.y - touchOrigin.y)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if touchOrigin == nil { touchOrigin = touches.first?.location(in: nil) }
    super.touchesBegan(touches, with: event)
  }

  override func reset() {
    super.reset()
    touchOrigin = nil
  }
}

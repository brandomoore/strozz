import SwiftUI
import UIKit

/// A window-level recognizer also receives presses over sheets and full-screen players.
struct MultiviewRemoteShortcut: UIViewRepresentable {
  let lineup: MultiviewLineup
  let palette: ThemePalette
  let glassDisabled: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(lineup: lineup, palette: palette, glassDisabled: glassDisabled)
  }

  func makeUIView(context: Context) -> WindowProbe {
    let view = WindowProbe()
    view.isHidden = true
    view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
    return view
  }

  func updateUIView(_ uiView: WindowProbe, context: Context) {
    context.coordinator.updateAppearance(palette: palette, glassDisabled: glassDisabled)
    context.coordinator.attach(to: uiView.window)
  }

  static func dismantleUIView(_ uiView: WindowProbe, coordinator: Coordinator) {
    uiView.windowChanged = nil
    coordinator.attach(to: nil)
  }

  final class WindowProbe: UIView {
    var windowChanged: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      windowChanged?(window)
    }
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    let lineup: MultiviewLineup
    private var palette: ThemePalette
    private var glassDisabled: Bool
    private weak var window: UIWindow?
    private var recognizer: UILongPressGestureRecognizer?
    private var toast: UIHostingController<MultiviewShortcutToast>?
    private var toastTask: Task<Void, Never>?

    init(lineup: MultiviewLineup, palette: ThemePalette, glassDisabled: Bool) {
      self.lineup = lineup
      self.palette = palette
      self.glassDisabled = glassDisabled
    }

    func updateAppearance(palette: ThemePalette, glassDisabled: Bool) {
      self.palette = palette
      self.glassDisabled = glassDisabled
      if let toast {
        toast.rootView = MultiviewShortcutToast(message: toast.rootView.message,
          palette: palette, glassDisabled: glassDisabled)
      }
    }

    func attach(to window: UIWindow?) {
      guard self.window !== window else { return }
      if let recognizer { self.window?.removeGestureRecognizer(recognizer) }
      hideToast()
      lineup.cancelPlaybackRequest()
      self.window = window
      recognizer = nil
      guard let window else { return }
      let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
      hold.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
      hold.minimumPressDuration = 0.7
      hold.delegate = self
      window.addGestureRecognizer(hold)
      recognizer = hold
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      otherGestureRecognizer.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.playPause.rawValue))
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
      guard recognizer.state == .began, !lineup.isOpeningPlayback else { return }
      guard lineup.canStart || lineup.isShowingPlayback else {
        showToast(lineup.liveChannels.isEmpty && lineup.controller == nil
          ? "Add two streams to multiview." : "Add another stream to multiview.")
        return
      }
      hideToast()
      guard let window, let root = window.rootViewController else { return }
      lineup.preparePlaybackRequest()
      window.endEditing(true)
      let open = { [weak self, weak window] in
        guard let self, let window, self.window === window else { return }
        self.lineup.requestPlayback()
      }
      if root.presentedViewController != nil { root.dismiss(animated: true, completion: open) }
      else { open() }
    }

    private func showToast(_ message: LocalizedStringResource) {
      guard let window else { return }
      hideToast()
      let host = UIHostingController(rootView: MultiviewShortcutToast(message: message,
        palette: palette, glassDisabled: glassDisabled))
      host.view.backgroundColor = .clear
      host.view.isUserInteractionEnabled = false
      host.view.frame = window.bounds
      host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      host.view.layer.zPosition = 1_000
      window.addSubview(host.view)
      toast = host
      UIAccessibility.post(notification: .announcement, argument: String(localized: message))
      toastTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        self?.hideToast()
      }
    }

    private func hideToast() {
      toastTask?.cancel()
      toastTask = nil
      toast?.view.removeFromSuperview()
      toast = nil
    }
  }
}

private struct MultiviewShortcutToast: View {
  let message: LocalizedStringResource
  let palette: ThemePalette
  let glassDisabled: Bool

  var body: some View {
    ToastPill {
      HStack(spacing: 14) {
        Icon(glyph: .borderAll, size: 30)
        Text(message)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("multiview-shortcut-toast")
    .padding(.top, 48)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.themePalette, palette)
    .environment(\.glassDisabled, glassDisabled)
    .environment(\.colorScheme, palette.chromeColorScheme)
  }
}

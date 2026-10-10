import SwiftUI

// SwiftUI's vertical TextField inserts a newline even with submitLabel(.send).
struct MobileChatTextInput: UIViewRepresentable {
  @Binding var text: String
  let sending: Bool
  let onSend: () -> Void
  @Environment(\.themePalette) private var palette
  @ScaledMetric(relativeTo: .body) private var fontSize = 17

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.delegate = context.coordinator
    view.backgroundColor = .clear
    view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
    view.textContainer.lineFragmentPadding = 0
    view.returnKeyType = .send
    view.enablesReturnKeyAutomatically = true
    view.scrollsToTop = false
    view.bounces = false
    view.contentInsetAdjustmentBehavior = .never
    view.accessibilityLabel = String(localized: "Send a message")
    view.accessibilityIdentifier = "mobile-chat-composer-input"
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.parent = self
    if view.text != text { view.text = text }
    view.font = .systemFont(ofSize: fontSize)
    view.textColor = UIColor(palette.chatSidePrimaryText)
    view.tintColor = UIColor(palette.chatSidePrimaryText)
    view.isEditable = !sending
    view.isUserInteractionEnabled = !sending
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0, let font = uiView.font else { return nil }
    let content = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    let maximum = font.lineHeight * 4 + uiView.textContainerInset.top + uiView.textContainerInset.bottom
    return CGSize(width: width, height: max(44, min(ceil(content.height), ceil(maximum))))
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: MobileChatTextInput

    init(_ parent: MobileChatTextInput) { self.parent = parent }

    func textViewDidChange(_ textView: UITextView) {
      parent.text = textView.text
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
      guard !parent.sending else { return false }
      guard text == "\n", textView.markedTextRange == nil else { return true }
      if !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parent.onSend()
      }
      return false
    }
  }
}

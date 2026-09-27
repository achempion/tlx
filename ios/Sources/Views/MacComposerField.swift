import SwiftUI

#if targetEnvironment(macCatalyst)
/// Native text insets keep the entire composer capsule clickable for focus.
struct MacComposerField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    let onSend: () -> Void

    private let insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textContainerInset = insets
        view.textContainer.lineFragmentPadding = 0
        view.placeholderLabel.font = view.font
        view.placeholderLabel.textColor = .placeholderText
        view.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(view.placeholderLabel)
        NSLayoutConstraint.activate([
            view.placeholderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.left),
            view.placeholderLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top),
            view.placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.frameLayoutGuide.trailingAnchor, constant: -insets.right),
        ])
        view.requestFocus = { [weak view, weak coordinator = context.coordinator] in
            DispatchQueue.main.async {
                guard let view, let coordinator, coordinator.parent.focused, view.window != nil else { return }
                if !view.isFirstResponder && !view.becomeFirstResponder() { coordinator.parent.focused = false }
            }
        }
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        view.onSend = onSend
        view.isEditable = context.environment.isEnabled
        if view.text != text { view.text = text }
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.isHidden = !text.isEmpty
        if focused {
            view.requestFocus?()
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: TextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let line = view.font?.lineHeight ?? 16
        let vertical = insets.top + insets.bottom
        let height = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(height, line + vertical), line * CGFloat(chatComposerLines.upperBound) + vertical))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class TextView: UITextView {
        var onSend: (() -> Void)?
        var requestFocus: (() -> Void)?
        let placeholderLabel = UILabel()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { requestFocus?() }
        }

        override var keyCommands: [UIKeyCommand]? {
            (super.keyCommands ?? []) + [
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnKey(_:))),
                UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(shiftReturn(_:))),
            ]
        }

        @objc private func returnKey(_ command: UIKeyCommand) {
            if markedTextRange != nil { unmarkText() }
            else { onSend?() }
        }

        @objc private func shiftReturn(_ command: UIKeyCommand) {
            if markedTextRange != nil { unmarkText() }
            insertText("\n")
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MacComposerField
        init(parent: MacComposerField) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) { parent.text = view.text }
        func textViewDidBeginEditing(_ view: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ view: UITextView) { if parent.focused { parent.focused = false } }
    }
}
#endif

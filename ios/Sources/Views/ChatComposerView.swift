import SwiftUI

let chatComposerLines = 1...6
private let sendButtonSize: CGFloat = 40

#if targetEnvironment(macCatalyst)
typealias ComposerFocusBinding = Binding<Bool>
#else
typealias ComposerFocusBinding = FocusState<Bool>.Binding
#endif

struct ChatComposerView: View {
    let title: String
    let editor: Composer
    let focused: ComposerFocusBinding
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if !editor.failure.isEmpty {
                Text(editor.failure).font(.footnote).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                field
                    .frame(maxWidth: .infinity, minHeight: sendButtonSize)
                    .modifier(ComposerSurface(shape: RoundedRectangle(cornerRadius: 22), interactive: false))
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: sendButtonSize, height: sendButtonSize)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Send message")
                .buttonStyle(.borderless)
                .modifier(ComposerSurface(shape: Circle()))
                .disabled(editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let text = Binding(get: { editor.text }, set: { editor.edit($0) })
        let placeholder = "Message \(title)"
        #if targetEnvironment(macCatalyst)
        MacComposerField(placeholder: placeholder, text: text, focused: focused, onSend: onSend)
        #else
        TextField(placeholder, text: text, axis: .vertical)
            .lineLimit(chatComposerLines)
            .focused(focused)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        #endif
    }
}

private struct ComposerSurface<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    var interactive = true

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.background {
                    Color.clear.glassEffect(.regular, in: shape).allowsHitTesting(false)
                }
            }
        } else {
            let rim = LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(rim, lineWidth: 0.5).allowsHitTesting(false))
        }
    }
}

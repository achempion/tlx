import SwiftUI

#if targetEnvironment(macCatalyst)
/// Keeps transcript scrolling from rebuilding Catalyst's window toolbar on chat changes.
struct MacChatContent<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> Controller { Controller(rootView: content) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.rootView = content }

    final class Controller: UIHostingController<Content> {
        override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
            return edge == .top ? nil : super.contentScrollView(for: edge)
        }
    }
}
#endif

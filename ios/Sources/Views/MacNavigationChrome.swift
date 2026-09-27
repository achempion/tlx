import SwiftUI

#if targetEnvironment(macCatalyst)
extension ToolbarContent {
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(iOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

/// Catalyst can restore its sidebar toggle whenever either column's navigation bar mounts.
struct MacSidebarConfiguration: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configure()
    }

    final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            configure()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            configure()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            configure()
        }

        func configure() {
            guard let split = splitViewController else { return }
            if split.primaryBackgroundStyle != .none { split.primaryBackgroundStyle = .none }
            if split.displayModeButtonVisibility != .never { split.displayModeButtonVisibility = .never }
            if split.presentsWithGesture { split.presentsWithGesture = false }
            guard let titlebar = view.window?.windowScene?.titlebar else { return }
            if titlebar.toolbarStyle != .unified { titlebar.toolbarStyle = .unified }
            if let toolbar = titlebar.toolbar {
                for (index, item) in toolbar.items.enumerated().reversed() where item.itemIdentifier == .toggleSidebar {
                    toolbar.removeItem(at: index)
                }
            }
        }
    }
}

struct MacWindowTitleHidden: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var titlebar: UITitlebar?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            hideTitle()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hideTitle()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Restoring during the push would overlap the outgoing chat header.
            transitionCoordinator?.animate(alongsideTransition: nil) { [titlebar] context in
                if !context.isCancelled { titlebar?.titleVisibility = .visible }
            }
        }

        private func hideTitle() {
            titlebar = view.window?.windowScene?.titlebar
            titlebar?.titleVisibility = .hidden
        }
    }
}
#endif

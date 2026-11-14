#if os(iOS)
import SwiftUI
import UIKit

/// Pops the enclosing navigation stack to its root when the shell asks for it.
///
/// Search results push their detail page through a view-based `NavigationLink`
/// (`MediaArtworkZoomLink`), so there is no `NavigationPath` to clear: a pushed page
/// can only be dismissed by the `UINavigationController` that hosts it. Pressing the
/// Search tab while a result is open is a request for "search", so this walks up to
/// that controller and pops it.
///
/// Deliberately a no-op unless the request counter changes, so a normal push is never
/// disturbed, and it only pops the stack it is installed in — the other tabs' stacks
/// are untouched.
struct PlozziOSNavigationPopProxy: UIViewControllerRepresentable {
    let request: Int

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.request = request
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.request = request
    }

    final class Controller: UIViewController {
        var request: Int = 0 {
            didSet {
                guard request != oldValue, request > 0 else { return }
                // Deferred: the update pass can run while the navigation controller is
                // mid-transition, and popping there is what drops frames.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await Task.yield()
                    self.enclosingNavigationController()?.popToRootViewController(animated: false)
                }
            }
        }

        private func enclosingNavigationController() -> UINavigationController? {
            var candidate: UIViewController? = self
            while let current = candidate {
                if let navigation = current.navigationController { return navigation }
                candidate = current.parent ?? current.presentingViewController
            }
            return nil
        }

        override func loadView() {
            // Zero-size so it can sit in a background without affecting layout.
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
    }
}
#endif

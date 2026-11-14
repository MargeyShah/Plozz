#if os(iOS)
import SwiftUI
import UIKit

/// Keeps a pushed page inert until its navigation transition has finished.
/// SwiftUI mounts the destination's controls before the push settles; a second tap
/// can otherwise land on the destination and activate Play or a description area.
struct PlozziOSNavigationTransitionGate: UIViewControllerRepresentable {
    @Binding var isInteractive: Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onChange = { isInteractive = $0 }
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onChange = { isInteractive = $0 }
    }

    final class Controller: UIViewController {
        var onChange: ((Bool) -> Void)?
        private var lastPublished: Bool?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Also clears the push state if the tab-root coordinator misses its
            // completion (e.g. a custom transition), so a detail can never wait for
            // a signal that will not arrive.
            PlozziOSNavigationTransitionState.end()
            if let coordinator = transitionCoordinator, animated {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.publish(true)
                }
            } else {
                publish(true)
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            publish(false)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if lastPublished != true { publish(false) }
        }

        private func publish(_ value: Bool) {
            guard lastPublished != value else { return }
            lastPublished = value
            Task { @MainActor [weak self] in self?.onChange?(value) }
        }

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
    }
}
#endif

#if os(iOS)
import Foundation

extension Notification.Name {
    /// Posted when a navigation push has finished animating.
    static let plozziOSNavigationPushSettled = Notification.Name("plozz.navigation.pushSettled")
}

/// Process-wide state for the push transition. Destinations use it to keep their
/// own data loads off the transition frames, without a wall-clock delay: a page
/// presented outside a push runs immediately.
@MainActor
enum PlozziOSNavigationTransitionState {
    private(set) static var isPushing = false

    static func begin() {
        isPushing = true
    }

    static func end() {
        guard isPushing else { return }
        isPushing = false
        NotificationCenter.default.post(name: .plozziOSNavigationPushSettled, object: nil)
    }

    /// Suspends until the current push settles. Re-checks after subscribing so a
    /// notification that lands in the gap cannot strand the caller.
    static func waitUntilSettled() async {
        while isPushing {
            for await _ in NotificationCenter.default.notifications(
                named: .plozziOSNavigationPushSettled
            ) {
                break
            }
        }
    }
}
#endif

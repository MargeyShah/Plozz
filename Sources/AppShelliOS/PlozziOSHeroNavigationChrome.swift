#if os(iOS)
import SwiftUI

/// Keeps a full-bleed hero visible beneath the status and navigation bars.
///
/// iOS 26 draws a scroll-edge treatment and gives the navigation bar a new
/// background-visibility API. A hero that is meant to meet the physical top
/// edge has to hide both, otherwise the system paints a page-coloured band over
/// the artwork. The deployment targets before iOS 26 keep the existing
/// `toolbarBackground` behavior.
struct PlozziOSHeroNavigationChrome: ViewModifier {
    /// False when Home has no hero. The navigation bar stays transparent as it
    /// did before iOS 26, but rows keep the system's ordinary scroll-edge
    /// treatment.
    var isFullBleed = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .scrollEdgeEffectHidden(isFullBleed, for: .top)
        } else {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

extension View {
    /// Hides the top navigation chrome while a full-bleed hero owns the page.
    func plozziOSHeroNavigationChrome(isFullBleed: Bool = true) -> some View {
        modifier(PlozziOSHeroNavigationChrome(isFullBleed: isFullBleed))
    }
}
#endif

import SwiftUI

/// Reserves a view's final geometry while its content is still loading.
///
/// Loading placeholders exist for two different jobs, and mixing them up is what
/// produced the reflows this exists to prevent:
///
/// 1. **Reserve the space** so the page does not jump when real content arrives.
/// 2. **Signal that something is happening**, which is only worth showing when the
///    viewer asked for it (a filter change, a season switch) or the wait is long.
///
/// A placeholder that is *only* the second thing leaves a zero-height hole and
/// reflows the page; one that is always visible flashes on every load. So the
/// placeholder is **always laid out** while pending (`isPending`), and
/// `revealsPlaceholder` decides only whether it is painted. Neither decision may
/// be driven by elapsed time — see `docs/swiftui-guidelines.md`.
///
/// ```swift
/// PlozzReservedPlaceholder(
///     isPending: episodes == nil,
///     revealsPlaceholder: viewerChangedSeason
/// ) {
///     EpisodeSkeletonRail()          // real card height
/// } content: {
///     EpisodeRail(episodes)
/// }
/// ```
public struct PlozzReservedPlaceholder<Placeholder: View, Content: View>: View {
    private let isPending: Bool
    private let revealsPlaceholder: Bool
    private let placeholder: Placeholder
    private let content: Content

    public init(
        isPending: Bool,
        revealsPlaceholder: Bool = false,
        @ViewBuilder placeholder: () -> Placeholder,
        @ViewBuilder content: () -> Content
    ) {
        self.isPending = isPending
        self.revealsPlaceholder = revealsPlaceholder
        self.placeholder = placeholder()
        self.content = content()
    }

    public var body: some View {
        if isPending {
            placeholder
                // Laid out either way: `.opacity` keeps the placeholder's real
                // height, which is the whole point of reserving it.
                .opacity(revealsPlaceholder ? 1 : 0)
                .accessibilityHidden(!revealsPlaceholder)
        } else {
            content
        }
    }
}

import CoreModels
import CoreNetworking
import Foundation

/// One-time **app-side** disposal of locally stored Jellyfin Continue Watching
/// state.
///
/// The rows themselves live on the server: Plozz's Continue Watching is
/// `Items/Resume` plus `Shows/NextUp`, read live, so no local change can remove a
/// resume point Jellyfin still stores. What app-side state *can* do is keep a row
/// alive after the server dropped it, and that is what this clears:
///
///  * **Jellyfin-sourced cards in the persisted Home row.** The carry-forward
///    path re-adds a cached card while a write is still queued or was applied
///    moments ago, and the snapshot is what it carries from.
///  * **Pending in-progress resume writes aimed at Jellyfin.** A position queued
///    by the pre-fix writer publishes the same row again as soon as it drains.
///
/// A card that also exists on another provider, and a write that still has a
/// target on another provider, are kept: a multi-server profile keeps the rows it
/// still owns. Completion writes (`played`, `clearResume`) are kept too — they
/// remove rows rather than create them, so dropping them could only leave a
/// stale row behind.
///
/// Run once per profile after the update that changed Jellyfin's resume write
/// path. The marker is written only after both stores were rewritten, so a
/// failure retries on the next launch instead of half-applying.
public enum ContinueWatchingLocalReset {
    /// Bump when the disposal needs to run again on the same devices.
    public static let version = 1

    public struct Summary: Sendable, Equatable {
        /// Jellyfin-only cards removed from the persisted Home row.
        public var removedCards = 0
        /// Pending resume writes whose Jellyfin targets were dropped.
        public var rewrittenWrites = 0
        /// Pending resume writes that had no target left and were removed.
        public var droppedWrites = 0

        public var isNoOp: Bool {
            removedCards == 0 && rewrittenWrites == 0 && droppedWrites == 0
        }

        public init(removedCards: Int = 0, rewrittenWrites: Int = 0, droppedWrites: Int = 0) {
            self.removedCards = removedCards
            self.rewrittenWrites = rewrittenWrites
            self.droppedWrites = droppedWrites
        }
    }

    /// Runs the disposal once per profile. Returns `nil` when it already ran.
    ///
    /// The caller passes the **same** outbox store the reconciler is about to
    /// load, so the rewriting is visible to the first drain rather than being
    /// overwritten by a stale in-memory copy.
    @discardableResult
    public static func runIfNeeded(
        profileID: String,
        homeStore: any HomeContentStoring,
        outbox: any WatchMutationStoring,
        defaults: UserDefaults = .standard
    ) -> Summary? {
        let key = appliedKey(profileID: profileID)
        guard !defaults.bool(forKey: key) else { return nil }
        do {
            let summary = try apply(homeStore: homeStore, outbox: outbox)
            defaults.set(true, forKey: key)
            if !summary.isNoOp {
                PlozzLog.app.info(
                    "Continue Watching reset removed \(summary.removedCards) cached Jellyfin cards and "
                        + "\(summary.rewrittenWrites + summary.droppedWrites) queued Jellyfin resume writes."
                )
            }
            return summary
        } catch {
            PlozzLog.app.error(
                "Continue Watching reset could not rewrite stored state; retrying on the next launch."
            )
            return nil
        }
    }

    static func appliedKey(profileID: String) -> String {
        "plozz.continue-watching-reset.jellyfin.v\(version).\(profileID)"
    }

    /// Applies the disposal. `homeStore` is only written when a card was actually
    /// removed, so a profile with nothing to prune keeps its snapshot timestamp
    /// (and the freshness window that depends on it).
    public static func apply(
        homeStore: any HomeContentStoring,
        outbox: any WatchMutationStoring
    ) throws -> Summary {
        var summary = Summary()

        if let content = homeStore.load() {
            let pruned = pruneCards(content, summary: &summary)
            if summary.removedCards > 0 {
                homeStore.save(pruned)
            }
        }

        var state = outbox.load()
        let pruned = pruneResumeWrites(state.pending, summary: &summary)
        if summary.rewrittenWrites + summary.droppedWrites > 0 {
            state.pending = pruned
            try outbox.save(state)
        }
        return summary
    }

    // MARK: - Rules

    static func pruneCards(
        _ content: HomeViewModel.Content,
        summary: inout Summary
    ) -> HomeViewModel.Content {
        var content = content
        let before = content.continueWatching.count
        content.continueWatching.removeAll { isJellyfinOnly($0) }
        summary.removedCards = before - content.continueWatching.count
        return content
    }

    /// A card is "Jellyfin only" when every provider we can attribute it to is
    /// Jellyfin. Unknown attribution keeps the card: deleting a row because a
    /// cache predates the provider field would be a guess.
    static func isJellyfinOnly(_ item: MediaItem) -> Bool {
        let kinds = item.sources.compactMap(\.providerKind)
        guard !kinds.isEmpty else { return false }
        return kinds.allSatisfy { $0 == .jellyfin }
    }

    static func pruneResumeWrites(
        _ pending: [WatchMutation],
        summary: inout Summary
    ) -> [WatchMutation] {
        pending.compactMap { mutation in
            // Only an in-progress position can publish a Continue Watching row,
            // and only that kind of write is disposable here.
            guard mutation.resumePosition != nil, mutation.played != true else {
                return mutation
            }
            guard mutation.targets.contains(where: { $0.providerKind == .jellyfin }) else {
                return mutation
            }
            var mutation = mutation
            mutation.targets.removeAll { $0.providerKind == .jellyfin }
            summary.rewrittenWrites += 1
            if mutation.targets.isEmpty {
                summary.droppedWrites += 1
                return nil
            }
            return mutation
        }
    }
}

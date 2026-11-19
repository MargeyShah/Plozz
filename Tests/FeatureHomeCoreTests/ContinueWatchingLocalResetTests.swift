import CoreModels
import XCTest
@testable import FeatureHomeCore

/// The one-time app-side disposal that accompanies the Jellyfin resume-write
/// change. It must remove exactly the local state that can keep a dropped
/// Jellyfin row alive, and nothing a multi-server profile still owns.
final class ContinueWatchingLocalResetTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ContinueWatchingLocalResetTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Cards

    func testRemovesOnlyCardsAttributedEntirelyToJellyfin() {
        let content = HomeViewModel.Content(continueWatching: [
            item("jf", sources: [.init(accountID: "a", itemID: "1", providerKind: .jellyfin)]),
            item("plex", sources: [.init(accountID: "b", itemID: "2", providerKind: .plex)]),
            item("mixed", sources: [
                .init(accountID: "a", itemID: "3", providerKind: .jellyfin),
                .init(accountID: "b", itemID: "4", providerKind: .plex)
            ]),
            item("unknown", sources: [.init(accountID: "c", itemID: "5")])
        ])
        var summary = ContinueWatchingLocalReset.Summary()

        let pruned = ContinueWatchingLocalReset.pruneCards(content, summary: &summary)

        XCTAssertEqual(pruned.continueWatching.map(\.id), ["plex", "mixed", "unknown"])
        XCTAssertEqual(summary.removedCards, 1)
    }

    func testCardWithoutSourcesSurvives() {
        var summary = ContinueWatchingLocalReset.Summary()
        let content = HomeViewModel.Content(continueWatching: [item("legacy", sources: [])])

        let pruned = ContinueWatchingLocalReset.pruneCards(content, summary: &summary)

        XCTAssertEqual(pruned.continueWatching.map(\.id), ["legacy"])
        XCTAssertTrue(summary.isNoOp)
    }

    // MARK: - Pending writes

    func testDropsAJellyfinOnlyResumeWrite() {
        var summary = ContinueWatchingLocalReset.Summary()
        let pending = ContinueWatchingLocalReset.pruneResumeWrites([
            mutation(resumePosition: 120, targets: [target("a", .jellyfin)])
        ], summary: &summary)

        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(summary.rewrittenWrites, 1)
        XCTAssertEqual(summary.droppedWrites, 1)
    }

    func testKeepsAnotherProvidersTargetOnAResumeWrite() {
        var summary = ContinueWatchingLocalReset.Summary()
        let pending = ContinueWatchingLocalReset.pruneResumeWrites([
            mutation(resumePosition: 120, targets: [target("a", .jellyfin), target("b", .plex)])
        ], summary: &summary)

        XCTAssertEqual(pending.first?.targets.map(\.accountID), ["b"])
        XCTAssertEqual(summary.rewrittenWrites, 1)
        XCTAssertEqual(summary.droppedWrites, 0)
    }

    func testKeepsCompletionAndDismissalWrites() {
        var summary = ContinueWatchingLocalReset.Summary()
        let pending = ContinueWatchingLocalReset.pruneResumeWrites([
            mutation(played: true, clearResume: true, targets: [target("a", .jellyfin)]),
            mutation(clearResume: true, targets: [target("a", .jellyfin)])
        ], summary: &summary)

        XCTAssertEqual(pending.count, 2, "Only an in-progress resume write can publish a row.")
        XCTAssertTrue(summary.isNoOp)
    }

    // MARK: - One-shot

    func testRunsOncePerProfileAndThenStaysOutOfTheWay() throws {
        let home = InMemoryHomeContentStore(HomeViewModel.Content(continueWatching: [
            item("jf", sources: [.init(accountID: "a", itemID: "1", providerKind: .jellyfin)]),
            item("plex", sources: [.init(accountID: "b", itemID: "2", providerKind: .plex)])
        ]))
        let outbox = InMemoryWatchMutationStore(WatchOutboxState(
            pending: [mutation(resumePosition: 60, targets: [target("a", .jellyfin)])]
        ))

        let first = ContinueWatchingLocalReset.runIfNeeded(
            profileID: "profile-1", homeStore: home, outbox: outbox, defaults: defaults
        )
        XCTAssertEqual(first?.removedCards, 1)
        XCTAssertEqual(home.load()?.continueWatching.map(\.id), ["plex"])
        XCTAssertTrue(outbox.load().pending.isEmpty)

        // A later row is not re-pruned: the disposal is a migration, not a rule.
        home.save(HomeViewModel.Content(continueWatching: [
            item("jf-again", sources: [.init(accountID: "a", itemID: "9", providerKind: .jellyfin)])
        ]))
        let second = ContinueWatchingLocalReset.runIfNeeded(
            profileID: "profile-1", homeStore: home, outbox: outbox, defaults: defaults
        )
        XCTAssertNil(second)
        XCTAssertEqual(home.load()?.continueWatching.map(\.id), ["jf-again"])
    }

    func testAnotherProfileStillGetsItsOwnRun() {
        let home = InMemoryHomeContentStore(HomeViewModel.Content(continueWatching: [
            item("jf", sources: [.init(accountID: "a", itemID: "1", providerKind: .jellyfin)])
        ]))
        let outbox = InMemoryWatchMutationStore()

        XCTAssertNotNil(ContinueWatchingLocalReset.runIfNeeded(
            profileID: "profile-1", homeStore: home, outbox: outbox, defaults: defaults
        ))
        XCTAssertNotNil(ContinueWatchingLocalReset.runIfNeeded(
            profileID: "profile-2", homeStore: home, outbox: outbox, defaults: defaults
        ))
        XCTAssertNil(ContinueWatchingLocalReset.runIfNeeded(
            profileID: "profile-2", homeStore: home, outbox: outbox, defaults: defaults
        ))
    }

    func testNoOpRunMarksTheProfileWithoutTouchingStores() {
        let home = InMemoryHomeContentStore(HomeViewModel.Content(continueWatching: [
            item("plex", sources: [.init(accountID: "b", itemID: "2", providerKind: .plex)])
        ]))
        let outbox = InMemoryWatchMutationStore()

        let summary = ContinueWatchingLocalReset.runIfNeeded(
            profileID: "profile-1", homeStore: home, outbox: outbox, defaults: defaults
        )

        XCTAssertEqual(summary, ContinueWatchingLocalReset.Summary())
        XCTAssertEqual(home.load()?.continueWatching.map(\.id), ["plex"])
    }

    // MARK: - Helpers

    private func item(_ id: String, sources: [MediaSourceRef]) -> MediaItem {
        var item = MediaItem(id: id, title: id, kind: .episode)
        item.sources = sources
        return item
    }

    private func target(_ accountID: String, _ kind: ProviderKind) -> WatchMutationTarget {
        WatchMutationTarget(accountID: accountID, itemID: "item-\(accountID)", providerKind: kind)
    }

    private func mutation(
        resumePosition: TimeInterval? = nil,
        played: Bool? = nil,
        clearResume: Bool = false,
        targets: [WatchMutationTarget]
    ) -> WatchMutation {
        WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            canonicalMediaID: "canonical",
            resumePosition: resumePosition,
            played: played,
            clearResume: clearResume,
            targets: targets
        )
    }
}

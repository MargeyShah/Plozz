import Foundation
import FeatureHomeCore

/// Deterministic driver for `ContentRefreshCoordinator` tests. The fake clock is
/// intentionally explicit so a test never depends on wall-clock timing.
@MainActor
public final class ContentRefreshHarness {
    public let coordinator: ContentRefreshCoordinator
    private let clock: TestClock

    public init(profile: ContentRefreshProfile = .tvOS) {
        let clock = TestClock()
        self.clock = clock
        self.coordinator = ContentRefreshCoordinator(profile: profile, now: { clock.now })
    }

    }
}

@MainActor
private final class TestClock {
}

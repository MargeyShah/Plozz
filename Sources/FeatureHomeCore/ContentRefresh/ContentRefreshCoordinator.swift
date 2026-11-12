import Foundation
import Observation

@MainActor
@Observable
public final class ContentRefreshCoordinator {
    public private(set) var request: ContentRefreshRequest?
    @ObservationIgnored private var generation: UInt64 = 0

    public init(
        profile: ContentRefreshProfile,
    ) {
        self.profile = profile
        self.now = now
    }

            reason: reason,
            generation: generation
        )
    }
}

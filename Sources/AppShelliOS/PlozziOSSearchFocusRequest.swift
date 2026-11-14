#if os(iOS)
import SwiftUI

/// How the shell asks the Search screen to take focus.
///
/// iOS/iPadOS only: pressing the Search tab must land the viewer in the search
/// field with the keyboard up, whether they arrive from another tab or press Search
/// again while already there. A counter rather than a Bool so **every** press is a
/// distinct request — a Bool would collapse a re-tap into "already true".
///
/// tvOS has no tab bar and no on-screen keyboard, so these values are unused there.
struct PlozziOSSearchFocusRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

/// Increments when the viewer pressed Search while the Search tab was already
/// selected, meaning "start a new search": the previous query is cleared rather
/// than left in place. Arriving from another tab keeps the query (the viewer may
/// be returning to their results) and only focuses the field.
struct PlozziOSSearchReplaceQueryRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var plozziOSSearchFocusRequest: Int {
        get { self[PlozziOSSearchFocusRequestKey.self] }
        set { self[PlozziOSSearchFocusRequestKey.self] = newValue }
    }

    var plozziOSSearchReplaceQueryRequest: Int {
        get { self[PlozziOSSearchReplaceQueryRequestKey.self] }
        set { self[PlozziOSSearchReplaceQueryRequestKey.self] = newValue }
    }
}
#endif

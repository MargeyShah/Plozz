import CoreModels
import CoreNetworking
import Foundation

/// Optional Jellyfin server plugins whose API Plozz can use when they are
/// installed.
///
/// A plugin is not part of the base server API, so every capability is probed
/// once per connection and the answer is cached. If a plugin is installed later,
/// reconnecting (or relaunching) picks it up; a missing plugin is never treated
/// as an error, only as "the server cannot express this".
struct JellyfinPluginSupport: Sendable, Equatable {
    /// `jellyfin-plugin-discontinue-watching` adds a per-user denylist plus
    /// `Override/UserItems/Resume` routes. Its denylist is the only server-side
    /// way to hide a title from Continue Watching **without losing its watch
    /// progress**; it also clears itself when the viewer starts the title again.
    var discontinueWatching = false

    static let none = JellyfinPluginSupport()

    var serverSideContinueWatchingRemoval: Bool { discontinueWatching }
}

/// Connection-scoped cache for ``JellyfinPluginSupport``. A reference type so
/// the value-semantics provider still shares one answer across copies.
final class JellyfinPluginSupportCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: JellyfinPluginSupport?

    func value() -> JellyfinPluginSupport? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ support: JellyfinPluginSupport) {
        lock.lock()
        defer { lock.unlock() }
        stored = support
    }
}

/// The `jellyfin-plugin-discontinue-watching` contract, as verified against the
/// plugin's `DiscontinueWatchingController`.
///
/// * `GET /DiscontinueWatching/Config` — present only when the plugin is
///   installed; used as the capability probe.
/// * `POST /DiscontinueWatching/Items/{itemId}` — add the title to the calling
///   user's denylist (server-side "remove from Continue Watching").
/// * `GET /DiscontinueWatching/items` — the current denylist.
///
/// The plugin's own `PlaybackStartConsumer` removes a title from the denylist
/// when the user plays it again, so re-watching needs no client bookkeeping.
struct DiscontinueWatchingConfig: Decodable {
    let EnableFrontendFiltering: Bool?
}


/// Next Up window from the server's display-preferences store. Cached per
/// connection; only the raw values are cached so the cutoff is recomputed for
/// each query instead of freezing at first read.
final class JellyfinNextUpPreferencesCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: JellyfinClient.NextUpPreferences?

    func value() -> JellyfinClient.NextUpPreferences? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ preferences: JellyfinClient.NextUpPreferences) {
        lock.lock()
        defer { lock.unlock() }
        stored = preferences
    }
}

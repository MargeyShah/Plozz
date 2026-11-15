# Networking consolidation plan

Status: design proposal. Branch `wip/home-flicker-fixes`, HEAD `3ab43c33d`.
No source is changed by this document. A separate inventory document owns the
call-site catalogue; this one covers architecture, mechanisms, migration and
acceptance.

## 0. What the evidence says (and what it rules out)

The 1:1 sideload comparison puts the branch aggregate **+299 ms** behind
release/072 (`docs/measurements/device-home-timing-1to1.md:49-57`), with
`recentlyAdded`/`libraries` **+333 ms** and `continueWatching` **+299 ms**.
The HTTP leg dominates each row; provider mapping and SwiftUI publication are
tens of milliseconds (`docs/measurements/device-http-timing.md:19-37`). The
branch publish gap is already ≤ 41 ms, so this is not a rendering or merge
problem.

Three facts in the current code narrow the client-side explanation:

1. **The rows that publish together regress together.** `libraries` and
   `recentlyAdded` have *identical* medians in the most recent captures
   (`device-home-timing-1to1.md:19-20`, `:38-39`) because
   `HomeAggregator` refuses to publish either until every account reports
   `librariesComplete` (`Sources/FeatureHomeCore/HomeAggregator.swift:636-640`).
   `libraries()` is not one request: after `/Views` it awaits
   `collectionDirectoryHasItems` **serially** for every collection-kind library
   (`Sources/ProviderJellyfin/JellyfinProvider.swift:96-129`). A single
   collection probe therefore lands directly on those two rows.
2. **The first frame starts same-host work that the rows do not need.**
   `warmHeroLogos` is attached to `displayHeroItems` with `.task(id:)`
   (`Sources/AppShelliOS/PlozziOSHomeView.swift:877-879`, body `:1112-1124`),
   and `loadHero` runs on a curation key derived from cached content
   (`:967-971`), before the live Home load completes. Hero metadata enrichment
   then runs identity resolution and a per-account library-target fan-out with a
   four-way concurrency cap (`Sources/FeatureHomeCore/HeroMetadataEnricher.swift:256-331`),
   wired to a resolver that searches every account with a 4 s deadline
   (`Sources/AppRuntime/CrossServerSourceResolverFactory.swift:84-164`).
3. **Those requests share one host budget with the rows.** All default-lane
   providers use `URLSession.plozzDefault` (`Sources/CoreNetworking/HTTPClient.swift:178-183`,
   `:397-409`), and `JellyfinClient` is one client with one `HTTPClient`
   (`Sources/ProviderJellyfin/JellyfinClient.swift:61-75`). The session asks for
   `httpMaximumConnectionsPerHost = 8` (`HTTPClient.swift:406`), which iOS caps
   at 6 for HTTP/1.1 and which does not raise stream concurrency for HTTP/2.
   `/Views`, Resume, NextUp, Latest and Watchlist are enqueued together
   (`HomeAggregator.swift:484-489`) with a 5-per-lane admission cap
   (`:529-549`), so four extra hero/search requests can displace row requests
   on the same six sockets.

This design fixes request **count**, request **priority** and request
**ownership** before considering any socket-count tuning. Raising the cap from
8 to 12 was already measured and changed nothing
(`docs/measurements/device-http-timing.md:50-51`), which is consistent with the
6-connection clamp and/or HTTP/2 multiplexing.

---

## 1. Target architecture

### 1.1 One transport, named `PlozzTransport`

`PlozzTransport` replaces `URLSessionHTTPClient` as the production transport and
absorbs the responsibilities currently spread across four wrappers:

| Responsibility | Today | Target |
| --- | --- | --- |
| Build the `URLRequest` | `URLSessionHTTPClient.makeRequest` (`HTTPClient.swift:315-334`) | `PlozzTransport` |
| Route to a reachable address | `ServerAddressResolver` + `ServerAddressHTTPClient` (`Sources/CoreNetworking/ServerAddressResolver.swift:163-220`) | `PlozzTransport` (one route owner) |
| Retry on another address | `ServerAddressHTTPClient` **and** `PlexClient.send` (`Sources/ProviderPlex/PlexClient.swift:303-324`) | `PlozzTransport` only |
| Coalesce identical in-flight reads | `JellyfinDiscoveryRequests` (`Sources/ProviderJellyfin/JellyfinDiscoveryRequests.swift:1-80`) | `PlozzTransport` + `RequestCoalescer` |
| TTL cache for immutable metadata | `JellyfinRecommendationRequests` only (`Sources/ProviderJellyfin/JellyfinRecommendationRequests.swift:20-122`) | `PlozzTransport` + `MetadataCache` |
| Auth headers | Rebuilt per endpoint (`JellyfinClient.swift:164-166`, `:193`, `:447-451`, `:533-546`) | One `TransportAuthorizer` per client |
| Error/status mapping | `URLSessionHTTPClient.send` + provider switches (`HTTPClient.swift:185-205`, `PlexClient.swift:326-421`) | One `TransportErrorMapper` |
| Logging | Ad-hoc debug lines (`HTTPClient.swift:233-234`, `:308-311`) | One ledger record per request |

`HTTPClient` stays as the test seam. `PlozzTransport` conforms to it, and
`URLSessionHTTPClient` becomes an internal primitive used only by the transport
and by tests. Providers keep accepting `HTTPClient` so existing fakes
(`Tests/TestSupportNetworking/RecordingHTTPClient.swift`) still work; they stop
constructing their own URLSession lanes.

The transport owns, per authenticated client:

- one `TransportScope` (provider, server id, user id, credential revision,
  origin),
- one `TransportAuthorizer` (credential injection + redaction rules),
- one `ServerAddressResolver` (route selection and failover),
- one `RequestCoalescer` and one `MetadataCache` (shared across all lanes so a
  coalesced flight cannot depend on which lane asked first),
- one `TransportLedger` sink.

### 1.2 Lanes and priority

Five lanes, each with its **own** `URLSession` (a pool per lane is deliberate:
it is what prevents an enrichment storm from queueing ahead of a row fetch —
the reason `plozzInteractive` exists at `HTTPClient.swift:411-429`).

| Lane | Traffic | Session cap / host | Request / resource timeout | Priority | May start before first Home row publishes? |
| --- | --- | ---: | --- | --- | --- |
| `interactive` | detail open (`item`/`metadata`), playback preparation, auth token exchange | 4 (was 6) | 10 s / 12 s | foreground | yes (user-blocking) |
| `browse` | Home rows, library pages, search, watchlist read | 6 (was 8) | 15 s / 20 s | foreground | yes |
| `background` | enrichment, series identity, collection probes, hero identity, cross-server discovery, silent refresh | 2 | 20 s / 30 s | enrichment | **no** |
| `artwork` | image bytes (posters, backdrops, logos) | 6 | 15 s / 30 s | foreground for visible, background for warm | visible art only |
| `discovery` | address/identity probes | 2 | 2.5 s / 3 s | speculative | only during sign-in/route recovery |

Priority is **admission**, not `TaskPriority`. Swift task priority does not order
URLSession's connection queue, and `URLSessionTask.priority` is unavailable
through the `data(for:)` convenience API. The transport therefore:

- admits every `interactive` and `browse` request immediately, up to the lane
  cap;
- admits `background` work only when the client's `BackgroundWorkGate` is open
  (closed until the first Home row publishes and while an interactive fetch is
  in flight);
- drops superseded speculative work before it reaches the network, reusing the
  generation pattern already proven by `EnrichmentScheduler`
  (`Sources/CoreNetworking/EnrichmentScheduler.swift:43-66`);
- never places a global serial queue in front of a lane. A single shared queue
  is exactly the head-of-line blocking that motivated the interactive pool.

Concretely, `interactive`/`browse`/`background` are **ordered**, not just
separated: a `background` request cannot be admitted while `foregroundActive > 0`
for the same host, unless it is already in flight. That keeps the hero warm and
enrichment from taking the last socket during the row fan-out.

### 1.3 Per-host connection budget

The budget is per **lane session**, because iOS applies
`httpMaximumConnectionsPerHost` per session:

| Host family | interactive | browse | background | artwork | discovery | Hard ceiling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Media server (Jellyfin/Emby/Plex) | 4 | 6 | 2 | 6 | 2 | 6 per lane; 14 non-artwork admitted; 20 total |
| plex.tv / metadata CDN | 2 | 3 | 2 | 6 | 1 | 6 per lane |

Rules:

- **Never set a lane above 6.** iOS clamps HTTP/1.1 to 6 per host; values above
  6 are either ignored or, under HTTP/2, create extra TCP/TLS connections that
  add server work without adding stream concurrency. Change
  `plozzDefault` from 8 to 6 (`HTTPClient.swift:406`).
- **Do not add a cross-lane semaphore by default.** A single per-host gate
  across all lanes reintroduces the queue this architecture is removing. Add a
  host-level admission cap only if a measured run shows the *server* saturating
  (see §2.5).
- **Record the negotiated protocol per host once** from
  `URLSessionTaskMetrics.networkProtocolName` and expose it in the ledger. The
  budget is only meaningful with that fact attached.
- **Keep tuner/playback requests out.** Plex Live TV session requests must not
  failover or retry (`PlexClient.swift:357-422`); they stay on their own path and
  are explicitly excluded from the generic retry policy.
- Artwork stays a separate lane with its existing bounded byte cache
  (`Sources/CoreUI/ArtworkSession.swift:46-80`); visible art may run in the
  foreground, but `warm` work must use the background gate
  (`ArtworkSession.swift:91-114`).

### 1.4 How providers build requests

Providers continue to describe requests with `Endpoint` (path, query, body,
redirect policy, byte cap). They stop adding auth headers and stop choosing a
URLSession. `Endpoint` gains additive fields with defaults, so existing call
sites compile unchanged:

```swift
public struct Endpoint: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var queryItems: [URLQueryItem]
    public var headers: [String: String]      // per-request extras only
    public var body: Data?
    public var redirectPolicy: RedirectPolicy
    public var allowsAutomaticAddressRetry: Bool
    public var reportsUndeliveredRequests: Bool
    public var redactsURLForLogging: Bool
    public var maximumResponseBytes: Int?
    public var reportsServerTrustFailures: Bool

    // New, additive:
    public var lane: TransportLane = .browse
    public var cache: CacheDirective = .noStore
    public var retry: RetryClass = .idempotentGet
    public var diagnosticsRoute: ResponseDecodingDiagnostic.Route?
}
```

A provider method becomes:

```swift
func seriesMetadata(userID: String, seriesIDs: [String]) async throws -> [BaseItemDto] {
    let query = [URLQueryItem(name: "IncludeItemTypes", value: "Series"),
                 URLQueryItem(name: "Ids", value: seriesIDs.joined(separator: ",")),
                 URLQueryItem(name: "Fields", value: "ProviderIds,DateLastSaved,LastPlayedDate")]
    // ...
    return try await transport.decode(
        ItemsResponse.self,
        request: TransportRequest(
            endpoint: Endpoint(path: "/Users/\(userID)/Items", queryItems: query,
                               lane: .browse, cache: .immutable(ttl: .minutes(10))),
            baseURL: baseURL
        )
    ).Items
}
```

What providers must **not** do any more:

- build `URLSession` instances (`JellyfinClient.swift:41-46`,
  `PlexClient.swift:229-295`),
- mutate `redirectPolicy` per call (`PlexClient.swift:308-309`,
  `JellyfinClient.swift:137`),
- map HTTP status to `AppError` themselves (`PlexClient.swift:336-346`,
  `:408-421`),
- retry on `serverUnreachable` themselves (`PlexClient.swift:316-323`),
- decode JSON directly (`PlexClient.swift:425-428`).

### 1.5 Auth and headers injected once

`TransportAuthorizer` is a value injected at client construction. It returns the
complete header set for the scope, and the transport merges
`authorizer.headers` then `endpoint.headers` (endpoint wins for
`Content-Type`, `Cache-Control`, `X-Plex-Session-Identifier`).

```swift
public protocol TransportAuthorizer: Sendable {
    var scope: TransportScope { get }
    var sensitiveHeaderNames: Set<String> { get }
    func headers(for endpoint: Endpoint) -> [String: String]
}
```

Jellyfin's implementation owns `JellyfinDeviceProfile.authorizationHeaderValue`
(`Sources/ProviderJellyfin/JellyfinDeviceProfile.swift:30-41`). Plex's owns
`PlexDeviceProfile.headers` and keeps the **discover** token distinct from the
server token (`Sources/ProviderPlex/PlexDeviceProfile.swift:81-96`,
`PlexClient.swift:164-179`) by exposing two authorizers, not by mutating a
shared header dictionary. Token refresh rebuilds the authorizer and keeps the
same transport, resolver, cache and latch — mirroring
`JellyfinClient.authenticated(token:)` (`JellyfinClient.swift:143-160`).

The transport is the only place allowed to read `Authorization` /
`X-Plex-Token`; it feeds `PlozzLog.redact(headers:)`
(`Sources/CoreNetworking/PlozzLog.swift:74-111`) before any diagnostic.

### 1.6 Cancellation and error mapping, unified

One mapper produces one public currency, `AppError`
(`Sources/CoreModels/AppError.swift:8-63`):

| Transport outcome | `AppError` |
| --- | --- |
| `CancellationError`, `URLError.cancelled`, task cancelled at admission | `.cancelled` (never a success-shaped default) |
| `.timedOut`, `.cannotConnectToHost`, `.cannotFindHost`, `.dnsLookupFailed`, `.networkConnectionLost`, `.secureConnectionFailed`, `.notConnectedToInternet` | `.serverUnreachable` (URL error code retained in diagnostics) |
| 401, 403 | `.unauthorized` |
| 404 | `.notFound` |
| 409 | `.conflict` |
| 429 | `.rateLimited(retryAfter:)` |
| 451 | `.accessRestricted` — **currently missing** from `HTTPClient.swift:188-204` even though the case exists (`AppError.swift:15-16`) |
| 408, 504 | `.serverUnreachable` |
| other 5xx | `.invalidResponse` (server answered; this is a bad answer, not a transport failure) |
| decode failure | `.decoding` |
| TLS trust rejection on an opted-in probe | `HTTPServerTrustFailure` (`HTTPClient.swift:32-35`, `:276-285`) |

Cancellation rules:

- Check cancellation **before** admission and **after** the response, so a
  cancelled row does not publish.
- A coalesced flight is shared; a follower's cancellation must not cancel the
  leader. The last follower leaving cancels the flight. `JellyfinDiscoveryRequests`
  already implements exactly this per-reader cancellation
  (`JellyfinDiscoveryRequests.swift:24-80`); promote it to `RequestCoalescer`.
- A cancelled request must never be reported as an empty array. Existing
  `HomeAggregator.fetch` already converts this correctly
  (`HomeAggregator.swift:1076-1085`); providers' ad-hoc re-mapping should be
  deleted, not duplicated.
- Route failover is retried **once, only** for an idempotent GET with
  `allowsAutomaticAddressRetry == true`, and never after an ambiguous mutation
  (`ServerAddressResolver.swift:195-210`). `PlexClient.send`'s second retry
  (`PlexClient.swift:316-323`) is removed; today the same GET can be replayed
  twice by two layers.

### 1.7 Swift API sketch

```swift
// CoreNetworking/TransportLane.swift
public enum TransportLane: String, Sendable, CaseIterable {
    case interactive, browse, background, artwork, discovery

    public var connectionLimit: Int {
        switch self {
        case .interactive: 4
        case .browse, .artwork: 6
        case .background: 2
        case .discovery: 2
        }
    }

    public var timeouts: (request: TimeInterval, resource: TimeInterval) {
        switch self {
        case .interactive: (10, 12)
        case .browse:      (15, 20)
        case .background:  (20, 30)
        case .artwork:     (15, 30)
        case .discovery:   (2.5, 3)
        }
    }

    public var mayRunBeforeFirstPaint: Bool {
        self == .interactive || self == .browse
    }
}

public enum CacheDirective: Sendable, Equatable {
    case noStore                      // mutations, user-mutable feeds
    case coalesceInFlight             // dedupe only; never retain a value
    case immutable(ttl: Duration)     // provider IDs, server info, item shape
    case revalidate(ttl: Duration)    // short-lived mutable metadata
}

public enum RetryClass: Sendable, Equatable {
    case none                         // playback prep, tuner, mutations
    case idempotentGet                // one alternate-address retry
}

public struct TransportRequest: Sendable {
    public var endpoint: Endpoint
    public var baseURL: URL
    public var lane: TransportLane { endpoint.lane }
    public var cache: CacheDirective { endpoint.cache }
    public var retry: RetryClass { endpoint.retry }
    public var timeout: Duration?
    public var trace: TransportTrace?
}

public struct TransportResponse: Sendable {
    public let data: Data
    public let http: HTTPURLResponse
    public let metrics: TransportMetrics   // protocol, ttfb, total, reusedConnection
    public let provenance: Provenance      // .fresh, .coalesced, .cache(age:)
}

public protocol PlozzTransportProtocol: HTTPClient {
    func send(_ request: TransportRequest) async throws -> TransportResponse
    func sendRaw(_ request: TransportRequest) async throws -> TransportResponse
    func decode<T: Decodable & Sendable>(
        _ type: T.Type, from request: TransportRequest, decoder: JSONDecoder
    ) async throws -> T
}

public struct PlozzTransport: PlozzTransportProtocol {
    public init(
        scope: TransportScope,
        authorizer: any TransportAuthorizer,
        resolver: ServerAddressResolver?,
        lanes: TransportLanes,             // the five URLSessions, built once
        coalescer: RequestCoalescer,
        cache: MetadataCache,
        ledger: TransportLedger
    )
}

public struct TransportScope: Hashable, Sendable {
    public let provider: ProviderKind
    public let serverID: String
    public let userID: String
    public let credentialRevision: CredentialRevision
    public let origin: String              // scheme://host:port, never credentials
}
```

`TransportLanes` is constructed once per app process and vended read-only, so
there is exactly one pool per lane. This replaces the `.plozzInteractive` client
being re-instantiated per provider (`Sources/AppRuntime/ManagedProviderRegistry.swift:56`,
`:65`, `:77`) with a shared lane value.

---

## 2. Efficiency mechanisms and tradeoffs

### 2.1 Request coalescing and dedup keys

`RequestCoalescer` is an actor holding `[RequestKey: Flight]`. It generalises
`JellyfinDiscoveryRequests` (`JellyfinDiscoveryRequests.swift:12-80`) and the
pending-inventory pattern in `LibraryQuerySession`
(`Sources/FeatureHomeCore/LibraryQuerySession.swift:269-311`).

```swift
struct RequestKey: Hashable, Sendable {
    let scope: TransportScope     // provider + server + user + credential revision + origin
    let method: HTTPMethod
    let path: String
    let query: [URLQueryItem]     // order-normalised
    let bodyDigest: SHA256Digest? // nil for GET
    let variant: String           // e.g. "includeUserData=false"
}
```

Rules:

- **Scope is part of the key.** Never coalesce two accounts, two profiles, or
  two credential revisions even when the URL is byte-identical. The existing
  `SeriesIdentities` cache is per account index
  (`HomeAggregator.swift:430-452`) and `LibraryInventoryStore` hashes the
  identity scope (`Sources/CoreModels/LibraryInventoryStore.swift:121-134`); keep
  that discipline.
- **Include task-local selectors that change the answer.** Jellyfin
  recommendations already key on `HomeRecommendationScope` revision
  (`JellyfinRecommendationRequests.swift:14-19`). Any endpoint whose response
  depends on `HomeRecommendationScope`, spoiler settings or profile policy must
  carry that revision in `variant` or opt out of coalescing.
- **Do not coalesce mutations or one-time exchanges.** Anything with
  `reportsUndeliveredRequests`, `redirectPolicy == .sameOrigin` mutations, or a
  non-GET method is excluded.
- **Do not coalesce across `.interactive` and `.browse`.** A detail open must not
  wait behind a Home row's request; the interactive lane's isolation is the
  point. Coalescing is within one lane plus the cache.
- Followers do not inherit the leader's `PerformanceDiagnostics.provider` or
  `HTTPResponseDiagnostics.$route` task-locals
  (`Sources/CoreNetworking/HTTPResponseDiagnostics.swift:22-30`). Only coalesce
  responses that are context-free; route-specific pages (`nextUp`, `resume`,
  `onDeck`) declare their route at the call site and are not shared.
- Tradeoff: coalescing changes cancellation semantics and can hide a slow
  leader from diagnostics. Mitigation: `TransportResponse.provenance` records
  `.coalesced` and the ledger names the leader's request id.

Expected wins: duplicate `/Views` on a reload, duplicate series identity batches
when Home and hero both resolve the same episodes, and hero/settings/search all
calling `libraries()` within one refresh window
(`PlozziOSHomeView.swift:4164`, `HomeContentPageLoader.swift:138`,
`HomeAggregator.swift:176`).

### 2.2 Bounded concurrency with priority: Home rows > hero warm > refresh

The Home fan-out already has useful bounds:

- 5 per account per lane (`HomeAggregator.swift:288`, `:529-549`),
- 1 for custom rows,
- 1 for recommendation catalogs (`HomeContentPageLoader.swift:34`, `:88-90`),
- 4 for `SeriesIdentities` fallback (`HomeAggregator.swift:1118-1123`),
- 4 for hero library targets (`HeroMetadataEnricher.swift:303-331`),
- 2 app-wide for detail enrichment (`EnrichmentScheduler.swift:25-39`).

What is missing is **ordering between row work and speculative work**. The
target policy:

1. `interactive` — always admitted. Never queued behind browse.
2. `browse` — all Home rows, admitted up to 6 per host. `/Views` and the global
   feeds enqueue first because they are the rows that publish first
   (`HomeAggregator.swift:484-489`).
3. `hero warm` — **not started** until the first Home row publishes. Then:
   front slide first, other slides one at a time at `.utility`
   (`PlozziOSHomeView.swift:1112-1124` already serialises), gated by
   `ArtworkSession.warmLimiter` (limit 4, `ArtworkSession.swift:100`).
4. `background refresh` — silent refresh only after the live load completes;
   `ContinueWatchingPolicy.refreshAfter` already gates staleness
   (`Sources/CoreModels/ContinueWatchingPolicy.swift:37-46`).
5. `speculative` (cross-server search, ratings) — lowest; cancelled by
   generation when the page changes.

Implementation: a `BackgroundWorkGate` value owned by the transport, opened by
`HomeViewModel` on first row publish and by the detail page on first paint, plus
the existing per-lane `ConcurrencyLimiter`. Do **not** implement this by
lowering `TaskPriority`: priority does not reorder URLSession admission, and a
low-priority task can still take a socket ahead of a high-priority one.

Tradeoff: Home rows get faster at the cost of hero polish arriving later. The
hero already has a deterministic first-paint seed from cached rows
(`PlozziOSHomeView.swift:1417-1441`), so deferring the *enrichment* does not
mean painting a skeleton; it means the slide appears from cached row content
and is refined when background work runs.

### 2.3 Coalesced metadata batching: series recency in one bounded task group

Today `continueWatching(limit:)` does:

1. `/Items/Resume` and `/Shows/NextUp` concurrently
   (`JellyfinProvider.swift:396-456`),
2. `/Users/{id}/Items?Ids=…` in batches of 50
   (`JellyfinClient.swift:520-558`),
3. then, for every series still missing a date, a **serial** loop of batches of
   four `/Users/{id}/Items?ParentId=…&IncludeItemTypes=Episode` requests
   (`JellyfinProvider.swift:512-545`).

For a 20-item Continue Watching row with 12 undated series that is up to 3
serial rounds, each waiting for 4 requests. Replace with:

- **Phase A (1 request):** the existing series batch with
  `Fields=ProviderIds,DateLastSaved,LastPlayedDate` and
  `EnableUserData=true`. Keep `Limit == batch.count`.
- **Phase B (1 request, bounded):** one
  `/Users/{id}/Items?Filters=IsPlayed&IncludeItemTypes=Episode&Recursive=true&SortBy=DatePlayed&SortOrder=Descending&Limit=min(500, max(50, seriesCount*8))`
  to derive `seriesID → max(DatePlayed)` locally. This replaces N per-series
  probes for the common case.
- **Phase C (bounded fallback):** only series still missing after A and B, at
  most 12, in **one** `withThrowingTaskGroup` with a `ConcurrencyLimiter(limit: 6)`
  on the `browse` or `background` lane. One round, no serial outer loop.
- **Short negative cache:** `seriesID → Date?` for 30-60 s, scoped to the
  account and user, coalesced in flight. A just-finished episode must not stay
  invisible for the whole TTL, so keep it short and invalidate on the watch
  mutation path (`HomeViewModel` already reacts to `.mediaItemDidMutate`,
  `Sources/FeatureHomeCore/HomeViewModel.swift:915-926`).
- **Budget:** never enrich more than `min(seriesCount, 15)` series for a rail;
  leave the remainder undated (the existing ordering already tolerates that,
  `JellyfinProvider.swift:339-357`).

Plex parity: `PlexProvider.seriesMetadataBestEffort` batches 50 rating keys but
still loops batches serially (`Sources/ProviderPlex/PlexProvider.swift:377-430`).
Apply the same bounded group and the same budget; Plex's `/library/metadata/{keys}`
already returns `lastViewedAt`, so Phase B is Jellyfin-only.

Tradeoff: the global played-episode pass can miss a series whose last play is
older than the bounded window. The fallback is the per-series probe; the
acceptance tests must cover "finished an episode, next-up card still sorts by
recency" (`JellyfinProvider.swift:246-255` documents that intent).

### 2.4 Immutable-metadata TTL cache, sized safely

The API lanes disable URLSession caching (`HTTPClient.swift:407`, `:426`), so a
shared response cache must be app-level. `MetadataCache` is memory-only by
default; the only disk-backed metadata stays in `LibraryInventoryStore`
(2 MiB cap, `LibraryInventoryStore.swift:23`, `:163-181`).

| Class | Examples | TTL | Max entries | Max bytes | Invalidate on |
| --- | --- | --- | ---: | ---: | --- |
| Server identity | `/System/Info/Public`, Plex `/identity` | 24 h | 16 | 256 KiB | server/user change |
| Library inventory | `/Users/{id}/Views` | 5 min | 32 | 512 KiB | library edit, scan, profile switch |
| Collection existence | `collectionDirectoryHasItems` | 5 min | 32 | 64 KiB | library edit |
| Series identity (no user data) | `seriesMetadata(includeUserData:false)` | 10 min | 256 | 4 MiB | server/user/credential change |
| Item metadata by id (no user data) | provider IDs, overview, taglines | 10 min | 512 | 8 MiB | explicit refresh, item mutation |
| Series recency (mutable) | `seriesID → lastPlayedAt` | 30-60 s | 128 | 256 KiB | watch mutation, playback end |
| Never cached | `Items/Resume`, `Shows/NextUp`, watchlist, playbackInfo, any mutation, any profile-scoped row | — | — | — | — |

Hard bounds: **16 MiB memory**, **1,024 entries**, LRU eviction, no single
response larger than 512 KiB. These are intentionally small next to the 64 MiB
artwork memory cache (`ArtworkSession.swift:34`) because metadata entries are
kilobytes, and a leak here would directly inflate the Home working set.

Key discipline mirrors §2.1, plus the response-shape variant
(`IncludeUserData`, `Fields`, `EnableImages`). Two requests that differ only in
`Fields` must not share a value; that is how a cached placeholder starts missing
taglines (`HeroMetadataEnricher` exists precisely to avoid that class of bug,
`Sources/FeatureHomeCore/HeroMetadataEnricher.swift:7-15`).

Use `DateLastSaved` as an optional validator for item metadata: add it to
`Fields`, store it with the entry, and treat a changed value as a miss. This is
cheap insurance against a library refresh changing a title under a TTL.

Tradeoff: any stale entry is a correctness bug in a user-visible row. The cache
therefore must never hold mutable rows, and every write path that mutates watch
state must bump a `cacheEpoch` that invalidates the mutable metadata class. A
cache hit must be visible in the ledger (`.cache(age:)`) so a future regression
can be attributed to it rather than guessed.

### 2.5 HTTP/2 versus HTTP/1.1 expectations

These are different systems and must not be tuned with one number:

- **HTTP/1.1** (plain `http://host:8096`, or a proxy that does not negotiate
  h2): 6 connections per host per session is the OS ceiling. `requests beyond 6`
  queue inside URLSession, and the 8 in `plozzDefault` is not real. The win is
  fewer requests and lane isolation, not more sockets.
- **HTTP/2** (HTTPS with ALPN, the common reverse-proxy setup): one connection
  multiplexes many streams. `httpMaximumConnectionsPerHost` stops being a
  throughput knob; extra connections add TCP/TLS handshakes and let the server
  schedule more parallel work, which can *increase* per-request latency on a
  small Jellyfin box. Keep 4-6 and measure `networkProtocolName`.
- **Unknown protocol is not a measurement.** Step 1 records the negotiated
  protocol once per host from task metrics and prints it in the ledger. Until
  then, no socket-cap conclusion is admissible.
- Do not disable HTTP/2 or force h1.1 to "get more connections"; that trades
  multiplexing for handshake and connection-pool cost on every launch.

---

## 3. Consistency rules

### 3.1 One timeout/retry policy per request class

| Class | Attempts | Address failover | Notes |
| --- | ---: | --- | --- |
| Authentication / token exchange | 1 | no | A replayed login can mint two sessions. |
| Interactive detail / playback prep | 1 | only if `allowsAutomaticAddressRetry` and the request cannot allocate server work | Playback-info GETs that can start a transcode must opt out. |
| Browse row / page | 2 | one alternate address on `.serverUnreachable` | Never retry a 4xx/5xx answer or a decode failure. |
| Background enrichment | 2 | one alternate address | Cancelled by generation before admission. |
| Discovery probe | 1 | parallel candidates, 300 ms LAN head start | Already implemented (`ServerAddressResolver.swift:125-157`). |
| Mutation | 1 | no | `HTTPRequestNotSentError` must survive (`HTTPClient.swift:24-30`). |
| Live TV tuner / session | 1 | **never** | A lost tune response may already hold a tuner (`PlexClient.swift:357-363`). |
| Artwork byte GET | 1 | no | URLCache absorbs repeats; retries create storms. |

No retry on 429: surface `.rateLimited(retryAfter:)` and let the caller decide.
No retry on decode failure. No retry that can duplicate a mutation.

### 3.2 One error taxonomy

`AppError` is the only error type crossing a provider boundary
(`Sources/CoreModels/AppError.swift:8-63`; enforced in principle by
`Sources/CoreModels/MediaProvider.swift:10-13`). Rules:

- Providers may add context but may not invent a parallel error enum for
  network failures.
- `AppError.isTransportFailure` stays the single predicate for "try later"
  decisions (`AppError.swift:55-63`); a timeout remains a transport failure even
  though it maps to `.serverUnreachable`.
- Cancellation is `.cancelled`, never `.notFound`, never `[]`.
- 451 maps to `.accessRestricted`; add it to the shared mapper and delete the
  duplicate switch in `PlexClient.liveTVGet` (`PlexClient.swift:336-346`).
- Multi-feed rows keep per-feed failure independence (the Continue Watching
  contract at `JellyfinProvider.swift:232-243`); the mapper must not turn one
  feed's failure into a row-wide failure.

### 3.3 One decode path, off the main actor

`PlozzTransport.decode` is `nonisolated` and performs the decode inside a child
task, so it runs on the cooperative pool even when the caller is `@MainActor`,
while still inheriting task-locals (`HTTPResponseDiagnostics`, search source)
and cancellation:

```swift
public func decode<T: Decodable & Sendable>(
    _ type: T.Type, from request: TransportRequest, decoder: JSONDecoder = .plozz
) async throws -> T {
    let response = try await send(request)
    let bytes = response.data
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try Task.checkCancellation()
            do { return try decoder.decode(T.self, from: bytes) }
            catch {
                HTTPResponseDiagnostics.recordDecodeFailure(error, data: bytes, response: response.http)
                throw AppError.decoding
            }
        }
        return try await group.next()!
    }
}
```

No provider calls `JSONDecoder().decode` directly (remove
`PlexClient.swift:425-428`). No global decode actor: serialising decode behind
I/O would recreate the same head-of-line problem. The decode diagnostic keeps
the existing bounded payload-shape contract
(`HTTPClient.swift:108-135`, `HTTPResponseDiagnostics.swift:77-94`).

### 3.4 One logging/diagnostics contract

Every transport attempt emits exactly one ledger record, independent of
`PlozzLog` verbosity:

```
PLZNET req id=7f2a scope=jellyfin/<hash> lane=browse route=home proto=h2
       ms=183 ttfb=141 bytes=18234 status=200 cache=fresh coalesced=0
```

```
PLZNET home requests=11 unique=11 duplicate=0 coalesced=3 cacheHits=2
       nextUp=1 views=1 resumePages=1 heroBeforeFirstRow=0
```

Rules:

- Emit only when `PLZNET_STDOUT=1` (or the existing diagnostics surface is
  enabled); silent in normal use.
- No URLs, query values, tokens, titles, item ids or bodies. Paths may appear
  only as closed route names already defined by
  `ResponseDecodingDiagnostic.Route`
  (`Sources/CoreModels/LibraryLoadDiagnostic.swift:5-13`).
- One record per real network request; `.coalesced` and `.cache` are reported on
  the follower without a second request line.
- Correlate with `PlozzLog.boot` (`HomeVM.load`, `HomeAgg.rowReady`,
  `HomeAgg.fanout`) and `FanoutDiagnostics` (`HOMESEED`, `HEROFRAME`)
  exactly as documented in `docs/agent-device-debugging.md:115-143`.
- Failures keep the existing bounded evidence
  (`HTTPResponseDiagnostics`, max 4 responses/4 paging failures, no raw payload)
  and add the request id, lane and provenance.
- Redaction is central: the transport calls `PlozzLog.redact(url:)` and
  `redact(headers:)`; a call site cannot log an unredacted URL because it no
  longer sees one (`HTTPClient.swift:233-234` is the only current guard).

### 3.5 Rules for what may run during first paint

"First paint" means: from the first body evaluation until the first Home row is
published. It is a **data** boundary (`hasCompletedLiveLoad` / first
`HomeAgg.rowReady`), never a timer.

| Work | Allowed before first row publish? | Why |
| --- | --- | --- |
| `/Views` + global Home feeds (Resume, NextUp, Latest, Watchlist) | yes | These are the rows. |
| Per-library rows after inventory | yes | They are user-visible rows. |
| Innovative/visible hero artwork for the front slide | yes, one slide | The hero is the first surface. |
| Hero logo warm for non-front slides | **no** | Pure speculation; competes for the same host (`PlozziOSHomeView.swift:877-879`). |
| Hero identity / library-target resolution | **no** | Cross-server search fan-out (`CrossServerSourceResolverFactory.swift:84-164`). |
| Ratings, taglines, external metadata | **no** | Enrichment after paint. |
| Collection existence probes | **no** (or parallel, never serial-gating) | They currently gate `libraries`/`recentlyAdded` (`JellyfinProvider.swift:113-127`). |
| Off-screen artwork prefetch | **no** | `ArtworkSession.warmLimiter` is still traffic. |
| Silent Home refresh | **no** | Must wait for the live load to finish. |
| Cross-server search / Related probing | **no** | Uses the same provider client. |

The gate must be lifted by the first row publish, not by a `Task.sleep`. This
follows the project rule that transient states are gated on data
(`docs/agent-device-debugging.md:34-36`).

---

## 4. Migration plan

Each step ships independently, keeps provider parity, and has a gate that can
fail. Steps 1-2 are deliberately small; step 1 changes no behavior at all.

### Step 1 — Network ledger + protocol probe (first, low risk, measurable)

**Affected:** `Sources/CoreNetworking/HTTPClient.swift`,
new `Sources/CoreNetworking/TransportLedger.swift`,
`Sources/CoreNetworking/HTTPResponseDiagnostics.swift` (route reuse),
`Sources/FeatureHomeCore/HomeAggregator.swift` (summary emission at fan-out end),
`Sources/CoreModels/FanoutDiagnostics.swift` (optional routing of the summary).

**What:** behind `PLZNET_STDOUT=1`, record one line per request (lane, route,
provider, protocol, ms, bytes, status, provenance) and a Home summary
(requests, unique, duplicates, coalesced, cache hits, NextUp/Views counts, hero
requests before first row). No cache, no coalescing, no cap changes, no retries
changed.

**Expected win:** none by itself; it makes every later delta attributable.
It also produces the HTTP/2-vs-h1.1 fact that §1.3 depends on.

**Risk:** low. Instrumentation only; the previous temporary HTTP line proved the
approach (`docs/measurements/device-http-timing.md:1-6`).

**Gate:** `swift test --filter CoreNetworkingTests`; `tools/arch-guard.py`;
one device run of both apps with `PLZNET_STDOUT=1` proving identical request
counts for identical workloads before any behavior change.

### Step 2 — Stop hero work competing with Home rows

**Affected:** `Sources/AppShelliOS/PlozziOSHomeView.swift` (`:877-879`,
`:967-971`, `:1112-1124`), `Sources/FeatureHome/HomeHeroView+Artwork.swift:210-230`,
`Sources/AppShelliOS/PlozziOSHeroViews.swift:2078`,
`Sources/FeatureHomeCore/HeroMetadataEnricher.swift:256-331`,
`Sources/AppRuntime/CrossServerSourceResolverFactory.swift:84-164`,
tvOS `Sources/FeatureHome/HomeView.swift` equivalent.

**What:** keep the cached-row hero seed; defer `warmHeroLogos` and
`HeroMetadataEnricher` until the first Home row publishes; move hero identity
work to the `background` lane; do not run `libraryTargetResolver` for items that
already have a validated local source (the existing guard at
`HeroMetadataEnricher.swift:298-302` already filters some, but the resolver still
runs for discovery-tagged slides). No new hero skeleton: the seed continues to
paint (`PlozziOSHomeView.swift:1417-1441`).

**Expected win:** the largest single win — removes 2-6 same-host requests from
the row window. Predicted 150-300 ms per affected row, aggregate −200-400 ms;
this is the hypothesis that matches the measured +150-330 ms per row.

**Risk:** medium. Hero polish can arrive later; a slide must not flash a styled
title after its logo resolves. The reveal gate in `PlozziOSHeroViews.swift`
(`:2060-2085`) already waits for the memo, so deferral changes *when* the
background work starts, not the reveal contract.

**Gate:** `PLZBOOT` row medians from `tools/device-timing-diff.py --runs 5`,
plus a simulator video/screenshot pass proving the first frame still has hero
content and no logo-swap flash. `PLZXFAN HOMESEED/HEROFRAME` must show a seed,
not an empty hero. Both platforms.

### Step 3 — Introduce `PlozzTransport` with lanes and the 6-connection cap

**Affected:** `Sources/CoreNetworking/HTTPClient.swift`,
new `TransportLane.swift` / `PlozzTransport.swift` / `TransportAuthorizer.swift`,
`Sources/CoreNetworking/ServerAddressResolver.swift` (move retry into transport),
`Sources/ProviderJellyfin/JellyfinClient.swift:61-87`, `:164-166`,
`Sources/ProviderPlex/PlexClient.swift:297-324`, `:425-428`,
`Sources/AppRuntime/ManagedProviderRegistry.swift:56-77`,
`Sources/AppShell/AppState.swift:1588-1611`,
`Sources/ProviderSilo/SiloClient.swift:33`, `ProviderSubsonic`, `ProviderIPTV`.

**What:** providers hold a `PlozzTransport` (still an `HTTPClient`), pass a lane
per endpoint, and no longer wrap with `ServerAddressHTTPClient` or retry
themselves. Set `plozzDefault` to 6 (from 8), `plozzInteractive` to 4 (from 6),
keep artwork at 6, add the background lane at 2. Auth headers move to the
authorizer. Delete the duplicate Plex retry. Keep `Endpoint` additive. Timeouts
keep their current per-lane values; retuning them is a separate measured change.

**Expected win:** removes the double GET after a transient failure, removes the
8-vs-6 mismatch, and gives hero/background work a lane that cannot queue ahead
of rows. Expected 20-80 ms on retry-heavy or contended runs; request count
unchanged on a healthy run (by design).

**Risk:** medium-high. Address failover, trust failures and one-time exchanges
have careful contracts (`Sources/CoreNetworking/README.md:82-102`).

**Gate:** `AlternateAddressHTTPIntegrationTests`,
`HTTPServerTrustFailureTests`, `HTTPRedirectPolicyTests`,
`HTTPRequestDeliveryEvidenceTests`, `ProviderPlexTests`, `ProviderJellyfinTests`;
`tools/test-fast.sh CoreNetworking ProviderJellyfin ProviderPlex`; device timing
must not regress from Step 2.

### Step 4 — Coalescing + immutable metadata cache

**Affected:** new `RequestCoalescer.swift`, `MetadataCache.swift`;
`JellyfinClient.userViews` (`:331-340`) and `seriesMetadata` (`:520-558`);
`Sources/ProviderPlex/PlexClient.swift` metadata/decode helpers;
`Sources/ProviderJellyfin/JellyfinRecommendationRequests.swift` (fold into the
shared cache, keep its scope key); `Sources/CoreModels/LibraryInventoryStore.swift`
(single-flight reuse); `HomeAggregator.SeriesIdentities` (`:430-452`).

**What:** `/Views` becomes coalesce + 5 min TTL; series identity becomes
coalesce + 10 min TTL; item metadata by id becomes coalesce + 10 min TTL.
`Resume`/`NextUp`/watchlist stay in-flight-only. Cache is 16 MiB / 1,024 entries.

**Expected win:** a second Home load within 5 minutes saves `/Views` and
collection probes; Home + hero + settings in one window save duplicate
libraries calls. Predicted 1-3 fewer requests on a reload and 100-350 ms on
`libraries`/`recentlyAdded` when the cache is warm. Cold launch unchanged.

**Risk:** medium. Stale library names or stale provider IDs. Invalidation must
cover profile switch, credential revision, address change, library edit and
watch mutation.

**Gate:** new cache tests (key includes scope/variant; TTL expiry; invalidation
on epoch bump; no mutable feed cached); `ProviderJellyfinTests` ordering tests;
a device run proving a library rename is reflected after the invalidation path
(manual, one case).

### Step 5 — Series recency: one bounded group, one pre-pass

**Affected:** `Sources/ProviderJellyfin/JellyfinProvider.swift:484-547`,
`Sources/ProviderJellyfin/JellyfinClient.swift:562-580`,
`Sources/ProviderPlex/PlexProvider.swift:377-430`.

**What:** Phase A/B/C from §2.3; remove the serial `stride(by: 4)` loop; add the
30-60 s negative cache; cap enrichment at 15 series. Plex gets the same bounded
group; only Jellyfin gets the global played-episode pre-pass.

**Expected win:** for rows with >4 undated series, removes ceil(N/4) serial
round-trips. Predicted 100-500 ms on `continueWatching` in exactly the case that
currently regresses by 299 ms; fewer requests when N is large.

**Risk:** medium. Ordering is user-visible: a just-finished show must still
outrank older resume items (`JellyfinProvider.swift:246-255`,
`:339-357`). The global pre-pass can miss series; the fallback must be covered
by tests.

**Gate:** `ProviderJellyfinTests` Continue Watching ordering fixtures (including
"finished an episode, next-up-only series"), `ProviderPlexTests` recency parity;
device `continueWatching` row timing; a fixture with 12 undated series proving
no serial rounds (ledger `resumePages`/`lastPlayed` counts).

### Step 6 — `libraries()`: parallel collection probes, no row gating

**Affected:** `Sources/ProviderJellyfin/JellyfinProvider.swift:95-129`,
`Sources/ProviderJellyfin/JellyfinDiscoveryRequests.swift`,
`Sources/CoreModels/LibraryInventoryStore.swift`,
`Sources/FeatureHomeCore/HomeContentPageLoader.swift:134-177`.

**What:** (a) probe collection existence with a bounded group (limit 3) instead
of serially; (b) cache `hasCollections` for 5 minutes; (c) preferred: publish
the `/Views` result first and fill `hasCollections` as a follow-up content
update so the tile can appear a beat later. (c) is the only step that needs a
product check because the Collections tile may appear after the first paint.

**Expected win (a+b):** removes one serial round-trip per collection library
from the `libraries`/`recentlyAdded` publish path. On the reference server that
is the most likely explanation for the +333 ms shared delta
(`device-home-timing-1to1.md:19-20`, `:38-39`);
predicted 150-350 ms on those two rows. (c) additionally removes the probe from
the critical path entirely.

**Risk:** low for (a+b); medium for (c) because it changes when the Collections
tile appears and requires a second content publication (the aggregator already
supports progressive publication at `HomeAggregator.swift:636-752`).

**Gate:** `ProviderJellyfinTests` library inventory; device timing for
`libraries` and `recentlyAdded`; for (c), a screenshot/video check that the tile
arrives without a layout jump.

### Step 7 — One error/retry/timeout mapper in the transport

**Affected:** `Sources/CoreNetworking/HTTPClient.swift:185-205`, `:336-348`,
new `TransportErrorMapper.swift`, `Sources/ProviderPlex/PlexClient.swift:326-421`,
`Sources/ProviderJellyfin/JellyfinProvider.swift:458-462`,
`Sources/CoreModels/AppError.swift` (only if a `.timedOut` case is approved;
otherwise no change).

**What:** status + URLError mapping lives once; add 451; align 5xx; remove
provider-local switches. Retry table from §3.1.

**Expected win:** fewer duplicate requests after transient failures, consistent
retry banner/copy, and no provider-specific divergence. Latency win only in
failure paths, but it makes the lane policy trustworthy.

**Risk:** medium. 503/504 semantics differ per endpoint (Live TV treats some as
`tunerUnavailable`, `PlexClient.swift:414-419`); those stay explicit endpoint
overrides and are documented as such.

**Gate:** new mapper unit tests for every status/error pair; existing redirect,
trust and alternate-address integration tests; a forced-offline run proving one
attempt, not two.

### Step 8 — Remove duplicated hero seed logic (last)

**Affected:** `Sources/AppShelliOS/PlozziOSHomeView.swift:310-330`, `:1417-1441`,
tvOS `Sources/FeatureHome/HomeView.swift` counterpart,
new `HeroSeed` helper in `Sources/FeatureHomeCore` (or `HeroLoadKeys.swift`).

**What:** one function computes the launch seed from `cachedHeroItems` →
cached rows → nil, with one configuration/disabled-key snapshot. Both platforms
call it.

**Expected win:** no runtime win; removes a three-way drift risk that has
already caused skeleton regressions (documented at
`PlozziOSHomeView.swift:1417-1431`).

**Risk:** low, but touch both shells.

**Gate:** existing `FeatureHomeCoreTests`/`FeatureHomeTests` hero fixtures; a
seed telemetry run (`HOMESEED`) on both platforms.

### Optional Step 9 — Bounded Home preview for unbounded rows (product sign-off)

**Affected:** `Sources/ProviderJellyfin/JellyfinClient.swift:342-359` (Resume
drains every page when `limit == .max`), `:404-420` (NextUp already bounded),
`Sources/CoreModels/HomeRowFeed.swift`, `HomeContentPageLoader`.

**What:** Home preview requests a bounded page (e.g. 200) and exposes `hasMore`
for browse; only the browse route drains the full feed. This is a contract
change to `MediaProvider.continueWatching(limit:)` semantics
(`Sources/CoreModels/MediaProvider.swift:44-47`).

**Expected win:** removes N-page drains on large resume histories. This is the
only step that can change request count by an unbounded amount, so measure it
before committing.

**Risk:** high. The complete resume row is deliberately persisted across
relaunch (`Sources/FeatureHomeCore/HomeViewModel.swift:238-241`). Do not ship
without explicit maintainer approval and a browse-path test.

---

## 5. Acceptance criteria

Reference workload: one Jellyfin account, same server/host/user as
`docs/measurements/device-http-timing.md`, iPhone 17 Pro Max, Release self-build,
5 runs, `tools/device-timing-diff.py`.

### 5.1 Timing

| Metric | Current (1:1) | Target | Fails if |
| --- | ---: | ---: | --- |
| Home aggregate delta vs release/072 | +299 ms | **≤ +75 ms** and ≤ 10% of the release median | > +100 ms |
| `recentlyAdded` ready delta | +333 ms | **≤ +100 ms** | > +125 ms |
| `libraries` ready delta | +333 ms | **≤ +100 ms** | > +125 ms |
| `watchlist` ready delta | +150 ms | **≤ +60 ms** | > +80 ms |
| `continueWatching` ready delta | +299 ms | **≤ +100 ms** | > +125 ms |
| Per-request HTTP leg delta, identical URL | +150-330 ms/row | **≤ 40 ms** | > 60 ms |
| Publish gap (`rowReady` → published content) | ≤ 41 ms | **≤ 50 ms** | > 60 ms |

If the residual is proven server-side (protocol is h2, one connection, server
queue saturated), record that evidence and do not claim a client fix. The target
is a client-side delta, not a promise about the server.

### 5.2 Request count

For a Home load with the same visible rows:

- **0 duplicate absolute URLs** within one load (excluding deliberate page
  continuations).
- `/Views` exactly **1 per account** (coalesced or cached).
- `/Shows/NextUp` exactly **1 per account** — never retried on a normal load
  (`JellyfinProvider.swift:368-392` must not fire without an inconsistent page).
- `/Items/Resume` **1 page** for a typical history; ≤ 2 when >100 in progress.
- Series metadata ≤ **1 request per 50 series**.
- Per-series `lastPlayedEpisode` **0** in the common case; ≤ 12 and in one
  bounded round in the fallback case.
- Total JSON GETs ≤ `visibleRows + 3` per account on the reference workload.
- On a second Home load within 5 minutes: `/Views` **0** network requests
  (cache hit).

### 5.3 Priority / first paint

- `PLZNET` hero summary: **0** provider requests from hero identity/logo warm
  before the first `HomeAgg.rowReady`.
- Hero logo warm starts only after the first row publishes; verified by
  timestamps in one capture.
- No `background`-lane request is admitted while an `interactive` request is
  active for the same host (ledger can assert `backgroundAdmittedDuringInteractive=0`).
- The first frame still shows seeded hero content (`HOMESEED` count > 0, no
  skeleton) on both platforms.

### 5.4 Consistency

- All provider requests carry exactly one lane; the ledger shows no
  `lane=unknown`.
- One error taxonomy: a forced 451 produces `.accessRestricted`; a forced
  timeout produces `.serverUnreachable` with a URL error code; a cancelled row
  produces `.cancelled` and does not publish.
- Exactly one decode path: no `JSONDecoder` call outside `PlozzTransport`
  (arch guard rule).
- Cache never returns a value for `Resume`, `NextUp`, watchlist, playbackInfo or
  a mutation (unit test asserts `noStore` for those endpoints).
- Jellyfin/Emby and Plex both pass their provider suites; any intentional
  capability difference is documented in `Sources/ProviderPlex/README.md` or
  `Sources/ProviderJellyfin/README.md`, not silent.

### 5.5 How to verify with existing tools

1. **Device A/B timing:** run
   `python3 tools/device-timing-diff.py --device <UDID> --runs 5 --output docs/measurements/device-home-timing-consolidation.md`.
   Launch both apps with `PLZBOOT_STDOUT=1`; the script parses
   `HomeVM.load START`, `HomeAgg.fanout`, `HomeAgg.rowReady`,
   `HomeAgg.request` (`tools/device-timing-diff.py:25-40`).
2. **Per-request truth:** launch with `PLZNET_STDOUT=1` (new) and
   `PLOZZ_LOG_STDOUT=1`; parse the `PLZNET` lines for lane, protocol, ms, bytes,
   provenance and the Home summary. This replaces the temporary HTTP line
   described at `docs/measurements/device-http-timing.md:1-6`.
3. **Hero first-paint truth:** `PLZXFAN_STDOUT=1`; check `HOMESEED`,
   `HEROFRAME`, `HOMECAROUSEL`, `HOMECW` (`docs/agent-device-debugging.md:140-148`).
4. **Simulator workload:** run
   `python3 tools/performance.py run --platform iOS --sim-id <UDID> --scenario home-jellyfin-live`
   (authorized broker only, `docs/performance-lab.md:55-96`) for request counts,
   duplicates and first-row timing; this is not first-pixel timing.
5. **Correctness:** run
   `tools/test-fast.sh CoreNetworking ProviderJellyfin ProviderPlex`; full matrix
   before merge; `tools/arch-guard.py` for layering.
6. **Physical-device row navigation:** `tools/run-physical-home-rows-first.sh`
   only with the documented opt-in; it is a navigation/hitch lane, not a
   substitute for the Home aggregate measurement.

Report simulator evidence and physical-device evidence separately, and say
"not run" for any lane that was skipped.

---

## 6. What NOT to do

1. **Do not add a global serial queue or one app-wide semaphore for all HTTP.**
   That is the head-of-line blocking that `plozzInteractive` was created to
   escape (`HTTPClient.swift:411-420`) and that `EnrichmentScheduler` documents
   as a cooperative-pool failure mode (`EnrichmentScheduler.swift:3-17`).
2. **Do not raise `httpMaximumConnectionsPerHost` above 6** expecting more
   sockets on HTTP/1.1 (the OS clamps at 6), or expecting more concurrency on
   HTTP/2 (streams, not connections). The 8→12 experiment already showed no
   change (`docs/measurements/device-http-timing.md:50-51`).
3. **Do not cache user-specific mutable rows** (`Items/Resume`, `Shows/NextUp`,
   watchlist, playbackInfo, watch state) without a TTL shorter than the
   mutation-to-refresh window *and* an explicit invalidation path. A cached
   Continue Watching row that hides a just-finished episode is a worse bug than
   a slow row.
4. **Do not coalesce or cache across accounts, profiles or credential
   revisions**, even when the URL and body are identical. Provider-local ids
   collide across servers; profile-scoped rows must never leak.
5. **Do not break provider parity.** Every transport, cache or retry change
   lands for Jellyfin/Emby and Plex, or is documented as an intentional
   capability difference in the provider README. Silently dropping Plex support
   is a regression (`Sources/ProviderPlex/README.md:45-46`).
6. **Do not move decoding onto a global actor** or onto the MainActor. A decode
   actor serialises JSON behind network I/O; MainActor decode reintroduces the
   layout stall this design is removing.
7. **Do not change retry semantics for mutations or Live TV tuner sessions.**
   A replayed one-time exchange or tune can mint two sessions or take two
   tuners (`Sources/CoreNetworking/README.md:92-97`,
   `PlexClient.swift:357-363`).
8. **Do not gate hero or UI states on timers.** Gate on `hasCompletedLiveLoad`
   or the first `rowReady` (`docs/agent-device-debugging.md:34-36`).
9. **Do not add retry-on-429 or retry-on-5xx storms.** Respect
   `.rateLimited(retryAfter:)` and let the caller decide.
10. **Do not log URLs, query values, headers, tokens or item titles** in the new
    ledger. Route names, counts, bytes, status and timings only.
11. **Do not introduce a third-party HTTP stack.** URLSession remains the only
    transport; the design is about ownership and admission, not a new library.
12. **Do not remove `ServerAddressResolver`'s approved-route failover** or its
    proof that a mutation was not transmitted. It is a correctness boundary,
    not an optimisation.
13. **Do not "fix" the branch by reverting the shared-session change**
    (`static var` → `static let` in `HTTPClient.swift:397-442`) as a first move.
    A single provider already used one session per lane before that change; the
    regression is better explained by added same-host work, and a revert would
    leak a new pool per client access.
14. **Do not change `MediaProvider.continueWatching(limit: .max)` semantics**
    as part of a performance step. That is Optional Step 9 and needs product
    approval.

---

## 7. Top five recommendations

1. **Defer hero logo warm and hero identity resolution until the first Home row
   publishes, and run them on the background lane.** Highest expected impact:
   removes the extra same-host requests from the row window. Expected
   **150-300 ms per affected row; −200-400 ms aggregate**. Files:
   `Sources/AppShelliOS/PlozziOSHomeView.swift:877-879`, `:967-971`,
   `:1112-1124`; `Sources/FeatureHomeCore/HeroMetadataEnricher.swift:296-331`;
   `Sources/AppRuntime/CrossServerSourceResolverFactory.swift:84-164`.
2. **Stop the serial collection probe from gating `libraries` and
   `recentlyAdded`.** Probe in parallel (cap 3), cache `hasCollections` for
   5 minutes, and publish the inventory before the probe. Expected
   **150-350 ms on both rows**, which currently share an identical ready time.
   File: `Sources/ProviderJellyfin/JellyfinProvider.swift:95-129`.
3. **Collapse series recency into one bounded batch plus one global
   played-episode pre-pass.** Removes the serial batches of four. Expected
   **100-500 ms on `continueWatching`** when a row has more than four undated
   series. Files: `Sources/ProviderJellyfin/JellyfinProvider.swift:484-547`;
   `Sources/ProviderJellyfin/JellyfinClient.swift:562-580`; Plex parity at
   `Sources/ProviderPlex/PlexProvider.swift:377-430`.
4. **Ship the transport ledger first, then introduce `PlozzTransport` with five
   lanes, a single authorizer, a single error mapper and the 6-connection cap.**
   Gives every later change a measurable baseline and removes the double GET
   retry. Expected **20-80 ms** on contended/failure runs and no regression on
   the healthy path; enables the later cache/coalescing wins. Files:
   `Sources/CoreNetworking/HTTPClient.swift:185-205`, `:397-442`;
   `Sources/CoreNetworking/ServerAddressResolver.swift:163-220`;
   `Sources/ProviderPlex/PlexClient.swift:303-324`, `:425-428`.
5. **Add duplicate-free coalescing and a small immutable-metadata TTL cache
   for `/Views`, series identity and item identity.** Expected **1-3 fewer
   requests per reload** and **100-350 ms** on `libraries`/`recentlyAdded` when
   warm, with zero duplicate URLs per load. Files:
   `Sources/ProviderJellyfin/JellyfinClient.swift:331-340`, `:520-558`;
   `Sources/ProviderJellyfin/JellyfinDiscoveryRequests.swift:1-80`;
   `Sources/CoreModels/LibraryInventoryStore.swift:52-72`.

Recommended order: 1 (ledger) → 2 (defer hero) → 3 (collection probes) →
4 (series recency) → 5 (transport/cache). Steps 2 and 3 are the fastest
measurable wins; the transport is the structural fix that prevents the same
class of regression from returning.

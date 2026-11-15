# Networking inventory

**Status:** descriptive inventory of the code as it exists. No proposals here.
**Repository:** `Plozz`, branch `wip/home-flicker-fixes`, HEAD `3ab43c33d`.
**Scope:** every app-owned HTTP path: transport sessions, request construction,
per-call execution semantics, caching/dedup, concurrency and the Home-load call
graph.

**Evidence rules used below**

- Every claim carries a `file:line` citation unless it is explicitly marked
  **unverified**.
- "Measured" means a number from `docs/measurements/*` or a log line the code
  emits. "Read from code" means derived by reading control flow; request counts
  read from code are *expected*, not observed.
- The codebase's own claim that `URLSession` pools ("lanes") are per-session is
  relied on throughout `HTTPClient.swift`, but Apple does not document it as a
  guarantee — see §8.

---

## 1. Transport layer

### 1.1 Lanes

"Lane" = one `URLSession` instance, i.e. one connection pool, one cache, one
timeout budget.

| # | Lane | Configuration | Created at | Used by |
| -: | --- | --- | --- | --- |
| 1 | `URLSession.plozzDefault` | `.default`; request 15 s, resource 20 s; 8 conns/host; `reloadIgnoringLocalCacheData`; `waitsForConnectivity` left at default | `Sources/CoreNetworking/HTTPClient.swift:397-409` | The **default argument** of `URLSessionHTTPClient.init` (`HTTPClient.swift:181`), i.e. every provider/feature client that does not pass a session: Jellyfin/Plex/Silo REST (`ProviderJellyfin/JellyfinClient.swift:41`, `ProviderPlex/PlexClient.swift:236,275`, `ProviderSilo/SiloProvider.swift:22`), trackers (Trakt `TraktService.swift:65,418`, MAL `MALService.swift:43,344`, AniList `AniListService.swift:46,260`, Simkl, Wetrakr, Last.fm), Seer (`SeerService/SeerService.swift:71,825`), `AnimeIDMapper.swift:47`, `ServerValidator.swift:21`, `ServerNameRefresher.swift:26`, `QuickConnectService.swift:32`, `PasswordSignInService.swift:22`, `PlexAuthClient.swift:50`, discovery validators |
| 2 | `URLSession.plozzInteractive` | `.default`; request 10 s, resource 12 s; 6 conns/host; `reloadIgnoringLocalCacheData`; `waitsForConnectivity = false` | `HTTPClient.swift:421-429` | Only the user-blocking detail/playback-inventory fetch: Jellyfin `item()` (`JellyfinClient.swift:729-750`) and `playbackSourceInventory()` (`JellyfinClient.swift:1177-1197`); Plex `metadata()`, `mediaSegments()` (markers) and remote-subtitle search (`PlexClient.swift:589,607,634`). Injected at `AppRuntime/ManagedProviderRegistry.swift:56,65,77` and `AppShell/AppState.swift:1588,1597,1611` |
| 3 | `URLSession.plozzDiscovery` | `.ephemeral`; request 2.5 s, resource 3 s; `reloadIgnoringLocalCacheData`; `waitsForConnectivity = false`; `allowsConstrainedNetworkAccess = true` | `HTTPClient.swift:434-442` | Address probes only: `JellyfinClient.verifyAddress` (`JellyfinClient.swift:131-141`), `JellyfinClient/Provider` `addressProbe` defaults (`:46`, `JellyfinProvider.swift:47`), `PlexConnectionResolver.swift:82`, `PlexAuthClient.swift:51`, `PlexProvider.swift:39,66`, `ServerValidator.manualHTTP` (`ServerValidator.swift:22`), `ServerAddressesModel.swift:25`, `UDPServerDiscovery.swift:47`, `SeerDiscovery.swift:52`, `SiloProvider.swift:24` |
| 4 | `OfflineNetworkSession.shared` | `URLSessionConfiguration.default` **with no Plozz tuning**: inherited ≈60 s request timeout, default 6 conns/host, `URLCache.shared`, protocol-cache policy | `CoreNetworking/OfflineNetworkSession.swift:13` | Direct `data(for:)`/`data(from:)` users that bypass `HTTPClient`: `FeaturePlayback/SubtitleOverlayLoader.swift:43`, `MetadataKit/RelatedTitlesProvider.swift:117,223`, `AppRuntime/AnimeIDBridgeStore.swift:135`, `CoreUI/TMDbArtworkResolver.swift:236` (non-UIKit only), `AppShelliOS/PlozziOSAppModel.swift:4032,4092` (Plex download-queue API), `AppShelliOS/PlozziOSBackgroundHTTPDownloadEngine.swift:351,1450` |
| 5 | `ArtworkSession.shared` | `.default`; request 15 s, resource 30 s; 6 conns/host; **own** `URLCache` 64 MB memory / 384 MB disk at `plozz-artwork`; `returnCacheDataElseLoad` | `CoreUI/ArtworkSession.swift:34-37,46-60,62-80` | All artwork **bytes** via `ArtworkImageCache.downloadData` (`CoreUI/ArtworkImageCache.swift:1092-1098`), hero logo/preview warming (`FeatureHome/HomeHeroView+Artwork.swift:70,131,184,220`), detail extras logos (`FeatureHome/DetailExtrasView.swift:375`), `CoreUI/HeroLogoArtwork.swift:1113`. URLs with the `AuthenticatedArtworkReference` scheme are routed to `ArtworkSession.authenticatedLoader` instead (`ArtworkSession.swift:23-32`, installed at `AppRuntime/AccountsProvidersModel.swift:120-140`) |
| 6 | `TMDbArtworkResolver.metadataSession` | `.default`; request 12 s, resource 20 s; 6 conns/host; default cache policy | `CoreUI/TMDbArtworkResolver.swift:76-82` | TMDb **JSON** for `TMDbArtworkResolver` only; currently one production caller: company logos in the detail studios strip (`FeatureHome/DetailExtrasView.swift:305`) |
| 7 | `MetadataHTTP.session` | `.default`; request 12 s, resource 20 s; `useProtocolCachePolicy` | `MetadataKit/MetadataHTTP.swift:17-25` | All keyless public-metadata traffic: Wikipedia/Wikidata/TVmaze/TVDB/MusicBrainz/Deezer, AniList artwork+ID resolution, `MetadataDiscoveryHTTPClient` (`MetadataKit/MetadataDiscoveryHTTPClient.swift:22`) |
| 8 | `ProviderIconLoader.iconSession` | `.ephemeral`; 4 s / 6 s; 2 conns/host; no cookies/credentials; memory-only 4 MB `URLCache` | `CoreNetworking/ProviderIconLoader.swift:43-53` | Provider favicon probes only |
| 9 | `SubtitleFileLoader.subtitleSession` / `.extractionSession` | `.ephemeral`; no cache/cookies/credentials; resource 60 s / 120 s, request 30 s / 120 s | `CoreNetworking/SubtitleFileLoader.swift:8-18,61-72` | Sidecar download, embedded-track extraction |
| 10 | `StreamingMediaPlaylist.client` | `.ephemeral`; 5 s / 5 s; no cookies/credentials, via `URLSessionHTTPClient` | `FeaturePlayback/StreamingMediaPlaylist.swift:7-14` | Single-rendition HLS master probe |
| 11 | `SubsonicProvider.defaultHTTP` | `.ephemeral`; `urlCache = nil`; 15 s / 30 s | `ProviderSubsonic/SubsonicProvider.swift:16-22` | All Subsonic REST + authenticated artwork (`SubsonicProvider.swift:254`) |
| 12 | `PublicMetaDBClient.transportSession` | `.ephemeral`; no cookies/credentials/cache; 20 s / 40 s; 2 conns/host; **not** created via `OfflineNetworkSession` | `PublicMetaDBService/PublicMetaDBClient.swift:40-50` | PublicMetaDB API (watchlist/history/playback reporting) |
| 13 | `PublicMetaDBBrowserPairing` inline session | `.ephemeral`; no cookies/credentials/cache; 20 s / 40 s; **not** via `OfflineNetworkSession`; one per pairing instance | `PublicMetaDBService/PublicMetaDBBrowserPairing.swift:107-118` | `plozz.app` pairing poll |
| 14 | `IPTVHTTP` (one per `IPTVClient`) | `.ephemeral`; no cache/cookies/credentials; 45 s / configurable resource (default 1800 s); redirect delegate; invalidated on `cancel()` | `ProviderIPTV/IPTVHTTP.swift:17-31,33-50`; constructed at `ProviderIPTV/IPTVClient.swift:60`, `IPTVPlaybackProxy.swift:52` | IPTV playlist, guide, stream bytes |
| 15 | `LiveTVSourceLoader` (one per loader) | `.ephemeral`; no cache/cookies; 30 s / 600 s; redirect delegate | `FeatureLiveTVCore/LiveTVSourceLoader.swift:30-40` | Playlist + XMLTV download |
| 16 | `LiveTVScanURLSessionTransport` | `.ephemeral`; no cache/cookies; request timeout from `LiveTVChannelScanLimits`; `httpMaximumConnectionsPerHost = limits.requestsPerHost`; own permit gate | `FeatureLiveTVCore/LiveTVChannelScanTransport.swift:156-168` | Channel-scan probes |
| 17 | `PlozzigenLiveSourceProbe` | `.ephemeral`; no cache/cookies; 15 s / 15 s | `EnginePlozzigen/PlozzigenLiveSourceProbe.swift:24-36` | Live-source reachability probe |
| 18 | `HDR10PlusHTTPRangeSource` | `.ephemeral`; no cache/cookies; `1` conn/host; budget-derived timeouts; delegate queue | `EnginePlozzigen/HDR10PlusHTTPRangeSource.swift:30-51` | HDR10+ range reads |
| 19 | `LiveHLSScrubThumbnails` | `.ephemeral`; **shares AVPlayer's cookie store**; no URL cache; 8 s / 12 s; 2 conns/host | `EnginePlozzigen/LiveHLSScrubThumbnails.swift:60-83` | Live scrub thumbnails |
| 20 | `TransportSessionRegistry` sessions (WebDAV/HTTP shares) | `.ephemeral`; `reloadIgnoringLocalAndRemoteCacheData`; no cookies/credentials; 6 conns/host; one per `TransportSessionKey` (account+credential revision+origin+trust revision+role) | `MediaTransportHTTP/TransportSessionRegistry.swift:186-192,281-320` | All managed HTTP share reads |
| 21 | `MediaShareRouteDetector.WebDAVReachabilityProbe` | `.ephemeral`; 6 s; **one session per probe**, `invalidateAndCancel()` in the completion | `AppShell/MediaShareRouteDetector.swift:324-341` | WebDAV route detection |
| 22 | `MediaSharePortSweeper.confirmsWebDAV` | `.ephemeral`; probe timeout; **one session per probe**, invalidated via `defer` | `ProviderShare/MediaSharePortSweeper.swift:263-294` | Port-sweep WebDAV confirmation |
| 23 | `PlozziOSBackgroundHTTPDownloadEngine` | `.background(withIdentifier:)`; `sessionSendsLaunchEvents`, non-discretionary | `AppShelliOS/PlozziOSBackgroundHTTPDownloadEngine.swift:1076-1093` | Offline downloads (iOS only) |

Cross-cutting: every session except lanes 12, 13, 21 and 23 is created through
`OfflineNetworkSession.make` (`OfflineNetworkSession.swift:15-30`), which prepends
`OfflineURLProtocol` to `protocolClasses` when the configuration has **no**
identifier (`:20-23`).

Naming note: there is no `OfflineURLSession` type in the tree (`rg OfflineURLSession`
→ no matches). The offline machinery is `OfflineNetworkSession` (the factory and
session registry) plus the private `OfflineURLProtocol`
(`OfflineNetworkSession.swift:6-52`), and the policy itself is `OfflineMode`
(`CoreModels/OfflineMode.swift:5-33`).

### 1.2 Lane lifetime and creation sites

- Lanes 1–3 are `static let` singletons on `URLSession` — created once per process
  (`HTTPClient.swift:397,421,434`).
- Lanes 4–11 are `static let` singletons in their owning type.
- Lanes 14–19 and 23 are created **per owning object** (per IPTV account, per live
  source loader, per probe, per download engine) and `invalidateAndCancel()` in
  `deinit`/`cancel()`. Consequence: each IPTV account and each live-source loader
  carries its own pool, so two accounts on the same tuner host do not share a
  connection budget.
- Lane 20 is cached per `TransportSessionKey` (`TransportSessionRegistry.swift:211-235`).
- `OfflineNetworkSession` keeps a weak registry of every session it created so
  offline-mode transitions can cancel all tasks (`OfflineNetworkSession.swift:12,25-37`,
  driven from `AppShelliOS/PlozziOSAppModel.swift:1155`).

### 1.3 Per-request sessions that still exist

| Site | Granularity | Note |
| --- | --- | --- |
| `AppShell/MediaShareRouteDetector.swift:327-339` | **one `URLSession` per WebDAV probe** | Not routed through `OfflineNetworkSession`, so it is not offline-gated and not cancellable by `OfflineNetworkSession.cancelRequests()` |
| `ProviderShare/MediaSharePortSweeper.swift:271-282` | one session per port probe (WebDAV confirmation) | Created via `OfflineNetworkSession.make`, invalidated in `defer` |
| `PublicMetaDBService/PublicMetaDBBrowserPairing.swift:107-118` | one session per pairing object | Not offline-gated |

No HTTP request inside `URLSessionHTTPClient` or any `MediaProvider` constructs a
session per request.

### 1.4 Offline gating

Two independent mechanisms, and their coverage differs:

1. `HTTPClient`-based calls: `URLSessionHTTPClient.sendRaw` calls
   `OfflineMode.shared.requireNetworkAccess()` before building the request
   (`HTTPClient.swift:211`). This throws `OfflineModeError.networkUnavailable`
   (`CoreModels/OfflineMode.swift:21-31`), which is **not** an `AppError` and is
   thrown before the `do/catch` that maps errors.
2. `OfflineURLProtocol` returns `networkUnavailable` for any `http(s)` request made
   on a Plozz-owned session while offline mode is on
   (`OfflineNetworkSession.swift:40-51`).

Not gated: lanes 12, 13, 21 (sessions built directly), and **all** byte traffic that
uses `AVFoundation`/Plozzigen rather than these sessions.

### 1.5 Redirect handling

| Policy | Implementation | Who uses it |
| --- | --- | --- |
| `.follow` (default) | `HTTPDeliveryTaskDelegate` only (metrics/body accounting) (`HTTPClient.swift:63-89,243-245`) | Most provider GETs |
| `.sameOrigin` | `SameOriginHTTPRedirectDelegate` — blocks any redirect whose scheme/host/port differs or whose URL carries userinfo (`HTTPClient.swift:362-392`) | Forced on every `ServerAddressHTTPClient` request (`ServerAddressResolver.swift:182`); also `ProviderPlex/PlexClient.swift:309`, `JellyfinClient.verifyAddress` (`JellyfinClient.swift:137`), MdbList ratings (`JellyfinClient.swift:757`), `SubsonicProvider.artworkData` (`SubsonicProvider.swift:264`) |
| `.doNotFollow` | `NoHTTPRedirectDelegate` returns the original response (`HTTPClient.swift:351-357`) | Trakt/Simkl history export (`TraktService/TraktHistoryExport.swift:460`, `SimklService/SimklHistoryExport.swift:45`) |
| Session-level delegates (not `Endpoint`) | IPTV (`IPTVRedirects`) and LiveTV (`LiveTVSourceRedirectPolicy`) attach a delegate to their own session; subtitle/icon sessions refuse every redirect | `ProviderIPTV/IPTVHTTP.swift:29-30,68-70`; `FeatureLiveTVCore/LiveTVSourceLoader.swift:13,39`; `SubtitleFileLoader.swift:75-91`; `ProviderIconLoader.swift:56-75` |

`ServerAddressHTTPClient` **overwrites** `endpoint.redirectPolicy` with `.sameOrigin`
on every request (`ServerAddressResolver.swift:181-182`), so a Jellyfin/Plex
endpoint that asked for `.follow` or `.doNotFollow` gets `.sameOrigin` whenever an
address resolver exists (i.e. whenever `serverID != nil`, `JellyfinClient.swift:52-60`).

### 1.6 Diagnostics, `requestLabel`, capture hooks

- `requestLabel` is a local in `sendRaw`: `endpoint.redactsURLForLogging ? "<private>"
  : PlozzLog.redact(url:)` (`HTTPClient.swift:233`). It is used for the `→`/`←`
  debug pair (`:234`, `:308-311`) and nowhere else.
- Redaction: header allowlist/denylist in `PlozzLog.sensitiveHeaders`
  (`PlozzLog.swift:74-91`); query keys in `PlozzLog.redact(url:)`
  (`PlozzLog.swift:94-111`) — includes `X-Plex-Token`, `api_key`, `token`,
  `secret`, `t`/`s`/`p`, `x-amz-*`, `x-goog-*`.
- `HTTPResponseDiagnostics` is a task-local recorder (`HTTPResponseDiagnostics.swift:25-26`).
  `sendRaw` records a `ResponseRequestDiagnostic` only when
  `HTTPResponseDiagnostics.isCapturing` is true (`HTTPClient.swift:213,218-229`):
  elapsed ms, status, URL error code, bytes, format, and **the session's configured
  request/resource timeouts** (`:225-226`).
- Capture call sites: Home Continue Watching (`HomeAggregator.swift:850-854`), library
  browse (`LibraryBrowseViewModel.swift:495,1180-1192,1463`), collection sections
  (`CollectionSectionSettingsView.swift:354`), playback preparation
  (`PlaybackPreparationDiagnostics.swift:15`), server connection diagnostics
  (`ServerConnectionDiagnostics.swift:45`).
- Route labels are set with `HTTPResponseDiagnostics.$route.withValue(...)` — e.g.
  `.resumeItems` (`JellyfinClient.swift:384`), `.nextUp` (`:452`),
  `.itemDetail` (`:747`), `.playbackInventory` (`:1178`),
  `.serverDiscovery` (`ServerAddressResolver.swift:136`).
- Successful operations discard evidence; a failed one keeps at most four entries per
  category (`HTTPResponseDiagnostics.swift:32-53,116-166`).

---

## 2. Request construction

### 2.1 `Endpoint`

`Endpoint` is method + path + query + headers + body + redirect policy +
`allowsAutomaticAddressRetry` + `reportsUndeliveredRequests` +
`redactsURLForLogging` + `maximumResponseBytes` + `reportsServerTrustFailures`
(`CoreNetworking/Endpoint.swift:15-56`). Serialization is centralized in
`URLSessionHTTPClient.makeRequest` (`HTTPClient.swift:315-334`): base path is
prefix-joined (trailing slash dropped), endpoint query items are **appended** to the
base URL's query, headers are `setValue`, body assigned verbatim. No provider builds
a `URLRequest` for normal API traffic.

`allowAutomaticAddressRetry` defaults to `true` (`Endpoint.swift:47`); probe-capable
GETs opt out (e.g. `/Items/{id}/PlaybackInfo`, `JellyfinClient.swift:1189`).

### 2.2 Base URL per provider

| Provider | Base URL source | Path joining |
| --- | --- | --- |
| Jellyfin/Emby | `addressResolver?.current ?? savedBaseURL` (`JellyfinClient.swift:12-14`), resolver seeded from `baseURL` + `alternateURLs` (`:52-60`) | `makeRequest` prefix join (`HTTPClient.swift:319-324`) |
| Plex (server) | `PlexConnectionResolver` owns candidates and the confirmed route (`PlexClient.swift:196-227`); `resolvedBaseURL()` (`:201-207`) is resolved before **each** request (`:311`) | Same, plus Plex-specific absolute builders (`absoluteURL(serverPath:extraQuery:)`, `PlexClient.swift:2392`) for streams/artwork |
| Plex (plex.tv Discover) | `PlexClient.baseURL` for server calls vs `plexTVToken`/`plexTVHeaders` for `plex.tv` (`:160-179`) | Same |
| Silo | `SiloClient.baseURL` + `SiloAPI.endpoint(path:method:query:token:profileID:profileToken:)` (`SiloClient.swift:222-226`) | Bespoke endpoint builder |
| Subsonic | `SubsonicClient.normalizeAddress(...)` (`SubsonicProvider.swift:28-31`) | `/rest/{method}.view` with auth in the query (`SubsonicClient.swift:67-77`) |
| IPTV | `LiveTVPlaylistSource` URLs straight from the playlist (`IPTVHTTP.swift:52-63`) | Absolute URL per entry |
| Share/WebDAV | `TransportSessionKey` origin (`TransportSessionRegistry.swift:281-312`) | Transport-specific |
| Third parties | Hard-coded absolute URLs (`MetadataHTTP`, `TMDbMetadataProvider.apiBase`, tracker configs) | Direct |

### 2.3 Header/auth injection

| Backend | Mechanism | Citation |
| --- | --- | --- |
| Jellyfin | `authHeaders` = `{ Authorization: "MediaBrowser Client=…, Device=…, DeviceId=…, Version=…, Token=…" }`, added **per call site** (each `Endpoint(…, headers: authHeaders)`) | `JellyfinClient.swift:164-166`, value built in `JellyfinDeviceProfile.swift:30-41` |
| Emby | Same header shape; only Emby-specific query names differ (`GroupItemsIntoCollections` vs `CollapseBoxSetItems`, `JellyfinClient.swift:935-940`) | as above |
| Plex | `deviceProfile.headers(token:)` → `X-Plex-Product/Version/Client-Identifier/Device/Device-Name/Platform/Platform-Version/[X-Plex-Token]` (`PlexDeviceProfile.swift:81-96`); media/stream/artwork URLs instead carry `X-Plex-Token` **in the query** (`PlexClient.swift:1913,1924,2165,2176-2184`) | `PlexClient.swift:297` |
| Plex Discover | `plexTVHeaders` with the account-level token, separately from the server token (`PlexClient.swift:160-179`) | |
| Silo | `Authorization: Bearer …`, `X-Silo-Device-Id`, profile token (`SiloClient.swift:126-128,222-232`) + 401-refresh | |
| Subsonic | Credentials in the **query** (`apiKey`, or `u`/`t`/`s`), plus `Cache-Control: no-store` (`SubsonicClient.swift:67-77`) | |
| IPTV | Per-source header validation then `request.setValue` (`IPTVHTTP.swift:59-63`, `IPTVCredential.validate(headers:)`) | |
| Trackers/Seer | `Authorization: Bearer` per service (`TraktService`, `SeerService`, …) | e.g. `SeerService.swift` call sites |
| Keyless metadata | `User-Agent: Plozz/…` only (`MetadataHTTP.swift:15,38,55,80`; `MetadataDiscoveryHTTPClient.swift:33-38`) | |

Because Jellyfin auth is applied per call site rather than in the transport, any new
Jellyfin endpoint that omits `headers: authHeaders` silently becomes unauthenticated;
the two deliberate exceptions are `publicSystemInfo()` (`JellyfinClient.swift:172-176`)
and `verifyAddress` (`:135-139`).

### 2.4 Artwork URLs and artwork sessions

URL construction (no network):

| Provider | Builder | Shape |
| --- | --- | --- |
| Jellyfin | `imageURL(itemID:kind:maxWidth:tag:index:)` → `itemImageURL` (`JellyfinClient.swift:1866-1901`) | `/Items/{id}/Images/{typeSegment}[/{index}]?maxWidth=&tag=` where `typeSegment` ∈ Primary, Backdrop, Thumb, Logo — **no token in the URL**; auth happens because the byte loader goes through `ArtworkSession`, and for items whose art needs auth, through `AuthenticatedArtworkReference` |
| Jellyfin avatar | `userAvatarURL(userID:maxWidth:token:)` (`:1906-1919`) | `/Users/{id}/Images/Primary?maxWidth=&api_key=` — **token in query** |
| Plex | `imageURL(path:maxWidth:)` (`PlexClient.swift:2161-2187`) | `/photo/:/transcode?width&height&minSize=0&upscale=0&url=<inner>?X-Plex-Token=…&X-Plex-Token=…`; absolute remote paths returned untouched (`:2163`) |
| Plex Discover | `discoverImageURL` / `reauthenticatedDiscoverImageURL` (`:1483-1516`) | absolute remote image URL carrying the account-level token |
| Subsonic | `AuthenticatedArtworkReference` with a custom scheme (`SubsonicProvider.swift:238-254`) | Resolved by `ArtworkSession.authenticatedLoader`, not by URL |

Byte path: `ArtworkImageCache` → in-flight coalescing → `ArtworkSession.data(from:)`
→ (a) plain `ArtworkSession.shared` for a normal URL, or (b) the provider's
`artworkData(for:)` for the authenticated scheme (`ArtworkSession.swift:23-32`).
`ArtworkImageCache` treats `AuthenticatedArtworkReference` URLs as network files keyed
by account+artworkID+variant (`ArtworkImageCache.swift:520-556`).

Artwork *metadata* (which URL to use) is resolved by `MetadataKit/ArtworkRouter`
(AniList/Kitsu/TVmaze/Wikidata/Wikipedia/Deezer/MusicBrainz/TMDb/TVDB), memoised per
process in `heroCandidates` (cap 600) plus `MetadataDiskCache`
(`MetadataKit/ArtworkRouter.swift:18-48`). Gateways: `ArtworkSession.artworkResolveLimiter`
(3), `backgroundArtworkResolveLimiter` (1) (`ArtworkSession.swift:111-114`).

### 2.5 Bespoke request code (no shared transport)

| Module | What it does itself | Citation |
| --- | --- | --- |
| Plex `PlexClient` | Own send + decode + status mapping + connection retry + its own `sameOrigin` forcing | `PlexClient.swift:303-345,424-430` |
| Silo `SiloClient` | Own `send`, own 401-refresh, own pacing/cooldowns, own `Problem` body parsing, own JSON decode | `SiloClient.swift:186-278` |
| IPTV | Own `URLRequest` build, own status→error map, own byte limits, own redirect delegate | `IPTVHTTP.swift:52-140` |
| LiveTV | Own byte download, own redirect policy, own ETag/expiry cache | `LiveTVSourceLoader.swift:44-190` |
| Subsonic | Query-string auth in a bespoke `Endpoint` builder | `SubsonicClient.swift:60-80` |
| Subtitle/Icon/Playlist | Raw `URLSession.bytes`/`data` with their own delegates | `SubtitleFileLoader.swift:36-59`, `ProviderIconLoader.swift:23-41`, `StreamingMediaPlaylist.swift:16-24` |
| `PlozziOSAppModel` (Plex download queue) | Raw `URLRequest` + `JSONDecoder()` on `OfflineNetworkSession.shared` | `PlozziOSAppModel.swift:4026-4032,4073-4106` |
| `RelatedTitlesProvider` | Raw AniList GraphQL `POST` on `OfflineNetworkSession.shared`, returns `nil` on any failure, no `User-Agent` | `RelatedTitlesProvider.swift:111-118,223` |

---

## 3. Execution semantics per call

### 3.1 Pagination

| Site | Policy | Citation |
| --- | --- | --- |
| Jellyfin `exhaustiveItems` | fixed 100-row pages; fails closed on duplicate ids, non-advancing offsets, unstable `TotalRecordCount` | `JellyfinClient.swift:462-515` |
| Jellyfin Resume (unbounded) | `exhaustiveItems` over `/Items/Resume` | `JellyfinClient.swift:342-359` |
| Jellyfin NextUp | **never** drains: one page capped at 100 even for `Int.max` | `JellyfinClient.swift:404-420` |
| Jellyfin native sections (Emby) | `exhaustiveItems` when `limit == .max` | `JellyfinClient.swift:275-314` |
| Jellyfin watchlist (`favorites`) | loop of up to 1 000 pages, `Limit = limit` (Home passes 10 000) | `JellyfinClient.swift:1570-1600` |
| Jellyfin series metadata | batches of 50 ids | `JellyfinClient.swift:520-558` |
| Plex continue-watching hub | `ContinueWatchingHub` with `ResumeFeedPagingFailure` surfaced, not swallowed | `PlexProvider.swift:253-283` |
| Plex series metadata | batches of 50 rating keys | `PlexProvider.swift:392-428` |
| Home collection rows | `HomeContentPager` serialized gate (1) and 3 concurrent source pages; `loadAll` for non-default queries | `HomeContentPager.swift:31,93,122-160` |
| Library grid | `PageRequest` per view-model page; A–Z rail uses a count-only `Limit=0` query | `JellyfinClient.swift:1060-1085` |
| LiveTV | whole-document download with hard byte caps | `LiveTVSourceLoader.swift:44-68` |

### 3.2 Retries

| Site | Trigger | Attempts | Citation |
| --- | --- | --- | --- |
| `ServerAddressHTTPClient` | `AppError.serverUnreachable` **and** method `GET` **and** `allowsAutomaticAddressRetry` | one retry on the next approved address | `ServerAddressResolver.swift:195-210` |
| `PlexClient.send` | `AppError.serverUnreachable` | one retry on the new resolved base URL — **for any HTTP method**, including POST/PUT/DELETE | `PlexClient.swift:303-324` |
| `JellyfinClient.readCollectionPage` | `AppError.serverUnreachable` | one retry after 250 ms sleep | `JellyfinClient.swift:1040-1049` |
| `JellyfinProvider.nextUpItemsResilient` | `invalidResponse` on an unbounded NextUp page | one bounded (100) re-request | `JellyfinProvider.swift:368-392` |
| Plex Home rows | incomplete hub payload without a shelf locator | one re-fetch of `serverHomeHubs` | `PlexHomeLayout.swift:175-196` |
| Plex resume feed | endpoint incompatibility (`notFound`/`invalidResponse`/`decoding`) | falls through hub/items → onDeck | `PlexProvider.swift:253-283` |
| Silo | HTTP 401 on **GET** | one refresh + retry | `SiloClient.swift:228-233` |
| Plex lean-parameter fallback | the request with `includeElements=Stream` fails with `AppError.invalidResponse` | one lean re-request without that parameter | `PlexClient.swift:452-471` |
| `ServerAddressResolver` probe sweep | first failure | re-sweep excluding the failed address | `ServerAddressResolver.swift:99,202` |
| Artwork bytes | — | **no automatic retry**; a view that returns re-triggers a load (`ArtworkImageCache.swift:1092-1098`; deadline kill at `:858-866`) | |
| Metadata (`MetadataHTTP`, `MetadataDiscoveryHTTPClient`) | — | **no retry**, caller-level circuit breakers instead (`MetadataHTTP.swift:88-134`) | |
| Everything else | — | single attempt | |

### 3.3 Cancellation

- Propagated: every `HTTPClient` path (`try Task.checkCancellation()` in
  `ServerAddressResolver.swift:85,121`, `PlexClient.swift:312,319`,
  `JellyfinClient.swift:472,530`, `SiloClient.swift:216,279`, `IPTVHTTP.swift:57`).
  `URLSession` task cancellation maps to `AppError.cancelled`
  (`HTTPClient.swift:266-271,287-289`; `map()` at `:336-348`).
- Swallowed to `nil`/empty:
  `TMDbArtworkResolver.tmdbData` (`TMDbArtworkResolver.swift:90-92`),
  `MetadataHTTP.performWithStatus` (`MetadataHTTP.swift:159-165`),
  `RelatedTitlesProvider` (`:117`), `ArtworkImageCache.downloadData`
  (`:1093`), `PlozziOSAppModel` (`:4032,4092`).
- Aggregated: `HomeAggregator.fetch` converts `CancellationError` to
  `.failure(.cancelled)` per row and keeps going (`HomeAggregator.swift:1076-1086`);
  the group then stops refilling once cancelled (`:315-320,530-531,554-557`).
- Continue Watching is stricter: `continueWatchingDTOs` rethrows cancellation
  (`JellyfinProvider.swift:420-422,434-436`).

### 3.4 Error mapping to `AppError`

| Layer | Mapping | Citation |
| --- | --- | --- |
| `URLSessionHTTPClient.send` | 200–299 pass; 401/403 → `.unauthorized`; 404 → `.notFound`; 409 → `.conflict`; 429 → `.rateLimited(retryAfter:)`; everything else → `.invalidResponse` | `HTTPClient.swift:185-205` |
| `URLSessionHTTPClient.sendRaw` | transport-only: `URLError` → `map()`; `CancellationError` → `.cancelled`; any other error → `.serverUnreachable` (unless `reportsServerTrustFailures`) | `HTTPClient.swift:266-294,336-348` |
| `HTTPRequestNotSentError` | wraps a proven-not-sent failure | `HTTPClient.swift:24-30,273-275`; `ServerAddressResolver.swift:186-193` |
| Decode | any `DecodingError` → `AppError.decoding` plus an error log | `HTTPClient.swift:118-134` |
| Plex (`sendRaw` callers) | own 401/402/403/404/409/423/429/502/504 map | `PlexClient.swift:336-346,408-421` |
| Silo | own 401/403/404/409/412/429/other map + `Problem` body | `SiloClient.swift:266-278` |
| IPTV | own map incl. 503 "connection limit" → `.conflict`, 3xx → `redirectBlocked` | `IPTVHTTP.swift:106-120` |
| Offline mode | throws `OfflineModeError`, **not** `AppError` | `HTTPClient.swift:211`, `OfflineMode.swift:21-31` |
| Home | `(error as? AppError) ?? .unknown("")` | `HomeAggregator.swift:1080` |

### 3.5 Where decode happens

| Path | Executor | Citation |
| --- | --- | --- |
| `HTTPClient.decodeResponse` | generic executor (nonisolated async), not the caller's actor | `HTTPClient.swift:108-135` |
| Provider mapping (Jellyfin/Plex/Silo/Subsonic) | generic executor, inside the provider's nonisolated async method | e.g. `JellyfinProvider.swift:565-567` |
| `MetadataHTTP` / `MetadataDiscoveryHTTPClient` | generic executor | `MetadataHTTP.swift:145-166`, `MetadataDiscoveryHTTPClient.swift:57-68` |
| `ArtworkRouter` / `ExternalTitleMetadataResolver` / `TMDbArtworkResolver` | their own actor executors (never MainActor) | `ArtworkRouter.swift:18`, `ExternalTitleMetadataResolver.swift:19`, `TMDbArtworkResolver.swift:18` |
| **`PlozziOSAppModel.send`** | **MainActor** — class is `@MainActor`, decode is `JSONDecoder().decode` inline | `PlozziOSAppModel.swift:35-37,4101-4105` |
| Home aggregation | `Task.detached(priority: .userInitiated)` around `aggregator.content` | `HomeViewModel.swift:1069-1077,1129-1137` |
| Artwork decode | dedicated `OperationQueue`s, off the cooperative pool | `ArtworkImageCache.swift:1100-1129` |

Note (§8): SE-0338 reasoning is a language-level argument, not a measurement; no
`PLZSTALL` sample here isolates decode specifically.

### 3.6 Logging

| Layer | Volume | Citation |
| --- | --- | --- |
| `URLSessionHTTPClient` | one `→` (debug) and one `←` (debug, with bytes) per request; error-level line on decode failure | `HTTPClient.swift:234,308-311,126-132` |
| `HTTPResponseDiagnostics` | no logging; in-memory evidence only | `HTTPResponseDiagnostics.swift` |
| Plex client | error-level lines for feed fallbacks and enrichment failures | `PlexProvider.swift:264,276,409-411`; `PlexHomeLayout.swift:182,210,305` |
| Jellyfin | info-level history summary per Continue Watching fetch, error per failed feed | `JellyfinProvider.swift:448-450,475-477,506-509` |
| Home aggregator | `PLZBOOT` per-row and per-fanout timings, error per failed row | `HomeAggregator.swift:616-617,699-700,753,1060-1084` |
| `MetadataHTTP` / `MetadataDiscoveryHTTPClient` | **nothing** | — |
| `RelatedTitlesProvider`, `SubtitleOverlayLoader`, `PlozziOSAppModel.send` | **nothing** | — |
| Artwork | error on resolution failure and deadline breach only | `ArtworkSession.swift:128`, `ArtworkImageCache.swift:861` |
| IPTV/LiveTV/Silo | dedicated setup/guide/handoff diagnostics | `IPTVHTTP.swift:64-67,103-105`; `SiloClient.swift:260-263` |

---

## 4. Caching, dedup and duplicated fetches

### 4.1 HTTP cache

| Lane | Cache | Policy |
| --- | --- | --- |
| `plozzDefault`, `plozzInteractive`, `plozzDiscovery` | `URLCache.shared` still attached but bypassed | `reloadIgnoringLocalCacheData` (`HTTPClient.swift:407,426,438`) |
| `ArtworkSession.shared` | dedicated 64 MB / 384 MB `URLCache` at `plozz-artwork` | `returnCacheDataElseLoad` (`ArtworkSession.swift:46-60,77-78`) |
| `MetadataHTTP.session` | `URLCache.shared` | `useProtocolCachePolicy` (`MetadataHTTP.swift:23`) |
| `TMDbArtworkResolver.metadataSession` | `URLCache.shared` | default protocol policy (`TMDbArtworkResolver.swift:76-82`) |
| `ProviderIconLoader` | memory-only 4 MB | default protocol policy (`ProviderIconLoader.swift:51`) |
| Subsonic, PublicMetaDB, IPTV, LiveTV, subtitle, playlist, transport registry | none | `urlCache = nil` / `.ephemeral` |
| LiveTV source loader | **application-level** ETag/`Last-Modified`/expiry cache | `LiveTVSourceLoader.swift:14-28` |

### 4.2 In-memory caches that stand in for requests

| Cache | Keyed by | Scope | Citation |
| --- | --- | --- | --- |
| `ArtworkImageCache.cache` (decoded pixels) + `inFlight` + `decodedNetworkKeys` + `stableIdentities` | URL/reference + variant | process, `NSCache` cost-capped | `ArtworkImageCache.swift:346-364,520-556` |
| `ArtworkSession.byteCache` | URL | process, 384 MB disk | `ArtworkSession.swift:46-60` |
| `ArtworkRouter.heroCandidates` (cap 600), `cache` (MetadataDiskCache), `originalLanguages`, `missingOriginalLanguages` | metadata query | process + disk | `ArtworkRouter.swift:31-48` |
| `TMDbArtworkResolver` `cache`/`logoCache`/`backdropCache`/`stillCache`/`seriesIDCache`/`companyLogoCache` | title / id / s/e | actor lifetime, negatives retained | `TMDbArtworkResolver.swift:43-62` |
| `ExternalTitleMetadataResolver` availability cache (cap 256) + in-flight tasks | identity key | process | `ExternalTitleMetadataResolver.swift:24-32` |
| `LibraryInventoryStore` | account scope | process + disk (`library-inventory-v1.json`) | `LibraryInventoryStore.swift:10-72` |
| `HomeContentStore` snapshot + hero snapshot/pool/exposure | profile scope | disk, repainted before the live fan-out | `HomeViewModel.swift:1266-1270`; `HomeView.swift:406-414` |
| `HomeContentPageLoader.Session` pages + recommendation catalogs | source/page key | one Home load | `HomeContentPageLoader.swift:31-36` |
| `HomeContentPager` cursors/items | one row | one row load | `HomeContentPager.swift:20-31` |
| `HomeSnapshotPersistence` generation ordering | scope | process | `HomeViewModel.swift:8-40` |

### 4.3 Request coalescing

| Mechanism | What it dedupes | Citation |
| --- | --- | --- |
| `JellyfinDiscoveryRequests` | concurrent `/Users/{id}/Views` calls for the same user id share one flight | `ProviderJellyfin/JellyfinDiscoveryRequests.swift:28-50`, used at `JellyfinClient.swift:337` |
| `PlaybackInfoRequestCoordinator` | concurrent `PlaybackInfo` for the same (server, user, item) | `JellyfinClient.swift:1179-1192` |
| `ServerAddressResolver.Flight` | concurrent address resolution shares one probe sweep | `ServerAddressResolver.swift:21-25,86-119` |
| `ArtworkImageCache.inFlight` | concurrent loads of the same URL+variant | `ArtworkImageCache.swift:344-346,569-591` |
| `SeriesIdentities` actor | per-series identity resolution for one account/Home load | `HomeAggregator.swift:430-452` |
| `HomeViewModel.load` guard + `wantsReloadAfterCurrent` | overlapping Home loads collapse (then re-run once) | `HomeViewModel.swift:915-926,949-966` |
| `HomeContentPager.gate`, `HomeContentPageLoader` recommendation gate | serialized pagination per row/catalog | `HomeContentPager.swift:31`, `HomeContentPageLoader.swift:34` |
| `PublicMetaDBRequestGate` | mutation transactions | `PublicMetaDBClient.swift:67-70,217-218` |

### 4.4 Same data fetched twice / redundant work

| # | Duplicate | Evidence | Status |
| -: | --- | --- | --- |
| 1 | **Continue Watching content is fetched by two independent paths in one Home load** (three endpoint calls: the feed's Resume + NextUp, plus the server rows' Resume/NextUp): the aggregator's `continueWatching` feed (`Items/Resume` + `Shows/NextUp`) and, when the row layout is `matchServer`, the server-owned `resume`/`nextup` server rows, which issue their own `/Items/Resume` and `/Shows/NextUp` per visible view | provider feed: `HomeAggregator.swift:791-811`; server rows: `JellyfinHomeLayout.swift:163-170,195-199`; measured as `server-sections` rows in `docs/measurements/device-home-timing-1to1.md` | observed in code + telemetry |
| 2 | **Recently Added is fetched twice**: global `latest` feed (`/Items/Latest`) plus one `latestmedia` server row per visible view (`/Items/Latest?ParentId=`) | `HomeAggregator.swift:820-829`; `JellyfinHomeLayout.swift:171-175,234-240` | observed in code + telemetry |
| 3 | **Jellyfin series metadata for the same series ids is fetched twice**: once with `includeUserData: true` for Continue Watching recency, once with `includeUserData: false` for Home identity stamping | `JellyfinProvider.swift:245,496-499` vs `HomeAggregator.swift:1093-1127` → `JellyfinProvider.swift:290-298` | read from code |
| 4 | **Plex Continue Watching runs an extra `/library/onDeck` query** on every load to diff the legacy feed against the hub, detached and fire-and-forget | `PlexProvider.swift:313-324,329-351` | gated by `FanoutDiagnostics.isEnabled`, which defaults **off** in release (`CoreModels/FanoutDiagnostics.swift:27-33`) |
| 5 | **`/Users/{id}/Views` can be requested up to three times per Home load**: `prepareServerDefaults` (via `serverHomeLayout`), the `libraries` feed, and `homeVisibleParents` for account-wide server sections — coalesced only when they overlap in time | `HomeLibraryVisibilityStore.swift:129,199` → `JellyfinHomeLayout.swift:69-76`; `HomeAggregator.swift:780-782`; `JellyfinHomeLayout.swift:195-199` | coalescer is per-user, so overlapping calls collapse; sequential ones do not |
| 6 | **Two TMDb JSON paths with separate caches and sessions** (`TMDbArtworkResolver.metadataSession` vs `MetadataKit.TMDbMetadataProvider` over `MetadataHTTP.session`) | `TMDbArtworkResolver.swift:76-92`; `TMDbMetadataProvider.swift:53-67` | only `companyLogoURL` currently uses the first (`DetailExtrasView.swift:305`) |
| 7 | **Four transports reach `graphql.anilist.co`**: `AniListService` on `plozzDefault`, `AniListRatingsProvider` on `plozzDefault`, MetadataKit's keyless providers on `MetadataHTTP.session`, `RelatedTitlesProvider` on `OfflineNetworkSession.shared` | `AniListService.swift:46`; `RatingsService/AniListRatingsProvider.swift:20-24`; `MetadataKit/AniListArtworkProvider.swift:22`; `MetadataKit/RelatedTitlesProvider.swift:111-118` | read from code |
| 8 | **Home can run twice back-to-back**: a `mediaItemDidMutate` notification during launch queues a second full fan-out; the share-scan observer explicitly baselines its first observation to avoid "the whole 5-account fan-out a second time (measured at 11s of duplicated network and CPU)" | `HomeViewModel.swift:915-926,955-961`; `HomeView.swift:2305-2311` | code comment + prior measurement |
| 9 | **Hero re-curation re-runs its network sources**: `HeroFreshnessRefreshDriver.runWhileVisible` bumps a revision every 600 s while Home is visible, which re-enters `recomputeHero` and its random/discovery/artwork providers | `HeroUI/HeroFreshnessRefreshDriver.swift:14,38-48`; `FeatureHomeCore/HeroFreshness.swift:104`; `HomeView.swift:781-787,1177-1218` | read from code |
| 10 | **Hero watch-state re-check re-fetches items individually**: `heroWatchStateRefresher` → `HeroCandidateWatchStateEnricher` → one `provider.item(id:)` per source ref | `AppShell/MainTabViewSupport.swift:217-256`; `HomeView.swift:1105-1135` | only when Hide Watched is on (`enrich(enabled:)`) |
| 11 | **Hero metadata enrichment re-fetches the play target**: up to 4 concurrent `provider.item`/`metadata` calls per curation for sparse slides | `FeatureHomeCore/HeroMetadataEnricher.swift:57-120` | |
| 12 | **Hero "library recovery" fans a search out to every account, per slide**: a slide without a locally validated source runs one 4 s-deadline library search + verification task per account; the outer fan-out is 4 slides at a time, but each slide's per-account lookups share no connection limiter | `AppRuntime/CrossServerSourceResolverFactory.swift:84-164` (task per account at `:99-148`, 4 s deadline at `:127-136`); outer 4-way at `FeatureHomeCore/HeroMetadataEnricher.swift:296-331`; wired at `AppShell/MainTabViewSupport.swift:281-284` | read from code; count is 1 × accounts × qualifying slides |

**Not a network duplicate (checked):** watchlist/identity resolution for the Home row
is answered from the durable local watchlist store, not from a provider request
(`HomeViewModel.swift:2010-2031` → `AppRuntime/MediaItemActionCoordinator.swift:774-780`),
and persisted artwork URLs are rehydrated synchronously without a metadata call
(`HomeViewModel.swift:2061-2065`).

---

## 5. Concurrency and backpressure

### 5.1 Limiters

| Limiter | Limit | Guards | Citation |
| --- | ---: | --- | --- |
| `HomeAggregator.accountFanoutLimit` | 5 | concurrent requests **per lane** (libraries, continueWatching, recentlyAdded, watchlist, libraryRows) | `HomeAggregator.swift:288,529-548` |
| custom/customRows lane | 1 | custom Home collection rows | `HomeAggregator.swift:531` |
| Jellyfin per-library continue watching | 4 | `resume+nextUp` pairs across libraries | `JellyfinProvider.swift:638-667` |
| Jellyfin per-library latest | 4 | `Items/Latest` per library | `JellyfinProvider.swift:711-724` |
| Jellyfin alphabet index | 6 | count-only `itemCount` probes per letter | `JellyfinProvider.swift:1267-1278` |
| Jellyfin library-scoped search | 4 | `searchItems` per enabled library | `JellyfinProvider.swift:1357-1378` |
| `HomeContentPager.gate` | 1 | one row's pagination | `HomeContentPager.swift:31` |
| `HomeContentPager` source pages | 3 | concurrent sources inside one page | `HomeContentPager.swift:93` |
| `HomeContentPageLoader` recommendation gate | 1 | one recommendation catalog | `HomeContentPageLoader.swift:34` |
| `ArtworkSession.warmLimiter` | 4 | background art warm/prefetch | `ArtworkSession.swift:100` |
| `ArtworkSession.artworkResolveLimiter` | 3 | grid live metadata→art resolution | `ArtworkSession.swift:111` |
| `ArtworkSession.backgroundArtworkResolveLimiter` | 1 | speculative art resolution | `ArtworkSession.swift:114` |
| `ArtworkImageCache` network limiters | 2 + 2 | foreground / background byte loads | `ArtworkImageCache.swift:363-364` |
| `HeroLogoArtwork.backgroundLimiter` | 2 | hero logo warm | `CoreUI/HeroLogoArtwork.swift:975` |
| `TMDbArtworkResolver.backgroundLimiter` | 2 | season still prefetch (`maxConcurrent` 4 outer) | `TMDbArtworkResolver.swift:87,213-249` |
| `MetadataDiscoveryHTTPClient.limiter` | 4 | all keyless discovery traffic | `MetadataDiscoveryHTTPClient.swift:18` |
| `LibraryQuerySession.materialization` | 3 | grid materialization | `FeatureHomeCore/LibraryQuerySession.swift:31` |
| `LibraryCollageCache` | 2 / 3 | collage download / image | `CoreUI/LibraryCollageCache.swift:13-14` |
| `ShareCatalogCoordinator.scanCapacity` | 2 | catalog scans | `ProviderShare/ShareCatalogCoordinator.swift:44` |
| Tracker/MAL/Wetrakr/PublicMetaDB gates | 1 | per-service serialization | `TraktWatchlistDestination.swift:25`, `MALWatchlistDestination.swift:39`, `WetrakrClient.swift:33`, `PublicMetaDBClient.swift:217-218` |

`ConcurrencyLimiter` is an actor; `run` keeps queued work after cancellation,
`runUnlessCancelled` drops it (`CoreModels/ConcurrencyLimiter.swift:19-22,84-133`).

### 5.2 The per-host connection ceiling

Per-session caps to a single Jellyfin/Plex host when several lanes talk to it:

| Lane | `httpMaximumConnectionsPerHost` | Citation |
| --- | ---: | --- |
| `plozzDefault` | 8 | `HTTPClient.swift:406` |
| `plozzInteractive` | 6 | `HTTPClient.swift:425` |
| `plozzDiscovery` | 6 (Foundation default; not set) | `HTTPClient.swift:434-442` |
| `ArtworkSession.shared` | 6 | `ArtworkSession.swift:66` |
| `OfflineNetworkSession.shared` | 6 (Foundation default) | `OfflineNetworkSession.swift:13` |
| `TMDbArtworkResolver.metadataSession` | 6 | `TMDbArtworkResolver.swift:80` |
| `MetadataHTTP.session` | 6 (default) | `MetadataHTTP.swift:17-25` |
| `TransportSessionRegistry` | 6 | `TransportSessionRegistry.swift:192,302` |
| `LiveHLSScrubThumbnails` | 2 | `LiveHLSScrubThumbnails.swift:78` |
| `ProviderIconLoader` | 2 | `ProviderIconLoader.swift:50` |
| `HDR10PlusHTTPRangeSource` | 1 | `HDR10PlusHTTPRangeSource.swift:46` |

The code treats these as **independent pools** and relies on that isolation: the
`plozzInteractive` doc comment states a shared pool let a foreground fetch wait
~18 s behind background work (`HTTPClient.swift:411-420`), and `plozzDefault` was
raised 6→8 for exactly this reason (`:400-406`).

Aggregate ceiling to one host is therefore **not** a single number: 8 + 6 + 6
(artwork, if art lives on the media host) + 6 (`OfflineNetworkSession.shared`, used
by share/subtitle helpers) + transport-registry sessions. On an HTTP/1.1 LAN server
each session's cap is a real socket budget; on HTTP/2 they multiplex.

**Measured negative result:** raising the per-host cap from 8 to 12 "changed
nothing" on the device measurements (`docs/measurements/device-http-timing.md:50-51`).

### 5.3 How Home competes with hero and background work

- Home's fan-out is 5 concurrent requests **per lane** — five non-custom lanes plus
  the custom lane (cap 1), i.e. a ceiling of 26 in-flight requests with ≥5 accounts
  (`HomeAggregator.swift:288,529-531`), which exceeds `plozzDefault`'s 8-socket cap,
  so the remainder queues inside the session.
- Home aggregation itself runs off the main actor (`HomeViewModel.swift:1069-1077`).
- Hero curation starts from a SwiftUI `.task(id:)` after content changes
  (`HomeView.swift:781-787`); it uses `plozzDefault` (random/discovery/enrichment)
  plus `ArtworkRouter` (`MetadataHTTP.session`) plus `ArtworkSession` for bytes, so
  its *server* traffic competes with Home's on `plozzDefault` while its *image*
  traffic uses a separate pool.
- Hero artwork warming is deliberately capped at 4 and documented as leaving ≥2 of
  the artwork pool's 6 connections for on-screen art
  (`ArtworkSession.swift:91-100`, `HomeHeroView+Artwork.swift:70,131`).
- Detail entry bypasses the queue entirely via `plozzInteractive`
  (`ManagedProviderRegistry.swift:56,65,77`).
- Share scans use their own sessions per account key with 6 conns
  (`TransportSessionRegistry.swift:186-192`), and the scanner pool is 4 listers
  (`TransportSessionRegistry.swift:186-190` comment), gated by `scanCapacity = 2`
  (`ShareCatalogCoordinator.swift:44`).
- Background metadata (`MetadataDiscoveryHTTPClient.limiter = 4`) is a separate
  budget from media-server traffic.

---

## 6. Consistency gaps (concrete)

| # | Dimension | Divergence | Citation |
| -: | --- | --- | --- |
| 1 | Timeouts | One process runs at least **nine** different request-timeout budgets: 2.5 s, 5 s, 8 s, 10 s, 12 s, 15 s, 20 s, 30 s, 45 s, plus "system default ≈60 s" for lane 4 | `HTTPClient.swift:399,423,436`; `StreamingMediaPlaylist.swift:9`; `LiveHLSScrubThumbnails.swift:75`; `TMDbArtworkResolver.swift:78`; `MetadataHTTP.swift:19`; `SubsonicProvider.swift:19`; `PublicMetaDBClient.swift:46`; `IPTVHTTP.swift:27`; `OfflineNetworkSession.swift:13` |
| 2 | Offline gating | `HTTPClient` paths are gated twice (explicit throw + URLProtocol); PublicMetaDB ×2 and the WebDAV probe session are gated **zero** times; background download sessions are excluded by design | `HTTPClient.swift:211`; `OfflineNetworkSession.swift:20-23`; `PublicMetaDBClient.swift:40-50`; `PublicMetaDBBrowserPairing.swift:107-118`; `MediaShareRouteDetector.swift:328-330` |
| 3 | Error currency | `OfflineModeError.networkUnavailable` escapes `HTTPClient.send`/`sendRaw` although the protocol documents `AppError` only | `HTTPClient.swift:8-22,211`; `OfflineMode.swift:21-31` |
| 4 | Retry | `PlexClient` retries **any** method on `serverUnreachable`; `ServerAddressHTTPClient` retries GET only; Jellyfin retries only collection reads; metadata and artwork never retry | `PlexClient.swift:303-324`; `ServerAddressResolver.swift:201`; `JellyfinClient.swift:1040-1049` |
| 5 | Redirects | Resolver-backed clients force `.sameOrigin` on every request, overriding the endpoint's policy; non-resolver clients honour `.follow`/`.doNotFollow` | `ServerAddressResolver.swift:181-182`; `HTTPClient.swift:243-250` |
| 6 | Credentials in URLs | Plex (server + Discover), Subsonic and Jellyfin avatars put tokens in the query string; Jellyfin item art does not (header/loader instead) | `PlexClient.swift:1913,1924,2165-2184`; `SubsonicClient.swift:67-77`; `JellyfinClient.swift:1914-1916`; `JellyfinClient.swift:1892-1899` |
| 7 | Decode actor | Everything decodes off the main actor except `PlozziOSAppModel.send` | `PlozziOSAppModel.swift:35-37,4101-4105` |
| 8 | Logging | `HTTPClient` logs every request; `MetadataHTTP`, `MetadataDiscoveryHTTPClient`, `RelatedTitlesProvider`, `SubtitleOverlayLoader`, `PlozziOSAppModel.send` log nothing | `HTTPClient.swift:234,308-311`; `MetadataHTTP.swift`; `RelatedTitlesProvider.swift:111-118` |
| 9 | Cancellation | `HomeAggregator` maps cancellation to a row failure; `JellyfinProvider.continueWatchingDTOs` rethrows it; `TMDbArtworkResolver`, `MetadataHTTP`, `RelatedTitlesProvider` collapse it to `nil` | `HomeAggregator.swift:1076-1086`; `JellyfinProvider.swift:420-422`; `TMDbArtworkResolver.swift:90-92`; `MetadataHTTP.swift:159-165` |
| 10 | Status mapping | `URLSessionHTTPClient.send` folds 400/405/500/503 into `.invalidResponse`; Plex and IPTV and Silo each carry richer status taxonomies | `HTTPClient.swift:188-204`; `PlexClient.swift:336-346`; `IPTVHTTP.swift:106-120`; `SiloClient.swift:266-278` |
| 11 | Provider registry | Two registries compose providers differently: the iOS registry's Emby has no `authenticatedStreamProber`, the tvOS one does | `AppRuntime/ManagedProviderRegistry.swift:60-68` vs `AppShell/AppState.swift:1592-1603` |
| 12 | Auth header injection | Jellyfin auth is per call site (not transport), so a forgotten `headers: authHeaders` is silently unauthenticated; Plex auth lives in the client and is applied automatically | `JellyfinClient.swift:164-166`; `PlexClient.swift:297` |
| 13 | HTTP caching | Three different policies in one process: bypass (`reloadIgnoring…`), protocol policy, and `returnCacheDataElseLoad` | `HTTPClient.swift:407`; `MetadataHTTP.swift:23`; `ArtworkSession.swift:78` |
| 14 | Timeouts recorded in diagnostics | The recorded budget is the **session's**, not the endpoint's, so per-request `timeoutInterval` overrides (e.g. subtitle loader) are invisible to diagnostics | `HTTPClient.swift:225-226` vs `SubtitleFileLoader.swift:36` |
| 15 | Watchlist scope | Jellyfin's watchlist is a 10 000-item recursive favorites query on `plozzDefault`; Plex's watchlist is a `plex.tv` Discover call with an account-level token | `HomeAggregator.swift:61`; `JellyfinClient.swift:1570-1600`; `PlexClient.swift:176-179`; `PlexProvider.swift:3031-3037` |
| 16 | Fallback semantics | Plex feed fallbacks log at `error` for a *recoverable* fallback; Jellyfin's equivalent paths log at `info` | `PlexProvider.swift:264,276` vs `JellyfinClient.swift:1045` |
| 17 | 401 recovery | Plex `sections()` silently re-mints a server token and retries once on `unauthorized`; Jellyfin surfaces `AppError.unauthorized` to the caller (the only Jellyfin 401 remap is sign-in → `.invalidCredentials`) | `PlexClient.swift:476-487`; `JellyfinClient.swift:245-249` |

---

## 7. Home-load call graph

### 7.1 Sequence

```
Home tab .task ── HomeViewModel.loadIfNeeded() → load()            HomeViewModel.swift:807-912
  ├─ prepareVisibility()                                            HomeViewModel.swift:969
  │    └─ HomeLibraryVisibilityStore.prepareServerDefaults           HomeLibraryVisibilityStore.swift:84
  │         ├─ (matchServer only) GET /DisplayPreferences/…         JellyfinClient.swift:254-265
  │         └─ GET /Users/{id}/Views                                JellyfinClient.swift:331-340
  └─ Task.detached(.userInitiated) → HomeAggregator.content/unmergedContent
       HomeViewModel.swift:1069-1077, 1129-1137
       └─ loadContent → task group, 5 per lane                     HomeAggregator.swift:454-761
            ├─ lane .global(.libraries)   → provider.libraries()   :778-782
            ├─ lane .global(.continueWatching)                     :783-869
            │     └─ provider.continueWatching(limit:)             JellyfinProvider.swift:238-256
            │          ├─ GET /Items/Resume  ┐ concurrent          JellyfinClient.swift:342-387
            │          ├─ GET /Shows/NextUp ┘                      JellyfinClient.swift:404-455
            │          ├─ GET /Users/{id}/Items?Ids=…  (recency)   JellyfinClient.swift:520-558
            │          └─ GET /Users/{id}/Items?ParentId=… (×⌈missing/4⌉ batches)
            │                                                     JellyfinProvider.swift:517-545
            ├─ lane .global(.recentlyAdded) → provider.latest()    :820-829
            ├─ lane .global(.watchlist)     → provider.watchlist() :830-832
            ├─ lane .libraryRows (.server batches)                 :975-1039
            │     └─ provider.serverHomeContent(sections:limit:…)  JellyfinHomeLayout.swift:88-116
            │          └─ per section: /Items/Resume | /Shows/NextUp | /Items/Latest
            │                                                     JellyfinHomeLayout.swift:159-182
            └─ lane .customRows (limit 1) → HomeContentPager         :933-974
```

After the aggregate lands, the hero re-curates off the published content
(`HomeView.swift:781-787` → `recomputeHero` at `:1065-1218`), which adds the
random/discovery/artwork/enrichment requests listed in §4.4 (#9–#12) and then the
hero carousel warms its own art (`HomeHeroView+Artwork` bounded by
`ArtworkSession.warmLimiter`).

### 7.2 Expected request counts (one Jellyfin account, unmerged layout)

Read from code; per-request URLs are the ones in the tables above.

| Phase | Request | Count |
| --- | --- | ---: |
| prepareServerDefaults | `/DisplayPreferences/usersettings` | 1 (only when row layout is `matchServer`) |
| | `/Users/{id}/Views` | 1 |
| libraries lane | `/Users/{id}/Views` (coalesced if overlapping) | 0–1 extra |
| continueWatching lane | `/Items/Resume` | 1 |
| | `/Shows/NextUp` (≤100 rows) | 1 |
| | `/Users/{id}/Items?Ids=…` series metadata | ⌈distinct series / 50⌉ |
| | `/Users/{id}/Items?ParentId=series` last-played probe | ⌈undated series / 4⌉ sequential batches |
| recentlyAdded lane | `/Users/{id}/Items/Latest` | 1 |
| watchlist lane | `/Users/{id}/Items?Filters=IsFavorite` | ⌈favorites / 10 000⌉ |
| server-sections lane | one batch per distinct (account, libraryID, isAccountWideHistory) | measured **3** on device |
| | per batch: one request per visible parent view (`/Items/Resume`, `/Shows/NextUp`) or one per library (`/Items/Latest`) | 1 × parents |
| hero (after content) | random libraries `provider.items(sort: .random)` | 1 per selected random library |
| | discovery (Seer/TMDb) | provider-dependent (**unverified** count) |
| | `ArtworkRouter` metadata lookups for hero candidates | 0–N, disk-cached per title |
| | artwork validation download (`HeroBackdropArtworkPolicy.warmFirstUsablePreview`) | 1 per validated URL |
| | `HeroMetadataEnricher` provider lookups | ≤4 concurrent, ≤ slide count |
| | hero library-target recovery (cross-server search per account) | 1 per account per qualifying slide, 4 s deadline |
| artwork bytes | poster/backdrop/logo fetches on `ArtworkSession` | 1 per uncached URL+variant |

For 4 libraries and a `matchServer` layout, the account-wide `resume`/`nextup`
server rows alone can add up to 4 + 4 view-scoped queries on top of the aggregator's
own Resume + NextUp, i.e. the Continue Watching data can be requested **3×** (feed,
resume row, nextup row) and Recently Added **2×** (feed + per-view rows).

### 7.3 Measured evidence

Single account, single Jellyfin server, unmerged layout (`merged=false`,
`libs=4`, `sections=0`). From `docs/measurements/device-home-timing-1to1.json`:

| Observed `HomeAgg.request` rows | Count | Meaning |
| --- | ---: | --- |
| `server-sections` | 3 | three server-section batches |
| `recentlyAdded` | 1 | global latest feed |
| `libraries` | 1 | `/Views` |
| `watchlist` | 1 | favorites query (empty list) |
| `continueWatching` | 1 | Resume + NextUp + recency enrichment |

So the measured run logged **7 aggregation operations** (`HomeAgg.request` lines), plus
the `prepareServerDefaults` requests, which are *not* logged as `HomeAgg.request`.
The `server-sections` line is one batch that issues one HTTP request per section, so
the HTTP request count for that run is higher than 7 and cannot be read off these
logs alone.

Timings (`device-home-timing-1to1.md:13-22,32-41`, medians):

| Row ready | TestFlight 72 | Self-build |
| --- | ---: | ---: |
| `libraries` / `recentlyAdded` | 647 ms | 980 ms |
| `watchlist` | 814 ms | 964 ms |
| `continueWatching` | 2 117 ms | 2 416 ms |

Continue Watching is the tail in both builds and roughly matches the HTTP legs
measured separately (Resume 523 ms, Latest 393/756 ms, `/Views` 351 ms —
`docs/measurements/device-http-timing.md:19-24`), i.e. the row time is network +
the two-feed merge + the recency-enrichment round trip.

### 7.4 Where it fans out and what it competes with

1. **Per lane × per account.** 5 concurrent per lane, so N accounts can put 5N
   requests on `plozzDefault` at once (`HomeAggregator.swift:531`), all sharing the
   8-socket budget (`HTTPClient.swift:406`).
2. **Per library inside a lane.** Jellyfin scoped history/latest fan out 4 at a time
   (`JellyfinProvider.swift:638,711`).
3. **Per series for recency.** Sequential batches of 4 `lastPlayedEpisode` queries
   (`JellyfinProvider.swift:517-545`).
4. **Hero after content.** Competes for `plozzDefault` sockets with the *next*
   Home load (post-play refresh, mutation-triggered reload) but not for artwork
   sockets (`ArtworkSession`).
5. **Hero art warming.** Bounded at 4 of 6 artwork connections
   (`ArtworkSession.swift:91-100`), explicitly reserving ≥2 for on-screen art.
6. **Background scans and metadata.** Share scanning has its own per-account sessions
   (`TransportSessionRegistry.swift:186-192`) and a capacity of 2
   (`ShareCatalogCoordinator.swift:44`); keyless metadata has a 4-permit budget
   (`MetadataDiscoveryHTTPClient.swift:18`). Neither shares a pool with the media
   server's API traffic.

---

## 8. Unverified / limits of this inventory

- **Per-session pool isolation.** The whole lane design assumes `URLSession`'s
  `httpMaximumConnectionsPerHost` is enforced per session (stated in
  `HTTPClient.swift:400-406,411-420`). Apple does not document this as a guarantee;
  the aggregate-connection arithmetic in §5.2 is therefore a model, not a
  measurement.
- **Exact Home request counts per configuration.** §7.2 is read from code. Only the
  single-account/single-Jellyfin/unmerged case has telemetry (§7.3); multi-account,
  Plex, Emby and `combined`/`custom` layouts are not measured here.
- **Which `HomeRowCustomization.defaults` the measured runs used.** Not logged; the
  3 `server-sections` batches are observed, their composition is inferred.
- **Decode-on-generic-executor claims** rest on SE-0338 semantics, not on a
  targeted stall/thread trace.
- **TMDbArtworkResolver** has a single production caller today; its other public
  APIs are exercised only by tests, so its second-TMDb-lane cost is small *now*.
- **Seer/hero discovery request counts** depend on server state and were not
  enumerated.
- This inventory covers HTTP only. AVFoundation/Plozzigen stream traffic, SMB/NFS/
  SFTP/FTP transports, WebSocket/long-poll paths and Top Shelf app-group I/O are out
  of scope.

---

## 9. Reference index

| Topic | File |
| --- | --- |
| Transport seam, lanes, mapping, retries-by-address | `Sources/CoreNetworking/HTTPClient.swift` |
| Request shape | `Sources/CoreNetworking/Endpoint.swift` |
| Offline admission + protocol | `Sources/CoreNetworking/OfflineNetworkSession.swift` |
| Address routing / same-origin / probe sweep | `Sources/CoreNetworking/ServerAddressResolver.swift` |
| Diagnostics recorder | `Sources/CoreNetworking/HTTPResponseDiagnostics.swift` |
| Secret-safe logging | `Sources/CoreNetworking/PlozzLog.swift` |
| Artwork lane + limiters | `Sources/CoreUI/ArtworkSession.swift` |
| Artwork bytes, coalescing, decode queues | `Sources/CoreUI/ArtworkImageCache.swift` |
| Second TMDb lane | `Sources/CoreUI/TMDbArtworkResolver.swift` |
| Keyless metadata transport | `Sources/MetadataKit/MetadataHTTP.swift`, `MetadataDiscoveryHTTPClient.swift` |
| Artwork metadata router | `Sources/MetadataKit/ArtworkRouter.swift` |
| Home fan-out | `Sources/FeatureHomeCore/HomeAggregator.swift` |
| Home load / publish | `Sources/FeatureHomeCore/HomeViewModel.swift` |
| Hero curation | `Sources/FeatureHome/HomeView.swift`, `FeatureHomeCore/HeroCurator.swift` |
| Jellyfin REST | `Sources/ProviderJellyfin/JellyfinClient.swift`, `JellyfinHomeLayout.swift` |
| Plex REST | `Sources/ProviderPlex/PlexClient.swift`, `PlexHomeLayout.swift` |
| IPTV transport | `Sources/ProviderIPTV/IPTVHTTP.swift` |
| LiveTV transport | `Sources/FeatureLiveTVCore/LiveTVSourceLoader.swift`, `LiveTVChannelScanTransport.swift` |
| WebDAV transport sessions | `Sources/MediaTransportHTTP/TransportSessionRegistry.swift` |
| Device measurements | `docs/measurements/device-http-timing.md`, `device-home-timing.md`, `device-home-timing-1to1.md` |

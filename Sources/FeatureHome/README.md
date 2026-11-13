# FeatureHome


## Invariants

- **Provider-agnostic.** All data flows through `MediaProvider`. No
  Jellyfin- or Plex-specific code paths above the provider seam.
- **Server art first.** External art (`MetadataKit`) is used as a
  fallback via `CoreUI.FallbackAsyncImage`, never as the default — the
  server's own backdrop/logo is always tried first.
  Shared logo views pair fallback lookups with the source item/account and
  metadata query. Memoized logos and in-flight tasks also distinguish artwork
  preference, so a missing server logo never gives unrelated titles a shared
  cache entry. A reused view rejects the previous title's image immediately.
- **`LoadState` everywhere.** Loading / empty / failure rendering uses
  `CoreUI.ContentStateView` so all surfaces feel identical.
- **No tokens in logs.** Provider calls log only opaque ids — never
  authorisation headers.

## Foreground and return refresh

See [Foreground and return refresh](../../docs/feature-home/refresh-and-watch-state.md#foreground-and-return-refresh).

## Related loading

See [Related loading](../../docs/feature-home/detail-and-playback.md#related-loading).

## Continue Watching watch actions

See [Continue Watching watch actions](../../docs/feature-home/refresh-and-watch-state.md#continue-watching-watch-actions).

## Mobile Home loading geometry

See [Mobile Home loading geometry](../../docs/feature-home/home-rows-and-loading.md#mobile-home-loading-geometry).

## Inline library collections

See [Inline library collections](../../docs/feature-home/library-browsing.md#inline-library-collections).

## Browsing Home rows

See [Browsing Home rows](../../docs/feature-home/library-browsing.md#browsing-home-rows).

## Recently Added watched filtering

See [Recently Added watched filtering](../../docs/feature-home/home-rows-and-loading.md#recently-added-watched-filtering).

## Request status

See [Request status](../../docs/feature-home/detail-and-playback.md#request-status).

## Responsibility

Responsibilities are grouped by behavior in the task map above. Start with the matching guide rather than reading every topic.

## Home loading

See [Home loading](../../docs/feature-home/home-rows-and-loading.md#home-loading).

## Showcase

See [Showcase](../../docs/feature-home/presentation-and-showcase.md#showcase).

## Detail watch-state updates

See [Detail watch-state updates](../../docs/feature-home/refresh-and-watch-state.md#detail-watch-state-updates).

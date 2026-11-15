# Where the self-build Home time actually goes

A temporary `PLZBOOT HTTP <path> ms=… bytes=…` line in `URLSessionHTTPClient`
measured the HTTP leg separately from the provider mapping. Captured on the
iPhone 17 Pro Max with the Release self-build, launched with
`PLOZZ_LOG_STDOUT=1` and `PLZBOOT_STDOUT=1`.

## Same server, same user, same query

Both apps use `https://jf.margeyshah.com`, which resolves to `192.168.0.2` on the
LAN; the host measured DNS 8.7 ms, connect 11.6 ms, TLS 35.9 ms, TTFB 40 ms.
Both speak as Jellyfin user `17a0282c1a1643c6b5e8007a98950888`. After restoring
the complementary NextUp query, the self-build sends the same Home request URLs
as TestFlight (`EnableResumable=false`; the brief-play gap is handled
client-side).

## HTTP legs vs whole row

| Request | HTTP leg | HomeAgg row |
| --- | ---: | ---: |
| `/Views` | 351 ms | `server-sections` 411 ms |
| `/Items/Latest` | 393 ms | `server-sections` 529 ms |
| `/Items/Latest` | 756 ms | `recentlyAdded` 766 ms |
| `/Items/Resume` | 523 ms | `libraries` 802 ms (row includes its own request) |

The provider mapping/decode adds only tens of milliseconds; the row time is the
HTTP time. The self-build is not spending the gap in SwiftUI or mapping.

## What the metric does not measure

`HomeAgg.request`/`fanout` times the **background network refresh**, not the
first row paint. The self-build restores Home content from its on-disk snapshot
and paints the Continue Watching cards immediately; the refresh that these
numbers time happens behind the already-visible row. TestFlight can show its
loading/empty row until its own request resolves. That is why the viewer sees
the self-build row load faster even though its `continueWatching` refresh
completes later. Do not use the aggregate below as the visible-row latency.

## Interpretation

The local server, user, and query are the same, so signing or entitlements alone
do not explain the HTTP latency. The remaining differences are client session
state:

- a separate Jellyfin `DeviceId`/session for the self-build bundle,
- separate URLSession connection history and an app data container that has been
  through many debug installs,
- a different app version from TestFlight build 72.

Cache clearing changed ~90 ms, sync-off changed nothing, the connection cap
8→12 changed nothing, and restoring TestFlight's NextUp query did not close the
gap. A matched TestFlight build of this exact commit (same bundle/session) is
the remaining experiment; it requires the release/TestFlight credentials.

The HTTP timing line was temporary and is not in the shipped build.

## Per-transfer ledger (`PLZNET_STDOUT`)

The transport now emits one line per HTTP transfer when the process is launched
with `PLZNET_STDOUT=1`:

```
PLZNET GET path=/Users/<id>/Items status=200 ms=346 bytes=560 coalesced=0 \
  route=collectionCandidates q=ParentId=9d7ad6af…,IncludeItemTypes=BoxSet,Limit=1,StartIndex=0
```

`ms` is the caller-visible transfer time, `coalesced=1` marks a caller that
joined an identical in-flight GET instead of issuing its own, and `q` is a
bounded summary of shape-defining query parameters (long id lists truncated,
tokens never included). Capture it with:

```
xcrun devicectl device process launch --device <udid> --console \
  --terminate-existing -e '{"PLZNET_STDOUT":"1","PLZBOOT_STDOUT":"1"}' \
  <bundle-id>
```

Read it next to `HomeAgg.rowReady`: the row line says how long a row took, the
ledger says which transfers composed it. The first device capture on 6313.9
showed the collection-existence probe at 346 ms (down from 701 ms after
dropping sort/fields/artwork) and `libraries` publishing at 347–484 ms instead
of waiting ~700 ms.

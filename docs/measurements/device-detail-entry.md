# Device detail-entry stall measurements

Captured on the iPhone 17 Pro Max with the Debug self-build and:

```sh
xcrun devicectl device process launch --console --terminate-existing \
  -e '{"PLZBOOT_STDOUT":"1","PLZSTALL":"1","PLZXFAN_STDOUT":"1","PLOZZ_SHOTS_NFS_HOST":"dummy-shots"}' \
  com.thatcube.Plozz.selfbuild
```

The capture rig then pushed real Home titles through the same navigation a card
tap uses (`detail?title=…`, `burstFirst?index=…`). `PLZSTALL=1` prints a
`PLZBOOT STALL <ms>ms screen=<context>` line when the main actor is unavailable
for at least 150 ms; it was not armed on iOS before this pass.

## What the measurements showed

| Entry path | Main-actor gap |
| --- | --- |
| First detail push, before the fix | `STALL 257ms screen=home` |
| Series detail push, before the fix | `STALL 331ms screen=home` |
| Same episode entry, stationary snapshot removed | `STALL 154ms screen=home` |
| Episode entry, same build rerun | no `STALL` line |
| Series entry via `burstFirst?index=40`, lazy season load | no `STALL` line |

The 154 ms episode line and the following no-`STALL` rerun are the same page,
so part of that difference is run variance; the 257/331 ms series/episode lines
before the snapshot removal were repeatable and are the primary signal. The
`burstFirst` baseline itself renders eight window frames on the main thread; a
400 ms line while capturing is capture work, not the entry path. The
non-capturing `detail?title=…` pushes are the comparison signal.

## Difference from TestFlight build 72

Two fork-only eager paths ran during the native push:

1. **Whole-page stationary snapshot.** `PlozziOSStationaryNavigationSource`
   called `snapshotView(afterScreenUpdates:)` synchronously in
   `viewWillDisappear`, then inserted the result as a sibling of the moving
   pages. Upstream navigation lets UIKit move the pages directly. Removed.
2. **Opening-season prefetch.** Production routes created the detail view model
   with `prefetchesOpeningSeason: true`, so a series started its season-list,
   then opening-season episode request during the push, duplicating the inline
   rail's own lazy load. Upstream does not prefetch. Disabled by default; the
   rail loads when the season is shown.

Our detail page uses a `LazyVStack`; upstream uses a plain `VStack`. The
remaining lazy-layout advantage is ours. The regressions above were data/entry
work, not the stack itself.

## Limits

The TestFlight app has no DEBUG capture channel, so it cannot be driven by the
same requests and does not emit `PLZSTALL`. The comparison is therefore a source
comparison against upstream plus stall measurements on the self-build, not a
matched two-app detail-entry trace. Home-load timing for both installed apps is
in [`device-home-timing.md`](device-home-timing.md) and
[`device-home-timing-release.md`](device-home-timing-release.md).

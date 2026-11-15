# Device Home-load timing diff

Captured **2026-11-15 10:44 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 5`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz TestFlight 72

- Bundle: `com.thatcube.Plozz.testflight72`
- Installed build: `2026.11.12 6190.1`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 795.1 ms | 744.0 ms | 875.1 ms |
| Launch → Home load start | 1005.0 ms | 941.3 ms | 1029.3 ms |
| Launch → Home load done | 4279.8 ms | 4139.9 ms | 5143.8 ms |
| App-side aggregate | 2583 ms | 2481 ms | 3179 ms |
| `recentlyAdded` ready | 787 ms | 632 ms | 1611 ms |
| `libraries` ready | 787 ms | 632 ms | 1009 ms |
| `watchlist` ready | 951 ms | 905 ms | 1612 ms |
| `continueWatching` ready | 2583 ms | 2481 ms | 3178 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6311.5`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 776.3 ms | 692.2 ms | 992.6 ms |
| Launch → Home load start | 984.5 ms | 916.3 ms | 1430.9 ms |
| Launch → Home load done | 4131.4 ms | 4108.9 ms | 4730.4 ms |
| App-side aggregate | 2493 ms | 2326 ms | 3138 ms |
| `recentlyAdded` ready | 995 ms | 945 ms | 1300 ms |
| `libraries` ready | 995 ms | 945 ms | 1281 ms |
| `watchlist` ready | 998 ms | 922 ms | 1339 ms |
| `continueWatching` ready | 2493 ms | 2325 ms | 3138 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Release** build; the TestFlight app is Release, so compare like configurations when drawing an optimisation conclusion.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 795.1 ms | 776.3 ms | -18.8 ms |
| Launch → Home load start | 1005.0 ms | 984.5 ms | -20.5 ms |
| Launch → Home load done | 4279.8 ms | 4131.4 ms | -148.3 ms |
| App-side aggregate | 2583 ms | 2493 ms | -90 ms |
| `recentlyAdded` ready | 787 ms | 995 ms | 208 ms |
| `libraries` ready | 787 ms | 995 ms | 208 ms |
| `watchlist` ready | 951 ms | 998 ms | 47 ms |
| `continueWatching` ready | 2583 ms | 2493 ms | -90 ms |

Both apps are locally signed sideloads on the same phone: `Plozz TestFlight 72` is source `release/072` (`313045087`, build 6190.1) and the self-build is `6311.5` (branch with parallel collection probes, bounded series-recency window, no NextUp retry). Same signing/entitlement class; separate containers. **The app-side metric is the background network refresh, not the visible row first paint.** This run was ~100–450 ms slower than the 10:07 run on both apps (network drift), so compare the deltas, not the absolutes.

The branch is at parity on the aggregate (`continueWatching`, the last row) and ahead on launch and Home-done. `recentlyAdded`/`libraries` remain ~200 ms behind because they publish together behind the shared `libraries` gate; the HTTP leg for that row is unchanged code and the residual tracks same-host contention rather than query shape.

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


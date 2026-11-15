# Device Home-load timing diff

Captured **2026-11-15 12:11 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 5`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz TestFlight 72

- Bundle: `com.thatcube.Plozz.testflight72`
- Installed build: `2026.11.12 6190.1`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 695.5 ms | 665.9 ms | 847.1 ms |
| Launch → Home load start | 855.0 ms | 795.2 ms | 1014.2 ms |
| Launch → Home load done | 3869.1 ms | 3557.5 ms | 3927.3 ms |
| App-side aggregate | 2177 ms | 1991 ms | 2461 ms |
| `recentlyAdded` ready | 615 ms | 538 ms | 712 ms |
| `libraries` ready | 615 ms | 538 ms | 712 ms |
| `watchlist` ready | 840 ms | 781 ms | 864 ms |
| `continueWatching` ready | 2177 ms | 1990 ms | 2460 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6313.11`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 741.4 ms | 685.6 ms | 907.3 ms |
| Launch → Home load start | 966.3 ms | 894.7 ms | 1146.3 ms |
| Launch → Home load done | 3691.6 ms | 3543.5 ms | 4018.9 ms |
| App-side aggregate | 2097 ms | 1853 ms | 2306 ms |
| `recentlyAdded` ready | 538 ms | 421 ms | 564 ms |
| `libraries` ready | 267 ms | 208 ms | 287 ms |
| `watchlist` ready | 749 ms | 598 ms | 796 ms |
| `continueWatching` ready | 2097 ms | 1852 ms | 2306 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Release** build; the TestFlight app is Release, so compare like configurations when drawing an optimisation conclusion.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 695.5 ms | 741.4 ms | 45.8 ms |
| Launch → Home load start | 855.0 ms | 966.3 ms | 111.3 ms |
| Launch → Home load done | 3869.1 ms | 3691.6 ms | -177.5 ms |
| App-side aggregate | 2177 ms | 2097 ms | -80 ms |
| `recentlyAdded` ready | 615 ms | 538 ms | -77 ms |
| `libraries` ready | 615 ms | 267 ms | -348 ms |
| `watchlist` ready | 840 ms | 749 ms | -91 ms |
| `continueWatching` ready | 2177 ms | 2097 ms | -80 ms |

Both apps are locally signed sideloads on the same phone: `Plozz TestFlight 72` is source `release/072` (`313045087`, build 6190.1) and the self-build is `6313.11` (branch with a shared in-flight GET coalescer, a `PLZNET` ledger, the lighter collection-existence probe, bounded series-recency lookups and the duplicate NextUp retry removed). Same signing/entitlement class; separate containers. **The app-side metric is the background network refresh, not the visible row first paint.**

The branch is ahead on every row in this run: `libraries` −348 ms (the collection probe dropped from ~700 ms to ~320 ms after it stopped asking for sort, fields and artwork), `recentlyAdded` −77 ms, `watchlist` −91 ms, the Continue Watching aggregate −80 ms and Home-done −178 ms. Launch→first telemetry is +46 ms, within the run-to-run spread on this device.

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


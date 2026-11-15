# Device Home-load timing diff

Captured **2026-11-15 10:07 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 5`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz TestFlight 72

- Bundle: `com.thatcube.Plozz.testflight72`
- Installed build: `2026.11.12 6190.1`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 763.4 ms | 707.7 ms | 1150.4 ms |
| Launch → Home load start | 913.8 ms | 899.1 ms | 1252.4 ms |
| Launch → Home load done | 3908.1 ms | 3584.1 ms | 4292.7 ms |
| App-side aggregate | 2117 ms | 2046 ms | 2696 ms |
| `recentlyAdded` ready | 647 ms | 577 ms | 678 ms |
| `libraries` ready | 647 ms | 577 ms | 678 ms |
| `watchlist` ready | 814 ms | 781 ms | 978 ms |
| `continueWatching` ready | 2117 ms | 2046 ms | 2695 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6310.1`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 848.5 ms | 679.8 ms | 1588.1 ms |
| Launch → Home load start | 1082.1 ms | 896.5 ms | 1894.0 ms |
| Launch → Home load done | 4126.2 ms | 4111.7 ms | 5384.3 ms |
| App-side aggregate | 2416 ms | 2291 ms | 2849 ms |
| `recentlyAdded` ready | 980 ms | 908 ms | 1194 ms |
| `libraries` ready | 980 ms | 908 ms | 1194 ms |
| `watchlist` ready | 964 ms | 922 ms | 1124 ms |
| `continueWatching` ready | 2416 ms | 2290 ms | 2849 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## 1:1 diff (self-build − TestFlight 72)

Both apps are locally signed sideloads on the same phone: `Plozz TestFlight 72` is source `release/072` (`313045087`, build 6190.1) and the self-build is `6310.1`. They have separate app containers but the same signing/entitlement class. This removes the TestFlight-signing advantage; residual container differences remain. **The metric is the background network refresh, not the visible row first paint.**

| Metric | TestFlight 72 | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 763 ms | 849 ms | 85 ms |
| Launch → Home load start | 914 ms | 1082 ms | 168 ms |
| Launch → Home load done | 3908 ms | 4126 ms | 218 ms |
| App-side aggregate | 2117 ms | 2416 ms | 299 ms |
| `recentlyAdded` ready | 647 ms | 980 ms | 333 ms |
| `watchlist` ready | 814 ms | 964 ms | 150 ms |
| `continueWatching` ready | 2117 ms | 2416 ms | 299 ms |

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


# Device Home-load timing diff

Captured **2026-11-15 04:19 UTC** from the iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 3`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz

- Bundle: `com.thatcube.Plozz`
- Installed build: `2026.11.12 72`
- Samples: 3

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 827.5 ms | 800.7 ms | 1668.0 ms |
| Launch → Home load start | 1002.4 ms | 992.9 ms | 1862.6 ms |
| Launch → Home load done | 3330.6 ms | 3264.4 ms | 4360.7 ms |
| App-side aggregate | 1556 ms | 1551 ms | 1669 ms |
| `recentlyAdded` ready | 413 ms | 411 ms | 511 ms |
| `libraries` ready | 414 ms | 411 ms | 511 ms |
| `watchlist` ready | 641 ms | 598 ms | 697 ms |
| `continueWatching` ready | 1556 ms | 1551 ms | 1669 ms |

Observed states: `loaded, loaded, loaded`; silent refresh: `true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6290.9`
- Samples: 3

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 848.3 ms | 695.7 ms | 976.0 ms |
| Launch → Home load start | 1046.1 ms | 931.9 ms | 1192.8 ms |
| Launch → Home load done | 3993.8 ms | 3923.6 ms | 5168.9 ms |
| App-side aggregate | 2203 ms | 2145 ms | 2913 ms |
| `recentlyAdded` ready | 790 ms | 739 ms | 818 ms |
| `libraries` ready | 751 ms | 739 ms | 790 ms |
| `watchlist` ready | 739 ms | 733 ms | 990 ms |
| `continueWatching` ready | 2203 ms | 2145 ms | 2913 ms |

Observed states: `loaded, loaded, loaded`; silent refresh: `true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Debug** build; the TestFlight app is Release, so this is a product-vs-development comparison, not a like-for-like optimisation benchmark.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 827.5 ms | 848.3 ms | 20.8 ms |
| Launch → Home load start | 1002.4 ms | 1046.1 ms | 43.7 ms |
| Launch → Home load done | 3330.6 ms | 3993.8 ms | 663.1 ms |
| App-side aggregate | 1556 ms | 2203 ms | 647 ms |
| `recentlyAdded` ready | 413 ms | 790 ms | 377 ms |
| `libraries` ready | 414 ms | 751 ms | 337 ms |
| `watchlist` ready | 641 ms | 739 ms | 98 ms |
| `continueWatching` ready | 1556 ms | 2203 ms | 647 ms |

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


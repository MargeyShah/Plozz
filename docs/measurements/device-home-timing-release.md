# Device Home-load timing diff

Captured **2026-11-15 07:07 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 5`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz

- Bundle: `com.thatcube.Plozz`
- Installed build: `2026.11.12 72`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 869.9 ms | 695.0 ms | 885.2 ms |
| Launch → Home load start | 1057.4 ms | 907.2 ms | 1174.4 ms |
| Launch → Home load done | 3271.3 ms | 3121.2 ms | 3315.3 ms |
| App-side aggregate | 1482 ms | 1393 ms | 1623 ms |
| `recentlyAdded` ready | 471 ms | 380 ms | 626 ms |
| `libraries` ready | 471 ms | 380 ms | 626 ms |
| `watchlist` ready | 697 ms | 570 ms | 737 ms |
| `continueWatching` ready | 1481 ms | 1393 ms | 1623 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6300.1`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 881.5 ms | 730.7 ms | 1056.1 ms |
| Launch → Home load start | 1084.4 ms | 964.8 ms | 1309.0 ms |
| Launch → Home load done | 3978.2 ms | 3725.2 ms | 4312.7 ms |
| App-side aggregate | 2274 ms | 2079 ms | 2370 ms |
| `recentlyAdded` ready | 707 ms | 698 ms | 919 ms |
| `libraries` ready | 698 ms | 581 ms | 919 ms |
| `watchlist` ready | 885 ms | 820 ms | 1057 ms |
| `continueWatching` ready | 2274 ms | 2078 ms | 2370 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Release** build; the TestFlight app is Release, so compare like configurations when drawing an optimisation conclusion.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 869.9 ms | 881.5 ms | 11.6 ms |
| Launch → Home load start | 1057.4 ms | 1084.4 ms | 27.0 ms |
| Launch → Home load done | 3271.3 ms | 3978.2 ms | 706.9 ms |
| App-side aggregate | 1482 ms | 2274 ms | 792 ms |
| `recentlyAdded` ready | 471 ms | 707 ms | 236 ms |
| `libraries` ready | 471 ms | 698 ms | 227 ms |
| `watchlist` ready | 697 ms | 885 ms | 188 ms |
| `continueWatching` ready | 1481 ms | 2274 ms | 793 ms |

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


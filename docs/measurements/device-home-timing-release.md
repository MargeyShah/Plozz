# Device Home-load timing diff

Captured **2026-11-15 04:41 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 3`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz

- Bundle: `com.thatcube.Plozz`
- Installed build: `2026.11.12 72`
- Samples: 3

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 989.1 ms | 818.4 ms | 1061.1 ms |
| Launch → Home load start | 1188.9 ms | 1126.5 ms | 1207.9 ms |
| Launch → Home load done | 3404.9 ms | 3253.1 ms | 3592.5 ms |
| App-side aggregate | 1567 ms | 1470 ms | 1610 ms |
| `recentlyAdded` ready | 443 ms | 377 ms | 503 ms |
| `libraries` ready | 443 ms | 377 ms | 503 ms |
| `watchlist` ready | 587 ms | 572 ms | 653 ms |
| `continueWatching` ready | 1567 ms | 1469 ms | 1602 ms |

Observed states: `loaded, loaded, loaded`; silent refresh: `true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6291.7`
- Samples: 3

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 818.3 ms | 686.6 ms | 959.7 ms |
| Launch → Home load start | 1061.9 ms | 1019.2 ms | 1107.4 ms |
| Launch → Home load done | 4133.6 ms | 3833.0 ms | 4291.8 ms |
| App-side aggregate | 2308 ms | 1933 ms | 2395 ms |
| `recentlyAdded` ready | 809 ms | 662 ms | 861 ms |
| `libraries` ready | 809 ms | 631 ms | 861 ms |
| `watchlist` ready | 823 ms | 794 ms | 1026 ms |
| `continueWatching` ready | 2307 ms | 1932 ms | 2395 ms |

Observed states: `loaded, loaded, loaded`; silent refresh: `true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Release** build; the TestFlight app is Release, so compare like configurations when drawing an optimisation conclusion.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 989.1 ms | 818.3 ms | -170.8 ms |
| Launch → Home load start | 1188.9 ms | 1061.9 ms | -127.1 ms |
| Launch → Home load done | 3404.9 ms | 4133.6 ms | 728.7 ms |
| App-side aggregate | 1567 ms | 2308 ms | 741 ms |
| `recentlyAdded` ready | 443 ms | 809 ms | 366 ms |
| `libraries` ready | 443 ms | 809 ms | 366 ms |
| `watchlist` ready | 587 ms | 823 ms | 236 ms |
| `continueWatching` ready | 1567 ms | 2307 ms | 740 ms |

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


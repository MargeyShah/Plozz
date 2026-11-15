# Device Home-load timing diff

Captured **2026-11-15 06:32 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 5`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz

- Bundle: `com.thatcube.Plozz`
- Installed build: `2026.11.12 72`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 1168.6 ms | 709.2 ms | 1558.6 ms |
| Launch → Home load start | 1369.0 ms | 918.1 ms | 1796.9 ms |
| Launch → Home load done | 3849.0 ms | 3386.1 ms | 4067.3 ms |
| App-side aggregate | 1690 ms | 1565 ms | 1988 ms |
| `recentlyAdded` ready | 532 ms | 427 ms | 560 ms |
| `libraries` ready | 532 ms | 427 ms | 560 ms |
| `watchlist` ready | 705 ms | 612 ms | 788 ms |
| `continueWatching` ready | 1690 ms | 1565 ms | 1914 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6297.1`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 1461.0 ms | 696.9 ms | 1652.9 ms |
| Launch → Home load start | 1695.2 ms | 968.4 ms | 1854.4 ms |
| Launch → Home load done | 4931.8 ms | 3808.6 ms | 5031.7 ms |
| App-side aggregate | 2610 ms | 2034 ms | 2679 ms |
| `recentlyAdded` ready | 909 ms | 702 ms | 1094 ms |
| `libraries` ready | 909 ms | 702 ms | 1094 ms |
| `watchlist` ready | 909 ms | 873 ms | 1062 ms |
| `continueWatching` ready | 2610 ms | 2034 ms | 2679 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Release** build; the TestFlight app is Release, so compare like configurations when drawing an optimisation conclusion.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 1168.6 ms | 1461.0 ms | 292.4 ms |
| Launch → Home load start | 1369.0 ms | 1695.2 ms | 326.2 ms |
| Launch → Home load done | 3849.0 ms | 4931.8 ms | 1082.8 ms |
| App-side aggregate | 1690 ms | 2610 ms | 920 ms |
| `recentlyAdded` ready | 532 ms | 909 ms | 377 ms |
| `libraries` ready | 532 ms | 909 ms | 377 ms |
| `watchlist` ready | 705 ms | 909 ms | 204 ms |
| `continueWatching` ready | 1690 ms | 2610 ms | 920 ms |

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


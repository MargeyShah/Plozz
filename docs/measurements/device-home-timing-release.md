# Device Home-load timing diff

Captured **2026-11-15 09:14 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 5`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz

- Bundle: `com.thatcube.Plozz`
- Installed build: `2026.11.12 72`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 778.5 ms | 683.4 ms | 934.0 ms |
| Launch → Home load start | 921.3 ms | 879.5 ms | 1131.2 ms |
| Launch → Home load done | 3412.4 ms | 3291.0 ms | 3911.8 ms |
| App-side aggregate | 1741 ms | 1679 ms | 2172 ms |
| `recentlyAdded` ready | 618 ms | 520 ms | 717 ms |
| `libraries` ready | 618 ms | 520 ms | 717 ms |
| `watchlist` ready | 721 ms | 715 ms | 805 ms |
| `continueWatching` ready | 1741 ms | 1679 ms | 2166 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6304.3`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 754.3 ms | 749.7 ms | 791.2 ms |
| Launch → Home load start | 997.6 ms | 972.2 ms | 1026.4 ms |
| Launch → Home load done | 4586.0 ms | 4021.8 ms | 4720.3 ms |
| App-side aggregate | 2803 ms | 2286 ms | 2902 ms |
| `recentlyAdded` ready | 1036 ms | 857 ms | 1160 ms |
| `libraries` ready | 1036 ms | 857 ms | 1160 ms |
| `watchlist` ready | 1021 ms | 929 ms | 1148 ms |
| `continueWatching` ready | 2802 ms | 2286 ms | 2902 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Release** build; the TestFlight app is Release, so compare like configurations when drawing an optimisation conclusion.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 778.5 ms | 754.3 ms | -24.2 ms |
| Launch → Home load start | 921.3 ms | 997.6 ms | 76.3 ms |
| Launch → Home load done | 3412.4 ms | 4586.0 ms | 1173.6 ms |
| App-side aggregate | 1741 ms | 2803 ms | 1062 ms |
| `recentlyAdded` ready | 618 ms | 1036 ms | 418 ms |
| `libraries` ready | 618 ms | 1036 ms | 418 ms |
| `watchlist` ready | 721 ms | 1021 ms | 300 ms |
| `continueWatching` ready | 1741 ms | 2802 ms | 1061 ms |

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


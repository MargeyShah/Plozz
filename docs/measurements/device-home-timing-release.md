# Device Home-load timing diff

Captured **2026-11-15 06:19 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 5`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz

- Bundle: `com.thatcube.Plozz`
- Installed build: `2026.11.12 72`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 721.2 ms | 641.4 ms | 984.9 ms |
| Launch → Home load start | 915.3 ms | 828.1 ms | 1146.7 ms |
| Launch → Home load done | 3184.0 ms | 3059.7 ms | 3505.5 ms |
| App-side aggregate | 1562 ms | 1475 ms | 1759 ms |
| `recentlyAdded` ready | 442 ms | 412 ms | 754 ms |
| `libraries` ready | 442 ms | 412 ms | 754 ms |
| `watchlist` ready | 683 ms | 597 ms | 950 ms |
| `continueWatching` ready | 1562 ms | 1475 ms | 1759 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6296.1`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 742.9 ms | 692.6 ms | 892.8 ms |
| Launch → Home load start | 996.0 ms | 887.1 ms | 1100.6 ms |
| Launch → Home load done | 4024.3 ms | 3696.3 ms | 4263.7 ms |
| App-side aggregate | 2418 ms | 2045 ms | 2583 ms |
| `recentlyAdded` ready | 776 ms | 609 ms | 1177 ms |
| `libraries` ready | 776 ms | 609 ms | 1177 ms |
| `watchlist` ready | 818 ms | 742 ms | 1141 ms |
| `continueWatching` ready | 2417 ms | 2045 ms | 2583 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Release** build; the TestFlight app is Release, so compare like configurations when drawing an optimisation conclusion.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 721.2 ms | 742.9 ms | 21.7 ms |
| Launch → Home load start | 915.3 ms | 996.0 ms | 80.7 ms |
| Launch → Home load done | 3184.0 ms | 4024.3 ms | 840.2 ms |
| App-side aggregate | 1562 ms | 2418 ms | 856 ms |
| `recentlyAdded` ready | 442 ms | 776 ms | 334 ms |
| `libraries` ready | 442 ms | 776 ms | 334 ms |
| `watchlist` ready | 683 ms | 818 ms | 135 ms |
| `continueWatching` ready | 1562 ms | 2417 ms | 855 ms |

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


# Home-load timing after clearing the self-build cache

Captured **2026-11-15 07:15 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 5`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz

- Bundle: `com.thatcube.Plozz`
- Installed build: `2026.11.12 72`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 743.6 ms | 723.3 ms | 812.6 ms |
| Launch → Home load start | 938.9 ms | 918.2 ms | 1007.6 ms |
| Launch → Home load done | 3123.6 ms | 3080.6 ms | 3435.6 ms |
| App-side aggregate | 1488 ms | 1334 ms | 1815 ms |
| `recentlyAdded` ready | 457 ms | 407 ms | 641 ms |
| `libraries` ready | 457 ms | 407 ms | 641 ms |
| `watchlist` ready | 695 ms | 594 ms | 838 ms |
| `continueWatching` ready | 1488 ms | 1334 ms | 1815 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6300.1`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 767.3 ms | 720.8 ms | 1014.8 ms |
| Launch → Home load start | 1001.5 ms | 948.8 ms | 1219.6 ms |
| Launch → Home load done | 4067.0 ms | 3781.0 ms | 4517.7 ms |
| App-side aggregate | 2184 ms | 2138 ms | 2803 ms |
| `recentlyAdded` ready | 683 ms | 537 ms | 1130 ms |
| `libraries` ready | 683 ms | 519 ms | 1130 ms |
| `watchlist` ready | 826 ms | 804 ms | 1125 ms |
| `continueWatching` ready | 2183 ms | 2138 ms | 2802 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Release** build; the TestFlight app is Release, so compare like configurations when drawing an optimisation conclusion.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 743.6 ms | 767.3 ms | 23.8 ms |
| Launch → Home load start | 938.9 ms | 1001.5 ms | 62.7 ms |
| Launch → Home load done | 3123.6 ms | 4067.0 ms | 943.4 ms |
| App-side aggregate | 1488 ms | 2184 ms | 696 ms |
| `recentlyAdded` ready | 457 ms | 683 ms | 226 ms |
| `libraries` ready | 457 ms | 683 ms | 226 ms |
| `watchlist` ready | 695 ms | 826 ms | 131 ms |
| `continueWatching` ready | 1488 ms | 2183 ms | 695 ms |

## Provenance

Before this run the self-build's `Caches/Plozz` index and `URLCache` were cleared
through a temporary DEBUG capture request, then the clean Release 6300.1 build
was reinstalled. The app data/session were preserved. The self-build Home
aggregate median is 2184 ms vs TestFlight 1488 ms; the cache clear accounts for
roughly 90 ms of the earlier 2274 ms, not the remaining ~700 ms. The residual is
the separate self-build container/server session, not branch code.

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


# Upstream-code Home-load timing diff

Captured **2026-11-15 06:57 UTC** from iPhone 17 Pro Max with `python3 tools/device-timing-diff.py --runs 5`.

Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same `HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start immediately before `devicectl`; app-side row times are the app's own millisecond measurements from `HomeVM.load START`.

## Plozz

- Bundle: `com.thatcube.Plozz`
- Installed build: `2026.11.12 72`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 658.5 ms | 611.3 ms | 817.7 ms |
| Launch → Home load start | 824.6 ms | 801.0 ms | 1015.4 ms |
| Launch → Home load done | 3411.4 ms | 3162.6 ms | 3688.9 ms |
| App-side aggregate | 1808 ms | 1671 ms | 1904 ms |
| `recentlyAdded` ready | 569 ms | 482 ms | 712 ms |
| `libraries` ready | 569 ms | 482 ms | 712 ms |
| `watchlist` ready | 741 ms | 693 ms | 867 ms |
| `continueWatching` ready | 1759 ms | 1669 ms | 1903 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Plozz Self-build

- Bundle: `com.thatcube.Plozz.selfbuild`
- Installed build: `2026.11.12 6219.3`
- Samples: 5

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 792.0 ms | 715.7 ms | 827.7 ms |
| Launch → Home load start | 941.1 ms | 828.0 ms | 1029.8 ms |
| Launch → Home load done | 3830.7 ms | 3595.8 ms | 5324.3 ms |
| App-side aggregate | 2228 ms | 1982 ms | 3568 ms |
| `recentlyAdded` ready | 645 ms | 559 ms | 1398 ms |
| `libraries` ready | 645 ms | 559 ms | 1398 ms |
| `watchlist` ready | 860 ms | 827 ms | 1140 ms |
| `continueWatching` ready | 2228 ms | 1982 ms | 3567 ms |

Observed states: `loaded, loaded, loaded, loaded, loaded`; silent refresh: `true, true, true, true, true`; accounts: `1`.

## Diff (self-build − TestFlight)

Positive values mean the self-build was slower on this run. The self-build is a **Release** build; the TestFlight app is Release, so compare like configurations when drawing an optimisation conclusion.

| Metric | TestFlight | Self-build | Delta |
| --- | ---: | ---: | ---: |
| Launch → first telemetry | 658.5 ms | 792.0 ms | 133.5 ms |
| Launch → Home load start | 824.6 ms | 941.1 ms | 116.5 ms |
| Launch → Home load done | 3411.4 ms | 3830.7 ms | 419.2 ms |
| App-side aggregate | 1808 ms | 2228 ms | 420 ms |
| `recentlyAdded` ready | 569 ms | 645 ms | 76 ms |
| `libraries` ready | 569 ms | 645 ms | 76 ms |
| `watchlist` ready | 741 ms | 860 ms | 119 ms |
| `continueWatching` ready | 1759 ms | 2228 ms | 469 ms |

## Provenance

The self-build column in this report was built from `upstream/main` `369b8ce98`
as a Release self-build and installed over the same `com.thatcube.Plozz.selfbuild`
bundle, so it kept the same app data container and Jellyfin session as the branch
self-build. The TestFlight app remains a separate install. This isolates the
branch code from the container/session: upstream code on the self-build is still
~420 ms slower than TestFlight, while branch code adds a smaller amount on top.

## Method notes

- The app data containers are independent. Each run starts from the state the installed app had before launch; `--terminate-existing` removes the process but not the disk snapshot.
- The launch wall time includes CoreDevice hand-off and the app's first telemetry line; the app-side aggregate/row times exclude that overhead and are the better comparison.
- A missing `HomeAgg.fanout` marker is recorded as an incomplete run and left out of the median rather than treated as zero.
- These are one-device, one-network samples, not a battery/thermal or scroll-smoothness result.


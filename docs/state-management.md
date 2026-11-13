# State management and cross-platform coordination


## Layer ownership

| Layer | Owns |
| --- | --- |
| `Feature*Core` | Observable state models, coordinators, decision logic, platform profiles, harness-facing seams. |
| `AppRuntime` | Process-scoped services, lifecycle aggregation, other runtime seams. |
| `CoreUI` | Shared presentation and environment injection only. |
| `Feature*` / `AppShelliOS` | SwiftUI wiring, surface registration, view-only state. |
| `AppShell` / `AppShelliOS` roots | Composition, coordinator injection, platform lifecycle adapters. |

Views may own ephemeral presentation state. They may not own cross-screen timing,
platform thresholds, or provider refresh policy.

4. **Inject at the root.** Use `@State` ownership in the app root and
   `@Environment` for shared access.
5. **Register the visible surface.** Only the top/visible surface receives work.
   The view supplies its stable identity, not its timing.
6. **Build a deterministic harness.** Use a fake clock and synthetic lifecycle
   transitions. Do not rely on UI timing or wall-clock sleeps.
7. **Test every platform profile.** The same scenario matrix should run for
   tvOS and iOS behavior.

## Content refresh coordinator

`ContentRefreshCoordinator` in `FeatureHomeCore` is the reference implementation.

- `ContentRefreshProfile` owns the tvOS/iOS timing and action mapping.
- Views call `.contentRefreshSurface(...)` with a stable identity and visibility.
- `ContentRefreshLifecycleReader` translates app activation into coordinator
  events. UIKit notifications are used instead of relying on a coalesced
  SwiftUI `scenePhase` change across suspend/resume.

Do not add a second foreground-refresh mechanism beside the coordinator.

## Test constants and fixtures


- lifecycle durations (`shortAway`, `longAway`, thresholds),
- surface identities and expected actions,
- item/account IDs and season/episode numbers,
- shared expected labels.


## Comments and single-source-of-truth values

Comments explain why and what must remain true. They do not restate the current
formatted output. When the exact text matters, name the owner (for example
`MediaItem.seasonEpisodeLabel`) or the owner's test.

A shared format change should edit the owner and its test, not every call site
comment or unrelated test that happens to quote an example. If a small format
change expands into dozens of files, fix ownership before changing the format.

## Pull-request scope

- One owner change plus call-site substitutions.
- Do not update unrelated comments merely to restate a new value.
- Split rules/documentation work from feature work.
- Keep generated Xcode projects and unrelated files out of the diff.

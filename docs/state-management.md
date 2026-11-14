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

## Home first paint and refresh retention

Home renders from a persisted snapshot before the network answers, and the rules
that keep that first paint stable are part of the contract, not incidental
polish. Measured regressions these rules exist to prevent: a hero that paints
then blanks to its no-image cover, a carousel that collapses from eight slides
to three and reseats, and a Continue Watching row that empties under the viewer.

- **Skeleton only without a snapshot.** `PlozziOSHomeView` paints the full-page
  skeleton only when `HomeViewModel.hasPersistedSnapshot` is false. With a
  snapshot on disk the page paints it on the frame it appears. Never gate this on
  elapsed time.
- **A fold never takes the loud path.** A `reloadHome` that arrives at
  `.idle`/`.loading`/`.failed` against a page that has already shown content
  refreshes silently (`load(showLoadingState: false)`), so the settled rows and
  hero stay on screen until replacements are ready.
- **Empty results are not evidence.** A per-account aggregate, a hero curation,
  or a snapshot write that returns nothing cannot clear content that is already
  shown. The row keeps its cards until a completed load says otherwise, and
  `HomeSnapshotPersistence` preserves the previous Continue Watching row when the
  new one is empty because other rows succeeded (that write is not an empty
  aggregate, so nothing else would have stopped it).
- **Snapshots are not pruned on unknown state.** `HomeViewModel.init` only
  prunes for an empty account list once accounts have resolved *and* a live load
  has completed; before that, an empty list means "not loaded yet", and pruning
  there (including `scheduleSnapshotClear`) destroyed the snapshot the next launch
  paints from.
- **Hero stability.** `heroItems` is replaced only by a non-empty curation, the
  visible set keeps `.unrestricted` eligibility until `hasCompletedLiveLoad`, and
  the slide is reseated by title identity so a copy arriving with a new id does
  not move the viewer. A decoded image is applied synchronously on first paint and
  art is retained across a reference change.
- **Continue Watching is not gate-kept behind the aggregate.** Cached cards stay
  painted while the fresh multi-account result lands.

These paths carry opt-in telemetry (`HOMESEED`, `HOMEFRAME`, `HEROFRAME`,
`HOMECAROUSEL`, `HEROARTREF`, `HOMECW`, `DETAILVIEW`, `DETAILRAIL`,
`DETAILRETURN`). It is silent unless the process is launched with
`PLZXFAN_STDOUT=1`; the lines print counts, kinds and hashes, never titles, ids or
URLs.


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

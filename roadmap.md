# Roadmap: Multi-Select App Uninstaller

## Context

PureMac's uninstaller currently works one app at a time: the left pane is a single-selection `Table` of installed apps, and selecting an app wipes and rescans state (`AppState.scanForAppFiles`) so the details pane shows only that app's related files. Uninstalling several apps means repeating select → scan → review → remove N times.

This feature makes the left pane **multi-select** and shows **all selected apps' related files together in the details pane, organized into per-app sections** (each section keeps the existing Caches / Preferences / … buckets). One combined file selection drives the toolbar `Uninstall (N files)` button and the action bar, so a whole batch can be reviewed and trashed in one confirmation.

**Process:** new branch, TDD throughout — every behavior milestone starts with failing XCTest cases (leveraging `AppState`'s existing injected `appFileScanner` / `appFileTrasher` seams), then the minimal implementation to make them pass.

## Decisions

Agreed with the user:

1. **Shared files** (found by more than one app's scan) are **deduplicated — the first-scanned app owns them**. The file appears exactly once; uninstall size/count naturally counts it once (`selectedFiles` is a `Set`).
2. **Deselecting an app** immediately drops its section from the details pane **and** its files from the pending uninstall selection. Re-selecting triggers a fresh rescan.
3. **Scans run sequentially, progressively**: apps scan one after another in name order; each app's section appears as soon as its scan completes, with a "Scanning 2 of 5 apps…" status. (Parallel/bounded-parallel scanning is explicitly out of scope for v1.)

Design defaults (flagged, changeable):

4. **Finder Services hand-off** ("Uninstall with PureMac" right-click) **replaces** the current selection with that single app — preserving today's behavior. If the app is already in the selection, it is force-rescanned in place instead.
5. **Section display order = app-name order**, matching the table's default sort, and equal to scan order — so "first-scanned wins" attribution is deterministic and visible.
6. **Per-app state is keyed by `bundleIdentifier`**, not `InstalledApp.id` — the id is a fresh random UUID on every `loadInstalledApps()`, so id-keyed state would silently orphan scanned files after a Refresh.

## Architecture

### State model — `PureMac/ViewModels/AppState.swift`

| Property | Type | Role |
|---|---|---|
| `selectedAppBundleIDs` | `@Published Set<String>` | Source of truth for which apps are selected (stable across refreshes) |
| `selectedAppSnapshots` | `[String: InstalledApp]` (private) | Icon/name/bundle for section headers; also covers apps arriving via Finder hand-off that aren't in `installedApps` |
| `discoveredFilesByApp` | `@Published [String: [URL]]` | Source of truth: bundle ID → sorted files, per app |
| `discoveredFiles` | **computed** `[URL]` | Sorted union of all per-app lists. Becomes a derived value so the dict can't drift from the flat list; existing readers (toolbar count, size-cache task, `currentAppFileSearchLocationCount` fallback) keep working unchanged |
| `scansCompleted` / `scansTotal` | `@Published Int` | Progress for "Scanning N of M apps…" (best-effort; reset each selection-change run) |
| `lastFailedRemovalAppNames` | `@Published [String]` | Frozen alongside the existing `lastFailedRemovalURLs` snapshot, so the FDA retry headline can't be poisoned by later selection edits |
| `scanQueue` / `scanGenerations` | private `[String]` / `[String: UUID]` | Sequential scan queue; per-app generation tokens so stale async completions are dropped |

`selectedApp`, `selectedFiles`, `isScanningAppFiles`, `isRemovingAppFiles`, `removalError`, `removalNeedsFullDiskAccess`, `lastFailedRemovalURLs` all keep their meaning; `isScanningAppFiles` becomes "any app scan in flight", which preserves the existing `canRunScheduledScan` gating.

### Core methods

```swift
/// Set the multi-selection. Diffs against current selection: dropped apps lose
/// their files/selection and any pending scan; newly added apps (name-sorted)
/// are queued for sequential scans. A no-op set does nothing.
func selectApps(_ apps: [InstalledApp])

/// Force-rescan ONE app, replacing only its entry (others' files untouched).
/// Keeps the existing single-app API and its tests intact; used by the
/// Finder hand-off and available for a future "Rescan" action.
func scanForAppFiles(_ app: InstalledApp)

private func dropApp(_ bundleID: String)          // remove dict entry, subtract from selectedFiles, drop snapshot, invalidate pending scan
private func startNextScan()                       // pop queue, bump generation, run injected scanner
private func applyRemovedAppFiles(_ urls: [URL])   // now removes urls from EVERY app's list
private func pruneMissingInstalledApps()           // pruned apps are dropped like a deselect
```

**Scan completion logic:** on completion, drop the result if the generation is stale or the app was deselected mid-scan. Otherwise dedupe against URLs already owned by other apps (first-scanned wins), store the sorted remainder in `discoveredFilesByApp[id]`, and auto-select it (`selectedFiles.formUnion`) — matching today's select-all-on-scan behavior. Then advance the queue; when it's empty, `isScanningAppFiles = false` and the location ticker resets.

**Removal:** `removeSelectedFiles(confirmedURLs:)` is untouched in shape — it operates on URL sets and already handles the trash, FDA detection, admin escalation, high-risk dotpath guard, and the frozen-retry snapshot. Only `applyRemovedAppFiles` and `pruneMissingInstalledApps` change to iterate per-app lists.

**FDA retry context** — `PermissionCoordinator.PromptContext.uninstall` generalizes from a single app name to:

```swift
case uninstall(appNames: [String], failedCount: Int)
// headline: 1 app  → "Uninstalling %@: %lld file(s) need Full Disk Access"  (existing key)
// headline: N apps  → "Uninstalling %lld apps: %lld file(s) need Full Disk Access"  (new key)
```

`AppState.finishRemoval` attributes the failed URLs to their owning apps via `discoveredFilesByApp` and freezes `lastFailedRemovalAppNames`; `AppFilesView` passes those names into the retry context.

### Views

**`PureMac/Views/Apps/AppListView.swift`**
- `@State selection: Set<InstalledApp.ID>` on the existing `Table` — ⌘-click and ⇧-click multi-select come free from SwiftUI's `Table`.
- `.onChange(of: selection)` → map IDs to `InstalledApp`s → `appState.selectApps(apps)` (the internal diff makes repeat changes no-ops, so programmatic syncs can't loop).
- `.onChange(of: appState.selectedAppBundleIDs)` and `.onChange(of: appState.installedApps)` → remap the table highlight to the current UUIDs (refresh assigns new UUIDs; bundle-ID state survives, the highlight must follow).
- Toolbar `Uninstall (N files)` button and Refresh button unchanged.

**`PureMac/Views/Apps/AppFilesView.swift`** — restructured into per-app sections:
- No apps selected → existing "Select an App" empty state.
- One or more selected → a list of **app sections** in name order. Each section reuses the existing header-card look (icon, name, bundle ID, count, size) plus the existing `LeftoverGroup` `DisclosureGroup`s and `FileRow`s, scoped to that app's URLs, with small per-app **Select All / Deselect All** buttons in the section header.
- The in-flight scan shows as a placeholder section with a progress indicator; completed sections appear progressively.
- The bottom **action bar** is unchanged in behavior: global Select All / Deselect All over the union, and the combined `Remove N files (size)` button with the existing confirmation dialog.
- **`removeSingleFile` fix:** currently does `selectedFiles = [url]`, which would wipe other apps' selections — it becomes "confirm, then `removeSelectedFiles(confirmedURLs: [url])`".
- The size-cache `.task(id: appState.discoveredFiles)` and the FDA-retry `.onChange` keep working; the retry now passes `lastFailedRemovalAppNames`.
- Per-section `.id(bundleID)` and per-app `collapsedGroups: [String: Set<LeftoverGroup>]` keep disclosure state independent per app.

**`FileRow`, `LeftoverGroup`, `AppPathFinder`** — unchanged. The multi-select feature orchestrates existing per-app scans; the heuristic engine itself is untouched.

### Localization

Two new user-facing keys, added to **all 11** `lproj/Localizable.strings` files (the parity test in `LocalizationFilesTests` requires every English key in every locale, with matching format specifiers; English values are acceptable placeholders in non-English locales):

- `"Scanning %lld of %lld apps..."`
- `"Uninstalling %lld apps: %lld file(s) need Full Disk Access"`

The `README.md` Uninstaller section gains a line: select multiple apps (⌘-click / ⇧-click) to review and uninstall them together, with related files grouped by app.

## TDD milestones

Each milestone: write the tests (red) → implement (green) → commit. Test file: new `PureMacTests/AppStateMultiUninstallTests.swift` (reusing the `StubLocations` + injected-scanner patterns from `AppStateTests.swift`).

**M0 — Branch + project regen.** `git checkout -b feature/multi-select-uninstall`; `xcodegen generate` (new files are picked up automatically; CI does the same).

**M1 — Multi-select state + sequential scanning.**
- `testSelectingMultipleAppsScansThemSequentially`: stub scanner records call order; `selectApps([A, B])` scans A first, B only after A completes; after both, `discoveredFilesByApp` holds both, `discoveredFiles` is the sorted union, all files auto-selected.
- `testAlreadyScannedAppIsNotRescannedWhenStillSelected`: `selectApps([A])` + complete, then `selectApps([A, B])` → scanner invoked only for B.
- `testReselectingDeselectedAppRescansIt`: A scanned, B selected (A dropped), A re-selected → A scanned again with fresh results.
- `testScanningProgressAndFlags`: `isScanningAppFiles` true while any scan pending; `scansCompleted`/`scansTotal` track progress; both settle when the queue drains.
- → Implement: new state, `selectApps`, `dropApp`, `startNextScan`, computed `discoveredFiles`, progress counters.

**M2 — Deselection + stale completions.**
- `testDeselectingAppRemovesItsFilesFromPaneAndSelection`: both scanned, `selectApps([A])` → B's list gone from dict, union, and `selectedFiles`.
- `testStaleCompletionForDeselectedAppIsDiscarded`: A in flight, deselect A, fire A's completion → nothing added anywhere; B's completion still lands.
- `testForceRescanReplacesOnlyThatAppsEntry`: `scanForAppFiles(A)` after B is scanned → A's entry replaced, B untouched (supersedes the old single-app wipe semantics).
- → Implement: generation invalidation in `dropApp`, completion guards, per-app `scanForAppFiles`.

**M3 — Shared files + removal across apps.**
- `testSharedFileAttributedToFirstScannedApp`: A → `{x, shared}`, B → `{y, shared}` → `shared` only in A's list, union contains it once.
- `testRemovingFilesAcrossAppsUpdatesAllSections`: trasher removes URLs spanning A and B → both per-app lists and `selectedFiles` updated, with the existing reduce-motion-aware animation.
- `testPruningUninstalledAppDropsItFromSelection`: `installedApps` loses B's bundle on disk → B removed from `selectedAppBundleIDs`, dict, and `selectedFiles`; A unaffected.
- → Implement: dedupe-on-completion, cross-app `applyRemovedAppFiles`, new `pruneMissingInstalledApps`.

**M4 — FDA retry across apps.**
- `testFailedRemovalSnapshotCapturesOwningAppNames`: multi-app failed batch → `lastFailedRemovalAppNames` frozen with the owning app names.
- Update `testFullDiskAccessRetryKeepsUninstallInTrashFlow` for `uninstall(appNames:)`.
- New `PermissionCoordinator` headline test: 1 app → old string; N apps → new string.
- → Implement: context generalization, `finishRemoval` attribution, `AppFilesView` wiring, new localization key in all 11 lproj files.

**M5 — Views + docs (manual-verification milestone; no unit tests for views in this repo).**
- `AppListView` multi-select wiring + refresh remapping.
- `AppFilesView` section layout, per-app select controls, scanning placeholder, `removeSingleFile` fix.
- Localization keys in all 11 `lproj/Localizable.strings`; README update.

## Verification

Full suite (same as CI):

```sh
xcodegen generate
xcodebuild -project PureMac.xcodeproj -scheme PureMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build-tests CODE_SIGNING_ALLOWED=NO test
```

Manual UI checklist:
1. ⌘-click and ⇧-click select several apps; sections appear progressively with the "Scanning N of M apps…" line.
2. Deselect an app → its section and its file selection vanish instantly; re-select → fresh scan.
3. A file shared by two selected apps (e.g. a shared vendor cache) appears exactly once, under the first app.
4. Row-level trash with multiple apps selected removes only that file; the other apps' selections survive.
5. Global and per-app Select All / Deselect All behave as expected; confirmation dialog shows the combined count/size.
6. Failed FDA batch spanning two apps → sheet headline "Uninstalling 2 apps: …"; grant → frozen batch retried.
7. Fully uninstalling one selected app prunes its row and selection; remaining apps' state is untouched.
8. Finder right-click "Uninstall with PureMac" replaces the current selection; if the app is already selected, it rescans in place.
9. Refresh (new app UUIDs) preserves the selection and sections via bundle-ID remapping.
10. Reduce Motion: transitions collapse to opacity; everything still functional.
11. Localization parity test passes; spot-check one non-English locale renders the new strings.

## Out of scope

Parallel or bounded-parallel scanning; a dedicated "Shared Files" section; per-app sensitivity levels; per-app rescan button (the method exists for it); the `cli/` tool.

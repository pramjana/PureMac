# Code Review — Multi-Select App Uninstaller

- **Reviewer**: Code Reviewer (Maestri Engineering Team)
- **Reviewed ref**: `feature/multi-select-uninstall` @ `43a9417` (feat(uninstaller): implement multi-select batch app uninstaller)
- **Baseline**: `main`
- **Spec**: `docs/adr-proposal.md` (Architectural Decision Record — Alternative 4, "Sequential Progressive + BundleID Indexing")
- **Review date**: 2026-09-21
- **Verdict**: 🔴 **REQUEST CHANGES**

---

## 1. Executive Summary

The feature is a faithful, well-structured implementation of the ADR's Alternative 4. The state model is cleanly keyed by `bundleIdentifier`, `discoveredFiles` is correctly derived, the generation-token staleness guard is correctly designed and tested, the row-trash selection wipe bug the ADR called out is fixed, the FDA retry flow is properly generalized and frozen, and all 11 locales plus the parity test are in sync. Build is clean relative to baseline, and the full suite passes (114/114, of which 12 are new `AppStateMultiUninstallTests`).

However, the review found **one blocking defect**: the ADR's own Finder Services hand-off path (`scanForAppFiles`) can be invoked *while a sequential multi-app scan queue is still running*. The force-rescan bypasses the queue, which (a) runs two+ scans concurrently — directly violating the sequential-scan invariant the ADR explicitly rejected alternatives for (§2.3 / §2.4), (b) prematurely resets `isScanningAppFiles`/desyncs `scansCompleted`/`scansTotal`, and (c) in a narrow interleaving, leaves queued apps permanently unscanned. Both behaviors were **reproduced empirically** with deterministic unit tests against the actual `AppState` (findings F1.1/F1.2 below). This path is exactly ADR verification gate 8 ("Finder right-click → if already selected, force-rescans in place") and is untested.

One P2 (progress counters desync when apps are added mid-batch) and several P3 nits (Set mutation during enumeration, non-`@Published` snapshot store, stale snapshots after refresh, redundant logger hops) are also reported. None of the P2/P3 items block merge on their own; all are cheap to fix alongside F1.

---

## 2. Verdict

```
Verdict:          REQUEST CHANGES
Blocking issues:  1  (P1 — concurrent-scan / queue-stall via scanForAppFiles mid-batch)
Tests:            114/114 pass (12 new); 0 failures
Warnings:         0 new warnings introduced by this diff (baseline parity, see §6)
```

**Blocking rationale**: F1 breaks two invariants the ADR treats as first-class requirements — strictly sequential scanning (§2.3, NFR §5.2) and deterministic first-scanned-wins attribution (§2.4) — in a user-reachable flow that the ADR itself wires up (M5 gate 8, `applyExternalUninstall`). The impact is silent: a user who ⌘-selects several apps and then right-clicks one in Finder can end up with concurrent scans, an incorrect "Scanning…" ticker, nondeterministic shared-file ownership, and possibly apps whose sections never materialize. This must be fixed and covered by tests before merge.

---

## 3. Scope & What Was Reviewed

| Area | File(s) | Verdict |
|---|---|---|
| State model & queue | `PureMac/ViewModels/AppState.swift` | ⚠️ F1 (blocking), F2, F3, F4, F5 |
| Presentation | `PureMac/Views/Apps/AppFilesView.swift`, `AppListView.swift` | ✅ clean; F1 manifests here |
| Permission/FDA | `PureMac/Services/PermissionCoordinator.swift` | ✅ correct generalization |
| Tests | `PureMacTests/AppStateMultiUninstallTests.swift` (new), `AppStateTests.swift` (updated) | ⚠️ gaps (see §7) |
| Localization | 11× `Localizable.strings` | ✅ parity preserved |
| Docs | `docs/adr-proposal.md`, `roadmap.md`, `README.md` | ✅ accurate |
| Project | `project.pbxproj` (+`.`gitignore`) | ✅ test file wired correctly |

---

## 4. Detailed Findings

### 🔴 F1 (P1, blocking) — `scanForAppFiles` bypasses the sequential queue and can break the scan batch

**Location**: `PureMac/ViewModels/AppState.swift:411–461` (`scanForAppFiles`), triggered via `applyExternalUninstall` at `AppState.swift:273–280`.

**Context**: `selectApps([A, B, C])` pops A, starts the queue scan, and leaves `[B, C]` queued. If the user right-clicks an **already-selected** app in Finder ("Uninstall with PureMac"), `applyExternalUninstall` calls `scanForAppFiles(A)`:
- `scanForAppFiles` runs the scanner *immediately* and out-of-band from `scanQueue` (`scanQueue.removeAll { $0 == A }` does not touch B/C; `startNextScan()` is never involved).
- Its completion handler (lines 449–451) sets `isScanningAppFiles = false`, `currentlyScanningBundleID = nil` **without advancing the queue** — so the batch's "scan in progress" signal is killed while B/C are still pending.

**Confirmed consequences** (reproduced with deterministic scratch tests against the real `AppState` in this review; repro harness omitted from the repo):

1. **F1.1 — Concurrent scans** (violates ADR §2.3 sequential I/O contention design and §5.2). Trace: `selectApps([A,B])` → A1 in flight → `scanForAppFiles(A)` → a second A2 scan starts while A1 is still running. Two scans are simultaneously traversing disk. The ADR explicitly rejected parallel scanning for exactly this (thermal throttling / APFS cache saturation / beachballing). ⚠️ **Attribution nondeterminism**: with two scans live, "first-scanned wins" (§2.4) is decided by *completion order*, not the ADR's mandated lexicographic scan order — a shared file between A and B can flip owners between runs.

2. **F1.2 — Premature `isScanningAppFiles = false` / progress desync**. After A2 completes: `isScanningAppFiles == false`, `scansCompleted == 1` but `scansTotal == 3`, and the ticker disappears while B/C are still queued. Verified output: `scanCalls=3, isScanningAppFiles=false, completed=1/3`.

3. **F1.3 — Silent queue stall (narrow interleaving)**: if the rescan is the only live scan and the queue still holds not-yet-popped items (queue advancement happens *only* inside `handleScanCompletion`), the queued apps are never rescanned — their sections never appear and their files are never discovered/selected. The queue is only restarted incidentally when some *other* queued completion happens to fire.

**Fix direction (for the Developer)**: either (i) route force-rescans through the queue (re-queue the bundle at the front, bump generation, `startNextScan()`), or (ii) guard `scanForAppFiles` to be a no-op while a multi-app batch is active, or (iii) if in-place rescan is kept, invalidate/drain `scanQueue` and end the rescan completion with `startNextScan()` so the invariant "queue always advances" holds, plus reconcile `scansCompleted/scansTotal`. Add unit tests: (a) rescan while queue active must never run a second concurrent scan; (b) after rescan, remaining queued apps are still scanned with correct counters.

---

### 🟠 F2 (P2) — Progress counters desync when apps are added mid-batch

**Location**: `AppState.swift:315–316` (`selectApps`).

`scansTotal = scanQueue.count + newQueueItems.count; scansCompleted = 0` — but if apps are added while a scan is **already in flight** (⌘-clicking more apps mid-batch), the in-flight app's completion later increments `scansCompleted` past this reset window, so the ticker can read "Scanning 3 of 2 apps…" (the view clamps with `min(...)`, so it degrades to a wrong-but-not-crashing label). The ADR's "Scanning N of M apps..." contract is best-effort, hence P2 not P1; fix by tracking completed count relative to the current batch (e.g. reset only when starting a new batch from idle, or store a per-batch base).

---

### 🟡 F3 (P3) — `pruneMissingInstalledApps` mutates a `Set` while enumerating it

**Location**: `AppState.swift:758–771`.

```swift
for bundleID in selectedAppBundleIDs {
    if let snapshot = selectedAppSnapshots[bundleID], !fileManager.fileExists(...) {
        dropApp(bundleID)   // removes from selectedAppBundleIDs during iteration
    }
}
```

Mutation during `Set` enumeration is formally undefined behavior per the Swift language rules. Empirically the current stdlib does not trap for remove-current-element patterns (verified with a standalone harness: all elements visited, no crash), so the new `testPruningUninstalledAppDropsItFromSelection` passes — but this is a latent trap that can crash or mis-iterate on future stdlib changes. Cheap fix: snapshot the IDs first (`Array(selectedAppBundleIDs)`).

---

### 🟡 F4 (P3) — `selectedAppSnapshots` is not `@Published`

**Location**: `AppState.swift:107`.

The snapshot store is `private(set) var` (non-`@Published`). Mutations never emit `objectWillChange`; the view only updates today because every mutation site also touches a `@Published` property in the same call (`selectedAppBundleIDs`, `discoveredFilesByApp`). This is fragile — a future edit that only mutates snapshots will silently not re-render. Recommend `@Published` (or a documented invariant that snapshot writes must be paired with a published write). Also, `AppFilesView.selectedApps` reads snapshots directly — consider a published accessor.

---

### 🟡 F5 (P3) — Stale snapshots after Refresh

**Location**: `AppState.swift:287–291` (`selectApps` early-return).

`guard incomingIDs != selectedAppBundleIDs else { return }` skips the snapshot refresh when the selection set is unchanged — after `loadInstalledApps()` (toolbar Refresh), `selectedAppSnapshots` keep the **old** `InstalledApp` (stale icon/size) even though the table now has fresh instances with new UUIDs. Path/bundleID are identical so pruning stays correct; impact is cosmetic. Fix: update snapshots for already-selected apps before the early return (or in the `installedApps` onChange in `AppListView`).

---

### 🟡 F6 (P3) — Redundant main-thread hops around `Logger` calls

**Location**: `AppState.swift:583, 595` (`defaultAppFileTrasher`).

The diff wraps two background-thread `Logger.shared.log(...)` calls in `DispatchQueue.main.async { ... }`. `Logger.log` is explicitly `nonisolated` and internally hops (`Logger.swift:38–44`), so these wrappers are unnecessary noise — they reorder logging and add hops without fixing anything. Remove them (or explain the intended fix).

---

### ✅ Non-issues verified (with evidence)

- **Stale completion discarding** (`AppState.swift:389–406`): generation token + membership guard is correct; `testStaleCompletionForDeselectedAppIsDiscarded` passes. The guard-failure path correctly re-advances the queue via `startNextScan()`.
- **Deduplication** (`handleScanCompletion`): `U_k = R_k \ (∪_{j<k} U_j)` is implemented exactly per ADR §2.4 and is deterministic under strict sequential execution (holds except during F1's concurrency).
- **`removeSelectedFiles` re-entrance guard + high-risk dotpath guard + admin escalation + FDA flow**: untouched and operating on the union set correctly.
- **FDA retry freezing**: `lastFailedRemovalURLs` and the new `lastFailedRemovalAppNames` are both frozen at `finishRemoval` time; the retry operates on frozen snapshots via `requestFullDiskAccessAndRetry(items:context:)` with `retryAfterFullDiskAccess` re-invoking `removeSelectedFiles(confirmedURLs:)` — correct.
- **Row-trash bugfix**: `removeSingleFile` now uses `removeSelectedFiles(confirmedURLs: [url])` (`AppFilesView.swift:463–466`) — the ADR's "selection obliteration" defect is fixed; per-file removals no longer wipe other selections.
- **`PermissionCoordinator.PromptContext` generalization**: single-vs-multi headline branching is correct and Equatable conformance is synthesized properly; `testPermissionCoordinatorHeadlineFormatting` passes.
- **Memory**: all scanner/trasher completion closures capture `[weak self]`; no new retain cycles or Notification/KVO token leaks found.
- **Concurrency**: all `@Published`/queue/selection mutations occur on `@MainActor`. Production scanner/trasher callbacks arrive off-main and are hopped via `Task { @MainActor }`. (Wildly spread pre-existing actor-isolation warnings exist across the codebase but this diff adds none, and no new data races were identified.)
- **Reduce Motion**: all row-sweep animations branch on `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (state) and `accessibilityReduceMotion` (view) consistently.

---

## 5. Checklist — Comprehensive Quality & Safety Audit

| Axis | Result | Notes |
|---|---|---|
| **Functional purity / structure** | ✅ | `discoveredFiles` is a pure derived computation; single source of truth (`discoveredFilesByApp`); dual storage prohibited per ADR and honored — old `discoveredFiles` storage removed |
| **Immutability / FP discipline** | ✅ | Selection math is pure set/subtract operations (`selectedFiles` as `Set<URL>`); snapshots held immutably |
| **Swift 6 / @MainActor safety** | ✅ / ⚠️ | All state mutations on main actor; background hops correct. ⚠️ F1 lets two scans run concurrently, causing the ADR's rejected parallel-I/O condition |
| **Data-race safety** | ✅ | No new shared mutable state across threads; `Logger` calls nonisolated |
| **ARC / retain cycles** | ✅ | `[weak self]` used throughout; no cycles; no token leaks |
| **Correctness & edge cases** | ⚠️ | F1 (blocking), F2, F3 (latent), F5 documented above; boundary handling of empty selection, empty scans (`[]` entries → correct "No additional files" UI), and repeated `selectApps` no-op guard all correct |
| **Multi-app FDA retry path** | ✅ | Attribution + frozen snapshot + retry verified by test |
| **Security (OWASP/HIG/least-privilege)** | ✅ | High-risk dotpath guard unchanged and applies to union; FDA/root escalation unchanged; no new sandboxing or TCC surface |
| **Accessibility / Reduce Motion** | ✅ | Branches throughout; DisclosureGroup + Toggle semantics preserved |
| **Code cleanliness** | ⚠️ | F6 redundant hops; otherwise idiomatic, well-commented, no dead code (old `iconHovering`, `checkingLocationsText`, `scanningState`, `fileGroupsList` removed cleanly) |
| **Localization parity** | ✅ | Both new keys present in all 11 locales with matching format specifiers; `LocalizationFilesTests` passes |
| **No scope creep** | ✅ | Diff matches ADR/roadmap exactly; `roadmap.md`/`README.md` documentation only |

---

## 6. Build & Test Verification

Executed per ADR §6.1 (Debug, `platform=macOS`, `CODE_SIGNING_ALLOWED=NO`):

```
xcodegen generate
xcodebuild ... test   → ** TEST SUCCEEDED **
  Executed 114 tests, 0 failures  (includes 12 new AppStateMultiUninstallTests)
```

**Warnings**: clean build of this branch emits **277** `warning:`-class lines; clean build of `main` baseline emits **284** — i.e. the diff introduces **zero new warnings** and slightly reduces them. The only two diagnostics attributed to changed files (`AppState.swift:784` actor-isolated `ignoredOrphansKey`, `AppState.swift:1146` `#ImplicitStrongCapture`) are pre-existing, in code the diff does not touch. No linter is configured in this repo (no `.swiftlint.yml`; CI runs xcodebuild only), so the "0 linter warnings" criterion is N/A. Note: the 200+ remaining actor-isolation warnings across `ScanEngine`/`CleaningEngine`/etc. will become **errors** when this project eventually migrates to Swift 6 language mode — pre-existing debt, out of scope for this review, but worth a dedicated follow-up.

---

## 7. Test Adequacy — `PureMacTests/AppStateMultiUninstallTests.swift`

**Strengths** (all passing, deterministic via injected seams):
- M1 sequential order + name-sorted queue + no-rescan-when-selected + re-scan-on-re-select + progress flags — good coverage of the happy path.
- M2 deselection purge, stale-completion discard, in-place force-rescan replacing only that app (covered **after** queue drain).
- M3 first-scanned-wins dedup, cross-app removal, pruning.
- M4 FDA owning-app-name snapshot + coordinator headline formatting; `AppStateTests.testFullDiskAccessRetryKeepsUninstallInTrashFlow` correctly migrated to `uninstall(appNames:)`.

**Gaps (should be added with the F1 fix)**:
1. **Force-rescan while the scan queue is active** (a queued or in-flight scan exists) — the exact F1 scenario; currently untested and failing by behavior.
2. Deselecting the *currently scanning* app while other apps remain queued (queue must still drain via the stale completion — currently works by accident of `handleScanCompletion`'s guard-fail path, but is untested and undocumented).
3. Adding an app mid-batch (progress counters desync — F2).
4. `pruneMissingInstalledApps` with **two** missing apps (multi-removal iteration under Set mutation).

Minor note: tests write directly to `discoveredFilesByApp`/`selectedFiles` (`testRemovingFilesAcrossApps…`, `testPruning…`) — acceptable for exercising removal/prune in isolation, but a slightly stronger test would drive them through the scanner seam.

---

## 8. Recommended Fix List (priority order)

1. **P1 — F1**: Make `scanForAppFiles` queue-cooperative (or guarded) per §4. `isScanningAppFiles`/`scansCompleted`/`scansTotal` must remain consistent whenever a force-rescan happens mid-batch; queued apps must always be scanned exactly once. Add the three missing tests from §7.
2. **P2 — F2**: Make `scansCompleted/scansTotal` batch-relative so mid-batch additions don't produce "3 of 2" tickers.
3. **P3 — F3**: Snapshot the `Set` before iterating/purging in `pruneMissingInstalledApps`.
4. **P3 — F4**: Promote `selectedAppSnapshots` to `@Published` (or codify the paired-write invariant).
5. **P3 — F5**: Refresh in-selection snapshots on `loadInstalledApps`-driven early-return.
6. **P3 — F6**: Drop the redundant `DispatchQueue.main.async` logger hops.

Addressing 2–6 can ride along with the F1 fix in a single follow-up commit; none block merge independently, but F1 does.

---

## 9. Sign-off

**Reviewed and verified by the Code Reviewer on 2026-09-21.**

This document is deliberately **uncommitted** (per reviewer role constraints, the only file the reviewer writes is `docs/review.md`). Once the Developer resolves F1 (blocking) and the accompanying test gaps, I am prepared to re-review and approve. No application source files were modified during this review.
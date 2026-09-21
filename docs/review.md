# Code Review — Multi-Select App Uninstaller (Re-Review)

- **Reviewer**: Code Reviewer (Maestri Engineering Team)
- **Re-reviewed ref**: `feature/multi-select-uninstall` @ `6559a69` (fix(uninstaller): address review findings F1–F6)
- **Prior review**: `43a9417` → `REQUEST CHANGES` (1× P1, 5× P2/P3) — record preserved in §5
- **Baseline**: `main`
- **Spec**: `docs/adr-proposal.md` (ADR — Alternative 4, "Sequential Progressive + BundleID Indexing")
- **Review date**: 2026-09-21

---

## 0. Current Verdict

```
Verdict:          🔴 REQUEST CHANGES  (narrow — single remaining item)
Blocking issues:  1 (P2 — F6 warning regression: 4 new compiler warnings in changed code)
F1–F5:            ✅ All resolved and independently verified (incl. re-running the review-1 reproductions)
F6:               ⚠️ Intent correct, implementation regressed to 4 warnings (AppState.swift:577/587)
Tests:            119/119 pass (0 failures, +5 new regression tests)
Warnings:         +4 new warning instances in the diff (2 unique × 2 arch) — violates the 0-new-warnings gate
```

F1–F5 are **verified fixed**. The only outstanding item is F6: removing the `DispatchQueue.main.async` wrappers around the two `Logger.shared.log` calls in `defaultAppFileTrasher` exposed the actor-isolation warning those wrappers had been suppressing (`Logger.shared` is a `@MainActor` static referenced from a `@Sendable` background closure). The diff therefore adds 4 compiler warnings (2 unique × arm64/x86_64). This is a small, precisely-understood remediation (~3 lines) — see §3.

---

## 1. Re-Review Summary

The Developer addressed all six findings. The P1 blocker from review 1 (F1) is genuinely fixed: `scanForAppFiles` no longer runs the scanner out-of-band; it prepends the bundle to `scanQueue`, invalidates prior generation tokens, and lets `startNextScan()` drive everything — so only one scan is ever in flight and the queue always advances through `handleScanCompletion`'s guard-fail/success paths. Both review-1 reproductions were re-run against `6559a69` and now pass (previously failing) with consistent counters (`completed == total` at completion). F2–F5 are correct as analyzed in §2. Regression testing is strong: 5 new deterministic tests cover exactly the previously untested paths, and the pre-existing `AppStateTests` generation test was correctly re-sequenced for the new deterministic completion order.

The one regression is F6 — new compiler warnings (see §3). Everything else meets the acceptance criteria.

---

## 2. Finding-by-Finding Resolution

| # | Finding (Review 1) | Status | Evidence |
|---|---|---|---|
| **F1** | `scanForAppFiles` bypassed the scan queue → concurrent scans, premature `isScanningAppFiles=false`, silent queue stall | ✅ **Resolved** | `AppState.swift:415–456` — queue-cooperative: `scanQueue.removeAll { $0 == bundleID }; scanQueue.insert(bundleID, at: 0)`, idle branch calls `startNextScan()`, in-flight branch only bumps `scansTotal` for genuinely new items. No out-of-band scanner invocation remains. **Independently re-verified**: review-1 killer scenario (rescan of already-scanned C while B in flight) and in-flight rescan repro now pass — `scanCalls` never exceeds 1 in-flight scan; queue fully drains; `scansCompleted == scansTotal` (3/3, 2/2). New test `testRescanWhileScanQueueIsActiveExecutesSequentiallyAndDrainsQueue` covers it; `testDeselectingCurrentlyScanningAppDrainsRemainingQueue` covers the drop-active path. `AppStateTests` generation test re-sequenced to the now-deterministic completion order (stale-first). |
| **F2** | Progress counters desynced on mid-batch additions ("3 of 2 apps") | ✅ **Resolved** | `selectApps` now accounts for the in-flight scan (`inFlight + scanQueue.count + newQueueItems.count`, `AppState.swift:321–324`); `handleScanCompletion` clamps via `min(scansCompleted + 1, scansTotal)` (:418); `dropApp` decrements `scansTotal` for pending/active drops, guarded against dropping below `scansCompleted` (:338, :351–352). Verified by `testMidBatchAppAdditionsProgressCounterTracking` (1→3 total, completed never exceeds total, ends 3/3). Residual: when apps are added mid-batch the ticker count can momentarily restart lower (e.g. show "1 of 3" during the second app) — cosmetic, bounded, self-correcting; acceptable. |
| **F3** | `pruneMissingInstalledApps` mutated `Set` during enumeration (UB) | ✅ **Resolved** | `for bundleID in Array(selectedAppBundleIDs)` (`AppState.swift:752`). New `testPruningMultipleMissingInstalledApps` prunes two of three apps concurrently with no crash/skip. |
| **F4** | `selectedAppSnapshots` not `@Published` (latent re-render trap) | ✅ **Resolved** | `@Published private(set) var selectedAppSnapshots` (`AppState.swift:107`). |
| **F5** | Stale snapshots after Refresh (early-return skipped snapshot refresh) | ✅ **Resolved** | `selectApps` now refreshes snapshots and re-matches `selectedApp` in the unchanged-selection early-return (`AppState.swift:288–296`); no new scans start, no view feedback loop (bundle-ID set untouched). Verified by `testSelectAppsRefreshesSnapshotsEvenWhenSelectionUnchanged` (100 → 500 size refresh). |
| **F6** | "Redundant" `DispatchQueue.main.async` logger hops | ⚠️ **Reopened** | See §3. The hops were load-bearing for warning suppression; removing them adds 4 compiler warnings. |

---

## 3. New Finding — F7 (P2): F6 introduced 4 compiler warnings

**Location**: `PureMac/ViewModels/AppState.swift:577, 587` (`defaultAppFileTrasher`).

**What happened**: F6 deleted the `DispatchQueue.main.async { Logger.shared.log(...) }` wrappers from the two background-thread error paths. My review-1 F6 write-up called the wrappers "unnecessary noise" — that root-cause read was **incomplete and led the Developer astray**. Re-verified: `Logger.log` is `nonisolated` and internally thread-safe, but the *expression* `Logger.shared.log(...)` first reads `Logger.shared`, which is a **`@MainActor`-isolated static property** (`Logger.swift:22`). Reading it inside the `DispatchQueue.global(qos: .userInitiated).async { ... }` closure (which is `@Sendable`) is exactly what the wrappers existed to avoid.

**Evidence** (clean rebuild, `-derivedDataPath` clean):
```
Total warnings:   6559a69 = 285   vs   43a9417 = 277   →  +8 (= 4 → 2 unique × 2 arch)
Changed-file warnings:
  AppState.swift:577,587  warning: main actor-isolated static property 'shared'
                          can not be referenced from a Sendable closure   ← NEW (this commit)
  (+ the 2 pre-existing warnings: :784 ignoredOrphansKey, :1146 #ImplicitStrongCapture — not from this diff)
```
No other warning changes exist in the committed files. So **this diff fails the "0 new compiler warnings" gate**, and under a future Swift 6 language-mode migration these two sites become **errors**.

**Remediation options (Developer's choice, ~3 lines, pick one)**:
1. **Restore the main-actor hop** for exactly these two calls (the proven, warning-free form that shipped in `43a9417`). Free of new warnings; slight log reordering is immaterial.
2. **Avoid the actor-isolated singleton read from the `@Sendable` closure** — e.g., add a `nonisolated` static helper on `Logger` that closes over the OS logger without touching `Logger.shared`, or hoist a nonisolated logger reference before the `DispatchQueue.global.async`. Cleaner long-term; must be verified warning-free.
3. As part of the eventual Swift 6 migration, revisit the 200+ pre-existing actor-isolation warnings codebase-wide (out of scope here, but F7 is a preview of that debt).

---

## 4. Verification (Re-Review)

```
xcodegen generate
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build-tests CODE_SIGNING_ALLOWED=NO test
  → ** TEST SUCCEEDED ** — Executed 119 tests, 0 failures
     (114 prior + 5 new regression tests; AppStateTests re-sequenced test passes)

Independent re-verification (scratch harness outside the repo, removed after use):
  • Review-1 killer scenario (rescan of already-scanned C while B in flight): PASS
    — no concurrent scan (scanCalls stays 2), C rescanned after requeue, counters 3/3.
  • Review-1 in-flight rescan repro: PASS — no concurrent scan (stays 1 until stale
    completion discarded), queue drains, counters 2/2.
  (Both harnesses failed against 43a9417; both pass against 6559a69.)

Warnings: clean builds compared — 43a9417: 277 → 6559a69: 285; all +8 are F7.
Security/ADR invariants: high-risk dotpath guard, FDA/admin flows, frozen retry
snapshots, localization parity (11 locales), reduce-motion branches — unchanged, intact.
```

---

## 5. Historical Record — Review #1 (43a9417) — Findings (for reference)

- **F1 (P1, blocking — RESOLVED)**: `scanForAppFiles` ran the scanner out-of-band while the sequential queue was active → concurrent scans (violating ADR §2.3/§2.4 and making first-scanned-wins completion-order-dependent), premature `isScanningAppFiles = false`, desynced counters, and a narrow silent queue stall. Reproduced deterministically in review 1.
- **F2 (P2)**: `scansTotal = scanQueue.count + newQueueItems.count` ignored the in-flight scan and reset `scansCompleted` mid-batch → "3 of 2 apps" ticker. → **RESOLVED** (§2).
- **F3 (P3)**: Set mutation during enumeration in `pruneMissingInstalledApps` (formally UB). → **RESOLVED**.
- **F4 (P3)**: `selectedAppSnapshots` non-`@Published`. → **RESOLVED**.
- **F5 (P3)**: stale snapshots after Refresh. → **RESOLVED**.
- **F6 (P3)**: redundant main-thread logger hops (my initial read) — **superseded by F7**: hops were warning-suppressive, and their removal regressed warnings.
- Review-1 strengths stand: bundleID-keyed state, pure derived `discoveredFiles`, generation-token staleness guard, row-trash wipe bugfix, generalized FDA retry with frozen snapshot + app-name attribution, all-11-locale parity, `[weak self]` hygiene, `@MainActor` mutation discipline, zero scope creep.

---

## 6. Sign-off

**Re-reviewed and verified by the Code Reviewer on 2026-09-21.**

- **F1–F5: APPROVED** — resolved and independently verified (including re-running the original failing reproductions).
- **F6/F7: one focused remediation remains** — eliminate the 4 new compiler warnings at `AppState.swift:577/587` (preferred: option 1 or 2 in §3) with a clean-build confirmation (warnings must return to ≤ 277, i.e., no diff-attributable warnings).

The moment that 3-line fix lands with a warning-free clean build, I will issue **APPROVE**. No application source files were modified during this review; `docs/review.md` is left uncommitted per reviewer role constraints.
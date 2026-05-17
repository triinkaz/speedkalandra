# Refactor Roadmap

> **Purpose.** Track what has and hasn't been addressed from the senior-review prompt that drove the v0.1.4 work, so that future sessions can resume the cleanup incrementally and with tests at each step.
>
> **How to use this file.** Open it at the start of every session that intends to continue the cleanup. Pick the next open phase, do only that phase, verify the tests, mark the phase Done, commit. Skip ahead only when explicitly noted as safe.
>
> **Scope.** This file covers only the senior-review work. Day-to-day bugs and features are tracked elsewhere (commit messages, CHANGELOG).

---

## 1. Status snapshot

The senior-review prompt enumerated 9 problem areas. Status as of the end of the v0.1.4 work-in-progress:

| # | Senior-review item | Status |
|---|---|---|
| 1 | Too many historical comments (`v17.x`, `Bug #N`, wave references) | **OPEN** — deliberately not bulk-deleted yet (would lose context). Plan: file-by-file in Phase B. |
| 2 | Too much explanatory commenting (AI-style "explaining itself") | **OPEN** — overlaps with #1. Handled together. |
| 3 | Large composition root (`src_v2/app/app.ahk` ≈ 1900 lines) | **OPEN** — extraction targets identified, deferred to Phase C. |
| 4 | Too many silent `try` statements | **PARTIAL** — 1 critical site fixed (the hydration call). Dozens of best-effort sites remain; most are intentional and acceptable, a few should be upgraded. Plan: Phase A2. |
| 5 | Documentation inconsistent (some docs claimed "no tests") | **DONE** — README, src_v2/README, CONTRIBUTING, tests_v2/README reconciled. CHANGELOG.md created. ARCHITECTURE.md already accurate; only test count bumped. |
| 6 | Hydration bug (`RunService.Hydrate` published `RunStarted` before subscribers existed) | **DONE** — bug confirmed real, fixed in `app.ahk` + `zone_tracking_service.ahk`, covered by 4 new regression tests. |
| 7 | Tests exist but need trust + CI | **PARTIAL** — 9 regression tests added (lifecycle, hydration, EventTrace opt-in, UndoLastSave PB rebuild). CI not added; blocker is the `MsgBox` at the end of the test runner. Plan: Phase A1. |
| 8 | Possible overengineering | **OPEN** — informally: ARCHITECTURE.md justifies each abstraction; suspicion is unfounded. Formal review in Phase D. |
| 9 | AI-generated smell | **PARTIAL** — docs reconciled, CHANGELOG exists, hydration patch-by-patch defensiveness reduced (root cause fixed properly instead of new local patch). In-source historical comments remain (Phase B). |

---

## 2. What's been done — details

### Bugs fixed (v0.1.4 WIP)

| # | Bug | Files | Tests |
|---|---|---|---|
| 1 | **Hydration ordering.** `runService.Hydrate(state)` was called in the middle of `__New`, before `RunStatsRecorder` and other downstream subscribers existed. `RunStarted{hydrated:true}` fired during hydration was lost, leaving `RunStatsRecorder._runId = ""`. Finalizing a hydrated run produced a snapshot with empty `runId` which `RunHistoryRepository.Save` silently rejected. **The hydrated run was never saved.** | `src_v2/app/app.ahk` (deferred `Hydrate` to end of `__New`, after `_WireEventHandlers()`; upgraded silent `try` to `try/catch` with log), `src_v2/app/services/zone_tracking_service.ahk` (`_OnRunStarted` respects `hydrated:true` so persisted totals aren't wiped) | `zone_tracking_service_tests.run_started_with_hydrated_flag_preserves_totals`, `run_started_without_hydrated_flag_wipes_totals`, `speedkalandra_app_integration_tests.hydrated_run_propagates_run_id_to_stats_recorder`, `hydrated_run_finalize_saves_to_history` |
| 2 | **`LoadingDetectionService` false positives on non-game windows.** Default window provider matched the substring `"Path of Exile 2"`, which also matches browser tabs on the PoE2 wiki and Discord channels titled that way. The HUD pixel scanner then sampled the wrong window. | `src_v2/app/services/loading_detection_service.ahk` — replaced title-substring scan with `ahk_exe` over the same canonical executable list `FocusAutoPauseService.GAME_EXECUTABLES` uses. Lock every follow-up `WinGetMinMax/WinGetPos` to the resolved HWND. | Manual verification recommended (Phase D). |
| 3 | **`UndoLastSave` left personal bests pointing at the deleted run.** Inconsistent with `RunHistoryDialog.Delete` (which already rebuilt PBs). | `src_v2/app/app.ahk` — added `_RebuildPbsFromHistory` helper, called after successful delete; updated tray-tip messages accordingly. | `speedkalandra_app_integration_tests.undo_last_save_rebuilds_pbs_from_history` |

### Privacy / hygiene

| Change | Files |
|---|---|
| **`EventTraceLogger` is now opt-in.** New `[Diagnostics].EventTracingEnabled` INI flag (default `0`). When false, the bus interceptor is constructed but never registered, so raw `Client.txt` lines never land in `speedkalandra.log` for a normal install. | `src_v2/domain/app_settings.ahk` (new `eventTracingEnabled` field + `FromMap` parsing), `src_v2/infra/settings_repository.ahk` (`_LoadDiagnostics`/`_SaveDiagnostics`), `src_v2/app/app.ahk` (`Start()` gates `eventTracer.Start()` behind the flag) |

### Build

- `build-dist.ps1`: rejects `-DestDir` that is a descendant of the source (prevents recursive copy). README-DIST.txt template now lists Ctrl+F8 (Steve mode).

### Documentation

| File | Change |
|---|---|
| `README.md` | Added Testing section. Added `Ctrl+F8 — Toggle Steve mode` to the hotkey table. Linked `CHANGELOG.md`. Fixed inverted Architecture pointer (was directing readers to `src_v2/README.md` as the "main" doc; now correctly points to `ARCHITECTURE.md`). |
| `CONTRIBUTING.md` | Removed "no automated test suite" claim, documented the actual suite (run command + count), added paragraph about the `[Diagnostics].EventTracingEnabled` flag for bug reports. |
| `ARCHITECTURE.md` | Test counts bumped (`~1557` → `~1567`); no structural changes (already excellent — well-organized, current, and free of historical noise). |
| `src_v2/README.md` | "No automated tests (v17.15)" → "Automated tests (v0.1.3+)" with current count. |
| `tests_v2/README.md` | Count `1510` → `1567`, time `~21s` → `~25s`. |
| `CHANGELOG.md` | **New file.** Keep-a-Changelog format. Captures `Unreleased` (v0.1.4 WIP), v0.1.3, v0.1.2, v0.1.1, v0.1.0. Pre-release `v17.x` mentioned as historical metadata. |

### Tests added (9 total across two sessions)

| Suite | Tests |
|---|---|
| `unit/domain/app_settings_tests.ahk` | `defaults_event_tracing_disabled_by_default`, `from_map_reads_event_tracing_enabled` |
| `unit/infra/settings_repository_tests.ahk` | `save_load_preserves_diagnostics_event_tracing` |
| `unit/app/services/zone_tracking_service_tests.ahk` | `run_started_with_hydrated_flag_preserves_totals`, `run_started_without_hydrated_flag_wipes_totals` |
| `integration/speedkalandra_app_integration_tests.ahk` | `constructor_event_tracer_not_enabled_by_default`, `undo_last_save_rebuilds_pbs_from_history`, `hydrated_run_propagates_run_id_to_stats_recorder`, `hydrated_run_finalize_saves_to_history` |

**Expected new total: 1567 PASS.** This must be verified by running the suite on Windows before starting Phase A1.

---

## 3. What was deliberately rejected (and why)

The senior-review prompt is comprehensive but not all of its asks are improvements. The following items are recorded as **not to be done** unless reasoning changes:

| Asked for | Decision | Rationale |
|---|---|---|
| **Bulk delete of all `v17.x` / `Bug #N` comments from source.** | Rejected as a bulk operation. Will happen incrementally in Phase B with judgement per file. | These comments encode *why* a specific defensive pattern exists (e.g. `; v17.15 (Bug #5): timeouts must publish, not be dropped`). Deleting them in bulk degrades the code from "engineered, maintained" to "context-free". The intent of the senior review (less AI smell) is better served by **moving** the high-value entries to CHANGELOG or `ARCHITECTURE.md §14` (AHK pitfalls), and **rewording** the in-code one-liners to focus on the *invariant* rather than the *bug number*. |
| **Reframe the disclaimer to be "more confident".** | Rejected. | The current disclaimer ("I directed what I wanted, reviewed the output, tested in actual runs… I won't pretend I wrote the architecture from scratch") is **honest**, which is what the senior review actually demanded. Rewording it to the prompt's suggested template would make it more polished and less truthful. The owner's voice stays. |
| **Aggressive simplification of "overengineered" architecture.** | Rejected pending Phase D audit. | `ARCHITECTURE.md` already justifies each abstraction. Repository pattern is justified by the INI/CSV/JSON pluralism; EventBus by the 20+ services; composition root by the absence of a DI container in AHK v2. Removing structure to shrink the codebase would damage the project, not improve it. |
| **One-shot composition-root rewrite.** | Rejected. Will happen in Phase C as a sequence of named, individually-tested extractions. | A 1900-line file with 50+ subscribers and 3 modal dialogs cannot be safely rewritten in one pass without a working CI. The right path is: get CI green (Phase A1) → extract one cohesive piece at a time → re-run tests → commit. |
| **Mass conversion of `try x()` to `try/catch` everywhere.** | Rejected. Selective only. | Most silent `try` is in `Stop()` (best-effort shutdown), `TrayTip` (optional UI feedback), `SetTimer` cancellation (idempotent), and widget `Hide()`. `ARCHITECTURE.md §13` already permits this category explicitly. Converting them all to logged catches adds noise without value. Critical paths are different (see Phase A2). |

---

## 4. Open work — phased plan

Phases are ordered so the cheapest, safest work happens first, and the riskiest only after we have CI as a safety net.

### Phase A1 — CI safety net + test runner `--no-gui` (one session, medium risk)

**Why first.** Every subsequent phase touches code. The current test workflow ends with a `MsgBox`, which means in practice the suite must be run manually on Windows. That's fine for spot-checks, but for a serious comment/extraction sweep we need *cheap*, *automated*, *unambiguous* test runs. Without CI, we'll either skip running tests or run them inconsistently — both of which kill the value of the sweep.

**Tasks.**

1. Modify `tests_v2/framework/test_reporter.ahk` (or wherever the final `MsgBox` lives) to skip the GUI when either:
   - an env var `SPEEDKALANDRA_TEST_NO_GUI=1` is set, **or**
   - a CLI flag `--no-gui` is passed to `run_tests.ahk`.
   In that mode, the runner should call `ExitApp(exitCode)` where `exitCode` is `0` on all-pass and `1` on any failure. The final summary still goes to `tests_v2/tests_output.log`.
2. Add `.github/workflows/test.yml` (GitHub Actions, `windows-latest`). Steps:
   - `choco install autohotkey --version=2.0.x -y`
   - `& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk --no-gui`
   - Upload `tests_v2/tests_output.log` as an artifact on failure.
3. Add a brief section to `tests_v2/README.md` describing the headless mode and the CI workflow.
4. Add `.github/workflows/` to `.gitignore`'s allow-list if anything excludes it.

**Touched files.**
- `tests_v2/framework/test_reporter.ahk` (probably — locate first)
- `tests_v2/run_tests.ahk` (CLI parsing if needed)
- `tests_v2/README.md`
- `.github/workflows/test.yml` (new)

**Tests added.** None — this phase modifies infrastructure, not behavior. Acceptance is *the suite still passes both with and without the new flag*.

**Acceptance criteria.**
- `AutoHotkey64.exe tests_v2\run_tests.ahk` (interactive) — still shows the MsgBox, still returns 1567 pass.
- `AutoHotkey64.exe tests_v2\run_tests.ahk --no-gui` — exits silently with code 0, no MsgBox, log written.
- A simulated failing test causes the headless run to exit with code 1.
- CI workflow runs green on push.

**Risk.** Medium — TestReporter modification. Failure mode: tests silently exit success when they shouldn't. Mitigation: write the exit-code logic carefully, then deliberately inject a failing test once and watch CI go red, then revert.

---

### Phase A2 — Targeted silent-`try` sweep (1–2 sessions, low risk per file)

**Why second.** With CI green, we can move quickly. Silent-`try` cleanup is the safest content change — each conversion is local, and the test suite catches regressions.

**Approach.** Not a bulk regex replace. File-by-file audit. For each `try x()` without `catch`, classify:

- **Critical** (persistence, lifecycle, hydration, save, event dispatch) → upgrade to `try { x() } catch as ex { log.Warn(...) }` following the pattern already used in `_PersistRunData` and the hydration call.
- **Best-effort** (shutdown, TrayTip, widget `Hide`/`Show`, SetTimer cancellation) → leave as silent `try`, but add a one-line comment if the file doesn't already have a category-level note. Don't pepper every line.

**Files to audit in priority order.**

1. `src_v2/app/app.ahk` — biggest surface; many silent `try`s in `Stop()`, dialog handlers, and `_OnX` methods.
2. `src_v2/app/services/run_service.ahk` — has silent `try` in `PersistTimer` and `_Persist`. These are critical (save path) and should log.
3. `src_v2/infra/run_state_repository.ahk` — check for silent `try` around IniWrite.
4. `src_v2/infra/run_history_repository.ahk` — check.
5. `src_v2/infra/personal_best_repository.ahk` — check.
6. `src_v2/app/services/event_trace_logger.ahk`, `log_monitor_service.ahk`, `focus_auto_pause_service.ahk`, `loading_detection_service.ahk` — quick scan.

**Tests.** One test per converted-to-logged catch is overkill; tests already exercise the happy path. Acceptance is *the suite still passes after each file*. A targeted test is justified only when the conversion changes observable behavior (e.g. a previously silently-swallowed error now causes a logged warning that some other test asserts on).

**Acceptance criteria.**
- All critical paths use `try/catch as ex { log.Warn(...) }` (or return an explicit success/failure value).
- Remaining silent `try` lines are all in clearly best-effort spots, and each file has at most one short comment explaining the category.
- `ARCHITECTURE.md §13` ("try only at the borders") is now accurate, not aspirational.
- 1567 tests still pass.

**Risk.** Low per file. Cumulative risk grows if rushed. **Do one file per commit.**

---

### Phase B — Historical comment cleanup (1 session per ~5 files, ~5–6 sessions total)

**Why third.** Lower-value than the bug fix and CI, but the biggest single source of "AI smell". With CI green and silent-`try` cleaned, we can move through files confidently.

**Approach. NOT a bulk operation.** For each file:

1. Read the file end-to-end.
2. For every comment referring to `v17.x`, `v0.1.x`, `Bug #N`, `Wave N`:
   - If the comment encodes an **invariant** ("zone counter must respect pause"), reword it to express the invariant without the version reference.
   - If it encodes a **lesson learned about AHK** (encoding bugs, `is` collisions, etc.), keep it but strip the version/bug number — it's permanent knowledge, not historical.
   - If it's **pure history** ("v17.15 fixed this"), check whether the same change is captured in `CHANGELOG.md`. If yes, delete the comment. If no, add a one-liner to `CHANGELOG.md` first, then delete.
3. Re-read the file to verify nothing essential was lost.
4. Run the test suite. Commit.

**Order.** Largest / most-touched first, because they have the most comments and the biggest reduction in noise.

1. `src_v2/app/app.ahk` (composition root — most v17.x markers)
2. `src_v2/app/services/run_service.ahk`
3. `src_v2/app/services/zone_tracking_service.ahk`
4. `src_v2/app/services/auto_start_service.ahk` (its `Bug #4` workaround can now have the historical reference removed since the root cause is fixed in `app.ahk`)
5. `src_v2/app/services/loading_detection_service.ahk`
6. `src_v2/app/services/run_stats_recorder.ahk`
7. `src_v2/app/services/timer_service.ahk`
8. `src_v2/infra/personal_best_repository.ahk` (has the famous `MigrateIniToUtf8` historical block)
9. `src_v2/infra/io/text_encoding.ahk` (same)
10. `src_v2/domain/run_state.ahk`
11. `src_v2/version.ahk` (move v17.15 trivia into the CHANGELOG's pre-release section if not already there)
12. Remaining UI / domain files — quick passes.

**Acceptance criteria per file.**
- No `v17.x`, `Bug #N`, `Wave N` strings remain unless tied to a *current* invariant we want to keep (rare).
- Test suite still passes.
- The deleted content is captured in `CHANGELOG.md` if it has user-visible relevance.

**Risk.** Low per file. The biggest danger is accidentally deleting a comment that was actually conveying a constraint, not just history. Mitigation: read the file end-to-end first, edit second.

---

### Phase C — Composition root extractions (3 sessions, medium-high risk per extraction)

**Why fourth.** This is where the prompt's "split the composition root" finally happens. We do it only after CI is green and the file has been cleaned of historical noise (Phase B touches `app.ahk` first), so we're rearranging clear code, not muddy code.

**Approach.** Three named, individually-tested extractions. **Do not merge them.** One commit per extraction.

#### C1 — Extract `BootPrompts` class

Three modals live as private methods in `app.ahk`: `_ShowDisclaimerIfNeeded`, `_PromptLogFileSetupIfNeeded` (+ `_SetupBrowseLog`, `_SetupValidatePath`), `_PromptHydratedRun`. They share the documented "Sleep-loop modal" pattern (ARCHITECTURE.md §6) and are the most self-contained piece of `app.ahk`.

- New file: `src_v2/app/boot_prompts.ahk`
- Class: `BootPrompts` with dependencies passed in (`cfg`, `settingsRepo`, `headless`, etc.) and three public methods: `ShowDisclaimerIfNeeded()`, `PromptLogFileSetupIfNeeded()`, `PromptHydratedRun(runService, timer)`.
- `app.Start()` instantiates `BootPrompts` and calls the three methods at the corresponding points in its current flow.
- Tests: a new `tests_v2/unit/app/boot_prompts_tests.ahk` with at least one test per method exercising the `headless=true` path (which currently returns instantly).

**Expected `app.ahk` reduction:** ~150–200 lines.

#### C2 — Extract `RunSnapshotSaver` class

`_SaveRunSnapshot`, `_MarkUndoableSave`, `UndoLastSave`, `_RebuildPbsFromHistory`, `_ExpireUndoableSave` form one cohesive responsibility ("save / undo run snapshot"). They were already lightly refactored when `UndoLastSave` was fixed.

- New file: `src_v2/app/run_snapshot_saver.ahk`
- Class: `RunSnapshotSaver(bus, runHistory, statsRecorder, plotBuilder, zoneTracker, actCheckpoints, personalBest, timer, log)`.
- `app.ahk` subscribes `_SaveRunSnapshot` via the saver instead of as a method.
- Tests: extend `speedkalandra_app_integration_tests.ahk` if needed; add unit tests for the snapshot-building logic if it can be tested without a full app.

**Expected `app.ahk` reduction:** ~250–300 lines.

#### C3 — (Optional) Extract `RunStatePersister`

`_PersistRunData`, `_PersistRunDataFull`, `_ComputeTotalsHash`. Smaller win than C1/C2 (these methods are already simple). Skip unless the file is still feeling too big after C1+C2.

**Acceptance criteria for all of C.**
- Each extraction is its own commit.
- 1567+ tests still pass after each commit (`+` because new tests are added for the extracted class).
- `ARCHITECTURE.md §6` (Composition Root) updated to reflect the new structure.
- `app.ahk` line count reduced by at least 500 after C1+C2.

**Risk.** Medium-high. Mitigations:
- Don't extract while comments are still messy — Phase B first.
- Don't extract without CI — Phase A1 first.
- One extraction per session, no exceptions.
- The composition root's *order* of operations is load-bearing (the hydration bug we just fixed proves it). When extracting, preserve the call order exactly.

---

### Phase D — Audit-only review (1 session, no code change)

**Why last.** Some of the senior-review questions can only be answered honestly after the previous phases. By Phase D, the codebase is clean enough that the audit is meaningful, not noise-dominated.

**Tasks.**

1. **Overengineering review.** For each abstraction (EventBus, Repository, Service, Domain layer, Composition Root): one paragraph confirming or rejecting it. Likely outcome: all confirmed. If something is rejected, file an issue for a follow-up phase; do not refactor in the audit session.
2. **Production-level manual testing on real PoE2:**
   - Reload mid-run, check the hydrated finalize actually writes a history file (validates the v0.1.4 fix in production, not just in tests).
   - Run with `[Diagnostics].EventTracingEnabled=0` and confirm `Client.txt` content is not appearing in `speedkalandra.log`.
   - Test all three overlay modes, click-through, Ctrl-drag, Ctrl-wheel.
   - Trigger UndoLastSave and confirm PBs are correctly rebuilt.
3. **Reverse-direction scan:** anything found in Phase D that needs a code change becomes a new entry under Open Work, not part of this audit session.

**Acceptance.** A short audit report appended to this file (or as a new Markdown file) describing findings.

---

## 5. Per-phase test verification protocol

Apply to every phase that touches code (A1, A2, B, C):

1. **Before starting:** `git status` clean. Run the full suite. Confirm `1567 PASS` (or whatever the current expected count is). If red, fix or revert before doing anything else.
2. **During work:** one file (Phase A2, B) or one extraction (Phase C) per commit. Do not batch.
3. **After each commit:** rerun the full suite. Confirm count unchanged (or increased by the new tests). If red, fix immediately or revert the commit.
4. **End of phase:** rerun the full suite one more time. Confirm. Update this file to mark the phase Done with a date.

For Phase A1 (CI setup), the verification is the GitHub Actions run itself.

---

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `MsgBox` removal in TestReporter breaks the interactive test workflow | Medium | Medium | Keep the existing MsgBox as the default behavior. Only skip when env var or `--no-gui` flag is set. Manually run both modes once before committing. |
| Extracting BootPrompts breaks the modal Sleep-loop's interaction with the AHK message pump | Low | High | The pattern is well-documented (ARCHITECTURE.md §6). Keep the Sleep-loop intact; only move the surrounding code. Test by booting the app fresh, with a missing `Client.txt`, and with a hydrated run, before merging. |
| Comment cleanup deletes a comment that was actually documenting an invariant | Medium | Low–Medium | Read each file end-to-end before editing. When in doubt, keep the comment but reword it to remove the historical reference. |
| Composition root extraction changes the order of `__New` operations and reintroduces the hydration-class bug | Low | High | The Hydrate call is now the *last* thing in `__New`. Extraction must preserve that ordering. The 4 new regression tests catch a regression here immediately. |
| Phase A2 upgrade of a silent `try` masks a different latent bug by now logging it loudly | Low | Low–Medium | Good outcome, not bad — the noisy log is the signal we wanted. Investigate each newly-logged warning before assuming it's spurious. |
| CI runs into AHK installation issues on `windows-latest` | Medium | Low | Document a fallback that uses a pinned AHK installer URL instead of chocolatey. If still flaky, leave Phase A1 as a "best-effort" workflow and document the limitation. |

---

## 7. Phase tracker

Mark each phase Done with a date when complete. Append notes if anything went sideways.

- [x] **Sanity check.** Run the full suite on Windows (`AutoHotkey64.exe tests_v2\run_tests.ahk`). Expected: **1567 PASS**. _1567 PASS, 27.187s — gate cleared._ This is the gate for everything below.
- [ ] **Phase A1.** CI safety net + test runner `--no-gui`. _Date: ____________ ._
- [ ] **Phase A2.** Targeted silent-`try` sweep. _Date: ____________ ._
- [ ] **Phase B.** Historical comment cleanup. _Sub-tracker by file:_
  - [ ] `app/app.ahk`
  - [ ] `app/services/run_service.ahk`
  - [ ] `app/services/zone_tracking_service.ahk`
  - [ ] `app/services/auto_start_service.ahk`
  - [ ] `app/services/loading_detection_service.ahk`
  - [ ] `app/services/run_stats_recorder.ahk`
  - [ ] `app/services/timer_service.ahk`
  - [ ] `infra/personal_best_repository.ahk`
  - [ ] `infra/io/text_encoding.ahk`
  - [ ] `domain/run_state.ahk`
  - [ ] `version.ahk`
  - [ ] Remaining files (sweep)
- [ ] **Phase C1.** Extract `BootPrompts`. _Date: ____________ ._
- [ ] **Phase C2.** Extract `RunSnapshotSaver`. _Date: ____________ ._
- [ ] **Phase C3.** Extract `RunStatePersister` (optional). _Date: ____________ ._
- [ ] **Phase D.** Audit-only review + manual production tests. _Date: ____________ ._

When all phases above are done, the senior-review work is closed and this file can be archived (move to `BKP/` or delete).

---

## 8. Recommended order, in plain English

1. **First:** verify the v0.1.4 work-in-progress builds green (sanity check above). Without this gate, nothing else is safe.
2. **Then:** Phase A1 — get CI working. This pays back its cost on the very next phase.
3. **Then:** Phase A2 — clean up silent `try` in critical paths. Cheap, valuable, low-risk.
4. **Then:** Phase B — file-by-file comment cleanup. Slow but mechanical with CI now catching regressions.
5. **Then:** Phase C — composition root extractions, one at a time, with the cleaned-up source making each extraction obvious.
6. **Finally:** Phase D — read everything one more time, run the app in production, sign off.

Total estimated effort: **8–10 working sessions**, paced however suits the project. None of this is urgent. The hydration bug — the only high-severity finding — is already fixed.

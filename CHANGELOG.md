# Changelog

All notable changes to SpeedKalandra are tracked here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each release section is short and user-facing; engineering rationale lives next to the code (or in `ARCHITECTURE.md` when it shapes the design). Pre-release `v17.x` tags are listed at the end of this file as historical context only; they are no longer kept in source comments.

## [Unreleased]

### Fixed

- **Hydration ordering bug (RunStatsRecorder silently dropped hydrated runs).** `SpeedKalandraApp.__New` used to call `RunService.Hydrate` mid-construction. When the loaded state had an active run, `Hydrate` published `Evt.RunStarted{hydrated:true}` before `RunStatsRecorder` (and other downstream subscribers) had been created. Finalizing the hydrated run later produced a snapshot with `runId=""`, which `RunHistoryRepository.Save` silently rejected — the run was lost. `Hydrate` is now deferred to the end of `__New` after `_WireEventHandlers()`, and `ZoneTrackingService._OnRunStarted` respects the `hydrated:true` flag so the in-flight event no longer wipes the totals that were just restored from disk. Regression tests added in `zone_tracking_service_tests.ahk` and `speedkalandra_app_integration_tests.ahk`.
- **`LoadingTotalsService` wiped hydrated `_totalMs` on `RunStarted{hydrated:true}`.** Sibling of the hydration-ordering bug above: the composition root hydrates the loading total from disk via `loadingTotals.Hydrate(loadingMs)`, but `_handlerRunStarted` was hard-wired to `Reset()` and so the deferred `RunService.Hydrate()` event zeroed the value immediately after restoration. Loading time of an in-progress run was lost on every reload. Handler now goes through `_OnRunStarted(data)` which honours the `hydrated:true` flag, mirroring `ZoneTrackingService`. Regression tests `run_started_with_hydrated_flag_preserves_total_ms` and `run_started_without_hydrated_flag_wipes_total_ms` added in `loading_totals_service_tests.ahk`.
- **`LoadingDetectionService` false positives from non-game windows.** The default window provider matched the substring `"Path of Exile 2"`, which also matched Chrome tabs on the PoE2 wiki and Discord channels with that text. The HUD scanner then sampled pixels from the wrong window. Replaced with an `ahk_exe` scan over the same canonical list `FocusAutoPauseService` uses (`PathOfExile2Steam.exe`, `PathOfExile2_x64.exe`, etc.), and lock every follow-up `WinGetMinMax` / `WinGetPos` to the resolved HWND via `ahk_id`.
- **`UndoLastSave` left personal bests pointing at the deleted run.** Inconsistent with `RunHistoryDialog.Delete`, which already rebuilt PBs. `UndoLastSave` now invokes a new `_RebuildPbsFromHistory` helper after a successful delete (mirrors the dialog), so deleting the most-recent run via the tray immediately purges any PBs the deleted run contributed to.

### Changed

- **`EventTraceLogger` is now opt-in.** New `[Diagnostics].EventTracingEnabled` INI flag (default `0`). When false, the bus interceptor is constructed but never registered, so a normal install never persists raw `Client.txt` lines into `speedkalandra.log`. Users who need event-level traces for a bug report flip the flag (see `CONTRIBUTING.md`). Documented in `AppSettings` and surfaced via `SettingsRepository._{Load,Save}Diagnostics`.
- **Silent `try` sweep in critical paths.** Failures in settings save, run-data flush (5 s tick + shutdown), PB update, act-checkpoint capture, hotkey rebind, log-monitor restart, hydrated-run discard/finalize, zone-totals clear, death penalty application, and disclaimer/setup persistence are now logged via `LogService.Warn` instead of being swallowed by bare `try`. Same treatment at the infrastructure layer (`RunStateRepository.SaveZoneTotals`, `RunHistoryRepository._EnsureDir`) via `OutputDebug`, mirroring the existing convention in `RunHistoryRepository.Delete`. Legitimate silent `try` in lifecycle teardown (`Stop`, `Dispose`, `Hide`) and cosmetic side effects (`TrayTip`, `log.Info`) are kept intentionally.
- **Boot-time modals extracted from `SpeedKalandraApp` into a new `BootPrompts` class.** The disclaimer dialog, the Client.txt setup dialog, and the hydrated-run resume/finalize/discard prompt — together ~360 lines — used to live as private methods on the composition root. They are now a thin coordinator class owning no state of its own, constructed in `__New` with a `persistFn` callback and references to the services it needs (`logMonitor`, `runService`, `timer`, `log`). `Start()` calls three public methods (`ShowDisclaimerIfNeeded`, `PromptLogFileSetupIfNeeded`, `PromptHydratedRun`) in sequence. Pure refactor — no behavior change. 10 unit tests cover the guard clauses (headless, already-acknowledged, valid existing path, missing/inactive run service). `src_v2/app/app.ahk` is now ~360 lines shorter as a result.
- **Run finalization + undo extracted into `RunSnapshotSaver`.** `_SaveRunSnapshot`, `UndoLastSave`, `_MarkUndoableSave`, `_RebuildPbsFromHistory`, `_ExpireUndoableSave` (and the `MIN_CANCELLED_SAVE_MS` constant, renamed to `MIN_SAVE_MS` to match its actual semantics) moved out of `SpeedKalandraApp` together with the `_lastSavedRunId` / `_undoTimerFn` state they own. The `RunCompleted` / `RunCancelled` subscriptions in `__New` now route through a late-bound callback (`(data) => this._snapshotSaver.Save(...)`) — the saver itself is constructed near the end of `__New` once every collaborator it depends on exists. `app.UndoLastSave()` remains as a one-line delegate so the tray callback in `speedkalandra.ahk` is unchanged. Pure refactor — no behavior change. 10 unit tests cover the threshold gate, undo state machine, and PB rebuild semantics.
- **Persistence flow extracted into `RunStatePersister`.** `_PersistRunData` (5 s tick), `_PersistRunDataFull` (final flush from `Stop()`), `_PersistSettings`, and `_ComputeTotalsHash` moved out of `SpeedKalandraApp`, together with the dirty-cache fields `_lastSavedLoadingTotal` / `_lastSavedZoneTotalsHash` that they own. `Start()` now schedules `() => this._persister.Tick()` instead of `() => this._PersistRunData()`. The `_persistFn` closure passed to widgets, dialogs, and `BootPrompts` routes through `this._persister.PersistSettings()` so every settings write goes through the same instance. `__New` primes the cache via `PrimeLoadingTotalCache` / `PrimeZoneTotalsCache` after hydration so the first tick doesn't redundantly rewrite the just-loaded state. Pure refactor — no behavior change. ~30 unit tests cover skip-cache, full-flush, cache priming, and reset semantics.
- **Hot-reload and destructive-action handlers extracted into `LiveReconfigurationHandlers`.** Three handlers — `_OnDeathApplyTimerPenalty` (timer penalty applied on `Evt.DeathDetected`), `_OnHotkeysChanged` (Stop + Hydrate + Start on the hotkey service), and `_OnResetPersonalBestsRequested` (confirmation dialog + reset) — moved out of `SpeedKalandraApp` into a small class constructed in `__New` with the collaborators each handler needs (`cfg`, `timer`, `hotkeyService`, `personalBest`, `log`). The subscriptions in `_WireEventHandlers` are now one-line delegates: `(data) => this._reconfig.ApplyDeathPenaltyToTimer(data)` etc. `_OnLogFilePathChanged` stays inline because it mutates `_logMonitorTimer` on the composition root and the extra plumbing isn't worth the size win. Pure refactor — no behavior change. 16 unit tests cover the guard clauses, payload-vs-cfg fallback, and the headless reset path.

### Build

- **`build-dist.ps1` rejects descendant destinations.** Running `.\build-dist.ps1 -DestDir ".\dist"` used to enter a recursive copy. Now both ancestor and descendant relationships between source and destination are rejected with a clear error.
- **CI reintroduced.** New `.github/workflows/test.yml` runs the `tests_v2/` suite on `windows-latest` for every push and PR; installs AutoHotkey v2 via Chocolatey, runs in headless mode (`SPEEDKALANDRA_TEST_NO_GUI=1`), and uploads `tests_output.log` as an artifact on failure. The previous attempt had been disabled because `#Warn All, MsgBox` in `run_tests.ahk` made the runner exit with a non-zero code even on all-green runs — routed to `OutputDebug` instead.

### Documentation

- **Historical version tags scrubbed from source comments.** Roughly 40 files across `src_v2/` and `tests_v2/` carried internal-timeline markers in their headers and inline comments — `Wave N`, `Phase A1` / `Phase B2.1` / `Phase 6 Option A` / `Phase 9.2`, `v17.x` and `v0.1.x` version tags, `Bug #N`, `POST-DEMOLITION VERSION:`, `(Item N)`, `(refactor R7)`, `(R11.1)` — all of which described how the code reached its current shape rather than what the code does today. They are gone. The few comments that genuinely explained _why_ (e.g. why `ConvertUtf16ToUtf8` was removed, why `_OnZoneEnteredForLevel` defends against re-entries to The Riverbank) were preserved but reworded without the version tag. Stale references to extracted symbols (`_SaveRunSnapshot` after the `RunSnapshotSaver` split) were updated. Bug IDs in test names (`bug9_*`, `bug21_*`, `W4.1`, `W5.1`, `W9.1`, `W9.2`) were intentionally kept — they are stable contracts with `tests_v2/REGRESSION-COVERAGE.md`.
- **Disclaimer rewritten and made canonical across all three surfaces.** The README, the in-app boot modal (`BootPrompts.ShowDisclaimerIfNeeded`), and `CONTRIBUTING.md` previously carried three different versions, several of them with self-deprecating phrasing about being a player rather than a developer, promises of slow support, and an explicit "I won't pretend I wrote the architecture" line. A single shorter version now lives in the README and is mirrored faithfully in the boot modal. The substantive points (AI-assisted development, anti-cheat / TOS posture, use-at-your-own-risk, GPL forks) are preserved; the apologetic framing is gone.
- **Hard-coded test counts replaced by stable phrasing.** README, `CONTRIBUTING.md`, `tests_v2/README.md`, and `ARCHITECTURE.md` previously stated `~1569` (and the per-layer breakdowns in two of those files disagreed numerically). All references switched to either `over 1500` or removed entirely; the per-layer tables now describe coverage by suite name rather than by count, so the docs no longer drift every time a test is added.
- **`ARCHITECTURE.md` updated for the `BootPrompts` and `RunSnapshotSaver` extractions.** §6 (composition root) describes the late-bound `(data) => this._snapshotSaver.Save(...)` subscription pattern; §11 (dialogs) lists the boot modals as living in `app/boot_prompts.ahk` instead of inline in `app.ahk`. §15 (test suite) drops the version-tagged coverage table.
- **`KNOWN_ISSUES.md` added.** Catalogues design constraints the user should be aware of before opening an issue: atomic-write window on Windows, loading-detection HUD position assumption, English-only regex defaults, no boss detection, untested Win32 paths, and the hand-edited zones catalog. Linked from the README.

### Tests

- +5 from the docs/opt-in/undo work: `AppSettings.defaults_event_tracing_disabled_by_default`, `AppSettings.from_map_reads_event_tracing_enabled`, `SettingsRepository.save_load_preserves_diagnostics_event_tracing`, `SpeedKalandraAppIntegration.constructor_event_tracer_not_enabled_by_default`, `SpeedKalandraAppIntegration.undo_last_save_rebuilds_pbs_from_history`.
- +4 from the hydration fix: `ZoneTrackingService.run_started_with_hydrated_flag_preserves_totals`, `ZoneTrackingService.run_started_without_hydrated_flag_wipes_totals`, `SpeedKalandraAppIntegration.hydrated_run_propagates_run_id_to_stats_recorder`, `SpeedKalandraAppIntegration.hydrated_run_finalize_saves_to_history`.
- +2 from the LoadingTotalsService hydration sibling: `LoadingTotalsService.run_started_with_hydrated_flag_preserves_total_ms`, `LoadingTotalsService.run_started_without_hydrated_flag_wipes_total_ms`.

## [v0.1.3] — 2026-05

### Added

- **Client.txt setup dialog on first boot.** When `cfg.logFile` is empty or points to a missing file, a modal dialog appears with a pre-filled Steam path and a Browse button. Cancel calls `ExitApp()` — the app refuses to run without a valid log path.
- **Death penalty applied to the live timer.** `TimerService.AddPenaltyMs(ms)` and an `_OnDeathApplyTimerPenalty` handler subscribed to `Evt.DeathDetected`. With `cfg.deathPenaltyEnabled = true` (default) the timer jumps forward by `cfg.deathPenaltyMs` (default 2 min 30 s) the moment a death is detected, so the user no longer sees an inconsistency between the overlay timer and the post-finalize plot.

### Changed

- **Settings UI cleanup.** Removed the unused `Patch` field; the value is still stored internally (`cfg.gamePatch = "Unknown"`) for back-compatibility with old saved runs. Fixed a visual bug where the Client.txt Edit auto-expanded vertically when the path was long.

### Tests

- 19 new tests (13 unit covering `TimerService.AddPenaltyMs`, 6 integration covering the death-penalty handler's guard paths).

## [v0.1.2]

### Fixed

- **Loading-detection timeouts no longer silently discarded** (Bug #5). When a loading screen exceeded `cfg.loadingVisualMaxMs` (default 90 s, slow PCs), `LoadingDetectionService` correctly detected the timeout but then dropped the event via a `durationMs > maxMs` filter in `_End`. The HUD-return event for that loading never reached the bus, so the run plot underestimated total loading time. Timeouts now publish with the real duration (no clamp).

### Changed

- **Duration formatting consolidated** (audit #19). Four near-identical copies of `FormatMs` were collapsed into a single `Duration.FormatMs` in `domain/values/duration.ahk`. All call sites updated.
- **Multi-line log entries are quieter** (audit #26). Stack-trace style entries now indent continuation lines instead of producing N separate timestamped rows.
- **Version visible in three UI surfaces** (audit #30): tray tooltip, Settings window title, run plot footer.

## [v0.1.1]

### Fixed

- **`TextEncoding.ConvertUtf16ToUtf8` and `MigrateIniToUtf8` removed** (Bug #2). The migration produced INIs with a UTF-8 BOM, and AHK v2's `IniRead(path, section, key, default)` silently returns the default on UTF-8 BOM files. Result: every key-based read after migration returned the fallback value — settings, run state, personal bests all looked freshly-installed. Reverted to UTF-16 LE BOM throughout. Documented in `text_encoding.ahk` and `ARCHITECTURE.md` §14.
- **"Lechtansi" bug: zone timer kept ticking during pause.** A `[SCENE]` line emitted by the game while alt-tabbed became a `ZoneChanged` event, which restarted `_startMs` in `ZoneTrackingService` even though `TimerPaused` had been observed earlier. Added a `_timerPaused` flag so `_OnZoneChanged` respects pause state.

## [v0.1.0] — first public release

Switched to public SemVer (`MAJOR.MINOR.PATCH`). Pre-1.0 signals "functional, evolving, no API-stability commitment" and pairs with the in-app AI-assistance disclaimer.

### Added

- **Export / import of run history** as JSON. `RunExportService` serializes runs (optionally with PBs, optionally anonymized); `RunImportService` previews + applies imports with conflict resolution by content signature. Two new dialogs (`ExportOptionsDialog`, `ImportPreviewDialog`).

### Removed

- Legacy `_LIXEIRA/` (deleted from gitignored tree) — campaign route system, step-based splits, replay engine, gem planner, build planner. Pre-rewrite paradigm; no migration path. Final wave of the demolition that started in pre-public v17.x development.

---

## Pre-release history (`v17.x`, internal)

The `v17.x` tags are from the pre-public iteration of the project, when the codebase was being incrementally rewritten under the paradigm now described in `ARCHITECTURE.md`. They have no SemVer mapping and are no longer present in source comments. The rewrite produced the layered architecture (`core/`, `domain/`, `infra/`, `app/`, `ui/`), the EventBus, the repository pattern around INI persistence, and the test framework — see `ARCHITECTURE.md` for the resulting design.

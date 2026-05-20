# SpeedKalandra — Regression Coverage Matrix

Maps catalogued bugs to the tests that prove the fix. Useful for ensuring no bug returns silently in a future refactor.

Bug IDs are stable and referenced by test names — e.g. `bug21_*` in the suite maps to `#21` below. Don't renumber.

---

## Pre-release audit bugs

### 🔴 Blockers

| #     | Symptom                                                  | Fix in                                            | Regression test                                                                                                                          |
| ----- | -------------------------------------------------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| #1    | Time of the last zone lost in FinalizeRun                | `zone_tracking_service.ahk::_OnTimerStopped`      | `ZoneTrackingServiceTests::timer_stopped_flushes_active_zone_before_zeroing`, `…::run_completed_flushes_active_zone_to_totals`            |
| #2    | `deathCount` inflated by boss kills                      | `log_monitor_service.ahk` `_characterName` filter | `LogMonitorServiceTests::death_not_published_when_does_not_match_character`, `…::death_not_published_when_character_name_empty`           |
| #4    | AutoStart wipe of hydrated run after reload              | `auto_start_service.ahk::__New(.., runService)`   | `AutoStartServiceTests::constructor_run_active_false_when_no_run_service_provided`, `…::constructor_queries_run_service_when_provided`    |
| #7    | PB atomicity                                             | `personal_best_repository.ahk::Save`              | `PersonalBestRepositoryTests::save_does_not_leave_tmp_behind`, `…::save_creates_file`, `…::roundtrip_load_save_preserves_pbs`              |
| #25   | `Map has no method Count` (enriched catch)               | `app.ahk` (try/catch with What/Line/File)         | No direct test (error message logic). Indirectly covered by `SpeedKalandraAppIntegrationTests::constructor_*` (does not throw).            |
| #33–34| Surface of WARN/ERROR on boot                            | `log_service.ahk` (`_warnCount`/`_errorCount`)    | `LogServiceTests::warn_counter_increments_regardless_of_min_level`, `…::error_counter_increments_regardless_of_min_level`, `…::reset_counts_zeroes_warn_and_error_counters` |

### 🟠 Pre-v1.0

| #   | Symptom                                                | Fix in                                       | Regression test                                                                                                  |
| --- | ------------------------------------------------------ | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| #3  | runId collision in the same second                     | `run_service.ahk::_GenerateRunId` (+ms)      | `RunServiceTests::new_run_generates_run_id_in_yyyyMMdd_HHmmss_nnn_format`                                         |
| #5  | Blocking prompt without pausing the timer              | `app.ahk::_PromptHydratedRun`                | Headless skip — not directly tested. Functionality skipped in `SpeedKalandraAppIntegrationTests` (headless=true). Same skip pattern applied to the Client.txt setup dialog. |
| #8  | `try` without `catch` (multiple)                       | Several services                             | No direct test (code pattern). Covered by the absence of silenced logs in existing tests.                         |
| #9  | Riverbank resets level on every entry                  | `app.ahk::_OnZoneEnteredForLevel` + flag     | `SpeedKalandraAppIntegrationTests::bug9_*`                                                                         |
| #11 | autoStartRegex default in English                      | `app_settings.ahk`                           | `AppSettingsTests::defaults_auto_start_regex_is_wounded_man_line` + `defaults_auto_finalize_regex_empty`. Default reverted to the Wounded Man line (`i)Wounded Man: By the First Ones!` — case-insensitive via PCRE flag) with caveat documented: non-EN players edit via the Settings dialog. |
| #12 | Obsolete test suite                                    | Moved to `_LIXEIRA/`                         | N/A (cleanup)                                                                                                      |
| #27 | Misleading atomicity doc                               | `atomic_write.ahk` (comment-only)            | N/A (comment-only)                                                                                                 |
| #32 | Log without rotation                                   | `log_service.ahk::_RotateIfTooBig`           | `LogServiceTests::constructor_rotates_existing_log_over_5mb`, `…::constructor_does_not_rotate_when_log_under_threshold` |

### 🟡 Cleanup

| #   | Symptom                                            | Fix in                                          | Regression test                                                                                       |
| --- | -------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| #13 | Empty directories                                  | Moved to `_LIXEIRA/`                            | N/A                                                                                                    |
| #14 | Services not instantiated                          | Moved to `_LIXEIRA/`                            | N/A                                                                                                    |
| #15 | Settings for dead features                         | `app_settings.ahk` removed keys                 | `AppSettingsTests::defaults_*` (doesn't mention removed keys)                                          |
| #16 | Hotkey `^!g` + `GamePauseHotkeyHelpers` class      | `speedkalandra.ahk` removed                     | N/A (cleanup)                                                                                          |
| #17 | `#Warn All, Off`                                   | `speedkalandra.ahk` `#Warn VarUnset`            | N/A (config)                                                                                           |
| #18 | `ReplayClock` dead code                            | `core/clock.ahk` removed                        | N/A (cleanup)                                                                                          |
| #19 | Duplicated `_FormatMs`                             | `Duration.FormatMs(ms)` static                  | `DurationTests::format_ms_*` (9 tests covering the contract). 4 callers refactored to delegate. |
| #20 | "Smoke fix Turno N" comments                       | `log_monitor_service.ahk` rewritten             | N/A (comment-only)                                                                                     |
| #21 | SCENE for ZoneChanged (PoE2 does not emit "entered")| `log_monitor_service.ahk`                       | `LogMonitorServiceTests::scene_also_publishes_zone_changed_event_bug_21`, `…::scene_with_*_is_filtered` |
| #22 | EventBus leaves empty keys on Unsubscribe          | `event_bus.ahk::Unsubscribe`                    | `EventBusTests::unsubscribing_last_handler_removes_key_from_internal_map`                              |
| #24 | `_ComputeTotalsHash` Map order                     | Discarded (Map preserves order)                 | N/A                                                                                                    |
| #29 | `README-DIST.txt` wrong hotkey/color               | `build-dist.ps1`                                | N/A (build script)                                                                                     |
| #30 | Build does not embed version                       | `src_v2/version.ahk::Version.STRING`            | N/A (display-only). Propagated to tray IconTip, Settings dialog title, Plot subheader. |
| #31 | OverlayModeService subscribes to dead commands     | `overlay_mode_service.ahk` removed subs         | `OverlayModeServiceTests::constructor_subscribes_to_3_commands` (validates count)                       |

---

## UX feature additions

Not bugs — they are new behaviors covered by tests to shield against future regressions. Catalogued here so refactors preserve the 4 intentional invariants.

| Feature | Implementation | Regression test |
| ------- | -------------- | --------------- |
| Client.txt setup dialog on 1st run (app doesn't run without a valid path) | `app.ahk::_PromptLogFileSetupIfNeeded` + helpers `_SetupBrowseLog`/`_SetupValidatePath`. Called in `Start()` between `_ShowDisclaimerIfNeeded` and `_PromptHydratedRun`. Cancel → `ExitApp()`. | Headless skip (pure UI). Integration tests use `headless=true` which skips the dialog on the first line of the method — same strategy as the disclaimer and the hydrated run prompt. |
| Settings dialog Edit with fixed height (`h22`) so it doesn't auto-expand with long paths | `settings_dialog.ahk::_AddEdit` opts string contains `h22` | N/A (UI-only, no testable behavior) |
| Death penalty applied to the timer in real-time (previously only in the post-finalize plot) | New `TimerService.AddPenaltyMs(ms)` + handler `app.ahk::_OnDeathApplyTimerPenalty` subscribed to `Evt.DeathDetected` in `_WireEventHandlers` | `TimerServiceTests::add_penalty_ms_*` (13 tests covering: true/false return per input type, behavior in RUNNING/PAUSED/IDLE, no timer freeze, no events published, float→int coercion, multiple applications, survival across Pause/Resume). `SpeedKalandraAppIntegrationTests::death_penalty_*` (6 tests covering: happy path, the 4 handler guards, multiple deaths, custom `cfg.deathPenaltyMs` value). |
| "Patch" field removed from the Settings dialog (kept internally as `cfg.gamePatch="Unknown"` for back-compat) | `settings_dialog.ahk` (Label+Edit+save removed), `run_stats_plot_dialog.ahk` (Patch dropped from subTxt). `AppSettings.gamePatch` kept as an internal field. | N/A (UI removal). `AppSettingsTests` keeps passing because the field remains in AppSettings with default. |

---

## Bugs discovered during construction of the test suite

### Infrastructure layer (W4.x)

| # | Symptom | Fix in | Regression test |
| - | ------- | ------ | --------------- |
| W4.1 | PersonalBest INI written in UTF-8 but `IniRead` needs UTF-16 LE BOM | `personal_best_repository.ahk::Save` changed from "UTF-8" to "UTF-16" | `PersonalBestRepositoryTests::iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom` (documents AHK pitfall) |

### Pure services (W5.x)

| # | Symptom | Fix in | Regression test |
| - | ------- | ------ | --------------- |
| W5.1 | `_MapToDebugStr` with integer keys was comparing `m[k]` (int) vs string keys, returned absence | (test framework) | Covered by `LoadingDetectionServiceTests` (uses integer keys in the points Map) |
| W5.2 | `_SafeCategoryLabel` scope-dependent — dynamic lookup via `%"..."%` failed in isolated tests without builder in scope | `run_history_repository.ahk::_SafeCategoryLabel` hardcoded fallback | `RunHistoryRepositoryTests::safe_category_label_fallback_for_known_categories`, `…::safe_category_label_passes_through_unknown` |

### Catalogued during test-driven sweep (W9.x)

| # | Symptom | Fix in | Regression test |
| - | ------- | ------ | --------------- |
| W9.1 | `MigrateIniToUtf8` corrupted `IniRead` (latent footgun) | `text_encoding.ahk` (API removed) | `TextEncodingTests::bug2_convert_utf16_to_utf8_was_removed`, `…::bug2_migrate_ini_to_utf8_was_removed` |
| W9.2 | `LoadingDetectionService._End` discarded timeouts (> maxMs vanished silently) | `loading_detection_service.ahk::_End` removed `> maxMs` filter | `LoadingDetectionServiceTests::tick_timeout_publishes_loading_measured`, `…::bug5_loading_100s_publishes_with_real_duration`, `…::bug5_loading_300s_publishes_with_real_duration` |

---

## AutoHotkey v2 pitfalls (not bugs, but non-obvious behaviors)

Catalogued to avoid reintroducing them:

| Pitfall                                                                                      | Doc / Regression                                                                            |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `IniRead` key-lookup only works on UTF-16 LE BOM (UTF-8 BOM silently returns default)         | `PersonalBestRepositoryTests::iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom`     |
| Local variables named after a builtin (`Run`, `File`, `Edit`, `Buffer`) trigger `#Warn All`   | Pitfall #4 in the project README. Convention: `run` → `runItem`, `file` → `selectedFile`, `edit` → `editCtrl` |
| Local variables with class names (case-insensitive!) — `runId` vs class `RunId`              | Convention: `runId` → `currentRunId`. Applied across ~10 files during the case-collision sweep.                    |
| `throw` does not fit inside an arrow function (AHK v2 parser)                                | Pitfall #1 in the README                                                                     |
| Closure-in-loop captures by reference (not value)                                            | `CompactLayoutWidget::_BindVendorButton` uses a helper method to create a fresh scope         |
| Object-literal with method: arrow `() => …` must receive `this` as the first param          | Pitfall #11 in the README                                                                    |
| `IniWrite` creates UTF-16 LE BOM by default on new files                                      | Documented in `IniFile.__New` and `text_encoding.ahk`                                         |
| Single-line `if` without braces with `:=` may confuse the parser                              | Convention: always use multi-line braces. Pitfall #12 in the README                          |
| `\"` is not a valid escape in AHK v2 — use `""` (doubled) or single quotes `'...'` as outer delimiter | Discovered when trying `"text \"The Riverbank\""`. Adopted convention: single quotes inside a string between double quotes |

---

## How to keep this doc up to date

1. **When you fix a bug**: add a line in the appropriate table with a link to the test.
2. **When you add a test that covers bug behavior**: mark `RegressionFor: #N` in the test's docstring.
3. **Bugs still pending**: mark with 🚧 in the "Fix in" column and reference an issue/comment.
4. **AHK pitfalls discovered**: add to the final section with a test that documents it.

To run the whole suite:
```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk
```

To run only specific regression tests:
```
AutoHotkey64.exe tests_v2\run_tests.ahk bug9
AutoHotkey64.exe tests_v2\run_tests.ahk regression
```

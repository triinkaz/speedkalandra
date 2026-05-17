# src_v2 — SpeedKalandra Architecture (v17.15)

Minimalist PoE2 speedrun tracker. Composition Root + EventBus + Services + Domain.

> **Historical decisions and demolition context**: see `ARCHITECTURE.md` at the root (>240KB, mixes current state and the history of the waves).

## Current layout

```
src_v2/
├── core/                          ; Basic infrastructure
│   ├── event_bus.ahk              ; Synchronous pub/sub
│   ├── log_service.ahk            ; Logger with log rotation + WARN/ERROR counters
│   └── clock.ahk                  ; RealClock + FakeClock
│
├── domain/                        ; Pure models (no I/O)
│   ├── values/
│   │   ├── duration.ahk
│   │   └── ids.ahk                ; runId helpers
│   ├── app_settings.ahk           ; Root configuration aggregate
│   ├── overlay_layout.ahk         ; OverlayPosition + OverlayLayout (Compact/Micro/Steve)
│   ├── run_state.ahk              ; Persisted state of an in-progress run (crash recovery)
│   ├── window_state.ahk           ; microLocked, steveLocked
│   └── xp_rules.ahk               ; XP table per level + helpers
│
├── infra/                         ; I/O
│   ├── io/                        ; ini_file, csv_file, json_file, atomic_write, text_encoding
│   ├── settings_repository.ahk    ; AppSettings <-> speedkalandra.ini
│   ├── run_state_repository.ahk   ; RunState <-> data/run_state.ini + zone_totals.txt
│   ├── run_history_repository.ahk ; Finalized runs <-> data/runs/{runId}.ini
│   ├── personal_best_repository.ahk ; PBs <-> data/personal_bests.ini
│   └── zones_catalog.ahk          ; Parser for data/zones.csv (77 PoE2 zones)
│
├── app/                           ; Orchestration
│   ├── bus/
│   │   ├── commands.ahk           ; Command constants (Cmd.*)
│   │   └── events.ahk             ; Event constants (Evt.*)
│   ├── services/                  ; ~20 services (lifecycle, detection, plot, etc.)
│   └── app.ahk                    ; Composition Root (SpeedKalandraApp)
│
└── ui/                            ; GUIs
    ├── theme.ahk                  ; Color palette + Font helpers
    ├── widget_base.ahk            ; Base class for GDI+ widgets
    ├── layout_widget_base.ahk     ; Base class for layouts (Compact/Micro/Steve)
    ├── compact_layout_widget.ahk  ; COMPACT overlay (720x80)
    ├── micro_layout_widget.ahk    ; MICRO overlay (200x32)
    ├── steve_layout_widget.ahk    ; STEVE overlay (v17.14, the happy whale)
    ├── settings_dialog.ahk
    ├── line_chart_renderer.ahk
    ├── run_stats_plot_dialog.ahk
    └── run_history_dialog.ahk
```

## Conventions

| Item                    | Convention           | Example            |
| ----------------------- | -------------------- | ------------------ |
| Classes                 | `PascalCase`         | `EventBus`         |
| Public methods          | `PascalCase`         | `Subscribe()`      |
| Private methods         | `_PascalCase`        | `_Log()`           |
| Public properties       | `camelCase`          | `isRunning`        |
| Private properties      | `_camelCase`         | `_subs`, `_clock`  |
| Constants               | `UPPER_SNAKE_CASE`   | `MAX_LOG_SIZE`     |
| Files                   | `snake_case.ahk`     | `event_bus.ahk`    |

## How to run

```
AutoHotkey.exe speedkalandra.ahk
```

That's the definitive entry point. Requires AutoHotkey v2.

## No automated tests (v17.15)

The legacy suite (~2500 tests) referenced classes that went to `_LIXEIRA/` during the demolition of Waves 1-6. It was archived in `_LIXEIRA/onda_7_tests_obsoletas/` and was not migrated. A deliberate decision to go to production without automated coverage in this version. Rewrite planned for Wave 8.

## Migration status

**v17.15: production-ready.** The wave-based demolition (1-6) eliminated the previous paradigm (campaign_route.ini route system, route editor, splits per step, targets, replay engine, CSV summaries, gem planner, build planner) and rebuilt the current minimalist app:

| Wave | Scope | Status |
|------|-------|--------|
| 0 | Extraction of boss_catalog.ini + zones.csv | ✅ |
| 1 | Demolition of the route paradigm (8 sub-waves) | ✅ |
| 2 | BossFightTracker + standalone BossTimerService | ✅ |
| 3 | ZoneTrackingService + ZonesCatalog | ✅ |
| 4 | 2 widgets (Compact + Micro) | ✅ |
| 5 | RunStatsPlotBuilder + RunStatsRecorder | ✅ |
| 6 | TimerService + RunService + AutoFinalize + rebuilt composition root | ✅ |
| 7 | AutoStart + GamePauseDetection (disconnected in v17.5) + cleanup | ✅ |
| 8 | VendorRegex slots in Compact widget + StevenTheHappyWhale layout (v17.14) | ✅ |
| 7-cleanup | Production audit + bug fixes (v17.15) | ✅ |

## Important design decisions

### Tolerant EventBus

Each service publishes events (`Evt.RunStarted`, `Evt.ZoneChanged`, ...) and/or subscribes to commands (`Cmd.NewRunRequested`, ...). A handler that throws in one subscriber does not prevent the others (`try/catch` in `Publish` with log). Safe Unsubscribe during Publish via array cloning. **After an Unsubscribe that empties the subscriber list, the key is deleted from the Map** (avoids leak in long sessions with Stop/Start cycles — v17.15 Bug #22).

### Headless mode in widgets and dialogs

Every UI accepts a `_headless := true` flag in the constructor. In headless, `Show()`/`Open()` become no-ops, and the testable part (state, validation, transformations) stays accessible via the public API. Used by the (extinct) test harness; preserved for the future reintroduction of tests.

### Unified Composition Root

`SpeedKalandraApp` (`src_v2/app/app.ahk`) is the only place where objects are instantiated and wired. Everything else receives deps via constructor. To understand the whole app, just read `app.ahk` top to bottom.

### Atomic persistence (best effort)

`infra/io/atomic_write.ahk` implements write-via-tempfile + FileMove with REPLACE_EXISTING. **Not fully atomic on Windows** (delete-then-rename internally), risk accepted for a single-thread desktop app. Covers 99% of mid-write crash cases.

### Manual zones catalog

`data/zones.csv` (77 zones, semicolon format with header) is hand-edited. The legacy RePoE pipeline was scrapped in the demolition. Adding new zones requires editing the CSV manually.

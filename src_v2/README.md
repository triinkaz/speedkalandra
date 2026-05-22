# src_v2 — SpeedKalandra source tree

Minimalist PoE2 speedrun tracker. The runtime is a single AHK v2 process organized as Composition Root + EventBus + Services + Domain. Top-down read of `app/app.ahk` is enough to understand the entire object graph.

> The full architectural tour is in [`ARCHITECTURE.md`](../ARCHITECTURE.md) at the repo root.

## Layout

```
src_v2/
├── core/                              ; Cross-cutting primitives
│   ├── event_bus.ahk                  ; Synchronous pub/sub (FIFO, clone-on-iterate)
│   ├── log_service.ahk                ; Logger with rotation + WARN/ERROR counters
│   └── clock.ahk                      ; RealClock + FakeClock
│
├── domain/                            ; Pure values + rules (no I/O)
│   ├── values/
│   │   ├── duration.ahk
│   │   └── ids.ahk                    ; runId helpers
│   ├── app_settings.ahk               ; Root configuration aggregate
│   ├── overlay_layout.ahk             ; OverlayPosition + OverlayLayout (Compact/Micro/Steve)
│   ├── run_state.ahk                  ; Persisted run state (crash recovery)
│   ├── window_state.ahk               ; microLocked, steveLocked flags
│   └── xp_rules.ahk                   ; XP table per level + helpers
│
├── infra/                             ; I/O — files, INI, JSON, CSV
│   ├── io/                            ; ini_file, csv_file, json_file, atomic_write, text_encoding, run_export_format
│   ├── settings_repository.ahk        ; AppSettings <-> speedkalandra.ini
│   ├── run_state_repository.ahk       ; RunState <-> speedkalandra.ini [RunState] + speedkalandra_zones.txt
│   ├── run_history_repository.ahk     ; Finalized runs <-> data/runs/{runId}.ini
│   ├── personal_best_repository.ahk   ; PBs <-> data/personal_bests.ini
│   └── zones_catalog.ahk              ; Parser for data/zones.csv (77 PoE2 zones)
│
├── app/                               ; Orchestration
│   ├── bus/
│   │   ├── commands.ahk               ; Cmd.* constants
│   │   └── events.ahk                 ; Evt.* constants
│   ├── services/                      ; ~20 services
│   └── app.ahk                        ; SpeedKalandraApp — composition root
│
└── ui/                                ; Widgets and dialogs
    ├── theme.ahk                      ; Color palette + font helpers
    ├── widget_base.ahk                ; Base for GDI+ widgets
    ├── layout_widget_base.ahk         ; Base for layout widgets (Compact/Micro/Steve, Classic + Plus)
    ├── compact_layout_widget.ahk      ; Classic variant
    ├── compact_layout_plus_widget.ahk ; Plus variant (BETA, opt-in)
    ├── micro_layout_widget.ahk
    ├── micro_layout_plus_widget.ahk
    ├── steve_layout_widget.ahk
    ├── steve_layout_plus_widget.ahk
    ├── settings_dialog.ahk
    ├── line_chart_renderer.ahk
    ├── run_stats_plot_dialog.ahk
    ├── run_history_dialog.ahk
    ├── death_stats_dialog.ahk         ; Aggregate "deaths per zone" view
    ├── export_options_dialog.ahk
    └── import_preview_dialog.ahk
```

## Conventions

| Item                | Convention           | Example            |
| ------------------- | -------------------- | ------------------ |
| Classes             | `PascalCase`         | `EventBus`         |
| Public methods      | `PascalCase`         | `Subscribe()`      |
| Private methods     | `_PascalCase`        | `_Log()`           |
| Public properties   | `camelCase`          | `isRunning`        |
| Private properties  | `_camelCase`         | `_subs`, `_clock`  |
| Constants           | `UPPER_SNAKE_CASE`   | `MAX_LOG_SIZE`     |
| Files               | `snake_case.ahk`     | `event_bus.ahk`    |

## How to run

```
AutoHotkey.exe speedkalandra.ahk
```

Requires AutoHotkey v2. The entry point is `speedkalandra.ahk` at the repo root, which includes everything under `src_v2/`.

## Tests

The full automated test suite lives in [`../tests_v2/`](../tests_v2/) — 2000+ unit + integration tests covering `core/`, `domain/`, `infra/`, `app/services/`, `ui/`, and end-to-end wiring of `SpeedKalandraApp`. Run with:

```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk
```

See `tests_v2/README.md` for framework conventions and the assertion API, and `tests_v2/REGRESSION-COVERAGE.md` for the bug → test mapping.

## Important design decisions

### Tolerant EventBus

Services publish events (`Evt.RunStarted`, `Evt.ZoneChanged`, …) and subscribe to commands (`Cmd.NewRunRequested`, …). A handler that throws does not block the others — `Publish` wraps each handler in `try/catch` and logs the failure. `Unsubscribe` during `Publish` is safe (the subscriber list is cloned before iteration). After an `Unsubscribe` that empties a subscriber list, the key is deleted from the internal Map to avoid leaks across long-running `Start`/`Stop` cycles.

### Headless mode in widgets and dialogs

Every UI surface accepts a `headless := true` flag in the constructor. In headless, `Show()` / `Open()` become no-ops, but the testable surface (state, validation, transformations) remains accessible via the public API. The full integration suite uses this so it can exercise `SpeedKalandraApp.__New` without touching real GUI.

### Unified Composition Root

`SpeedKalandraApp` (`app/app.ahk`) is the only place where objects are instantiated and wired. Every other class receives its dependencies via constructor. To understand the whole app, read `app.ahk` top to bottom.

### Atomic persistence (best effort)

`infra/io/atomic_write.ahk` implements write-via-tempfile + `FileMove` with `MOVEFILE_REPLACE_EXISTING`. Not fully atomic on Windows (the underlying `MoveFileEx` does a delete-then-rename internally); the inconsistency window is short enough — milliseconds, single-threaded — to be acceptable for desktop save patterns. Covers 99% of mid-write crashes.

### Manual zones catalog

`data/zones.csv` (77 zones, semicolon-delimited with header) is hand-edited. Adding new zones requires editing the CSV directly.

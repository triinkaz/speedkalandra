# SpeedKalandra — Architecture

> **Status:** Public release. AutoHotkey v2 desktop overlay for Path of Exile 2 speedrunning.
>
> This document describes the **current architecture**. It does not track historical decisions or refactor history — see git history for that.

---

## 1. What the App Does

SpeedKalandra is a single-process AHK v2 script that runs alongside Path of Exile 2 and:

- **Tails the game's `Client.txt`** to detect zone changes, character level ups, deaths, area level changes, and window focus events.
- **Detects loading screens** via pixel sampling of the PoE2 HUD regions (life/mana/hotbar).
- **Tracks a "run"** — a span of gameplay with a stable timer, accumulated time per zone, death count, and per-act checkpoints.
- **Renders three overlay widgets** (Compact, Micro, Steve) showing real-time stats with always-on-top behavior and click-through outside Ctrl.
- **Persists state** for crash recovery (timer, zone totals, current run metadata).
- **Saves finished runs** to disk with full breakdown, and surfaces them in a history dialog and run plot.
- **Tracks personal bests** per zone and per act, updated only on completed runs.
- **Exports / imports** run history as JSON for sharing or backup.

The app is fully driven by an in-process event bus. There are **no globals** beyond the entry point's `app` instance.

---

## 2. Layered Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  ui/         Gui widgets, dialogs, theme                     │
│    Subscribes to Events for state. Publishes Commands.       │
└──────────────────────────────────────────────────────────────┘
                  ▲ Events                  │ Commands
                  │                         ▼
┌──────────────────────────────────────────────────────────────┐
│  app/        Services, EventBus, composition root            │
│    Stateful logic. Subscribes to Commands, publishes Events. │
└──────────────────────────────────────────────────────────────┘
                  ▲ pull              │ depends on
                  │                   ▼
┌──────────────────────────────────────────────────────────────┐
│  domain/     Pure value objects, rules, no I/O               │
└──────────────────────────────────────────────────────────────┘
                  ▲ depends on              │ implements
                  │                         ▼
┌──────────────────────────────────────────────────────────────┐
│  infra/      I/O: INI, CSV, JSON, atomic writes, repositories│
└──────────────────────────────────────────────────────────────┘
                  ▲
                  │
┌──────────────────────────────────────────────────────────────┐
│  core/       Cross-cutting primitives: EventBus, Clock, Log  │
└──────────────────────────────────────────────────────────────┘
```

Dependencies flow **downward only**. `domain` knows nothing about `infra`, `app`, or `ui`. `core` knows nothing about anything else. The composition root in `app/app.ahk` is the only place that wires the layers together.

---

## 3. Directory Layout

```
SpeedKalandra/
├── speedkalandra.ahk           Entry point. Tray menu, #Include order, OnExit.
├── speedkalandra.ini           User settings (created on first run).
├── data/
│   ├── zones.csv               77 PoE2 campaign zones (name, internal id, act, isTown).
│   ├── speedkalandra.log       App log (rotated at 5 MB).
│   ├── personal_bests.ini      Run PB, per-act PBs, per-zone PBs.
│   ├── speedkalandra_zones.txt Zone totals of the in-progress run (txt for write speed).
│   ├── deaths.csv              Append-only log of every detected death (zone, patch, build).
│   └── runs/                   One INI file per finished run.
├── exports/                    Default destination for JSON exports.
├── assets/                     Static images (whale icon, etc).
└── src_v2/
    ├── version.ahk
    ├── core/
    │   ├── event_bus.ahk
    │   ├── log_service.ahk
    │   └── clock.ahk
    ├── domain/
    │   ├── values/             duration.ahk, ids.ahk
    │   ├── app_settings.ahk
    │   ├── overlay_layout.ahk
    │   ├── run_state.ahk
    │   ├── window_state.ahk
    │   └── xp_rules.ahk
    ├── infra/
    │   ├── io/                 atomic_write, ini_file, csv_file, json_file,
    │   │                       run_export_format, text_encoding
    │   ├── settings_repository.ahk
    │   ├── run_state_repository.ahk
    │   ├── run_history_repository.ahk
    │   ├── personal_best_repository.ahk
    │   ├── death_log_repository.ahk
    │   └── zones_catalog.ahk
    ├── app/
    │   ├── bus/
    │   │   ├── events.ahk      Evt.* constants
    │   │   └── commands.ahk    Cmd.* constants
    │   ├── services/           ~20 services (see § 5)
    │   └── app.ahk             SpeedKalandraApp — composition root
    └── ui/
        ├── theme.ahk
        ├── widget_base.ahk
        ├── layout_widget_base.ahk
        ├── compact_layout_widget.ahk
        ├── micro_layout_widget.ahk
        ├── steve_layout_widget.ahk
        ├── settings_dialog.ahk
        ├── run_stats_plot_dialog.ahk
        ├── run_history_dialog.ahk
        ├── death_stats_dialog.ahk
        ├── export_options_dialog.ahk
        ├── import_preview_dialog.ahk
        ├── line_chart_renderer.ahk
        └── hotkey_formatter.ahk
```

---

## 4. Core Primitives (`core/`)

### EventBus

In-process, synchronous pub/sub. Single instance, owned by the composition root.

- `Subscribe(eventName, callback)` registers a handler; returns the callback as an unsubscribe token.
- `Publish(eventName, data := "")` calls all handlers **in subscription order (FIFO)**. The handler list is cloned before iteration, so handlers may safely `Subscribe`/`Unsubscribe` mid-publish.
- A handler that throws is isolated: the error is logged and the next handler still fires.
- When all handlers for an event are unsubscribed, the key is removed from the internal Map. Prevents leaks in long sessions with `Start`/`Stop` cycles.

Subscription order matters: see "Subscribe order in `__New`" in § 6.

### LogService

Severity-tagged, line-based logger.

- Four levels: `DEBUG < INFO < WARN < ERROR`. `minLevel` filter applied at write time.
- **Buffered**: in production, INFO/DEBUG accumulate in a buffer of 32 lines before a single `FileAppend`. `WARN`/`ERROR` flush immediately (and flush any pending buffer first to preserve chronological order).
- **WARN/ERROR counters** increment regardless of `minLevel`. The composition root surfaces a `TrayTip` at boot if either is non-zero, then resets them.
- **Rotation**: at construction, if the log file exceeds 5 MB, it is renamed to `.log.old` and a fresh file begins. Single rotation only (no multi-generation history).
- Test doubles: `NullLogger` (no-op) and `InMemoryLogger` (captures entries for assertion).

### Clock

Time abstraction. Services that depend on time receive a clock by constructor.

- `RealClock.Now()` → `A_Now` string, `NowMs()` → `A_TickCount` (monotonic ms).
- `FakeClock` for tests: `SetNow(s)`, `AdvanceMs(n)`, `AdvanceSeconds(n)`, `AdvanceMinutes(n)`, `SyncNowFromMs()`.

---

## 5. Services (`app/services/`)

All services are constructed by the composition root and receive their dependencies explicitly. Most subscribe to bus events in their `__New`, expose pull-based queries, and (sometimes) publish events of their own.

### Time and Run Lifecycle

| Service | Responsibility | Key events |
|---|---|---|
| **TimerService** | Mechanical timer: `Start`/`Pause`/`Resume`/`Stop`/`Reset`/`Toggle`/`Hydrate`/`AddPenaltyMs`. Tracks `_baseMs` and `_startTick`, computes `GetRunMs()` lazily. `AddPenaltyMs(ms)` commits the current delta and adds a flat amount to `_baseMs` — used by the composition root when a death is detected and `cfg.deathPenaltyEnabled`, so the penalty becomes visible in the overlay immediately instead of only post-finalize in the run plot. Silent (no event published — widgets pick it up on the next `Tick`). | Publishes `Evt.TimerStarted`/`Paused`/`Resumed`/`Stopped`/`Reset`. |
| **RunService** | Run lifecycle on top of TimerService: `NewRun`, `FinalizeRun`, `CancelRun`, `ResetRun`. Holds `RunState` (runId, startedAt, status, runBaseMs). | Subscribes to `Cmd.NewRunRequested`/`FinalizeRun`/`Cancel`/`Reset`. Publishes `Evt.RunStarted`/`Completed`/`Cancelled`/`Reset`. |
| **ActCheckpointTracker** | Captures the total `runMs` at each `(act, stage)` transition (first `ZoneEntered` of a new act-or-stage closes the previous one). Maintains two parallel views: `_checkpointsByActStage` keyed by composite `"act|stage"` (the canonical post-B1 view consumed by per-stage PBs) and the legacy `_checkpointsByAct` keyed by integer act (last-write-wins, preserved for callers not yet migrated). Output consumed by `PersonalBestService` and persisted in run history. | Subscribes to `Evt.ZoneEntered`, run lifecycle events. |
| **AppTickEmitter** | Periodic `Evt.Tick` (default 300 ms). Widgets refresh on tick instead of running their own timers. | Publishes `Evt.Tick`. |

### Game State Detection

| Service | Responsibility | Key events |
|---|---|---|
| **LogMonitorService** | Tails `Client.txt`. `Tick()` is called every 250 ms by the composition root. Parses six line types (character level up, area level, scene, "you have entered", death, window focus) and publishes raw events. Filters deaths by character name to avoid counting boss kills. Republishes `[SCENE]` as `ZoneChanged` because modern PoE2 sometimes skips "you have entered". On startup, seeds state from the last 64 KB of the file. | Publishes `Evt.LogLineRead`, `CharacterLevelUp`, `AreaLevelChanged`, `SceneEntered`, `ZoneChanged`, `DeathDetected`, `WindowFocusChanged`. |
| **ZoneTrackingService** | Per-zone time accounting using `ZoneChanged` events. Tracks `_activeZone`, `_startMs`, `_totals`, `_runActive`, `_timerPaused`. Time only accumulates when a run is active **and** the timer is not paused. Exposes totals to widgets and persists snapshots to `speedkalandra_zones.txt`. | Subscribes to `Evt.ZoneChanged`, timer events, run lifecycle. Publishes `Evt.ZoneEntered` (enriched with act + isTown from catalog) and `Evt.ZoneTimeAccumulated`. |
| **XpService** | Pure state of `(characterName, characterClass, characterLevel, currentAreaLevel, currentAreaCode)`. Delegates penalty calculation to `XpRules` (domain). No subscriptions — the composition root pushes updates from log events. | None. |
| **LoadingDetectionService** | Detects loading screens between zones. Armed by `Evt.AreaLevelChanged` ("Generating level X area Y"); polls HUD every 25 ms via `HudPixelScanner`; ends when HUD returns or on timeout. Skipped when window focus, timer pause, or panel keys make the measurement unreliable. | Publishes `Evt.LoadingMeasured`. |
| **LoadingTotalsService** | Accumulates `Evt.LoadingMeasured` durations into a single `_totalMs` for the current run. Persisted in `[RunState].LoadingTotalMs`. | None published. |
| **HudPixelScanner** | Pure function. Samples three regions of the game window (mana, life, hotbar) using an injected pixel reader and decides whether the HUD is visible. Used by `LoadingDetectionService`. Pixel reader is `PixelGetColor` in production, mockable in tests. | None. |

### Focus and Auto-Triggers

| Service | Responsibility |
|---|---|
| **FocusAutoPauseService** | Pauses the timer when PoE2 loses focus, resumes when it regains. **Hybrid detection**: subscribes to `Evt.WindowFocusChanged` (fast path from log) **and** polls `WinActive("ahk_exe PathOfExile…")` every tick (~300 ms) as a backup, because modern PoE2 does not reliably emit `[WINDOW] Gained focus` in `Client.txt`. Both paths call the same idempotent handler. Match is by `ahk_exe` to avoid false positives on browsers / Discord channels with similar titles. |
| **AutoStartService** | Watches `Evt.LogLineRead` against `cfg.autoStartRegex`. On match (and only if no run is already active), publishes `Cmd.NewRunRequested`. Empty regex = no-op. Queries `RunService.IsActive()` at boot so a hydrated run is not wiped by the first matching log line. |
| **AutoFinalizeService** | Same shape as AutoStart but for `cfg.autoFinalizeRegex` → `Cmd.FinalizeRunRequested`. Fires at most once per run (dedup by runId). |

### Overlay and Input

| Service | Responsibility |
|---|---|
| **OverlayModeService** | Tracks the active overlay mode (`compact` / `micro` / `steve`) and lock flags. Publishes `Evt.OverlayModeChanged`. |
| **OverlayModeApplier** | Subscribes to `Evt.OverlayModeChanged` and calls `SetModeVisible(shouldShow)` on each registered widget. Pure routing — knows only the widget id ↔ mode mapping. |
| **OverlayInteractionService** | Singleton (`Instance` static). Handles three behaviors: Ctrl-drag (move window), Ctrl-wheel (resize via scale), and click-through (toggles `WS_EX_TRANSPARENT` on registered Hwnds when Ctrl is up/down). Polls Ctrl state at 50 ms and updates per-widget opacity for hover-fade (overlay dims to ~10% when the mouse hovers it, full opacity when Ctrl is held). Drag is event-driven via `OnMessage(WM_MOUSEMOVE)` + `OnMessage(WM_LBUTTONUP)` with explicit `SetCapture` on LBUTTONDOWN (required because `_OnLButtonDown` returns 0 to suppress the click on child buttons, which also suppresses `DefWindowProc`'s automatic capture); a 100 ms watchdog covers the lost-LBUTTONUP edge case (cross-process focus stolen mid-drag). |
| **HotkeyService** | Registers global hotkeys for nine actions. Each action maps to a `Cmd.*` constant. For dialog-opening actions (`Settings`, `PlotRunStats`), sends a blind `{Ctrl up}{Alt up}{Shift up}` before publishing to prevent the "stuck modifier" artifact when the dialog steals focus from the game. |

### Recording, Reporting, Export

| Service | Responsibility |
|---|---|
| **RunStatsRecorder** | Reactive buffer for the current run. Accumulates `Evt.LoadingMeasured` events into `_loadingEvents` and counts `Evt.DeathDetected`. Exposes `GetSnapshot(zoneTotals, runDurationMs)` for the plot builder. |
| **RunStatsPlotBuilder** | Pure aggregator. Takes a snapshot and produces a `Map` with totals per category (Map / Town / Loading / Deaths) and a sorted `details` array (one entry per zone visit + per loading event + a synthetic Deaths entry). Run history is saved in exactly this shape. |
| **PersonalBestService** | Loads PBs at construction. Pull-based: the composition root calls `UpdateFromRun(runMs, runId, zoneTotals, actCheckpoints)` after a successful save of a completed run. PBs are kept in four buckets: legacy global run PB, **per-(act, stage)** run PB (`Map<"act|stage", ms>` — the post-B1 canonical view: normal Act 1 and cruel Act 1 maintain independent PBs), legacy per-act run PB (`Map<actNum, ms>`, projected from the stage-aware bucket as `Act<N>|normal` only, kept for callers not yet migrated), and per-zone PB. `RebuildFromHistory` exists for rebuilding PBs after a run deletion. |
| **RunExportService** | Loads runs from `RunHistoryRepository`, optionally bundles PBs and anonymizes character data, and writes JSON via `RunExportFormat.Serialize` + atomic write. Publishes `Evt.RunsExported`. |
| **RunImportService** | Two phases: `Preview(path)` parses + validates the JSON file and returns a summary (new / identical / rename-on-conflict) without writing. `Execute(preview, pbStrategy)` then persists. Conflict resolution is by content signature (`runId + totalMs + deathCount + maxActReached + details.Length`). PB strategy is one of `keep` / `rebuild` / `replace`. Publishes `Evt.RunsImported`. Refuses imports above `RunImportService.MAX_FILE_BYTES` (10 MB) before `FileRead`. `RunExportFormat.ValidateSchema` enforces per-payload caps from the same source of truth (`MAX_RUNS_PER_FILE=5000`, `MAX_STRING_LEN=500`, `MAX_DETAILS_PER_RUN=1000`, `MAX_TOTALS_PER_RUN=200`, `MAX_ZONE_PBS=200`, `MAX_ACT_CHECKPOINTS=20`) and runs `RunId.IsValid` on `runId` and `runPbRunId`. |
| **DeathStatsService** | Aggregates `data/deaths.csv` (written by `DeathLogRepository`) for the `DeathStatsDialog`. Pure read service: `Aggregate(filter := "")` returns `{totalDeaths, perZone, availablePatches, availableProfiles}` in one pass over the in-memory CSV. No cache — every call re-reads the file, which is fine because the dataset is small (one row per death across all play sessions) and the dialog is opened on demand. Town zones are dropped via `ZonesCatalog.IsTownName` when a catalog is wired (defensive against unknown zones — a zone the catalog doesn't recognize passes through to the chart). `availablePatches` / `availableProfiles` are extracted from the **whole** dataset, not the filtered subset, so the dialog's two dropdowns stay populated as the user cycles through filters. The `perZone` array is sorted by count desc via a stable insertion sort; the available lists are sorted case-insensitively via `StrCompare(..., 1)` so the dropdown order is predictable across locales. |
| **DeathLogScanner** | Alternative read path for the `DeathStatsDialog`'s "All-time (from log)" view. One-shot streaming scan of Client.txt that bypasses `data/deaths.csv` entirely — reads the raw log, resolves zones via the catalog, applies a **campaign-only filter** (anything not in `data/zones.csv` is dropped — hideouts, atlas maps, endgame trials, towns), and returns the same `perZone` shape `DeathStatsService` produces. Cruel difficulty is detected via the **`C_` prefix** on the internal area code (`C_G3_3` = Jungle Ruins in Cruel) and surfaces as a separate row with a `" (Cruel)"` suffix; the catalog is not duplicated for cruel — the suffix is dynamic. Zone detection has **three signals** in precedence order: `Generating level X area "<code>"` (highest — the only way to detect cruel since PoE2 does NOT emit `[SCENE] Set Source` for cruel zones, verified empirically), `[SCENE] Set Source [<name>]` (fallback for normal-difficulty and when the area-gen line is truncated), and `<NAME> has been slain.` (counted against the most recent resolved zone, or to `skippedNonCampaign` if none resolved). Pure: no event bus, no disk writes, no shared state with `DeathLogRepository`. Duplicates three regexes from `LogMonitorService` by design — a shared parser module for three patterns would be more plumbing than the duplication itself, and the live tail carries unrelated complexity (state machine, partial-line handling, focus/level-up branches) that would weigh down a shared module. Headless-safe; the dialog calls it synchronously, briefly freezing the UI on large logs. |

---

## 6. Composition Root (`app/app.ahk`)

`SpeedKalandraApp` is the single place where objects are created and wired. Reading `app.ahk` top-to-bottom is enough to understand the entire object graph.

Four collaborators live alongside `app.ahk` in `src_v2/app/` and exist precisely to keep the composition root focused on wiring rather than on the flows they implement:

| Class | File | Purpose |
|---|---|---|
| **BootPrompts** | `boot_prompts.ahk` | Disclaimer / Client.txt setup / hydrated-run modals. Driven from `Start()`. Headless mode short-circuits each method. |
| **RunSnapshotSaver** | `run_snapshot_saver.ahk` | `RunCompleted` / `RunCancelled` handler + tray-undo flow. Subscribes via late-bound callback in `__New`. |
| **RunStatePersister** | `run_state_persister.ahk` | 5 s persistence tick (skip-cache via hash) + final flush from `Stop()` + `PersistSettings` callback for widgets, dialogs, and boot prompts. |
| **LiveReconfigurationHandlers** | `live_reconfiguration_handlers.ahk` | Death-penalty timer update, hotkey rebind, PB reset (destructive). Subscribed in `_WireEventHandlers` as one-line delegates. |

A small number of handlers stay inline in `app.ahk` because they need direct access to fields owned by the composition root (`_OnLogFilePathChanged` mutates `_logMonitorTimer`) or because they coordinate state shared between several services (`_OnZoneEnteredForLevel` for the Riverbank-resets-level rule, `_OnRunEndedClearZones` for the cross-service cache reset).

The constructor:

1. Loads `AppSettings` from disk via `SettingsRepository`.
2. Builds `core` primitives: `LogService`, `EventBus`, `RealClock`.
3. Constructs domain catalogs and repositories.
4. **Registers the run-finalization handlers for `RunCompleted` / `RunCancelled` *first*** — before instantiating `ZoneTrackingService` and `RunStatsRecorder`, which zero their state on those same events. Because the bus dispatches FIFO, this guarantees the save handler runs with intact state. The subscriptions are late-bound (`(data) => this._snapshotSaver.Save(...)`) because `RunSnapshotSaver` itself depends on services that don't exist yet at subscription time; it is constructed near the end of `__New`, once they do.
5. Constructs all services in dependency order. Each receives its deps explicitly.
6. Hydrates services from persisted state: `RunService.Hydrate`, `ZoneTrackingService.Hydrate` + `SetRunActive`, `LoadingTotalsService.Hydrate`, `XpService.Hydrate`, `OverlayModeService.Hydrate`. The hydrated loading total and zone totals are captured in locals and then handed to `RunStatePersister.PrimeLoadingTotalCache` / `PrimeZoneTotalsCache` once the persister is constructed, so the first `Tick()` doesn't redundantly rewrite the just-loaded state.
7. Constructs widgets and dialogs.

`Start()`:

1. Drives the three **boot-time modals** in sequence via `BootPrompts`:
   - **Disclaimer** on first boot or until acknowledged.
   - **Client.txt setup** if `cfg.logFile` is empty or points to a file that doesn't exist. Default suggested path is the Steam install location; Cancel calls `ExitApp()` — the app is not allowed to run without a valid log path.
   - **Hydrated run prompt** (Resume / Finalize / Discard) when boot finds an active run from a previous session. Timer is paused during the prompt to not bleed seconds while the user thinks.
2. Wires runtime event handlers (`_WireEventHandlers`).
3. Starts `LogMonitorService` and registers a 250 ms `SetTimer` to drive its `Tick()`.
4. Starts `FocusAutoPauseService`, `HotkeyService`, `OverlayInteractionService`, optionally `LoadingDetectionService`.
5. Shows widgets and applies the current overlay mode.
6. Starts `AppTickEmitter`.
7. Registers the 5-second persistence tick (`() => this._persister.Tick()`).
8. Surfaces boot warnings/errors as a `TrayTip` if any.

In `_headless = true` mode (used by every integration test), `BootPrompts` short-circuits on the first line of each method, so the test suite never touches GUI. The same flag is checked by widgets and other dialog classes for the same reason.

`Stop()` reverses the order: stops timers, stops services, hides widgets, calls `RunStatePersister.PersistSettings` + `Flush` to commit final state, flushes the log.

**`Stop()` is terminal.** The lifecycle is `__New` → `Start` → `Stop`, exactly once. `Start()` after `Stop()` throws (`start_after_stop_throws` in the integration suite covers this); `Stop()` itself is idempotent so duplicated teardown from `OnExit` + an explicit tray-Exit click is safe (`stop_is_idempotent`). The app does not support live restart in the same process; reload is implemented as a fresh AHK process via the tray menu's Reload item, which exits this process and re-launches the script. The OnExit handler in `speedkalandra.ahk` is what makes that reliable — it sends defensive modifier key-ups before invoking `Stop()` so a Reload that fires while the user is holding a hotkey doesn't leave a modifier logically stuck in the game.

**Dispose vs Stop, by design.** `Stop()` releases every service that owns an external resource: AHK SetTimers (`tickEmitter`, `loadingDetection`, `overlayInter`, the app's own `_logMonitorTimer` and `_runPersistTimer`), AHK `Hotkey()` registrations at the OS level (`hotkeyService`), file-tail state (`logMonitor`), the bus interceptor (`eventTracer`), and the Gui handles for the three widgets (`Hide()` calls `gui.Destroy()`). Services that only subscribe to the bus and own no other resource (`LoadingTotalsService`, `ActCheckpointTracker`, `RunStatsRecorder`, `ZoneTrackingService`, `OverlayModeService`, `OverlayModeApplier`, `AutoStartService`, `AutoFinalizeService`, `RunService`) expose `Dispose()` for symmetry but are **not** invoked from `Stop()` — their only effect is `bus.Unsubscribe`, and the bus itself is dropped when the process exits or a new instance is constructed. Calling them would be cerimony with no observable effect.

---

## 7. Run Persistence (Crash Recovery)

State of the in-progress run is split across two files for performance reasons. `IniWrite` parses the entire file on every call, which became a 5–10 s thread block for runs with 20+ zones. Splitting the hot path off to plain text fixed it.

| File | Section / format | Content | Save cadence |
|---|---|---|---|
| `speedkalandra.ini` | `[RunState]` | `RunId`, `StartedAt`, `Status`, `RunBaseMs`, `LoadingTotalMs` | Transitions + 5 s tick |
| `speedkalandra_zones.txt` | `name=ms` per line | Zone totals of the current run | 5 s tick (hash-skipped if unchanged) |

The 5-second tick is hash-gated: if neither value has changed since the last write, the IniWrite/FileWrite is skipped. This keeps the main thread responsive on long runs.

Atomic writes use `AtomicWriter.WriteAll` (write `.tmp` then `FileMove` with overwrite). The implementation is **not fully atomic on Windows** (`MoveFileEx` does a delete-then-rename internally), but the inconsistency window is short enough (≈1 ms, single-threaded) to be acceptable for desktop save patterns.

---

## 8. Finished Runs (`data/runs/{runId}.ini`)

Each finished run is saved as its own INI by `RunHistoryRepository`. The file contains the exact output shape of `RunStatsPlotBuilder.Build` — already aggregated — so opening a historical run does not require re-running the builder.

```ini
[meta]
runId=20260513_051547
profile=Default
patch=Unknown
firstTs=2026-05-13 05:15:47
totalMs=3719000
deathCount=3
maxActReached=2

[totals]
mapa=2918000
cidade=226000
loading=44000
morte=450000

[checkpoints]
Act1NormalMs=1725000
Act2NormalMs=3719000

[details]
count=15
0=mapa|Cemetery of the Eternals|220000|Ato 1|
1=mapa|Clearfell|156000|Ato 1|
...
```

Details are serialized as pipe-delimited records with backslash escaping. Pipe was chosen over JSON to avoid a parser dependency — INI is already a stable reader in the project.

Save rules:

- `RunCompleted` always saves (if `totalMs ≥ 3 min`).
- `RunCancelled` saves only if `totalMs ≥ 3 min` (avoids cluttering history with test aborts).
- Save under 3 min is silently dropped, with an INFO log entry.
- After a successful completed-run save, a tray menu item "Undo last save" appears for 60 s. Clicking it deletes the run file from disk and rebuilds personal bests from the remaining history via `PersonalBestService.RebuildFromHistory`, so PBs never point to a deleted run. The tray item also auto-expires after 60 s if not clicked.

---

## 9. Personal Bests

`PersonalBestRepository` reads/writes `data/personal_bests.ini` with three sections:

```ini
[Run]
BestMs=410000
BestRunId=20260512_142345

[RunByAct]
Act1NormalMs=1725000
Act2NormalMs=3900000
Act3NormalMs=6900000
Act1InterludeMs=8200000

[Zones]
Mud Burrow=215000
Clearfell=180000
The Riverbank=95000
```

`PersonalBestService` loads at construction, exposes `GetRunPbForAct`, `GetZonePbMs`, etc., and accepts `UpdateFromRun(runMs, runId, zoneTotalsMap, actCheckpointsMap)` from the composition root. The service is pull-based (no bus subscription) precisely because run lifecycle events arrive *after* `ZoneTrackingService` has zeroed its state.

Writes are atomic: the full INI is serialized in memory and `AtomicWriter` does a `.tmp + FileMove`. This prevents the "delete-then-write split crashed mid-way" failure mode that would have erased weeks of PB history.

---

## 10. Widgets

All widgets extend `WidgetBase`. The two with rich content (`Compact`, `Steve`) extend the further-specialized `LayoutWidgetBase`. Each widget:

- Owns a single AHK `Gui` with `+AlwaysOnTop -Caption +ToolWindow +E0x80` (layered for transparency).
- Reads its position from `AppSettings.overlay.positions[widgetId]` — a shared mutable `OverlayPosition`. Drag/resize updates this object inline and calls the `onPersist` callback (which saves settings).
- Refreshes on `Evt.Tick` (300 ms) and on specific events (`ZoneEntered`, `DeathDetected`, etc).
- Caches the last rendered values to skip `SetFont` and `SetText` calls that would not change visible output (avoids unnecessary repaint).

| Widget | Purpose | Visible in mode |
|---|---|---|
| **CompactLayoutWidget** | 380×96 horizontal bar with act, zone, two timers (zone / run), death count, XP indicator, PB display, stacked Map/Town/Loading bar, and three vendor regex copy-to-clipboard buttons. | compact |
| **SteveLayoutWidget** | 380×64 minimalist layout with prominent run timer (high-frequency 50 ms refresh for millisecond rendering) and condensed deaths/XP/zone line. Compact's higher-information cousin. | steve |
| **MicroLayoutWidget** | 200×32 stripped-down bar: act, zone, timer. For when the overlay is in the way. | micro |

The three widgets are **mutually exclusive** — only one is visible at a time. `OverlayModeApplier` flips `_modeVisible` on each widget when the mode changes. The user toggles modes via lock hotkeys (`ToggleMicroLock` → Ctrl+F9, `ToggleSteveLock` → Ctrl+F8) or via the overlay toggle (F8).

Click-through is the default. While Ctrl is held, the widget under the cursor becomes interactive: left-drag moves it, mouse wheel resizes it (scale 0.5 – 3.0). Hover-fade brings the widget down to ~10% opacity when the cursor is over it (without Ctrl) so the player can see the game underneath without moving the overlay.

---

## 11. Dialogs

The app has two flavors of dialogs:

**Boot-time modals** (extracted into `app/boot_prompts.ahk`, driven from `Start()`). All three follow the same Sleep-loop pattern: build a `Gui`, attach button handlers that write to a shared `choice` closure object and destroy the window, then block on `while (choice.value = "" && WinExist("ahk_id " hwnd)) Sleep 50`. AHK v2 has no built-in `ShowModal()` — this Sleep-loop is the idiomatic way to make the call site synchronous while keeping the message pump alive.

- **Disclaimer dialog** — shown on first boot, dismissible with "I understand". A checkbox persists `cfg.disclaimerAcknowledged = true` so it doesn't show again.
- **Client.txt setup dialog** — shown when `cfg.logFile` is empty or invalid. Pre-fills the Steam install path. OK validates with `FileExist`; Cancel calls `ExitApp()`.
- **Hydrated run prompt** — shown when boot finds an active run from a previous session. Three choices: Resume / Finalize & save / Discard. Timer is paused during the prompt so seconds don't bleed into the run while the user thinks.

**Dedicated dialog classes** (live in `ui/`, opened via bus commands):

| Dialog | Opened by | Purpose |
|---|---|---|
| **SettingsDialog** | `Cmd.OpenSettingsRequested` (tray menu, hotkey) | Edit all `AppSettings` fields. Hotkey section uses `HotkeyFormatter` for human-readable display and a Capture button (InputHook-based combo recording) plus Clear; the underlying Edit is read-only. |
| **RunStatsPlotDialog** | `Cmd.OpenRunStatsPlotRequested` | Stacked-bar / line-chart visualization of the latest (or a selected historical) run. Uses `LineChartRenderer` for the time-distribution plot. Bottom-bar buttons: Details... / History... / Death Stats (publishes `Cmd.OpenDeathStatsRequested`, opening the death aggregate over `data/deaths.csv`). |
| **RunHistoryDialog** | `Cmd.OpenRunHistoryRequested` | Sortable list of past runs. Opens a run in the plot dialog. Buttons: Export selected / Export all / Import. |
| **DeathStatsDialog** | `Cmd.OpenDeathStatsRequested` (RunStatsPlotDialog button) | Aggregates `data/deaths.csv` via `DeathStatsService`. Two filter dropdowns (`Patch`, `Build`) with `"(All)"` sentinel for no-filter; ListView with three columns (Zone / Count / Bar). The Bar column is an ASCII proportion (`█` repeated, max 30 chars) because AHK v2's ListView has no per-cell custom-draw hook short of subclassing via `WM_NOTIFY` — ASCII bars stay readable in the default font, copy-paste cleanly, and survive HiDPI scaling without code. Dropdown contents are stable across filter changes (the `availablePatches` / `availableProfiles` arrays come from the unfiltered dataset), so only the ListView redraws on dropdown change. Has two modes: `live` (default — reads `data/deaths.csv` via `DeathStatsService`) and `alltime` (one-shot scan of Client.txt via `DeathLogScanner`, no filters, ephemeral; the cache is cleared on next toggle or on dialog close). The alltime view is **campaign-only** — deaths in hideouts / atlas maps / endgame trials / towns are dropped and the count surfaces in the header as `(skipped: N outside campaign zones)`. **Cruel difficulty** is detected via the `C_` prefix on the area code and surfaces as a separate row with a `" (Cruel)"` suffix (e.g. "Mud Burrow" and "Mud Burrow (Cruel)" counted independently). In alltime mode an `Export...` button appears between the toggle and Close, letting the user save the current view as CSV to a path of their choice (default folder: Downloads). The export never touches the app's data directory; the alltime view itself never persists. |
| **ExportOptionsDialog** | `Cmd.ExportRunsRequested` (with runIds in payload) | Picks output path and toggles (`Anonymize`, `Include PBs`). Calls `RunExportService.Export`. |
| **ImportPreviewDialog** | `Cmd.ImportRunsRequested` (with path in payload) | Shows summary of `RunImportService.Preview` (new / identical / rename) and lets the user pick a PB strategy before calling `Execute`. |

All dialogs that show `MsgBox` use the `SpeedKalandraMsgBox` wrapper at the entry-point level, which adds `0x40000` (MB_TOPMOST). Default `MsgBox` does not inherit `AlwaysOnTop` from its caller, so confirmation dialogs would otherwise appear behind the overlay.

---

## 12. The Event/Command Vocabulary

Two namespaces, both implemented as classes with `static` string constants to make typos throw `undefined property` at parse time rather than become silently unrouted events.

**Commands** (`app/bus/commands.ahk`) — verbs from UI to services:

- Run lifecycle: `NewRunRequested`, `ResetRunRequested`, `FinalizeRunRequested`, `CancelRunRequested`
- Timer: `TimerToggleRequested`
- UI: `OpenSettingsRequested`, `OpenRunStatsPlotRequested`, `OpenRunHistoryRequested`, `OpenDeathStatsRequested`, `ToggleOverlayRequested`, `ToggleMicroLockRequested`, `ToggleSteveLockRequested`, `SetOverlayModeRequested`
- PBs: `ResetPersonalBestsRequested`
- Export/Import: `ExportRunsRequested`, `ImportRunsRequested`

**Events** (`app/bus/events.ahk`) — facts published by services:

- Run lifecycle: `RunStarted`, `RunPaused`, `RunResumed`, `RunCompleted`, `RunReset`, `RunCancelled`
- Timer: `TimerStarted`, `TimerPaused`, `TimerResumed`, `TimerStopped`, `TimerReset`
- Game state: `ZoneChanged`, `AreaLevelChanged`, `CharacterLevelUp`, `DeathDetected`, `SceneEntered`, `WindowFocusChanged`, `LogLineRead`
- Zone tracking: `ZoneEntered` (enriched), `ZoneTimeAccumulated`
- Loading: `LoadingMeasured`
- UI/state: `Tick`, `OverlayToggled`, `OverlayModeChanged`, `WidgetVisibilityChanged`, `CtrlStateChanged`
- App: `AppStarted`, `AppStopping`
- Export/Import: `RunsExported`, `RunsImported`

---

## 13. Conventions

| Item | Convention | Example |
|---|---|---|
| Classes | `PascalCase` | `EventBus`, `ZoneTrackingService` |
| Public methods | `PascalCase` | `Subscribe()`, `GetActiveZone()` |
| Private methods | `_PascalCase` | `_Log()`, `_FlushActive()` |
| Public fields | `camelCase` | `isRunning`, `runId` |
| Private fields | `_camelCase` | `_subs`, `_clock`, `_timerPaused` |
| Constants | `UPPER_SNAKE_CASE` / `static` | `MAX_LOG_SIZE`, `POLL_MS` |
| Files | `snake_case.ahk` | `event_bus.ahk`, `focus_auto_pause_service.ahk` |

Design rules carried throughout:

- **No globals.** The only global is `app` (the composition root). Every service receives deps via constructor.
- **Strict type checks at boundaries.** `__New` validates each dependency with `is` and throws `TypeError` on mismatch.
- **Fail loud, fail early.** Validation errors throw immediately, not five calls later with a corrupted state.
- **`try` only at the borders.** I/O operations, event dispatch, and OS primitives wrap `try`; pure logic does not (an exception there is a real bug). Whether a given `try` should log on failure follows the policy in § 14 — the short version is *log where silence would hide data loss, broken state, or actionable failure*; otherwise silent is the honest option.
- **Pull, don't push, for cross-cutting state.** When run lifecycle events arrive in an order that would zero needed state (PB updates after `RunStatsRecorder.Reset`), the composition root captures state and calls the consumer with the snapshot, instead of having the consumer subscribe.
- **Headless flag.** Widgets and dialogs accept `headless := true`. In that mode `Show()`/`Open()` is a no-op but the testable surface (state, validation, computations) remains accessible.

---

## 14. Error Handling Policy

The codebase uses `try` deliberately, not by default. The rule is one line:

> **Log where silence would hide data loss, broken state, or actionable failure.**

A silent `try` (no `catch`, or `catch` with no body / only a `return`) is acceptable only when none of those three conditions apply. Every catch in the codebase falls into one of four buckets:

### 1. Catches that log via `LogService.Warn`

The default. Used everywhere the failure represents lost user data, corrupted on-disk state, or anything the operator could act on (disk full, permission denied, INI parse error, regex mismatch with no fallback). Examples: `RunStatePersister.Tick`, `RunSnapshotSaver.Save`, `RunStateRepository.SaveZoneTotals`, `PersonalBestRepository.Save`, `BootPrompts._SetupValidatePath` failure of `Configure`. Every such warn includes a context tag (`"Persister"`, `"RunSnapshotSaver"`, `"BootPrompts"`, `"App"`) so the log file is greppable.

### 2. Silent — lifecycle teardown

`Stop()`, `Dispose()`, `Hide()`, `OnExit`, and the per-service `Stop` cascades in `SpeedKalandraApp.Stop`. We're on the way out; if the failure is caused by the same condition that's killing the process (disk full, file lock), logging it would attempt another I/O against the same broken resource — at best wasted, at worst it delays the exit. Examples: `try this.tickEmitter.Stop()`, `try SetTimer(this._undoTimerFn, 0)`, `try this._timer.Pause()` before opening a modal.

### 3. Silent — cosmetic side effect with no recovery path

`TrayTip`, `log.Info` (informational, not diagnostic), tray menu item add/remove, status-label updates on a Gui that may already be destroyed. The user can't act on "TrayTip failed because notifications are disabled" — they configured it that way themselves. Logging would flood `data/speedkalandra.log` with WARNs on every boot for those users and drown out signals that actually matter. Examples: `try TrayTip(...)`, `try this._log.Info(...)`, `try SpeedKalandraTrayAddUndoItem()`, `try statusLbl.Value := "..."`.

### 4. Silent — UI fallback that aborts safely

More subtle. The pattern is `try { result := UI_Operation() } catch { return }` or `try { result := UI_Operation() return result } return defaultValue`. If the UI primitive fails (no display server, headless without provisions, permission denied for window creation), the catch is the signal that the operation didn't run. Adding a `Warn` here would create a *worse* mental model: the user sees "PB reset failed" in the log, thinks something is broken, when in fact the system did exactly what it should have done — refused to destroy data without confirmation. Examples: the `catch return` around `SpeedKalandraMsgBox` in `LiveReconfigurationHandlers.ResetPersonalBests`; the `try { FileSelect(...) }` in `BootPrompts._SetupBrowseLog`.

### How to decide when adding new code

```
Does failure here lose user data, corrupt persisted state,
or reveal an actionable problem?
  YES → catch + try this._log.Warn("...", "<ContextTag>")
  NO  → which of (2) (3) (4) applies?
         lifecycle teardown                   → silent
         cosmetic / no recovery               → silent
         UI primitive whose failure means
           "the operation did not happen"     → silent + safe return
         none of the above                    → reconsider; probably (1)
```

If adding silent code that doesn't cleanly map to (2) (3) or (4), the right move is usually to log it. Borderline cases caught during the original sweep: `RunSnapshotSaver` reading the act-checkpoints map for the saved-run payload was silent, but a failure there meant the on-disk run file would carry an empty checkpoint map without any signal — that's data loss in disguise, so it moved to bucket (1).

### Auditing the existing code

This policy was applied retroactively to the codebase. Spot checks across the four extracted composition-root collaborators (`RunStatePersister`, `RunSnapshotSaver`, `BootPrompts`, `LiveReconfigurationHandlers`) found ~24 catches in bucket (1) with explicit `Warn`s + context tags, and ~25 silent catches all classifiable in buckets (2)–(4). To find every `try` site in the repository for re-review:

```
Get-ChildItem -Recurse -Include *.ahk src_v2 |
  Select-String -Pattern '^\s*try\b' -CaseSensitive
```

A reviewer can sample any line from that list and ask: "if this throws, will the user notice something is wrong but find nothing in `speedkalandra.log`?" If yes, it's a bug. If no, it's by design.

---

## 15. AHK v2 Pitfalls Encoded in the Code

A few language quirks come up often enough that the codebase has standard patterns for them:

| Pitfall | Pattern |
|---|---|
| **`for` loop variables capture by reference** in fat-arrow closures, so the closure sees the latest value, not the iteration value. | Wrap the closure-producing code in a helper method (`_MakeXxxHandler(arg)`) — each call has its own scope, so each returned arrow captures a distinct value. Used in `SettingsDialog` for hotkey row buttons. |
| **Case-insensitive variable lookup.** A parameter named `timerService` collides with the class `TimerService` in `is` checks ("Expected a Class but got a TimerService"); a parameter named `warningSink` shadows the `WarningSink` class so `WarningSink.Resolve(warningSink)` resolves the parameter (a string by default) and throws `MethodError: This value of type "String" has no method named "Resolve"`. | Use case-insensitive-distinct names: `timerSvc`, `catalog`, `sinkOrEmpty`, etc. The pitfall surfaces silently at parse time and only fails at runtime when the shadowed class is actually dereferenced. |
| **`MsgBox` does not inherit `AlwaysOnTop`** from its caller. Confirmations appear behind the overlay. | All call sites use `SpeedKalandraMsgBox(text, title, options)` which adds the `0x40000` MB_TOPMOST flag. |
| **AHK v2 multi-line continuation.** A line starting with a quoted string literal (`" ("`) is parsed as a new statement rather than a continuation. | Prefix with `.` or refactor into separate `if`/`else` branches. |
| **`Map(...)` vs object literal.** Object literals (`{key: val}`) coerce keys to property names; `Map(key, val)` keeps key types intact. | Always use `Map(...)` for dictionaries with non-identifier keys (zone names, runIds, hotkey strings). |
| **"Stuck modifier" on dialog open.** Hotkey opens a dialog → game loses focus while Ctrl/Alt/Shift is still held → game never sees the keyup → modifier sticks. | `HotkeyService.FocusChangingActions` sends `Send "{Blind}{Ctrl up}{Alt up}{Shift up}"` immediately before publishing the command. Same pattern in the global `OnExit` handler. |
| **`WinActive` substring match.** Default `SetTitleMatchMode` of 2 matches substring, so `WinActive("Path of Exile 2")` matches a browser tab titled "Path of Exile 2 Wiki — …". | Match by `ahk_exe` instead, listing the known process names: `PathOfExile2_x64.exe`, `PathOfExile2Steam.exe`, etc. |
| **`InputHook` for hotkey capture.** Modifier-only key presses (Ctrl alone) trigger if you mark `{All}` as `E`. | Use `KeyOpt("{All}", "N")` and an `OnKeyDown` callback that ignores known modifier VKs (`0x10/A0/A1`, `0x11/A2/A3`, `0x12/A4/A5`, `0x5B/5C`). Read modifier state at capture time via `GetKeyState(name, "P")`. |
| **`IniRead` key-lookup only works on UTF-16 LE BOM files.** Files with UTF-8 BOM cause `IniRead(path, section, key, default)` to silently return the default for every key — the parser does not recognize the section/key layout. Section-only reads (without key) tolerate both encodings. | The project keeps all INIs in UTF-16 LE BOM (the AHK `IniWrite` default for new files). The `MigrateIniToUtf8` helper was removed because it produced files that broke every subsequent read. Documented in `text_encoding.ahk` and `PersonalBestRepositoryTests::iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom`. |
| **AHK v2 string escape syntax.** Backslash is not an escape character — `"text \"quoted\" text"` is a parse error (`Illegal character in expression`). | Double the quote (`"text ""quoted"" text"`) or wrap with single quotes when convenient (`"text 'quoted' text"`). |

---

## 16. Test Suite

The project ships with a self-contained test framework in `tests_v2/` written in pure AHK v2 — no external runner, no `pip install`, no `npm`. Entry point: `tests_v2/run_tests.ahk`.

**Running:**

```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk
```

Outputs to `tests_v2/tests_output.log` and shows a final `MsgBox` with pass/fail counts. A substring argument filters tests by `ClassName::method`:

```
AutoHotkey64.exe tests_v2\run_tests.ahk EventBus
AutoHotkey64.exe tests_v2\run_tests.ahk regression_bug
```

**Coverage:**

| Layer | Notable coverage |
|---|---|
| `core/` | EventBus, LogService, Clock (Real + Fake), NullLogger, InMemoryLogger |
| `domain/` | Duration, Ids, WindowState, RunState, XpRules, OverlayLayout, AppSettings |
| `infra/io/` | AtomicWriter, TextEncoding, IniFile, CsvFile, JsonFile, RunExportFormat |
| `infra/` repos | ZonesCatalog, PersonalBest, RunState, RunHistory, Settings |
| `app/services/` | Every service (pure, stateful, OS-hook) covered in its own suite |
| `app/` composition | BootPrompts, RunSnapshotSaver, RunStatePersister, LiveReconfigurationHandlers |
| `ui/` | Theme, HotkeyFormatter, WidgetBase, LayoutWidgetBase |
| `integration/` | SpeedKalandraApp full wire-up + regression suite (death-penalty handler, EventTraceLogger opt-in, UndoLastSave PB rebuild, hydration ordering) |

Full suite runs in roughly 25 seconds on a typical desktop. Headless mode (`headless := true` constructor arg on widgets/dialogs) skips Gui creation so the entire surface is exercisable.

**Regression coverage** is documented in `tests_v2/REGRESSION-COVERAGE.md`, which maps every catalogued bug (from the pre-release internal audit and from bugs found during test-suite construction) to the specific test(s) that comprove the fix. The doc also catalogues AHK v2 pitfalls encountered during development (the table in §14 is a summary of that list).

**Framework conventions:**

- One file per `TestCase` subclass under `tests_v2/unit/{layer}/{file}_tests.ahk`.
- Each test is a parameterless method; the `static Tests := [...]` array determines run order.
- Optional `Setup()` / `Teardown()` hooks per `TestCase`. Shared fixtures are in `tests_v2/framework/fixtures.ahk` (temp paths, in-memory logger, fake clock).
- Assertions use `Assert.Equal`, `Assert.True`, `Assert.False`, `Assert.Throws`, `Assert.Contains`, etc.
- `TestRegistry.Register(SuiteClass)` at the end of each suite file is what hooks the suite into the runner.

---

## 17. What This App Does Not Do

For people coming from other speedrun trackers or expecting more, the app deliberately avoids:

- **Route/step splits.** There is no campaign route, no per-step targets, no replay engine. The unit of tracking is a run with a timer, a zone, and a death count.
- **Boss detection.** PoE2 class voice lines do not appear in `Client.txt`, so reliable boss-fight tracking was not feasible.
- **Game memory reads / injection.** The app only reads `Client.txt` and samples pixels in a fixed region of the screen. It does not inject into the game process or send inputs to it.
- **External dependencies.** No npm, no pip, no DLLs beyond what ships with AHK v2 itself. The entire codebase plus its test suite runs from a fresh AutoHotkey install with no setup.

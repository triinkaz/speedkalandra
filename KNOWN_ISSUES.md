# Known Issues & Limitations

Design constraints to be aware of before reporting them as bugs. Actual bugs
go on the GitHub issue tracker.

## File writes are not fully atomic on Windows

`AtomicWriter` writes to a `.tmp` file then calls `FileMove` with overwrite,
which maps to `MoveFileEx` with `MOVEFILE_REPLACE_EXISTING`. Windows
implements that as delete-then-rename, leaving a ~1 ms window where a crash
could lose the file. Single-threaded desktop usage with sporadic saves
makes the practical risk negligible, but it is not theoretically
crash-proof. Full rationale in `src_v2/infra/io/atomic_write.ahk`.

## Loading detection depends on the default HUD position

`LoadingDetectionService` samples pixel colors at fixed screen coordinates
matching the PoE2 default HUD layout. Custom UI scaling, non-native
resolutions, or unusual aspect ratios can cause the detector to miss or
miscount loading screens. If the widget's loading total never moves, this
is the likely cause.

## English client only

PoE2 translates `Client.txt` to match the UI language, and every parser
in the app matches against English text. Lines the parser looks for
include `[SCENE] Set Source [...]` (zone transitions), `has been slain`
(deaths), `is now level` (character level-ups), `Generating level N area X
with seed` (area level changes), and `[WINDOW] Lost focus` /
`Gained focus` (auto-pause), plus the default auto-start and
auto-finalize regexes. On a non-English client none of these match.

The auto-start and auto-finalize regexes are user-configurable in Settings.
Loading detection (pixel-based) is the only feature that is genuinely
language-agnostic. A non-English user can still time runs manually with
loading isolation, but per-zone tracking, deaths, and level tracking will
be empty.

## No boss detection

PoE2's `Client.txt` does not log boss class-voice-line markers reliably
enough to base detection on. Per-act and per-zone breakdowns work; per-boss
does not.

## A few UI paths are not covered by automated tests

`LineChartRenderer` uses `DllCall` into Gdi32/User32 and needs a real
display — not testable without a desktop session. A few interactive paths
in `OverlayInteractionService` (`_OnLButtonDown`, `_OnMouseWheel`, the
drag handlers `_OnDragMove`/`_OnDragUp`/`_DragWatchdog`, and
`_UpdateHoverState`) need real `OnMessage`/Win32 events and are only
partially covered via lifecycle and state-machine tests. Everything else
(layered architecture, services, persistence, run lifecycle) has unit
and integration coverage.

## Zones catalog is hand-edited

`data/zones.csv` (PoE2 campaign zones, semicolon-delimited) is maintained
by hand. Adding new zones from a future patch requires editing the file —
there is no automatic sync against the game's data files.

## Interrupted-visit accumulator not persisted across restarts

When `FinalizeRun` fires, the zone that was active at the moment of the
hotkey has its visit time discounted from the run's PB-eligible zone
totals — the visit never closed via a zone transition, so it isn't
comparable to a normal completed visit. The visit accumulator that drives
this discount lives in `ZoneTrackingService._currentVisitMs` and is
deliberately not written to `speedkalandra.ini`.

This matters in one narrow edge case: app crash mid-run, restart
(which hydrates the zone totals from disk), then finalize via hotkey
without crossing another zone transition first. After the restart the
accumulator resets to 0 and only counts the post-hydrate elapsed, so the
interrupted zone gets less subtracted than it should and the resulting
zone PB candidate is too low for that one zone in that one run. The other
run's zones, the global run PB, and per-act PBs are unaffected.

Decision: not persisted by design. Crash plus same-zone hotkey plus no
intervening transition is a rare combination, and persisting per-visit
elapsed adds an INI write on every flush. The user can simply finalize on
a different zone or rerun for a clean PB.

## Death log is decoupled from run history

Every detected death is appended to `data/deaths.csv` by
`DeathLogRepository` at the moment `Evt.DeathDetected` fires —
independent of run lifecycle. Deleting a run from
`RunHistoryDialog` (the trash icon) removes the run's `.ini` file
and rebuilds personal bests, but it does **not** retract the rows
that run's deaths contributed to `deaths.csv`. The Death Stats
dialog will still show those deaths in the per-zone counts.

The split is deliberate. `deaths.csv` answers "where does the
player die across all play sessions, ever", which is the question
the per-zone aggregate exists to answer. Coupling it to run
history would make the aggregate jump around every time the user
prunes test aborts or short runs from the history list, which is
the noisy end of the same dataset the user is trying to learn
from. The dialog's filters (`Patch`, `Build`) cover the
legitimate "narrow to a specific build/season" use case without
requiring history-level deletion.

Decision: a user who really wants to retract specific deaths can
edit `data/deaths.csv` directly (semicolon-delimited, UTF-8,
double-quoted fields per `CsvFile`). There is no UI for it because
the edit is a one-shot per league and the file format is stable.

## All-time scan briefly freezes the dialog on large logs

The `"All-time (from log)"` toggle in `DeathStatsDialog` runs
`DeathLogScanner.Scan` synchronously — a streaming `FileOpen +
ReadLine` over the entire `Client.txt`. For an active player who
has not rotated the log, the file can reach hundreds of MB; the
scan then takes a few seconds to complete and the dialog (and the
rest of the overlay) is unresponsive during that time.

Decision: synchronous by design. The user clicked an explicit
"from log" button so a brief pause is expected; making the scan
asynchronous would require a `SetTimer`-driven chunked reader with
cancelation + partial-result rendering, which is a lot of moving
parts for a feature that the user invokes at most a few times per
session. Restarting the toggle re-scans from scratch — nothing is
cached across toggles, so the time cost repeats per click. The
live view (CSV-backed) has no such freeze; it reads the small
append-only `deaths.csv` instead.

## Per-zone totals and per-zone PBs merge Normal and Interlude visits

A PoE2 EA run is "campaign (Acts 1–4) + Interlude (Acts 1–4 in cruel
difficulty)". The B1 tracking pipeline (see `CHANGELOG.md`) added
stage-aware handling at the event layer (`ZoneChanged.stage`), the
act-checkpoint layer (per-`(act, stage)` checkpoints), the personal-best
layer (per-`(act, stage)` PB), and the plot dialog (the **Interlude**
entry in the Act Filter dropdown keeps only Interlude details). What B1
did NOT extend is per-zone time accumulation: `ZoneTrackingService._totals`
is still keyed by zone name alone, so Normal-Act-1 Mud Burrow and
Interlude-Act-1 Mud Burrow fold into a single bucket. The same holds for
per-zone PBs (`PersonalBestService.GetZonePbMs("Mud Burrow")` returns one
value across both stages).

User-facing consequence: the **By map** granularity in the Run Statistics
plot dialog shows one row per zone name, summing both stages. To see
Interlude-only times, pick **Interlude** in the Act Filter — the chart
rebuilds against Interlude-stage details only, but the rows are still
aggregated per zone name (`Mud Burrow` is one row, not `Mud Burrow` and
`Mud Burrow (Interlude)` as separate rows).

The all-time death view (`DeathLogScanner` + `DeathStatsDialog`) is the
one surface that DOES distinguish: it surfaces cruel deaths under a
separate row with a ` (Cruel)` suffix (e.g. `Mud Burrow` and
`Mud Burrow (Cruel)` as independent rows). The technical signal there is
the `C_` prefix on the area code in the `Generating level X area
"<code>"` line; the suffix renders the literal engine term ("Cruel")
rather than the user-facing label ("Interlude") because the scanner is a
one-shot raw-log read with no stage propagation — the suffix is the only
place the distinction lives in that path.

Out of scope for B1. A future iteration would extend
`ZoneTrackingService` to maintain `_totalsByStage` and propagate the
stage dimension to downstream consumers (per-`(zone, stage)` PBs, plot
dialog showing distinct rows for Normal vs Interlude visits to the same
zone, deaths.csv carrying stage at append time so the live view matches
the all-time view). Tracked in the internal backlog.

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
in `OverlayInteractionService` (`_OnLButtonDown`, `_OnMouseWheel`,
`_DragTick`, `_UpdateHoverState`) need real `OnMessage`/Win32 events and
are only partially covered via lifecycle and state-machine tests.
Everything else (layered architecture, services, persistence, run
lifecycle) has unit and integration coverage.

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

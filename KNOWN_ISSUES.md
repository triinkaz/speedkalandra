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

## Auto-start / auto-finalize regex defaults are English-only

The default `autoStartRegex` and `autoFinalizeRegex` match lines from the
English PoE2 client. Other client languages need either custom regexes (set
in Settings) or the manual hotkeys. Zone detection, deaths, level changes,
and loading detection work regardless of client language — they rely on
stable text fragments and pixel patterns.

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

; ============================================================
; Version - global version constant for SpeedKalandra
; ============================================================
;
; v17.15 (Bug #30): introduced to surface the version number.
;
; v0.1.0 (first public release): adopted SemVer for external
; versioning. Pre-1.0 signals "functional but still evolving, no
; commitment to API stability". Pairs with the disclaimer.
;
; v0.1.1: Bug #2 (TextEncoding) - ConvertUtf16ToUtf8 and
;   MigrateIniToUtf8 APIs removed (they broke IniRead on UTF-8 BOM).
;
; v0.1.2: Bug #5 (LoadingDetectionService) - timeouts now publish
;   LoadingMeasured with the real duration (previously discarded by
;   the `> maxMs` filter, causing underestimated loading time on
;   slow PCs). Also #19 (Duration.FormatMs consolidation), #26
;   (multi-line log hygiene), #30 (version embed in 3 UI surfaces).
;
; v0.1.3: 4 UX features:
;   1. Client.txt setup dialog on first run (app doesn't run without
;      a valid path).
;   2. Fix visual bug in the Settings Edit (fixed h22 height to avoid
;      auto-expand when the path is long).
;   3. Death penalty now applies to the timer in real time (previously
;      only shown in the post-finalize plot). New TimerService.AddPenaltyMs(ms)
;      + _OnDeathApplyTimerPenalty handler subscribed to Evt.DeathDetected.
;   4. Removed Patch field from the Settings dialog (kept internally
;      as cfg.gamePatch="Unknown" for back-compat with old runs).
;   +19 new tests (13 unit TimerService.AddPenaltyMs + 6 integration
;   of the handler), total suite ~1557 green.
;
; Internal tags in the code (v17.15.x) are historical and remain for
; change traceability — they are not used in public releases.
;
; Where it appears:
;   - Tray tooltip (A_IconTip in speedkalandra.ahk)
;   - Settings dialog (window title)
;   - Run plot (footer)
;
; MANUAL UPDATE:
;   Before each release, bump STRING here. There is no automation in
;   the build script yet.
;
;   SemVer: MAJOR.MINOR.PATCH
;     - PATCH (0.1.0 -> 0.1.1): bug fixes that don't add features
;     - MINOR (0.1.0 -> 0.2.0): new features, backward-compatible
;     - MAJOR (0.x -> 1.0): first "stable" release. After that, bump
;       MAJOR only when public compatibility breaks.

class Version
{
    static STRING := "v0.1.3"
}

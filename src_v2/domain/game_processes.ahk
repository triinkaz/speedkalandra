; ============================================================
; GameProcesses - PoE2 executable names (single source of truth)
; ============================================================
;
; Two services match against the foreground / running process by
; ahk_exe (exact process name): FocusAutoPauseService uses the
; list for focus detection and process-death detection;
; LoadingDetectionService uses it to locate the game window for
; HUD scanning. Both must compare against the SAME list of names
; or one service silently breaks the moment a new build ships
; (e.g. focus auto-pause works on a fresh launcher, but loading
; measurements stop firing because the window provider can't find
; the window).
;
; Exact ahk_exe match (not title substring) is mandatory: a
; substring match against window titles would hijack the checks
; for a browser tab titled "Path of Exile 2 - Wiki" or a Discord
; channel named after the game.
;
; Adding a new build requires a single edit here -- both services
; pick it up automatically, and game_processes_tests.ahk locks
; the contract.

class GameProcesses
{
    ; Every known PoE2 executable across launchers (Steam,
    ; standalone, hypothetical future variants) plus the shared
    ; PoE1 executables that the same scripts can encounter when
    ; the user has both games installed. The defensive entry
    ; PathOfExile2Steam.exe covers a hypothetical Steam launcher
    ; variant that doesn't ship today but would slot into the
    ; same checks without code changes.
    static POE2_EXECUTABLES := [
        "PathOfExile2Steam.exe",
        "PathOfExile2_x64.exe",
        "PathOfExile2.exe",
        "PathOfExile_x64Steam.exe",
        "PathOfExileSteam.exe",
        "PathOfExile_x64.exe",
        "PathOfExile.exe"
    ]
}

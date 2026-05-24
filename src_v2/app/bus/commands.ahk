; ============================================================
; Commands - command names published by the UI on the EventBus
; ============================================================
;
; Convention: pass through the bus as a string, BUT always via a constant:
;   bus.Publish(Commands.PauseRequested)         OK
;   bus.Publish("PauseRequested")                 NO (silent typo)
;
; A typo in "Commands.PauseRequsted" throws "undefined property"
; instead of turning into an event nobody listens to.
;
; Each Command represents INTENT ("the user wants X"). The Service
; decides whether the action happens (it may ignore if inappropriate).

class Commands
{
    ; --- Run lifecycle ---
    static NewRunRequested      := "Cmd.NewRunRequested"
    static ResetRunRequested    := "Cmd.ResetRunRequested"
    static FinalizeRunRequested := "Cmd.FinalizeRunRequested"
    static CancelRunRequested   := "Cmd.CancelRunRequested"

    ; --- Timer ---
    static TimerToggleRequested := "Cmd.TimerToggleRequested"

    ; --- UI ---
    static OpenSettingsRequested     := "Cmd.OpenSettingsRequested"
    static OpenRunStatsPlotRequested := "Cmd.OpenRunStatsPlotRequested"
    static OpenRunHistoryRequested   := "Cmd.OpenRunHistoryRequested"
    static OpenDeathStatsRequested   := "Cmd.OpenDeathStatsRequested"

    ; Single user-facing layout control: published by the
    ; CycleLayout hotkey (HotkeyService). Cycles the overlay mode
    ; STEVE -> COMPACT -> MICRO -> STEVE; handled by
    ; OverlayModeService.CycleLayout.
    ;
    ; Replaced the earlier ToggleMicroLockRequested /
    ; ToggleSteveLockRequested / ToggleOverlayRequested trio.
    ; The two Toggle*Lock commands gave the user two separate
    ; hotkeys for the same conceptual action ("pick a layout");
    ; ToggleOverlay (hide/show the overlay) was redundant with
    ; the hover-dim that already drops opacity to ~10% when the
    ; mouse passes over the overlay. Old INI binds on the Toggle*
    ; actions are migrated to CycleLayout in SettingsRepository
    ; ._LoadHotkeys so existing users don't lose their muscle
    ; memory after the upgrade.
    static CycleOverlayLayoutRequested := "Cmd.CycleOverlayLayoutRequested"

    ; Programmatic API — kept for direct mode targeting from code
    ; (tests, hydrate paths). Not bound to any default hotkey.
    static SetOverlayModeRequested   := "Cmd.SetOverlayModeRequested"

    ; --- Personal Bests ---
    static ResetPersonalBestsRequested := "Cmd.ResetPersonalBestsRequested"

    ; --- Run export/import ---
    static ExportRunsRequested := "Cmd.ExportRunsRequested"
    static ImportRunsRequested := "Cmd.ImportRunsRequested"

    ; --- Route (B4 Stage 2) ---
    ; Published by any of the 4 anchor-eligible timer widgets
    ; (micro/micro_plus/steve/steve_plus) when the user Ctrl+Clicks
    ; the bottom-right arrow. The composition root handles it:
    ; flips cfg.routeWidgetVisible, persists settings, then
    ; publishes Evt.RouteVisibilityToggled with the new value.
    static ToggleRouteVisibilityRequested := "Cmd.ToggleRouteVisibilityRequested"
}

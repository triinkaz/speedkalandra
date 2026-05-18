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
    static ToggleOverlayRequested    := "Cmd.ToggleOverlayRequested"
    static ToggleMicroLockRequested  := "Cmd.ToggleMicroLockRequested"
    static ToggleSteveLockRequested  := "Cmd.ToggleSteveLockRequested"
    static SetOverlayModeRequested   := "Cmd.SetOverlayModeRequested"

    ; --- Personal Bests (v17.13) ---
    static ResetPersonalBestsRequested := "Cmd.ResetPersonalBestsRequested"

    ; --- Run export/import (v0.1.0) ---
    static ExportRunsRequested := "Cmd.ExportRunsRequested"
    static ImportRunsRequested := "Cmd.ImportRunsRequested"

    ; --- Overlay panel keys (auto-MICRO mode) ---
    static PanelKeyPressed  := "Cmd.PanelKeyPressed"
    static PanelKeyReleased := "Cmd.PanelKeyReleased"
}

; ============================================================
; Commands - nomes de comandos publicados pela UI no EventBus (Onda 6)
; ============================================================
;
; Convencao: passe pelo bus como string, MAS sempre via constante:
;   bus.Publish(Commands.PauseRequested)         OK
;   bus.Publish("PauseRequested")                 NAO (typo silencioso)
;
; Erro de typo em "Commands.PauseRequsted" estoura "undefined property"
; em vez de virar evento que ninguem escuta.
;
; Cada Command representa INTENCAO ("o usuario quer X"). Quem decide
; se a acao acontece eh o Service (pode ignorar se inapropriado).

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

    ; --- Export/Import de runs (v0.1.0) ---
    static ExportRunsRequested := "Cmd.ExportRunsRequested"
    static ImportRunsRequested := "Cmd.ImportRunsRequested"

    ; --- Overlay panel keys (auto-MICRO mode) ---
    static PanelKeyPressed  := "Cmd.PanelKeyPressed"
    static PanelKeyReleased := "Cmd.PanelKeyReleased"
}

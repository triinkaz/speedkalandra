; ============================================================
; Events - nomes de eventos publicados por Services no EventBus
; ============================================================
;
; Convencao: igual a Commands, sempre via constante.
;
; Cada Event representa FATO ("X aconteceu"). Multiplos subscribers
; reagem (widget atualiza, repository persiste, logger registra, etc.).

class Events
{
    ; --- Run lifecycle ---
    static RunStarted    := "Evt.RunStarted"      ; data: {runId, startedAt, profileId}
    static RunPaused     := "Evt.RunPaused"       ; data: {runId, elapsedMs}
    static RunResumed    := "Evt.RunResumed"      ; data: {runId, elapsedMs}
    static RunCompleted  := "Evt.RunCompleted"    ; data: {runId, durationMs}
    static RunReset      := "Evt.RunReset"        ; data: {runId}
    static RunCancelled  := "Evt.RunCancelled"    ; data: {runId}

    ; --- Timer (mecanica pura) ---
    static TimerStarted  := "Evt.TimerStarted"   ; data: {runMs}
    static TimerPaused   := "Evt.TimerPaused"    ; data: {runMs}
    static TimerResumed  := "Evt.TimerResumed"   ; data: {runMs}
    static TimerStopped  := "Evt.TimerStopped"   ; data: {runMs}
    static TimerReset    := "Evt.TimerReset"     ; data: {scope: "all"}
    static TimerUndone   := "Evt.TimerUndone"    ; data: {runMs}

    ; --- Game state (vindos do log monitor) ---
    static ZoneChanged       := "Evt.ZoneChanged"       ; data: {zoneName, sceneId}
    static AreaLevelChanged  := "Evt.AreaLevelChanged"  ; data: {areaLevel, areaCode}
    static CharacterLevelUp  := "Evt.CharacterLevelUp"  ; data: {character, class, level}
    static DeathDetected     := "Evt.DeathDetected"     ; data: {character}
    static SceneEntered      := "Evt.SceneEntered"      ; data: {sceneId}
    static NpcDialogue       := "Evt.NpcDialogue"       ; data: {npc, line}
    static WindowFocusChanged := "Evt.WindowFocusChanged" ; data: {state} in {"lost", "gained"}
    static LogLineRead       := "Evt.LogLineRead"       ; data: {line}

    ; --- Zone tracking (Onda 3) ---
    ; Publicados pelo ZoneTrackingService apos ZoneChanged enriquecer
    ; com metadata do ZonesCatalog (act, isTown).
    static ZoneEntered          := "Evt.ZoneEntered"          ; data: {zoneName, actIndex, isTown, enteredAt}
    static ZoneTimeAccumulated  := "Evt.ZoneTimeAccumulated"  ; data: {zoneName, durationMs, totalMs}

    ; --- Loading detection (Fase 9.2) ---
    ; Publicado por LoadingDetectionService quando uma medicao de loading
    ; (de Generating level ate HUD voltar) eh fechada com sucesso.
    static LoadingMeasured := "Evt.LoadingMeasured"    ; data: {durationMs, fromZone, toZone, source, score, anchor}

    ; --- Tick (UI refresh trigger) ---
    static Tick := "Evt.Tick"   ; data: {runElapsedMs, isRunning, isPaused}

    ; --- Settings/UI ---
    static ProfileChanged       := "Evt.ProfileChanged"       ; data: {profileId, profileName}
    static OverlayToggled       := "Evt.OverlayToggled"       ; data: {visible}
    static WidgetVisibilityChanged := "Evt.WidgetVisibilityChanged" ; data: {widgetId, visible}
    static OverlayModeChanged   := "Evt.OverlayModeChanged"   ; data: {mode, prevMode, locked, heldKeys}
    static CtrlStateChanged     := "Evt.CtrlStateChanged"     ; data: {active}

    ; --- App lifecycle ---
    static AppStarted  := "Evt.AppStarted"
    static AppStopping := "Evt.AppStopping"

    ; --- Export/Import de runs (v0.1.0) ---
    static RunsExported := "Evt.RunsExported"  ; data: {path, count}
    static RunsImported := "Evt.RunsImported"  ; data: {path, imported, renamed, skipped}
}

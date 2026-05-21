; ============================================================
; Events - event names published by Services on the EventBus
; ============================================================
;
; Convention: same as Commands, always via a constant.
;
; Each Event represents a FACT ("X happened"). Multiple subscribers
; react (widget updates, repository persists, logger records, etc.).

class Events
{
    ; --- Run lifecycle ---
    static RunStarted    := "Evt.RunStarted"      ; data: {runId, startedAt, profileId}
    static RunPaused     := "Evt.RunPaused"       ; data: {runId, elapsedMs}
    static RunResumed    := "Evt.RunResumed"      ; data: {runId, elapsedMs}
    static RunCompleted  := "Evt.RunCompleted"    ; data: {runId, durationMs}
    static RunReset      := "Evt.RunReset"        ; data: {runId}
    static RunCancelled  := "Evt.RunCancelled"    ; data: {runId}

    ; --- Timer (pure mechanics) ---
    static TimerStarted  := "Evt.TimerStarted"   ; data: {runMs}
    static TimerPaused   := "Evt.TimerPaused"    ; data: {runMs}
    static TimerResumed  := "Evt.TimerResumed"   ; data: {runMs}
    static TimerStopped  := "Evt.TimerStopped"   ; data: {runMs}
    static TimerReset    := "Evt.TimerReset"     ; data: {scope: "all"}
    static TimerUndone   := "Evt.TimerUndone"    ; data: {runMs}

    ; --- Game state (from the log monitor) ---
    static ZoneChanged       := "Evt.ZoneChanged"       ; data: {zoneName, sceneId}
                                                          ; zoneName: canonical human name from ZonesCatalog
                                                          ; when the raw text from Client.txt resolves; raw fallback
                                                          ; (preserved verbatim) when the zone is unknown. sceneId:
                                                          ; raw text as it appeared in the log (engine internal id
                                                          ; for [SCENE] lines; "" for "You have entered" lines).
                                                          ; Resolution lives in LogMonitorService — see the header
                                                          ; comment of src_v2/app/services/log_monitor_service.ahk
                                                          ; for the algorithm and the rationale.
    static AreaLevelChanged  := "Evt.AreaLevelChanged"  ; data: {areaLevel, areaCode}
    static CharacterLevelUp  := "Evt.CharacterLevelUp"  ; data: {character, class, level}
    static DeathDetected     := "Evt.DeathDetected"     ; data: {character}
    static SceneEntered      := "Evt.SceneEntered"      ; data: {sceneId}
    static NpcDialogue       := "Evt.NpcDialogue"       ; data: {npc, line}
    static WindowFocusChanged := "Evt.WindowFocusChanged" ; data: {state} in {"lost", "gained"}
    static LogLineRead       := "Evt.LogLineRead"       ; data: {line}

    ; --- Zone tracking ---
    ; Published by ZoneTrackingService after ZoneChanged is enriched
    ; with metadata from ZonesCatalog (act, isTown).
    static ZoneEntered          := "Evt.ZoneEntered"          ; data: {zoneName, actIndex, isTown, enteredAt}
    static ZoneTimeAccumulated  := "Evt.ZoneTimeAccumulated"  ; data: {zoneName, durationMs, totalMs}

    ; --- Loading detection ---
    ; Published by LoadingDetectionService when a loading measurement
    ; (from "Generating level" to HUD reappearance) is successfully closed.
    static LoadingMeasured := "Evt.LoadingMeasured"    ; data: {durationMs, fromZone, toZone, source, score, anchor}

    ; --- Tick (UI refresh trigger) ---
    static Tick := "Evt.Tick"   ; data: {runElapsedMs, isRunning, isPaused}

    ; --- Settings/UI ---
    static ProfileChanged       := "Evt.ProfileChanged"       ; data: {profileId, profileName}
    static OverlayToggled       := "Evt.OverlayToggled"       ; data: {visible}
    static WidgetVisibilityChanged := "Evt.WidgetVisibilityChanged" ; data: {widgetId, visible}
    static OverlayModeChanged   := "Evt.OverlayModeChanged"   ; data: {mode, prevMode, locked, steveLocked}
    static CtrlStateChanged     := "Evt.CtrlStateChanged"     ; data: {active}

    ; --- Settings changes ---
    ; Published by SettingsDialog._OnSave when cfg.logFile is changed
    ; to a different (non-empty) value. App composition root reacts by
    ; restarting LogMonitorService against the new path — no full app
    ; reload required.
    static LogFilePathChanged := "Evt.LogFilePathChanged"     ; data: {oldPath, newPath}

    ; Published by SettingsDialog._OnSave when cfg.hotkeys changed in
    ; any way (added/removed/rebound a key). App composition root
    ; reacts by Stop + Hydrate + Start on HotkeyService so the new
    ; bindings take effect without a full app reload.
    static HotkeysChanged := "Evt.HotkeysChanged"             ; data: {oldHotkeys, newHotkeys}

    ; Published by SettingsDialog._OnSave when cfg.vendorRegexes
    ; changed in any slot. CompactLayoutWidget reacts by updating
    ; the labels/colors of the V1/V2/V3 buttons in the overlay
    ; without a full widget rebuild. The click handlers always read
    ; cfg.vendorRegexes on-demand, so functionality is already live;
    ; this event only refreshes the visual state.
    static VendorRegexesChanged := "Evt.VendorRegexesChanged" ; data: {oldRegexes, newRegexes}

    ; --- App lifecycle ---
    static AppStarted  := "Evt.AppStarted"
    static AppStopping := "Evt.AppStopping"

    ; --- Run export/import ---
    static RunsExported := "Evt.RunsExported"  ; data: {path, count}
    static RunsImported := "Evt.RunsImported"  ; data: {path, imported, renamed, skipped}
}

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

    ; Published by WidgetBase whenever a widget's persisted geometry
    ; changes — after Ctrl+drag completes (_UpdatePositionFromGui),
    ; after Ctrl+wheel resize (SetScale), and after programmatic
    ; SetPosition. Carries the FINAL geometry post-change so
    ; subscribers can re-align dependent visuals (e.g. RouteWidget
    ; glues itself below the active timer widget on every move/
    ; resize). Not published during the drag motion itself — only
    ; at gesture end — because B4 sabor 2 explicitly accepted the
    ; brief "detached" frame during drag to keep the hot path free
    ; of bus traffic.
    static WidgetGeometryChanged := "Evt.WidgetGeometryChanged" ; data: {widgetId, x, y, w, h, scale}

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

    ; Published by SettingsDialog._OnSave when cfg.pbDisplayMode
    ; changed between "pb" and "avg5". Widgets that surface PB
    ; (Steve Plus bare value, Compact Plus block sub-labels,
    ; Compact Classic line2 chip) and widgets that use PB for the
    ; live-timer color (every layout except Micro Classic)
    ; subscribe and re-render their PB-related controls. The cache
    ; of `RunAverageService` does NOT need a separate invalidation
    ; hook here — its values are already up to date; what changes
    ; is only WHICH service the widgets consult. No restart
    ; required, unlike LayoutVariant.
    static PbDisplayModeChanged := "Evt.PbDisplayModeChanged"  ; data: {oldMode, newMode}

    ; --- Run outcome (UI-facing fact: what happened to the run) ---
    ; Published by RunSnapshotSaver (after the save attempt resolves
    ; with a verdict — saved / saved-as-DNF / discarded-as-too-short)
    ; and by RunService.ResetRun (when the user resets an active run).
    ; The four outcomes below are what the user actually experienced;
    ; they intentionally do NOT mirror the lifecycle events 1:1.
    ; Lifecycle (RunCompleted/RunCancelled/RunReset) says "how the
    ; run ended"; RunOutcomeReported says "what the user got".
    ;
    ;   outcome="saved"     run was completed, written to history,
    ;                       and pbChanged tells whether PBs moved.
    ;   outcome="dnf"       run was cancelled but long enough to save
    ;                       as DNF (history yes, PB no).
    ;   outcome="too_short" any reason, runMs < threshold; not saved,
    ;                       no PB update.
    ;   outcome="reset"     user reset an active run (no save, no PB).
    ;
    ; durationMs is the runMs that was *measured* at the moment the
    ; outcome was decided (after timer.Stop / before timer.Reset).
    ; pbChanged is meaningful only for outcome="saved"; the other
    ; three are always false.
    static RunOutcomeReported := "Evt.RunOutcomeReported"   ; data: {outcome, durationMs, runId, pbChanged}

    ; Published by SettingsDialog._OnSave when cfg.showOutcomeBanner
    ; flips (true ↔ false). RunOutcomeBannerWidget uses it to clear
    ; any banner that happens to be on screen the moment the user
    ; turns the feature off, so the user gets immediate confirmation
    ; that the setting took effect.
    static ShowOutcomeBannerChanged := "Evt.ShowOutcomeBannerChanged"  ; data: {oldValue, newValue}

    ; --- Persistence health ---
    ; Published by RunService on transitions of its
    ; _persistenceDegraded flag (false↔true). UI/tray surfaces
    ; "crash recovery may be stale" while degraded=true. Idempotent
    ; semantics: publish ONLY when the flag actually changes, not
    ; on every _Persist call — otherwise a burst of failing saves
    ; would spam subscribers that just need to know the *state*.
    static PersistenceHealthChanged := "Evt.PersistenceHealthChanged"  ; data: {degraded}

    ; --- App lifecycle ---
    static AppStarted  := "Evt.AppStarted"
    static AppStopping := "Evt.AppStopping"

    ; --- Run export/import ---
    static RunsExported := "Evt.RunsExported"  ; data: {path, count}
    static RunsImported := "Evt.RunsImported"  ; data: {path, imported, renamed, skipped}

    ; --- Route (B4 Stage 2) ---
    ; Published by RouteService whenever the visible slice of the
    ; current route changes — player moved into a mapa zone listed
    ; in the route (advance/retreat), or the route itself was
    ; edited in Settings, or the run was reset/cancelled (which
    ; resets _currentIdx to -1). RouteWidget consumes this to
    ; re-render its rows. Town zones do NOT trigger this event
    ; (Q5 decision: cities ignored).
    static RouteChanged := "Evt.RouteChanged"   ; data: {visibleZones, currentIdx, totalZones, hasRoute}

    ; Published by the composition root when the user Ctrl+Clicks
    ; the arrow on any of the 4 anchor-eligible timer widgets
    ; (micro/micro_plus/steve/steve_plus). Carries the NEW desired
    ; visibility state (flipped from the current cfg.routeWidgetVisible).
    ; RouteWidget calls Show()/Hide() in response; the 4 timer
    ; widgets refresh the arrow glyph (▾ when hidden, ▴ when shown).
    ; cfg.routeWidgetVisible is persisted by the same handler before
    ; the event fires so a crash mid-toggle still leaves a consistent
    ; state.
    static RouteVisibilityToggled := "Evt.RouteVisibilityToggled"  ; data: {visible}
}

; ============================================================
; LiveReconfigurationHandlers — hot-reload + destructive-action handlers
; ============================================================
;
; A small set of event handlers that the composition root used to
; carry inline. Each is independently subscribable and runs in
; response to a single bus event:
;
;   Evt.DeathDetected             -> ApplyDeathPenaltyToTimer(data)
;   Evt.HotkeysChanged            -> RebindHotkeys(data)
;   Cmd.ResetPersonalBestsRequested -> ResetPersonalBests()
;
; Why a class instead of free functions: each handler needs a small
; set of collaborators (cfg, timer, hotkeyService, personalBest,
; log) and the headless flag. Passing them as constructor args keeps
; the wiring in `_WireEventHandlers` to one-line subscriptions.
;
; `_OnLogFilePathChanged` stays inline in `SpeedKalandraApp` because
; it mutates the composition root's `_logMonitorTimer` field — the
; extra plumbing isn't worth the size win.

class LiveReconfigurationHandlers
{
    _cfg           := ""
    _log           := ""
    _timer         := ""
    _hotkeyService := ""
    _personalBest  := ""
    _headless      := false

    __New(cfg, log, timer, hotkeyService, personalBest, headless := false)
    {
        if !IsObject(cfg)
            throw TypeError("LiveReconfigurationHandlers: 'cfg' required")
        if !IsObject(log)
            throw TypeError("LiveReconfigurationHandlers: 'log' required")
        if !IsObject(timer)
            throw TypeError("LiveReconfigurationHandlers: 'timer' required")
        if !IsObject(hotkeyService)
            throw TypeError("LiveReconfigurationHandlers: 'hotkeyService' required")
        if !IsObject(personalBest)
            throw TypeError("LiveReconfigurationHandlers: 'personalBest' required")

        this._cfg           := cfg
        this._log           := log
        this._timer         := timer
        this._hotkeyService := hotkeyService
        this._personalBest  := personalBest
        this._headless      := !!headless
    }

    ; Adds the configured death penalty to the live timer when a
    ; death is detected. The post-finalize plot already accounts for
    ; this via count * penalty; applying it here keeps the visible
    ; timer in sync.
    ApplyDeathPenaltyToTimer(data)
    {
        if !this._cfg.deathPenaltyEnabled
            return
        if !this._timer.IsActive()
            return
        penaltyMs := this._cfg.deathPenaltyMs
        if (!IsNumber(penaltyMs) || penaltyMs <= 0)
            return
        try
        {
            this._timer.AddPenaltyMs(penaltyMs)
        }
        catch as ex
        {
            try this._log.Warn("Failed to apply death penalty to timer (" . penaltyMs . " ms): " . ex.Message, "ReconfigHandlers")
        }
        try this._log.Info("Death penalty applied to timer: +" . penaltyMs . " ms", "ReconfigHandlers")
    }

    ; Rebinds hotkeys live when the user changes them in Settings.
    ; Stop + Hydrate + Start so the previous bindings are released
    ; before the new ones are registered.
    RebindHotkeys(data)
    {
        ; Prefer the payload; fall back to cfg if it's missing/malformed.
        newHotkeys := ""
        if (IsObject(data) && data.Has("newHotkeys") && data["newHotkeys"] is Map)
            newHotkeys := data["newHotkeys"]
        else if (this._cfg.hotkeys is Map)
            newHotkeys := this._cfg.hotkeys
        else
            newHotkeys := Map()

        try
        {
            this._hotkeyService.Stop()
            this._hotkeyService.Hydrate(newHotkeys)
            this._hotkeyService.Start()
        }
        catch as ex
        {
            try this._log.Warn("Hotkey rebind failed (" . newHotkeys.Count . " action(s)): " . ex.Message, "ReconfigHandlers")
        }

        try this._log.Info("Hotkeys rebound: " . newHotkeys.Count
            . " action(s), " . this._hotkeyService.Count() . " registered", "ReconfigHandlers")

        if !this._headless
            try TrayTip("SpeedKalandra", "Hotkeys updated.", "Mute")
    }

    ; Subscribed to Commands.ResetPersonalBestsRequested (tray menu).
    ; Shows a confirmation MsgBox before clearing (destructive action).
    ; Headless mode resets without prompting.
    ResetPersonalBests()
    {
        if this._headless
        {
            this._personalBest.Reset()
            return
        }

        ; Build context for the confirmation dialog so the user
        ; sees what they're about to lose.
        runPbStr := this._personalBest.HasRunPb()
                    ? Duration.FormatMs(this._personalBest.GetRunPbMs())
                    : "—"
        zoneCount := 0
        try
        {
            for zk, zv in this._personalBest.GetAllZonePbs()
                zoneCount += 1
        }
        actPbCount := 0
        try
            actPbCount := this._personalBest.CountActPbs()

        result := ""
        try
        {
            result := SpeedKalandraMsgBox(
                "Reset all Personal Bests?`n`n"
                . "Full run PB: " runPbStr "`n"
                . "PBs per act: " actPbCount "`n"
                . "Zone PBs: " zoneCount "`n`n"
                . "This action erases all best times and cannot be undone.",
                "SpeedKalandra - Reset PBs",
                "YesNo Icon? Default2")
        }
        catch
            return

        if (result != "Yes")
            return

        this._personalBest.Reset()
        try this._log.Info("PBs reset by user (run PB: " . runPbStr
            . ", " . actPbCount . " acts, " . zoneCount . " zones)", "ReconfigHandlers")
        try TrayTip("SpeedKalandra", "Personal Bests reset.", "Mute")
    }
}

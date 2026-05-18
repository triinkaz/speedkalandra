; ============================================================
; RunStatePersister — periodic and final persistence of run state
; ============================================================
;
; Owns the 5-second tick that writes runBaseMs / loading total /
; per-zone totals to disk while a run is in progress, plus the
; full flush invoked on graceful shutdown. Extracted out of
; SpeedKalandraApp so the composition root stays focused on wiring.
;
; A hash cache (_lastSavedLoadingTotal, _lastSavedZoneTotalsHash)
; skips IniWrite / AtomicWriter calls when nothing has changed — a
; naive write every tick was blocking the main thread for 1–2 s on
; runs with many zones.
;
; Public API:
;   Tick()              5-second SetTimer callback. Skip-cache active.
;   Flush()             Called from app.Stop / OnExit. Always writes.
;   PersistSettings()   Called from the settings dialog OK, hotkey
;                       changes, widget drag/resize callbacks, and
;                       the boot prompts. Writes the full AppSettings
;                       INI.
;   PrimeLoadingTotalCache(ms)
;   PrimeZoneTotalsCache(totalsMap)
;                       Called once after construction with the
;                       hydrated values so the first Tick doesn't
;                       redundantly rewrite the just-loaded state.
;   ResetCache()        Called from the app's _OnRunEndedClearZones
;                       handler when a run ends, so the next run
;                       starts with a fresh hash.
;
; Static:
;   ComputeTotalsHash(totalsMap)  Stable string from a Map<key, val>.
;
; Construction:
;   persister := RunStatePersister(
;       runService, runState, loadingTotals, zoneTracker,
;       settingsRepo, cfg, log
;   )

class RunStatePersister
{
    _runService     := ""
    _runState       := ""
    _loadingTotals  := ""
    _zoneTracker    := ""
    _settingsRepo   := ""
    _cfg            := ""
    _log            := ""

    _lastSavedLoadingTotal   := -1
    _lastSavedZoneTotalsHash := ""

    __New(runService, runState, loadingTotals, zoneTracker, settingsRepo, cfg, log)
    {
        if !IsObject(runService)
            throw TypeError("RunStatePersister: 'runService' required")
        if !IsObject(runState)
            throw TypeError("RunStatePersister: 'runState' required")
        if !IsObject(loadingTotals)
            throw TypeError("RunStatePersister: 'loadingTotals' required")
        if !IsObject(zoneTracker)
            throw TypeError("RunStatePersister: 'zoneTracker' required")
        if !IsObject(settingsRepo)
            throw TypeError("RunStatePersister: 'settingsRepo' required")
        if !IsObject(cfg)
            throw TypeError("RunStatePersister: 'cfg' required")
        if !IsObject(log)
            throw TypeError("RunStatePersister: 'log' required")

        this._runService     := runService
        this._runState       := runState
        this._loadingTotals  := loadingTotals
        this._zoneTracker    := zoneTracker
        this._settingsRepo   := settingsRepo
        this._cfg            := cfg
        this._log            := log
    }

    ; Called every 5 s while the app is running. Skip-cache reduces
    ; disk I/O when nothing has changed since the previous tick.
    Tick()
    {
        try
        {
            this._runService.PersistTick()
        }
        catch as ex
        {
            try this._log.Warn("PersistTick failed (tick): " . ex.Message, "Persister")
        }

        ; Explicit catch on each branch: this runs every 5 s, and
        ; silent failure here (disk full, corrupt INI) would mean
        ; persistent data loss with no signal.
        try
        {
            if IsObject(this._loadingTotals) && this._runService.IsActive()
            {
                ltms := this._loadingTotals.GetTotalMs()
                if (ltms != this._lastSavedLoadingTotal)
                {
                    this._runState.SaveLoadingTotal(ltms)
                    this._lastSavedLoadingTotal := ltms
                }
            }
        }
        catch as ex
        {
            try this._log.Warn("Failed to persist loading total: " . ex.Message, "Persister")
        }

        try
        {
            if IsObject(this._zoneTracker) && this._zoneTracker.IsRunActive()
            {
                snapshot := this._zoneTracker.GetTotals()
                hash := RunStatePersister.ComputeTotalsHash(snapshot)
                if (hash != this._lastSavedZoneTotalsHash)
                {
                    this._runState.SaveZoneTotals(snapshot)
                    this._lastSavedZoneTotalsHash := hash
                }
            }
        }
        catch as ex
        {
            try this._log.Warn("Failed to persist zone totals: " . ex.Message, "Persister")
        }
    }

    ; Called from Stop() / OnExit — last chance to flush before
    ; closing. Always writes (no skip check) so the on-disk state
    ; reflects exactly what is in memory.
    Flush()
    {
        try
        {
            this._runService.PersistTick()
        }
        catch as ex
        {
            try this._log.Warn("PersistTick failed (full flush): " . ex.Message, "Persister")
        }

        try
        {
            if IsObject(this._loadingTotals) && this._runService.IsActive()
            {
                ltms := this._loadingTotals.GetTotalMs()
                this._runState.SaveLoadingTotal(ltms)
                this._lastSavedLoadingTotal := ltms
            }
        }
        catch as ex
        {
            try this._log.Warn("Failed to persist loading total (Full): " . ex.Message, "Persister")
        }

        try
        {
            if IsObject(this._zoneTracker) && this._zoneTracker.IsRunActive()
            {
                snapshot := this._zoneTracker.GetTotalsForSnapshot()
                this._runState.SaveZoneTotals(snapshot)
                this._lastSavedZoneTotalsHash := RunStatePersister.ComputeTotalsHash(snapshot)
            }
        }
        catch as ex
        {
            try this._log.Warn("Failed to persist zone totals (Full): " . ex.Message, "Persister")
        }
    }

    ; Writes AppSettings to disk. Called by the settings dialog,
    ; widget drag/resize callbacks (via the `_persistFn` closure in
    ; the composition root), the boot prompts, and the death-penalty
    ; / disclaimer / log-path handlers.
    PersistSettings()
    {
        try
        {
            this._settingsRepo.Save(this._cfg)
        }
        catch as ex
        {
            try this._log.Warn("Failed to persist settings: " . ex.Message, "Persister")
        }
    }

    ; Prime the cache after the composition root hydrates loadingTotals
    ; from disk, so the first Tick doesn't redundantly rewrite the
    ; just-loaded value.
    PrimeLoadingTotalCache(loadingMs)
    {
        if (IsNumber(loadingMs) && loadingMs >= 0)
            this._lastSavedLoadingTotal := loadingMs
    }

    ; Same idea for zone totals, called after zoneTracker.Hydrate.
    PrimeZoneTotalsCache(zoneTotals)
    {
        if IsObject(zoneTotals)
            this._lastSavedZoneTotalsHash := RunStatePersister.ComputeTotalsHash(zoneTotals)
    }

    ; Clears the dirty-cache when a run ends (RunReset / RunCancelled).
    ; Without this, the first Tick of the next run would compare
    ; against stale data and skip the initial write.
    ResetCache()
    {
        this._lastSavedLoadingTotal := -1
        this._lastSavedZoneTotalsHash := ""
    }

    ; Stable hash of a Map<key, val>. Used to skip Save calls when
    ; nothing has changed. Format: `key=val|key=val|...` — not
    ; cryptographic, just deterministic.
    static ComputeTotalsHash(totalsMap)
    {
        if !IsObject(totalsMap)
            return ""
        parts := ""
        for k, v in totalsMap
            parts .= k "=" v "|"
        return parts
    }
}

; ZoneTrackingService — accumulates time per physical zone during
; an active run. Result: Map<zoneName, totalMs>.
;
; Time is only counted when the run is active. Before RunStarted
; (or after it ends) the service may register the current zone for
; widget display, but does NOT increment counters. This prevents
; the LogMonitor seed (which republishes the last ZoneChanged on
; boot to hydrate widgets) from producing phantom time.
;
; Timer interactions:
;   TimerPaused   flushes elapsed into _totals, freezes _startMs.
;   TimerResumed  re-arms _startMs from NowMs.
;   TimerStopped  flushes (without this, FinalizeRun → Stop wiped
;                 the last zone's time before _OnRunCompleted ran).
;
; Persistence: _totals is written every ~5s by the composition
; root via RunStateRepository ([RunZoneTotals]). Hydrate(map) +
; SetRunActive(true) restore the in-progress run on the next boot;
; the deferred RunService.Hydrate(state) at the end of the
; composition root's __New then publishes RunStarted{hydrated:true},
; which _OnRunStarted handles WITHOUT wiping the just-restored
; totals.
;
; AHK v2 gotcha: parameter is `catalog`, not `zonesCatalog` — AHK
; variable lookup is case-insensitive, and `is ZonesCatalog` would
; collide with a `zonesCatalog` local.


class ZoneTrackingService
{
    _bus     := ""
    _clock   := ""
    _catalog := ""    ; ZonesCatalog, may be "" when none is provided

    _activeZone := ""
    _startMs    := 0
    _totals     := ""    ; Map<zoneName, totalMs>
    _firstEnteredAt := ""    ; Map<zoneName, "YYYY-MM-DD HH:MM:SS"> — first-entry timestamp per zone in the current run
    _runActive  := false

    ; Tracks the timer's pause state so ZoneChanged respects it.
    ; PoE2 emits [SCENE] lines during alt-tab (background loads,
    ; portal animations, etc.) that become ZoneChanged events; without
    ; this flag those events restart _startMs and the zone keeps
    ; counting while the overall timer is paused.
    _timerPaused := false

    _handlerZoneChanged   := ""
    _handlerTimerPaused   := ""
    _handlerTimerResumed  := ""
    _handlerTimerStopped  := ""
    _handlerRunStarted    := ""
    _handlerRunReset      := ""
    _handlerRunCancelled  := ""
    _handlerRunCompleted  := ""

    __New(bus, clock, catalog := "")
    {
        if !(bus is EventBus)
            throw TypeError("ZoneTrackingService: 'bus' must be EventBus")
        if !IsObject(clock) || !clock.HasMethod("NowMs")
            throw TypeError("ZoneTrackingService: 'clock' must implement NowMs()")
        ; catalog is optional (for tests / boot without CSV).
        if (catalog != "" && !(catalog is ZonesCatalog))
            throw TypeError("ZoneTrackingService: 'catalog' must be ZonesCatalog or empty")

        this._bus     := bus
        this._clock   := clock
        this._catalog := catalog
        this._totals  := Map()
        this._firstEnteredAt := Map()

        this._handlerZoneChanged   := (data) => this._OnZoneChanged(data)
        this._handlerTimerPaused   := (data) => this._OnTimerPaused(data)
        this._handlerTimerResumed  := (data) => this._OnTimerResumed(data)
        this._handlerTimerStopped  := (data) => this._OnTimerStopped(data)
        this._handlerRunStarted    := (data) => this._OnRunStarted(data)
        this._handlerRunReset      := (data) => this._OnRunEnded(data)
        this._handlerRunCancelled  := (data) => this._OnRunEnded(data)
        this._handlerRunCompleted  := (data) => this._OnRunCompleted(data)

        bus.Subscribe(Events.ZoneChanged,  this._handlerZoneChanged)
        bus.Subscribe(Events.TimerPaused,  this._handlerTimerPaused)
        bus.Subscribe(Events.TimerResumed, this._handlerTimerResumed)
        bus.Subscribe(Events.TimerStopped, this._handlerTimerStopped)
        bus.Subscribe(Events.RunStarted,   this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,     this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled, this._handlerRunCancelled)
        bus.Subscribe(Events.RunCompleted, this._handlerRunCompleted)
    }

    Dispose()
    {
        if (this._handlerZoneChanged != "")
        {
            this._bus.Unsubscribe(Events.ZoneChanged, this._handlerZoneChanged)
            this._handlerZoneChanged := ""
        }
        if (this._handlerTimerPaused != "")
        {
            this._bus.Unsubscribe(Events.TimerPaused, this._handlerTimerPaused)
            this._handlerTimerPaused := ""
        }
        if (this._handlerTimerResumed != "")
        {
            this._bus.Unsubscribe(Events.TimerResumed, this._handlerTimerResumed)
            this._handlerTimerResumed := ""
        }
        if (this._handlerTimerStopped != "")
        {
            this._bus.Unsubscribe(Events.TimerStopped, this._handlerTimerStopped)
            this._handlerTimerStopped := ""
        }
        if (this._handlerRunStarted != "")
        {
            this._bus.Unsubscribe(Events.RunStarted, this._handlerRunStarted)
            this._handlerRunStarted := ""
        }
        if (this._handlerRunReset != "")
        {
            this._bus.Unsubscribe(Events.RunReset, this._handlerRunReset)
            this._handlerRunReset := ""
        }
        if (this._handlerRunCancelled != "")
        {
            this._bus.Unsubscribe(Events.RunCancelled, this._handlerRunCancelled)
            this._handlerRunCancelled := ""
        }
        if (this._handlerRunCompleted != "")
        {
            this._bus.Unsubscribe(Events.RunCompleted, this._handlerRunCompleted)
            this._handlerRunCompleted := ""
        }
    }

    ; Restores _totals from disk on boot. The composition root pairs
    ; this with SetRunActive(true) when the persisted RunState
    ; reports an active run. _activeZone stays empty until the
    ; LogMonitor seed re-publishes the last ZoneChanged.
    Hydrate(zoneTotalsMap)
    {
        if !(zoneTotalsMap is Map)
            throw TypeError("ZoneTrackingService.Hydrate: 'zoneTotalsMap' must be Map")
        clean := Map()
        for k, v in zoneTotalsMap
            clean[k] := v
        this._totals    := clean
        this._activeZone := ""
        this._startMs    := 0
        ; The pre-shutdown per-zone entry timestamps were never
        ; persisted; zones entered after hydrate get fresh timestamps,
        ; pre-hydrate zones simply have none in the plot.
        this._firstEnteredAt := Map()
    }

    ; Manually marks the run as active when RunStarted will not be
    ; (re)published. Used by the composition root after hydrating an
    ; in-progress run.
    SetRunActive(active)
    {
        this._runActive := !!active
        if (this._runActive && this._activeZone != "" && this._startMs = 0)
            this._startMs := this._clock.NowMs()
    }

    ; ---- Public queries ----

    GetActiveZone()    => this._activeZone
    GetActiveElapsedMs()
    {
        if (this._activeZone = "" || this._startMs = 0)
            return 0
        return Max(0, this._clock.NowMs() - this._startMs)
    }
    IsActive()     => this._activeZone != "" && this._startMs > 0
    IsRunActive()  => this._runActive

    GetZoneTotal(zoneName)
    {
        if (zoneName = "")
            return 0
        return this._totals.Has(zoneName) ? this._totals[zoneName] : 0
    }

    ; History total + ongoing elapsed for the active zone. Useful
    ; when a widget wants to show "time on current zone" after the
    ; player re-entered it.
    GetZoneTotalWithActive(zoneName)
    {
        base := this.GetZoneTotal(zoneName)
        if (zoneName = this._activeZone)
            base += this.GetActiveElapsedMs()
        return base
    }

    GetTotals()
    {
        out := Map()
        for k, v in this._totals
            out[k] := v
        return out
    }

    ; Defensive copy of the per-zone first-entry timestamp map. Used
    ; by the composition root and the plot dialog to drive the
    ; chronological ordering of zones in the post-run plot. Cleared
    ; on RunStarted/RunReset/RunCancelled; empty after Hydrate.
    GetFirstEnteredAtMap()
    {
        out := Map()
        for k, v in this._firstEnteredAt
            out[k] := v
        return out
    }

    ; Like GetTotals() but folds in the ongoing time of the active
    ; zone (not yet flushed into _totals). Used by the composition
    ; root's 5 s persistence tick so an interrupted run preserves
    ; in-flight zone time across crashes. Does not mutate state.
    GetTotalsForSnapshot()
    {
        out := Map()
        for k, v in this._totals
            out[k] := v
        if this.IsActive()
        {
            elapsed := this.GetActiveElapsedMs()
            if (elapsed > 0)
            {
                current := out.Has(this._activeZone) ? out[this._activeZone] : 0
                out[this._activeZone] := current + elapsed
            }
        }
        return out
    }

    ; Per-act totals, looked up via the catalog. Unknown zones are skipped.
    GetActTotals()
    {
        out := Map()
        if !IsObject(this._catalog)
            return out
        for zoneName, ms in this._totals
        {
            entry := this._catalog.FindByName(zoneName)
            if !IsObject(entry)
                continue
            act := entry.act
            current := out.Has(act) ? out[act] : 0
            out[act] := current + ms
        }
        return out
    }

    ; Per-act totals filtered to town zones only.
    GetTownTotalsByAct()
    {
        out := Map()
        if !IsObject(this._catalog)
            return out
        for zoneName, ms in this._totals
        {
            entry := this._catalog.FindByName(zoneName)
            if !IsObject(entry) || !entry.isTown
                continue
            act := entry.act
            current := out.Has(act) ? out[act] : 0
            out[act] := current + ms
        }
        return out
    }

    ; Sum of all town time in the run, including the ongoing elapsed
    ; if the active zone is itself a town. 0 when there is no catalog.
    GetTotalTownMs()
    {
        if !IsObject(this._catalog)
            return 0

        total := 0
        for zoneName, ms in this._totals
        {
            entry := this._catalog.FindByName(zoneName)
            if IsObject(entry) && entry.isTown
                total += ms
        }

        ; Fold in the active zone's in-flight time if it is a town.
        if this.IsActive()
        {
            entry := this._catalog.FindByName(this._activeZone)
            if IsObject(entry) && entry.isTown
                total += this.GetActiveElapsedMs()
        }

        return total
    }

    GetTotalRunMs()
    {
        total := 0
        for _, ms in this._totals
            total += ms
        if this.IsActive()
            total += this.GetActiveElapsedMs()
        return total
    }

    ; Test-only convenience: wipes everything. Production lifecycle
    ; flags are managed by _OnRunStarted / _OnRunEnded, not by Reset.
    Reset()
    {
        this._activeZone := ""
        this._startMs    := 0
        this._totals     := Map()
        this._firstEnteredAt := Map()
        this._runActive  := false
        this._timerPaused := false
    }

    ; ---- Private handlers ----

    _OnZoneChanged(data)
    {
        if !IsObject(data) || !data.Has("zoneName")
            return
        newZone := data["zoneName"]
        if (newZone = "")
            return

        ; Close the previous zone (no-op when _startMs=0, i.e. when
        ; the zone was only registered for display, not timed).
        this._FlushActive()

        this._activeZone := newZone
        ; Count time only when the run is active AND the timer isn't
        ; paused. The paused check is critical: PoE2 emits [SCENE]
        ; lines during alt-tab (background loads, portal animations)
        ; that arrive here as ZoneChanged; without the guard, they
        ; restart _startMs and the zone keeps counting while the
        ; overall timer is paused.
        this._startMs := (this._runActive && !this._timerPaused) ? this._clock.NowMs() : 0

        ; Record the first-entry timestamp once per zone, only while
        ; the run is active. Skipping pre-RunStarted writes avoids
        ; recording the LogMonitor seed's ZoneChanged. Re-entries
        ; (death, portal) don't overwrite.
        if (this._runActive && !this._firstEnteredAt.Has(newZone))
            this._firstEnteredAt[newZone] := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")

        ; Enrich the outgoing event with catalog metadata.
        actIdx := 0
        isTown := false
        if IsObject(this._catalog)
        {
            entry := this._catalog.FindByName(newZone)
            if IsObject(entry)
            {
                actIdx := entry.act
                isTown := entry.isTown
            }
        }

        this._bus.Publish(Events.ZoneEntered, Map(
            "zoneName", newZone,
            "actIndex", actIdx,
            "isTown",   isTown,
            "enteredAt", this._startMs
        ))
    }

    _OnTimerPaused(data)
    {
        ; Set the flag BEFORE _FlushActive so a ZoneChanged firing
        ; in the same tick (race between log lines) doesn't restart
        ; _startMs.
        this._timerPaused := true
        ; keepActive=true preserves _activeZone; only _startMs zeroes.
        this._FlushActive(true)
    }

    _OnTimerResumed(data)
    {
        this._timerPaused := false
        ; Restart the active zone's clock from now. Pause time is
        ; not counted.
        if (this._activeZone != "" && this._runActive)
            this._startMs := this._clock.NowMs()
    }

    _OnTimerStopped(data)
    {
        ; Flush BEFORE zeroing _startMs. Without this, FinalizeRun
        ; → timer.Stop → TimerStopped (zeroes _startMs) →
        ; RunCompleted → _OnRunCompleted's flush would be a no-op,
        ; and the time since the last ZoneChanged would be lost in
        ; every finalized run.
        this._timerPaused := false
        this._FlushActive(true)
    }

    _OnRunStarted(data)
    {
        ; The hydrated:true variant comes from RunService.Hydrate at
        ; the end of the composition root's __New. By the time it
        ; fires, _totals has already been restored from disk via
        ; Hydrate(map) + SetRunActive(true). Wiping totals here would
        ; lose every ms tracked before the previous shutdown. Same
        ; convention used by SpeedKalandraApp._OnRunStartedForXp.
        isHydrate := IsObject(data) && data.Has("hydrated") && data["hydrated"]
        if !isHydrate
        {
            this._totals := Map()
            this._firstEnteredAt := Map()
        }
        this._runActive := true
        this._timerPaused := false
        if (this._activeZone != "")
        {
            this._startMs := this._clock.NowMs()
            ; Only stamp the first-entry timestamp for a fresh run.
            ; On hydrate the active zone is "" (Hydrate wipes it), so
            ; this branch is normally not taken — the guard is
            ; defensive in case Hydrate semantics ever change.
            if !isHydrate && !this._firstEnteredAt.Has(this._activeZone)
                this._firstEnteredAt[this._activeZone] := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        }
    }

    _OnRunEnded(data)
    {
        ; RunReset / RunCancelled: drop everything. The next
        ; RunStarted requires a fresh ZoneChanged before counting
        ; resumes — the tracker is idle until then.
        this._totals := Map()
        this._firstEnteredAt := Map()
        this._activeZone := ""
        this._startMs := 0
        this._runActive := false
        this._timerPaused := false
    }

    _OnRunCompleted(data)
    {
        ; Flush before deactivating so the final zone's time lands in
        ; _totals. _totals is intentionally NOT cleared here — the
        ; plot dialog (and other subscribers downstream of
        ; RunCompleted) query GetTotals() while the event fans out.
        ; The next RunStarted resets it via _OnRunStarted.
        this._FlushActive()
        this._runActive := false
        this._timerPaused := false
    }

    ; Closes the active zone, adding the elapsed since _startMs into
    ; _totals. No-op when _startMs=0 (zone registered but not timed).
    ; keepActive=true preserves _activeZone; only _startMs is zeroed.
    _FlushActive(keepActive := false)
    {
        if (this._activeZone = "" || this._startMs = 0)
            return

        elapsed := Max(0, this._clock.NowMs() - this._startMs)
        if (elapsed > 0)
        {
            zone := this._activeZone
            current := this._totals.Has(zone) ? this._totals[zone] : 0
            this._totals[zone] := current + elapsed

            this._bus.Publish(Events.ZoneTimeAccumulated, Map(
                "zoneName",   zone,
                "durationMs", elapsed,
                "totalMs",    this._totals[zone]
            ))
        }

        this._startMs := 0
        if !keepActive
            this._activeZone := ""
    }
}

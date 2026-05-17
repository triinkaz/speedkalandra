; ============================================================
; ZoneTrackingService - aggregated time per zone during a run
; ============================================================
;
; Replaces the legacy TownVisitTracker + the "time per step" paradigm.
; Instead of tracking per step (which no longer exists without a
; route), we track time per PHYSICAL ZONE. Result: Map<zoneName, totalMs>.
;
; "TIME" SEMANTICS:
;   Time is only accumulated when there is an ACTIVE RUN. Before
;   RunStarted (or after RunCompleted/Cancelled/Reset), the service
;   may REGISTER which zone is current (for widget display) but
;   does NOT increment counters or start _startMs.
;
;   This prevents the LogMonitor seed (which republishes the last
;   ZoneChanged from the log tail on boot to hydrate widgets) from
;   making the tracker accumulate "phantom" time before any run
;   has started.
;
; FLOW:
;   - boot: _runActive=false, _activeZone="", _startMs=0, _totals={}
;
;   - Evt.ZoneChanged arrives with a new zone:
;       1. If there is an active zone WITH startMs > 0: flush (adds
;          elapsed to _totals)
;       2. Set _activeZone = new
;       3. If _runActive: _startMs = NowMs() (starts counting)
;          Otherwise: _startMs = 0 (just registers the zone, no counting)
;       4. Publishes Evt.ZoneEntered (with catalog metadata).
;
;   - Evt.RunStarted:
;       1. Clears _totals (new run starts from zero)
;       2. _runActive = true
;       3. If _activeZone != "": _startMs = NowMs() (player was
;          already in a zone when the run started, count from now)
;
;   - Evt.RunReset / Evt.RunCancelled:
;       Clears everything (_totals, _activeZone, _startMs); _runActive=false
;
;   - Evt.RunCompleted:
;       Flush last zone (preserves _totals for the final plot); _runActive=false
;
; INTERACTION WITH TIMER:
;   - TimerPaused: closes the active zone (adds time up to the pause).
;     The "logical" zone stays active, but _startMs is zeroed. When
;     the timer resumes, _startMs is redefined.
;   - TimerResumed: reopens tracking for the active zone (_startMs=NowMs).
;   - TimerStopped: closes without adding (run ended — orphan time).
;     Keeps _activeZone in case TimerStop is only mechanical (run not
;     yet formally cancelled).
;
; QUERIES FOR WIDGETS:
;   GetActiveZone()           => string (zone currently being tracked)
;   GetActiveElapsedMs()      => Int (time since entry into the active zone)
;   GetZoneTotal(zoneName)    => Int (zone's historical accumulated)
;   GetZoneTotalWithActive(zoneName) => Int (history + current elapsed)
;   GetTotals()               => Map<zoneName, totalMs> (defensive copy)
;   GetTotalsForSnapshot()    => Map (copy + adds active zone elapsed)
;   GetTownTotalsByAct()      => Map<actIndex, totalMs> (is_town filtered)
;   GetTotalTownMs()          => Int (total town sum incl. active zone)
;   GetActTotals()            => Map<actIndex, totalMs> (all act zones)
;   GetTotalRunMs()           => Int (sum of everything)
;   IsRunActive()             => bool (true between RunStarted and RunEnded)
;
; PERSISTENCE:
;   _totals is persisted by the composition root via
;   RunStateRepository ([RunZoneTotals] INI section). Saved every ~5s
;   and on shutdown. On boot, the composition root calls
;   Hydrate(runState.LoadZoneTotals()) to restore the time of the
;   ongoing run across sessions/crashes.
;
;   To capture the current ongoing time of the active zone (not yet
;   flushed), use GetTotalsForSnapshot() instead of GetTotals().
;
; CONSTRUCTION:
;   svc := ZoneTrackingService(bus, clock, catalog)
;
; NOTE ON PARAMETER NAME:
;   AHK v2 does case-insensitive variable lookup. If we named the
;   param `zonesCatalog`, it would collide case-insensitively with
;   the `ZonesCatalog` class on the right side of `is`, and the
;   check would become "instance is instance" (fails with "Expected
;   a Class but got a ZonesCatalog"). Hence `catalog` —
;   case-insensitive-distinct.


class ZoneTrackingService
{
    _bus     := ""
    _clock   := ""
    _catalog := ""    ; ZonesCatalog (may be "" if none)

    _activeZone := ""
    _startMs    := 0
    _totals     := ""    ; Map<zoneName, totalMs>
    _firstEnteredAt := ""   ; v0.1.4: Map<zoneName, "YYYY-MM-DD HH:MM:SS"> — first entry timestamp per zone in the current run
    _runActive  := false
    _timerPaused := false   ; v0.1.1 (Bug Lechtansi): tracks timer pause state
                            ; so ZoneChanged respects it. Without this, a
                            ; ZoneChanged that fires during a pause (e.g. [SCENE]
                            ; emitted by the game while alt-tabbed) would restart
                            ; _startMs and the zone timer would keep "ticking"
                            ; even with the overall paused.

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

    ; ============================================================
    ; Hydrate - restores state from disk (crash recovery)
    ;
    ; Called by the composition root on boot, BEFORE RunStarted is
    ; (re)published. If there is an ongoing run on disk, RunService
    ; was also hydrated and _runActive will be set when RunStarted
    ; fires — or manually marked via SetRunActive(true).
    ;
    ; Important: this does NOT activate timing for the current active
    ; zone here (without a known ZoneChanged, _activeZone stays empty).
    ; The LogMonitor seed re-emits the last ZoneChanged on boot to
    ; repopulate that state.
    ; ============================================================
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
        ; v0.1.4: hydrated runs lose per-zone entry timestamps (the
        ; old INI persistence didn't carry them). The map stays empty
        ; — zones entered AFTER hydrate get fresh timestamps; pre-
        ; hydrate zones simply have no timestamp in the final plot.
        this._firstEnteredAt := Map()
    }

    ; ============================================================
    ; SetRunActive - manually sets _runActive
    ;
    ; Used by the composition root on boot when RunService was
    ; hydrated with a run in progress (status=running) and the
    ; RunStarted event will NOT be re-published. Without this, the
    ; service would stay "stuck" in _runActive=false until the next
    ; manual RunStarted.
    ; ============================================================
    SetRunActive(active)
    {
        this._runActive := !!active
        ; If enabling and there's a known zone, start the clock
        if (this._runActive && this._activeZone != "" && this._startMs = 0)
            this._startMs := this._clock.NowMs()
    }

    ; ============================================================
    ; Public queries
    ; ============================================================

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

    ; Current total of the active zone = accumulated history + ongoing elapsed.
    ; Useful for widgets to display the "time on the current zone" even if
    ; the player returned after leaving.
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

    ; ============================================================
    ; GetFirstEnteredAtMap (v0.1.4)
    ;
    ; Returns a defensive copy of Map<zoneName, "YYYY-MM-DD HH:MM:SS">
    ; with the FIRST entry timestamp per zone in the current run.
    ;
    ; Used by the composition root and the plot dialog to inject
    ; timestamps into the snapshot, enabling chronological ordering
    ; of zone details in the plot.
    ;
    ; The map is cleared on RunStarted/RunReset/RunCancelled. After
    ; Hydrate (crash recovery) it starts empty — the old persistence
    ; didn't carry per-zone timestamps; zones entered after hydrate
    ; get fresh timestamps.
    ; ============================================================
    GetFirstEnteredAtMap()
    {
        out := Map()
        for k, v in this._firstEnteredAt
            out[k] := v
        return out
    }

    ; ============================================================
    ; GetTotalsForSnapshot - copy of _totals + elapsed from the ACTIVE zone
    ;
    ; Unlike GetTotals(), this includes the active zone's ongoing
    ; time (which has not yet been flushed into _totals). Used by
    ; the composition root to persist every ~5s to disk — guarantees
    ; that even "ongoing" time is preserved.
    ;
    ; Does not modify internal state (no flush, no _startMs reset).
    ; ============================================================
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

    ; Aggregated totals by act (queries ZonesCatalog to map them).
    ; Includes only known zones (lookup via FindByName).
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

    ; TOWN-only totals, aggregated by act. Replaces the legacy
    ; TownVisitTracker.GetTownTotals().
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

    ; ============================================================
    ; GetTotalTownMs - sum of all time spent in town zones in the run.
    ;
    ; Includes CLOSED town zones (in _totals) + elapsed of the ACTIVE
    ; zone if it is a town. Equivalent to legacy
    ; TownVisitTracker.GetTotalRunTownMs().
    ;
    ; Used by CompactLayoutWidget to render the stacked bar (Map /
    ; Loading / Town) in real time during the run.
    ;
    ; Returns 0 if there is no catalog (no way to classify town).
    ; ============================================================
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

        ; Add ACTIVE zone elapsed if it is town (not yet flushed into
        ; _totals — "ongoing" time).
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

    ; ============================================================
    ; Reset - clears internal state (totals + active zone + flags)
    ;   Publishes nothing. Useful externally in tests; internally the
    ;   Run lifecycle handlers control the flags with specific
    ;   semantics (see _OnRunStarted / _OnRunEnded).
    ; ============================================================

    Reset()
    {
        this._activeZone := ""
        this._startMs    := 0
        this._totals     := Map()
        this._firstEnteredAt := Map()
        this._runActive  := false
        this._timerPaused := false   ; v0.1.1
    }

    ; ============================================================
    ; Private handlers
    ; ============================================================

    _OnZoneChanged(data)
    {
        if !IsObject(data) || !data.Has("zoneName")
            return
        newZone := data["zoneName"]
        if (newZone = "")
            return

        ; Closes the previous zone (if it was being timed) by adding the elapsed.
        ; _FlushActive is a no-op when _startMs=0 (zone registered without clock).
        this._FlushActive()

        ; Opens new
        this._activeZone := newZone
        ; Counts time only if the run is active AND the timer is NOT paused.
        ; Otherwise, keeps the zone registered (for display) with the
        ; clock stopped.
        ;
        ; v0.1.1 (Bug Lechtansi): added the !_timerPaused check. Before
        ; it only considered _runActive — ZoneChanged during a pause
        ; restarted _startMs and the zone timer kept ticking while the
        ; overall was paused. Common case: PoE2 emits [SCENE] events
        ; during alt-tab (background loading screens, portal animations,
        ; etc.) that become ZoneChanged via LogMonitor's _ProcessLine.
        this._startMs := (this._runActive && !this._timerPaused) ? this._clock.NowMs() : 0

        ; v0.1.4: record FIRST entry timestamp per zone in the run.
        ; Only writes if the zone was never entered before — re-entries
        ; (death respawn, portals) do not overwrite. Stored only when
        ; the run is active to avoid timestamps from the LogMonitor
        ; seed before RunStarted.
        if (this._runActive && !this._firstEnteredAt.Has(newZone))
            this._firstEnteredAt[newZone] := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")

        ; Publishes the event enriched with catalog metadata
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
        ; v0.1.1: sets the flag BEFORE _FlushActive so that a
        ; ZoneChanged firing immediately after (race between log
        ; lines) does not restart _startMs.
        this._timerPaused := true
        ; Closes the active zone (accumulates time up to the pause).
        ; After resume, the current active zone is "reopened" in
        ; _OnTimerResumed.
        ; Param true = keepActive (preserves _activeZone, only zeroes _startMs).
        this._FlushActive(true)
    }

    _OnTimerResumed(data)
    {
        ; v0.1.1: clears the flag BEFORE setting _startMs.
        this._timerPaused := false
        ; Resets startMs of the current zone (if any) to count from
        ; now on. Time during the pause was not counted.
        if (this._activeZone != "" && this._runActive)
            this._startMs := this._clock.NowMs()
    }

    _OnTimerStopped(data)
    {
        ; v17.15 (Bug #1): FLUSH before zeroing _startMs.
        ;
        ; Before: _startMs := 0 with no flush. Result: FinalizeRun ->
        ; timer.Stop -> TimerStopped (zeroes _startMs) -> RunCompleted
        ; -> _OnRunCompleted called _FlushActive() but it was already
        ; a no-op (_startMs=0). The zone time since the last
        ; ZoneChanged was lost in EVERY finalized run.
        ;
        ; Now: _FlushActive(true) commits the elapsed into _totals
        ; before zeroing _startMs. keepActive=true preserves
        ; _activeZone (player is still in the zone; the future
        ; RunStarted will reopen tracking).
        this._timerPaused := false   ; v0.1.1: run ended, no longer paused
        this._FlushActive(true)
    }

    _OnRunStarted(data)
    {
        ; A new run normally clears totals and starts counting from
        ; the registered zone (if any). The hydrated:true variant is
        ; different: RunService.Hydrate publishes RunStarted{hydrated:
        ; true} at the end of the composition root's __New so that
        ; services constructed later (RunStatsRecorder, etc.) can
        ; pick up the run id. By that point the composition root has
        ; ALREADY hydrated _totals from disk (via Hydrate(map) +
        ; SetRunActive(true)) — wiping them here would lose every ms
        ; tracked before the previous shutdown. Same convention used
        ; by SpeedKalandraApp._OnRunStartedForXp.
        isHydrate := IsObject(data) && data.Has("hydrated") && data["hydrated"]
        if !isHydrate
        {
            this._totals := Map()
            this._firstEnteredAt := Map()
        }
        this._runActive := true
        this._timerPaused := false   ; v0.1.1: fresh start
        if (this._activeZone != "")
        {
            this._startMs := this._clock.NowMs()
            ; Only stamp the first-entry timestamp for a fresh run.
            ; On hydrate the active zone is "" (Hydrate wipes it),
            ; so this branch is normally not taken; the guard is
            ; defensive in case Hydrate semantics ever change.
            if !isHydrate && !this._firstEnteredAt.Has(this._activeZone)
                this._firstEnteredAt[this._activeZone] := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        }
    }

    _OnRunEnded(data)
    {
        ; RunReset / RunCancelled: clear everything (clean state,
        ; _runActive=false). _activeZone is also cleared so the next
        ; RunStarted requires a new ZoneChanged (or the player entering
        ; a new map) before counting time. Practical behavior: when a
        ; run is cancelled, the tracker becomes fully idle.
        this._totals := Map()
        this._firstEnteredAt := Map()   ; v0.1.4: clear per-zone entry timestamps
        this._activeZone := ""
        this._startMs := 0
        this._runActive := false
        this._timerPaused := false   ; v0.1.1: run ended
    }

    _OnRunCompleted(data)
    {
        ; Before zeroing, closes the active zone to capture the final
        ; time. The composition root should use GetTotals() between
        ; Evt.RunCompleted and the Reset that happens shortly after.
        this._FlushActive()
        this._runActive := false
        this._timerPaused := false   ; v0.1.1: run ended
        ; Does not zero _totals — other subscribers (RunStatsPlotDialog)
        ; query GetTotals() during the RunCompleted cycle to build the
        ; final plot. The next RunStarted clears it via _OnRunStarted.
    }

    ; ============================================================
    ; _FlushActive — closes the active zone, accumulates elapsed into _totals.
    ;
    ;   No-op if _startMs=0 (zone "registered but not timed", e.g.
    ;   pre-run state).
    ;
    ;   keepActive=true: does not reset _activeZone (only zeroes
    ;     _startMs). Used in TimerPaused — the "logical" zone stays
    ;     active, but the timer stopped. When the timer resumes,
    ;     _startMs is redefined.
    ; ============================================================
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

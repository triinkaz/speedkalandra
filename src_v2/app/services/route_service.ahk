; ============================================================
; RouteService — keeps the active Route in sync with run state
; ============================================================
;
; Responsibilities:
;   - Hold the active Route for the current profile (loaded
;     from RouteRepository on boot or on Evt.ProfileChanged).
;   - Advance / retreat _currentIdx as the runner enters zones
;     (Evt.ZoneEntered), ignoring town zones (Q5 decision).
;   - Reset the route position to "haven't started" (_currentIdx
;     = -1) on RunStarted / RunReset / RunCancelled.
;   - Publish Evt.RouteChanged whenever the visible state of
;     the route changes, so RouteWidget can re-render.
;
; The runtime _currentIdx is NEVER persisted — it's a per-run
; concept. A fresh app boot starts the route at -1 even mid-
; run; the next ZoneEntered will re-sync. Persisting _currentIdx
; would risk showing a stale "you're at zone X" after the
; runner has moved on between sessions.
;
; Public API:
;   LoadRouteForProfile(profileName)    — initial hydrate from
;                                         repository (called by
;                                         composition root on
;                                         boot, AFTER subscribers
;                                         are wired — GSG §17.1).
;   Refresh()                            — re-loads the route for
;                                         the current profile;
;                                         used after the Settings
;                                         UI edits the route via
;                                         the repo directly.
;   GetCurrentRoute()                    — Route (always non-null)
;   GetVisibleSlice(n)                   — pass-through to Route
;   GetCurrentIdx() / HasRoute() / Count
;   Dispose()                            — unsubscribe handlers
;
; Events consumed:
;   Evt.ZoneEntered   — advance/retreat (town zones filtered)
;   Evt.RunStarted    — Reset() (always; hydrated runs re-sync
;                       via the next ZoneEntered)
;   Evt.RunReset      — Reset()
;   Evt.RunCancelled  — Reset()
;   Evt.ProfileChanged — reload for new profile
;
; Events published:
;   Evt.RouteChanged   — { currentIdx, totalZones, hasRoute, route }
;                        Only published when the state actually
;                        changes; off-route zone entries are
;                        silent no-ops.

class RouteService
{
    _bus  := ""
    _repo := ""
    _log  := ""    ; LogService (optional) — diagnostic logging only
    _zoneProvider := ""   ; callable() => String | "" — re-syncs after Reset

    _route          := ""    ; Route (always populated, never empty string)
    _currentProfile := ""

    _handlerZoneEntered    := ""
    _handlerRunStarted     := ""
    _handlerRunReset       := ""
    _handlerRunCancelled   := ""
    _handlerProfileChanged := ""

    ; The optional `zoneProvider` is a closure `() => String` that
    ; returns the player's CURRENT active zone (typically wired to
    ; `ZoneTrackingService.GetActiveZone()` by the composition
    ; root). Used to re-sync `_currentIdx` after a Reset() — fixes
    ; the case where the player is already physically inside a
    ; route zone (e.g. The Riverbank at character spawn) when
    ; RunStarted fires; without the re-sync, the route highlight
    ; would disappear until the NEXT ZoneEntered transition, which
    ; may be minutes away. Defaults to "" so tests that don't care
    ; about this behavior can omit it.
    __New(bus, repo, log := "", zoneProvider := "")
    {
        if !(bus is EventBus)
            throw TypeError("RouteService: 'bus' must be EventBus")
        ; Parameter is named `repo` (not `routeRepository`) because
        ; AHK v2 identifier lookup is case-insensitive, so a local
        ; `routeRepository` would shadow the global `RouteRepository`
        ; class and the `is RouteRepository` check would fail with
        ; `TypeError: Expected a Class but got a RouteRepository`.
        ; Same pattern documented in RouteRepository (routeObj vs Route).
        if !(repo is RouteRepository)
            throw TypeError("RouteService: 'repo' must be RouteRepository")

        this._bus  := bus
        this._repo := repo
        this._log  := log               ; "" or LogService; diagnostic only
        this._zoneProvider := zoneProvider ; "" or callable; used only by Reset re-sync
        ; Start with an empty Route so GetCurrentRoute never returns
        ; "" — every public query stays type-safe even before the
        ; composition root calls LoadRouteForProfile.
        this._route := Route()

        this._handlerZoneEntered    := (data) => this._OnZoneEntered(data)
        this._handlerRunStarted     := (data) => this._OnRunLifecycleReset(data)
        this._handlerRunReset       := (data) => this._OnRunLifecycleReset(data)
        this._handlerRunCancelled   := (data) => this._OnRunLifecycleReset(data)
        this._handlerProfileChanged := (data) => this._OnProfileChanged(data)

        bus.Subscribe(Events.ZoneEntered,    this._handlerZoneEntered)
        bus.Subscribe(Events.RunStarted,     this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,       this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,   this._handlerRunCancelled)
        bus.Subscribe(Events.ProfileChanged, this._handlerProfileChanged)
    }

    ; ------------------------------------------------------------
    ; Public API
    ; ------------------------------------------------------------

    ; Loads the route for the given profile from the repository.
    ; Called by the composition root on boot AFTER subscribers
    ; are wired (GSG §17 item 1: hydrate-before-subscribers).
    ; Also called internally on Evt.ProfileChanged.
    ;
    ; Resets _currentIdx to -1 — a fresh profile means "haven't
    ; started this route yet". Publishes Evt.RouteChanged so the
    ; widget re-renders.
    LoadRouteForProfile(profileName)
    {
        this._currentProfile := String(profileName)
        this._route := this._repo.Load(this._currentProfile)
        this._LogInfo("LoadRouteForProfile: profile='" this._currentProfile
            "' hasRoute=" (this._route.HasRoute() ? "1" : "0")
            " count=" this._route.Count())
        this._PublishChanged()
    }

    ; Re-loads the route from the repository for the current
    ; profile. Used after Settings UI mutates the route via the
    ; repo directly (Settings doesn't go through this service for
    ; editing — only for reading the live state).
    ;
    ; No-op when no profile has been loaded yet (early-boot case).
    Refresh()
    {
        if (this._currentProfile = "")
            return
        this._route := this._repo.Load(this._currentProfile)
        this._PublishChanged()
    }

    GetCurrentRoute() => this._route
    HasRoute()        => this._route.HasRoute()
    Count()           => this._route.Count()
    GetCurrentIdx()   => this._route.GetCurrentIdx()
    GetCurrentProfile() => this._currentProfile

    ; Pass-through to Route.GetVisibleSlice. The widget calls this
    ; on every render. Returning the slice as-is keeps Route's
    ; encapsulation: the widget never touches the internal array.
    GetVisibleSlice(n) => this._route.GetVisibleSlice(n)

    ; ------------------------------------------------------------
    ; Lifecycle
    ; ------------------------------------------------------------

    Dispose()
    {
        if (this._handlerZoneEntered != "")
        {
            this._bus.Unsubscribe(Events.ZoneEntered, this._handlerZoneEntered)
            this._handlerZoneEntered := ""
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
        if (this._handlerProfileChanged != "")
        {
            this._bus.Unsubscribe(Events.ProfileChanged, this._handlerProfileChanged)
            this._handlerProfileChanged := ""
        }
    }

    ; ------------------------------------------------------------
    ; Event handlers
    ; ------------------------------------------------------------

    ; Evt.ZoneEntered handler. Filters town zones (Q5: cities
    ; ignored entirely) and asks the Route to advance / retreat
    ; to the matching position. Off-route zones are silent no-ops
    ; — no event is published when the state doesn't change.
    _OnZoneEntered(data)
    {
        if !IsObject(data)
            return
        if !data.Has("zoneName")
            return
        zoneName := String(data["zoneName"])
        if (Trim(zoneName) = "")
            return

        ; Q5: town zones never advance the route. ZoneTrackingService
        ; enriches the payload with isTown via ZonesCatalog, so this
        ; layer trusts the flag without re-querying the catalog.
        if (data.Has("isTown") && data["isTown"])
        {
            this._LogInfo("ZoneEntered SKIP (town): '" zoneName "' currentIdx=" this._route.GetCurrentIdx())
            return
        }

        prevIdx := this._route.GetCurrentIdx()
        ; AdvanceTo returns true only when _currentIdx actually
        ; changed (forward match or backward retreat). Off-route
        ; entries return false and we stay silent — no spam on the
        ; bus when the runner walks through unlisted zones.
        if this._route.AdvanceTo(zoneName)
        {
            this._LogInfo("ZoneEntered ADVANCED: '" zoneName "' " prevIdx " -> " this._route.GetCurrentIdx())
            this._PublishChanged()
        }
        else
        {
            this._LogInfo("ZoneEntered OFF-ROUTE: '" zoneName "' currentIdx=" prevIdx " (no change)")
        }
    }

    ; Resets the route position on any "fresh start" run event.
    ; RunStarted (including hydrated runs), RunReset, RunCancelled
    ; all route here.
    ;
    ; For HYDRATED runs (app re-launched mid-run, data.hydrated =
    ; true), the route still resets to -1 because we can't know
    ; which zones the runner already visited between sessions —
    ; _currentIdx is deliberately not persisted. The next
    ; ZoneEntered will re-sync via AdvanceTo's forward-or-backward
    ; scan within a few seconds of resumed play.
    _OnRunLifecycleReset(data)
    {
        evtName := IsObject(data) && data.Has("hydrated") && data["hydrated"]
                   ? "RunStarted(hydrated)"
                   : "RunLifecycle"
        prevIdx := this._route.GetCurrentIdx()
        this._route.Reset()

        ; Re-sync to the player's current zone. The classic crash
        ; case: runner ALREADY standing in The Riverbank when
        ; RunStarted fires (autoStart regex matched the "homem
        ; ferido" dialogue, or the user pressed New Run after
        ; loading into the zone). Without this re-sync, the
        ; previous `Reset() → currentIdx = -1` would strip the
        ; highlight, and no `ZoneEntered` would fire until the
        ; runner left the zone — minutes of confusion.
        ;
        ; Empty / off-route zones leave currentIdx at -1, matching
        ; the original semantics ("haven't started this route yet").
        if RouteService._IsCallable(this._zoneProvider)
        {
            try
            {
                activeZone := (this._zoneProvider)()
                if (Trim(String(activeZone)) != "")
                    this._route.AdvanceTo(activeZone)
            }
        }

        this._LogInfo("RESET via " evtName ": prevIdx=" prevIdx
            " newIdx=" this._route.GetCurrentIdx())
        this._PublishChanged()
    }

    ; Evt.ProfileChanged handler. Reloads the route from the new
    ; profile's INI file. The new profile gets _currentIdx = -1
    ; via LoadRouteForProfile.
    _OnProfileChanged(data)
    {
        if !IsObject(data)
            return
        if !data.Has("profileName")
            return
        name := String(data["profileName"])
        if (Trim(name) = "")
            return
        this.LoadRouteForProfile(name)
    }

    ; ------------------------------------------------------------
    ; Internal helpers
    ; ------------------------------------------------------------

    ; Publishes Evt.RouteChanged with the current state. The
    ; payload carries enough for the widget to render without
    ; re-querying the service, but also includes a reference to
    ; the Route itself for subscribers that want to traverse it
    ; directly (e.g. integration tests).
    _PublishChanged()
    {
        this._bus.Publish(Events.RouteChanged, Map(
            "currentIdx", this._route.GetCurrentIdx(),
            "totalZones", this._route.Count(),
            "hasRoute",   this._route.HasRoute(),
            "route",      this._route
        ))
    }

    ; Diagnostic logging — silent no-op when no log was injected.
    ; B4 Stage 2 only: helps trace mid-run state transitions while
    ; the feature is in shakedown. Once the feature stabilizes,
    ; the .Info → .Debug downgrade (or removal) is a CHANGELOG-
    ; worthy chore.
    _LogInfo(msg)
    {
        if !IsObject(this._log)
            return
        try this._log.Info(msg, "Route")
    }

    ; Same callable detection used by RouteWidget.
    static _IsCallable(f)
    {
        if (f = "")
            return false
        return HasMethod(f, "Call")
    }
}

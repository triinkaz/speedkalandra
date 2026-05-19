; ============================================================
; CompactLayoutWidget tests
; ============================================================
;
; CompactLayoutWidget renders the horizontal speedrun overlay bar.
; Like every WidgetBase subclass, its constructor only subscribes to
; the bus and stores dep refs — the real Gui controls are created
; lazily in Show()/_BuildGui(). That separation is what makes the
; widget testable headless: we can construct it, fire events at it,
; and assert state mutations without ever creating a window.
;
; What's testable here:
;   - Constructor smoke (no throw with minimal or full deps)
;   - _GetFixedSize() — pure static-style readback
;   - Static pure helpers:
;       _EstimateTextW (used to shrink the zone label font when long)
;       _SegmentLabel  (used to decide bar-segment text vs %% vs empty)
;   - Pure instance methods:
;       _FormatAct, _ResolveTimerColor
;   - Bus event handlers that mutate state without touching Gui:
;       _OnDeathDetected, _OnRunRestart, _OnZoneEntered
;     They're already guarded by `if !this._gui return` at the
;     refresh boundary, so calling them on a widget that hasn't
;     been Show()n is safe by design.
;   - Dispose() — unsubscribes from the bus
;
; What's NOT testable headless:
;   - Show() / _BuildGui() (creates real Gui controls)
;   - _Refresh() and the SetFont/Move/Value cascade (needs _gui)
;   - Vendor button clicks (OnEvent handlers attached to real
;     Gui controls)


class CompactLayoutWidgetTests extends TestCase
{
    bus           := ""
    position      := ""
    cfg           := ""
    persistCount  := 0
    persistCb     := ""
    timer         := ""
    stubClock     := ""
    zoneTracker   := ""
    xp            := ""
    catalogPath   := ""
    catalog       := ""
    loadingTotals := ""
    pbRepoPath    := ""
    pbService     := ""
    widget        := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(1000)
        this.cfg       := AppSettings.Defaults()

        this.position := OverlayPosition.FromMap(Map(
            "left", 10.0, "top", 5.0, "scale", 1.0,
            "visible", false, "centered", false
        ))

        this.persistCount := 0
        this.persistCb    := ObjBindMethod(this, "_PersistCounter")

        this.timer       := TimerService(this.stubClock, this.bus)
        this.xp          := XpService()
        this.catalogPath := Fixtures.TempPath("csv")
        FileAppend(
            "name;internal_id;act;is_town`n"
            . "Clearfell Encampment;G1_town;1;1`n"
            . "Mud Burrow;G1_3;1;0`n",
            this.catalogPath, "UTF-8")
        this.catalog       := ZonesCatalog(this.catalogPath)
        this.zoneTracker   := ZoneTrackingService(this.bus, this.stubClock, this.catalog)
        this.loadingTotals := LoadingTotalsService(this.bus)

        this.pbRepoPath := Fixtures.TempPath("ini")
        this.pbService  := PersonalBestService(PersonalBestRepository(this.pbRepoPath))

        this.widget := CompactLayoutWidget(
            this.bus, this.position, this.persistCb,
            this.timer, this.zoneTracker, this.xp,
            this.catalog, this.loadingTotals, this.cfg, this.pbService
        )
    }

    Teardown()
    {
        if IsObject(this.widget)
            try this.widget.Dispose()
        Fixtures.CleanupAll()
    }

    _PersistCounter()
    {
        this.persistCount += 1
    }

    static Tests := [
        ; --- Constructor smoke ---
        "constructor_does_not_throw_with_minimal_deps",
        "constructor_does_not_throw_with_full_deps_including_pb",

        ; --- _GetFixedSize ---
        "get_fixed_size_returns_380_by_96_at_scale_1",

        ; --- Static: _EstimateTextW ---
        "estimate_text_w_grows_with_string_length",
        "estimate_text_w_grows_with_font_size",
        "estimate_text_w_zero_for_empty_string",

        ; --- Static: _SegmentLabel ---
        "segment_label_empty_when_width_below_min_pct_w",
        "segment_label_pct_only_when_width_between_min_pct_w_and_min_label_w",
        "segment_label_name_and_pct_when_width_above_min_label_w",

        ; --- Pure instance methods ---
        "format_act_returns_em_dash_when_act_unknown",
        "format_act_returns_act_n_when_known",
        "resolve_timer_color_neutral_when_pb_absent",
        "resolve_timer_color_under_pb_is_good_strong",
        "resolve_timer_color_over_pb_is_danger",

        ; --- Bus event handlers ---
        "on_death_detected_increments_counter",
        "on_run_restart_zeroes_counter",
        "on_zone_entered_mutates_current_zone_and_act",

        ; --- Lifecycle ---
        "dispose_unsubscribes_all_handlers"
    ]

    ; ============================================================
    ; Constructor smoke
    ; ============================================================

    constructor_does_not_throw_with_minimal_deps()
    {
        ; Setup already constructed with full deps. Here we
        ; cross-check that the widget also accepts the minimal set
        ; (bus, position, persist, timer, zoneTracker, xp — the rest
        ; default to ""). This is the path the entry script uses
        ; before PersonalBestService is wired.
        freshBus      := Fixtures.MakeBus()
        freshClock    := Fixtures.MakeFakeClock(1000)
        freshTimer    := TimerService(freshClock, freshBus)
        freshXp       := XpService()
        freshTracker  := ZoneTrackingService(freshBus, freshClock, this.catalog)
        freshPos      := OverlayPosition.FromMap(Map(
            "left", 0.0, "top", 0.0, "scale", 1.0,
            "visible", false, "centered", false
        ))

        w := CompactLayoutWidget(freshBus, freshPos, "",
            freshTimer, freshTracker, freshXp)

        Assert.True(IsObject(w), "constructor returns the widget")
        Assert.Equal("compactLayout", w.id)
        Assert.Equal("Layout Compact", w.name)

        try w.Dispose()
    }

    constructor_does_not_throw_with_full_deps_including_pb()
    {
        Assert.True(IsObject(this.widget), "setup-time construction with full deps")
        Assert.Equal("compactLayout", this.widget.id)
    }

    ; ============================================================
    ; _GetFixedSize
    ; ============================================================

    get_fixed_size_returns_380_by_96_at_scale_1()
    {
        ; FIXED_W=380 FIXED_H=96 are the design baseline; Show()
        ; multiplies them by _position.scale. If a future redesign
        ; changes these, the test should be updated consciously —
        ; widget positions persisted in user INIs depend on the
        ; baseline aspect ratio holding steady.
        size := this.widget._GetFixedSize()
        Assert.Equal(380, size["w"])
        Assert.Equal(96,  size["h"])
    }

    ; ============================================================
    ; Static: _EstimateTextW
    ; ============================================================

    estimate_text_w_grows_with_string_length()
    {
        ; _EstimateTextW = chars × fontSize × 0.6. Used in
        ; _RefreshZoneText to shrink the zone-label font when the
        ; text doesn't fit the available width. Linearity in string
        ; length is the property the shrink loop relies on.
        w5  := CompactLayoutWidget._EstimateTextW("AAAAA",  10)
        w10 := CompactLayoutWidget._EstimateTextW("AAAAAAAAAA", 10)
        Assert.True(w10 > w5,
            "longer string yields wider estimate (" w10 " > " w5 ")")
        ; Roughly 2× length should yield ~2× width.
        Assert.True(w10 >= w5 * 1.5,
            "10 chars are at least 1.5× wider than 5 chars at the same font")
    }

    estimate_text_w_grows_with_font_size()
    {
        wSmall := CompactLayoutWidget._EstimateTextW("AAAAA", 8)
        wLarge := CompactLayoutWidget._EstimateTextW("AAAAA", 14)
        Assert.True(wLarge > wSmall,
            "larger font yields wider estimate (" wLarge " > " wSmall ")")
    }

    estimate_text_w_zero_for_empty_string()
    {
        ; Edge case: an empty zone (between zones) gives 0 — the
        ; shrink loop would otherwise loop on impossible math.
        Assert.Equal(0, CompactLayoutWidget._EstimateTextW("", 10))
    }

    ; ============================================================
    ; Static: _SegmentLabel
    ; ============================================================

    segment_label_empty_when_width_below_min_pct_w()
    {
        ; Below the percent-only threshold: empty label. The bar
        ; renders an unlabeled colored segment — readable but no
        ; text to squeeze in.
        result := CompactLayoutWidget._SegmentLabel("Map", 5, 10, 30, 70)
        Assert.Equal("", result, "narrow segment shows no label")
    }

    segment_label_pct_only_when_width_between_min_pct_w_and_min_label_w()
    {
        ; Between thresholds: just the percentage. Tight but
        ; informative — the user still knows what fraction of the
        ; run this segment represents.
        result := CompactLayoutWidget._SegmentLabel("Map", 25, 50, 30, 70)
        Assert.Equal("25%", result, "medium segment shows only pct")
    }

    segment_label_name_and_pct_when_width_above_min_label_w()
    {
        ; Above the label threshold: full "Name pct%" — the
        ; ergonomic case the layout aims for at default scale.
        result := CompactLayoutWidget._SegmentLabel("Map", 70, 100, 30, 70)
        Assert.Equal("Map 70%", result, "wide segment shows name + pct")
    }

    ; ============================================================
    ; Pure instance methods
    ; ============================================================

    format_act_returns_em_dash_when_act_unknown()
    {
        ; With _currentAct=0 (not yet entered a zone), the display
        ; shows "Act —". This is the cold-start state right after
        ; constructor before any ZoneEntered fires.
        ;
        ; Uses Chr(0x2014) instead of a literal em-dash so the
        ; comparison doesn't depend on the test file's encoding
        ; matching the source file's encoding bit-for-bit.
        emDash := Chr(0x2014)
        Assert.Equal(0, this.widget._currentAct, "sanity: cold-start act")
        Assert.Equal("Act " emDash, this.widget._FormatAct())
    }

    format_act_returns_act_n_when_known()
    {
        this.widget._currentAct := 3
        Assert.Equal("Act 3", this.widget._FormatAct())
    }

    resolve_timer_color_neutral_when_pb_absent()
    {
        ; Two paths to "neutral" (Theme.Color("text")):
        ;   - PB absent (player hasn't completed a run yet)
        ;   - Timer at zero (run hasn't started)
        ; Both legitimately mean "no comparison to color against".
        neutralColor := Theme.Color("text")
        Assert.Equal(neutralColor, this.widget._ResolveTimerColor(60000, 0),
            "PB=0 => neutral color")
        Assert.Equal(neutralColor, this.widget._ResolveTimerColor(0, 60000),
            "timer=0 => neutral color")
    }

    resolve_timer_color_under_pb_is_good_strong()
    {
        ; Under PB: vibrant green. goodStrong (not the desaturated
        ; "good") is intentional — the user needs the "under PB"
        ; color to pop against the desaturated red for "over PB".
        expected := Theme.Color("goodStrong")
        Assert.Equal(expected, this.widget._ResolveTimerColor(50000, 60000),
            "current < PB => goodStrong (green)")
        Assert.Equal(expected, this.widget._ResolveTimerColor(60000, 60000),
            "tie counts as under PB (favours the player)")
    }

    resolve_timer_color_over_pb_is_danger()
    {
        Assert.Equal(Theme.Color("danger"),
            this.widget._ResolveTimerColor(70000, 60000),
            "current > PB => danger (red)")
    }

    ; ============================================================
    ; Bus event handlers
    ; ============================================================

    on_death_detected_increments_counter()
    {
        ; Each DeathDetected adds 1 to the in-run death counter,
        ; shown as "✗ N" on LINE 2 of the widget. Source-agnostic:
        ; whether the event comes from the log monitor or a test
        ; harness, the count increments.
        Assert.Equal(0, this.widget._deathCount, "starts at zero")
        this.bus.Publish(Events.DeathDetected, Map("character", "TestChar"))
        this.bus.Publish(Events.DeathDetected, Map("character", "TestChar"))
        Assert.Equal(2, this.widget._deathCount, "two deaths accumulate")
    }

    on_run_restart_zeroes_counter()
    {
        ; Three fresh-start events all zero the counter:
        ;   RunStarted    — explicit new run
        ;   RunReset      — hotkey reset
        ;   RunCancelled  — hotkey cancel
        ; Notably RunCompleted is NOT one of them: deaths survive
        ; finalize so the user can review the plot with the count
        ; still on screen.
        this.bus.Publish(Events.DeathDetected, Map("character", "X"))
        this.bus.Publish(Events.DeathDetected, Map("character", "X"))
        Assert.Equal(2, this.widget._deathCount, "two deaths before reset")

        this.bus.Publish(Events.RunStarted, Map("runId", "abc"))
        Assert.Equal(0, this.widget._deathCount, "RunStarted zeroes the counter")

        this.bus.Publish(Events.DeathDetected, Map("character", "X"))
        Assert.Equal(1, this.widget._deathCount)
        this.bus.Publish(Events.RunReset, Map("runId", "abc"))
        Assert.Equal(0, this.widget._deathCount, "RunReset zeroes the counter")

        this.bus.Publish(Events.DeathDetected, Map("character", "X"))
        Assert.Equal(1, this.widget._deathCount)
        this.bus.Publish(Events.RunCancelled, Map("runId", "abc"))
        Assert.Equal(0, this.widget._deathCount, "RunCancelled zeroes the counter")
    }

    on_zone_entered_mutates_current_zone_and_act()
    {
        ; ZoneEntered with both zoneName + actIndex sets both.
        ; LINE 1 of the widget reads these on the next _Refresh tick
        ; — until then, the widget keeps the previous zone visible
        ; (no jarring blank state mid-transition).
        Assert.Equal("", this.widget._currentZone)
        Assert.Equal(0,  this.widget._currentAct)

        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "Mud Burrow",
            "actIndex", 1
        ))

        Assert.Equal("Mud Burrow", this.widget._currentZone)
        Assert.Equal(1,            this.widget._currentAct)
    }

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    dispose_unsubscribes_all_handlers()
    {
        ; Dispose must clean up every bus subscription. Without it,
        ; long-running tests or hot-reload paths would accumulate
        ; ghost handlers — each one would fire on every Publish even
        ; after the widget is unreachable, multiplying the work and
        ; eventually hitting Unsubscribe errors when the widget
        ; references go stale.
        beforeTick      := this.bus.Subscribers(Events.Tick)
        beforeZone      := this.bus.Subscribers(Events.ZoneEntered)
        beforeLevelUp   := this.bus.Subscribers(Events.CharacterLevelUp)
        beforeAreaLevel := this.bus.Subscribers(Events.AreaLevelChanged)
        beforeRunStart  := this.bus.Subscribers(Events.RunStarted)
        beforeRunReset  := this.bus.Subscribers(Events.RunReset)
        beforeRunCancel := this.bus.Subscribers(Events.RunCancelled)
        beforeDeath     := this.bus.Subscribers(Events.DeathDetected)
        beforeVendor    := this.bus.Subscribers(Events.VendorRegexesChanged)

        this.widget.Dispose()

        Assert.Equal(beforeTick      - 1, this.bus.Subscribers(Events.Tick))
        Assert.Equal(beforeZone      - 1, this.bus.Subscribers(Events.ZoneEntered))
        Assert.Equal(beforeLevelUp   - 1, this.bus.Subscribers(Events.CharacterLevelUp))
        Assert.Equal(beforeAreaLevel - 1, this.bus.Subscribers(Events.AreaLevelChanged))
        Assert.Equal(beforeRunStart  - 1, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(beforeRunReset  - 1, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(beforeRunCancel - 1, this.bus.Subscribers(Events.RunCancelled))
        Assert.Equal(beforeDeath     - 1, this.bus.Subscribers(Events.DeathDetected))
        Assert.Equal(beforeVendor    - 1, this.bus.Subscribers(Events.VendorRegexesChanged))

        ; Setting widget=null so Teardown's Dispose() is a no-op
        ; (Dispose IS idempotent, but no need to call it twice).
        this.widget := ""
    }
}

TestRegistry.Register(CompactLayoutWidgetTests)

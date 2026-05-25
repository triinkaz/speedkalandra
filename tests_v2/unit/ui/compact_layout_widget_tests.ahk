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

        ; --- Static: _ResolveTimerColor (live timer colour vs PB) ---
        "resolve_timer_color_neutral_when_pb_absent",
        "resolve_timer_color_under_pb_is_good_strong",
        "resolve_timer_color_over_pb_is_danger",

        ; --- Static: _FormatMs (live mono timer, no centiseconds) ---
        "format_ms_zero_returns_zero_padded",
        "format_ms_under_hour_no_centiseconds",
        "format_ms_over_hour",
        "format_ms_negative_treated_as_zero",

        ; --- Static: _FormatMsShort (PB chips, no centiseconds) ---
        "format_ms_short_under_hour",
        "format_ms_short_over_hour",

        ; --- Static: _SplitToTwoWords (left-column layout) ---
        "split_to_two_words_empty_string",
        "split_to_two_words_single_word",
        "split_to_two_words_two_words",
        "split_to_two_words_three_words_drops_third",

        ; --- Static: _TruncateToWidth (zone-name overflow) ---
        "truncate_short_text_returns_as_is",
        "truncate_long_text_appends_ellipsis",
        "truncate_empty_text_returns_empty",
        "truncate_very_narrow_avail_returns_just_ellipsis",

        ; --- Bus event handlers ---
        "on_death_detected_increments_counter",
        "on_run_restart_zeroes_counter",
        "on_zone_entered_mutates_current_zone_and_act",

        ; --- Defensive: extremely long zone names ---
        "on_zone_entered_accepts_200_char_zone_name_without_throwing",

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
    ; Static: _ResolveTimerColor — colour branch coverage
    ; ============================================================
    ;
    ; The canonical Compact widget exposes _ResolveTimerColor as a
    ; static helper (no `this`-state dependency). The widget calls
    ; it twice per refresh: once for the ZONE block (current zone
    ; ms vs zone PB) and once for the RUN block (run ms vs run PB
    ; for the current act). The same helper is also pinned by the
    ; Steve / Micro tests; keeping it tested in each widget's suite
    ; catches a copy-paste regression in any one of them without
    ; cross-suite coupling.

    resolve_timer_color_neutral_when_pb_absent()
    {
        ; Two paths to neutral (Theme.Color("text")):
        ;   pbMs=0       — no PB yet (first run, or PB file fresh)
        ;   currentMs=0  — timer hasn't started ticking
        ; Both legitimately mean "no comparison to colour against".
        neutralColor := Theme.Color("text")
        Assert.Equal(neutralColor,
            CompactLayoutWidget._ResolveTimerColor(60000, 0),
            "PB=0 => neutral colour")
        Assert.Equal(neutralColor,
            CompactLayoutWidget._ResolveTimerColor(0, 60000),
            "timer=0 => neutral colour")
    }

    resolve_timer_color_under_pb_is_good_strong()
    {
        ; Under PB: vibrant green. goodStrong (not the desaturated
        ; "good") is intentional — the user needs the "under PB"
        ; colour to pop against the desaturated red for "over PB".
        expected := Theme.Color("goodStrong")
        Assert.Equal(expected,
            CompactLayoutWidget._ResolveTimerColor(50000, 60000),
            "current < PB => goodStrong (green)")
        Assert.Equal(expected,
            CompactLayoutWidget._ResolveTimerColor(60000, 60000),
            "tie counts as under PB (favours the player)")
    }

    resolve_timer_color_over_pb_is_danger()
    {
        Assert.Equal(Theme.Color("danger"),
            CompactLayoutWidget._ResolveTimerColor(70000, 60000),
            "current > PB => danger (red)")
    }

    ; ============================================================
    ; Static: _FormatMs — live mono timer, no centiseconds
    ; ============================================================
    ;
    ; Compact intentionally drops centiseconds from the live timer:
    ; the widget sits next to a static zone-name column on the
    ; left and ticking cs digits compete visually with the steady
    ; text. PB sub-labels are already cs-free via _FormatMsShort,
    ; so both rows end up with the same MM:SS shape. (Compact and
    ; Steve match; Micro keeps centiseconds — see micro tests.)

    format_ms_zero_returns_zero_padded()
    {
        Assert.Equal("00:00", CompactLayoutWidget._FormatMs(0))
    }

    format_ms_under_hour_no_centiseconds()
    {
        ; 2 min 31 s 234 ms — the ms tail is dropped (NOT rounded
        ; up). MM:SS shape so the column width is stable.
        Assert.Equal("02:31", CompactLayoutWidget._FormatMs(151234))
    }

    format_ms_over_hour()
    {
        ; 1 h 23 min 45 s → "1:23:45" — switches to H:MM:SS so
        ; the column can hold the longer string without crop.
        Assert.Equal("1:23:45", CompactLayoutWidget._FormatMs(5025000))
    }

    format_ms_negative_treated_as_zero()
    {
        ; Defensive: a corrupt clock or under-flow shouldn't
        ; crash the timer render. Negative is normalized to 0.
        Assert.Equal("00:00", CompactLayoutWidget._FormatMs(-100))
    }

    ; ============================================================
    ; Static: _FormatMsShort — PB chip, no centiseconds, no leading zero
    ; ============================================================
    ;
    ; PB sub-labels render with this format so the chip stays
    ; compact even at scale=0.8. "2:15" not "02:15"; "1:23:45"
    ; matches _FormatMs at the 1 h+ boundary so the live timer
    ; and the PB chip read the same shape under a long run.

    format_ms_short_under_hour()
    {
        ; 2 min 15 s → "2:15" (no leading zero on minutes).
        Assert.Equal("2:15", CompactLayoutWidget._FormatMsShort(135000))
    }

    format_ms_short_over_hour()
    {
        Assert.Equal("1:23:45",
            CompactLayoutWidget._FormatMsShort(5025000))
    }

    ; ============================================================
    ; Static: _SplitToTwoWords — left-column layout
    ; ============================================================
    ;
    ; The Compact widget's left column stacks two zone-name lines,
    ; one word each. Showing partial tails ("Strand" of "The
    ; Twilight Strand") would clutter without communicating the
    ; rest, so words after the second are dropped. Truncation of
    ; a single overlong word falls back to _TruncateToWidth in
    ; the rendering path.

    split_to_two_words_empty_string()
    {
        result := CompactLayoutWidget._SplitToTwoWords("")
        Assert.Equal("", result["line1"])
        Assert.Equal("", result["line2"])
    }

    split_to_two_words_single_word()
    {
        ; Single word → first line; second line blank so the
        ; second control renders empty rather than echoing line1.
        result := CompactLayoutWidget._SplitToTwoWords("Crypt")
        Assert.Equal("Crypt", result["line1"])
        Assert.Equal("",      result["line2"])
    }

    split_to_two_words_two_words()
    {
        result := CompactLayoutWidget._SplitToTwoWords("Mud Burrow")
        Assert.Equal("Mud",    result["line1"])
        Assert.Equal("Burrow", result["line2"])
    }

    split_to_two_words_three_words_drops_third()
    {
        ; "The Twilight Strand" — third word dropped on purpose.
        result := CompactLayoutWidget._SplitToTwoWords("The Twilight Strand")
        Assert.Equal("The",      result["line1"])
        Assert.Equal("Twilight", result["line2"])
    }

    ; ============================================================
    ; Static: _TruncateToWidth — zone-name overflow guard
    ; ============================================================
    ;
    ; Used in the rendering path when a zone name is a single
    ; overlong word (so _SplitToTwoWords can't help) or when the
    ; widget is at scale < 1.0 and the left column is narrower
    ; than even the two-word split needs. Reserves space for
    ; "..." up front so the visible prefix doesn't need to be
    ; retrimmed after the ellipsis is appended.

    truncate_short_text_returns_as_is()
    {
        ; "Crypt" at 10pt × 0.6 = ~30 px estimate; far under 100.
        Assert.Equal("Crypt",
            CompactLayoutWidget._TruncateToWidth("Crypt", 10, 100))
    }

    truncate_long_text_appends_ellipsis()
    {
        ; 29-char string at 10pt × 0.6 = ~174 px, over a 60 px
        ; budget. Returns "<prefix>..." that ends with the
        ; ellipsis and is strictly shorter than the input.
        bigName := "Clearfell Encampment Mountain"
        result := CompactLayoutWidget._TruncateToWidth(bigName, 10, 60)
        Assert.Equal("...", SubStr(result, -3),
            "truncated must end in '...': got '" result "'")
        Assert.True(StrLen(result) < StrLen(bigName),
            "truncated must be shorter than the original")
    }

    truncate_empty_text_returns_empty()
    {
        Assert.Equal("",
            CompactLayoutWidget._TruncateToWidth("", 10, 100))
    }

    truncate_very_narrow_avail_returns_just_ellipsis()
    {
        ; availW < ellipsisW: helper returns "..." alone (still
        ; signals truncation visually) rather than a half-
        ; rendered ellipsis or crashing.
        Assert.Equal("...",
            CompactLayoutWidget._TruncateToWidth("anything", 10, 5))
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
    ; Defensive: extremely long zone names
    ; ============================================================
    ;
    ; Real PoE2 zone names cap at ~40 chars; the import validator
    ; allows up to MAX_STRING_LEN (500). Between those, a value of
    ; 200 characters is the realistic worst case for a hand-edited
    ; INI or a future game expansion with verbose location strings
    ; ("The Deep Forge Where the Brass Mistress Sleeps Beneath…").
    ; The widget must not throw on the state-mutation path —
    ; rendering (font shrink, clipping) is delegated to the lazy
    ; _Refresh tick guarded by `if !this._gui return`, which we
    ; can't exercise headless. The static helpers exercised above
    ; (_TruncateToWidth, _SplitToTwoWords) carry the heavy lifting
    ; for the real render path; this section pins the headless
    ; entry point.

    on_zone_entered_accepts_200_char_zone_name_without_throwing()
    {
        ; State-mutation path only. The widget's bus subscription
        ; writes _currentZone and _currentAct on the ZoneEntered
        ; payload; the next _Refresh would apply font shrink
        ; against the real Gui controls. Headless, the bus path
        ; must complete without an exception and store the value
        ; verbatim for the next render to consume.
        bigName := ""
        loop 200
            bigName .= "Z"

        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", bigName,
            "actIndex", 1
        ))

        Assert.Equal(bigName, this.widget._currentZone,
            "long zone name stored verbatim, no truncation in the handler")
        Assert.Equal(1, this.widget._currentAct)
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

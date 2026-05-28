; ============================================================
; LogMonitorServiceTests
; ============================================================
;
; LogMonitorService is pure parsing of PoE2's Client.txt. ProcessText
; is the public test interface — receives a chunk of text and
; publishes events on the bus.
;
; Recognized lines:
;   - "X (Class) is now level N"     -> CharacterLevelUp
;   - "Generating level N area X"    -> AreaLevelChanged
;   - "[SCENE] Set Source [name]"    -> SceneEntered + ZoneChanged (Bug #21)
;   - "You have entered X"           -> ZoneChanged
;   - "<Name> has been slain."       -> DeathDetected (filtered by _characterName)
;   - "[WINDOW] Lost/Gained focus"   -> WindowFocusChanged
;
; Also publishes LogLineRead for EVERY line (broadcast for
; specialized parsers).
;
; Filters:
;   - Scene: filters "(null)", "(unknown)", "Act N" (transition marker)
;   - Death: requires _characterName set + exact match (Bug #2: bosses
;     would otherwise inflate deathCount)
;
; Parsing details:
;   - Partial line: chunks not ending with `n are buffered
;   - CRLF/CR: normalized to LF
;
; Lifecycle (Start/Stop/Tick) NOT tested here — depends on FileOpen,
; left for integration tests.


class LogMonitorServiceTests extends TestCase
{
    bus       := ""
    stubClock := ""
    memLog    := ""
    svc       := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(1000)
        this.memLog    := Fixtures.MakeInMemoryLogger()
        this.svc       := LogMonitorService(this.stubClock, this.bus, this.memLog)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_clock_missing_now_ms",
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_log_missing_info_method",
        "constructor_accepts_optional_catalog",
        "constructor_throws_when_catalog_not_zones_catalog",

        ; --- Configure / SetCharacterName ---
        "set_character_name_stores_name",
        "get_character_name_empty_initially",
        "set_character_name_accepts_string_conversion",

        ; --- LogLineRead broadcast ---
        "process_text_publishes_log_line_read_for_each_line",
        "log_line_read_includes_line_content",
        "empty_lines_skipped",
        "whitespace_only_lines_skipped",

        ; --- CharacterLevelUp ---
        "extracts_character_level_up_simple_case",
        "character_level_up_includes_name_class_level",
        "character_level_up_ignored_with_zero_level",
        "character_level_up_with_complex_name",
        "character_level_up_with_complex_class",

        ; --- AreaLevelChanged ---
        "extracts_area_level_simple_case",
        "area_level_changed_includes_level_and_code",
        "area_level_changed_trims_quotes_from_code",

        ; --- Cruel / Interlude (B1 Layer A) ---
        ; Cruel zone-gen lines (`C_<base>`) are the ONLY signal
        ; for cruel transitions — [SCENE] is suppressed by the
        ; engine. The area-level branch publishes BOTH events.
        "cruel_area_gen_still_publishes_area_level_changed",
        "cruel_area_gen_publishes_zone_changed_with_interlude_stage",
        "cruel_area_gen_scene_id_carries_raw_cruel_code",
        "cruel_area_gen_resolves_human_name_via_catalog",
        "cruel_area_gen_without_catalog_uses_base_code",
        "cruel_area_gen_unknown_base_code_falls_back_to_raw",
        "cruel_town_publishes_zone_changed",
        "normal_area_gen_does_not_publish_zone_changed",
        "scene_zone_changed_has_normal_stage",
        "zone_entered_zone_changed_has_normal_stage",

        ; --- SceneEntered + ZoneChanged double (Bug #21) ---
        "extracts_scene_simple_case",
        "scene_publishes_scene_entered_event",
        "scene_also_publishes_zone_changed_event_bug_21",
        "scene_with_null_is_filtered",
        "scene_with_unknown_is_filtered",
        "scene_with_act_marker_is_filtered_case_insensitive",
        "scene_with_empty_name_is_filtered",
        "scene_zone_changed_includes_scene_id",

        ; --- Zone resolution via catalog ---
        "scene_resolves_internal_id_to_human_name_when_catalog_present",
        "scene_resolves_human_name_to_canonical_when_catalog_present",
        "scene_falls_back_to_raw_when_unknown_zone_and_catalog_present",
        "zone_entered_resolves_via_catalog",
        "no_catalog_preserves_raw_for_scene",
        "no_catalog_preserves_raw_for_zone_entered",

        ; --- ZoneChanged via 'You have entered' ---
        "extracts_zone_entered_simple_case",
        "zone_entered_publishes_zone_changed",
        "zone_entered_zone_name_trimmed",
        "zone_entered_scene_id_empty",

        ; --- DeathDetected (Bug #2) ---
        "death_not_published_when_character_name_empty",
        "death_published_when_matches_character_name",
        "death_not_published_when_does_not_match_character",
        "death_extracts_name_with_colon_prefix",
        "death_extracts_name_without_colon_prefix",

        ; --- WindowFocusChanged ---
        "extracts_lost_focus",
        "extracts_gained_focus",
        "window_focus_state_value_correct",
        "window_focus_is_case_insensitive",

        ; --- Partial-line handling ---
        "partial_line_buffered_until_newline_arrives",
        "complete_line_flushed_immediately",
        "multiple_partial_chunks_concatenated",
        "trailing_newline_clears_partial_buffer",

        ; --- CRLF/CR normalization ---
        "crlf_normalized_to_lf",
        "cr_normalized_to_lf",
        "mixed_line_endings_handled",

        ; --- Unknown lines ---
        "unknown_line_still_publishes_log_line_read",
        "unknown_line_publishes_no_specific_event"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _CaptureEvents(eventName)
    {
        capturedEvents := []
        this.bus.Subscribe(eventName, (data) => capturedEvents.Push(data))
        return capturedEvents
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_clock_missing_now_ms()
    {
        b := this.bus
        memLog := this.memLog
        emptyObj := { foo: () => 0 }
        Assert.Throws(TypeError, () => LogMonitorService(emptyObj, b, memLog))
    }

    constructor_throws_when_bus_not_event_bus()
    {
        clk := this.stubClock
        memLog := this.memLog
        Assert.Throws(TypeError, () => LogMonitorService(clk, "not a bus", memLog))
    }

    constructor_throws_when_log_missing_info_method()
    {
        clk := this.stubClock
        b := this.bus
        emptyObj := { foo: () => 0 }
        Assert.Throws(TypeError, () => LogMonitorService(clk, b, emptyObj))
    }

    constructor_accepts_optional_catalog()
    {
        ; The catalog is optional — omitting it preserves the
        ; legacy behaviour (raw zone strings pass through).
        ; Passing one wires it in for _ResolveZoneToHumanName.
        clk := this.stubClock
        b := this.bus
        memLog := this.memLog
        catalog := this._MakeTestCatalog()
        ; Just construct — if it didn't throw, the type-check
        ; accepted the catalog.
        svc := LogMonitorService(clk, b, memLog, catalog)
        Assert.True(IsObject(svc), "constructor with catalog returns object")
    }

    constructor_throws_when_catalog_not_zones_catalog()
    {
        ; A wiring bug that passes a Map (or any plausible-looking
        ; object) must trip fail-fast, not silently bypass
        ; resolution and leave _catalog holding garbage.
        clk := this.stubClock
        b := this.bus
        memLog := this.memLog
        Assert.Throws(TypeError, () => LogMonitorService(clk, b, memLog, Map("not", "a catalog")))
    }

    ; ============================================================
    ; Configure / SetCharacterName
    ; ============================================================

    set_character_name_stores_name()
    {
        this.svc.SetCharacterName("Olaf")
        Assert.Equal("Olaf", this.svc.GetCharacterName())
    }

    get_character_name_empty_initially()
    {
        Assert.Equal("", this.svc.GetCharacterName())
    }

    set_character_name_accepts_string_conversion()
    {
        this.svc.SetCharacterName(12345)
        Assert.Equal("12345", this.svc.GetCharacterName())
    }

    ; ============================================================
    ; LogLineRead broadcast
    ; ============================================================

    process_text_publishes_log_line_read_for_each_line()
    {
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("line one`nline two`nline three`n")
        Assert.Equal(3, capturedEvents.Length)
    }

    log_line_read_includes_line_content()
    {
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("hello world`n")
        Assert.Equal("hello world", capturedEvents[1]["line"])
    }

    empty_lines_skipped()
    {
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("line`n`n`nother`n")
        Assert.Equal(2, capturedEvents.Length)
    }

    whitespace_only_lines_skipped()
    {
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("   `nactual`n   `n")
        Assert.Equal(1, capturedEvents.Length, "Only 'actual' is non-empty after Trim")
    }

    ; ============================================================
    ; CharacterLevelUp
    ; ============================================================

    extracts_character_level_up_simple_case()
    {
        capturedEvents := this._CaptureEvents(Events.CharacterLevelUp)
        this.svc.ProcessText("2026/05/15 03:25:50 12345 abc [INFO Client 123] : Olaf (Warrior) is now level 42`n")
        Assert.Equal(1, capturedEvents.Length)
    }

    character_level_up_includes_name_class_level()
    {
        capturedEvents := this._CaptureEvents(Events.CharacterLevelUp)
        this.svc.ProcessText(": Olaf (Warrior) is now level 42`n")
        ev := capturedEvents[1]
        Assert.Equal("Olaf",    ev["character"])
        Assert.Equal("Warrior", ev["class"])
        Assert.Equal(42,        ev["level"])
    }

    character_level_up_ignored_with_zero_level()
    {
        ; level 0 must not pass through the extractor (regex requires
        ; \d+ but the `charLevel > 0` check filters it)
        capturedEvents := this._CaptureEvents(Events.CharacterLevelUp)
        this.svc.ProcessText(": Olaf (Warrior) is now level 0`n")
        Assert.Equal(0, capturedEvents.Length)
    }

    character_level_up_with_complex_name()
    {
        capturedEvents := this._CaptureEvents(Events.CharacterLevelUp)
        this.svc.ProcessText(": SpeedRunner_99 (Witch) is now level 100`n")
        Assert.Equal("SpeedRunner_99", capturedEvents[1]["character"])
    }

    character_level_up_with_complex_class()
    {
        capturedEvents := this._CaptureEvents(Events.CharacterLevelUp)
        this.svc.ProcessText(": Hero (Path of the Templar) is now level 50`n")
        Assert.Equal("Path of the Templar", capturedEvents[1]["class"])
    }

    ; ============================================================
    ; AreaLevelChanged
    ; ============================================================

    extracts_area_level_simple_case()
    {
        capturedEvents := this._CaptureEvents(Events.AreaLevelChanged)
        this.svc.ProcessText("Generating level 23 area G2_TheRiver with seed 99887766`n")
        Assert.Equal(1, capturedEvents.Length)
    }

    area_level_changed_includes_level_and_code()
    {
        capturedEvents := this._CaptureEvents(Events.AreaLevelChanged)
        this.svc.ProcessText("Generating level 65 area G3_Boss with seed 12345`n")
        Assert.Equal(65,        capturedEvents[1]["areaLevel"])
        Assert.Equal("G3_Boss", capturedEvents[1]["areaCode"])
    }

    area_level_changed_trims_quotes_from_code()
    {
        ; In some lines the area code is enclosed in double quotes
        capturedEvents := this._CaptureEvents(Events.AreaLevelChanged)
        this.svc.ProcessText('Generating level 10 area "G1_2" with seed 42`n')
        Assert.Equal("G1_2", capturedEvents[1]["areaCode"], "Quotes trimmed")
    }

    ; ============================================================
    ; Cruel / Interlude (B1 Layer A)
    ; ============================================================
    ;
    ; Empirical finding: PoE2 emits cruel zone transitions ONLY
    ; through the `Generating level N area "C_<base>"` line.
    ; [SCENE] Set Source is NOT emitted for cruel — verified
    ; against a real Client.txt with thousands of cruel area-gens
    ; and zero matching SCENE lines. See class header.
    ;
    ; Pre-fix, the live pipeline (ZoneTrackingService, route widget,
    ; active-zone display, ActCheckpointTracker, etc.) was COMPLETELY
    ; blind during the interlude — not just imprecise. The area-
    ; level branch now publishes ZoneChanged for cruel codes in
    ; addition to AreaLevelChanged.

    cruel_area_gen_still_publishes_area_level_changed()
    {
        ; Regression: cruel must still publish AreaLevelChanged with
        ; the raw C_-prefixed code (subscribers like XpService and
        ; the debug widget rely on the engine id).
        capturedEvents := this._CaptureEvents(Events.AreaLevelChanged)
        this.svc.ProcessText('Generating level 51 area "C_G1_2" with seed 12345`n')
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal(51,       capturedEvents[1]["areaLevel"])
        Assert.Equal("C_G1_2", capturedEvents[1]["areaCode"])
    }

    cruel_area_gen_publishes_zone_changed_with_interlude_stage()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText('Generating level 51 area "C_G1_2" with seed 12345`n')
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("interlude", capturedEvents[1]["stage"])
    }

    cruel_area_gen_scene_id_carries_raw_cruel_code()
    {
        ; sceneId always carries the raw engine id (with C_ prefix
        ; for cruel). Diagnostics and event-tracing subscribers
        ; rely on it being the unmodified source string.
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText('Generating level 51 area "C_G1_2" with seed 12345`n')
        Assert.Equal("C_G1_2", capturedEvents[1]["sceneId"])
    }

    cruel_area_gen_resolves_human_name_via_catalog()
    {
        ; Catalog only knows base codes ("G1_2" → "Clearfell"). The
        ; cruel branch strips C_ before lookup, same pattern as
        ; DeathLogScanner._ResolveAreaCode. Result: cruel Clearfell
        ; and normal Clearfell share the same human name; the
        ; `stage` field is what distinguishes them downstream.
        svcWithCatalog := this._MakeServiceWithCatalog()
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        svcWithCatalog.ProcessText('Generating level 51 area "C_G1_2" with seed 12345`n')
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("Clearfell", capturedEvents[1]["zoneName"])
        Assert.Equal("C_G1_2",    capturedEvents[1]["sceneId"])
        Assert.Equal("interlude", capturedEvents[1]["stage"])
    }

    cruel_area_gen_without_catalog_uses_base_code()
    {
        ; No catalog: zoneName falls through as the raw base code
        ; (sans C_). Matches the legacy no-resolution behaviour of
        ; the SCENE branch when no catalog is wired.
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText('Generating level 51 area "C_G1_2" with seed 12345`n')
        Assert.Equal("G1_2",      capturedEvents[1]["zoneName"])
        Assert.Equal("C_G1_2",    capturedEvents[1]["sceneId"])
        Assert.Equal("interlude", capturedEvents[1]["stage"])
    }

    cruel_area_gen_unknown_base_code_falls_back_to_raw()
    {
        ; Catalog present but base code unknown (future zone, or
        ; mistyped). zoneName is the raw base code; the event
        ; still publishes so the live pipeline isn't silently
        ; dropping the transition.
        svcWithCatalog := this._MakeServiceWithCatalog()
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        svcWithCatalog.ProcessText('Generating level 99 area "C_G99_unknown" with seed 1`n')
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("G99_unknown",    capturedEvents[1]["zoneName"])
        Assert.Equal("C_G99_unknown",  capturedEvents[1]["sceneId"])
        Assert.Equal("interlude",      capturedEvents[1]["stage"])
    }

    cruel_town_publishes_zone_changed()
    {
        ; Cruel towns (e.g. C_G1_town → Clearfell Encampment) are
        ; also surfaced as ZoneChanged. The live pipeline can then
        ; show the user in a cruel town in the active-zone display,
        ; matching how normal towns work today.
        svcWithCatalog := this._MakeServiceWithCatalog()
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        svcWithCatalog.ProcessText('Generating level 51 area "C_G1_town" with seed 1`n')
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("Clearfell Encampment", capturedEvents[1]["zoneName"])
        Assert.Equal("interlude",            capturedEvents[1]["stage"])
    }

    normal_area_gen_does_not_publish_zone_changed()
    {
        ; Regression: normal area-gens (no C_ prefix) must NOT
        ; publish ZoneChanged from the area-level branch. The
        ; subsequent [SCENE] line is the only ZoneChanged source
        ; for normal zones — same as today's behaviour. Without
        ; this guard, every normal transition would double-publish
        ; ZoneChanged and zone-totals would double-count.
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText('Generating level 10 area "G1_2" with seed 42`n')
        Assert.Equal(0, capturedEvents.Length)
    }

    scene_zone_changed_has_normal_stage()
    {
        ; New default field on ZoneChanged. Legacy subscribers that
        ; ignore unknown keys keep working; new subscribers read
        ; `stage` to route data into per-(act, stage) buckets.
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText("[SCENE] Set Source [Clearfell]`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("normal", capturedEvents[1]["stage"])
    }

    zone_entered_zone_changed_has_normal_stage()
    {
        ; Same default applies to the legacy "You have entered"
        ; branch (defensive code, not observed in current PoE2 but
        ; retained against future engine changes).
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText("You have entered Clearfell.`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("normal", capturedEvents[1]["stage"])
    }

    ; ============================================================
    ; SceneEntered + ZoneChanged double (Bug #21)
    ; ============================================================

    extracts_scene_simple_case()
    {
        capturedEvents := this._CaptureEvents(Events.SceneEntered)
        this.svc.ProcessText("[SCENE] Set Source [Mud Burrow]`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("Mud Burrow", capturedEvents[1]["sceneId"])
    }

    scene_publishes_scene_entered_event()
    {
        capturedEvents := this._CaptureEvents(Events.SceneEntered)
        this.svc.ProcessText("[SCENE] Set Source [Clearfell]`n")
        Assert.Equal(1, capturedEvents.Length)
    }

    scene_also_publishes_zone_changed_event_bug_21()
    {
        ; Bug #21: current PoE2 doesn't emit "You have entered" on all
        ; transitions; only [SCENE]. Republishing as ZoneChanged
        ; ensures ZoneTrackingService gets the change.
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText("[SCENE] Set Source [Clearfell]`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("Clearfell", capturedEvents[1]["zoneName"])
    }

    scene_with_null_is_filtered()
    {
        sceneEvents := this._CaptureEvents(Events.SceneEntered)
        zoneEvents  := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText("[SCENE] Set Source [(null)]`n")
        Assert.Equal(0, sceneEvents.Length)
        Assert.Equal(0, zoneEvents.Length)
    }

    scene_with_unknown_is_filtered()
    {
        sceneEvents := this._CaptureEvents(Events.SceneEntered)
        this.svc.ProcessText("[SCENE] Set Source [(unknown)]`n")
        Assert.Equal(0, sceneEvents.Length)
    }

    scene_with_act_marker_is_filtered_case_insensitive()
    {
        ; "Act 1" is not a zone, it's a cinematic/title card
        sceneEvents := this._CaptureEvents(Events.SceneEntered)
        this.svc.ProcessText("[SCENE] Set Source [Act 1]`n")
        this.svc.ProcessText("[SCENE] Set Source [act 2]`n")
        this.svc.ProcessText("[SCENE] Set Source [ACT 6]`n")
        Assert.Equal(0, sceneEvents.Length, "All Act markers filtered")
    }

    scene_with_empty_name_is_filtered()
    {
        sceneEvents := this._CaptureEvents(Events.SceneEntered)
        this.svc.ProcessText("[SCENE] Set Source []`n")
        Assert.Equal(0, sceneEvents.Length)
    }

    scene_zone_changed_includes_scene_id()
    {
        ; Without a catalog (default setup), ZoneChanged via [SCENE]
        ; preserves the raw text in both fields — legacy behaviour
        ; that callers without a catalog still get. Resolution to
        ; canonical human name when a catalog IS wired is covered by
        ; the "Zone resolution via catalog" group.
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText("[SCENE] Set Source [G1_2]`n")
        Assert.Equal("G1_2", capturedEvents[1]["sceneId"])
        Assert.Equal("G1_2", capturedEvents[1]["zoneName"])
    }

    ; ============================================================
    ; Zone resolution via catalog
    ; ============================================================
    ;
    ; The PoE2 client emits `[SCENE] Set Source [<raw>]` with <raw>
    ; being either a human name ("Mud Burrow") or the engine's
    ; internal id ("G1_3"). Either way the rest of the app needs
    ; to receive the canonical human name so the zone tracker,
    ; plot builder, history and PB stores all key by the same
    ; string. _ResolveZoneToHumanName handles that here, at the
    ; publisher, instead of replicating the logic in every
    ; subscriber.

    _MakeTestCatalog()
    {
        ; Tiny CSV with three entries matching the real catalog
        ; format: G1_2 → Clearfell, G1_7 → Cemetery of the Eternals,
        ; G1_town → Clearfell Encampment. The exact data doesn't
        ; matter for the test — only that FindByName and FindById
        ; resolve as expected.
        csv := "name;internal_id;act;is_town`n"
            . "Clearfell;G1_2;1;0`n"
            . "Cemetery of the Eternals;G1_7;1;0`n"
            . "Clearfell Encampment;G1_town;1;1`n"
        csvPath := Fixtures.TempFile(csv, "csv")
        return ZonesCatalog(csvPath)
    }

    _MakeServiceWithCatalog()
    {
        catalog := this._MakeTestCatalog()
        return LogMonitorService(this.stubClock, this.bus, this.memLog, catalog)
    }

    scene_resolves_internal_id_to_human_name_when_catalog_present()
    {
        ; The smoking gun: PoE2 emits an internal id and the publisher
        ; turns it into the human name before ZoneChanged goes out.
        ; sceneId still carries the raw id so downstream subscribers
        ; that want it (event tracing, diagnostics) can see it.
        svcWithCatalog := this._MakeServiceWithCatalog()
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        svcWithCatalog.ProcessText("[SCENE] Set Source [G1_2]`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("Clearfell", capturedEvents[1]["zoneName"],
            "internal id resolved to human name")
        Assert.Equal("G1_2", capturedEvents[1]["sceneId"],
            "raw id preserved in sceneId")
    }

    scene_resolves_human_name_to_canonical_when_catalog_present()
    {
        ; If PoE2 emits the human name in [SCENE], the resolver still
        ; round-trips it through the catalog to recover canonical
        ; case/spacing. "Clearfell" stays "Clearfell" here; the more
        ; interesting case is when the log emits a slightly different
        ; variant — future-proof guarantee that the catalog wins.
        svcWithCatalog := this._MakeServiceWithCatalog()
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        svcWithCatalog.ProcessText("[SCENE] Set Source [Clearfell]`n")
        Assert.Equal("Clearfell", capturedEvents[1]["zoneName"])
    }

    scene_falls_back_to_raw_when_unknown_zone_and_catalog_present()
    {
        ; Unknown zone (a new game patch adds an area not in the CSV,
        ; or a randomized instance with an opaque name). The resolver
        ; passes the raw text through so the user still sees the new
        ; zone in the overlay/history — just without act/isTown
        ; metadata from the catalog. Better than dropping the event.
        svcWithCatalog := this._MakeServiceWithCatalog()
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        svcWithCatalog.ProcessText("[SCENE] Set Source [G99_NewZone]`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("G99_NewZone", capturedEvents[1]["zoneName"],
            "unknown zone preserved as raw")
        Assert.Equal("G99_NewZone", capturedEvents[1]["sceneId"])
    }

    zone_entered_resolves_via_catalog()
    {
        ; "You have entered" path also routes through the resolver
        ; so a log emitting a slight variant of the name (case,
        ; trailing whitespace handled by FindByName via StrLower+Trim)
        ; gets normalised to the catalog's stored form.
        svcWithCatalog := this._MakeServiceWithCatalog()
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        svcWithCatalog.ProcessText(": You have entered clearfell.`n")
        Assert.Equal("Clearfell", capturedEvents[1]["zoneName"],
            "case-insensitive lookup recovers canonical name")
        Assert.Equal("", capturedEvents[1]["sceneId"],
            "sceneId stays empty for 'You have entered'")
    }

    no_catalog_preserves_raw_for_scene()
    {
        ; Backward-compat: services without a catalog (legacy tests,
        ; headless scenarios) keep the no-resolution behaviour. This
        ; is effectively the same scenario as `scene_zone_changed_includes_scene_id`,
        ; tagged separately so the intent of the guarantee shows up
        ; in the failure log if regression hits it.
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText("[SCENE] Set Source [G1_2]`n")
        Assert.Equal("G1_2", capturedEvents[1]["zoneName"])
    }

    no_catalog_preserves_raw_for_zone_entered()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText(": You have entered clearfell.`n")
        Assert.Equal("clearfell", capturedEvents[1]["zoneName"],
            "raw lowercase preserved when no catalog")
    }

    ; ============================================================
    ; ZoneChanged via 'You have entered'
    ; ============================================================

    extracts_zone_entered_simple_case()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText(": You have entered Mud Burrow.`n")
        Assert.Equal(1, capturedEvents.Length)
    }

    zone_entered_publishes_zone_changed()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText(": You have entered Vastiri Outskirts.`n")
        Assert.Equal("Vastiri Outskirts", capturedEvents[1]["zoneName"])
    }

    zone_entered_zone_name_trimmed()
    {
        ; Trailing period removed by Trim(m[1], " .")
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText(": You have entered Clearfell Encampment.`n")
        Assert.Equal("Clearfell Encampment", capturedEvents[1]["zoneName"])
    }

    zone_entered_scene_id_empty()
    {
        ; ZoneChanged via "You have entered" has sceneId=""
        capturedEvents := this._CaptureEvents(Events.ZoneChanged)
        this.svc.ProcessText(": You have entered Mud Burrow.`n")
        Assert.Equal("", capturedEvents[1]["sceneId"])
    }

    ; ============================================================
    ; DeathDetected (Bug #2)
    ; ============================================================

    death_not_published_when_character_name_empty()
    {
        ; characterName="" = filter disabled = death is NEVER published
        capturedEvents := this._CaptureEvents(Events.DeathDetected)
        this.svc.ProcessText(": Olaf has been slain.`n")
        Assert.Equal(0, capturedEvents.Length)
    }

    death_published_when_matches_character_name()
    {
        capturedEvents := this._CaptureEvents(Events.DeathDetected)
        this.svc.SetCharacterName("Olaf")
        this.svc.ProcessText(": Olaf has been slain.`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("Olaf", capturedEvents[1]["character"])
    }

    death_not_published_when_does_not_match_character()
    {
        ; Bug #2: bosses also trigger "has been slain" — the filter prevents it
        capturedEvents := this._CaptureEvents(Events.DeathDetected)
        this.svc.SetCharacterName("Olaf")
        this.svc.ProcessText(": Geonor has been slain.`n")
        Assert.Equal(0, capturedEvents.Length, "Boss kill doesn't inflate deathCount")
    }

    death_extracts_name_with_colon_prefix()
    {
        capturedEvents := this._CaptureEvents(Events.DeathDetected)
        this.svc.SetCharacterName("Olaf")
        this.svc.ProcessText("2026/05/15 03:25:50 abc [INFO Client] : Olaf has been slain.`n")
        Assert.Equal(1, capturedEvents.Length)
    }

    death_extracts_name_without_colon_prefix()
    {
        ; Lines without timestamp prefix (rare format but exists)
        capturedEvents := this._CaptureEvents(Events.DeathDetected)
        this.svc.SetCharacterName("Olaf")
        this.svc.ProcessText("Olaf has been slain.`n")
        Assert.Equal(1, capturedEvents.Length)
    }

    ; ============================================================
    ; WindowFocusChanged
    ; ============================================================

    extracts_lost_focus()
    {
        capturedEvents := this._CaptureEvents(Events.WindowFocusChanged)
        this.svc.ProcessText("[WINDOW] Lost focus`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("lost", capturedEvents[1]["state"])
    }

    extracts_gained_focus()
    {
        capturedEvents := this._CaptureEvents(Events.WindowFocusChanged)
        this.svc.ProcessText("[WINDOW] Gained focus`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("gained", capturedEvents[1]["state"])
    }

    window_focus_state_value_correct()
    {
        capturedEvents := this._CaptureEvents(Events.WindowFocusChanged)
        this.svc.ProcessText("[WINDOW] Lost focus`n[WINDOW] Gained focus`n")
        Assert.Equal("lost",   capturedEvents[1]["state"])
        Assert.Equal("gained", capturedEvents[2]["state"])
    }

    window_focus_is_case_insensitive()
    {
        capturedEvents := this._CaptureEvents(Events.WindowFocusChanged)
        this.svc.ProcessText("[window] LOST FOCUS`n[Window] gained Focus`n")
        Assert.Equal(2, capturedEvents.Length)
    }

    ; ============================================================
    ; Partial-line handling
    ; ============================================================

    partial_line_buffered_until_newline_arrives()
    {
        ; Chunk without trailing newline: buffers
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("incomplete...")
        Assert.Equal(0, capturedEvents.Length, "Without newline: doesn't process")
        ; When the newline arrives, processes the full line
        this.svc.ProcessText(" continued`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("incomplete... continued", capturedEvents[1]["line"])
    }

    complete_line_flushed_immediately()
    {
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("complete line`n")
        Assert.Equal(1, capturedEvents.Length)
    }

    multiple_partial_chunks_concatenated()
    {
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("part1")
        this.svc.ProcessText("part2")
        this.svc.ProcessText("part3`n")
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("part1part2part3", capturedEvents[1]["line"])
    }

    trailing_newline_clears_partial_buffer()
    {
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("first`nsecond")   ; buffers "second"
        this.svc.ProcessText("`n")              ; flush
        this.svc.ProcessText("third`n")         ; doesn't concat with "second"
        Assert.Equal(3, capturedEvents.Length)
        Assert.Equal("first",  capturedEvents[1]["line"])
        Assert.Equal("second", capturedEvents[2]["line"])
        Assert.Equal("third",  capturedEvents[3]["line"])
    }

    ; ============================================================
    ; CRLF/CR normalization
    ; ============================================================

    crlf_normalized_to_lf()
    {
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("line1`r`nline2`r`n")
        Assert.Equal(2, capturedEvents.Length)
        Assert.Equal("line1", capturedEvents[1]["line"])
        Assert.Equal("line2", capturedEvents[2]["line"])
    }

    cr_normalized_to_lf()
    {
        ; Old-Mac line ending — rare case but supported
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("line1`rline2`r")
        Assert.Equal(2, capturedEvents.Length)
    }

    mixed_line_endings_handled()
    {
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("a`nb`r`nc`rd`n")
        Assert.Equal(4, capturedEvents.Length)
    }

    ; ============================================================
    ; Unknown lines
    ; ============================================================

    unknown_line_still_publishes_log_line_read()
    {
        ; LogLineRead is broadcast BEFORE any specific parsing
        capturedEvents := this._CaptureEvents(Events.LogLineRead)
        this.svc.ProcessText("some random garbage that matches nothing`n")
        Assert.Equal(1, capturedEvents.Length)
    }

    unknown_line_publishes_no_specific_event()
    {
        levelEvents := this._CaptureEvents(Events.CharacterLevelUp)
        areaEvents  := this._CaptureEvents(Events.AreaLevelChanged)
        sceneEvents := this._CaptureEvents(Events.SceneEntered)
        zoneEvents  := this._CaptureEvents(Events.ZoneChanged)
        deathEvents := this._CaptureEvents(Events.DeathDetected)
        focusEvents := this._CaptureEvents(Events.WindowFocusChanged)

        this.svc.SetCharacterName("Olaf")
        this.svc.ProcessText("This line matches no pattern`n")

        Assert.Equal(0, levelEvents.Length)
        Assert.Equal(0, areaEvents.Length)
        Assert.Equal(0, sceneEvents.Length)
        Assert.Equal(0, zoneEvents.Length)
        Assert.Equal(0, deathEvents.Length)
        Assert.Equal(0, focusEvents.Length)
    }
}

TestRegistry.Register(LogMonitorServiceTests)

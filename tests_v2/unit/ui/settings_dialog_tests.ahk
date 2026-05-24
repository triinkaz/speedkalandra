; ============================================================
; SettingsDialogTests
; ============================================================
;
; Headless tests for the snapshot/restore/persist-and-publish
; pipeline. _OnSave itself reads from this._ctrls (GUI-bound,
; populated only after _BuildGui), so it isn't tested directly
; here; the meat of its responsibility lives in three methods
; that are reachable in headless mode:
;
;   _SnapshotMutableCfg(cfg)        - static, pure
;   _RestoreCfgFromSnapshot(snap)   - instance, mutates this._cfg
;   _PersistAndPublishCfg(cfg,snap) - instance, save + publish/restore
;
; Coverage:
;   - snapshot captures all mutable fields and deep-copies the
;     Array/Map ones (without deep-copy, a later mutation in
;     this._cfg would leak into the snapshot and defeat rollback)
;   - restore overwrites the in-memory cfg from snapshot
;   - PersistAndPublishCfg returns true on success, publishes the
;     diff events vs snapshot
;   - PersistAndPublishCfg returns false on save failure, restores
;     the in-memory cfg from snapshot, and publishes NOTHING
;
; Senior-review note: these tests exist specifically to lock in
; the "no ghost values" contract — services that hold a reference
; to this._cfg must NOT observe values that never landed on disk.

; Helper: SettingsRepository whose Save always throws. Used to
; drive the save-failure branch of _PersistAndPublishCfg without
; setting up an IniFile that fails on a specific call.
class _ThrowingSettingsRepository extends SettingsRepository
{
    Save(cfg)
    {
        throw Error("_ThrowingSettingsRepository: forced save failure")
    }
}

; Helper: RouteRepository whose Save always throws. Used to drive
; the route-save failure branch of _SaveRouteIfWired (warns log,
; surfaces a MsgBox via the SpeedKalandraMsgBox shim, but DOES
; NOT roll back the already-persisted settings). Mirrors the
; _ThrowingSettingsRepository pattern above.
class _ThrowingRouteRepository extends RouteRepository
{
    Save(profileName, routeObj)
    {
        throw Error("_ThrowingRouteRepository: forced route save failure")
    }
}


class SettingsDialogTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Snapshot ---
        "snapshot_captures_all_mutable_fields",
        "snapshot_deep_copies_hotkeys_map",
        "snapshot_deep_copies_vendor_regexes_array",

        ; --- Restore ---
        "restore_overwrites_in_memory_cfg_fields",

        ; --- PersistAndPublishCfg: success path ---
        "persist_and_publish_returns_true_on_success",
        "persist_and_publish_publishes_log_file_change_on_success",
        "persist_and_publish_publishes_hotkeys_change_on_success",
        "persist_and_publish_publishes_vendor_regexes_change_on_success",
        "persist_and_publish_publishes_pb_display_mode_change_on_success",
        "persist_and_publish_publishes_show_outcome_banner_change_on_success",
        "persist_and_publish_no_publish_when_unchanged",

        ; --- PersistAndPublishCfg: failure path ---
        "persist_and_publish_returns_false_on_save_failure",
        "persist_and_publish_restores_in_memory_cfg_on_save_failure",
        "persist_and_publish_does_not_publish_events_on_save_failure",
        "persist_and_publish_warns_log_on_save_failure",

        ; --- Route tab: constructor + wiring ---
        "constructor_accepts_route_deps_when_all_three_wired",
        "constructor_does_not_throw_without_route_deps",
        "constructor_throws_on_invalid_routeRepo_type",
        "constructor_throws_on_invalid_routeService_type",
        "constructor_throws_on_invalid_zonesCatalog_type",
        "has_route_wiring_true_when_all_three_wired",
        "has_route_wiring_false_when_routeRepo_missing",

        ; --- Route tab: load + buffer mutation ---
        "open_loads_route_zones_from_repo",
        "open_leaves_buffer_empty_when_route_deps_missing",
        "move_up_swaps_with_above",
        "move_up_no_op_at_top",
        "move_down_swaps_with_below",
        "move_down_no_op_at_bottom",
        "remove_drops_selected_zone",
        "add_appends_zone_to_buffer",
        "add_ignores_empty_zone_name",

        ; --- Route tab: persistence ---
        "save_persists_route_zones_to_repo",
        "save_calls_routeService_Refresh",
        "save_route_failure_warns_log_but_does_not_throw",

        ; --- Route tab: helpers ---
        "clamp_rows_enforces_3_to_10_bounds",
        "non_town_zone_names_filters_towns_from_catalog",
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _MakeDialog()
    {
        ; Standard fixture: headless dialog with a real INI repo
        ; and an InMemoryLogger. Returns a handle bag so tests
        ; don't have to redeclare every dependency.
        bus     := Fixtures.MakeBus()
        iniPath := Fixtures.TempPath("ini")
        ini     := IniFile(iniPath)
        repo    := SettingsRepository(ini)
        cfg     := AppSettings.Defaults()
        memLog  := InMemoryLogger()
        dialog  := SettingsDialog(bus, repo, cfg, true, memLog)   ; headless=true
        return {
            dialog:  dialog,
            bus:     bus,
            cfg:     cfg,
            repo:    repo,
            memLog:  memLog,
            iniPath: iniPath
        }
    }

    _MakeDialogWithThrowingRepo()
    {
        bus     := Fixtures.MakeBus()
        iniPath := Fixtures.TempPath("ini")
        ini     := IniFile(iniPath)
        repo    := _ThrowingSettingsRepository(ini)
        cfg     := AppSettings.Defaults()
        memLog  := InMemoryLogger()
        dialog  := SettingsDialog(bus, repo, cfg, true, memLog)
        return {
            dialog:  dialog,
            bus:     bus,
            cfg:     cfg,
            repo:    repo,
            memLog:  memLog,
            iniPath: iniPath
        }
    }

    ; Route fixture. Builds a SettingsDialog with all three route
    ; dependencies wired against real (tempdir-backed) repositories
    ; and a small ZonesCatalog built from a temp CSV. `initialZones`
    ; is an optional Array<String> seeded into the repo before the
    ; dialog is constructed — useful for testing Open()'s load path.
    ; `throwingRouteRepo` swaps in _ThrowingRouteRepository instead
    ; of the real one so save-failure paths can be exercised.
    ;
    ; The CSV has 4 non-town zones and 1 town so the
    ; non-town-filter test has something to discriminate against.
    _MakeDialogWithRoute(initialZones := "", throwingRouteRepo := false)
    {
        bus          := Fixtures.MakeBus()
        iniPath      := Fixtures.TempPath("ini")
        ini          := IniFile(iniPath)
        settingsRepo := SettingsRepository(ini)
        cfg          := AppSettings.Defaults()
        memLog       := InMemoryLogger()

        routesDir := Fixtures.TempDir()
        routeRepo := throwingRouteRepo
                   ? _ThrowingRouteRepository(routesDir)
                   : RouteRepository(routesDir)

        ; Minimal in-tree zones.csv (UTF-8 sem BOM; IniRead's ASCII
        ; fallback handles it for the CSV layer too, since
        ; ZonesCatalog reads via plain FileRead).
        ; Local name `zonesCat` (not `zonesCatalog`) to avoid the
        ; case-collision with the `ZonesCatalog` class on the next
        ; line — same trap documented in CLAUDE.md §3.
        csvContent := "name;internal_id;act;is_town`n"
                    . "The Riverbank;G1_1;1;0`n"
                    . "Mud Burrow;G1_3;1;0`n"
                    . "Hunting Grounds;G1_2;1;0`n"
                    . "Ogham Farmlands;G1_4;1;0`n"
                    . "Clearfell Encampment;G1_town;1;1`n"
        csvPath := Fixtures.TempFile(csvContent, "csv")
        zonesCat := ZonesCatalog(csvPath)

        ; Same case-collision reason — `svc` short form for the
        ; service local since `routeService`/`RouteService` collide.
        svc := RouteService(bus, routeRepo)

        ; Optional seed: if the caller wanted an initial route on
        ; disk, persist it BEFORE constructing the dialog so
        ; Open()'s _LoadRouteZonesFromRepo finds it. Skip the seed
        ; when the throwing-repo variant is in use — the .Save
        ; would throw and the fixture would be unusable.
        if (!throwingRouteRepo
            && initialZones is Array
            && initialZones.Length > 0)
        {
            try routeRepo.Save(cfg.profileName, Route(initialZones))
        }

        ; Hydrate the service with the active profile, mimicking the
        ; boot sequence in app.ahk. RouteService.Refresh() is a no-op
        ; until _currentProfile is set, so the save_calls_routeService_Refresh
        ; test requires this priming step.
        try svc.LoadRouteForProfile(cfg.profileName)

        dialog := SettingsDialog(
            bus, settingsRepo, cfg, true, memLog,
            routeRepo, svc, zonesCat)

        ; Return-bag keys keep the long names (`routeService` /
        ; `zonesCatalog`) for readability at the call sites —
        ; property access is case-insensitive and doesn't share the
        ; local-variable shadowing trap.
        return {
            dialog:       dialog,
            bus:          bus,
            cfg:          cfg,
            settingsRepo: settingsRepo,
            memLog:       memLog,
            iniPath:      iniPath,
            routesDir:    routesDir,
            routeRepo:    routeRepo,
            zonesCatalog: zonesCat,
            routeService: svc
        }
    }

    ; ============================================================
    ; Snapshot
    ; ============================================================

    snapshot_captures_all_mutable_fields()
    {
        cfg := AppSettings.Defaults()
        cfg.profileName         := "P"
        cfg.logFile             := "F"
        cfg.autoStartRegex      := "AS"
        cfg.autoFinalizeRegex   := "AF"
        cfg.vendorRegexes       := ["x", "y", "z"]
        cfg.autoPauseOnFocus    := false
        cfg.deathPenaltyEnabled := true
        cfg.deathPenaltyMs      := 12345
        cfg.layoutVariant       := "plus"
        cfg.pbDisplayMode       := "avg5"
        cfg.showOutcomeBanner   := false
        cfg.routeRowsVisible    := 7
        cfg.hotkeys["test"]     := "F1"

        snap := SettingsDialog._SnapshotMutableCfg(cfg)

        Assert.Equal("P",                 snap["profileName"])
        Assert.Equal("F",                 snap["logFile"])
        Assert.Equal("AS",                snap["autoStartRegex"])
        Assert.Equal("AF",                snap["autoFinalizeRegex"])
        Assert.Equal(["x", "y", "z"],     snap["vendorRegexes"])
        Assert.False(snap["autoPauseOnFocus"])
        Assert.True(snap["deathPenaltyEnabled"])
        Assert.Equal(12345,               snap["deathPenaltyMs"])
        Assert.Equal("plus",              snap["layoutVariant"])
        Assert.Equal("avg5",              snap["pbDisplayMode"])
        Assert.False(snap["showOutcomeBanner"],
            "showOutcomeBanner round-trips through snapshot")
        Assert.Equal(7,                   snap["routeRowsVisible"],
            "routeRowsVisible round-trips through snapshot")
        Assert.Equal("F1",                snap["hotkeys"]["test"])
    }

    snapshot_deep_copies_hotkeys_map()
    {
        ; Mutating cfg.hotkeys AFTER snapshotting must NOT reflect
        ; in the snapshot. Without deep-copy, the snapshot would
        ; alias the live Map and a later edit (which IS the normal
        ; path in _OnSave) would corrupt the rollback record.
        cfg := AppSettings.Defaults()
        cfg.hotkeys["k"] := "F1"

        snap := SettingsDialog._SnapshotMutableCfg(cfg)

        cfg.hotkeys["k"]   := "F2"      ; mutation after snapshot
        cfg.hotkeys["new"] := "F3"      ; new key after snapshot

        Assert.Equal("F1", snap["hotkeys"]["k"],
            "snapshot must hold the pre-mutation value")
        Assert.False(snap["hotkeys"].Has("new"),
            "snapshot must NOT see post-snapshot keys")
    }

    snapshot_deep_copies_vendor_regexes_array()
    {
        cfg := AppSettings.Defaults()
        cfg.vendorRegexes := ["a", "b", "c"]

        snap := SettingsDialog._SnapshotMutableCfg(cfg)

        cfg.vendorRegexes[1] := "MUTATED"
        cfg.vendorRegexes.Push("EXTRA")

        Assert.Equal("a", snap["vendorRegexes"][1],
            "snapshot must hold the pre-mutation value")
        Assert.Equal(3, snap["vendorRegexes"].Length,
            "snapshot must NOT see post-snapshot length")
    }

    ; ============================================================
    ; Restore
    ; ============================================================

    restore_overwrites_in_memory_cfg_fields()
    {
        ; Take a snapshot, mutate cfg, call _Restore. Each field
        ; must revert to the snapshot value. The hotkeys + vendor-
        ; regex assertions also pin the "replace, don't merge"
        ; semantic (Map/Array reference replacement, not key-by-key
        ; copy).
        ctx := this._MakeDialog()
        d   := ctx.dialog
        cfg := ctx.cfg

        cfg.profileName         := "orig"
        cfg.logFile             := "orig.txt"
        cfg.vendorRegexes       := ["a", "b", "c"]
        cfg.autoPauseOnFocus    := true
        cfg.deathPenaltyEnabled := false
        cfg.deathPenaltyMs      := 10000
        cfg.layoutVariant       := "classic"
        cfg.pbDisplayMode       := "pb"
        cfg.showOutcomeBanner   := true
        cfg.routeRowsVisible    := 4
        cfg.hotkeys["k"]        := "F1"

        snap := SettingsDialog._SnapshotMutableCfg(cfg)

        ; Mutate everything (including replacing hotkeys with a
        ; completely different Map so we can verify the restore is
        ; a full replacement, not a per-key merge).
        cfg.profileName         := "MUTATED"
        cfg.logFile             := "mutated.txt"
        cfg.vendorRegexes       := ["x", "y", "z"]
        cfg.autoPauseOnFocus    := false
        cfg.deathPenaltyEnabled := true
        cfg.deathPenaltyMs      := 99999
        cfg.layoutVariant       := "plus"
        cfg.pbDisplayMode       := "avg5"
        cfg.showOutcomeBanner   := false
        cfg.routeRowsVisible    := 9
        cfg.hotkeys             := Map("other", "F9")

        d._RestoreCfgFromSnapshot(snap)

        Assert.Equal("orig",              cfg.profileName)
        Assert.Equal("orig.txt",          cfg.logFile)
        Assert.Equal(["a", "b", "c"],     cfg.vendorRegexes)
        Assert.True(cfg.autoPauseOnFocus)
        Assert.False(cfg.deathPenaltyEnabled)
        Assert.Equal(10000,               cfg.deathPenaltyMs)
        Assert.Equal("classic",           cfg.layoutVariant)
        Assert.Equal("pb",                cfg.pbDisplayMode)
        Assert.True(cfg.showOutcomeBanner,
            "showOutcomeBanner restores to pre-mutation value")
        Assert.Equal(4,                   cfg.routeRowsVisible,
            "routeRowsVisible restores to pre-mutation value")
        Assert.Equal("F1",                cfg.hotkeys["k"])
        Assert.False(cfg.hotkeys.Has("other"),
            "restore must replace hotkeys entirely (not merge with post-snapshot keys)")
    }

    ; ============================================================
    ; PersistAndPublishCfg - success path
    ; ============================================================

    persist_and_publish_returns_true_on_success()
    {
        ctx  := this._MakeDialog()
        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        result := ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)
        Assert.True(result, "Save success must return true")
    }

    persist_and_publish_publishes_log_file_change_on_success()
    {
        ctx := this._MakeDialog()
        captured := []
        ctx.bus.Subscribe(Events.LogFilePathChanged,
            (data) => captured.Push(data))

        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        ctx.cfg.logFile := "C:\\new\\path.txt"

        ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)

        Assert.Equal(1, captured.Length,
            "LogFilePathChanged must fire when logFile differs from snapshot")
        Assert.Equal("C:\\new\\path.txt", captured[1]["newPath"])
    }

    persist_and_publish_publishes_hotkeys_change_on_success()
    {
        ctx := this._MakeDialog()
        captured := []
        ctx.bus.Subscribe(Events.HotkeysChanged,
            (data) => captured.Push(data))

        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        ctx.cfg.hotkeys["new_action"] := "F12"

        ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)

        Assert.Equal(1, captured.Length,
            "HotkeysChanged must fire when hotkeys differ from snapshot")
        Assert.Equal("F12", captured[1]["newHotkeys"]["new_action"])
    }

    persist_and_publish_publishes_vendor_regexes_change_on_success()
    {
        ctx := this._MakeDialog()
        captured := []
        ctx.bus.Subscribe(Events.VendorRegexesChanged,
            (data) => captured.Push(data))

        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        ctx.cfg.vendorRegexes := ["fire|cold", "phys", "rare"]

        ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)

        Assert.Equal(1, captured.Length,
            "VendorRegexesChanged must fire when array differs from snapshot")
    }

    persist_and_publish_publishes_pb_display_mode_change_on_success()
    {
        ; Flipping cfg.pbDisplayMode (PB ↔ avg5) must publish
        ; Evt.PbDisplayModeChanged so widgets re-render against
        ; the new source without a restart. Without this, the
        ; checkbox saves to disk but the live overlays keep
        ; showing the old value until a full app reload.
        ctx := this._MakeDialog()
        captured := []
        ctx.bus.Subscribe(Events.PbDisplayModeChanged,
            (data) => captured.Push(data))

        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        ctx.cfg.pbDisplayMode := "avg5"

        ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)

        Assert.Equal(1, captured.Length,
            "PbDisplayModeChanged must fire when the mode differs from snapshot")
        Assert.Equal("pb",   captured[1]["oldMode"])
        Assert.Equal("avg5", captured[1]["newMode"])
    }

    persist_and_publish_publishes_show_outcome_banner_change_on_success()
    {
        ; Flipping cfg.showOutcomeBanner publishes
        ; Evt.ShowOutcomeBannerChanged so the widget can clear
        ; any banner that happens to be on screen the moment the
        ; user turns the feature off. Symmetric to the
        ; PbDisplayModeChanged path right above.
        ctx := this._MakeDialog()
        captured := []
        ctx.bus.Subscribe(Events.ShowOutcomeBannerChanged,
            (data) => captured.Push(data))

        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        ctx.cfg.showOutcomeBanner := false

        ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)

        Assert.Equal(1, captured.Length,
            "ShowOutcomeBannerChanged must fire when the flag differs from snapshot")
        Assert.True(captured[1]["oldValue"])
        Assert.False(captured[1]["newValue"])
    }

    persist_and_publish_no_publish_when_unchanged()
    {
        ; Snapshot == cfg ? no events should fire. Avoids spurious
        ; hot-reloads when the user just opens the dialog and
        ; clicks Save without changing anything.
        ctx := this._MakeDialog()
        capturedLog := []
        capturedHk  := []
        capturedVr  := []
        ctx.bus.Subscribe(Events.LogFilePathChanged,    (data) => capturedLog.Push(data))
        ctx.bus.Subscribe(Events.HotkeysChanged,        (data) => capturedHk.Push(data))
        ctx.bus.Subscribe(Events.VendorRegexesChanged,  (data) => capturedVr.Push(data))

        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        ; deliberately do NOT mutate cfg

        ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)

        Assert.Equal(0, capturedLog.Length, "no logFile diff -> no publish")
        Assert.Equal(0, capturedHk.Length,  "no hotkey diff -> no publish")
        Assert.Equal(0, capturedVr.Length,  "no vendorRegex diff -> no publish")
    }

    ; ============================================================
    ; PersistAndPublishCfg - failure path
    ; ============================================================

    persist_and_publish_returns_false_on_save_failure()
    {
        ctx  := this._MakeDialogWithThrowingRepo()
        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        result := ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)
        Assert.False(result, "Save failure must return false")
    }

    persist_and_publish_restores_in_memory_cfg_on_save_failure()
    {
        ; Save throws -> cfg fields must revert to the snapshot
        ; values. This is the contract that makes the MsgBox
        ; "in-memory state restored" promise honest. Without it,
        ; services holding a reference to this._cfg would observe
        ; ghost values that never landed on disk.
        ctx := this._MakeDialogWithThrowingRepo()
        ctx.cfg.profileName     := "OriginalProfile"
        ctx.cfg.hotkeys["foo"]  := "F1"
        ctx.cfg.vendorRegexes   := ["original", "", ""]

        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)

        ; Mutate to "new" values that should be rolled back.
        ctx.cfg.profileName        := "MutatedProfile"
        ctx.cfg.hotkeys["foo"]     := "F2"
        ctx.cfg.hotkeys["new_key"] := "F3"
        ctx.cfg.vendorRegexes      := ["mutated", "", ""]

        ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)

        Assert.Equal("OriginalProfile", ctx.cfg.profileName,
            "profileName must roll back on save failure")
        Assert.Equal("F1", ctx.cfg.hotkeys["foo"],
            "hotkeys[foo] must roll back to pre-mutation value")
        Assert.False(ctx.cfg.hotkeys.Has("new_key"),
            "hotkeys[new_key] (added after snapshot) must be gone after restore")
        Assert.Equal("original", ctx.cfg.vendorRegexes[1],
            "vendorRegexes must roll back to pre-mutation values")
    }

    persist_and_publish_does_not_publish_events_on_save_failure()
    {
        ; The big contract: failure must NOT publish change events.
        ; Services downstream (LogMonitor, HotkeyService,
        ; CompactLayoutWidget) would otherwise hot-reload based on
        ; values that never landed on disk and stay out of sync
        ; with the eventual recovery.
        ctx := this._MakeDialogWithThrowingRepo()
        capturedLog := []
        capturedHk  := []
        capturedVr  := []
        ctx.bus.Subscribe(Events.LogFilePathChanged,   (data) => capturedLog.Push(data))
        ctx.bus.Subscribe(Events.HotkeysChanged,       (data) => capturedHk.Push(data))
        ctx.bus.Subscribe(Events.VendorRegexesChanged, (data) => capturedVr.Push(data))

        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        ctx.cfg.logFile            := "C:\\new.txt"
        ctx.cfg.hotkeys["test"]    := "F9"
        ctx.cfg.vendorRegexes      := ["x", "y", "z"]

        ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)

        Assert.Equal(0, capturedLog.Length, "no LogFilePathChanged on save failure")
        Assert.Equal(0, capturedHk.Length,  "no HotkeysChanged on save failure")
        Assert.Equal(0, capturedVr.Length,  "no VendorRegexesChanged on save failure")
    }

    persist_and_publish_warns_log_on_save_failure()
    {
        ctx  := this._MakeDialogWithThrowingRepo()
        snap := SettingsDialog._SnapshotMutableCfg(ctx.cfg)
        ctx.dialog._PersistAndPublishCfg(ctx.cfg, snap)
        Assert.True(ctx.memLog.HasEntry("WARN", "Settings save failed"),
            "save failure must be logged at WARN level for diagnostics")
    }

    ; ============================================================
    ; Route tab - constructor + wiring
    ; ============================================================
    ;
    ; The three route deps (routeRepo, routeService, zonesCatalog)
    ; are ctor-optional so legacy/headless setups that don't care
    ; about the route surface keep working. When provided they're
    ; type-validated; missing any one disables the ROUTE section
    ; (via _HasRouteWiring) but doesn't break the dialog.

    constructor_accepts_route_deps_when_all_three_wired()
    {
        ; Just constructing the fixture exercises the validated
        ; path. If any of the `is X` checks rejected the real
        ; objects, the helper would throw before returning.
        ctx := this._MakeDialogWithRoute()
        Assert.True(ctx.dialog is SettingsDialog,
            "dialog must construct cleanly with all three route deps")
    }

    constructor_does_not_throw_without_route_deps()
    {
        ; Back-compat: callers built before the route feature pass
        ; only the 5 original args. The new params have defaults
        ; ("") and skip type validation, so the legacy ctor call
        ; must still work.
        ctx := this._MakeDialog()
        Assert.True(ctx.dialog is SettingsDialog,
            "5-arg ctor must remain valid for legacy call sites")
    }

    constructor_throws_on_invalid_routeRepo_type()
    {
        bus     := Fixtures.MakeBus()
        iniPath := Fixtures.TempPath("ini")
        repo    := SettingsRepository(IniFile(iniPath))
        cfg     := AppSettings.Defaults()
        threw   := false
        try
        {
            ; routeRepo is a plain Map — wrong type.
            SettingsDialog(bus, repo, cfg, true, NullLogger(),
                Map(), "", "")
        }
        catch TypeError
            threw := true
        Assert.True(threw,
            "non-RouteRepository value for routeRepo must throw TypeError")
    }

    constructor_throws_on_invalid_routeService_type()
    {
        bus       := Fixtures.MakeBus()
        iniPath   := Fixtures.TempPath("ini")
        repo      := SettingsRepository(IniFile(iniPath))
        cfg       := AppSettings.Defaults()
        routesDir := Fixtures.TempDir()
        routeRepo := RouteRepository(routesDir)
        threw := false
        try
        {
            SettingsDialog(bus, repo, cfg, true, NullLogger(),
                routeRepo, Map(), "")
        }
        catch TypeError
            threw := true
        Assert.True(threw,
            "non-RouteService value for routeService must throw TypeError")
    }

    constructor_throws_on_invalid_zonesCatalog_type()
    {
        bus       := Fixtures.MakeBus()
        iniPath   := Fixtures.TempPath("ini")
        repo      := SettingsRepository(IniFile(iniPath))
        cfg       := AppSettings.Defaults()
        routesDir := Fixtures.TempDir()
        routeRepo := RouteRepository(routesDir)
        routeSvc  := RouteService(bus, routeRepo)
        threw := false
        try
        {
            SettingsDialog(bus, repo, cfg, true, NullLogger(),
                routeRepo, routeSvc, Map())
        }
        catch TypeError
            threw := true
        Assert.True(threw,
            "non-ZonesCatalog value for zonesCatalog must throw TypeError")
    }

    has_route_wiring_true_when_all_three_wired()
    {
        ctx := this._MakeDialogWithRoute()
        Assert.True(ctx.dialog._HasRouteWiring(),
            "_HasRouteWiring must be true when all three deps are wired")
    }

    has_route_wiring_false_when_routeRepo_missing()
    {
        ; A dialog built with the 5-arg ctor has no route deps and
        ; must report HasRouteWiring=false. Symmetric tests for
        ; routeService/zonesCatalog missing would just exercise
        ; the same `IsObject(...)` chain — one negative case is
        ; enough to lock the all-or-nothing contract.
        ctx := this._MakeDialog()
        Assert.False(ctx.dialog._HasRouteWiring(),
            "_HasRouteWiring must be false when any dep is missing")
    }

    ; ============================================================
    ; Route tab - load + buffer mutation
    ; ============================================================

    open_loads_route_zones_from_repo()
    {
        ; Seed a route on disk for the default profile, then open
        ; the dialog (headless). The Open() handler calls
        ; _LoadRouteZonesFromRepo which must populate _routeZones
        ; from the persisted INI.
        seed := ["The Riverbank", "Mud Burrow", "Hunting Grounds"]
        ctx  := this._MakeDialogWithRoute(seed)
        ctx.dialog.Open()
        Assert.Equal(3, ctx.dialog._routeZones.Length,
            "Open must hydrate the buffer from the seeded route")
        Assert.Equal("The Riverbank",  ctx.dialog._routeZones[1])
        Assert.Equal("Mud Burrow",     ctx.dialog._routeZones[2])
        Assert.Equal("Hunting Grounds", ctx.dialog._routeZones[3])
    }

    open_leaves_buffer_empty_when_route_deps_missing()
    {
        ; Without route deps wired, _LoadRouteZonesFromRepo bails
        ; before touching the buffer — it stays at the ctor's
        ; empty default. Guarantees legacy ctor sites observe no
        ; surprise state change.
        ctx := this._MakeDialog()
        ctx.dialog.Open()
        Assert.Equal(0, ctx.dialog._routeZones.Length,
            "buffer must remain empty when route deps are missing")
    }

    move_up_swaps_with_above()
    {
        ctx := this._MakeDialogWithRoute(["A", "B", "C"])
        ctx.dialog.Open()
        ctx.dialog._OnRouteMoveUp(2)    ; move B up
        Assert.Equal("B", ctx.dialog._routeZones[1])
        Assert.Equal("A", ctx.dialog._routeZones[2])
        Assert.Equal("C", ctx.dialog._routeZones[3])
    }

    move_up_no_op_at_top()
    {
        ctx := this._MakeDialogWithRoute(["A", "B", "C"])
        ctx.dialog.Open()
        ctx.dialog._OnRouteMoveUp(1)    ; already at top — no-op
        Assert.Equal("A", ctx.dialog._routeZones[1])
        Assert.Equal("B", ctx.dialog._routeZones[2])
        Assert.Equal("C", ctx.dialog._routeZones[3])
    }

    move_down_swaps_with_below()
    {
        ctx := this._MakeDialogWithRoute(["A", "B", "C"])
        ctx.dialog.Open()
        ctx.dialog._OnRouteMoveDown(2)  ; move B down
        Assert.Equal("A", ctx.dialog._routeZones[1])
        Assert.Equal("C", ctx.dialog._routeZones[2])
        Assert.Equal("B", ctx.dialog._routeZones[3])
    }

    move_down_no_op_at_bottom()
    {
        ctx := this._MakeDialogWithRoute(["A", "B", "C"])
        ctx.dialog.Open()
        ctx.dialog._OnRouteMoveDown(3)  ; already at bottom — no-op
        Assert.Equal("A", ctx.dialog._routeZones[1])
        Assert.Equal("B", ctx.dialog._routeZones[2])
        Assert.Equal("C", ctx.dialog._routeZones[3])
    }

    remove_drops_selected_zone()
    {
        ctx := this._MakeDialogWithRoute(["A", "B", "C"])
        ctx.dialog.Open()
        ctx.dialog._OnRouteRemove(2)    ; drop B
        Assert.Equal(2, ctx.dialog._routeZones.Length)
        Assert.Equal("A", ctx.dialog._routeZones[1])
        Assert.Equal("C", ctx.dialog._routeZones[2])
    }

    add_appends_zone_to_buffer()
    {
        ctx := this._MakeDialogWithRoute(["A", "B"])
        ctx.dialog.Open()
        ctx.dialog._OnRouteAdd("The Riverbank")
        Assert.Equal(3, ctx.dialog._routeZones.Length)
        Assert.Equal("The Riverbank", ctx.dialog._routeZones[3],
            "Add must push the zone to the END of the buffer")
    }

    add_ignores_empty_zone_name()
    {
        ; Whitespace-only names hit the explicit Trim() guard in
        ; _OnRouteAdd. (An empty-string override would also be
        ; ignored, but only because it routes to the dropdown
        ; branch, which is absent in headless — testing that path
        ; would prove dropdown-absence handling, not Trim-empty
        ; rejection. Whitespace-only is the cleaner signal.)
        ctx := this._MakeDialogWithRoute(["A", "B"])
        ctx.dialog.Open()
        ctx.dialog._OnRouteAdd("   ")
        ctx.dialog._OnRouteAdd("`t  `t")
        Assert.Equal(2, ctx.dialog._routeZones.Length,
            "whitespace-only zone names must be ignored")
    }

    ; ============================================================
    ; Route tab - persistence
    ; ============================================================

    save_persists_route_zones_to_repo()
    {
        ; Open with an initial route, mutate the buffer, fire
        ; _SaveRouteIfWired, then reload from disk through a fresh
        ; RouteRepository read to confirm the persisted zones match
        ; the in-memory buffer (i.e. the save is a full overwrite,
        ; not an incremental append).
        ctx := this._MakeDialogWithRoute(["A", "B", "C"])
        ctx.dialog.Open()

        ; Mutate the buffer through the same handlers a user would
        ; drive via the GUI.
        ctx.dialog._OnRouteMoveDown(1)         ; A <-> B
        ctx.dialog._OnRouteRemove(3)           ; drop the now-last
        ctx.dialog._OnRouteAdd("Mud Burrow")   ; append a fresh zone
        ; Buffer should now be: B, A, Mud Burrow

        ctx.dialog._SaveRouteIfWired()

        ; Re-load from disk to confirm persistence.
        loaded := ctx.routeRepo.Load(ctx.cfg.profileName)
        zones  := loaded.GetZones()
        Assert.Equal(3, zones.Length)
        Assert.Equal("B",          zones[1])
        Assert.Equal("A",          zones[2])
        Assert.Equal("Mud Burrow", zones[3])
    }

    save_calls_routeService_Refresh()
    {
        ; routeService.Refresh publishes Evt.RouteChanged so the
        ; live RouteWidget re-renders against both the new zone
        ; list AND the new cfg.routeRowsVisible. A successful
        ; _SaveRouteIfWired must reach Refresh exactly once.
        ctx := this._MakeDialogWithRoute(["A"])
        ctx.dialog.Open()
        captured := []
        ctx.bus.Subscribe(Events.RouteChanged,
            (data) => captured.Push(data))
        ctx.dialog._SaveRouteIfWired()
        Assert.Equal(1, captured.Length,
            "_SaveRouteIfWired must publish exactly one RouteChanged event")
    }

    save_route_failure_warns_log_but_does_not_throw()
    {
        ; When routeRepo.Save throws, _SaveRouteIfWired catches it,
        ; logs a WARN with the exception message, and returns
        ; cleanly. The dialog must NOT propagate — the
        ; _PersistAndPublishCfg flow has already saved settings and
        ; needs to reach Close() regardless.
        ctx := this._MakeDialogWithRoute("", true)    ; throwing repo
        ctx.dialog.Open()
        ctx.dialog._routeZones := ["will fail to save"]
        threw := false
        try ctx.dialog._SaveRouteIfWired()
        catch
            threw := true
        Assert.False(threw,
            "route save failure must NOT propagate out of _SaveRouteIfWired")
        Assert.True(ctx.memLog.HasEntry("WARN", "Route save failed"),
            "route save failure must be logged at WARN level")
    }

    ; ============================================================
    ; Route tab - helpers
    ; ============================================================

    clamp_rows_enforces_3_to_10_bounds()
    {
        ctx := this._MakeDialogWithRoute()
        d   := ctx.dialog
        Assert.Equal(3,  d._ClampRows(1),   "below-range clamps up to 3")
        Assert.Equal(3,  d._ClampRows(3),   "lower bound is inclusive")
        Assert.Equal(5,  d._ClampRows(5),   "in-range passes through")
        Assert.Equal(10, d._ClampRows(10),  "upper bound is inclusive")
        Assert.Equal(10, d._ClampRows(99),  "above-range clamps down to 10")
    }

    non_town_zone_names_filters_towns_from_catalog()
    {
        ; The fixture CSV has 4 non-town zones + 1 town (Clearfell
        ; Encampment). _BuildNonTownZoneNames must return only the
        ; 4 non-town names, alphabetically sorted (matching the
        ; existing _SortArray pass), with the town excluded.
        ctx := this._MakeDialogWithRoute()
        names := ctx.dialog._BuildNonTownZoneNames()
        Assert.Equal(4, names.Length,
            "only the 4 non-town zones must be returned")
        ; Sorted alphabetically: H, M, O, T (Hunting, Mud, Ogham, Riverbank)
        Assert.Equal("Hunting Grounds", names[1])
        Assert.Equal("Mud Burrow",      names[2])
        Assert.Equal("Ogham Farmlands", names[3])
        Assert.Equal("The Riverbank",   names[4])
        ; And the town must NOT appear anywhere in the result.
        for _, n in names
        {
            Assert.NotEqual("Clearfell Encampment", n,
                "towns must be filtered out of the dropdown list")
        }
    }
}

TestRegistry.Register(SettingsDialogTests)

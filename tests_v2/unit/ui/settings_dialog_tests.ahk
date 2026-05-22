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
        "persist_and_publish_no_publish_when_unchanged",

        ; --- PersistAndPublishCfg: failure path ---
        "persist_and_publish_returns_false_on_save_failure",
        "persist_and_publish_restores_in_memory_cfg_on_save_failure",
        "persist_and_publish_does_not_publish_events_on_save_failure",
        "persist_and_publish_warns_log_on_save_failure",
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
}

TestRegistry.Register(SettingsDialogTests)

; ============================================================
; B1CruelPipelineIntegrationTests
; ============================================================
;
; End-to-end integration test for the cruel/interlude tracking
; pipeline introduced in BACKLOG B1. The narrower commit-level
; unit tests already cover each layer in isolation:
;
;   Commit 1 - log_monitor_service_tests:
;       cruel area-gen line publishes ZoneChanged with
;       stage="interlude".
;   Commit 2 - zone_tracking_service_tests + act_checkpoint_
;       tracker_tests: stage propagates from ZoneChanged to
;       ZoneEntered, then to per-(act, stage) checkpoints.
;   Commit 3 - personal_best_service_tests +
;       personal_best_repository_tests + run_history_repository_
;       tests: per-(act, stage) PB persistence + INI round-trip.
;
; What this file adds is the wiring proof: the same Client.txt
; line that produces a cruel transition in production lands on
; the PersonalBestService and RunHistoryRepository with the right
; composite keys, going through the real SpeedKalandraApp
; composition root. A regression that breaks any of the splice
; points (LogMonitor publishes the wrong shape, ZoneTracker
; drops the stage field, RunSnapshotSaver still calls the
; legacy integer-keyed GetCheckpoints, etc.) trips here even if
; every isolated unit test still passes.
;
; The fixture mirrors SpeedKalandraAppIntegrationTests but seeds
; an extra Act-2 zone so the act-transition path is exercised
; alongside the cruel-stage transition. Two transitions in the
; same run lets the checkpoint capture fire twice with
; different (act, stage) tuples.


class B1CruelPipelineIntegrationTests extends TestCase
{
    tmpDir        := ""
    iniPath       := ""
    zonesCsvPath  := ""
    logPath       := ""
    runHistoryDir := ""
    pbPath        := ""
    deathLogPath  := ""
    routesDir     := ""
    stubClock     := ""
    app           := ""

    Setup()
    {
        this.tmpDir        := Fixtures.TempDir()
        this.iniPath       := this.tmpDir "\settings.ini"
        this.zonesCsvPath  := this.tmpDir "\zones.csv"
        this.logPath       := this.tmpDir "\app.log"
        this.runHistoryDir := this.tmpDir "\runs"
        this.pbPath        := this.tmpDir "\pb.ini"
        this.deathLogPath  := this.tmpDir "\deaths.csv"
        this.routesDir     := this.tmpDir "\routes"

        ; Catalog with Act 1 + Act 2 zones. The cruel pipeline
        ; reuses the SAME catalog entries — cruel ZoneChanged
        ; emits the base human name (LogMonitor strips the C_
        ; prefix before resolving via the catalog), so no
        ; "C_*" rows are needed here.
        FileAppend(
            "name;internal_id;act;is_town`n"
            . "Clearfell Encampment;G1_town;1;1`n"
            . "Mud Burrow;G1_3;1;0`n"
            . "The Ardura Caravan;G2_town;2;1`n"
            . "Vastiri Outskirts;G2_1;2;0`n",
            this.zonesCsvPath, "UTF-8")

        Fixtures.RegisterTempPath(this.zonesCsvPath)
        Fixtures.RegisterTempPath(this.iniPath)
        Fixtures.RegisterTempPath(this.logPath)
        Fixtures.RegisterTempPath(this.pbPath)
        Fixtures.RegisterTempPath(this.deathLogPath)

        try DirCreate(this.runHistoryDir)
        Fixtures.RegisterTempPath(this.runHistoryDir)
        Fixtures.RegisterTempPath(this.routesDir)

        this.stubClock := Fixtures.MakeFakeClock(1000000)

        this.app := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "deathLogPath",     this.deathLogPath,
            "routesDir",        this.routesDir,
            "headless",         true,
            "clock",            this.stubClock
        ))
    }

    Teardown()
    {
        if IsObject(this.app)
            try this.app.Stop()
        Fixtures.CleanupAll()
    }

    static Tests := [
        "cruel_area_gen_line_publishes_zone_changed_with_interlude_stage",
        "normal_then_cruel_transitions_capture_independent_per_act_stage_checkpoints",
        "finalize_persists_stage_aware_pb_and_history"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    ; Captures every ZoneChanged published on the app's bus into
    ; an array, for asserting the LogMonitor-published shape
    ; without going through the consumers that immediately
    ; consume + transform it (zoneTracker -> ZoneEntered).
    _SubscribeZoneChangedCapture()
    {
        captured := []
        this.app.bus.Subscribe(Events.ZoneChanged, (data) => captured.Push(data))
        return captured
    }

    ; Captures every ZoneEntered (the post-ZoneTracker enriched
    ; event). The integration check is that `stage` survives the
    ; ZoneTracker re-publish — pre-B1 the field didn't exist;
    ; Commit 2 added the propagation.
    _SubscribeZoneEnteredCapture()
    {
        captured := []
        this.app.bus.Subscribe(Events.ZoneEntered, (data) => captured.Push(data))
        return captured
    }

    ; ============================================================
    ; Tests
    ; ============================================================

    cruel_area_gen_line_publishes_zone_changed_with_interlude_stage()
    {
        ; Narrowest integration check: the cruel area-gen line
        ; flowing through the REAL LogMonitor (with the real
        ; catalog, the real bus, the real ZoneTrackingService)
        ; ends up as a ZoneEntered with stage="interlude" AND
        ; the canonical human name. A regression on any of:
        ;   - LogMonitor's CRUEL_PREFIX detection
        ;   - the C_-strip-then-resolve order in _ResolveZoneToHumanName
        ;   - ZoneTracker forwarding stage on the outgoing event
        ; will fail here.
        zoneChangedCapture := this._SubscribeZoneChangedCapture()
        zoneEnteredCapture := this._SubscribeZoneEnteredCapture()

        ; Real cruel line as PoE2 writes it (empirically verified
        ; against debug/Client.txt; see LogMonitorService header).
        this.app.logMonitor.ProcessText(
            'Generating level 51 area "C_G1_3" with seed 123456789`n')

        ; AreaLevelChanged + ZoneChanged from the cruel branch.
        ; ZoneChanged is the one we care about here; the
        ; AreaLevelChanged side-effect is covered by log_monitor
        ; unit tests.
        Assert.Equal(1, zoneChangedCapture.Length,
            "exactly one ZoneChanged for the cruel area-gen")
        published := zoneChangedCapture[1]
        Assert.Equal("Mud Burrow", published["zoneName"],
            "C_G1_3 resolves to the catalog's human name (C_ stripped, "
            . "G1_3 looked up by internal_id)")
        Assert.Equal("C_G1_3", published["sceneId"],
            "sceneId carries the raw cruel code for diagnostic / catalog "
            . "round-trip; the human name went into zoneName instead")
        Assert.Equal("interlude", published["stage"],
            "ZoneChanged.stage flags the cruel ladder so downstream "
            . "subscribers can route to per-(act, stage) buckets")

        ; ZoneTracker forwards the stage on the enriched event.
        Assert.Equal(1, zoneEnteredCapture.Length,
            "ZoneTracker re-published exactly one ZoneEntered for the cruel zone")
        enriched := zoneEnteredCapture[1]
        Assert.Equal("interlude", enriched["stage"],
            "ZoneTracker preserves stage on the outgoing ZoneEntered "
            . "(pre-B1 the field didn't exist; Commit 2 added the propagation)")
        Assert.Equal(1, enriched["actIndex"],
            "act is derived from the catalog entry, not from the C_ prefix")
        Assert.False(enriched["isTown"],
            "Mud Burrow is a map, not a town — catalog metadata "
            . "survives the stage tagging")
    }

    normal_then_cruel_transitions_capture_independent_per_act_stage_checkpoints()
    {
        ; Two transitions in the same run, with different (act,
        ; stage) tuples. The ActCheckpointTracker must produce
        ; two distinct composite-key entries:
        ;   "1|normal"    captured at the act 1 → act 2 boundary
        ;   "2|normal"    captured at the act 2 → cruel-1 boundary
        ; Plus a third on finalize for the active (1, interlude)
        ; bucket. The pre-B1 single-axis tracker would have
        ; overwritten "1" with whichever transition fired last.
        this.app.bus.Publish(Commands.NewRunRequested, Map())

        ; --- Normal Act 1: 60 s in Mud Burrow ---
        this.app.logMonitor.ProcessText("[SCENE] Set Source [G1_3]`n")
        this.stubClock.AdvanceMs(60000)

        ; --- Normal Act 2: 90 s in Vastiri Outskirts ---
        ; The transition fires the first checkpoint capture
        ; (act 1, normal → act 2, normal) with runMs = 60000.
        this.app.logMonitor.ProcessText("[SCENE] Set Source [G2_1]`n")
        this.stubClock.AdvanceMs(90000)

        ; --- Cruel Act 1: enter Mud Burrow via the cruel area-gen.
        ; The transition fires the second checkpoint capture
        ; (act 2, normal → act 1, interlude) with runMs = 150000.
        this.app.logMonitor.ProcessText(
            'Generating level 51 area "C_G1_3" with seed 987654321`n')
        this.stubClock.AdvanceMs(120000)

        ; Pre-finalize check: capture the in-memory state of the
        ; tracker. The "1|interlude" bucket hasn't been written
        ; yet — that happens on the final CaptureCurrentAsCheckpoint
        ; inside RunSnapshotSaver.
        midRun := this.app.actCheckpoints.GetCheckpointsByStage()
        Assert.True(midRun.Has("1|normal"),
            "first transition captured '1|normal'")
        Assert.Equal(60000, midRun["1|normal"],
            "act 1 normal bucket carries the time spent before "
            . "the act 1 → act 2 transition")
        Assert.True(midRun.Has("2|normal"),
            "second transition captured '2|normal'")
        Assert.Equal(150000, midRun["2|normal"],
            "act 2 normal bucket carries the cumulative runMs at "
            . "the act 2 → cruel-1 transition (60 + 90)")
        Assert.False(midRun.Has("1|interlude"),
            "cruel act 1 bucket is still active in memory; not "
            . "captured until finalize")

        ; Sanity: the tracker's current pointer is on (1, interlude).
        Assert.Equal(1,           this.app.actCheckpoints.GetCurrentAct())
        Assert.Equal("interlude", this.app.actCheckpoints.GetCurrentStage())
    }

    finalize_persists_stage_aware_pb_and_history()
    {
        ; Full end-to-end: same scenario as the previous test,
        ; but finalize the run and assert that BOTH the PB
        ; service (in-memory + INI) AND the run history INI
        ; carry composite-keyed actCheckpoints. The
        ; "1|interlude" bucket — active at finalize — is the
        ; one that pre-B1 silently overwrote normal "1" in the
        ; legacy integer-keyed map.
        this.app.bus.Publish(Commands.NewRunRequested, Map())

        ; --- Normal Act 1: 60 s ---
        this.app.logMonitor.ProcessText("[SCENE] Set Source [G1_3]`n")
        this.stubClock.AdvanceMs(60000)

        ; --- Normal Act 2: 90 s (captures 1|normal = 60000) ---
        this.app.logMonitor.ProcessText("[SCENE] Set Source [G2_1]`n")
        this.stubClock.AdvanceMs(90000)

        ; --- Cruel Act 1: 120 s (captures 2|normal = 150000) ---
        this.app.logMonitor.ProcessText(
            'Generating level 51 area "C_G1_3" with seed 987654321`n')
        this.stubClock.AdvanceMs(120000)

        ; Total runMs at finalize = 270000 (well above 3 min).
        producedRunId := this.app.runService.GetRunId()
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        ; ---- In-memory PB Service ----
        ; Three buckets, all positive: the pre-B1 bug (single
        ; integer-keyed map) would have shown ONE entry under
        ; key 1, overwriting between the normal and cruel
        ; captures.
        Assert.Equal(60000, this.app.personalBest.GetRunPbForActStage(1, "normal"),
            "Act 1 normal PB matches the time captured at the act 1 → 2 boundary")
        Assert.Equal(150000, this.app.personalBest.GetRunPbForActStage(2, "normal"),
            "Act 2 normal PB matches the time captured at the act 2 → cruel-1 boundary")
        Assert.Equal(270000, this.app.personalBest.GetRunPbForActStage(1, "interlude"),
            "Cruel Act 1 PB matches the finalize-time capture "
            . "(active bucket at finalize, the one pre-B1 would have lost)")

        ; The legacy view (GetRunPbForAct(N)) projects only the
        ; normal-stage entries — Commit 3's backward-compat
        ; contract. A consumer that hasn't migrated still sees
        ; the same Act 1 PB it would have seen pre-B1 (no cruel
        ; data leaking into the campaign timing).
        Assert.Equal(60000,  this.app.personalBest.GetRunPbForAct(1),
            "legacy GetRunPbForAct(1) projects the normal-stage bucket")
        Assert.Equal(150000, this.app.personalBest.GetRunPbForAct(2),
            "legacy GetRunPbForAct(2) projects the normal-stage bucket")

        ; ---- PB INI round-trip ----
        ; A fresh repo reads the same file the service just
        ; wrote on persist. Confirms the new schema
        ; (Act<N>NormalMs / Act<N>InterludeMs) survives the
        ; in-memory → disk → in-memory cycle.
        freshPbRepo := PersonalBestRepository(this.pbPath)
        loadedPb := freshPbRepo.Load()
        Assert.True(loadedPb.Has("runPbByActStage"),
            "PB INI Load surfaces the composite-keyed bucket")
        byStage := loadedPb["runPbByActStage"]
        Assert.Equal(60000,  byStage["1|normal"])
        Assert.Equal(150000, byStage["2|normal"])
        Assert.Equal(270000, byStage["1|interlude"])

        ; ---- Run history INI round-trip ----
        ; [checkpoints] section serialized with the post-B1
        ; schema (Act<N>NormalMs / Act<N>InterludeMs) and loaded
        ; back as the canonical composite-keyed Map.
        loadedRun := this.app.runHistory.Load(producedRunId)
        Assert.True(IsObject(loadedRun),
            "history INI loads back successfully")
        ckpts := loadedRun["actCheckpoints"]
        Assert.True(ckpts.Has("1|normal"),
            "history carries the act 1 normal checkpoint")
        Assert.Equal(60000, ckpts["1|normal"])
        Assert.True(ckpts.Has("2|normal"),
            "history carries the act 2 normal checkpoint")
        Assert.Equal(150000, ckpts["2|normal"])
        Assert.True(ckpts.Has("1|interlude"),
            "history carries the cruel act 1 checkpoint — the bucket "
            . "that pre-B1 would have overwritten the normal entry under "
            . "the legacy integer-keyed schema")
        Assert.Equal(270000, ckpts["1|interlude"])
    }
}

TestRegistry.Register(B1CruelPipelineIntegrationTests)

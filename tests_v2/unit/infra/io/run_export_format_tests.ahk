; ============================================================
; RunExportFormat tests
; ============================================================
;
; Schema v1 for export/import of runs:
;   - Serialize(runs, pbData, options) -> JSON-ready Map
;   - ValidateSchema(parsed)           -> Map{valid, errors, warnings}
;   - Deserialize(parsed)              -> Map{runs, personalBests, meta}
;
; Most asserts check structural properties of the schema (required
; fields, Map<int> <-> Map<str> conversion on actCheckpoints keys,
; profile anonymization).
;
; Roundtrip tests cover the full path:
;   Serialize -> Stringify -> Parse -> ValidateSchema -> Deserialize
;
; Local helper: _MakeRun() builds a valid buildResult for reuse.

class RunExportFormatTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Serialize: basic schema ---
        "serialize_includes_schema_version",
        "serialize_includes_exported_at",
        "serialize_includes_exported_by_with_version",
        "serialize_anonymized_flag_defaults_false",
        "serialize_throws_when_runs_not_array",
        "serialize_skips_non_object_runs",

        ; --- Serialize: anonymized ---
        "serialize_anonymized_replaces_profile_with_anonymous",
        "serialize_non_anonymized_preserves_profile",

        ; --- Serialize: personalBests ---
        "serialize_omits_personal_bests_when_pb_data_missing",
        "serialize_includes_personal_bests_when_pb_data_present",

        ; --- Serialize: run fields ---
        "serialize_run_preserves_basic_fields",
        "serialize_run_converts_act_checkpoints_keys_to_strings",
        "serialize_run_skips_invalid_act_checkpoints",
        "serialize_run_preserves_details_fields",

        ; --- ValidateSchema: invalid ---
        "validate_returns_invalid_for_non_map_root",
        "validate_returns_invalid_when_schema_version_missing",
        "validate_returns_invalid_when_schema_version_older",
        "validate_returns_invalid_when_schema_version_newer",
        "validate_returns_invalid_when_runs_missing",
        "validate_returns_invalid_when_runs_not_array",
        "validate_returns_invalid_when_run_missing_run_id",
        "validate_returns_invalid_when_run_total_ms_not_positive",

        ; --- ValidateSchema: non-negative numeric fields ---
        "validate_rejects_negative_death_count",
        "validate_rejects_non_numeric_death_count",
        "validate_rejects_negative_max_act_reached",
        "validate_rejects_negative_totals_value",
        "validate_rejects_non_numeric_totals_value",
        "validate_rejects_negative_detail_ms",
        "validate_accepts_zero_in_optional_numeric_fields",
        "validate_accepts_absent_optional_numeric_fields",

        ; --- ValidateSchema: INI-breaking characters ---
        "validate_rejects_run_id_with_newline",
        "validate_rejects_profile_with_bracket",
        "validate_rejects_patch_with_carriage_return",
        "validate_rejects_totals_key_with_close_bracket",
        "validate_rejects_detail_label_with_newline",
        "validate_rejects_detail_note_with_bracket",
        "validate_rejects_zone_pbs_key_with_newline",
        "validate_rejects_run_pb_run_id_with_bracket",
        "validate_accepts_safe_punctuation_in_textual_fields",

        ; --- ValidateSchema: operational limits (import hardening) ---
        "validate_rejects_runs_array_exceeding_max",
        "validate_rejects_invalid_run_id_format",
        "validate_accepts_run_id_with_suffix",
        "validate_rejects_run_id_exceeding_max_length",
        "validate_rejects_profile_exceeding_max_length",
        "validate_rejects_totals_exceeding_max_entries",
        "validate_rejects_actcheckpoints_exceeding_max_entries",
        "validate_rejects_details_exceeding_max_entries",
        "validate_rejects_zone_name_exceeding_max_length",
        "validate_rejects_detail_label_exceeding_max_length",
        "validate_rejects_zone_pbs_exceeding_max_entries",
        "validate_rejects_zone_pb_key_exceeding_max_length",
        "validate_rejects_run_pb_run_id_exceeding_max_length",
        "validate_rejects_invalid_run_pb_run_id_format",
        "validate_accepts_empty_run_pb_run_id",

        ; --- ValidateSchema: valid + warnings ---
        "validate_returns_valid_for_minimal_correct_schema",
        "validate_includes_warning_when_exported_at_missing",

        ; --- Deserialize ---
        "deserialize_throws_on_non_map_input",
        "deserialize_returns_runs_array",
        "deserialize_converts_act_checkpoints_keys_back_to_int",
        "deserialize_extracts_meta_fields",
        "deserialize_returns_empty_string_for_missing_pbs",

        ; --- Roundtrip ---
        "roundtrip_serialize_stringify_parse_validate_deserialize",
    ]

    ; ============================================================
    ; Helper
    ; ============================================================

    _MakeRun()
    {
        return Map(
            "runId",         "20260515_103045",
            "profile",       "TestProfile",
            "patch",         "0.2.0",
            "firstTs",       "2026-05-15 10:30:45",
            "totalMs",       7665873,
            "deathCount",    3,
            "maxActReached", 5,
            "totals",        Map("mapa", 5800000, "loading", 800000, "cidade", 1065873),
            "actCheckpoints", Map(1, 1200000, 2, 2600000, 5, 7665873),
            "details", [
                Map("category", "mapa", "label", "Mud Burrow", "ms", 184321,
                    "note", "Act 1", "timestamp", "2026-05-15 10:32:13"),
                Map("category", "cidade", "label", "The Hooded One",
                    "ms", 23456, "note", "Act 1", "timestamp", "")
            ]
        )
    }

    _MakePbs()
    {
        return Map(
            "runPbMs",    7100000,
            "runPbRunId", "20260512_142345",
            "runPbByAct", Map(1, 1100000, 5, 7100000),
            "zonePbs",    Map("Mud Burrow", 175000, "Clearfell", 220000)
        )
    }

    ; ============================================================
    ; Serialize: basic schema
    ; ============================================================

    serialize_includes_schema_version()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        Assert.Equal(1, payload["schemaVersion"])
    }

    serialize_includes_exported_at()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        Assert.True(payload.Has("exportedAt"))
        ; Format "YYYY-MM-DD HH:MM:SS"
        Assert.True(RegExMatch(payload["exportedAt"],
            "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$") > 0)
    }

    serialize_includes_exported_by_with_version()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()], "",
            Map("exporterVersion", "v0.1.0"))
        Assert.Contains("SpeedKalandra", payload["exportedBy"])
        Assert.Contains("v0.1.0",        payload["exportedBy"])
    }

    serialize_anonymized_flag_defaults_false()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        ; anonymized is a JsonBool wrapper - we test it via .value
        Assert.IsType(JsonBool, payload["anonymized"])
        Assert.False(payload["anonymized"].value)
    }

    serialize_throws_when_runs_not_array()
    {
        Assert.Throws(TypeError, () => RunExportFormat.Serialize("not array"))
        Assert.Throws(TypeError, () => RunExportFormat.Serialize(Map()))
    }

    serialize_skips_non_object_runs()
    {
        ; runs with non-Map items are silently skipped
        payload := RunExportFormat.Serialize([this._MakeRun(), "not a map", 42])
        Assert.Equal(1, payload["runs"].Length)
    }

    ; ============================================================
    ; Serialize: anonymized
    ; ============================================================

    serialize_anonymized_replaces_profile_with_anonymous()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()], "",
            Map("anonymized", true))
        Assert.Equal("Anonymous", payload["runs"][1]["profile"])
        Assert.True(payload["anonymized"].value)
    }

    serialize_non_anonymized_preserves_profile()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()], "",
            Map("anonymized", false))
        Assert.Equal("TestProfile", payload["runs"][1]["profile"])
    }

    ; ============================================================
    ; Serialize: personalBests
    ; ============================================================

    serialize_omits_personal_bests_when_pb_data_missing()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        Assert.False(payload.Has("personalBests"))
    }

    serialize_includes_personal_bests_when_pb_data_present()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()], this._MakePbs())
        Assert.True(payload.Has("personalBests"))
        Assert.Equal(7100000, payload["personalBests"]["runPbMs"])
    }

    ; ============================================================
    ; Serialize: run fields
    ; ============================================================

    serialize_run_preserves_basic_fields()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        ; `run` collides with the builtin function `Run` (case-insensitive).
        ; We use `serializedRun` to avoid #Warn LocalSameAsGlobal.
        serializedRun := payload["runs"][1]
        Assert.Equal("20260515_103045",     serializedRun["runId"])
        Assert.Equal("0.2.0",               serializedRun["patch"])
        Assert.Equal("2026-05-15 10:30:45", serializedRun["firstTs"])
        Assert.Equal(7665873,               serializedRun["totalMs"])
        Assert.Equal(3,                     serializedRun["deathCount"])
        Assert.Equal(5,                     serializedRun["maxActReached"])
    }

    serialize_run_converts_act_checkpoints_keys_to_strings()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        ckpts := payload["runs"][1]["actCheckpoints"]
        ; JSON keys are always strings
        Assert.True(ckpts.Has("1"))
        Assert.True(ckpts.Has("5"))
        Assert.Equal(1200000, ckpts["1"])
        Assert.Equal(7665873, ckpts["5"])
    }

    serialize_run_skips_invalid_act_checkpoints()
    {
        ; Build a run with an invalid checkpoint key (0 or negative)
        bad := this._MakeRun()
        bad["actCheckpoints"] := Map(1, 100, 0, 200, -1, 300, 2, 400)

        payload := RunExportFormat.Serialize([bad])
        ckpts := payload["runs"][1]["actCheckpoints"]

        Assert.True(ckpts.Has("1"))
        Assert.True(ckpts.Has("2"))
        Assert.False(ckpts.Has("0"),  "key 0 must be skipped")
        Assert.False(ckpts.Has("-1"), "negative key must be skipped")
    }

    serialize_run_preserves_details_fields()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        details := payload["runs"][1]["details"]
        Assert.Equal(2, details.Length)
        Assert.Equal("mapa",                details[1]["category"])
        Assert.Equal("Mud Burrow",          details[1]["label"])
        Assert.Equal(184321,                details[1]["ms"])
        Assert.Equal("Act 1",               details[1]["note"])
        Assert.Equal("2026-05-15 10:32:13", details[1]["timestamp"])
    }

    ; ============================================================
    ; ValidateSchema: invalid
    ; ============================================================

    validate_returns_invalid_for_non_map_root()
    {
        validation := RunExportFormat.ValidateSchema("not a map")
        Assert.False(validation["valid"])
        Assert.True(validation["errors"].Length > 0)
    }

    validate_returns_invalid_when_schema_version_missing()
    {
        validation := RunExportFormat.ValidateSchema(Map("runs", []))
        Assert.False(validation["valid"])
    }

    validate_returns_invalid_when_schema_version_older()
    {
        validation := RunExportFormat.ValidateSchema(Map("schemaVersion", 0, "runs", []))
        Assert.False(validation["valid"])
    }

    validate_returns_invalid_when_schema_version_newer()
    {
        validation := RunExportFormat.ValidateSchema(Map("schemaVersion", 99, "runs", []))
        Assert.False(validation["valid"])
    }

    validate_returns_invalid_when_runs_missing()
    {
        validation := RunExportFormat.ValidateSchema(Map("schemaVersion", 1))
        Assert.False(validation["valid"])
    }

    validate_returns_invalid_when_runs_not_array()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1, "runs", "not array"
        ))
        Assert.False(validation["valid"])
    }

    validate_returns_invalid_when_run_missing_run_id()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map("totalMs", 1000)]
        ))
        Assert.False(validation["valid"])
    }

    validate_returns_invalid_when_run_total_ms_not_positive()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map("runId", "20260101_000000", "totalMs", 0)]
        ))
        Assert.False(validation["valid"])
    }

    ; ============================================================
    ; ValidateSchema: non-negative numeric fields
    ; ============================================================
    ;
    ; Imported JSON can carry negative or non-numeric values in fields
    ; that were never produced by the exporter (the exporter always
    ; emits valid integers) — hand-edited or maliciously crafted files
    ; are the realistic source. The values feed straight into the
    ; saved INI and from there into the plot dialog, PB comparisons,
    ; and run-history dialog totals, so a negative `deathCount` becomes
    ; a -3 in the death chart, a negative `totals` value distorts the
    ; per-zone breakdown, and so on. The schema gateway rejects the
    ; import with a clear error before any disk write, consistent with
    ; the INI-breaking-char policy above. Zero is accepted everywhere
    ; because zero is a legitimate value (zero deaths, a zone visited
    ; for zero ms because the player immediately left, a detail row
    ; with no measurable duration).

    validate_rejects_negative_death_count()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map("runId", "20260101_000000", "totalMs", 1000,
                         "deathCount", -3)]
        ))
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "deathCount") > 0,
            "error message names the field")
        Assert.True(InStr(validation["errors"][1], "non-negative") > 0,
            "error message identifies the constraint")
    }

    validate_rejects_non_numeric_death_count()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map("runId", "20260101_000000", "totalMs", 1000,
                         "deathCount", "three")]
        ))
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "deathCount") > 0)
    }

    validate_rejects_negative_max_act_reached()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map("runId", "20260101_000000", "totalMs", 1000,
                         "maxActReached", -1)]
        ))
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "maxActReached") > 0)
    }

    validate_rejects_negative_totals_value()
    {
        ; A zone with negative time. The INI-char check on the key
        ; passes ("Mud Burrow" is clean); the value check is what trips.
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map("runId", "20260101_000000", "totalMs", 1000,
                         "totals", Map("Mud Burrow", -5000))]
        ))
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "totals") > 0)
        Assert.True(InStr(validation["errors"][1], "non-negative") > 0)
    }

    validate_rejects_non_numeric_totals_value()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map("runId", "20260101_000000", "totalMs", 1000,
                         "totals", Map("Mud Burrow", "a lot"))]
        ))
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "totals") > 0)
    }

    validate_rejects_negative_detail_ms()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map("runId", "20260101_000000", "totalMs", 1000,
                         "details", [
                             Map("category", "mapa", "label", "Mud Burrow",
                                 "ms", -100, "note", "", "timestamp", "")
                         ])]
        ))
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "details") > 0)
        Assert.True(InStr(validation["errors"][1], "ms") > 0)
    }

    validate_accepts_zero_in_optional_numeric_fields()
    {
        ; Positive control: zero must NOT be rejected. Zero deaths is
        ; the common case for a clean run; a zone visited for 0 ms
        ; happens when the player crosses through an instance without
        ; the timer registering a measurable stay; a detail row with
        ; ms=0 can show up for a zone that loaded and immediately
        ; transitioned. The lower bound is 0, not 1.
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map(
                "runId",         "20260101_000000",
                "totalMs",       1000,
                "deathCount",    0,
                "maxActReached", 0,
                "totals",        Map("Mud Burrow", 0),
                "details",       [
                    Map("category", "mapa", "label", "Mud Burrow",
                        "ms", 0, "note", "", "timestamp", "")
                ]
            )]
        ))
        firstError := validation["errors"].Length > 0 ? validation["errors"][1] : "<no error>"
        Assert.True(validation["valid"],
            "zero in optional numeric fields must validate. Error: " . firstError)
    }

    validate_accepts_absent_optional_numeric_fields()
    {
        ; Positive control: deathCount / maxActReached / totals / details
        ; are all optional. Their absence must not produce errors —
        ; only `runId` and `totalMs` are required at the run level.
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map(
                "runId",   "20260101_000000",
                "totalMs", 1000
            )]
        ))
        Assert.True(validation["valid"],
            "missing optional fields must validate (only runId/totalMs required)")
    }

    ; ============================================================
    ; ValidateSchema: INI-breaking characters
    ; ============================================================
    ;
    ; Imported runs are persisted to data/runs/{runId}.ini, whose
    ; structure depends on \r, \n, [ and ] being reserved. A JSON
    ; payload with any of those in a textual field would silently
    ; corrupt the saved file or merge fields across sections. The
    ; check happens at import time (Preview → ValidateSchema) so the
    ; user sees a clear error before disk is touched. A second
    ; defensive check inside RunHistoryRepository._SerializeBuildResultToIni
    ; catches the case where a bad char slips in through some other
    ; code path (covered by run_history_repository_tests).

    _BuildParsedPayload(modifyRun := "", modifyPbs := "")
    {
        ; Helper: returns a parsed-shape Map (i.e. what JsonFile.Parse
        ; produces) holding one minimally valid run plus optional PBs.
        ; Callers mutate the returned Map before passing to
        ; ValidateSchema to assert specific rejections.
        run := Map(
            "runId",   "20260515_103045",
            "totalMs", 5000,
            "totals",  Map("mapa", 5000),
            "details", [
                Map("category", "mapa", "label", "Test Zone",
                    "ms", 5000, "note", "", "timestamp", "")
            ]
        )
        if IsObject(modifyRun)
        {
            for k, v in modifyRun
                run[k] := v
        }
        payload := Map(
            "schemaVersion", 1,
            "runs",          [run]
        )
        if IsObject(modifyPbs)
        {
            payload["personalBests"] := modifyPbs
        }
        return payload
    }

    validate_rejects_run_id_with_newline()
    {
        ; \n in runId would split the [meta] section across two
        ; lines, so runId=`foo\nbar` becomes `runId=foo` plus a
        ; stray `bar` line.
        payload := this._BuildParsedPayload(Map("runId", "20260515`n_evil"))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"], "newline in runId rejected")
        Assert.True(validation["errors"].Length >= 1)
        Assert.True(InStr(validation["errors"][1], "runId") > 0,
            "error message names the field")
        Assert.True(InStr(validation["errors"][1], "INI-breaking") > 0,
            "error message identifies the cause")
    }

    validate_rejects_profile_with_bracket()
    {
        ; [ at the start of a value can be mistaken for a new INI
        ; section header by some parsers, even mid-value.
        payload := this._BuildParsedPayload(Map("profile", "Default[evil"))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "profile") > 0)
    }

    validate_rejects_patch_with_carriage_return()
    {
        ; \r alone (Mac-classic line endings) is just as dangerous
        ; as \n for INI parsing.
        payload := this._BuildParsedPayload(Map("patch", "0.2.0`r0.2.1"))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "patch") > 0)
    }

    validate_rejects_totals_key_with_close_bracket()
    {
        ; Zone names become INI keys under [totals]. A ] in the key
        ; could trip strict parsers.
        payload := this._BuildParsedPayload(Map(
            "totals", Map("Mud Burrow]", 5000)
        ))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "totals") > 0)
    }

    validate_rejects_detail_label_with_newline()
    {
        ; details rows are written as `N=category|label|ms|note|timestamp`
        ; on a single line. A \n in label splits the row and the
        ; count value becomes inconsistent on load.
        payload := this._BuildParsedPayload(Map(
            "details", [
                Map("category", "mapa", "label", "Mud`nBurrow",
                    "ms", 5000, "note", "", "timestamp", "")
            ]
        ))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "label") > 0)
    }

    validate_rejects_detail_note_with_bracket()
    {
        payload := this._BuildParsedPayload(Map(
            "details", [
                Map("category", "mapa", "label", "Mud Burrow",
                    "ms", 5000, "note", "Act [1]", "timestamp", "")
            ]
        ))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "note") > 0)
    }

    validate_rejects_zone_pbs_key_with_newline()
    {
        ; Personal bests live in their own INI (data/personal_bests.ini)
        ; but the same structural rules apply.
        pbs := Map(
            "runPbMs",    7100000,
            "runPbRunId", "20260512_142345",
            "zonePbs",    Map("Mud`nBurrow", 175000)
        )
        payload := this._BuildParsedPayload("", pbs)
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "zonePbs") > 0)
    }

    validate_rejects_run_pb_run_id_with_bracket()
    {
        pbs := Map(
            "runPbMs",    7100000,
            "runPbRunId", "20260512_142345[evil"
        )
        payload := this._BuildParsedPayload("", pbs)
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "runPbRunId") > 0)
    }

    validate_accepts_safe_punctuation_in_textual_fields()
    {
        ; Positive control: =, ;, |, parens and long strings must
        ; NOT trigger the rejection. The INI format only cares about
        ; \r\n[]; everything else is fair game for human-readable
        ; profile / patch names and zone labels. Unicode coverage
        ; lives in the round-trip tests in run_history_repository_tests.
        longString := ""
        loop 300
            longString .= "a"
        payload := this._BuildParsedPayload(Map(
            "profile", "Default = main; (test) | branch",
            "patch",   "0.2.0 (build #42) - hotfix",
            "totals",  Map("Mud Burrow", 5000, "Clearfell Encampment", 3000),
            "details", [
                Map("category", "mapa", "label", longString,
                    "ms", 5000, "note", "Act 1; pre-boss", "timestamp", "")
            ]
        ))
        validation := RunExportFormat.ValidateSchema(payload)
        firstError := validation["errors"].Length > 0 ? validation["errors"][1] : "<no error>"
        Assert.True(validation["valid"], firstError)
    }

    ; ============================================================
    ; ValidateSchema: operational limits (import hardening)
    ; ============================================================
    ;
    ; The import boundary is the most untrusted surface in the
    ; app. The exporter only emits well-formed payloads, but
    ; hand-edited or maliciously crafted JSON could carry millions
    ; of runs, gigabytes of single-field strings, or runIds that
    ; would name themselves as path traversal sequences. Each cap
    ; below has a paired test — the reasoning for the specific
    ; numbers lives in RunExportFormat (see the constants block).
    ;
    ; All tests build a structurally valid payload first via
    ; _BuildParsedPayload, then mutate the one field under test;
    ; this isolates the failure cause from any other check.

    validate_rejects_runs_array_exceeding_max()
    {
        ; Build a payload with MAX_RUNS_PER_FILE + 1 minimal runs.
        ; The cap is enforced BEFORE per-run validation, so the
        ; entries themselves can be cheap stubs — we're testing
        ; the early-exit, not the inner loop.
        bigArray := []
        loop RunExportFormat.MAX_RUNS_PER_FILE + 1
            bigArray.Push(Map("runId", "20260101_000000", "totalMs", 1000))
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", bigArray
        ))
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "exceeds maximum") > 0,
            "error names the cap, not just 'invalid runs'")
        Assert.True(InStr(validation["errors"][1], "runs") > 0)
    }

    validate_rejects_invalid_run_id_format()
    {
        ; A non-empty runId that doesn't match YYYYMMDD_HHMMSS
        ; must be rejected (it would become the saved filename
        ; on disk, possibly carrying path separators or
        ; AHK-meaningful chars).
        payload := this._BuildParsedPayload(Map("runId", "not-a-runid"))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "runId") > 0)
        Assert.True(InStr(validation["errors"][1], "invalid format") > 0,
            "error message identifies the cause")
    }

    validate_accepts_run_id_with_suffix()
    {
        ; Positive control: the legacy `YYYYMMDD_HHMMSS_<suffix>`
        ; form (used historically for profile-tagged runIds, and
        ; today for rename-on-conflict during import) must keep
        ; passing validation — RunImportService relies on it.
        payload := this._BuildParsedPayload(Map("runId", "20260515_103045_imported_2"))
        validation := RunExportFormat.ValidateSchema(payload)
        firstError := validation["errors"].Length > 0 ? validation["errors"][1] : "<no error>"
        Assert.True(validation["valid"], firstError)
    }

    validate_rejects_run_id_exceeding_max_length()
    {
        ; A 600-char runId would otherwise pass the format check
        ; only because the regex `(_[a-zA-Z0-9_-]+)?` accepts an
        ; arbitrarily long suffix. The length cap is what stops it.
        bigSuffix := ""
        loop 600
            bigSuffix .= "a"
        oversized := "20260101_000000_" bigSuffix
        payload := this._BuildParsedPayload(Map("runId", oversized))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "runId") > 0)
        Assert.True(InStr(validation["errors"][1], "maximum length") > 0)
    }

    validate_rejects_profile_exceeding_max_length()
    {
        bigProfile := ""
        loop RunExportFormat.MAX_STRING_LEN + 1
            bigProfile .= "x"
        payload := this._BuildParsedPayload(Map("profile", bigProfile))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "profile") > 0)
        Assert.True(InStr(validation["errors"][1], "maximum length") > 0)
    }

    validate_rejects_totals_exceeding_max_entries()
    {
        bigTotals := Map()
        loop RunExportFormat.MAX_TOTALS_PER_RUN + 1
            bigTotals["zone_" A_Index] := A_Index * 1000
        payload := this._BuildParsedPayload(Map("totals", bigTotals))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "totals") > 0)
        Assert.True(InStr(validation["errors"][1], "exceeds maximum") > 0)
    }

    validate_rejects_actcheckpoints_exceeding_max_entries()
    {
        bigCheckpoints := Map()
        loop RunExportFormat.MAX_ACT_CHECKPOINTS + 1
            bigCheckpoints[A_Index] := A_Index * 100000
        payload := this._BuildParsedPayload(Map("actCheckpoints", bigCheckpoints))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "actCheckpoints") > 0)
        Assert.True(InStr(validation["errors"][1], "exceeds maximum") > 0)
    }

    validate_rejects_details_exceeding_max_entries()
    {
        bigDetails := []
        loop RunExportFormat.MAX_DETAILS_PER_RUN + 1
            bigDetails.Push(Map("category", "mapa", "label", "Z",
                "ms", 100, "note", "", "timestamp", ""))
        payload := this._BuildParsedPayload(Map("details", bigDetails))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "details") > 0)
        Assert.True(InStr(validation["errors"][1], "exceeds maximum") > 0)
    }

    validate_rejects_zone_name_exceeding_max_length()
    {
        bigZone := ""
        loop RunExportFormat.MAX_STRING_LEN + 1
            bigZone .= "z"
        payload := this._BuildParsedPayload(Map(
            "totals", Map(bigZone, 5000)
        ))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "totals") > 0)
        Assert.True(InStr(validation["errors"][1], "maximum length") > 0)
    }

    validate_rejects_detail_label_exceeding_max_length()
    {
        bigLabel := ""
        loop RunExportFormat.MAX_STRING_LEN + 1
            bigLabel .= "l"
        payload := this._BuildParsedPayload(Map(
            "details", [
                Map("category", "mapa", "label", bigLabel,
                    "ms", 5000, "note", "", "timestamp", "")
            ]
        ))
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "label") > 0)
        Assert.True(InStr(validation["errors"][1], "maximum length") > 0)
    }

    validate_rejects_zone_pbs_exceeding_max_entries()
    {
        bigZonePbs := Map()
        loop RunExportFormat.MAX_ZONE_PBS + 1
            bigZonePbs["zone_" A_Index] := A_Index * 1000
        pbs := Map(
            "runPbMs",    7100000,
            "runPbRunId", "20260512_142345",
            "zonePbs",    bigZonePbs
        )
        payload := this._BuildParsedPayload("", pbs)
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "zonePbs") > 0)
        Assert.True(InStr(validation["errors"][1], "exceeds maximum") > 0)
    }

    validate_rejects_zone_pb_key_exceeding_max_length()
    {
        bigZone := ""
        loop RunExportFormat.MAX_STRING_LEN + 1
            bigZone .= "k"
        pbs := Map(
            "runPbMs",    7100000,
            "runPbRunId", "20260512_142345",
            "zonePbs",    Map(bigZone, 100000)
        )
        payload := this._BuildParsedPayload("", pbs)
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "zonePbs") > 0)
        Assert.True(InStr(validation["errors"][1], "maximum length") > 0)
    }

    validate_rejects_run_pb_run_id_exceeding_max_length()
    {
        bigRunId := "20260101_000000_"
        loop 600
            bigRunId .= "a"
        pbs := Map(
            "runPbMs",    7100000,
            "runPbRunId", bigRunId
        )
        payload := this._BuildParsedPayload("", pbs)
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "runPbRunId") > 0)
        Assert.True(InStr(validation["errors"][1], "maximum length") > 0)
    }

    validate_rejects_invalid_run_pb_run_id_format()
    {
        ; A clean, short but malformed runPbRunId fails the format
        ; check (not the length check, not the INI-char check).
        ; This is the gap RunId.IsValid closes for PBs.
        pbs := Map(
            "runPbMs",    7100000,
            "runPbRunId", "not-a-valid-runid"
        )
        payload := this._BuildParsedPayload("", pbs)
        validation := RunExportFormat.ValidateSchema(payload)
        Assert.False(validation["valid"])
        Assert.True(InStr(validation["errors"][1], "runPbRunId") > 0)
        Assert.True(InStr(validation["errors"][1], "invalid format") > 0)
    }

    validate_accepts_empty_run_pb_run_id()
    {
        ; Positive control: an empty runPbRunId is the well-formed
        ; "no PB yet" state (a PB block with runPbMs=0 and no
        ; anchored runId). The format check must skip empty values.
        pbs := Map(
            "runPbMs",    0,
            "runPbRunId", ""
        )
        payload := this._BuildParsedPayload("", pbs)
        validation := RunExportFormat.ValidateSchema(payload)
        firstError := validation["errors"].Length > 0 ? validation["errors"][1] : "<no error>"
        Assert.True(validation["valid"], firstError)
    }

    ; ============================================================
    ; ValidateSchema: valid + warnings
    ; ============================================================

    validate_returns_valid_for_minimal_correct_schema()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "exportedAt", "2026-05-15 10:00:00",
            "exportedBy", "SpeedKalandra v0.1.0",
            "runs", [Map(
                "runId",   "20260101_000000",
                "totalMs", 1000
            )]
        ))
        Assert.True(validation["valid"],
            "Minimal schema should validate. Errors: "
            . (validation["errors"].Length > 0 ? validation["errors"][1] : "(none)"))
    }

    validate_includes_warning_when_exported_at_missing()
    {
        validation := RunExportFormat.ValidateSchema(Map(
            "schemaVersion", 1,
            "runs", [Map("runId", "20260101_000000", "totalMs", 1000)]
        ))
        Assert.True(validation["valid"], "exportedAt is only a warning, doesn't block")
        Assert.True(validation["warnings"].Length > 0)
    }

    ; ============================================================
    ; Deserialize
    ; ============================================================

    deserialize_throws_on_non_map_input()
    {
        Assert.Throws(TypeError, () => RunExportFormat.Deserialize("not map"))
        Assert.Throws(TypeError, () => RunExportFormat.Deserialize([]))
    }

    deserialize_returns_runs_array()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        decoded := RunExportFormat.Deserialize(payload)
        Assert.Equal(1, decoded["runs"].Length)
        Assert.Equal("20260515_103045", decoded["runs"][1]["runId"])
    }

    deserialize_converts_act_checkpoints_keys_back_to_int()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        decoded := RunExportFormat.Deserialize(payload)
        ckpts := decoded["runs"][1]["actCheckpoints"]
        ; Keys are integers after Deserialize (reverted from "1" -> 1)
        Assert.True(ckpts.Has(1))
        Assert.True(ckpts.Has(5))
        Assert.Equal(1200000, ckpts[1])
    }

    deserialize_extracts_meta_fields()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()], "",
            Map("anonymized", true, "exporterVersion", "v0.1.0"))
        decoded := RunExportFormat.Deserialize(payload)
        Assert.True(decoded["meta"]["anonymized"])
        Assert.Contains("SpeedKalandra", decoded["meta"]["exportedBy"])
    }

    deserialize_returns_empty_string_for_missing_pbs()
    {
        payload := RunExportFormat.Serialize([this._MakeRun()])
        ; No pbData -> no personalBests
        decoded := RunExportFormat.Deserialize(payload)
        Assert.Equal("", decoded["personalBests"])
    }

    ; ============================================================
    ; Roundtrip
    ; ============================================================

    roundtrip_serialize_stringify_parse_validate_deserialize()
    {
        originalRun := this._MakeRun()
        originalPbs := this._MakePbs()

        ; 1. Serialize
        payload := RunExportFormat.Serialize([originalRun], originalPbs,
            Map("anonymized", false))

        ; 2. Stringify
        jsonStr := JsonFile.Stringify(payload, 0)
        Assert.True(StrLen(jsonStr) > 100)

        ; 3. Parse
        parsed := JsonFile.Parse(jsonStr)

        ; 4. Validate
        validation := RunExportFormat.ValidateSchema(parsed)
        Assert.True(validation["valid"],
            "Roundtrip should validate. Errors: "
            . (validation["errors"].Length > 0 ? validation["errors"][1] : "(none)"))

        ; 5. Deserialize and compare
        decoded := RunExportFormat.Deserialize(parsed)
        Assert.Equal(1, decoded["runs"].Length)

        decodedRun := decoded["runs"][1]
        Assert.Equal(originalRun["runId"],         decodedRun["runId"])
        Assert.Equal(originalRun["profile"],       decodedRun["profile"])
        Assert.Equal(originalRun["totalMs"],       decodedRun["totalMs"])
        Assert.Equal(originalRun["deathCount"],    decodedRun["deathCount"])
        Assert.Equal(originalRun["maxActReached"], decodedRun["maxActReached"])

        ; actCheckpoints: back to Map<int, int>
        Assert.Equal(1200000, decodedRun["actCheckpoints"][1])
        Assert.Equal(7665873, decodedRun["actCheckpoints"][5])

        ; details preserved
        Assert.Equal(2, decodedRun["details"].Length)
        Assert.Equal("Mud Burrow", decodedRun["details"][1]["label"])

        ; PBs
        Assert.Equal(7100000, decoded["personalBests"]["runPbMs"])
        Assert.Equal(1100000, decoded["personalBests"]["runPbByAct"][1])
        Assert.Equal(175000,  decoded["personalBests"]["zonePbs"]["Mud Burrow"])
    }
}

TestRegistry.Register(RunExportFormatTests)

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

; ============================================================
; RunState tests
; ============================================================
;
; Cobre o value object RunState (runId, startedAt, status, runBaseMs):
;   - Empty() retorna estado zerado
;   - FromMap valida status contra os 5 valores aceitos
;   - FromMap aceita runBaseMs negativo coercendo pra 0
;   - FromMap aceita data nao-Map retornando Empty (defensive)
;   - ToMap/FromMap roundtrip
;   - Predicates: IsEmpty, IsRunning, IsPaused, IsCompleted, IsCancelled, IsActive

class RunStateTests extends TestCase
{
    static Tests := [
        ; --- Empty ---
        "empty_returns_idle_state_with_no_run",
        "empty_starts_with_zero_base_ms",

        ; --- FromMap ---
        "from_map_reads_all_fields",
        "from_map_coerces_run_base_ms_string_to_int",
        "from_map_clamps_negative_run_base_ms_to_zero",
        "from_map_ignores_unknown_status",
        "from_map_accepts_all_known_statuses",
        "from_map_returns_empty_when_data_not_object",
        "from_map_handles_partial_data",

        ; --- ToMap ---
        "to_map_serializes_all_fields",
        "to_map_from_map_roundtrip",

        ; --- Predicates ---
        "is_empty_true_only_when_run_id_missing",
        "is_running_true_only_when_status_running",
        "is_paused_true_only_when_status_paused",
        "is_completed_true_only_when_status_completed",
        "is_cancelled_true_only_when_status_cancelled",
        "is_active_true_for_running_or_paused",
        "is_active_false_for_idle_completed_cancelled",
    ]

    ; ============================================================
    ; Empty
    ; ============================================================

    empty_returns_idle_state_with_no_run()
    {
        s := RunState.Empty()
        Assert.Equal("", s.runId)
        Assert.Equal("", s.startedAt)
        Assert.Equal("idle", s.status)
    }

    empty_starts_with_zero_base_ms()
    {
        Assert.Equal(0, RunState.Empty().runBaseMs)
    }

    ; ============================================================
    ; FromMap
    ; ============================================================

    from_map_reads_all_fields()
    {
        s := RunState.FromMap(Map(
            "runId",     "20260512_142345",
            "startedAt", "2026-05-12 14:23:45",
            "status",    "running",
            "runBaseMs", 187432
        ))
        Assert.Equal("20260512_142345",      s.runId)
        Assert.Equal("2026-05-12 14:23:45",  s.startedAt)
        Assert.Equal("running",              s.status)
        Assert.Equal(187432,                 s.runBaseMs)
    }

    from_map_coerces_run_base_ms_string_to_int()
    {
        s := RunState.FromMap(Map("runBaseMs", "12345"))
        Assert.Equal(12345, s.runBaseMs)
    }

    from_map_clamps_negative_run_base_ms_to_zero()
    {
        s := RunState.FromMap(Map("runBaseMs", -100))
        Assert.Equal(0, s.runBaseMs)
    }

    from_map_ignores_unknown_status()
    {
        s := RunState.FromMap(Map("status", "weird_status"))
        Assert.Equal("idle", s.status, "Status invalido deve manter default")
    }

    from_map_accepts_all_known_statuses()
    {
        for _, status in ["idle", "running", "paused", "completed", "cancelled"]
        {
            s := RunState.FromMap(Map("status", status))
            Assert.Equal(status, s.status)
        }
    }

    from_map_returns_empty_when_data_not_object()
    {
        s := RunState.FromMap("")
        Assert.True(s.IsEmpty())
        Assert.Equal("idle", s.status)
    }

    from_map_handles_partial_data()
    {
        s := RunState.FromMap(Map("runId", "20260512_142345"))
        Assert.Equal("20260512_142345", s.runId)
        Assert.Equal("idle", s.status, "Status nao informado mantem default")
        Assert.Equal(0, s.runBaseMs)
    }

    ; ============================================================
    ; ToMap
    ; ============================================================

    to_map_serializes_all_fields()
    {
        s := RunState.Empty()
        s.runId     := "20260512_142345"
        s.startedAt := "2026-05-12 14:23:45"
        s.status    := "running"
        s.runBaseMs := 5000

        m := s.ToMap()
        Assert.Equal("20260512_142345",     m["runId"])
        Assert.Equal("2026-05-12 14:23:45", m["startedAt"])
        Assert.Equal("running",             m["status"])
        Assert.Equal(5000,                  m["runBaseMs"])
    }

    to_map_from_map_roundtrip()
    {
        original := RunState.Empty()
        original.runId     := "20260512_142345"
        original.startedAt := "2026-05-12 14:23:45"
        original.status    := "paused"
        original.runBaseMs := 99999

        recovered := RunState.FromMap(original.ToMap())
        Assert.Equal(original.runId,     recovered.runId)
        Assert.Equal(original.startedAt, recovered.startedAt)
        Assert.Equal(original.status,    recovered.status)
        Assert.Equal(original.runBaseMs, recovered.runBaseMs)
    }

    ; ============================================================
    ; Predicates
    ; ============================================================

    is_empty_true_only_when_run_id_missing()
    {
        Assert.True(RunState.Empty().IsEmpty())

        s := RunState.Empty()
        s.runId := "20260512_142345"
        Assert.False(s.IsEmpty())
    }

    is_running_true_only_when_status_running()
    {
        s := RunState.Empty()
        Assert.False(s.IsRunning())
        s.status := "running"
        Assert.True(s.IsRunning())
        s.status := "paused"
        Assert.False(s.IsRunning())
    }

    is_paused_true_only_when_status_paused()
    {
        s := RunState.Empty()
        s.status := "paused"
        Assert.True(s.IsPaused())
        s.status := "running"
        Assert.False(s.IsPaused())
    }

    is_completed_true_only_when_status_completed()
    {
        s := RunState.Empty()
        s.status := "completed"
        Assert.True(s.IsCompleted())
        s.status := "cancelled"
        Assert.False(s.IsCompleted())
    }

    is_cancelled_true_only_when_status_cancelled()
    {
        s := RunState.Empty()
        s.status := "cancelled"
        Assert.True(s.IsCancelled())
        s.status := "completed"
        Assert.False(s.IsCancelled())
    }

    is_active_true_for_running_or_paused()
    {
        s := RunState.Empty()
        s.status := "running"
        Assert.True(s.IsActive())
        s.status := "paused"
        Assert.True(s.IsActive())
    }

    is_active_false_for_idle_completed_cancelled()
    {
        s := RunState.Empty()
        Assert.False(s.IsActive(), "idle nao eh ativo")

        s.status := "completed"
        Assert.False(s.IsActive())

        s.status := "cancelled"
        Assert.False(s.IsActive())
    }
}

TestRegistry.Register(RunStateTests)

; ============================================================
; Clock tests - cobertura completa de RealClock + FakeClock
; ============================================================
;
; RealClock e' uma fachada fina sobre A_Now / A_TickCount - testamos
; apenas que os retornos sao compativeis com os tipos esperados e que
; NowMs eh monotonico no curto prazo (ja que A_TickCount eh).
;
; FakeClock eh onde mora a complexidade: avancos manuais, independencia
; entre Now() (string YYYYMMDDHH24MISS) e NowMs() (inteiro arbitrario)
; e a sincronizacao opcional via SyncNowFromMs.

class RealClockTests extends TestCase
{
    static Tests := [
        "now_returns_yyyymmddhhmmss_string",
        "now_ms_returns_integer",
        "now_ms_is_monotonic_in_short_term",
    ]

    now_returns_yyyymmddhhmmss_string()
    {
        clock := RealClock()
        result := clock.Now()
        ; A_Now eh sempre 14 chars: YYYYMMDDHH24MISS
        Assert.Equal(14, StrLen(result))
        ; Todos digitos
        Assert.True(RegExMatch(result, "^\d{14}$") > 0,
            "Now() deveria ser 14 digitos, veio: " result)
    }

    now_ms_returns_integer()
    {
        clock := RealClock()
        result := clock.NowMs()
        Assert.True(IsNumber(result), "NowMs() deveria ser numero")
        Assert.True(result > 0, "NowMs() deveria ser > 0 num sistema rodando")
    }

    now_ms_is_monotonic_in_short_term()
    {
        clock := RealClock()
        t1 := clock.NowMs()
        Sleep 10
        t2 := clock.NowMs()
        Assert.True(t2 >= t1, "NowMs() deve ser monotonico: t1=" t1 " t2=" t2)
        Assert.True(t2 - t1 >= 1, "Sleep 10 deveria ter avancado pelo menos 1ms")
    }
}

class FakeClockTests extends TestCase
{
    static Tests := [
        "default_constructor_uses_2026_01_01_and_zero_ms",
        "explicit_constructor_sets_initial_values",
        "now_ms_starts_at_initial_and_advances_via_advance_ms",
        "advance_seconds_multiplies_by_1000",
        "advance_minutes_multiplies_by_60000",
        "set_now_updates_now_independently",
        "advance_ms_does_not_affect_now",
        "set_now_does_not_affect_now_ms",
        "sync_now_from_ms_advances_now_by_tick_seconds",
        "sync_now_from_ms_is_idempotent_at_zero",
        "multiple_advances_accumulate",
    ]

    default_constructor_uses_2026_01_01_and_zero_ms()
    {
        clock := FakeClock()
        Assert.Equal("20260101000000", clock.Now())
        Assert.Equal(0, clock.NowMs())
    }

    explicit_constructor_sets_initial_values()
    {
        clock := FakeClock("20300615120000", 5000)
        Assert.Equal("20300615120000", clock.Now())
        Assert.Equal(5000, clock.NowMs())
    }

    now_ms_starts_at_initial_and_advances_via_advance_ms()
    {
        clock := FakeClock("20260101000000", 100)
        Assert.Equal(100, clock.NowMs())
        clock.AdvanceMs(250)
        Assert.Equal(350, clock.NowMs())
        clock.AdvanceMs(0)
        Assert.Equal(350, clock.NowMs())
    }

    advance_seconds_multiplies_by_1000()
    {
        clock := FakeClock()
        clock.AdvanceSeconds(3)
        Assert.Equal(3000, clock.NowMs())
        clock.AdvanceSeconds(0.5)
        Assert.Equal(3500, clock.NowMs())
    }

    advance_minutes_multiplies_by_60000()
    {
        clock := FakeClock()
        clock.AdvanceMinutes(2)
        Assert.Equal(120000, clock.NowMs())
    }

    set_now_updates_now_independently()
    {
        clock := FakeClock()
        clock.SetNow("20270315093045")
        Assert.Equal("20270315093045", clock.Now())
    }

    advance_ms_does_not_affect_now()
    {
        clock := FakeClock("20260101000000", 0)
        clock.AdvanceMs(60000)
        ; Now deve permanecer no inicial - independencia explicita no design
        Assert.Equal("20260101000000", clock.Now())
        Assert.Equal(60000, clock.NowMs())
    }

    set_now_does_not_affect_now_ms()
    {
        clock := FakeClock("20260101000000", 1234)
        clock.SetNow("20270101000000")
        Assert.Equal(1234, clock.NowMs())
    }

    sync_now_from_ms_advances_now_by_tick_seconds()
    {
        clock := FakeClock("20260101000000", 0)
        clock.AdvanceMs(125000)   ; 125s
        clock.SyncNowFromMs()
        ; 125s apos 2026-01-01 00:00:00 = 00:02:05
        Assert.Equal("20260101000205", clock.Now())
    }

    sync_now_from_ms_is_idempotent_at_zero()
    {
        clock := FakeClock("20260101000000", 0)
        clock.SyncNowFromMs()
        Assert.Equal("20260101000000", clock.Now())
    }

    multiple_advances_accumulate()
    {
        clock := FakeClock()
        clock.AdvanceMs(100)
        clock.AdvanceSeconds(1)
        clock.AdvanceMinutes(1)
        ; 100 + 1000 + 60000 = 61100
        Assert.Equal(61100, clock.NowMs())
    }
}

TestRegistry.Register(RealClockTests)
TestRegistry.Register(FakeClockTests)

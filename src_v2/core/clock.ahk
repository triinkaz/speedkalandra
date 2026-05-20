; ============================================================
; Clock — time abstraction
; ============================================================
;
; Why does this exist?
;   - Services that depend on A_Now / A_TickCount become untestable
;     ("test passes at 23:59 and fails at 00:01")
;   - Services receive `clock` via constructor; in the real app it's
;     RealClock, in tests it's FakeClock that you advance manually
;
; Usage in a service:
;     class TimerService {
;         _clock := ""
;         __New(bus, clock) {
;             this._clock := clock
;         }
;         Start() {
;             this._startMs := this._clock.NowMs()
;         }
;     }
;
; Usage in a test:
;     clock := FakeClock()
;     service := TimerService(bus, clock)
;     service.Start()
;     clock.AdvanceMs(5000)
;     Assert.Equals(5000, service.GetElapsedMs())

; ------------------------------------------------------------
; Implicit interface (duck-typed):
;   Now()    -> string YYYYMMDDHH24MISS (compatible with A_Now)
;   NowMs()  -> integer ms since arbitrary epoch (monotonic)
; ------------------------------------------------------------

class RealClock
{
    Now()   => A_Now
    NowMs() => A_TickCount
}

; ------------------------------------------------------------
; FakeClock — manual control for tests
;
; - Now() returns a timestamp adjustable via SetNow()
; - NowMs() starts at 0 and advances via AdvanceMs / AdvanceSeconds / AdvanceMinutes
; - The two are independent (advancing NowMs does not advance Now); if you want
;   to sync them use SyncNowFromMs() (advances Now according to NowMs ms)
; ------------------------------------------------------------
class FakeClock
{
    _now    := "20260101000000"
    _tickMs := 0

    __New(initialNow := "20260101000000", initialTickMs := 0)
    {
        this._now    := initialNow
        this._tickMs := initialTickMs
    }

    Now()   => this._now
    NowMs() => this._tickMs

    SetNow(now)
    {
        this._now := now
    }

    AdvanceMs(ms)
    {
        this._tickMs += ms
    }

    AdvanceSeconds(s)
    {
        this.AdvanceMs(s * 1000)
    }

    AdvanceMinutes(m)
    {
        this.AdvanceMs(m * 60 * 1000)
    }

    ; Advances _now according to the current tick.
    ; Useful when you want Now() to reflect simulated time.
    SyncNowFromMs()
    {
        ; converts _tickMs (ms since start) into YYYYMMDDHH24MISS offset
        ; it's approximate, sufficient for tests
        seconds := this._tickMs // 1000
        baseTime := this._now
        baseTime := DateAdd(baseTime, seconds, "Seconds")
        this._now := baseTime
    }
}

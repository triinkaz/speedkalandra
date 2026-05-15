; ============================================================
; Clock — abstracao de tempo
; ============================================================
;
; Por que isso existe?
;   - Services que dependem de A_Now / A_TickCount viram intestaveis
;     ("teste passa as 23h59 e falha as 00h01")
;   - Services recebem `clock` por construtor; no app real eh RealClock,
;     em testes eh FakeClock que voce avanca manualmente
;
; Uso em servico:
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
; Uso em teste:
;     clock := FakeClock()
;     service := TimerService(bus, clock)
;     service.Start()
;     clock.AdvanceMs(5000)
;     Assert.Equals(5000, service.GetElapsedMs())

; ------------------------------------------------------------
; Interface implicita (duck-typed):
;   Now()    -> string YYYYMMDDHH24MISS (compativel com A_Now)
;   NowMs()  -> integer ms desde epoch arbitrario (monotono)
; ------------------------------------------------------------

class RealClock
{
    Now()   => A_Now
    NowMs() => A_TickCount
}

; ------------------------------------------------------------
; FakeClock — controle manual para testes
;
; - Now() retorna um timestamp ajustavel via SetNow()
; - NowMs() comeca em 0 e avanca via AdvanceMs / AdvanceSeconds / AdvanceMinutes
; - Ambos sao independentes (avancar NowMs nao avanca Now); se quiser
;   sincronizar use SyncNowFromMs() (avanca Now de acordo com NowMs ms)
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

    ; Avanca _now de acordo com o tick atual.
    ; Util quando voce quer que Now() reflita o tempo simulado.
    SyncNowFromMs()
    {
        ; converte _tickMs (ms desde inicio) em offset YYYYMMDDHH24MISS
        ; eh aproximado, suficiente para testes
        seconds := this._tickMs // 1000
        baseTime := this._now
        baseTime := DateAdd(baseTime, seconds, "Seconds")
        this._now := baseTime
    }
}

; ------------------------------------------------------------
; v17.15 (Bug #18): ReplayClock removido.
;
; Era um clock simulado pro modo replay (CampaignReplayCore +
; CampaignReplayService). Esses services foram demolidos na Onda 1
; e agora vivem em _LIXEIRA/. Sem callers no codigo vivo, a classe
; era 100+ linhas de codigo morto.
;
; Se voltar a precisar de replay no futuro, recuperar da historia
; do git ou do _LIXEIRA/.
; ------------------------------------------------------------

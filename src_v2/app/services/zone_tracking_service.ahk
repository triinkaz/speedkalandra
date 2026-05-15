; ============================================================
; ZoneTrackingService - tempo agregado por zona durante uma run
; ============================================================
;
; Substitui o legado TownVisitTracker + paradigma de "tempo por step".
; Em vez de tracking por step (que nao existe mais sem rota), rastreamos
; tempo por ZONA fisica. Resultado: Map<zoneName, totalMs>.
;
; SEMANTICA DE "TEMPO":
;   Tempo so eh acumulado quando ha RUN ATIVA. Antes de RunStarted (ou
;   apos RunCompleted/Cancelled/Reset), o service pode REGISTRAR qual eh
;   a zona corrente (pra display nos widgets) mas NAO incrementa
;   contadores nem inicia _startMs.
;
;   Isso evita que o seed do LogMonitor (que republica o ultimo
;   ZoneChanged do tail do log no boot pra hidratar widgets) faca o
;   tracker acumular tempo "fantasma" antes de qualquer run comecar.
;
; FLUXO:
;   - boot: _runActive=false, _activeZone="", _startMs=0, _totals={}
;
;   - Evt.ZoneChanged chega com nova zona:
;       1. Se ha zona ativa COM startMs > 0: flush (soma elapsed em _totals)
;       2. Set _activeZone = nova
;       3. Se _runActive: _startMs = NowMs() (comeca a contar)
;          Senao: _startMs = 0 (so registra a zona, sem contar)
;       4. Publica Evt.ZoneEntered (com metadata do catalog).
;
;   - Evt.RunStarted:
;       1. Zera _totals (run nova comeca do zero)
;       2. _runActive = true
;       3. Se _activeZone != "": _startMs = NowMs() (jogador ja estava
;          numa zona quando run iniciou, comeca a contar agora)
;
;   - Evt.RunReset / Evt.RunCancelled:
;       Zera tudo (_totals, _activeZone, _startMs); _runActive=false
;
;   - Evt.RunCompleted:
;       Flush ultimo zone (preserva _totals pro plot final); _runActive=false
;
; INTERACAO COM TIMER:
;   - TimerPaused: fecha zona ativa (soma tempo ate o pause). A zona
;     "logica" continua ativa, mas _startMs zera. Quando timer resume,
;     _startMs eh redefinido.
;   - TimerResumed: reabre tracking da zona ativa (_startMs=NowMs).
;   - TimerStopped: fecha sem somar (run encerrada — tempo orfao).
;     Mantem _activeZone pro caso de TimerStop ser apenas mecanico
;     (run ainda nao formalmente cancelada).
;
; CONSULTAS PARA WIDGETS:
;   GetActiveZone()           => string (zona atualmente sendo tracked)
;   GetActiveElapsedMs()      => Int (tempo desde entrada na ativa)
;   GetZoneTotal(zoneName)    => Int (acumulado historico da zona)
;   GetZoneTotalWithActive(zoneName) => Int (historico + elapsed atual)
;   GetTotals()               => Map<zoneName, totalMs> (copia defensiva)
;   GetTotalsForSnapshot()    => Map (copia + soma elapsed da zona ativa)
;   GetTownTotalsByAct()      => Map<actIndex, totalMs> (filtrado is_town)
;   GetTotalTownMs()          => Int (soma total de town inc. zona ativa)
;   GetActTotals()            => Map<actIndex, totalMs> (todas zonas do ato)
;   GetTotalRunMs()           => Int (sum de tudo)
;   IsRunActive()             => bool (true entre RunStarted e RunEnded)
;
; PERSISTENCIA:
;   _totals eh persistido pelo composition root via RunStateRepository
;   (section [RunZoneTotals] no INI). Salvo a cada ~5s e no shutdown.
;   No boot, o composition root chama Hydrate(runState.LoadZoneTotals())
;   pra restaurar tempo da run em andamento entre sessoes/crashes.
;
;   Pra capturar o tempo em curso da zona ativa (que ainda nao foi
;   flushed), use GetTotalsForSnapshot() em vez de GetTotals().
;
; CONSTRUCAO:
;   svc := ZoneTrackingService(bus, clock, catalog)
;
; NOTA SOBRE NOME DO PARAMETRO:
;   AHK v2 faz lookup case-insensitive de variaveis. Se nomeassemos
;   o param `zonesCatalog`, ele colidiria case-insensitive com a classe
;   `ZonesCatalog` no operando direito de `is`, e a checagem viraria
;   "instancia is instancia" (falha com "Expected a Class but got a
;   ZonesCatalog"). Por isso `catalog` — case-insensitive-distinto.


class ZoneTrackingService
{
    _bus     := ""
    _clock   := ""
    _catalog := ""    ; ZonesCatalog (pode ser "" se nao houver)

    _activeZone := ""
    _startMs    := 0
    _totals     := ""    ; Map<zoneName, totalMs>
    _runActive  := false

    _handlerZoneChanged   := ""
    _handlerTimerPaused   := ""
    _handlerTimerResumed  := ""
    _handlerTimerStopped  := ""
    _handlerRunStarted    := ""
    _handlerRunReset      := ""
    _handlerRunCancelled  := ""
    _handlerRunCompleted  := ""

    __New(bus, clock, catalog := "")
    {
        if !(bus is EventBus)
            throw TypeError("ZoneTrackingService: 'bus' deve ser EventBus")
        if !IsObject(clock) || !clock.HasMethod("NowMs")
            throw TypeError("ZoneTrackingService: 'clock' deve implementar NowMs()")
        ; catalog eh opcional (pra testes / boot sem CSV).
        if (catalog != "" && !(catalog is ZonesCatalog))
            throw TypeError("ZoneTrackingService: 'catalog' deve ser ZonesCatalog ou vazio")

        this._bus     := bus
        this._clock   := clock
        this._catalog := catalog
        this._totals  := Map()

        this._handlerZoneChanged   := (data) => this._OnZoneChanged(data)
        this._handlerTimerPaused   := (data) => this._OnTimerPaused(data)
        this._handlerTimerResumed  := (data) => this._OnTimerResumed(data)
        this._handlerTimerStopped  := (data) => this._OnTimerStopped(data)
        this._handlerRunStarted    := (data) => this._OnRunStarted(data)
        this._handlerRunReset      := (data) => this._OnRunEnded(data)
        this._handlerRunCancelled  := (data) => this._OnRunEnded(data)
        this._handlerRunCompleted  := (data) => this._OnRunCompleted(data)

        bus.Subscribe(Events.ZoneChanged,  this._handlerZoneChanged)
        bus.Subscribe(Events.TimerPaused,  this._handlerTimerPaused)
        bus.Subscribe(Events.TimerResumed, this._handlerTimerResumed)
        bus.Subscribe(Events.TimerStopped, this._handlerTimerStopped)
        bus.Subscribe(Events.RunStarted,   this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,     this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled, this._handlerRunCancelled)
        bus.Subscribe(Events.RunCompleted, this._handlerRunCompleted)
    }

    Dispose()
    {
        if (this._handlerZoneChanged != "")
        {
            this._bus.Unsubscribe(Events.ZoneChanged, this._handlerZoneChanged)
            this._handlerZoneChanged := ""
        }
        if (this._handlerTimerPaused != "")
        {
            this._bus.Unsubscribe(Events.TimerPaused, this._handlerTimerPaused)
            this._handlerTimerPaused := ""
        }
        if (this._handlerTimerResumed != "")
        {
            this._bus.Unsubscribe(Events.TimerResumed, this._handlerTimerResumed)
            this._handlerTimerResumed := ""
        }
        if (this._handlerTimerStopped != "")
        {
            this._bus.Unsubscribe(Events.TimerStopped, this._handlerTimerStopped)
            this._handlerTimerStopped := ""
        }
        if (this._handlerRunStarted != "")
        {
            this._bus.Unsubscribe(Events.RunStarted, this._handlerRunStarted)
            this._handlerRunStarted := ""
        }
        if (this._handlerRunReset != "")
        {
            this._bus.Unsubscribe(Events.RunReset, this._handlerRunReset)
            this._handlerRunReset := ""
        }
        if (this._handlerRunCancelled != "")
        {
            this._bus.Unsubscribe(Events.RunCancelled, this._handlerRunCancelled)
            this._handlerRunCancelled := ""
        }
        if (this._handlerRunCompleted != "")
        {
            this._bus.Unsubscribe(Events.RunCompleted, this._handlerRunCompleted)
            this._handlerRunCompleted := ""
        }
    }

    ; ============================================================
    ; Hydrate - restaura state vindo do disco (crash recovery)
    ;
    ; Chamado pelo composition root no boot, ANTES de RunStarted ser
    ; (re)publicado. Se houver run em andamento no disco, o RunService
    ; tambem foi hidratado e _runActive sera setado quando RunStarted
    ; disparar — ou marcado manualmente via SetRunActive(true).
    ;
    ; Importante: NAO ativa cronometragem da zona ativa atual aqui (sem
    ; ZoneChanged conhecida, _activeZone fica vazio). O LogMonitor seed
    ; reemite o ultimo ZoneChanged no boot pra repopular esse state.
    ; ============================================================
    Hydrate(zoneTotalsMap)
    {
        if !(zoneTotalsMap is Map)
            throw TypeError("ZoneTrackingService.Hydrate: 'zoneTotalsMap' deve ser Map")
        clean := Map()
        for k, v in zoneTotalsMap
            clean[k] := v
        this._totals    := clean
        this._activeZone := ""
        this._startMs    := 0
    }

    ; ============================================================
    ; SetRunActive - manualmente seta _runActive
    ;
    ; Usado pelo composition root no boot quando o RunService foi
    ; hidratado com run em andamento (status=running) e o evento
    ; RunStarted NAO sera re-publicado. Sem isso, o service ficaria
    ; "preso" em _runActive=false ate proximo RunStarted manual.
    ; ============================================================
    SetRunActive(active)
    {
        this._runActive := !!active
        ; Se ativando e ja ha zona conhecida, comeca cronometro
        if (this._runActive && this._activeZone != "" && this._startMs = 0)
            this._startMs := this._clock.NowMs()
    }

    ; ============================================================
    ; Queries publicas
    ; ============================================================

    GetActiveZone()    => this._activeZone
    GetActiveElapsedMs()
    {
        if (this._activeZone = "" || this._startMs = 0)
            return 0
        return Max(0, this._clock.NowMs() - this._startMs)
    }
    IsActive()     => this._activeZone != "" && this._startMs > 0
    IsRunActive()  => this._runActive

    GetZoneTotal(zoneName)
    {
        if (zoneName = "")
            return 0
        return this._totals.Has(zoneName) ? this._totals[zoneName] : 0
    }

    ; Total atual da zona ativa = historico acumulado + elapsed em curso.
    ; Util pra widgets exibirem o "tempo na zona atual" mesmo se voltou
    ; depois de ter saido.
    GetZoneTotalWithActive(zoneName)
    {
        base := this.GetZoneTotal(zoneName)
        if (zoneName = this._activeZone)
            base += this.GetActiveElapsedMs()
        return base
    }

    GetTotals()
    {
        out := Map()
        for k, v in this._totals
            out[k] := v
        return out
    }

    ; ============================================================
    ; GetTotalsForSnapshot - copia de _totals + elapsed da zona ATIVA
    ;
    ; Diferente de GetTotals(), esta inclui o tempo em curso da zona
    ; ativa (que ainda nao foi flushed em _totals). Usado pelo
    ; composition root pra persistir a cada ~5s no disco — garante
    ; que mesmo o tempo "em andamento" eh preservado.
    ;
    ; Nao modifica state interno (nao faz flush, nao reseta _startMs).
    ; ============================================================
    GetTotalsForSnapshot()
    {
        out := Map()
        for k, v in this._totals
            out[k] := v
        if this.IsActive()
        {
            elapsed := this.GetActiveElapsedMs()
            if (elapsed > 0)
            {
                current := out.Has(this._activeZone) ? out[this._activeZone] : 0
                out[this._activeZone] := current + elapsed
            }
        }
        return out
    }

    ; Totais agregados por ato (consulta ZonesCatalog pra mapear).
    ; Inclui apenas zonas conhecidas (lookup via FindByName).
    GetActTotals()
    {
        out := Map()
        if !IsObject(this._catalog)
            return out
        for zoneName, ms in this._totals
        {
            entry := this._catalog.FindByName(zoneName)
            if !IsObject(entry)
                continue
            act := entry.act
            current := out.Has(act) ? out[act] : 0
            out[act] := current + ms
        }
        return out
    }

    ; Totais de TOWN apenas, agregados por ato. Substitui o
    ; GetTownTotals() do legado TownVisitTracker.
    GetTownTotalsByAct()
    {
        out := Map()
        if !IsObject(this._catalog)
            return out
        for zoneName, ms in this._totals
        {
            entry := this._catalog.FindByName(zoneName)
            if !IsObject(entry) || !entry.isTown
                continue
            act := entry.act
            current := out.Has(act) ? out[act] : 0
            out[act] := current + ms
        }
        return out
    }

    ; ============================================================
    ; GetTotalTownMs - soma todo tempo gasto em zonas town na run.
    ;
    ; Inclui zonas town FECHADAS (em _totals) + elapsed da zona ATIVA
    ; se ela for town. Equivalente ao GetTotalRunTownMs() do legado
    ; TownVisitTracker.
    ;
    ; Usado pelo CompactLayoutWidget pra renderizar a stacked bar
    ; (Mapa / Loading / Cidade) em tempo real durante a run.
    ;
    ; Retorna 0 se nao houver catalog (sem como classificar town).
    ; ============================================================
    GetTotalTownMs()
    {
        if !IsObject(this._catalog)
            return 0

        total := 0
        for zoneName, ms in this._totals
        {
            entry := this._catalog.FindByName(zoneName)
            if IsObject(entry) && entry.isTown
                total += ms
        }

        ; Adiciona elapsed da zona ATIVA se for town (ainda nao foi
        ; flushed em _totals — tempo "em curso").
        if this.IsActive()
        {
            entry := this._catalog.FindByName(this._activeZone)
            if IsObject(entry) && entry.isTown
                total += this.GetActiveElapsedMs()
        }

        return total
    }

    GetTotalRunMs()
    {
        total := 0
        for _, ms in this._totals
            total += ms
        if this.IsActive()
            total += this.GetActiveElapsedMs()
        return total
    }

    ; ============================================================
    ; Reset - zera state interno (totals + zona ativa + flags)
    ;   Publica nada. Util externamente em testes; internamente os
    ;   handlers de Run lifecycle controlam os flags com semantica
    ;   especifica (ver _OnRunStarted / _OnRunEnded).
    ; ============================================================

    Reset()
    {
        this._activeZone := ""
        this._startMs    := 0
        this._totals     := Map()
        this._runActive  := false
    }

    ; ============================================================
    ; Handlers privados
    ; ============================================================

    _OnZoneChanged(data)
    {
        if !IsObject(data) || !data.Has("zoneName")
            return
        newZone := data["zoneName"]
        if (newZone = "")
            return

        ; Fecha zona anterior (se estava sendo cronometrada) somando elapsed.
        ; _FlushActive eh no-op quando _startMs=0 (zona registrada sem cronometro).
        this._FlushActive()

        ; Abre nova
        this._activeZone := newZone
        ; Conta tempo somente se run ativa. Caso contrario, mantem a zona
        ; registrada (pra display) com cronometro parado.
        this._startMs := this._runActive ? this._clock.NowMs() : 0

        ; Publica evento enriquecido com metadata do catalog
        actIdx := 0
        isTown := false
        if IsObject(this._catalog)
        {
            entry := this._catalog.FindByName(newZone)
            if IsObject(entry)
            {
                actIdx := entry.act
                isTown := entry.isTown
            }
        }

        this._bus.Publish(Events.ZoneEntered, Map(
            "zoneName", newZone,
            "actIndex", actIdx,
            "isTown",   isTown,
            "enteredAt", this._startMs
        ))
    }

    _OnTimerPaused(data)
    {
        ; Fecha zona ativa (acumula tempo ate o pause). Apos resume,
        ; a zona ativa atual eh "reaberta" no _OnTimerResumed.
        ; Param true = keepActive (preserva _activeZone, so zera _startMs).
        this._FlushActive(true)
    }

    _OnTimerResumed(data)
    {
        ; Reseta startMs da zona atual (se houver) pra contar de
        ; agora em diante. Tempo durante o pause nao foi contado.
        if (this._activeZone != "" && this._runActive)
            this._startMs := this._clock.NowMs()
    }

    _OnTimerStopped(data)
    {
        ; v17.15 (Bug #1): faz FLUSH antes de zerar _startMs.
        ;
        ; Antes: _startMs := 0 sem flush. Resultado: FinalizeRun ->
        ; timer.Stop -> TimerStopped (zera _startMs) -> RunCompleted
        ; -> _OnRunCompleted chamava _FlushActive() mas ja era no-op
        ; (_startMs=0). O tempo da zona desde o ultimo ZoneChanged
        ; era perdido em TODAS as runs finalizadas.
        ;
        ; Agora: _FlushActive(true) commita o elapsed em _totals antes
        ; de zerar _startMs. keepActive=true preserva _activeZone
        ; (jogador continua na zona; futura RunStarted reabrira tracking).
        this._FlushActive(true)
    }

    _OnRunStarted(data)
    {
        ; Nova run: zera totals, marca runActive.
        ; Se ja ha zona registrada (do seed ou ZoneChanged anterior),
        ; comeca a contar a partir de agora.
        this._totals := Map()
        this._runActive := true
        if (this._activeZone != "")
            this._startMs := this._clock.NowMs()
    }

    _OnRunEnded(data)
    {
        ; RunReset / RunCancelled: zera tudo (state limpo, _runActive=false).
        ; _activeZone limpo tambem pra que proxima RunStarted exija
        ; uma nova ZoneChanged (ou exigir entrada do jogador num novo
        ; mapa) antes de contar tempo. Comportamento pratico: ao cancelar
        ; uma run, o tracker fica em estado completamente idle.
        this._totals := Map()
        this._activeZone := ""
        this._startMs := 0
        this._runActive := false
    }

    _OnRunCompleted(data)
    {
        ; Antes de zerar, fecha a zona ativa pra capturar tempo final.
        ; Composition root deve usar GetTotals() entre Evt.RunCompleted
        ; e o Reset que ocorre logo apos.
        this._FlushActive()
        this._runActive := false
        ; Nao zera _totals — outros subscribers (RunStatsPlotDialog)
        ; consultam GetTotals() durante o ciclo de RunCompleted pra
        ; montar o plot final. Proxima RunStarted limpa via _OnRunStarted.
    }

    ; ============================================================
    ; _FlushActive — fecha a zona ativa, acumula elapsed em _totals.
    ;
    ;   No-op se _startMs=0 (zona "registrada mas nao cronometrada",
    ;   ex: estado pre-run).
    ;
    ;   keepActive=true: nao reseta _activeZone (so zera _startMs).
    ;     Usado em TimerPaused — a zona "logica" continua ativa, mas
    ;     o timer parou. Quando timer resume, _startMs eh redefinido.
    ; ============================================================
    _FlushActive(keepActive := false)
    {
        if (this._activeZone = "" || this._startMs = 0)
            return

        elapsed := Max(0, this._clock.NowMs() - this._startMs)
        if (elapsed > 0)
        {
            zone := this._activeZone
            current := this._totals.Has(zone) ? this._totals[zone] : 0
            this._totals[zone] := current + elapsed

            this._bus.Publish(Events.ZoneTimeAccumulated, Map(
                "zoneName",   zone,
                "durationMs", elapsed,
                "totalMs",    this._totals[zone]
            ))
        }

        this._startMs := 0
        if !keepActive
            this._activeZone := ""
    }
}

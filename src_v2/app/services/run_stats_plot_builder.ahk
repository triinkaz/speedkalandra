; ============================================================
; RunStatsPlotBuilder - agrega snapshot de run em Map renderizavel
; ============================================================
;
; VERSAO POS-DEMOLICAO (Onda 5):
;   - Sem RunRepository / LoadingRepository (sem persistencia historica).
;   - Recebe dados via Map snapshot e os agrega em totals + details.
;   - Categorias zerada-up: mapa / cidade / loading / morte.
;   - Sem transitionMs (era step-based, removido).
;   - Categoria boss REMOVIDA em v17.13 (boss tracking saiu da app).
;
; FONTE DE DADOS (snapshot):
;   Map(
;     "runId":         "20260512_1423",
;     "profile":       "Default",
;     "patch":         "0.4",
;     "firstTs":       "2026-05-12 14:23:45",
;     "runDurationMs": 5040000,
;     "zoneTotals":    Map<zoneName, totalMs>,        ; ZoneTrackingService.GetTotals()
;     "loadingEvents": Array< Map{fromZone,toZone,durationMs,ts} >,
;     "deathCount":    int
;   )
;
; CATEGORIAS:
;   mapa     - tempo agregado de zonas com isTown=false
;   cidade   - tempo agregado de zonas com isTown=true
;   loading  - soma de durationMs de todos os loadingEvents
;   morte    - deathCount * deathPenaltyMs (cfg)
;
; OUTPUT (Map):
;   runId         (string)
;   profile       (string)
;   patch         (string)
;   firstTs       (string)
;   totals        (Map<key, ms>)
;   details       (Array<Map>)    {category, categoryLabel, label, ms, note, timestamp}
;   deathCount    (int)
;   totalMs       (int)
;   maxActReached (int)            ; v17.13 — maior numero de ato visitado na run
;                                  ; (derivado dos `note` dos details). Usado pelo
;                                  ; filtro "Min Ato" no plot dialog.
;
; CONSTRUCAO:
;   builder := RunStatsPlotBuilder(catalog, cfg)
;   data := builder.Build(snapshot)
;
; NOTA SOBRE NOME DO PARAMETRO:
;   AHK v2 faz lookup case-insensitive de variaveis. Param `zonesCatalog`
;   colidiria com a classe `ZonesCatalog` no operando direito de `is`
;   (falha com "Expected a Class but got a ZonesCatalog"). Por isso
;   `catalog` — case-insensitive-distinto.


class RunStatsPlotBuilder
{
    _zonesCatalog := ""    ; ZonesCatalog ou ""
    _settings     := ""    ; AppSettings

    static SEGMENT_KEYS := ["mapa", "cidade", "loading", "morte"]

    __New(catalog, cfg)
    {
        if (catalog != "" && !(catalog is ZonesCatalog))
            throw TypeError("RunStatsPlotBuilder: 'catalog' deve ser ZonesCatalog ou vazio")
        if !(cfg is AppSettings)
            throw TypeError("RunStatsPlotBuilder: 'cfg' deve ser AppSettings")
        this._zonesCatalog := catalog
        this._settings     := cfg
    }

    ; ============================================================
    ; Definicoes de categoria (paridade visual com legado)
    ; ============================================================
    static SegmentDefinitions()
    {
        return [
            Map("key", "mapa",    "label", "Map",     "color", "38BDF8"),
            Map("key", "cidade",  "label", "Town",    "color", "A78BFA"),
            Map("key", "loading", "label", "Loading", "color", "FACC15"),
            Map("key", "morte",   "label", "Deaths",  "color", "EF4444")
        ]
    }

    static CategoryLabel(category)
    {
        for _, seg in RunStatsPlotBuilder.SegmentDefinitions()
            if (seg["key"] = category)
                return seg["label"]
        return "All"
    }

    static CategoryColor(category)
    {
        for _, seg in RunStatsPlotBuilder.SegmentDefinitions()
            if (seg["key"] = category)
                return seg["color"]
        return ""
    }

    ; ============================================================
    ; Build(snapshot) -> Map
    ; ============================================================
    Build(snapshot)
    {
        data := this._InitData(snapshot)
        if !IsObject(snapshot)
            return data

        this._AddZoneDetails(data, snapshot)
        this._AddLoadingDetails(data, snapshot)
        this._AddDeathDetails(data, snapshot)

        data["totalMs"] := RunStatsPlotBuilder._TotalFromTotals(data["totals"])
        data["maxActReached"] := RunStatsPlotBuilder._DeriveMaxAct(data["details"])
        return data
    }

    ; Deriva ato MAX alcancado dos details. Itera notes procurando
    ; pattern "Ato N" ou "Act N" (compat com runs salvas em v17.13 ou
    ; anteriores que usavam "Ato") e retorna o maior N. 0 se nao achar.
    ;
    ; v17.13: usado pelo dialog pra filtrar runs comparaveis no chart.
    static _DeriveMaxAct(details)
    {
        if !IsObject(details)
            return 0
        maxAct := 0
        for _, d in details
        {
            if !IsObject(d)
                continue
            note := d.Has("note") ? d["note"] : ""
            if !RegExMatch(note, "(?:Ato|Act)\s+(\d+)", &m)
                continue
            n := Integer(m[1] + 0)
            if (n > maxAct)
                maxAct := n
        }
        return maxAct
    }

    ; ============================================================
    ; Init
    ; ============================================================
    _InitData(snapshot)
    {
        totals := Map()
        for _, key in RunStatsPlotBuilder.SEGMENT_KEYS
            totals[key] := 0

        ; v0.1.0: `runId` local colide case-insensitively com classe `RunId`
        ; (#Warn LocalSameAsGlobal). Mesma resolucao adotada em outros lugares
        ; do projeto: usar `currentRunId`.
        currentRunId := IsObject(snapshot) && snapshot.Has("runId")      ? snapshot["runId"]      : ""
        profile      := IsObject(snapshot) && snapshot.Has("profile")    ? snapshot["profile"]    : ""
        patch        := IsObject(snapshot) && snapshot.Has("patch")      ? snapshot["patch"]      : ""
        firstTs      := IsObject(snapshot) && snapshot.Has("firstTs")    ? snapshot["firstTs"]    : ""
        deathCount   := IsObject(snapshot) && snapshot.Has("deathCount") ? snapshot["deathCount"] : 0

        ; Defaults dos settings se nao vieram no snapshot
        if (profile = "")
            profile := this._settings.profileName
        if (patch = "")
            patch := this._settings.gamePatch

        return Map(
            "runId",         String(currentRunId),
            "profile",       String(profile),
            "patch",         String(patch),
            "firstTs",       String(firstTs),
            "totals",        totals,
            "details",       [],
            "deathCount",    Integer(deathCount),
            "totalMs",       0,
            "maxActReached", 0
        )
    }

    ; ============================================================
    ; _AddZoneDetails - itera zoneTotals; categoriza por isTown
    ; ============================================================
    _AddZoneDetails(data, snapshot)
    {
        if !snapshot.Has("zoneTotals") || !IsObject(snapshot["zoneTotals"])
            return
        for zoneName, ms in snapshot["zoneTotals"]
        {
            if (ms <= 0)
                continue
            ; Categoriza via ZonesCatalog (fallback: trata como mapa)
            category := "mapa"
            act := 0
            if IsObject(this._zonesCatalog)
            {
                entry := this._zonesCatalog.FindByName(zoneName)
                if IsObject(entry)
                {
                    category := entry.isTown ? "cidade" : "mapa"
                    act := entry.act
                }
            }
            note := act > 0 ? "Act " act : ""
            this._AddDetail(data, category, zoneName, ms, note, "")
        }
    }

    ; ============================================================
    ; _AddLoadingDetails - itera loadingEvents
    ; ============================================================
    _AddLoadingDetails(data, snapshot)
    {
        if !snapshot.Has("loadingEvents") || !IsObject(snapshot["loadingEvents"])
            return
        for _, ev in snapshot["loadingEvents"]
        {
            if !IsObject(ev)
                continue
            ms := ev.Has("durationMs") ? ev["durationMs"] : 0
            if (ms <= 0)
                continue

            fromZ := ev.Has("fromZone") ? ev["fromZone"] : ""
            toZ   := ev.Has("toZone")   ? ev["toZone"]   : ""
            label := "Loading"
            if (fromZ != "" || toZ != "")
            {
                f := fromZ != "" ? fromZ : "?"
                t := toZ   != "" ? toZ   : "?"
                label := f " -> " t
            }
            ts := ev.Has("ts") ? ev["ts"] : (ev.Has("timestamp") ? ev["timestamp"] : "")
            this._AddDetail(data, "loading", label, ms, "", ts)
            this._RememberMetaTs(data, ts)
        }
    }

    ; ============================================================
    ; _AddDeathDetails - usa snapshot.deathCount * cfg.deathPenaltyMs
    ;
    ; v17.15.1: respeita cfg.deathPenaltyEnabled. Se desabilitado,
    ; mortes aparecem em deathCount mas nao adicionam barra no plot.
    ; ============================================================
    _AddDeathDetails(data, snapshot)
    {
        count := data["deathCount"]
        if (count <= 0)
            return
        if !this._settings.deathPenaltyEnabled
            return
        penalty := this._settings.deathPenaltyMs
        ; Soma como uma entrada agregada -- detalhes por morte ficam fora
        ; do plot simplificado. Composition root pode adicionar mais detalhe
        ; se passar deathEvents no snapshot futuramente.
        this._AddDetail(data, "morte", count " deaths",
            count * penalty, "Penalty " RunStatsPlotBuilder._FormatMs(penalty) " each", "")
    }

    ; ============================================================
    ; _AddDetail
    ; ============================================================
    _AddDetail(data, category, label, ms, note := "", timestamp := "")
    {
        n := RunStatsPlotBuilder._ToInt(ms)
        if (n < 0)
            n := 0
        if !data["totals"].Has(category)
            data["totals"][category] := 0
        data["totals"][category] += n
        data["details"].Push(Map(
            "category",      category,
            "categoryLabel", RunStatsPlotBuilder.CategoryLabel(category),
            "label",         label,
            "ms",            n,
            "note",          note,
            "timestamp",     timestamp
        ))
    }

    _RememberMetaTs(data, ts)
    {
        if (ts = "")
            return
        if (data["firstTs"] = "" || StrCompare(ts, data["firstTs"]) < 0)
            data["firstTs"] := ts
    }

    ; ============================================================
    ; Static helpers
    ; ============================================================
    static _ToInt(v)
    {
        n := 0
        try
            n := Integer(v + 0)
        catch
            n := 0
        return n
    }

    static _TotalFromTotals(totals)
    {
        total := 0
        for _, ms in totals
            total += RunStatsPlotBuilder._ToInt(ms)
        return total
    }

    static FormatMs(ms) => Duration.FormatMs(ms)

    ; v0.1.2 (auditoria #19): _FormatMs consolidado em Duration.FormatMs.
    ; Mantido como alias static interno pra retrocompat dos call sites
    ; deste arquivo (incluindo _AddDeathDetails que passa penalty).
    static _FormatMs(ms) => Duration.FormatMs(ms)
}

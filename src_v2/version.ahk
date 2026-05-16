; ============================================================
; Version - constante global de versao do SpeedKalandra
; ============================================================
;
; v17.15 (Bug #30): introduzido pra dar surface ao numero de versao.
;
; v0.1.0 (primeira release publica): adotada SemVer pra versionamento
; externo. Pre-1.0 sinaliza "funcional mas ainda evoluindo, sem
; compromisso de estabilidade de API". Combina com o disclaimer.
;
; v0.1.1: Bug #2 (TextEncoding) - API ConvertUtf16ToUtf8 e
;   MigrateIniToUtf8 removidas (quebravam IniRead em UTF-8 BOM).
;
; v0.1.2: Bug #5 (LoadingDetectionService) - timeouts agora publicam
;   LoadingMeasured com duracao real (antes eram descartados pelo
;   filtro `> maxMs`, causando loading-time subestimado em PCs lentos).
;   Tambem #19 (Duration.FormatMs consolidacao), #26 (log multi-linha
;   hygiene), #30 (version embed em 3 superficies UI).
;
; v0.1.3: 4 features de UX:
;   1. Setup dialog do Client.txt na primeira execucao (app nao roda
;      sem path valido).
;   2. Fix bug visual no Edit do Settings (altura fixa h22 pra evitar
;      auto-expansao quando o path eh longo).
;   3. Death penalty agora aplica no timer real-time (antes so aparecia
;      no plot post-finalize). Novo TimerService.AddPenaltyMs(ms) +
;      handler _OnDeathApplyTimerPenalty subscrito a Evt.DeathDetected.
;   4. Removido campo Patch do Settings dialog (mantido internamente
;      como cfg.gamePatch="Unknown" pra retrocompat com runs antigas).
;   +19 tests novos (13 unit TimerService.AddPenaltyMs + 6 integration
;   do handler), suite total ~1557 verdes.
;
; Tags internas no codigo (v17.15.x) sao historicas e ficam pra
; rastreabilidade de mudancas — nao sao usadas em release publica.
;
; Onde aparece:
;   - Tray tooltip (A_IconTip em speedkalandra.ahk)
;   - Settings dialog (titulo da janela)
;   - Plot da run (footer)
;
; ATUALIZACAO MANUAL:
;   Antes de cada release, bumpa STRING aqui. Nao ha automacao no
;   build script ainda.
;
;   SemVer: MAJOR.MINOR.PATCH
;     - PATCH (0.1.0 -> 0.1.1): bug fixes que nao adicionam features
;     - MINOR (0.1.0 -> 0.2.0): features novas, backward-compatible
;     - MAJOR (0.x -> 1.0): primeiro release "estavel". Depois disso,
;       bumpa MAJOR so quando quebra compat de algo publico.

class Version
{
    static STRING := "v0.1.3"
}

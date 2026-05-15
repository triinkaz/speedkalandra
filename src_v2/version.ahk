; ============================================================
; Version - constante global de versao do SpeedKalandra
; ============================================================
;
; v17.15 (Bug #30): introduzido pra dar surface ao numero de versao.
;
; v0.1.0 (primeira release publica): adotada SemVer pra versionamento
; externo. Pre-1.0 sinaliza "funcional mas ainda evoluindo, sem
; compromisso de estabilidade de API". Combina com o disclaimer.
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
    static STRING := "v0.1.0"
}

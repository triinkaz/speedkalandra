; ============================================================
; Theme — paleta de cores e fontes do overlay
; ============================================================
;
; Centraliza as constantes visuais usadas por todos os widgets:
;   - Cores hex (sem '#') compatíveis com AHK Gui SetFont/Background.
;   - Fontes padrão (UI vs monospace para timers).
;   - Helper Size(scale, baseSize) que arredonda para inteiro >= 1.
;
; Uso:
;   Theme.Color("text")        ; -> "E8E8EB"
;   Theme.Size(scale, 18)       ; -> Round(18 * scale), mínimo 1
;   wg.SetFont("s10 c" Theme.Color("text") " bold", Theme.FONT_UI)
;
; Por que estática?
;   Sem state. Mesmo conjunto de cores em toda a aplicação. Uma
;   eventual mudança de tema (claro/escuro) far-se-ia trocando a
;   classe inteira ou tendo Theme.SetPalette("dark") — fora de escopo
;   pra Fase 6.1.
;
; Por que erro em Color desconhecida?
;   Strict por design. Typos em nome de cor estouram cedo, na
;   construção do widget, em vez de produzir cor "default" silenciosa.


class Theme
{
    static FONT_UI   := "Segoe UI"
    static FONT_MONO := "Consolas"

    ; Mapa de cores hex (sem '#'). Usar via Theme.Color(name).
    ;
    ; Paleta dividida em 2 grupos:
    ;
    ; (B) Tema KALANDRA — PALETA OFICIAL DA V2:
    ;     surface/surface2/surface3/line/muted/subtle/accent/accentSoft/
    ;     good/warn/danger/steel
    ;
    ;     Caracteristicas: bg quase preto (050506), surfaces com tom
    ;     levemente azulado, accent laranja queimado D8492F. Usado
    ;     por todos os widgets soltos (TimerWidget, ZoneWidget, etc),
    ;     LayoutWidgets (Normal/Compact/Micro) e dialogs principais.
    ;
    ; (A) Aliases LEGACY (DEPRECATED — backwards-compat apenas):
    ;     bg/headerBg/border/inputBg/text/textDim/textFaint/green/red/
    ;     amber/purple/blue
    ;
    ;     Os values ja estao alinhados com Kalandra (mesmos hex).
    ;     Mantidos pra nao quebrar dialogs antigos (gem_planner_dialog,
    ;     campaign_editor, plot_metrics, etc) que ainda usam esses nomes.
    ;     Em codigo NOVO, prefira nomes Kalandra:
    ;       headerBg  -> surface2
    ;       border    -> line
    ;       inputBg   -> surface3
    ;       textDim   -> muted
    ;       textFaint -> subtle
    ;       amber     -> warn
    ;       green     -> good
    ;       red       -> danger
    ;       purple    -> accentSoft
    static _COLORS := Map(
        ; --- (A) Aliases LEGACY (deprecated; mantidos pra back-compat) ---
        "bg",         "050506",   ; (== Kalandra bg implicito — BackColor de Guis)
        "headerBg",   "15181B",   ; alias — use "surface2"
        "border",     "3A3330",   ; alias — use "line"
        "inputBg",    "22252A",   ; alias — use "surface3"
        "text",       "E8E2D6",   ; (mesmo nome em ambas as paletas)
        "textDim",    "A49C91",   ; alias — use "muted"
        "textFaint",  "6E6962",   ; alias — use "subtle"
        "green",      "4ADE80",   ; alias deprecated — use "good" (B8C7B0)
        "red",        "EF4444",   ; alias deprecated — use "danger" (F87171)
        "amber",      "F59E0B",   ; alias — use "warn"
        "purple",     "A78BFA",   ; alias deprecated — use "accentSoft" (F07A3B)
        "blue",       "60A5FA",   ; (sem equivalente Kalandra; usado em raros lugares)

        ; --- (B) Tema Kalandra (paleta exata do legado) ---
        "surface",    "0D0F11",   ; banda principal (header, reward, drops, tips)
        "surface2",   "15181B",   ; banda secundaria (route, status)
        "surface3",   "22252A",   ; backgrounds escuros (progress bg, bandas decorativas)
        "line",       "3A3330",   ; bordas e separadores
        "muted",      "A49C91",   ; texto secundario
        "subtle",     "6E6962",   ; headers de bandas ("MAPA", "OBJETIVO")
        "accent",     "D8492F",   ; laranja queimado — progresso, divisores, accent stripes
        "accentSoft", "F07A3B",   ; laranja claro — buffs, XP
        "good",       "B8C7B0",   ; verde dessaturado — dentro do alvo
        "goodStrong", "4ADE80",   ; verde vibrante (v17.13) — pra destaques (timers PB)
        "warn",       "F59E0B",   ; ambar — atencao
        "danger",     "F87171",   ; vermelho dessaturado — alerta
        "steel",      "C8C0B4"    ; cinza claro — destaque suave
    )

    ; ============================================================
    ; Color(name) — retorna cor hex (sem '#').
    ;   Lança ValueError se nome desconhecido (strict).
    ; ============================================================
    static Color(name)
    {
        if !Theme._COLORS.Has(name)
            throw ValueError("Theme.Color: nome desconhecido: '" name "'")
        return Theme._COLORS[name]
    }

    ; HasColor(name) — true se nome registrado. Util para fallbacks.
    static HasColor(name) => Theme._COLORS.Has(name)

    ; ListColors() — retorna Array com todos os nomes de cor disponíveis.
    static ListColors()
    {
        out := []
        for k, _ in Theme._COLORS
            out.Push(k)
        return out
    }

    ; ============================================================
    ; InputStyle() — string de options compartilhada entre Edits/DropDowns
    ; em dialogs do tema escuro. Define Background (inputBg) + cor de
    ; texto explicita pra evitar branco-em-branco padrao do Windows.
    ;
    ; Uso:
    ;   g.SetFont(Theme.InputFont())
    ;   g.Add("Edit", "x10 y10 w200 " Theme.InputBg(), "")
    ;
    ; Separar Background (na option string) de cor de fonte (via SetFont)
    ; pq AHK v2 trata Background como prefixo da string de options e
    ; cor de fonte via SetFont "cRRGGBB".
    ; ============================================================
    static InputBg()   => "Background" Theme._COLORS["inputBg"]
    static InputFont() => "s9 c" Theme._COLORS["text"]

    ; ============================================================
    ; Size(scale, baseSize) — escalona pixels.
    ;   Arredonda para inteiro mais próximo, mínimo 1.
    ;   Lança ValueError se scale <= 0 ou não-numérico.
    ; ============================================================
    static Size(scale, baseSize)
    {
        if (!IsNumber(scale) || scale <= 0)
            throw ValueError("Theme.Size: 'scale' deve ser número positivo, recebi: " scale)
        if !IsNumber(baseSize)
            throw ValueError("Theme.Size: 'baseSize' deve ser número, recebi: " baseSize)
        n := Round(baseSize * scale)
        return n < 1 ? 1 : n
    }
}

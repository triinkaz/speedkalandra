; ============================================================
; Theme — overlay color palette and fonts
; ============================================================
;
; Centralizes the visual constants used by all widgets:
;   - Hex colors (no '#') compatible with AHK Gui SetFont/Background.
;   - Default fonts (UI vs. monospace for timers).
;   - Helper Size(scale, baseSize) that rounds to integer >= 1.
;
; Usage:
;   Theme.Color("text")        ; -> "E8E8EB"
;   Theme.Size(scale, 18)       ; -> Round(18 * scale), minimum 1
;   wg.SetFont("s10 c" Theme.Color("text") " bold", Theme.FONT_UI)
;
; Why static?
;   No state. Same color set across the entire application. An
;   eventual theme change (light/dark) would mean swapping the class
;   entirely or adding `Theme.SetPalette("dark")` — not in scope.
;
; Why error on unknown Color?
;   Strict by design. Color-name typos blow up early, at widget
;   construction, instead of producing a silent "default" color.


class Theme
{
    static FONT_UI   := "Segoe UI"
    static FONT_MONO := "Consolas"

    ; Hex color map (no '#'). Used via Theme.Color(name).
    ;
    ; Palette split into 2 groups:
    ;
    ; (B) KALANDRA theme — OFFICIAL PALETTE OF V2:
    ;     surface/surface2/surface3/line/muted/subtle/accent/accentSoft/
    ;     good/warn/danger/steel
    ;
    ;     Characteristics: near-black bg (050506), surfaces with a
    ;     slight bluish tint, burnt-orange accent D8492F. Used by
    ;     all loose widgets (TimerWidget, ZoneWidget, etc),
    ;     LayoutWidgets (Normal/Compact/Micro) and main dialogs.
    ;
    ; (A) LEGACY aliases (DEPRECATED — backwards-compat only):
    ;     bg/headerBg/border/inputBg/text/textDim/textFaint/green/red/
    ;     amber/purple/blue
    ;
    ;     The values are already aligned with Kalandra (same hex).
    ;     Kept so as not to break old dialogs (gem_planner_dialog,
    ;     campaign_editor, plot_metrics, etc.) that still use these
    ;     names. In NEW code, prefer Kalandra names:
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
        ; --- (A) LEGACY aliases (deprecated; kept for back-compat) ---
        "bg",         "050506",   ; (== implicit Kalandra bg — BackColor of Guis)
        "headerBg",   "15181B",   ; alias — use "surface2"
        "border",     "3A3330",   ; alias — use "line"
        "inputBg",    "22252A",   ; alias — use "surface3"
        "text",       "E8E2D6",   ; (same name in both palettes)
        "textDim",    "A49C91",   ; alias — use "muted"
        "textFaint",  "6E6962",   ; alias — use "subtle"
        "green",      "4ADE80",   ; deprecated alias — use "good" (B8C7B0)
        "red",        "EF4444",   ; deprecated alias — use "danger" (F87171)
        "amber",      "F59E0B",   ; alias — use "warn"
        "purple",     "A78BFA",   ; deprecated alias — use "accentSoft" (F07A3B)
        "blue",       "60A5FA",   ; (no Kalandra equivalent; used in a few rare places)

        ; --- (B) Kalandra theme (exact legacy palette) ---
        "surface",    "0D0F11",   ; main band (header, reward, drops, tips)
        "surface2",   "15181B",   ; secondary band (route, status)
        "surface3",   "22252A",   ; dark backgrounds (progress bg, decorative bands)
        "line",       "3A3330",   ; borders and separators
        "muted",      "A49C91",   ; secondary text
        "subtle",     "6E6962",   ; band headers ("MAP", "OBJECTIVE")
        "accent",     "D8492F",   ; burnt orange — progress, dividers, accent stripes
        "accentSoft", "F07A3B",   ; lighter orange — buffs, XP
        "good",       "B8C7B0",   ; desaturated green — within target
        "goodStrong", "4ADE80",   ; vibrant green -- for highlights (PB timers)
        "warn",       "F59E0B",   ; amber — attention
        "danger",     "F87171",   ; desaturated red — alert
        "steel",      "C8C0B4",   ; light gray — soft highlight

        ; --- Plus layouts: PB chip + distribution bar ---
        ; pb is its own color (teal) so the chip is distinguishable
        ; from the good/goodStrong timers that mark under-PB state.
        ; town shares the hex with the legacy `purple` by design —
        ; the two names are kept independent so a future restyle of
        ; one doesn't drag the other.
        "pb",         "2DD4BF",   ; teal — PB chips and PB sub-labels
        "map",        "38BDF8",   ; distribution bar: map time
        "loading",    "FACC15",   ; distribution bar: loading time
        "town",       "A78BFA"    ; distribution bar: town time
    )

    ; ============================================================
    ; Color(name) — returns hex color (no '#').
    ;   Throws ValueError on unknown name (strict).
    ; ============================================================
    static Color(name)
    {
        if !Theme._COLORS.Has(name)
            throw ValueError("Theme.Color: unknown name: '" name "'")
        return Theme._COLORS[name]
    }

    ; HasColor(name) — true if name is registered. Useful for fallbacks.
    static HasColor(name) => Theme._COLORS.Has(name)

    ; ListColors() — returns Array with all available color names.
    static ListColors()
    {
        out := []
        for k, _ in Theme._COLORS
            out.Push(k)
        return out
    }

    ; ============================================================
    ; InputStyle() — options string shared between Edits/DropDowns
    ; in dark-theme dialogs. Defines Background (inputBg) + explicit
    ; text color to avoid the Windows-default white-on-white.
    ;
    ; Usage:
    ;   g.SetFont(Theme.InputFont())
    ;   g.Add("Edit", "x10 y10 w200 " Theme.InputBg(), "")
    ;
    ; Separate Background (in the options string) from font color
    ; (via SetFont) because AHK v2 treats Background as a prefix in
    ; the options string and font color via SetFont "cRRGGBB".
    ; ============================================================
    static InputBg()   => "Background" Theme._COLORS["inputBg"]
    static InputFont() => "s9 c" Theme._COLORS["text"]

    ; ============================================================
    ; Size(scale, baseSize) — scales pixels.
    ;   Rounds to nearest integer, minimum 1.
    ;   Throws ValueError if scale <= 0 or non-numeric.
    ; ============================================================
    static Size(scale, baseSize)
    {
        if (!IsNumber(scale) || scale <= 0)
            throw ValueError("Theme.Size: 'scale' must be a positive number, got: " scale)
        if !IsNumber(baseSize)
            throw ValueError("Theme.Size: 'baseSize' must be a number, got: " baseSize)
        n := Round(baseSize * scale)
        return n < 1 ? 1 : n
    }
}

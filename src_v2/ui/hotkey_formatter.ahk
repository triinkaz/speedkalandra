; ============================================================
; HotkeyFormatter - converte hotkeys entre AHK syntax e human readable
; ============================================================
;
; MOTIVACAO (v0.1.0):
;   AHK usa simbolos pra modifiers no Hotkey():
;     ^ = Ctrl
;     ! = Alt
;     + = Shift
;     # = Win
;
;   Ex: "^!f" significa Ctrl+Alt+F. Pra usuario normal isso eh
;   hieroglifo. Esta classe traduz bidirecionalmente:
;
;     ToHuman("^!f")       -> "Ctrl+Alt+F"   (display no Settings)
;     ToAhk("Ctrl+Alt+F")  -> "^!f"          (persistencia no INI)
;
; ONDE EH USADO:
;   - SettingsDialog._BuildGui: popula Edit com ToHuman(cfg.GetHotkey(...))
;   - SettingsDialog._OnSave:   persiste com ToAhk(edit.Value)
;
; TOLERANCIAS DO ToAhk (input do usuario):
;   "Ctrl+Alt+F"       -> "^!f"
;   "ctrl+alt+f"       -> "^!f"    (case-insensitive)
;   "Ctrl + Alt + F"   -> "^!f"    (espacos OK)
;   "^!f"              -> "^!f"    (passthrough \u2014 power user)
;   "F8"               -> "F8"     (sem modifier)
;   ""                 -> ""       (sem hotkey, valido)
;
; TOLERANCIAS DO ToHuman (lendo do INI):
;   "^!f"              -> "Ctrl+Alt+F"
;   "F8"               -> "F8"
;   "RButton"          -> "RButton"  (passthrough, sem modifier prefix)
;
; NAO COBRE:
;   - Prefixos especiais ($, *, ~, <, >) sao raros e nao usados pelo
;     SpeedKalandra. Se aparecerem, ToHuman provavelmente fica
;     confuso \u2014 nao eh um caso suportado.


class HotkeyFormatter
{
    ; ------------------------------------------------------------
    ; ToHuman(ahkStr) - AHK syntax -> human readable
    ; ------------------------------------------------------------
    static ToHuman(ahkStr)
    {
        s := Trim(String(ahkStr))
        if (s = "")
            return ""

        parts := []

        ; Consome modifier symbols do inicio
        while (StrLen(s) > 0)
        {
            ch := SubStr(s, 1, 1)
            if (ch = "^")
                parts.Push("Ctrl")
            else if (ch = "!")
                parts.Push("Alt")
            else if (ch = "+")
                parts.Push("Shift")
            else if (ch = "#")
                parts.Push("Win")
            else
                break
            s := SubStr(s, 2)
        }

        ; Resto eh a "key"
        if (s != "")
            parts.Push(HotkeyFormatter._PrettifyKey(s))

        ; Join com "+"
        out := ""
        for i, p in parts
            out .= (i > 1 ? "+" : "") . p
        return out
    }

    ; ------------------------------------------------------------
    ; ToAhk(humanStr) - human readable -> AHK syntax
    ; ------------------------------------------------------------
    static ToAhk(humanStr)
    {
        s := Trim(String(humanStr))
        if (s = "")
            return ""

        ; Passthrough: se ja parece AHK syntax (comeca com ^ ! + #),
        ; nao tenta converter. Permite power user typar "^!f" direto.
        firstCh := SubStr(s, 1, 1)
        if (firstCh = "^" || firstCh = "!" || firstCh = "+" || firstCh = "#")
            return s

        ; Split por "+" e classifica cada token
        tokens := StrSplit(s, "+")
        modifiers := ""
        key := ""

        for _, token in tokens
        {
            t := Trim(token)
            if (t = "")
                continue
            tLower := StrLower(t)
            if (tLower = "ctrl" || tLower = "control")
                modifiers .= "^"
            else if (tLower = "alt")
                modifiers .= "!"
            else if (tLower = "shift")
                modifiers .= "+"
            else if (tLower = "win" || tLower = "lwin" || tLower = "rwin")
                modifiers .= "#"
            else
                key := t   ; ultimo nao-modifier vence (deve haver so 1)
        }

        if (key = "")
            return ""

        ; Normaliza a key pra convencao AHK
        ; Letra unica -> lowercase (a-z)
        if RegExMatch(key, "^[A-Za-z]$")
            key := StrLower(key)
        ; F-key (F1-F24) -> "F" + numero
        else if RegExMatch(key, "i)^f(\d+)$", &m)
            key := "F" m[1]
        ; Outros (Esc, Space, Tab, digits...) -> deixa como veio
        ; (AHK eh case-insensitive nesses casos)

        return modifiers . key
    }

    ; ------------------------------------------------------------
    ; _PrettifyKey - capitaliza a "key" raw pra display
    ; ------------------------------------------------------------
    static _PrettifyKey(key)
    {
        if (key = "")
            return ""
        ; Letra unica -> uppercase
        if RegExMatch(key, "^[a-zA-Z]$")
            return StrUpper(key)
        ; F-key
        if RegExMatch(key, "i)^f(\d+)$", &m)
            return "F" m[1]
        ; Numeros / digits -> as-is
        if RegExMatch(key, "^\d+$")
            return key
        ; Outros: capitaliza so a primeira letra (Esc, Space, Tab, etc)
        return StrUpper(SubStr(key, 1, 1)) . SubStr(key, 2)
    }
}

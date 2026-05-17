; ============================================================
; HotkeyFormatter - converts hotkeys between AHK syntax and human readable
; ============================================================
;
; MOTIVATION (v0.1.0):
;   AHK uses symbols for modifiers in Hotkey():
;     ^ = Ctrl
;     ! = Alt
;     + = Shift
;     # = Win
;
;   E.g.: "^!f" means Ctrl+Alt+F. To a normal user that's hieroglyphics.
;   This class translates bidirectionally:
;
;     ToHuman("^!f")       -> "Ctrl+Alt+F"   (display in Settings)
;     ToAhk("Ctrl+Alt+F")  -> "^!f"          (persistence to INI)
;
; WHERE IT'S USED:
;   - SettingsDialog._BuildGui: populates Edit with ToHuman(cfg.GetHotkey(...))
;   - SettingsDialog._OnSave:   persists with ToAhk(edit.Value)
;
; ToAhk INPUT TOLERANCES (user input):
;   "Ctrl+Alt+F"       -> "^!f"
;   "ctrl+alt+f"       -> "^!f"    (case-insensitive)
;   "Ctrl + Alt + F"   -> "^!f"    (spaces OK)
;   "^!f"              -> "^!f"    (passthrough — power user)
;   "F8"               -> "F8"     (no modifier)
;   ""                 -> ""       (no hotkey, valid)
;
; ToHuman TOLERANCES (reading from INI):
;   "^!f"              -> "Ctrl+Alt+F"
;   "F8"               -> "F8"
;   "RButton"          -> "RButton"  (passthrough, no modifier prefix)
;
; NOT COVERED:
;   - Special prefixes ($, *, ~, <, >) are rare and not used by
;     SpeedKalandra. If they appear, ToHuman will probably get confused —
;     this is not a supported case.


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

        ; Consume leading modifier symbols
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

        ; Remainder is the "key"
        if (s != "")
            parts.Push(HotkeyFormatter._PrettifyKey(s))

        ; Join with "+"
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

        ; Passthrough: if it already looks like AHK syntax (starts
        ; with ^ ! + #), don't try to convert. Lets power users type
        ; "^!f" directly.
        firstCh := SubStr(s, 1, 1)
        if (firstCh = "^" || firstCh = "!" || firstCh = "+" || firstCh = "#")
            return s

        ; Split by "+" and classify each token
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
                key := t   ; last non-modifier wins (there should be only 1)
        }

        if (key = "")
            return ""

        ; Normalize the key to AHK convention
        ; Single letter -> lowercase (a-z)
        if RegExMatch(key, "^[A-Za-z]$")
            key := StrLower(key)
        ; F-key (F1-F24) -> "F" + number
        else if RegExMatch(key, "i)^f(\d+)$", &m)
            key := "F" m[1]
        ; Others (Esc, Space, Tab, digits...) -> leave as-is
        ; (AHK is case-insensitive in these cases)

        return modifiers . key
    }

    ; ------------------------------------------------------------
    ; _PrettifyKey - capitalizes the raw "key" for display
    ; ------------------------------------------------------------
    static _PrettifyKey(key)
    {
        if (key = "")
            return ""
        ; Single letter -> uppercase
        if RegExMatch(key, "^[a-zA-Z]$")
            return StrUpper(key)
        ; F-key
        if RegExMatch(key, "i)^f(\d+)$", &m)
            return "F" m[1]
        ; Numbers / digits -> as-is
        if RegExMatch(key, "^\d+$")
            return key
        ; Others: only capitalize the first letter (Esc, Space, Tab, etc.)
        return StrUpper(SubStr(key, 1, 1)) . SubStr(key, 2)
    }
}

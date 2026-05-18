; TextEncoding — BOM detection only.
;
; Project invariant: every INI file ships and stays as UTF-16 LE
; with BOM — the format IniWrite generates by default. The reason
; is brutal: AHK v2's IniRead key-lookup
; (`IniRead(path, section, key, default)`) ONLY recognizes entries
; in UTF-16 LE BOM. On UTF-8 BOM it silently returns the default
; for every key, no error, no warning — a saved INI looks empty
; on the next boot, every PB/run state/setting reads as missing.
;
; Alternatives that were considered and rejected:
;   - UTF-8 without BOM → AHK reads as ANSI/CP1252; accents break.
;   - UTF-16 BE → no explicit BE flag in AHK v2 FileRead.
;   - UTF-8 BOM → the silent IniRead failure above.
;   - UTF-16 LE BOM → default already; the only working option.
;
; This module used to ship ConvertUtf16ToUtf8 / MigrateIniToUtf8
; helpers; both were removed once the IniRead failure was confirmed
; empirically. The pitfall is also captured by the
; PersonalBestRepository test
; `iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom`.
;
; DetectBom is diagnostic only — useful for validating that a file
; on disk is in the expected encoding. It does NOT convert.
;
;   enc := TextEncoding.DetectBom(path)
;   ; enc in {"UTF-16-LE", "UTF-16-BE", "UTF-8-BOM", "NONE"}


class TextEncoding
{
    ; Reads the first 2-3 bytes via FileRead("RAW") and identifies
    ; the BOM. "NONE" covers empty files, missing BOM, or anything
    ; shorter than 2 bytes. Throws OSError when the file is missing.
    static DetectBom(path)
    {
        if !FileExist(path)
            throw OSError("TextEncoding.DetectBom: file does not exist: " path)

        ; FileRead with "RAW" returns a Buffer of raw bytes (no
        ; decode). The BOM lives in the first 2-3, no need to load
        ; large files.
        buf := FileRead(path, "RAW")
        if (buf.Size < 2)
            return "NONE"

        b0 := NumGet(buf, 0, "UChar")
        b1 := NumGet(buf, 1, "UChar")

        ; UTF-16 LE BOM: FF FE
        if (b0 = 0xFF && b1 = 0xFE)
            return "UTF-16-LE"

        ; UTF-16 BE BOM: FE FF
        if (b0 = 0xFE && b1 = 0xFF)
            return "UTF-16-BE"

        ; UTF-8 BOM: EF BB BF
        if (buf.Size >= 3)
        {
            b2 := NumGet(buf, 2, "UChar")
            if (b0 = 0xEF && b1 = 0xBB && b2 = 0xBF)
                return "UTF-8-BOM"
        }

        return "NONE"
    }
}

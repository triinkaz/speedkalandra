; ============================================================
; TextEncoding — BOM detection (R11.1)
; ============================================================
;
; HISTORY:
;   - R11 introduced TextEncoding with 3 methods:
;       DetectBom            -> identifies encoding via BOM
;       ConvertUtf16ToUtf8   -> rewrites UTF-16 LE as UTF-8 BOM
;       MigrateIniToUtf8     -> detect+convert facade for INIs
;
;   - R11.1 (Bug #2, Wave 9 regression tests): ConvertUtf16ToUtf8 and
;     MigrateIniToUtf8 were REMOVED. Keep only DetectBom.
;
; WHY THE REMOVAL:
;   AHK v2's IniRead key-lookup ONLY works in UTF-16 LE BOM files.
;   On UTF-8 BOM, IniRead(path, section, key, default) always returns
;   the default — regardless of line endings, correct encoding, etc.
;
;   MigrateIniToUtf8 promised "auto-convert INIs from UTF-16 to UTF-8
;   BOM to save space and improve diffs". But the side effect was
;   catastrophic: EVERY repository's Load() silently failed, returning
;   defaults for every key. PBs, run state, settings — all read as if
;   they did not exist.
;
;   The bug stayed latent because IniFile.__New had the call wrapped
;   in try/catch and the function was disabled before being widely
;   tested. Wave 9 regression tests (text_encoding_tests
;   `iniread_works_after_migration_*`) confirmed empirically that
;   IniRead failed after the migration.
;
;   No viable fix path:
;     - UTF-8 without BOM: AHK treats it as ANSI/CP1252; accents break.
;     - UTF-16 BE: AHK v2 FileRead has no explicit BE flag.
;     - UTF-8 BOM: what MigrateIniToUtf8 did — breaks IniRead.
;     - Keep UTF-16 LE: what AHK already generates by default — the
;                       function becomes a semantic no-op.
;
;   Conclusion: the migration was an UNFEASIBLE feature. The project's
;   INIs remain in UTF-16 LE BOM (what AHK generates by default in
;   IniWrite when the file does not exist). No migration = no bug.
;
; RELATED PITFALL (PersonalBestRepositoryTests):
;   The test `iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom`
;   documents the AHK v2 behavior that motivated this removal.
;
; CURRENT USAGE:
;   enc := TextEncoding.DetectBom(path)
;   ; enc in {"UTF-16-LE", "UTF-16-BE", "UTF-8-BOM", "NONE"}
;
;   ; Use cases: diagnosis, debug, validate that IniWrite produced
;   ; the expected encoding. DO NOT use to convert — we no longer
;   ; have that capability in the project.


class TextEncoding
{
    ; ------------------------------------------------------------
    ; DetectBom(path) -> "UTF-16-LE" | "UTF-16-BE" | "UTF-8-BOM" | "NONE"
    ;
    ; Reads the first 2-3 bytes of the file via FileRead(..., "RAW")
    ; and identifies the BOM. "NONE" covers: empty file, no BOM, or
    ; smaller than 2 bytes.
    ;
    ; Throws OSError if the file does not exist.
    ; ------------------------------------------------------------
    static DetectBom(path)
    {
        if !FileExist(path)
            throw OSError("TextEncoding.DetectBom: file does not exist: " path)

        ; FileRead "RAW" returns a Buffer with raw bytes, no decode.
        ; Limits to 4 bytes to avoid loading large files when we only
        ; need the BOM.
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

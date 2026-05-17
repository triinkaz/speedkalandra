; ============================================================
; IniFile — wrapper over IniRead/IniWrite/IniDelete
; ============================================================
;
; Why does it exist?
;   - Legacy modules (settings.ahk, state.ahk) call IniRead/IniWrite
;     with INI_FILE as a global passed around everywhere. The wrapper
;     centralizes encoding, directory creation, and error isolation.
;   - Phase 3 repositories receive an IniFile instance in their
;     constructor. That decouples the repo from the global filesystem.
;   - Tests inject an IniFile pointing at a tempfile.
;
; Encoding:
;   AHK v2 auto-detects UTF-16-LE / UTF-8 / ANSI by the BOM.
;   IniWrite uses UTF-16-LE when the file does not exist. For existing
;   files, it keeps the original encoding. We don't need to specify.
;
; Usage:
;   ini := IniFile(A_ScriptDir "\poe2_tracker.ini")
;   ini.Read("General", "ProfileName", "Default")  ; with default
;   ini.Write("Default", "General", "ProfileName")
;   ini.Delete("Progress", "a1_01_riverbank_miller")
;   ini.SectionExists("Run")
;   ini.KeysIn("Progress")  ; -> Array<string>


class IniFile
{
    path := ""

    __New(path)
    {
        if (path = "")
            throw ValueError("IniFile: 'path' is required")
        this.path := path
        this._EnsureDir()
        ; Encoding: AHK v2 IniWrite creates UTF-16 LE BOM by default when
        ; the file does not exist. We DO NOT try to migrate to UTF-8 —
        ; AHK v2's IniRead key-lookup ONLY works in UTF-16 LE BOM (in
        ; UTF-8 BOM, it silently returns the default). See R11.1 doc in
        ; text_encoding.ahk and the pitfall test in
        ; PersonalBestRepositoryTests.iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom.
    }

    ; ------------------------------------------------------------
    ; Read(section, key, default := "")
    ;   Reads a specific value. If the key does not exist and a default
    ;   was passed, returns the default. If default is "" and the key
    ;   does not exist, returns "" (NEVER throws).
    ; ------------------------------------------------------------
    Read(section, key, default := "")
    {
        try
            return IniRead(this.path, section, key, default)
        catch
            return default
    }

    ; ------------------------------------------------------------
    ; ReadSection(section) -> string (multi-line "key=value\n...")
    ;   Useful to list all keys in a section. Returns "" if the
    ;   section does not exist.
    ; ------------------------------------------------------------
    ReadSection(section)
    {
        try
            return IniRead(this.path, section, , "")
        catch
            return ""
    }

    ; ------------------------------------------------------------
    ; KeysIn(section) -> Array<string>
    ;   Parses ReadSection and returns only the key names.
    ; ------------------------------------------------------------
    KeysIn(section)
    {
        keys := []
        block := this.ReadSection(section)
        if (block = "")
            return keys

        ; Normalize CRLF
        block := StrReplace(block, "`r`n", "`n")
        for _, line in StrSplit(block, "`n")
        {
            line := Trim(line)
            if (line = "")
                continue
            eqPos := InStr(line, "=")
            if (eqPos < 2)
                continue
            keys.Push(SubStr(line, 1, eqPos - 1))
        }
        return keys
    }

    ; ------------------------------------------------------------
    ; ReadSectionAsMap(section) -> Map<key, value>
    ;   Reads all keys of a section as a Map.
    ; ------------------------------------------------------------
    ReadSectionAsMap(section)
    {
        result := Map()
        block := this.ReadSection(section)
        if (block = "")
            return result

        block := StrReplace(block, "`r`n", "`n")
        for _, line in StrSplit(block, "`n")
        {
            line := Trim(line)
            if (line = "")
                continue
            eqPos := InStr(line, "=")
            if (eqPos < 2)
                continue
            key := SubStr(line, 1, eqPos - 1)
            value := SubStr(line, eqPos + 1)
            result[key] := value
        }
        return result
    }

    ; ------------------------------------------------------------
    ; Write(value, section, key)
    ;   Arguments in the SAME order as native IniWrite (value, file,
    ;   section, key) minus the file. Keeps consistency with the AHK API.
    ; ------------------------------------------------------------
    Write(value, section, key)
    {
        IniWrite(value, this.path, section, key)
    }

    ; ------------------------------------------------------------
    ; WriteVerbatim(value, section, key)
    ;
    ; Like Write, but preserves values where the user typed leading/
    ; trailing double-quotes (vendor regex strings being the canonical
    ; case).
    ;
    ; AHK's IniRead has an undocumented-but-stable behavior: when a
    ; value is enclosed in a SINGLE pair of double quotes
    ; ("..." anywhere from start to end), IniRead strips that pair
    ; on read. So:
    ;
    ;     IniWrite('"!(uiv)" "melee"', file, sec, key)
    ;     -> file content: key="!(uiv)" "melee"
    ;     -> IniRead returns: !(uiv)" "melee   <-- outer quotes stripped
    ;
    ; The fix is to ALWAYS wrap in an extra pair of quotes on write.
    ; Then IniRead strips the pair WE added, returning the user's
    ; original string intact (including its own quotes):
    ;
    ;     IniWrite('""!(uiv)" "melee""', ...)
    ;     -> file content: key=""!(uiv)" "melee""
    ;     -> IniRead returns: "!(uiv)" "melee"   <-- correct!
    ;
    ; The wrapping is idempotent on reload because the next Write
    ; re-wraps from the already-unwrapped value.
    ;
    ; Read for a verbatim value uses the regular Read method — no
    ; special read-side handling is needed since IniRead does the
    ; un-wrap automatically.
    ; ------------------------------------------------------------
    WriteVerbatim(value, section, key)
    {
        IniWrite('"' . String(value) . '"', this.path, section, key)
    }

    ; ------------------------------------------------------------
    ; Delete(section, key := "")
    ;   If key is empty, deletes the entire section. No effect if
    ;   it does not exist (never throws).
    ; ------------------------------------------------------------
    Delete(section, key := "")
    {
        try
        {
            if (key = "")
                IniDelete(this.path, section)
            else
                IniDelete(this.path, section, key)
        }
    }

    ; ------------------------------------------------------------
    ; Exists() -> bool
    ;   True if the file exists on disk.
    ; ------------------------------------------------------------
    Exists()
    {
        return FileExist(this.path) != ""
    }

    ; ------------------------------------------------------------
    ; SectionExists(section) -> bool
    ;   True if the section has at least one key.
    ; ------------------------------------------------------------
    SectionExists(section)
    {
        return this.ReadSection(section) != ""
    }

    GetPath() => this.path

    ; ------------------------------------------------------------
    ; Private helpers
    ; ------------------------------------------------------------
    _EnsureDir()
    {
        SplitPath(this.path, , &dir)
        if (dir != "" && !DirExist(dir))
        {
            try DirCreate(dir)
        }
    }
}

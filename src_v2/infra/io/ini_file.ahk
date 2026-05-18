; IniFile — thin wrapper over IniRead / IniWrite / IniDelete.
; Centralizes directory creation and error isolation, so repositories
; can take an IniFile in their constructor and stay decoupled from
; the filesystem (tests inject one pointing at a tempfile).
;
; Encoding: AHK v2 auto-detects UTF-16-LE / UTF-8 / ANSI from the
; BOM. IniWrite creates new files as UTF-16 LE with BOM; existing
; files keep their encoding. The project relies on the UTF-16 LE
; BOM default because IniRead's key-lookup variant
; (`IniRead(file, section, key, default)`) silently returns the
; default on UTF-8 BOM files — see text_encoding.ahk for the full
; story.
;
; Usage:
;   ini := IniFile(A_ScriptDir "\poe2_tracker.ini")
;   ini.Read("General", "ProfileName", "Default")
;   ini.Write("Default", "General", "ProfileName")
;   ini.Delete("Progress", "a1_01_riverbank_miller")
;   ini.SectionExists("Run")
;   ini.KeysIn("Progress")  ; → Array<string>


class IniFile
{
    path := ""

    __New(path)
    {
        if (path = "")
            throw ValueError("IniFile: 'path' is required")
        this.path := path
        this._EnsureDir()
    }

    ; Reads a specific value. Returns `default` (or "") for missing
    ; keys; never throws.
    Read(section, key, default := "")
    {
        try
            return IniRead(this.path, section, key, default)
        catch
            return default
    }

    ; Returns the full section block as a "key=value\n..." string,
    ; or "" when the section is absent. Useful for listing keys.
    ReadSection(section)
    {
        try
            return IniRead(this.path, section, , "")
        catch
            return ""
    }

    ; Parses ReadSection and returns only the key names.
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

    ; Reads every key=value pair of a section into a Map.
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

    ; Arguments mirror native IniWrite (value, section, key), minus
    ; the file path — it's already bound to this instance.
    Write(value, section, key)
    {
        IniWrite(value, this.path, section, key)
    }

    ; Same as Write but preserves values that contain their own
    ; leading/trailing double quotes (vendor regex strings being the
    ; canonical case).
    ;
    ; IniRead has an undocumented-but-stable behavior: when a value
    ; is wrapped in a single pair of double quotes from start to end,
    ; IniRead strips that pair on read. So writing the user's raw
    ; string would lose its outer quotes:
    ;
    ;     IniWrite('"!(uiv)" "melee"', file, sec, key)
    ;     → file content: key="!(uiv)" "melee"
    ;     → IniRead returns: !(uiv)" "melee   (outer pair stripped)
    ;
    ; The workaround: always wrap with one extra pair of quotes on
    ; write. IniRead then strips the pair WE added and returns the
    ; original string intact, quotes and all:
    ;
    ;     IniWrite('""!(uiv)" "melee""', ...)
    ;     → file content: key=""!(uiv)" "melee""
    ;     → IniRead returns: "!(uiv)" "melee"   ✓
    ;
    ; Idempotent across save/reload — the next Write wraps from the
    ; already-unwrapped value. Reading a verbatim value uses Read()
    ; with no special handling; IniRead does the unwrap automatically.
    WriteVerbatim(value, section, key)
    {
        IniWrite('"' . String(value) . '"', this.path, section, key)
    }

    ; Empty key deletes the entire section. No effect when missing;
    ; never throws.
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

    Exists()
    {
        return FileExist(this.path) != ""
    }

    SectionExists(section)
    {
        return this.ReadSection(section) != ""
    }

    GetPath() => this.path

    ; ---- Private ----

    _EnsureDir()
    {
        SplitPath(this.path, , &dir)
        if (dir != "" && !DirExist(dir))
        {
            try DirCreate(dir)
        }
    }
}

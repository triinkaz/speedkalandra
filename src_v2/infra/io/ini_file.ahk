; ============================================================
; IniFile — wrapper sobre IniRead/IniWrite/IniDelete
; ============================================================
;
; Por que existe?
;   - Os legados (settings.ahk, state.ahk) chamam IniRead/IniWrite com
;     o path INI_FILE como global passado em todo lugar. O wrapper
;     centraliza encoding, criacao de diretorio, e isolamento de erros.
;   - Repositorios da Fase 3 recebem uma instancia de IniFile no
;     construtor. Isso desacopla o repo do filesystem global.
;   - Testes injetam IniFile apontando para um tempfile.
;
; Encoding:
;   AHK v2 detecta UTF-16-LE / UTF-8 / ANSI automaticamente pelo BOM.
;   IniWrite usa UTF-16-LE quando o arquivo nao existe. Para arquivos
;   existentes, mantem o encoding original. Nao precisamos especificar.
;
; Uso:
;   ini := IniFile(A_ScriptDir "\poe2_tracker.ini")
;   ini.Read("General", "ProfileName", "Default")  ; com default
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
            throw ValueError("IniFile: 'path' obrigatorio")
        this.path := path
        this._EnsureDir()
        ; Encoding: AHK v2 IniWrite cria UTF-16 LE BOM por default quando
        ; o arquivo nao existe. NAO TENTAMOS migrar pra UTF-8 — IniRead
        ; key-lookup do AHK v2 SO funciona em UTF-16 LE BOM (em UTF-8 BOM,
        ; retorna default silenciosamente). Vide R11.1 doc em
        ; text_encoding.ahk e o pitfall test em
        ; PersonalBestRepositoryTests.iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom.
    }

    ; ------------------------------------------------------------
    ; Read(section, key, default := "")
    ;   Le um valor especifico. Se a chave nao existe e default foi
    ;   passado, retorna default. Se default for "" e a chave nao
    ;   existir, retorna "" (NUNCA estoura).
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
    ;   Util para listar todas as keys de uma section. Retorna ""
    ;   se a section nao existir.
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
    ;   Parseia ReadSection e retorna so os nomes das keys.
    ; ------------------------------------------------------------
    KeysIn(section)
    {
        keys := []
        block := this.ReadSection(section)
        if (block = "")
            return keys

        ; Normaliza CRLF
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
    ;   Le todas as keys de uma section como Map.
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
    ;   Argumentos na MESMA ordem do IniWrite nativo (value, file,
    ;   section, key) menos o file. Mantem coerencia com a API AHK.
    ; ------------------------------------------------------------
    Write(value, section, key)
    {
        IniWrite(value, this.path, section, key)
    }

    ; ------------------------------------------------------------
    ; Delete(section, key := "")
    ;   Se key for vazio, apaga a section inteira. Sem efeito se
    ;   nao existe (nunca estoura).
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
    ;   True se o arquivo existe no disco.
    ; ------------------------------------------------------------
    Exists()
    {
        return FileExist(this.path) != ""
    }

    ; ------------------------------------------------------------
    ; SectionExists(section) -> bool
    ;   True se a section tem pelo menos uma key.
    ; ------------------------------------------------------------
    SectionExists(section)
    {
        return this.ReadSection(section) != ""
    }

    GetPath() => this.path

    ; ------------------------------------------------------------
    ; Helpers privados
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

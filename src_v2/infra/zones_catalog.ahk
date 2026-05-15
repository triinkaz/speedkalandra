; ============================================================
; ZonesCatalog - carrega data/zones.csv em memoria
; ============================================================
;
; Catalogo estatico de zonas de campanha (77 zonas POE2 Early Access).
; Substitui o legado town_zones_repository.ahk + data/town_zones.txt:
; agora todas as info de zona vem de um arquivo unico no formato CSV
; ponto-virgula, com is_town como flag.
;
; FORMATO data/zones.csv:
;
;   name;internal_id;act;is_town
;   Clearfell Encampment;G1_town;1;1
;   Cemetery of the Eternals;G1_7;1;0
;   ...
;
;   - name        : nome de display (case-sensitive, mas matching faz lower)
;   - internal_id : id do log do PoE2 (G1_..., G2_..., etc)
;   - act         : 1, 2, 3, 4
;   - is_town     : 1 = cidade/hub, 0 = zona normal
;
; LOG MATCHING:
;   O Client.txt pode reportar zona por NAME (texto humano) ou via
;   internal_id. ZonesCatalog suporta lookup pelos dois lados:
;     IsTownName("Clearfell Encampment") => true
;     IsTownById("G1_town")              => true
;
; CONSTRUCAO:
;   catalog := ZonesCatalog(A_ScriptDir "\data\zones.csv")
;   catalog.Count()                  => 77
;   catalog.FindByName("Clearfell")  => ZoneEntry | ""
;   catalog.IsTownName("...")        => bool
;   catalog.GetActOfName("...")      => Int | 0
;   catalog.All()                    => Array<ZoneEntry>

class ZoneEntry
{
    name       := ""
    internalId := ""
    act        := 0
    isTown     := false

    __New(name, internalId, act, isTown)
    {
        this.name       := name
        this.internalId := internalId
        this.act        := act
        this.isTown     := isTown
    }
}


class ZonesCatalog
{
    _path        := ""
    _zones       := []        ; Array<ZoneEntry>
    _byName      := Map()     ; lower-name -> ZoneEntry
    _byId        := Map()     ; internal_id -> ZoneEntry

    __New(csvPath)
    {
        if (csvPath = "")
            throw ValueError("ZonesCatalog: 'csvPath' obrigatorio")
        this._path := csvPath
        this._Load()
    }

    ; ------------------------------------------------------------
    ; Queries publicas
    ; ------------------------------------------------------------
    All()             => this._zones
    Count()           => this._zones.Length
    GetPath()         => this._path

    FindByName(name)
    {
        if (name = "")
            return ""
        key := StrLower(Trim(name))
        return this._byName.Has(key) ? this._byName[key] : ""
    }

    FindById(internalId)
    {
        if (internalId = "")
            return ""
        return this._byId.Has(internalId) ? this._byId[internalId] : ""
    }

    HasName(name)     => this.FindByName(name) != ""
    HasId(internalId) => this.FindById(internalId) != ""

    IsTownName(name)
    {
        z := this.FindByName(name)
        return IsObject(z) && z.isTown
    }

    IsTownById(internalId)
    {
        z := this.FindById(internalId)
        return IsObject(z) && z.isTown
    }

    GetActOfName(name)
    {
        z := this.FindByName(name)
        return IsObject(z) ? z.act : 0
    }

    GetActOfId(internalId)
    {
        z := this.FindById(internalId)
        return IsObject(z) ? z.act : 0
    }

    ; Lista de zonas filtradas
    ByAct(actIndex)
    {
        out := []
        for _, z in this._zones
            if (z.act = actIndex)
                out.Push(z)
        return out
    }

    Towns()
    {
        out := []
        for _, z in this._zones
            if z.isTown
                out.Push(z)
        return out
    }

    Reload() => this._Load()

    ; ------------------------------------------------------------
    ; _Load — parse CSV manual
    ; ------------------------------------------------------------
    _Load()
    {
        this._zones  := []
        this._byName := Map()
        this._byId   := Map()

        if !FileExist(this._path)
            return

        try
            content := FileRead(this._path, "UTF-8")
        catch
        {
            try
                content := FileRead(this._path)
            catch
                return
        }

        if (content = "")
            return

        content := StrReplace(content, "`r`n", "`n")
        lineNum := 0

        for _, rawLine in StrSplit(content, "`n")
        {
            lineNum++
            line := Trim(rawLine)
            if (line = "")
                continue
            ; Skip header (case-insensitive). Tambem skipa comments.
            firstChar := SubStr(line, 1, 1)
            if (firstChar = "#" || firstChar = ";")
                continue
            if (lineNum = 1 && InStr(StrLower(line), "name;internal_id"))
                continue

            parts := StrSplit(line, ";")
            if (parts.Length < 4)
                continue

            name       := Trim(parts[1])
            internalId := Trim(parts[2])
            actStr     := Trim(parts[3])
            townStr    := Trim(parts[4])

            if (name = "")
                continue

            act := 0
            try
                act := Integer(actStr)
            catch
                act := 0

            isTown := (townStr = "1" || StrLower(townStr) = "true")

            entry := ZoneEntry(name, internalId, act, isTown)
            this._zones.Push(entry)
            this._byName[StrLower(name)] := entry
            if (internalId != "")
                this._byId[internalId] := entry
        }
    }
}

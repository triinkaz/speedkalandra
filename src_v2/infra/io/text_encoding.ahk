; ============================================================
; TextEncoding — deteccao de BOM (R11.1)
; ============================================================
;
; HISTORICO:
;   - R11 introduziu TextEncoding com 3 metodos:
;       DetectBom            -> identifica encoding via BOM
;       ConvertUtf16ToUtf8   -> reescreve UTF-16 LE como UTF-8 BOM
;       MigrateIniToUtf8     -> facade detect+convert para INIs
;
;   - R11.1 (Bug #2, regression tests Wave 9): ConvertUtf16ToUtf8 e
;     MigrateIniToUtf8 foram REMOVIDOS. Manter so DetectBom.
;
; POR QUE A REMOCAO:
;   IniRead key-lookup do AHK v2 SO funciona em arquivos UTF-16 LE BOM.
;   Em UTF-8 BOM, IniRead(path, section, key, default) sempre retorna
;   o default — independente de line endings, encoding correto, etc.
;
;   A funcao MigrateIniToUtf8 prometia "auto-converter INIs de UTF-16
;   pra UTF-8 BOM pra economizar espaco e melhorar diffs". Mas o efeito
;   colateral era catastrofico: TODO Load() dos repositorios falhava
;   silenciosamente, retornando defaults pra todas as keys. PBs, run
;   state, settings — tudo lido como se nao existisse.
;
;   O bug ficou latente porque IniFile.__New tinha a chamada envolvida
;   em try/catch e a funcao foi desativada antes de ser amplamente
;   testada. Os regression tests da Wave 9 (text_encoding_tests
;   `iniread_works_after_migration_*`) confirmaram empiricamente que
;   o IniRead falhava apos a migration.
;
;   Sem caminho de fix viavel:
;     - UTF-8 sem BOM: AHK trata como ANSI/CP1252; acentos quebram.
;     - UTF-16 BE: AHK v2 FileRead nao tem flag explicita BE.
;     - UTF-8 BOM: o que MigrateIniToUtf8 fazia — quebra IniRead.
;     - Manter UTF-16 LE: o que o AHK ja gera por default — funcao
;                         vira no-op semanticamente.
;
;   Conclusao: a migration era uma feature INVIAVEL. INIs do projeto
;   continuam em UTF-16 LE BOM (o que o AHK gera por default em
;   IniWrite quando o arquivo nao existe). Sem migration = sem bug.
;
; PITFALL RELACIONADO (PersonalBestRepositoryTests):
;   O teste `iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom`
;   documenta o comportamento do AHK v2 que motivou esta remocao.
;
; USO ATUAL:
;   enc := TextEncoding.DetectBom(path)
;   ; enc in {"UTF-16-LE", "UTF-16-BE", "UTF-8-BOM", "NONE"}
;
;   ; Use casos: diagnostico, debug, validar que IniWrite gerou o
;   ; encoding esperado. NAO use pra converter — nao temos mais essa
;   ; capacidade no projeto.


class TextEncoding
{
    ; ------------------------------------------------------------
    ; DetectBom(path) -> "UTF-16-LE" | "UTF-16-BE" | "UTF-8-BOM" | "NONE"
    ;
    ; Le os primeiros 2-3 bytes do arquivo via FileRead(..., "RAW")
    ; e identifica o BOM. "NONE" cobre: arquivo vazio, sem BOM, ou
    ; menor que 2 bytes.
    ;
    ; Throws OSError se o arquivo nao existe.
    ; ------------------------------------------------------------
    static DetectBom(path)
    {
        if !FileExist(path)
            throw OSError("TextEncoding.DetectBom: arquivo nao existe: " path)

        ; FileRead "RAW" retorna Buffer com bytes crus, sem decode.
        ; Limita a 4 bytes pra evitar carregar arquivos grandes
        ; quando so precisamos do BOM.
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

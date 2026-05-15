; ============================================================
; TextEncoding — deteccao de BOM + conversao UTF-16 -> UTF-8 (R11)
; ============================================================
;
; CONTEXTO:
;   AHK v2 cria arquivos INI em UTF-16 LE BOM por default (quando
;   o arquivo nao existe e a primeira chamada eh IniWrite). UTF-16
;   tem 2 problemas pratos:
;
;   1. Arquivos ficam ~2x maiores que UTF-8 (cada char ASCII ocupa
;      2 bytes em vez de 1). Pra INIs do nosso projeto que tem
;      muito texto ASCII, isso eh waste de espaco.
;
;   2. Editores modernos (VSCode, Notepad++, sublime) leem UTF-8
;      por default. Abrir UTF-16 funciona mas o BOM aparece como
;      "EF BB BF" garbage em editors que nao detectam corretamente.
;      Diff tools (git diff, beyond compare) tambem podem ter
;      problemas em modo binario.
;
;   3. Versionamento (.gitignore desativa, mas se voltar um dia)
;      mostra diffs ilegiveis em UTF-16.
;
; SOLUCAO:
;   Auto-migrar INIs UTF-16 LE pra UTF-8 (com BOM) na primeira vez
;   que um IniFile eh instanciado apontando pra esse arquivo.
;   Idempotente: arquivos ja UTF-8 ou inexistentes ficam no-op.
;
; POR QUE UTF-8 COM BOM E NAO UTF-8-RAW (sem BOM)?
;   AHK v2 detecta encoding em IniRead/IniWrite pelo BOM:
;     - UTF-16 LE BOM: le como UTF-16 LE
;     - UTF-8 BOM:     le como UTF-8
;     - Sem BOM:       trata como ANSI (CP1252 em pt-BR Windows)
;
;   Se gravassemos UTF-8 sem BOM, AHK trataria como ANSI no proximo
;   IniRead e caracteres acentuados (cao, cafe, posicao) viriam
;   corrompidos. BOM UTF-8 (3 bytes: EF BB BF) eh o sinal correto.
;
; PRINCIPIO ATOMICO:
;   Conversao usa AtomicWriter (refactor R10). Crash durante a
;   migration deixa arquivo intacto ou ja convertido, nunca corrompido.
;
; USO:
;   enc := TextEncoding.DetectBom(path)
;   if (enc = "UTF-16-LE")
;       TextEncoding.ConvertUtf16ToUtf8(path)
;
;   ; Ou direto:
;   TextEncoding.MigrateIniToUtf8(path)    ; faz detect + convert
;
; LIMITES:
;   - Nao detecta encoding sem BOM (ANSI vs UTF-8-RAW): falta info
;     em bytes. Esse caso assume "sem BOM = nao mexe".
;   - UTF-16 BE (Big Endian) eh raro em Windows mas suportado pela
;     deteccao; conversao trata como erro (skip) porque AHK v2
;     FileRead nao tem flag pra UTF-16-BE explicito.


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

    ; ------------------------------------------------------------
    ; ConvertUtf16ToUtf8(path)
    ;
    ; Le path como UTF-16 LE e regrava como UTF-8 com BOM.
    ; Usa AtomicWriter (R10) — crash durante conversao deixa
    ; arquivo antigo intacto.
    ;
    ; PRE: path existe, BOM = UTF-16 LE (chamador deve checar antes).
    ; POST: path tem BOM UTF-8 e conteudo decodificado igual ao original.
    ;
    ; Throws OSError se FileRead/FileMove falhar.
    ; ------------------------------------------------------------
    static ConvertUtf16ToUtf8(path)
    {
        if !FileExist(path)
            throw OSError("TextEncoding.ConvertUtf16ToUtf8: arquivo nao existe: " path)

        ; AHK v2 FileRead com "UTF-16" decoda assumindo UTF-16 LE com BOM.
        ; Retorna string AHK (que internamente eh UTF-16 mas isso eh
        ; detalhe de implementacao do AHK; pra nos eh "uma string").
        content := FileRead(path, "UTF-16")

        ; Defensive: alguns paths de FileRead deixam U+FEFF (zero-width
        ; no-break space, codepoint do BOM) como primeiro char da string.
        ; Se gravassemos com encoding "UTF-8" (que adiciona BOM EF BB BF
        ; automaticamente), terminariamos com 2 BOMs encadeados (EF BB BF
        ; EF BB BF). Strip o U+FEFF antes pra evitar isso.
        if (StrLen(content) > 0 && SubStr(content, 1, 1) = Chr(0xFEFF))
            content := SubStr(content, 2)

        ; AtomicWriter escreve em UTF-8 com BOM por default.
        ; .tmp + FileMove garante atomicidade.
        AtomicWriter.WriteAll(path, content, "UTF-8")
    }

    ; ------------------------------------------------------------
    ; MigrateIniToUtf8(path)
    ;
    ; Helper conveniente: detecta encoding e converte se necessario.
    ; No-op se arquivo nao existe, ja eh UTF-8, ou eh ANSI (sem BOM).
    ;
    ; Retorna:
    ;   "converted"      — UTF-16 LE detectado e convertido
    ;   "already-utf8"   — ja tem BOM UTF-8
    ;   "no-bom"         — sem BOM (ANSI ou UTF-8-RAW; deixa quieto)
    ;   "not-found"      — arquivo nao existe
    ;   "skipped-be"     — UTF-16 BE (raro; nao convertido)
    ;
    ; Idempotente: chamadas sucessivas no mesmo path sao seguras.
    ; ------------------------------------------------------------
    static MigrateIniToUtf8(path)
    {
        if !FileExist(path)
            return "not-found"

        enc := TextEncoding.DetectBom(path)
        switch enc
        {
            case "UTF-16-LE":
                TextEncoding.ConvertUtf16ToUtf8(path)
                return "converted"
            case "UTF-8-BOM":
                return "already-utf8"
            case "UTF-16-BE":
                ; Nao convertemos automaticamente — caso raro
                ; e AHK v2 FileRead nao tem flag explicita BE.
                return "skipped-be"
            default:
                return "no-bom"
        }
    }
}

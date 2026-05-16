; ============================================================
; TextEncoding tests (R11.1)
; ============================================================
;
; DetectBom(path) -> "UTF-16-LE" | "UTF-16-BE" | "UTF-8-BOM" | "NONE"
;
; HISTORICO:
;   R11.1 (Bug #2 fix): ConvertUtf16ToUtf8 e MigrateIniToUtf8 foram
;   REMOVIDOS porque quebravam IniRead key-lookup do AHK v2 (so
;   funciona em UTF-16 LE BOM). Tests dos metodos removidos foram
;   apagados deste arquivo.
;
;   Os 4 regression tests `regression_bug2_*` que demonstravam a
;   incompatibilidade foram substituidos por 2 tests positivos
;   confirmando a remocao da API.

class TextEncodingTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- DetectBom ---
        "detect_bom_throws_os_error_on_missing_file",
        "detect_bom_returns_none_for_empty_file",
        "detect_bom_returns_none_for_single_byte_file",
        "detect_bom_returns_utf16_le_for_ff_fe",
        "detect_bom_returns_utf16_be_for_fe_ff",
        "detect_bom_returns_utf8_bom_for_ef_bb_bf",
        "detect_bom_returns_none_for_ascii_without_bom",

        ; --- Regression Bug #2: metodos de conversao removidos da API ---
        "bug2_convert_utf16_to_utf8_was_removed",
        "bug2_migrate_ini_to_utf8_was_removed",
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _WriteRawBytes(path, byteArray)
    {
        ; Escreve bytes especificos sem BOM nenhum (truncate write).
        buf := Buffer(byteArray.Length)
        for i, b in byteArray
            NumPut("UChar", b, buf, i - 1)
        f := FileOpen(path, "w")
        f.RawWrite(buf)
        f.Close()
    }

    ; ============================================================
    ; DetectBom
    ; ============================================================

    detect_bom_throws_os_error_on_missing_file()
    {
        Assert.Throws(OSError, () => TextEncoding.DetectBom("C:\\__nonexistent_xyz__.ini"))
    }

    detect_bom_returns_none_for_empty_file()
    {
        path := Fixtures.TempPath("ini")
        FileAppend("", path)   ; cria arquivo vazio (sem encoding -> sem BOM)
        Assert.Equal("NONE", TextEncoding.DetectBom(path))
    }

    detect_bom_returns_none_for_single_byte_file()
    {
        path := Fixtures.TempPath("ini")
        this._WriteRawBytes(path, [0x41])   ; "A" sozinho
        Assert.Equal("NONE", TextEncoding.DetectBom(path))
    }

    detect_bom_returns_utf16_le_for_ff_fe()
    {
        path := Fixtures.TempPath("ini")
        this._WriteRawBytes(path, [0xFF, 0xFE, 0x41, 0x00])
        Assert.Equal("UTF-16-LE", TextEncoding.DetectBom(path))
    }

    detect_bom_returns_utf16_be_for_fe_ff()
    {
        path := Fixtures.TempPath("ini")
        this._WriteRawBytes(path, [0xFE, 0xFF, 0x00, 0x41])
        Assert.Equal("UTF-16-BE", TextEncoding.DetectBom(path))
    }

    detect_bom_returns_utf8_bom_for_ef_bb_bf()
    {
        path := Fixtures.TempPath("ini")
        this._WriteRawBytes(path, [0xEF, 0xBB, 0xBF, 0x41, 0x42])
        Assert.Equal("UTF-8-BOM", TextEncoding.DetectBom(path))
    }

    detect_bom_returns_none_for_ascii_without_bom()
    {
        path := Fixtures.TempPath("ini")
        this._WriteRawBytes(path, [0x41, 0x42, 0x43, 0x44])   ; "ABCD"
        Assert.Equal("NONE", TextEncoding.DetectBom(path))
    }

    ; ============================================================
    ; Regression: Bug #2 (R11.1 - migration api removida)
    ; ============================================================
    ;
    ; CONTEXTO: ConvertUtf16ToUtf8 e MigrateIniToUtf8 foram removidos
    ; em R11.1 porque corrompiam IniRead key-lookup (so funciona em
    ; UTF-16 LE BOM no AHK v2). Estes testes garantem que se alguem
    ; tentar reintroduzir um desses metodos via copy-paste de codigo
    ; antigo, o test suite vai pegar.

    bug2_convert_utf16_to_utf8_was_removed()
    {
        ; HasMethod retorna false pra metodos static que nao existem
        ; na classe. Se alguem reintroduzir o metodo (sem revisao do
        ; pitfall), este teste passa a falhar e bloqueia o merge.
        Assert.False(TextEncoding.HasMethod("ConvertUtf16ToUtf8"),
            "Bug #2: ConvertUtf16ToUtf8 deve permanecer removido "
            . "(quebrava IniRead em UTF-8 BOM).")
    }

    bug2_migrate_ini_to_utf8_was_removed()
    {
        Assert.False(TextEncoding.HasMethod("MigrateIniToUtf8"),
            "Bug #2: MigrateIniToUtf8 deve permanecer removido "
            . "(quebrava IniRead em UTF-8 BOM).")
    }
}

TestRegistry.Register(TextEncodingTests)

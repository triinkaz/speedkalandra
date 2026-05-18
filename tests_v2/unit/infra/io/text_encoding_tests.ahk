; ============================================================
; TextEncoding tests
; ============================================================
;
; DetectBom(path) -> "UTF-16-LE" | "UTF-16-BE" | "UTF-8-BOM" | "NONE"
;
; NOTE: ConvertUtf16ToUtf8 and MigrateIniToUtf8 were removed because
; they broke AHK v2's IniRead key-lookup (which only works on
; UTF-16 LE BOM). The 4 regression tests that demonstrated the
; incompatibility were replaced with 2 positive tests confirming
; the API removal.

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

        ; --- Regression Bug #2: conversion methods removed from the API ---
        "bug2_convert_utf16_to_utf8_was_removed",
        "bug2_migrate_ini_to_utf8_was_removed",
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _WriteRawBytes(path, byteArray)
    {
        ; Writes specific bytes without any BOM (truncate write).
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
        FileAppend("", path)   ; creates empty file (no encoding -> no BOM)
        Assert.Equal("NONE", TextEncoding.DetectBom(path))
    }

    detect_bom_returns_none_for_single_byte_file()
    {
        path := Fixtures.TempPath("ini")
        this._WriteRawBytes(path, [0x41])   ; lone "A"
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
    ; Regression: Bug #2 (R11.1 - migration api removed)
    ; ============================================================
    ;
    ; CONTEXT: ConvertUtf16ToUtf8 and MigrateIniToUtf8 were removed
    ; in R11.1 because they corrupted IniRead key-lookup (only works
    ; on UTF-16 LE BOM in AHK v2). These tests guarantee that if
    ; anyone tries to reintroduce one of these methods via copy-paste
    ; of old code, the test suite catches it.

    bug2_convert_utf16_to_utf8_was_removed()
    {
        ; HasMethod returns false for static methods that don't exist
        ; on the class. If anyone reintroduces the method (without
        ; reviewing the pitfall), this test starts failing and blocks
        ; the merge.
        Assert.False(TextEncoding.HasMethod("ConvertUtf16ToUtf8"),
            "Bug #2: ConvertUtf16ToUtf8 must stay removed "
            . "(it broke IniRead on UTF-8 BOM).")
    }

    bug2_migrate_ini_to_utf8_was_removed()
    {
        Assert.False(TextEncoding.HasMethod("MigrateIniToUtf8"),
            "Bug #2: MigrateIniToUtf8 must stay removed "
            . "(it broke IniRead on UTF-8 BOM).")
    }
}

TestRegistry.Register(TextEncodingTests)

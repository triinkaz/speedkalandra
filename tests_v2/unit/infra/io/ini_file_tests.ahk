; ============================================================
; IniFile tests
; ============================================================
;
; Wrapper over IniRead/IniWrite/IniDelete + helpers:
;   - Constructor: path required, creates directory
;   - Read/Write/Delete (key or section)
;   - ReadSection, KeysIn, ReadSectionAsMap
;   - Exists, SectionExists, GetPath
;
; Naming: we use `iniInst` instead of `iniFile` to avoid the
; case-insensitive collision with the `IniFile` class.

class IniFileTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_on_empty_path",
        "constructor_creates_parent_directory",
        "constructor_does_not_create_file_until_first_write",

        ; --- Read / Write ---
        "write_creates_value_in_section",
        "read_returns_written_value",
        "read_returns_default_when_key_missing",
        "read_returns_empty_when_no_default_and_key_missing",
        "read_does_not_throw_on_missing_file",
        "write_overwrites_existing_value",

        ; --- ReadSection / KeysIn / ReadSectionAsMap ---
        "read_section_returns_multiline_block",
        "read_section_returns_empty_for_missing_section",
        "keys_in_returns_array_of_key_names",
        "keys_in_returns_empty_for_missing_section",
        "read_section_as_map_returns_key_value_map",

        ; --- Delete ---
        "delete_key_removes_only_that_key",
        "delete_section_removes_entire_section",
        "delete_does_not_throw_for_missing_section_or_key",

        ; --- Exists / SectionExists / GetPath ---
        "exists_true_after_write",
        "exists_false_before_first_write",
        "section_exists_true_when_section_has_keys",
        "section_exists_false_for_missing_section",
        "get_path_returns_constructor_arg",
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_on_empty_path()
    {
        Assert.Throws(ValueError, () => IniFile(""))
    }

    constructor_creates_parent_directory()
    {
        tmpDir := Fixtures.TempDir()
        nested := tmpDir "\sub\dir\settings.ini"
        iniInst := IniFile(nested)
        SplitPath(nested, , &dir)
        Assert.True(DirExist(dir),
            "Intermediate directory should have been created")
    }

    constructor_does_not_create_file_until_first_write()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        Assert.False(FileExist(path),
            "Constructor should not touch disk before the first Write")
        Assert.False(iniInst.Exists())
    }

    ; ============================================================
    ; Read / Write
    ; ============================================================

    write_creates_value_in_section()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("Default", "General", "ProfileName")
        Assert.True(FileExist(path))
    }

    read_returns_written_value()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("MyProfile", "General", "ProfileName")
        Assert.Equal("MyProfile", iniInst.Read("General", "ProfileName"))
    }

    read_returns_default_when_key_missing()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("anything", "General", "Other")
        Assert.Equal("fallback", iniInst.Read("General", "Missing", "fallback"))
    }

    read_returns_empty_when_no_default_and_key_missing()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("anything", "General", "Other")
        Assert.Equal("", iniInst.Read("General", "Missing"))
    }

    read_does_not_throw_on_missing_file()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        ; File doesn't even exist yet
        Assert.Equal("default", iniInst.Read("Any", "Key", "default"))
    }

    write_overwrites_existing_value()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("first",  "General", "Key")
        iniInst.Write("second", "General", "Key")
        Assert.Equal("second", iniInst.Read("General", "Key"))
    }

    ; ============================================================
    ; ReadSection / KeysIn / ReadSectionAsMap
    ; ============================================================

    read_section_returns_multiline_block()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("a", "S", "K1")
        iniInst.Write("b", "S", "K2")

        block := iniInst.ReadSection("S")
        Assert.Contains("K1=a", block)
        Assert.Contains("K2=b", block)
    }

    read_section_returns_empty_for_missing_section()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("a", "S", "K")
        Assert.Equal("", iniInst.ReadSection("Other"))
    }

    keys_in_returns_array_of_key_names()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("a", "S", "alpha")
        iniInst.Write("b", "S", "beta")
        iniInst.Write("c", "S", "gamma")

        keys := iniInst.KeysIn("S")
        Assert.Equal(3, keys.Length)
        Assert.Contains("alpha", keys)
        Assert.Contains("beta",  keys)
        Assert.Contains("gamma", keys)
    }

    keys_in_returns_empty_for_missing_section()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        Assert.Equal(0, iniInst.KeysIn("Missing").Length)
    }

    read_section_as_map_returns_key_value_map()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("100", "Run", "Ms")
        iniInst.Write("42",  "Run", "Deaths")

        m := iniInst.ReadSectionAsMap("Run")
        Assert.Equal(2,     m.Count)
        Assert.Equal("100", m["Ms"])
        Assert.Equal("42",  m["Deaths"])
    }

    ; ============================================================
    ; Delete
    ; ============================================================

    delete_key_removes_only_that_key()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("a", "S", "Keep")
        iniInst.Write("b", "S", "Remove")

        iniInst.Delete("S", "Remove")

        Assert.Equal("a", iniInst.Read("S", "Keep"))
        Assert.Equal("",  iniInst.Read("S", "Remove"))
    }

    delete_section_removes_entire_section()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("a", "Trash", "K1")
        iniInst.Write("b", "Trash", "K2")
        iniInst.Write("c", "Keep",  "K1")

        iniInst.Delete("Trash")

        Assert.False(iniInst.SectionExists("Trash"))
        Assert.True(iniInst.SectionExists("Keep"))
    }

    delete_does_not_throw_for_missing_section_or_key()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        ; Nothing written yet - delete must be a no-op
        iniInst.Delete("NonExistent")
        iniInst.Delete("Also", "Missing")
        Assert.True(true)   ; reached here without throw
    }

    ; ============================================================
    ; Exists / SectionExists / GetPath
    ; ============================================================

    exists_true_after_write()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("v", "S", "K")
        Assert.True(iniInst.Exists())
    }

    exists_false_before_first_write()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        Assert.False(iniInst.Exists())
    }

    section_exists_true_when_section_has_keys()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("v", "S", "K")
        Assert.True(iniInst.SectionExists("S"))
    }

    section_exists_false_for_missing_section()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        iniInst.Write("v", "S", "K")
        Assert.False(iniInst.SectionExists("Other"))
    }

    get_path_returns_constructor_arg()
    {
        path := Fixtures.TempPath("ini")
        iniInst := IniFile(path)
        Assert.Equal(path, iniInst.GetPath())
    }
}

TestRegistry.Register(IniFileTests)

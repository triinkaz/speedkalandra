; ============================================================
; JsonFile tests
; ============================================================
;
; JsonFile + JsonNull + JsonBool:
;   - Stringify(value, indent := 2) -> JSON string
;   - Parse(jsonStr) -> AHK structure (Map/Array/Integer/Float/String/0/1/"")
;   - Write(value, indent) -> AtomicWriter at the constructor's path
;   - EscapeString(s) -> escapes without enclosing quotes
;
; Naming: `jsonInst` instead of `jsonFile` to avoid colliding with
; the class.

; ------------------------------------------------------------
; Helper class used in stringify_uses_to_map_for_objects.
; Defined at top-level scope to be visible to the test.
; ------------------------------------------------------------
class _JsonTestToMapObj
{
    ToMap()
    {
        return Map("name", "test", "id", 42)
    }
}

class _JsonTestPlainObj
{
    ; No ToMap and no special __New()
}


class JsonFileTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_on_empty_path",
        "constructor_throws_on_whitespace_path",

        ; --- Stringify: primitives ---
        "stringify_integer",
        "stringify_negative_integer",
        "stringify_float",
        "stringify_simple_string",
        "stringify_empty_string",
        "stringify_string_with_escape_chars",
        "stringify_string_with_unicode_control_char",

        ; --- Stringify: wrappers ---
        "stringify_json_bool_true",
        "stringify_json_bool_false",
        "stringify_json_null",

        ; --- Stringify: collections ---
        "stringify_empty_map",
        "stringify_empty_array",
        "stringify_map_with_keys",
        "stringify_array_with_values",
        "stringify_nested_structure",

        ; --- Stringify: indent ---
        "stringify_indent_zero_is_minified",
        "stringify_indent_two_adds_newlines_and_spaces",

        ; --- Stringify: ToMap fallback ---
        "stringify_uses_to_map_for_custom_objects",
        "stringify_throws_for_objects_without_to_map",

        ; --- Parse: primitives ---
        "parse_integer_returns_integer_type",
        "parse_float_returns_float_type",
        "parse_negative_number",
        "parse_simple_string",
        "parse_string_with_escapes",
        "parse_unicode_escape",
        "parse_true_returns_one",
        "parse_false_returns_zero",
        "parse_null_returns_empty_string",

        ; --- Parse: collections ---
        "parse_empty_object_returns_empty_map",
        "parse_empty_array_returns_empty_array",
        "parse_object_with_keys",
        "parse_array_with_values",
        "parse_nested_structure",

        ; --- Parse: errors ---
        "parse_throws_on_empty_input",
        "parse_throws_on_extra_content_after_json",
        "parse_throws_on_unclosed_string",
        "parse_throws_on_unclosed_object",
        "parse_throws_on_invalid_escape",
        "parse_throws_on_non_string_input",

        ; --- Roundtrip ---
        "roundtrip_stringify_parse_preserves_simple_map",
        "roundtrip_stringify_parse_preserves_nested",

        ; --- EscapeString static ---
        "escape_string_returns_escapes_without_surrounding_quotes",

        ; --- Write ---
        "write_persists_serialized_value_via_atomic_writer",
        "write_does_not_leave_tmp_behind",
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_on_empty_path()
    {
        Assert.Throws(ValueError, () => JsonFile(""))
    }

    constructor_throws_on_whitespace_path()
    {
        Assert.Throws(ValueError, () => JsonFile("  "))
    }

    ; ============================================================
    ; Stringify: primitives
    ; ============================================================

    stringify_integer()
    {
        Assert.Equal("42", JsonFile.Stringify(42))
    }

    stringify_negative_integer()
    {
        Assert.Equal("-5", JsonFile.Stringify(-5))
    }

    stringify_float()
    {
        ; AHK Float -> string. Accepts "3.14" or "3.140000".
        result := JsonFile.Stringify(3.14)
        Assert.Contains("3.14", result)
    }

    stringify_simple_string()
    {
        Assert.Equal('"hello"', JsonFile.Stringify("hello"))
    }

    stringify_empty_string()
    {
        Assert.Equal('""', JsonFile.Stringify(""))
    }

    stringify_string_with_escape_chars()
    {
        Assert.Equal('"a\nb"', JsonFile.Stringify("a`nb"))
        Assert.Equal('"a\tb"', JsonFile.Stringify("a`tb"))
        Assert.Equal('"a\\b"', JsonFile.Stringify("a\b"))
        Assert.Equal('"a\"b"', JsonFile.Stringify('a"b'))
    }

    stringify_string_with_unicode_control_char()
    {
        ; Chr(7) = bell, codepoint 7 (< 32 -> \uXXXX)
        result := JsonFile.Stringify(Chr(7))
        Assert.Equal('"\u0007"', result)
    }

    ; ============================================================
    ; Stringify: wrappers
    ; ============================================================

    stringify_json_bool_true()
    {
        Assert.Equal("true", JsonFile.Stringify(JsonBool(true)))
    }

    stringify_json_bool_false()
    {
        Assert.Equal("false", JsonFile.Stringify(JsonBool(false)))
    }

    stringify_json_null()
    {
        Assert.Equal("null", JsonFile.Stringify(JsonNull()))
    }

    ; ============================================================
    ; Stringify: collections
    ; ============================================================

    stringify_empty_map()
    {
        Assert.Equal("{}", JsonFile.Stringify(Map()))
    }

    stringify_empty_array()
    {
        Assert.Equal("[]", JsonFile.Stringify([]))
    }

    stringify_map_with_keys()
    {
        result := JsonFile.Stringify(Map("name", "alice", "age", 30), 0)
        ; Minified with indent=0 -> '{"name":"alice","age":30}'
        Assert.Contains('"name":"alice"', result)
        Assert.Contains('"age":30',       result)
    }

    stringify_array_with_values()
    {
        result := JsonFile.Stringify([1, 2, 3], 0)
        Assert.Equal("[1,2,3]", result)
    }

    stringify_nested_structure()
    {
        result := JsonFile.Stringify(Map("items", [1, 2], "meta", Map("v", 1)), 0)
        Assert.Contains('"items":[1,2]', result)
        Assert.Contains('"meta":{"v":1}', result)
    }

    ; ============================================================
    ; Stringify: indent
    ; ============================================================

    stringify_indent_zero_is_minified()
    {
        result := JsonFile.Stringify(Map("a", 1), 0)
        ; Minified: no newlines, no spaces after :
        Assert.False(InStr(result, "`n") > 0, "Minified must not have newlines")
    }

    stringify_indent_two_adds_newlines_and_spaces()
    {
        result := JsonFile.Stringify(Map("a", 1), 2)
        Assert.True(InStr(result, "`n") > 0, "Pretty must have newlines")
        Assert.True(InStr(result, "  ") > 0, "Pretty must have 2-space indent")
    }

    ; ============================================================
    ; Stringify: ToMap fallback
    ; ============================================================

    stringify_uses_to_map_for_custom_objects()
    {
        obj := _JsonTestToMapObj()
        result := JsonFile.Stringify(obj, 0)
        Assert.Contains('"name":"test"', result)
        Assert.Contains('"id":42',       result)
    }

    stringify_throws_for_objects_without_to_map()
    {
        obj := _JsonTestPlainObj()
        Assert.Throws(TypeError, () => JsonFile.Stringify(obj))
    }

    ; ============================================================
    ; Parse: primitives
    ; ============================================================

    parse_integer_returns_integer_type()
    {
        result := JsonFile.Parse("42")
        Assert.Equal(42, result)
        Assert.Equal("Integer", Type(result))
    }

    parse_float_returns_float_type()
    {
        result := JsonFile.Parse("3.14")
        Assert.Near(3.14, result, 0.0001)
        Assert.Equal("Float", Type(result))
    }

    parse_negative_number()
    {
        Assert.Equal(-7, JsonFile.Parse("-7"))
    }

    parse_simple_string()
    {
        Assert.Equal("hello", JsonFile.Parse('"hello"'))
    }

    parse_string_with_escapes()
    {
        Assert.Equal("a`nb",  JsonFile.Parse('"a\nb"'))
        Assert.Equal("a`tb",  JsonFile.Parse('"a\tb"'))
        Assert.Equal('a"b',   JsonFile.Parse('"a\"b"'))
        Assert.Equal("a\b",   JsonFile.Parse('"a\\b"'))
    }

    parse_unicode_escape()
    {
        ; \u0041 = "A"
        Assert.Equal("A", JsonFile.Parse('"\u0041"'))
    }

    parse_true_returns_one()
    {
        Assert.Equal(1, JsonFile.Parse("true"))
    }

    parse_false_returns_zero()
    {
        Assert.Equal(0, JsonFile.Parse("false"))
    }

    parse_null_returns_empty_string()
    {
        Assert.Equal("", JsonFile.Parse("null"))
    }

    ; ============================================================
    ; Parse: collections
    ; ============================================================

    parse_empty_object_returns_empty_map()
    {
        result := JsonFile.Parse("{}")
        Assert.IsType(Map, result)
        Assert.Equal(0, result.Count)
    }

    parse_empty_array_returns_empty_array()
    {
        result := JsonFile.Parse("[]")
        Assert.IsType(Array, result)
        Assert.Equal(0, result.Length)
    }

    parse_object_with_keys()
    {
        result := JsonFile.Parse('{"name":"alice","age":30}')
        Assert.Equal("alice", result["name"])
        Assert.Equal(30,      result["age"])
    }

    parse_array_with_values()
    {
        result := JsonFile.Parse("[1, 2, 3]")
        Assert.Equal([1, 2, 3], result)
    }

    parse_nested_structure()
    {
        result := JsonFile.Parse('{"items":[1,2],"meta":{"v":1}}')
        Assert.Equal([1, 2], result["items"])
        Assert.Equal(1,      result["meta"]["v"])
    }

    ; ============================================================
    ; Parse: errors
    ; ============================================================

    parse_throws_on_empty_input()
    {
        Assert.Throws(Error, () => JsonFile.Parse(""))
    }

    parse_throws_on_extra_content_after_json()
    {
        Assert.Throws(Error, () => JsonFile.Parse("42 extra_stuff"))
    }

    parse_throws_on_unclosed_string()
    {
        Assert.Throws(Error, () => JsonFile.Parse('"unclosed'))
    }

    parse_throws_on_unclosed_object()
    {
        Assert.Throws(Error, () => JsonFile.Parse('{"a":1'))
    }

    parse_throws_on_invalid_escape()
    {
        Assert.Throws(Error, () => JsonFile.Parse('"\q"'))
    }

    parse_throws_on_non_string_input()
    {
        Assert.Throws(TypeError, () => JsonFile.Parse(Map()))
    }

    ; ============================================================
    ; Roundtrip
    ; ============================================================

    roundtrip_stringify_parse_preserves_simple_map()
    {
        original := Map("name", "test", "count", 42)
        json := JsonFile.Stringify(original, 0)
        recovered := JsonFile.Parse(json)
        Assert.Equal("test", recovered["name"])
        Assert.Equal(42,     recovered["count"])
    }

    roundtrip_stringify_parse_preserves_nested()
    {
        original := Map(
            "id", "abc",
            "tags", ["one", "two"],
            "meta", Map("active", JsonBool(true), "version", 1)
        )
        json := JsonFile.Stringify(original, 0)
        recovered := JsonFile.Parse(json)
        Assert.Equal("abc", recovered["id"])
        Assert.Equal(["one", "two"], recovered["tags"])
        Assert.Equal(1, recovered["meta"]["active"], "JsonBool(true) parses as 1")
        Assert.Equal(1, recovered["meta"]["version"])
    }

    ; ============================================================
    ; EscapeString static
    ; ============================================================

    escape_string_returns_escapes_without_surrounding_quotes()
    {
        result := JsonFile.EscapeString('a"b`nc')
        ; No surrounding quotes, but internal escapes applied
        Assert.Equal('a\"b\nc', result)
    }

    ; ============================================================
    ; Write
    ; ============================================================

    write_persists_serialized_value_via_atomic_writer()
    {
        path := Fixtures.TempPath("json")
        jsonInst := JsonFile(path)
        jsonInst.Write(Map("k", "v"), 0)

        Assert.True(FileExist(path))
        content := Fixtures.FileReadAll(path)
        Assert.Contains('"k":"v"', content)
    }

    write_does_not_leave_tmp_behind()
    {
        path := Fixtures.TempPath("json")
        jsonInst := JsonFile(path)
        jsonInst.Write(Map("k", "v"))
        Assert.False(FileExist(path ".tmp"))
    }
}

TestRegistry.Register(JsonFileTests)

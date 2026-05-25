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
        ; Regression: numeric-looking STRINGS must stay strings.
        ; AHK v2's IsNumber("42") returns true, which used to make
        ; the serializer emit a bare JSON number — stripping the
        ; quotes and losing leading zeros / scientific-notation form.
        "stringify_numeric_looking_string_stays_string",
        "stringify_string_with_leading_zeros_preserves_leading_zeros",
        "stringify_string_with_scientific_notation_stays_string",
        "stringify_float_looking_string_stays_string",

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

        ; --- Parse: surrogate pairs (BMP+ chars like emoji) ---
        "parse_handles_surrogate_pair_for_emoji",
        "parse_throws_on_lone_high_surrogate",
        "parse_throws_on_lone_low_surrogate",
        "parse_throws_on_high_surrogate_not_followed_by_low",

        ; --- Parse: strict number grammar (RFC 8259) ---
        "parse_throws_on_leading_zero_integer",
        "parse_throws_on_dot_without_fractional_digits",
        "parse_throws_on_exponent_without_digits",
        "parse_throws_on_exponent_sign_without_digits",

        ; --- Parse: trailing comma (JSON forbids) ---
        "parse_throws_on_trailing_comma_in_array",
        "parse_throws_on_trailing_comma_in_object",

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

    ; ------------------------------------------------------------
    ; Regression: numeric-looking strings must serialize AS strings
    ; ------------------------------------------------------------
    ;
    ; AHK v2's IsNumber() returns true for strings that PARSE as
    ; numbers ("42", "00123", "1e5"), not just for values whose
    ; concrete type is Integer or Float. The pre-fix serializer
    ; used IsNumber(v) to decide between the number and string
    ; branches, which meant "42" would emit a bare 42 in the JSON
    ; output — stripping the quotes and losing information when
    ; the string carried leading zeros ("00123"), scientific
    ; notation ("1e5"), or any non-canonical form a number-shaped
    ; string can take. The fix replaces IsNumber with a concrete-
    ; type check (Type(v) = "Integer" / "Float"), so values that
    ; were CREATED as strings stay strings regardless of how their
    ; characters happen to parse.

    stringify_numeric_looking_string_stays_string()
    {
        ; The shape that motivated the fix — a plain ASCII numeric
        ; string. Must come out quoted, not bare.
        Assert.Equal('"42"', JsonFile.Stringify("42"))
    }

    stringify_string_with_leading_zeros_preserves_leading_zeros()
    {
        ; The pre-fix bug was especially nasty here: "00123" would
        ; serialize as bare 123, silently losing the leading zeros.
        ; If a downstream system relied on the string form (zone
        ; identifiers, zero-padded record IDs), the round-trip
        ; would corrupt the data without surfacing an error.
        Assert.Equal('"00123"', JsonFile.Stringify("00123"))
    }

    stringify_string_with_scientific_notation_stays_string()
    {
        ; AHK's IsNumber accepts "1e5" as a number. The serializer
        ; must still treat it as a string when that's its concrete
        ; type — emitting bare 1e5 would also change the textual
        ; form (numeric form in some serializers is 100000), which
        ; is silently destructive.
        Assert.Equal('"1e5"', JsonFile.Stringify("1e5"))
    }

    stringify_float_looking_string_stays_string()
    {
        ; Float-shaped strings ("3.14") parse as numbers via
        ; IsNumber too. Pin the string-stays-string contract for
        ; them explicitly.
        Assert.Equal('"3.14"', JsonFile.Stringify("3.14"))
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

    ; ============================================================
    ; Parse: surrogate pairs (BMP+ chars like emoji)
    ; ============================================================
    ;
    ; JSON encodes characters above the BMP as a high-surrogate +
    ; low-surrogate pair (RFC 8259 §7). Without surrogate handling,
    ; Chr() on a lone high surrogate emits ill-formed UTF-16; with
    ; it, the two escapes combine into a single codepoint that AHK
    ; can round-trip cleanly. Lone surrogates (high without low, or
    ; low alone) are malformed and must throw.

    parse_handles_surrogate_pair_for_emoji()
    {
        ; U+1F600 (GRINNING FACE) is encoded as \uD83D\uDE00.
        ; The combined codepoint is 0x10000 + (0xD83D - 0xD800) * 0x400
        ; + (0xDE00 - 0xDC00) = 0x1F600.
        result := JsonFile.Parse('"\uD83D\uDE00"')
        Assert.Equal(Chr(0x1F600), result,
            "Surrogate pair must combine into U+1F600")
    }

    parse_throws_on_lone_high_surrogate()
    {
        ; \uD83D alone (no following \uXXXX) is malformed.
        Assert.Throws(Error, () => JsonFile.Parse('"\uD83D"'),
            "Lone high surrogate must throw")
    }

    parse_throws_on_lone_low_surrogate()
    {
        ; \uDE00 with no preceding high surrogate is malformed.
        Assert.Throws(Error, () => JsonFile.Parse('"\uDE00"'),
            "Lone low surrogate must throw")
    }

    parse_throws_on_high_surrogate_not_followed_by_low()
    {
        ; \uD83D followed by a non-surrogate \u (\u0041 = 'A') is
        ; malformed: the high surrogate demands a low surrogate.
        Assert.Throws(Error, () => JsonFile.Parse('"\uD83D\u0041"'),
            "High surrogate not followed by low surrogate must throw")
    }

    ; ============================================================
    ; Parse: strict number grammar (RFC 8259 §6)
    ; ============================================================
    ;
    ; The lax pre-fix parser accepted 01, 1., 1e and other shapes
    ; that JSON forbids. Each of these would silently feed into
    ; Integer()/Float() and either round-trip with surprising values
    ; or throw with a confusing low-level message. The hardened
    ; parser rejects these at the JSON layer with a clear message.

    parse_throws_on_leading_zero_integer()
    {
        ; "01" is malformed (RFC 8259 §6: a single 0 OR 1-9 followed
        ; by more digits; never 0 followed by more digits).
        Assert.Throws(Error, () => JsonFile.Parse("01"),
            "Leading zero must throw")
        Assert.Throws(Error, () => JsonFile.Parse("007"),
            "Multiple leading zeros must throw")
    }

    parse_throws_on_dot_without_fractional_digits()
    {
        ; "1." is malformed: the decimal point demands at least one
        ; digit after it.
        Assert.Throws(Error, () => JsonFile.Parse("1."),
            "Decimal point without fractional digits must throw")
    }

    parse_throws_on_exponent_without_digits()
    {
        ; "1e" is malformed: the exponent marker demands at least
        ; one digit (with or without sign).
        Assert.Throws(Error, () => JsonFile.Parse("1e"),
            "Exponent marker without digits must throw")
        Assert.Throws(Error, () => JsonFile.Parse("1E"),
            "Uppercase exponent marker without digits must throw")
    }

    parse_throws_on_exponent_sign_without_digits()
    {
        ; "1e+" and "1e-" are malformed: even with the sign, at
        ; least one digit must follow.
        Assert.Throws(Error, () => JsonFile.Parse("1e+"),
            "Exponent with sign but no digits must throw")
        Assert.Throws(Error, () => JsonFile.Parse("1e-"),
            "Exponent with negative sign but no digits must throw")
    }

    ; ============================================================
    ; Parse: trailing comma (JSON forbids)
    ; ============================================================
    ;
    ; JSON (RFC 8259) does NOT allow trailing commas in arrays or
    ; objects — unlike JavaScript object literals. The parser must
    ; reject them so a stray comma in a hand-edited or AI-generated
    ; file surfaces with a clear error instead of being silently
    ; tolerated.

    parse_throws_on_trailing_comma_in_array()
    {
        Assert.Throws(Error, () => JsonFile.Parse("[1, 2, 3,]"),
            "Trailing comma in array must throw")
    }

    parse_throws_on_trailing_comma_in_object()
    {
        Assert.Throws(Error, () => JsonFile.Parse('{"a":1,}'),
            "Trailing comma in object must throw")
    }
}

TestRegistry.Register(JsonFileTests)

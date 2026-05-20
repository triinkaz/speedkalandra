; ============================================================
; Duration — value object representing duration in milliseconds
; ============================================================
;
; Immutable (operations return a new instance).
; Validation in the constructor: throws on invalid ms.
;
; Usage:
;   d := Duration(1500)
;   d.Formatted()     ; "00:01"
;   d2 := d.Plus(Duration.FromSeconds(30))
;   d2.Formatted()    ; "00:31"
;
; AVAILABLE FORMATS:
;   d.Formatted()           - always MM:SS, with long minutes ("105:30")
;                             Speedrun philosophy: consistent padding.
;   Duration.FormatMs(ms)   - static, MM:SS if < 1h, H:MM:SS if >= 1h.
;                             "Long" version used in TrayTip, dialogs
;                             and overlay widgets (Compact/Micro/Plot).

class Duration
{
    ms := 0

    __New(ms)
    {
        if (!IsNumber(ms))
            throw TypeError("Duration.ms must be a number, got: " Type(ms) " (" ms ")")
        if (ms < 0)
            throw ValueError("Duration.ms must be >= 0, got: " ms)
        ; Coerce float -> integer (preserves ms precision)
        this.ms := Integer(ms)
    }

    static Zero() => Duration(0)
    static FromSeconds(s) => Duration(s * 1000)
    static FromMinutes(m) => Duration(m * 60 * 1000)

    ; "MM:SS" format (up to 99:59 without hours). Above that uses long minutes.
    Formatted()
    {
        totalSec := this.ms // 1000
        m := totalSec // 60
        s := Mod(totalSec, 60)
        return Format("{:02d}:{:02d}", m, s)
    }

    ; ============================================================
    ; FormatMs(ms) - static; "H:MM:SS" format if >= 1h, "MM:SS" sub-1h.
    ;
    ; Consolidated path: previously 4 identical copies lived in
    ; app.ahk, run_stats_plot_builder.ahk, and the compact/micro
    ; widgets. Steve keeps _FormatMsWithMillis (different format, with
    ; hundredths for high-frequency visual motion).
    ;
    ; Accepts any number (negatives become 0, floats truncate to int).
    ; Does not use a Duration instance because the constructor throws on
    ; ms<0; this API is defensive to integrate with code that may pass
    ; bad values (external services, INI hydration, etc.).
    ; ============================================================
    static FormatMs(ms)
    {
        if (!IsNumber(ms) || ms < 0)
            ms := 0
        n := Integer(ms)
        totalSec := Floor(n / 1000)
        h := Floor(totalSec / 3600)
        m := Floor(Mod(totalSec, 3600) / 60)
        s := Mod(totalSec, 60)
        if (h > 0)
            return Format("{:d}:{:02d}:{:02d}", h, m, s)
        return Format("{:02d}:{:02d}", m, s)
    }

    Plus(other)        => Duration(this.ms + other.ms)
    Minus(other)       => Duration(Max(0, this.ms - other.ms))
    Equals(other)      => this.ms = other.ms
    GreaterThan(other) => this.ms > other.ms
    LessThan(other)    => this.ms < other.ms
    IsZero()           => this.ms = 0
}

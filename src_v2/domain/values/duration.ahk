; ============================================================
; Duration — value object para representar duracao em milissegundos
; ============================================================
;
; Imutavel (operacoes retornam nova instancia).
; Validacao na construcao: estoura se ms invalido.
;
; Uso:
;   d := Duration(1500)
;   d.Formatted()     ; "00:01"
;   d2 := d.Plus(Duration.FromSeconds(30))
;   d2.Formatted()    ; "00:31"
;
; FORMATOS DISPONIVEIS:
;   d.Formatted()           - sempre MM:SS, com minutos longos ("105:30")
;                             Filosofia speedrun: padding consistente.
;   Duration.FormatMs(ms)   - static, MM:SS se < 1h, H:MM:SS se >= 1h.
;                             Versao "longa" usada em TrayTip, dialogs e
;                             widgets de overlay (Compact/Micro/Plot).
;                             Consolidado em #19 (auditoria pre-release).

class Duration
{
    ms := 0

    __New(ms)
    {
        if (!IsNumber(ms))
            throw TypeError("Duration.ms deve ser numero, recebi: " Type(ms) " (" ms ")")
        if (ms < 0)
            throw ValueError("Duration.ms deve ser >= 0, recebi: " ms)
        ; Coerce float -> integer (mantem precisao em ms)
        this.ms := Integer(ms)
    }

    static Zero() => Duration(0)
    static FromSeconds(s) => Duration(s * 1000)
    static FromMinutes(m) => Duration(m * 60 * 1000)

    ; Formato "MM:SS" (ate 99:59 sem hora). Acima disso usa minutos longos.
    Formatted()
    {
        totalSec := this.ms // 1000
        m := totalSec // 60
        s := Mod(totalSec, 60)
        return Format("{:02d}:{:02d}", m, s)
    }

    ; ============================================================
    ; FormatMs(ms) - static; formato "H:MM:SS" se >= 1h, "MM:SS" sub-1h.
    ;
    ; Consolidado em v0.1.2 (auditoria #19): antes 4 copias identicas
    ; em app.ahk, run_stats_plot_builder.ahk, compact/micro widgets.
    ; Steve mantem _FormatMsWithMillis (formato diferente, com
    ; centesimos pra movimento visual de alta frequencia).
    ;
    ; Aceita qualquer numero (negativos viram 0, floats truncam pra int).
    ; Nao usa Duration instance porque o construtor estoura em ms<0;
    ; esta API eh defensiva pra integrar com codigo que pode passar
    ; valores ruins (services externos, hidratacao de INI etc).
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

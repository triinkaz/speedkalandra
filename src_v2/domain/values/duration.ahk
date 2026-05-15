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

    Plus(other)        => Duration(this.ms + other.ms)
    Minus(other)       => Duration(Max(0, this.ms - other.ms))
    Equals(other)      => this.ms = other.ms
    GreaterThan(other) => this.ms > other.ms
    LessThan(other)    => this.ms < other.ms
    IsZero()           => this.ms = 0
}

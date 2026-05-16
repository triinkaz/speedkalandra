; ============================================================
; TestCase - classe base para suites de teste
; ============================================================
;
; Cada suite eh uma classe que extende TestCase e define:
;   - static Tests := ["nome_do_metodo_1", ...]  - lista explicita
;   - Setup()    (opcional) - roda antes de cada teste
;   - Teardown() (opcional) - roda depois de cada teste
;   - Metodos de teste cujo nome consta em static Tests
;
; O TestRunner cria UMA nova instancia da suite por teste, garantindo
; isolamento de estado entre testes. Setup roda em estado limpo.
;
; Discovery eh explicita (static Tests array) em vez de reflection
; porque enumerar metodos de uma classe em AHK v2 e' flaky, e porque
; queremos que adicionar um teste seja uma acao visivel no diff.
;
; Exemplo:
;
;   class FooTests extends TestCase
;   {
;       static Tests := [
;           "publishes_event_on_start",
;           "throws_when_already_started",
;       ]
;
;       Setup()
;       {
;           this.bus := Fixtures.MakeBus()
;           this.svc := FooService(this.bus)
;       }
;
;       publishes_event_on_start()
;       {
;           this.svc.Start()
;           Assert.Equal(1, this.bus.Subscribers("FooStarted"))
;       }
;   }
;
;   TestRegistry.Register(FooTests)

class TestCase
{
    ; Hook opcional - sobrescrito por subclasses
    Setup()
    {
    }

    ; Hook opcional - sobrescrito por subclasses
    Teardown()
    {
    }
}

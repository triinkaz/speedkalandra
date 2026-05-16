; ============================================================
; TestRegistry - registro de classes de teste
; ============================================================
;
; Cada arquivo de teste, no final, chama:
;   TestRegistry.Register(MinhaSuite)
;
; Isso popula um array que o TestRunner consome na hora de rodar.
;
; Por que registro explicito e nao auto-discovery por nome?
; - AHK v2 nao tem enumeracao de classes derivadas de uma base.
; - Auto-discovery por nome (varrer simbolos por prefixo "Test") seria
;   pior em ergonomia e nao pega classes com nomes que fogem do padrao.
; - Explicito eh visivel no diff e impossivel de esquecer "acidentalmente".

class TestRegistry
{
    static Classes := []

    static Register(cls)
    {
        if (!IsObject(cls))
            throw TypeError("TestRegistry.Register: argumento nao eh classe")
        if (!cls.HasOwnProp("Tests"))
            throw ValueError("TestCase '" cls.Prototype.__Class "' sem static Tests array")
        if (!(cls.Tests is Array))
            throw TypeError("TestCase '" cls.Prototype.__Class "': static Tests deve ser Array")
        TestRegistry.Classes.Push(cls)
    }

    static Reset()
    {
        TestRegistry.Classes := []
    }
}

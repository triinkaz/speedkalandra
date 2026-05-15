; ============================================================
; EventBus — pub/sub in-process, sincrono
; ============================================================
;
; Coracao da arquitetura. UI publica Commands, Services consomem
; e publicam Events, outros assinantes reagem.
;
; Uso:
;   bus := EventBus(logger)
;   bus.Subscribe(Events.RunPaused, MyHandler)
;   bus.Publish(Commands.PauseRequested)
;
; Caracteristicas:
;   - Sincrono: handlers rodam imediatamente em ordem de subscribe
;   - Tolerante a falhas: handler que estoura nao impede outros
;   - Erros sao logados via logger (nunca silenciados)
;   - Unsubscribe seguro durante Publish (clona array antes de iterar)
;
; NAO faz:
;   - Threading (AHK nao tem). Para "async" use SetTimer + Publish
;   - Filas persistentes. Eventos perdidos sao perdidos (sem replay)

class EventBus
{
    _subs   := Map()      ; eventName -> Array of callbacks
    _logger := ""

    __New(logger := "")
    {
        this._logger := IsObject(logger) ? logger : NullLogger()
    }

    ; ------------------------------------------------------------
    ; Subscribe(eventName, callback)
    ;   callback recebe (data) onde data eh o que foi passado em Publish
    ;   (string vazia se Publish nao passar data)
    ; Retorna um token que pode ser usado em Unsubscribe (a propria callback)
    ; ------------------------------------------------------------
    Subscribe(eventName, callback)
    {
        if (eventName = "")
            throw ValueError("EventBus.Subscribe: eventName vazio")
        if (!IsObject(callback))
            throw TypeError("EventBus.Subscribe: callback deve ser callable")

        if !this._subs.Has(eventName)
            this._subs[eventName] := []
        this._subs[eventName].Push(callback)

        this._logger.Debug("Subscribed to '" eventName "' (" this._subs[eventName].Length " total)", "EventBus")
        return callback
    }

    ; ------------------------------------------------------------
    ; Unsubscribe(eventName, callback)
    ;   Remove a callback do evento. Sem efeito se nao estava inscrita.
    ; ------------------------------------------------------------
    Unsubscribe(eventName, callback)
    {
        if !this._subs.Has(eventName)
            return false

        for i, cb in this._subs[eventName]
        {
            if (cb = callback)
            {
                this._subs[eventName].RemoveAt(i)
                this._logger.Debug("Unsubscribed from '" eventName "'", "EventBus")
                ; v17.15 (Bug #22): se ficou sem subscribers, apaga a
                ; key do Map. Evita _subs crescer indefinidamente em
                ; sessoes longas com ciclos Stop/Start (e mantem o
                ; Publish() fast-path quando ngm escuta o evento).
                if (this._subs[eventName].Length = 0)
                    this._subs.Delete(eventName)
                return true
            }
        }
        return false
    }

    ; ------------------------------------------------------------
    ; Publish(eventName, data := "")
    ;   Chama todas as callbacks inscritas em ordem de subscribe.
    ;   Erros sao isolados — uma callback que estoura nao impede as
    ;   demais. Erros sao logados como ERROR.
    ; ------------------------------------------------------------
    Publish(eventName, data := "")
    {
        if !this._subs.Has(eventName)
            return 0

        ; Clona para permitir Unsubscribe ou Subscribe novos durante o Publish
        callbacks := this._subs[eventName].Clone()
        delivered := 0

        for _, cb in callbacks
        {
            try
            {
                cb(data)
                delivered++
            }
            catch as e
            {
                this._logger.Error(
                    "Handler de '" eventName "' falhou: " e.Message
                    . " | What: " (e.HasOwnProp("What") ? e.What : "?")
                    . " | Line: " (e.HasOwnProp("Line") ? e.Line : "?"),
                    "EventBus"
                )
            }
        }

        return delivered
    }

    ; ------------------------------------------------------------
    ; Subscribers(eventName) -> int
    ;   Quantos handlers estao inscritos. Util para debug/teste.
    ; ------------------------------------------------------------
    Subscribers(eventName)
    {
        return this._subs.Has(eventName) ? this._subs[eventName].Length : 0
    }

    ; ------------------------------------------------------------
    ; Clear()
    ;   Remove TODOS os subscribers. Util em testes/teardown.
    ;   NAO use em producao.
    ; ------------------------------------------------------------
    Clear()
    {
        this._subs := Map()
    }
}

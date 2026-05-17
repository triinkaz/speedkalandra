; ============================================================
; RunState - persistable state of a run (Wave 6, minimal)
; ============================================================
;
; POST-DEMOLITION VERSION: 4 fields only.
;
;   runId     : "YYYYMMDD_HHMMSS" (stable id of the ongoing run) or ""
;   startedAt : "yyyy-MM-dd HH:mm:ss" start timestamp (string)
;   status    : "idle" | "running" | "paused" | "completed" | "cancelled"
;   runBaseMs : committed accumulated ms (TimerService persists)
;
; SERIALIZATION (INI section [RunState]):
;   RunId=20260512_142345
;   StartedAt=2026-05-12 14:23:45
;   Status=running
;   RunBaseMs=187432

class RunState
{
    runId     := ""
    startedAt := ""
    status    := "idle"
    runBaseMs := 0

    static Empty()
    {
        s := RunState()
        s.runId     := ""
        s.startedAt := ""
        s.status    := "idle"
        s.runBaseMs := 0
        return s
    }

    static FromMap(data)
    {
        s := RunState.Empty()
        if !IsObject(data)
            return s
        if data.Has("runId")
            s.runId := String(data["runId"])
        if data.Has("startedAt")
            s.startedAt := String(data["startedAt"])
        if data.Has("status")
        {
            v := String(data["status"])
            if (v = "idle" || v = "running" || v = "paused" || v = "completed" || v = "cancelled")
                s.status := v
        }
        if data.Has("runBaseMs")
        {
            try
                s.runBaseMs := Integer(data["runBaseMs"] + 0)
            catch
                s.runBaseMs := 0
            if (s.runBaseMs < 0)
                s.runBaseMs := 0
        }
        return s
    }

    ToMap()
    {
        return Map(
            "runId",     this.runId,
            "startedAt", this.startedAt,
            "status",    this.status,
            "runBaseMs", this.runBaseMs
        )
    }

    IsEmpty()       => (this.runId = "")
    IsRunning()     => (this.status = "running")
    IsPaused()      => (this.status = "paused")
    IsCompleted()   => (this.status = "completed")
    IsCancelled()   => (this.status = "cancelled")
    IsActive()      => (this.status = "running" || this.status = "paused")
}

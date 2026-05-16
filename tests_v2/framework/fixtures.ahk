; ============================================================
; Fixtures - helpers compartilhados entre testes
; ============================================================
;
; Padrao de uso:
;
;   Setup()
;   {
;       this.bus    := Fixtures.MakeBus()
;       this.clock  := Fixtures.MakeFakeClock()
;       this.tmpDir := Fixtures.TempDir()
;       this.iniFile := Fixtures.TempFile("[Section]`nKey=value", "ini")
;   }
;
;   Teardown()
;   {
;       Fixtures.CleanupAll()
;   }
;
; TempDir / TempFile / TempPath registram o caminho num pool.
; CleanupAll apaga tudo do pool (recursivamente pra dirs).
; Chamar CleanupAll em todo Teardown evita lixo em A_Temp quando
; uma suite cresce.
;
; MakeBus retorna EventBus(NullLogger) - o EventBus eh suficiente
; para a maioria dos testes; quando precisa inspecionar o log, troca
; pelo InMemoryLogger no Setup:
;
;   this.memLog := InMemoryLogger()
;   this.bus    := EventBus(this.memLog)
;
; (NOTA: nao usar nome `log` como local em testes - colide com global
; em algum arquivo do projeto e dispara #Warn LocalSameAsGlobal.
; Use `memLog`, `srvLog`, `nullLog`.)

class Fixtures
{
    static _tempPaths := []

    ; ============================================================
    ; Tempfiles / tempdirs / temppaths
    ; ============================================================

    ; Cria um diretorio temporario, registra para cleanup, retorna path.
    static TempDir()
    {
        Loop
        {
            path := A_Temp "\sk_test_" Random(100000, 999999)
            if !FileExist(path) && !DirExist(path)
            {
                DirCreate(path)
                Fixtures._tempPaths.Push(path)
                return path
            }
        }
    }

    ; Cria um arquivo temporario com conteudo opcional. Registra para
    ; cleanup. Retorna path.
    static TempFile(content := "", extension := "txt")
    {
        Loop
        {
            path := A_Temp "\sk_test_" Random(100000, 999999) "." extension
            if !FileExist(path)
                break
        }
        FileAppend(content, path, "UTF-8")
        Fixtures._tempPaths.Push(path)
        return path
    }

    ; Gera um path unico SEM criar o arquivo. Util quando o SUT eh
    ; quem deve criar o arquivo (ex: LogService cria no primeiro append,
    ; rotation acontece no construtor antes do append). Registra para
    ; cleanup mesmo assim - se o SUT nao criar, CleanupAll vira no-op
    ; nesse path. Se criar, e' apagado.
    static TempPath(extension := "tmp")
    {
        Loop
        {
            path := A_Temp "\sk_test_" Random(100000, 999999) "." extension
            if !FileExist(path)
            {
                Fixtures._tempPaths.Push(path)
                return path
            }
        }
    }

    ; Registra um path externo no pool de cleanup. Util quando o
    ; SUT cria arquivos derivados (ex: LogService cria .log.old).
    static RegisterTempPath(path)
    {
        Fixtures._tempPaths.Push(path)
    }

    static CleanupAll()
    {
        for _, path in Fixtures._tempPaths
        {
            try
            {
                if DirExist(path)
                    DirDelete(path, true)
                else if FileExist(path)
                    FileDelete(path)
            }
            catch
            {
                ; ignora - tempfile pode ter sumido por outras causas
            }
        }
        Fixtures._tempPaths := []
    }

    ; ============================================================
    ; Inspecao de arquivos (uteis em testes de I/O)
    ; ============================================================

    ; Conta newlines (`n) no arquivo. LogService sempre termina cada
    ; entry com `n, entao isso conta entries efetivas. Retorna 0 se
    ; o arquivo nao existe ou esta vazio.
    static FileLineCount(path)
    {
        if !FileExist(path)
            return 0
        content := FileRead(path, "UTF-8")
        if (content = "")
            return 0
        count := 0
        Loop Parse, content
        {
            if (A_LoopField = "`n")
                count += 1
        }
        return count
    }

    ; Le o arquivo inteiro como string UTF-8. Retorna "" se nao existe.
    static FileReadAll(path)
    {
        if !FileExist(path)
            return ""
        return FileRead(path, "UTF-8")
    }

    ; ============================================================
    ; Factories de objetos comuns
    ; ============================================================

    static MakeBus()
    {
        return EventBus(NullLogger())
    }

    static MakeBusWithLog(&logOut)
    {
        logOut := InMemoryLogger()
        return EventBus(logOut)
    }

    static MakeFakeClock(initialMs := 0, initialNow := "20260101000000")
    {
        return FakeClock(initialNow, initialMs)
    }

    static MakeNullLogger()
    {
        return NullLogger()
    }

    static MakeInMemoryLogger()
    {
        return InMemoryLogger()
    }
}

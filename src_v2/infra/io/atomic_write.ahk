; ============================================================
; AtomicWriter — escrita resiliente de arquivos (refactor R10)
; ============================================================
;
; Pattern classico Unix/Windows para minimizar risco de corrupcao
; quando o app crasha ou o sistema desliga no meio de um Save:
;
;   1. Escreve o conteudo em <path>.tmp
;   2. FileMove <path>.tmp -> <path> (substitui se path existir)
;
; NOTA SOBRE ATOMICIDADE (v17.15 - Bug #27, correcao da doc):
;
;   Esta doc anteriormente afirmava que FileMove no NTFS eh
;   "totalmente atomico". ISSO NAO EH VERDADE no Windows.
;
;   FileMove do AHK chama MoveFileEx com MOVEFILE_REPLACE_EXISTING.
;   Quando o destino existe, a implementacao do Windows faz
;   essencialmente "delete dst + rename src". Existe uma janela
;   curta de inconsistencia entre essas duas operacoes.
;
;   Pra atomicidade REAL em Windows precisa de ReplaceFileW ou
;   MoveFileTransacted (este ultimo deprecated). Nenhum dos dois
;   eh exposto pelo FileMove do AHK.
;
;   RISCO ACEITO: a janela de inconsistencia eh muito curta
;   (~1ms) e nosso uso eh single-threaded, sem concorrencia
;   externa. Pra um app desktop com saves esporadicos (run state,
;   PBs, settings), o risco eh aceitavel. Mesmo crashando dentro
;   da janela, o .tmp sobrevive com o conteudo novo — cleanup
;   manual eh possivel.
;
; PROBLEMA QUE RESOLVE (mesmo sem ser totalmente atomico):
;
;   Antes do R10, varios saves faziam:
;       try FileDelete(path)
;       FileAppend(json, path, "UTF-8")
;
;   Se crash ENTRE FileDelete e FileAppend, o arquivo eh perdido
;   permanentemente. AtomicWriter elimina ESSA classe de bug —
;   o destino so eh tocado no momento do FileMove.
;
; ORFAOS:
;
;   Se .tmp orfao existir de execucao anterior crashada,
;   FileAppend cria fresh (sem append a residuo) porque o .tmp
;   eh deletado primeiro. Logica defensiva: garante limpeza
;   antes de cada escrita.
;
; LIMITES:
;
;   - Windows/NTFS: "quasi-atomico" (janela curta). Ok pra uso
;     single-thread em desktop.
;   - FAT32/exFAT: comportamento similar mas com mais variancia.
;     Risco aceito — usuarios em FAT32 sao ~0% do publico-alvo.
;   - Path em rede: latencia + falhas de rede aumentam a janela
;     de risco. Crash no meio pode deixar .tmp orfao na origem.
;
; USO:
;
;   AtomicWriter.WriteAll(path, "conteudo completo")
;   AtomicWriter.WriteAll(path, jsonStr, "UTF-8")
;   AtomicWriter.WriteAll(path, csvBuffer, "UTF-8")


class AtomicWriter
{
    ; ------------------------------------------------------------
    ; WriteAll(path, content, encoding := "UTF-8")
    ;
    ; Escreve content em path de forma atomica via .tmp + FileMove.
    ; Sobrescreve path se ja existe. Cria diretorio se nao existir.
    ;
    ; Args:
    ;   path     : caminho final (ex: "C:\...\step_summary.csv")
    ;   content  : string (UTF-8 padrao). Pode ser vazia (cria arquivo vazio).
    ;   encoding : "UTF-8" (default), "UTF-16", "CP1252", etc.
    ;              Mesmos valores aceitos por FileAppend do AHK v2.
    ;
    ; Throws: OSError se FileAppend ou FileMove falhar (disco cheio,
    ;         permission denied, path invalido).
    ; ------------------------------------------------------------
    static WriteAll(path, content, encoding := "UTF-8")
    {
        if (Trim(String(path)) = "")
            throw ValueError("AtomicWriter.WriteAll: 'path' obrigatorio")

        ; Garante diretorio (FileAppend nao cria sozinho)
        SplitPath(path, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)

        tmpPath := path ".tmp"

        ; Cleanup defensivo: se ha .tmp orfao de execucao anterior
        ; crashada, deleta antes pra evitar append em residuo.
        if FileExist(tmpPath)
        {
            try FileDelete(tmpPath)
        }

        ; Escreve conteudo inteiro em .tmp
        FileAppend(content, tmpPath, encoding)

        ; FileMove com overwrite=true substitui o destino se existir.
        ; Implementacao Windows (MoveFileEx + MOVEFILE_REPLACE_EXISTING)
        ; faz delete-then-rename, com janela curta de inconsistencia.
        ; Ok pro uso single-thread do app. Vide LIMITES no docstring.
        FileMove(tmpPath, path, true)
    }
}

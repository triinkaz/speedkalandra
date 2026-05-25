; AtomicWriter — resilient file writing through the classic
; .tmp + rename pattern, to minimize corruption risk when the app
; crashes or the system shuts down mid-Save:
;
;   1. Write the entire content to <path>.tmp (TRUNCATING any
;      leftover .tmp from a previous crashed save)
;   2. FileMove <path>.tmp → <path> (replacing <path> if it exists)
;
; Atomicity caveat: this is NOT fully atomic on Windows. AHK's
; FileMove calls MoveFileEx with MOVEFILE_REPLACE_EXISTING, which
; (when the destination exists) is implemented as "delete dst +
; rename src". There's a short window of inconsistency between
; those two operations. True atomicity would need ReplaceFileW or
; MoveFileTransacted (the latter is deprecated), and neither is
; exposed by AHK's FileMove.
;
; That risk is accepted here: the window is ~1 ms, the app is
; single-threaded with no external concurrency, and the saves
; involved are sporadic (run state, PBs, settings). If a crash
; lands in that window, the .tmp survives with the new content, so
; manual recovery is still possible.
;
; What this DOES eliminate is the previous pattern of
;   try FileDelete(path)
;   FileAppend(content, path, "UTF-8")
; where a crash between the two steps lost the file permanently.
; AtomicWriter only touches the destination at FileMove time.
;
; Orphans: a leftover .tmp from a prior crashed save is TRUNCATED
; on open (FileOpen with "w" mode), so the new content is the
; only content the .tmp ever holds. The previous version used
; `try FileDelete(tmpPath)` + `FileAppend`, where a silent
; FileDelete failure (file locked by antivirus, sharing
; violation, permission glitch) would leave the .tmp alive and
; the subsequent FileAppend would concatenate the new content
; onto the stale one — silently corrupting the next FileMove's
; destination. FileOpen "w" cannot fail the same way: it either
; opens with the file truncated, or returns 0 and we throw.
;
; Surface-level limits:
;   Windows / NTFS  — quasi-atomic; fine for single-thread desktop use.
;   FAT32 / exFAT   — similar behavior but more variance; risk accepted.
;   Network paths   — latency widens the window; a crash midway can
;                     leave an orphan .tmp on the source.
;
; Usage:
;   AtomicWriter.WriteAll(path, "complete content")
;   AtomicWriter.WriteAll(path, jsonStr, "UTF-8")
;   AtomicWriter.WriteAll(path, csvBuffer, "UTF-8")


class AtomicWriter
{
    ; Writes `content` to `path` atomically via .tmp + FileMove.
    ; Overwrites `path` if it already exists; creates parent
    ; directory when missing.
    ;
    ; Arguments:
    ;   path     — final path (e.g. "C:\...\step_summary.csv")
    ;   content  — string. May be empty (creates an empty file).
    ;   encoding — "UTF-8" (default), "UTF-16", "CP1252", …; same
    ;              values FileOpen accepts.
    ;
    ; Throws OSError when FileOpen, .Write, or FileMove fails
    ; (disk full, permission denied, invalid path, file locked).
    static WriteAll(path, content, encoding := "UTF-8")
    {
        if (Trim(String(path)) = "")
            throw ValueError("AtomicWriter.WriteAll: 'path' is required")

        ; Ensure directory (FileOpen does not create it on its own)
        SplitPath(path, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)

        tmpPath := path ".tmp"

        ; Open the .tmp in write mode. "w" mode TRUNCATES any
        ; existing content (a leftover from a previous crashed
        ; save), so the new write is guaranteed not to be
        ; appended onto stale bytes. FileOpen returns 0 on
        ; failure (locked file, permission, etc.) — we throw
        ; an OSError in that case so the caller sees a hard
        ; failure rather than silently writing nothing.
        f := FileOpen(tmpPath, "w", encoding)
        if !IsObject(f)
        {
            throw OSError("AtomicWriter.WriteAll: FileOpen('" . tmpPath
                . "', 'w') failed (A_LastError=" . A_LastError . ")")
        }

        ; Use the file object's Write + Close. If .Write throws
        ; (rare; usually only disk-full mid-write), we still need
        ; to release the handle before propagating — AHK v2 has
        ; no `finally`, so the writeError pattern handles both
        ; paths uniformly.
        writeError := ""
        try
            f.Write(content)
        catch as ex
            writeError := ex
        f.Close()
        if (writeError != "")
            throw writeError

        ; Replace the destination. MoveFileEx with
        ; MOVEFILE_REPLACE_EXISTING does delete-then-rename, leaving
        ; the short window described at the top of this file. Fine
        ; for single-thread usage.
        FileMove(tmpPath, path, true)
    }
}

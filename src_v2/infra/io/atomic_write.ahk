; AtomicWriter — resilient file writing through the classic
; .tmp + rename pattern, to minimize corruption risk when the app
; crashes or the system shuts down mid-Save:
;
;   1. Write the entire content to <path>.tmp
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
; Orphans: a leftover .tmp from a prior crashed save is deleted
; before every write, so FileAppend never appends to stale content.
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
    ;              values FileAppend accepts.
    ;
    ; Throws OSError when FileAppend or FileMove fails (disk full,
    ; permission denied, invalid path).
    static WriteAll(path, content, encoding := "UTF-8")
    {
        if (Trim(String(path)) = "")
            throw ValueError("AtomicWriter.WriteAll: 'path' is required")

        ; Ensure directory (FileAppend does not create it on its own)
        SplitPath(path, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)

        tmpPath := path ".tmp"

        ; Defensive cleanup so FileAppend never appends to a
        ; leftover .tmp from an earlier crashed save.
        if FileExist(tmpPath)
        {
            try FileDelete(tmpPath)
        }

        ; Write the entire content to .tmp.
        FileAppend(content, tmpPath, encoding)

        ; Replace the destination. MoveFileEx with
        ; MOVEFILE_REPLACE_EXISTING does delete-then-rename, leaving
        ; the short window described at the top of this file. Fine
        ; for single-thread usage.
        FileMove(tmpPath, path, true)
    }
}

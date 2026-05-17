; ============================================================
; AtomicWriter — resilient file writing (refactor R10)
; ============================================================
;
; Classic Unix/Windows pattern to minimize corruption risk when
; the app crashes or the system shuts down in the middle of a Save:
;
;   1. Write content to <path>.tmp
;   2. FileMove <path>.tmp -> <path> (replaces path if it exists)
;
; NOTE ON ATOMICITY (v17.15 - Bug #27, doc fix):
;
;   This doc previously claimed that FileMove on NTFS is
;   "fully atomic". THAT IS NOT TRUE on Windows.
;
;   AHK's FileMove calls MoveFileEx with MOVEFILE_REPLACE_EXISTING.
;   When the destination exists, the Windows implementation
;   essentially does "delete dst + rename src". There is a short
;   window of inconsistency between those two operations.
;
;   For TRUE atomicity on Windows you need ReplaceFileW or
;   MoveFileTransacted (the latter is deprecated). Neither of
;   them is exposed by AHK's FileMove.
;
;   ACCEPTED RISK: the inconsistency window is very short (~1ms)
;   and our usage is single-threaded, without external concurrency.
;   For a desktop app with sporadic saves (run state, PBs,
;   settings), the risk is acceptable. Even if a crash happens
;   inside the window, the .tmp survives with the new content —
;   manual cleanup is possible.
;
; PROBLEM IT SOLVES (even without being fully atomic):
;
;   Before R10, several saves did:
;       try FileDelete(path)
;       FileAppend(json, path, "UTF-8")
;
;   If a crash happened BETWEEN FileDelete and FileAppend, the file
;   was permanently lost. AtomicWriter eliminates THAT class of bug —
;   the destination is only touched at the moment of FileMove.
;
; ORPHANS:
;
;   If an orphan .tmp exists from a previously crashed execution,
;   FileAppend creates fresh (no append to leftovers) because the
;   .tmp is deleted first. Defensive logic: guarantees cleanup
;   before every write.
;
; LIMITS:
;
;   - Windows/NTFS: "quasi-atomic" (short window). OK for single-thread
;     desktop usage.
;   - FAT32/exFAT: similar behavior but with more variance.
;     Accepted risk — FAT32 users are ~0% of the target audience.
;   - Network paths: latency + network failures widen the risk window.
;     A crash midway can leave an orphan .tmp on the source.
;
; USAGE:
;
;   AtomicWriter.WriteAll(path, "complete content")
;   AtomicWriter.WriteAll(path, jsonStr, "UTF-8")
;   AtomicWriter.WriteAll(path, csvBuffer, "UTF-8")


class AtomicWriter
{
    ; ------------------------------------------------------------
    ; WriteAll(path, content, encoding := "UTF-8")
    ;
    ; Writes content to path atomically via .tmp + FileMove.
    ; Overwrites path if it already exists. Creates directory if missing.
    ;
    ; Args:
    ;   path     : final path (e.g. "C:\...\step_summary.csv")
    ;   content  : string (UTF-8 default). May be empty (creates empty file).
    ;   encoding : "UTF-8" (default), "UTF-16", "CP1252", etc.
    ;              Same values accepted by AHK v2's FileAppend.
    ;
    ; Throws: OSError if FileAppend or FileMove fails (disk full,
    ;         permission denied, invalid path).
    ; ------------------------------------------------------------
    static WriteAll(path, content, encoding := "UTF-8")
    {
        if (Trim(String(path)) = "")
            throw ValueError("AtomicWriter.WriteAll: 'path' is required")

        ; Ensure directory (FileAppend does not create it on its own)
        SplitPath(path, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)

        tmpPath := path ".tmp"

        ; Defensive cleanup: if there is an orphan .tmp from a previously
        ; crashed execution, delete it first to avoid appending to leftovers.
        if FileExist(tmpPath)
        {
            try FileDelete(tmpPath)
        }

        ; Write the entire content to .tmp
        FileAppend(content, tmpPath, encoding)

        ; FileMove with overwrite=true replaces the destination if it exists.
        ; Windows implementation (MoveFileEx + MOVEFILE_REPLACE_EXISTING)
        ; does delete-then-rename, with a short window of inconsistency.
        ; OK for the app's single-thread usage. See LIMITS in the docstring.
        FileMove(tmpPath, path, true)
    }
}

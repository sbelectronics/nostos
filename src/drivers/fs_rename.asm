; ============================================================
; fs_rename.asm - Filesystem rename helper
; ============================================================

; Temporary variables for fs_rename
; Overlaps fs_remove vars (KERN_TEMP_SPACE + 119..123) — safe since
; rename and remove never execute concurrently.
fs_rename_src       EQU KERN_TEMP_SPACE + 119  ; src name pointer (2 bytes)
fs_rename_entry_idx EQU KERN_TEMP_SPACE + 121  ; entry index within parent block (1 byte)
fs_rename_dst       EQU KERN_TEMP_SPACE + 122  ; dst name pointer (2 bytes)

; ------------------------------------------------------------
; fs_rename (dft_fs slot 6 = FNIDX_RENAME)
; Rename a file or directory.  Supports multi-component paths
; on the src name (e.g. "/subdir/name").  The dst name is a
; bare name within the same parent directory.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to {src name ptr (2 bytes), dst name ptr (2 bytes)}
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - 0
; ------------------------------------------------------------
fs_rename:
    PUSH BC
    PUSH DE

    ; 1. Get underlying block device
    PUSH DE
    CALL fs_get_block_dev
    POP  DE
    OR   A
    JP   NZ, fs_rename_exit
    LD   A, L
    LD   (fs_temp_blk_id), A

    ; 2. Load src and dst name pointers from DE
    LD   A, (DE)
    LD   (fs_rename_src), A
    INC  DE
    LD   A, (DE)
    LD   (fs_rename_src + 1), A
    INC  DE
    LD   A, (DE)
    LD   (fs_rename_dst), A
    INC  DE
    LD   A, (DE)
    LD   (fs_rename_dst + 1), A

    ; 3. Resolve src path to (parent_inode, final_component)
    LD   DE, (fs_rename_src)
    CALL fs_path_traverse          ; A = status, DE = bare name, (fs_trav_parent_ino) = parent
    OR   A
    JP   NZ, fs_rename_exit
    LD   (fs_rename_src), DE       ; update src to bare final component

    ; 4. Verify dst does not already exist in the same parent directory
    LD   HL, (fs_rename_dst)
    EX   DE, HL                    ; DE = dst ptr
    LD   HL, (fs_trav_parent_ino)
    CALL fs_find_dir_entry
    CP   ERR_NOT_FOUND
    JP   Z, fs_rename_find_src     ; Good — dst doesn't exist
    OR   A
    JP   Z, fs_rename_err_exists   ; dst already exists
    JP   fs_rename_exit            ; IO error

fs_rename_find_src:
    ; 5. Find src in resolved parent directory
    LD   HL, (fs_rename_src)
    EX   DE, HL                    ; DE = src ptr
    LD   HL, (fs_trav_parent_ino)
    CALL fs_find_dir_entry
    OR   A
    JP   NZ, fs_rename_exit        ; ERR_NOT_FOUND or IO error

    ; Save entry index; fs_temp_dir_blk already holds the parent block
    LD   A, C
    LD   (fs_rename_entry_idx), A

    ; 5. Re-read the parent block
    LD   HL, (fs_temp_dir_blk)
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    JP   NZ, fs_rename_exit

    ; 6. Point HL to the name field of the matching entry
    ;    entry offset = entry_idx * 32; name is at offset +1 (past type byte)
    LD   HL, DISK_BUFFER
    LD   A, (fs_rename_entry_idx)
    OR   A
    JP   Z, fs_rename_at_entry
    LD   B, A
    LD   DE, 32
fs_rename_skip:
    ADD  HL, DE
    DEC  B
    JP   NZ, fs_rename_skip
fs_rename_at_entry:
    INC  HL                        ; skip type byte → HL = name field

    ; 7. Write dst name into the entry (16 bytes, null-padded)
    LD   DE, (fs_rename_dst)
    LD   B, 16
fs_rename_copy:
    LD   A, (DE)
    LD   (HL), A
    INC  HL
    INC  DE
    OR   A
    JP   Z, fs_rename_pad
    DEC  B
    JP   NZ, fs_rename_copy
    JP   fs_rename_write

fs_rename_pad:
    DEC  B
    JP   Z, fs_rename_write
    XOR  A
    LD   (HL), A
    INC  HL
    JP   fs_rename_pad

fs_rename_write:
    ; 8. Write modified block back to disk
    LD   HL, (fs_temp_dir_blk)
    LD   DE, DISK_BUFFER
    CALL fs_write_block
    JP   fs_rename_exit

fs_rename_err_exists:
    LD   A, ERR_EXISTS

fs_rename_exit:
    LD   HL, 0
    POP  DE
    POP  BC
    RET

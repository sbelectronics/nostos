; ============================================================
; fs_remove.asm - Filesystem block-free and remove helpers
; ============================================================

; Temporary variables for fs_remove (KERN_TEMP_SPACE + 119..124)
fs_remove_parent_blk EQU KERN_TEMP_SPACE + 119  ; parent dir block containing entry (2 bytes)
fs_remove_entry_idx  EQU KERN_TEMP_SPACE + 121  ; entry index (0-15) within parent block (1 byte)
fs_remove_target_ino EQU KERN_TEMP_SPACE + 122  ; target inode block number (2 bytes)
fs_remove_is_dir     EQU KERN_TEMP_SPACE + 124  ; non-zero if target is a directory (1 byte)

; ------------------------------------------------------------
; fs_free_block
; Mark a block as free in the bitmap (set its bit to 1).
; Inputs:
;   HL - block number to free
;   (fs_temp_blk_id) - physical block device ID
; Outputs:
;   A  - ERR_SUCCESS or error code
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fs_free_block:
    PUSH BC
    PUSH DE
    PUSH HL                     ; save block number

    ; Read bitmap data block (always at FS_BITMAP_START)
    LD   HL, FS_BITMAP_START
    LD   (fs_temp_alloc_blk), HL
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    JP   NZ, fs_free_block_exit

    POP  HL                     ; HL = block number to free
    PUSH HL

    ; D = bit index = block & 7
    LD   A, L
    AND  0x07
    LD   D, A

    ; Logical right shift HL by 3 to get byte index (0-511)
    OR   A                      ; clear carry (OR r clears C in Z80)
    LD   A, H
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A

    OR   A
    LD   A, H
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A

    OR   A
    LD   A, H
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A

    ; HL = byte index; compute pointer = DISK_BUFFER + HL
    LD   BC, DISK_BUFFER
    ADD  HL, BC                 ; HL = byte pointer in bitmap

    ; Build bit mask = 1 << D (D = bit index 0-7)
    LD   C, 1
fs_free_block_shift:
    LD   A, D
    OR   A
    JP   Z, fs_free_block_apply
    LD   A, C
    ADD  A                      ; C <<= 1  (ADD A = ADD A,A)
    LD   C, A
    DEC  D
    JP   fs_free_block_shift

fs_free_block_apply:
    ; OR the bit in to mark block as free (bit = 1 means free)
    LD   A, (HL)
    OR   C
    LD   (HL), A

    ; Write bitmap block back to disk
    LD   HL, (fs_temp_alloc_blk)
    LD   DE, DISK_BUFFER
    CALL fs_write_block

fs_free_block_exit:
    POP  HL
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; fs_dir_load_span
; Load FirstBlock and LastBlock for the current span from the
; span cache into fs_temp_dir_blk / fs_temp_dir_lastblk.
; Used by directory scanning in find, create, remove, and flush.
; Inputs:
;   (fs_temp_dir_span)  - current span index
;   (fs_temp_span_cache) - cached span table
; Outputs:
;   (fs_temp_dir_blk)     - FirstBlock of this span
;   (fs_temp_dir_lastblk) - LastBlock of this span
; Modifies: A, B, C, HL
; ------------------------------------------------------------
fs_dir_load_span:
    LD   A, (fs_temp_dir_span)
    LD   C, A
    LD   B, 0
    LD   HL, fs_temp_span_cache
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC                 ; HL = &cache[span_idx * 4]
    LD   A, (HL)
    LD   (fs_temp_dir_blk), A
    INC  HL
    LD   A, (HL)
    LD   (fs_temp_dir_blk + 1), A
    INC  HL
    LD   A, (HL)
    LD   (fs_temp_dir_lastblk), A
    INC  HL
    LD   A, (HL)
    LD   (fs_temp_dir_lastblk + 1), A
    RET

; ------------------------------------------------------------
; fs_remove (dft_fs slot 7)
; Remove a file or empty directory by path.
; Supports multi-component paths (e.g. "/subdir/name").
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated path
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - 0
; ------------------------------------------------------------
fs_remove:
    PUSH BC
    PUSH DE

    ; 1. Get block device
    PUSH DE
    CALL fs_get_block_dev
    POP  DE
    OR   A
    JP   NZ, fs_remove_exit
    LD   A, L
    LD   (fs_temp_blk_id), A

    ; 1b. Path traversal: resolve to (parent_inode, final_component).
    CALL fs_path_traverse       ; A = status, DE = final name, (fs_trav_parent_ino) = parent
    OR   A
    JP   NZ, fs_remove_exit

    ; 2. Find entry in resolved parent directory
    LD   HL, (fs_trav_parent_ino)
    CALL fs_find_dir_entry      ; DE = name; sets fs_temp_dir_blk, C = entry idx
    OR   A
    JP   NZ, fs_remove_exit

    ; 3. Save whether target is a directory (non-zero) or file (zero)
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_TYPE)
    AND  DIRENT_TYPE_DIR
    LD   (fs_remove_is_dir), A

    ; 4. Save: parent block, entry index within block, target inode
    LD   HL, (fs_temp_dir_blk)
    LD   (fs_remove_parent_blk), HL
    LD   A, C
    LD   (fs_remove_entry_idx), A
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_INODE)
    LD   (fs_remove_target_ino), A
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_INODE + 1)
    LD   (fs_remove_target_ino + 1), A

    ; 5. Read target dir inode
    LD   HL, (fs_remove_target_ino)
    CALL fs_read_inode
    OR   A
    JP   NZ, fs_remove_exit

    ; 6. Cache spans from inode
    CALL fs_cache_inode_spans
    ; 7. If target is a file, skip emptiness check
    LD   A, (fs_remove_is_dir)
    OR   A
    JP   Z, fs_remove_is_empty

    ; Pass 1: verify every data block has no used entries
    XOR  A
    LD   (fs_temp_dir_span), A

fs_remove_check_span:
    LD   A, (fs_temp_dir_spans)
    LD   B, A
    LD   A, (fs_temp_dir_span)
    CP   B
    JP   NC, fs_remove_is_empty ; All spans checked — directory is empty
    ; If span index >= 13, re-read inode to get uncached span
    CP   13
    JP   NC, fs_remove_check_reload
    CALL fs_dir_load_span
    JP   fs_remove_check_block

fs_remove_check_reload:
    PUSH AF                         ; save span index
    LD   HL, (fs_remove_target_ino)
    CALL fs_read_inode
    POP  BC                         ; B = span index
    OR   A
    JP   NZ, fs_remove_exit
    CALL fs_load_span_from_buffer

fs_remove_check_block:
    LD   HL, (fs_temp_dir_blk)
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    JP   NZ, fs_remove_exit

    ; Scan 16 entries (32 bytes each) for DIRENT_TYPE_USED
    LD   HL, DISK_BUFFER
    LD   B, 16
fs_remove_check_entry:
    LD   A, (HL)
    AND  DIRENT_TYPE_USED
    LD   A, ERR_DIR_NOT_EMPTY
    JP   NZ, fs_remove_exit     ; Found a live entry
    LD   DE, 32
    ADD  HL, DE
    DEC  B
    JP   NZ, fs_remove_check_entry

    ; Advance to next block in span
    CALL fs_dir_advance_block
    JP   C, fs_remove_check_next_span
    JP   fs_remove_check_block

fs_remove_check_next_span:
    LD   A, (fs_temp_dir_span)
    INC  A
    LD   (fs_temp_dir_span), A
    JP   fs_remove_check_span

fs_remove_is_empty:
    ; 8. Pass 2: free all data blocks
    XOR  A
    LD   (fs_temp_dir_span), A

fs_remove_free_span:
    LD   A, (fs_temp_dir_spans)
    LD   B, A
    LD   A, (fs_temp_dir_span)
    CP   B
    JP   NC, fs_remove_blocks_freed
    ; If span index >= 13, re-read inode and load span from DISK_BUFFER
    CP   13
    JP   NC, fs_remove_reload_span
    CALL fs_dir_load_span
    JP   fs_remove_free_block

fs_remove_reload_span:
    ; Re-read the inode from disk (fs_free_block clobbers DISK_BUFFER)
    PUSH AF                         ; save span index
    LD   HL, (fs_remove_target_ino)
    CALL fs_read_inode
    POP  BC                         ; B = span index
    OR   A
    JP   NZ, fs_remove_exit
    CALL fs_load_span_from_buffer

fs_remove_free_block:
    LD   HL, (fs_temp_dir_blk)
    CALL fs_free_block
    OR   A
    JP   NZ, fs_remove_exit

    CALL fs_dir_advance_block
    JP   C, fs_remove_free_next_span
    JP   fs_remove_free_block

fs_remove_free_next_span:
    LD   A, (fs_temp_dir_span)
    INC  A
    LD   (fs_temp_dir_span), A
    JP   fs_remove_free_span

fs_remove_blocks_freed:
    ; 9. Free the inode block itself
    LD   HL, (fs_remove_target_ino)
    CALL fs_free_block
    OR   A
    JP   NZ, fs_remove_exit

    ; 10. Read parent block, clear entry type byte, write back
    LD   HL, (fs_remove_parent_blk)
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    JP   NZ, fs_remove_exit

    ; entry_ptr = DISK_BUFFER + entry_idx * 32
    LD   HL, DISK_BUFFER
    LD   A, (fs_remove_entry_idx)
    OR   A
    JP   Z, fs_remove_clear_entry
    LD   B, A
    LD   DE, 32
fs_remove_entry_offset:
    ADD  HL, DE
    DEC  B
    JP   NZ, fs_remove_entry_offset

fs_remove_clear_entry:
    XOR  A
    LD   (HL), A                ; zero type byte = mark entry unused

    LD   HL, (fs_remove_parent_blk)
    LD   DE, DISK_BUFFER
    CALL fs_write_block         ; A = ERR_SUCCESS or error

fs_remove_exit:
    LD   HL, 0
    POP  DE
    POP  BC
    RET

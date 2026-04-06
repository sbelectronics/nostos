; ============================================================
; Filesystem Directory Helpers (8080 Compatible)
; ============================================================

fs_temp_dir_inode   EQU KERN_TEMP_SPACE + 64    ; Target directory inode (2 bytes)
fs_temp_dir_name    EQU KERN_TEMP_SPACE + 66    ; Target name pointer (2 bytes)
fs_temp_dir_blk     EQU KERN_TEMP_SPACE + 68    ; Current block number being scanned (2 bytes)
fs_temp_dir_lastblk EQU KERN_TEMP_SPACE + 70    ; End block of current span (2 bytes)
fs_temp_dir_span    EQU KERN_TEMP_SPACE + 72    ; Current span index (1 byte)
fs_temp_dir_spans   EQU KERN_TEMP_SPACE + 73    ; Total span count (1 byte)

fs_temp_span_cache  EQU FS_SPAN_CACHE           ; Cache of (First, Last) spans (52 bytes, 13 max)
fs_trav_parent_ino  EQU KERN_TEMP_SPACE + 103   ; Path traversal: resolved parent inode (2 bytes)

; ------------------------------------------------------------
; fs_find_dir_entry
; Searches a directory for a given name.
; Inputs:
;   HL - directory inode block number
;   DE - pointer to null-terminated name string
;   (fs_temp_blk_id) - physical device ID
; Outputs:
;   A  - ERR_SUCCESS if found, ERR_NOT_FOUND or error code
;   (fs_temp_dir_entry) - 32-byte directory entry on success
;   (fs_temp_dir_blk)   - block number where entry was found
;   C  - index (0-15) within the block on success
; ------------------------------------------------------------
fs_find_dir_entry:
    ; Save parameters
    LD   (fs_temp_dir_inode), HL
    EX   DE, HL
    LD   (fs_temp_dir_name), HL
    EX   DE, HL

    ; Read the directory inode into DISK_BUFFER
    LD   HL, (fs_temp_dir_inode)
    CALL fs_read_inode
    OR   A
    RET  NZ

    ; Cache spans from inode into temp space
    CALL fs_cache_inode_spans

    ; Start at Span 0
    XOR  A
    LD   (fs_temp_dir_span), A

fs_find_span_loop:
    ; Are we out of spans?
    LD   A, (fs_temp_dir_spans)
    LD   B, A
    LD   A, (fs_temp_dir_span)
    CP   B
    JP   NC, fs_find_not_found  ; Span index >= Span count

    ; If span index >= 13, re-read inode from disk (cache only holds 13)
    CP   13
    JP   NC, fs_find_reload_span

    ; Load Span (FirstBlock, LastBlock) from cache
    CALL fs_dir_load_span
    JP   fs_find_block_loop

fs_find_reload_span:
    ; Re-read the directory inode from disk
    PUSH AF                     ; save span index
    LD   HL, (fs_temp_dir_inode)
    CALL fs_read_inode
    POP  BC                     ; B = span index
    OR   A
    RET  NZ
    CALL fs_load_span_from_buffer

fs_find_block_loop:
    ; Read the directory block
    LD   HL, (fs_temp_dir_blk)
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    RET  NZ                     ; Return on read error

    ; Scan the 16 entries in the block (Block is 512 bytes, entry is 32)
    LD   HL, DISK_BUFFER
    LD   C, 0                   ; C = entry index (0-15)

fs_find_entry_loop:
    ; Check Type (offset 0 in entry)
    LD   A, (HL)
    AND  DIRENT_TYPE_USED
    JP   Z, fs_find_next_entry  ; Unused entry

    ; Used entry! Check name (offset 1 in entry).
    PUSH HL                     ; Save entry pointer
    INC  HL                     ; HL = entry Name

    ; DE = target name
    LD   A, (fs_temp_dir_name)
    LD   E, A
    LD   A, (fs_temp_dir_name + 1)
    LD   D, A                   ; DE = target name pointer

    PUSH BC                     ; Save C (entry index)
    CALL strcasecmp_hl_de       ; Z set if names match (case-insensitive)
    POP  BC
    POP  HL                     ; Restore entry pointer

    JP   Z, fs_find_success

fs_find_next_entry:
    ; Advance HL by 32 bytes to next entry
    LD   DE, 32
    ADD  HL, DE
    INC  C
    LD   A, C
    CP   16
    JP   C, fs_find_entry_loop  ; Loop if C < 16

    ; Out of entries in block. Advance to next block.
    CALL fs_dir_advance_block
    JP   C, fs_find_advance_span
    JP   fs_find_block_loop

fs_find_advance_span:
    ; Block > LastBlock. Advance span.
    LD   A, (fs_temp_dir_span)
    INC  A
    LD   (fs_temp_dir_span), A
    JP   fs_find_span_loop

fs_find_success:
    ; Match found! Copy the 32-byte entry to fs_temp_dir_entry so the
    ; caller doesn't have to worry about parsing it out of DISK_BUFFER.
    LD   DE, fs_temp_dir_entry
    LD   B, 32
fs_find_copy_entry:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, fs_find_copy_entry

    ; C still contains the index within the block.
    ; Return SUCCESS.
    XOR  A
    RET

fs_find_not_found:
    LD   A, ERR_NOT_FOUND
    RET

; ------------------------------------------------------------
; fs_dir_advance_block
; Increments fs_temp_dir_blk and compares with fs_temp_dir_lastblk.
; Inputs:
;   (fs_temp_dir_blk)     - current block
;   (fs_temp_dir_lastblk) - last block of span
; Outputs:
;   Carry set if past last block (need to advance span)
;   Carry clear if still in span (continue block loop)
; Modifies: A, DE, HL
; ------------------------------------------------------------
fs_dir_advance_block:
    LD   HL, (fs_temp_dir_blk)
    INC  HL
    LD   (fs_temp_dir_blk), HL
    LD   DE, (fs_temp_dir_lastblk)
    LD   A, D
    CP   H
    RET  C                          ; H > D → past end
    JP   NZ, fs_dir_adv_nc          ; H < D → still in span
    LD   A, E
    CP   L
    RET                             ; C set if L > E (past end)
fs_dir_adv_nc:
    OR   A                          ; clear carry
    RET

; ------------------------------------------------------------
; fs_cache_inode_spans
; Cache up to 13 spans from the inode currently in DISK_BUFFER
; into fs_temp_span_cache, and store the total span count.
; Inputs:
;   (DISK_BUFFER) - contains the inode data
; Outputs:
;   (fs_temp_dir_spans)  - total span count (not capped)
;   (fs_temp_span_cache) - cached span data (up to 13 spans)
; Modifies: A, BC, DE, HL
; ------------------------------------------------------------
fs_cache_inode_spans:
    LD   A, (DISK_BUFFER + INODE_OFF_COUNT)
    LD   (fs_temp_dir_spans), A
    CP   13
    JP   C, fs_cache_spans_ok
    LD   A, 13
fs_cache_spans_ok:
    ADD  A, A                   ; A = spans * 2
    ADD  A, A                   ; A = spans * 4 = byte count
    LD   C, A
    LD   B, 0
    LD   HL, DISK_BUFFER + INODE_OFF_SPANS
    LD   DE, fs_temp_span_cache
    JP   memcpy                 ; tail call

; ------------------------------------------------------------
; fs_load_span_from_buffer
; Load span FirstBlock/LastBlock from an inode already in DISK_BUFFER.
; Inputs:
;   B - span index (0-based)
; Outputs:
;   (fs_temp_dir_blk)     - FirstBlock of this span
;   (fs_temp_dir_lastblk) - LastBlock of this span
; Modifies: A, B, C, HL
; ------------------------------------------------------------
fs_load_span_from_buffer:
    LD   C, B
    LD   B, 0
    LD   HL, DISK_BUFFER + INODE_OFF_SPANS
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC                 ; HL = &inode_spans[index * 4]
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
; fs_path_traverse
; Walk a multi-component path, resolving intermediate directory
; components. Returns a pointer to the final (leaf) component
; and the inode of its parent directory.
; Inputs:
;   DE - null-terminated path (may start with '/')
;   (fs_temp_blk_id) - physical block device ID
; Outputs:
;   A  - ERR_SUCCESS or error code
;   DE - pointer to final component name (bare name)
;   (fs_trav_parent_ino) - inode of the parent directory
; ------------------------------------------------------------
fs_path_traverse:
    ; Initialize parent = FS_ROOT_INODE
    LD   A, FS_ROOT_INODE & 0xFF
    LD   (fs_trav_parent_ino), A
    XOR  A
    LD   (fs_trav_parent_ino + 1), A

    ; Strip leading '/'
    LD   A, (DE)
    CP   '/'
    JP   NZ, fs_trav_next
    INC  DE

fs_trav_next:
    ; Scan for '/' or end-of-string
    PUSH DE                     ; save component start
    LD   H, D
    LD   L, E
fs_trav_scan:
    LD   A, (HL)
    OR   A
    JP   Z, fs_trav_final       ; no slash -> final component
    CP   '/'
    JP   Z, fs_trav_mid
    INC  HL
    JP   fs_trav_scan

fs_trav_mid:
    ; HL = '/' position; [SP] = component start
    POP  DE                     ; DE = component start
    PUSH HL                     ; save '/' position
    LD   HL, fs_temp_name
    LD   B, 16
fs_trav_copy:
    LD   A, (DE)
    CP   '/'
    JP   Z, fs_trav_copy_done
    OR   A
    JP   Z, fs_trav_copy_done
    LD   (HL), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, fs_trav_copy
    ; Copied 16 chars; check if the 17th char is a terminator
    LD   A, (DE)
    CP   '/'
    JP   Z, fs_trav_copy_done   ; exactly 16 chars — valid
    OR   A
    JP   Z, fs_trav_copy_done   ; exactly 16 chars — valid
    ; 17th char is a real char — component name too long
    POP  HL                     ; balance stack (saved '/' position from line 279)
    LD   A, ERR_INVALID_PARAM
    RET
fs_trav_copy_done:
    LD   (HL), 0                ; null-terminate component
    ; Reject empty component (e.g. "//" or leading "/")
    LD   A, (fs_temp_name)
    OR   A
    JP   Z, fs_trav_empty_comp
    POP  HL                     ; HL = '/' position
    INC  HL                     ; char after '/'
    LD   D, H
    LD   E, L                   ; DE = remaining path
    PUSH DE                     ; save across fs_find_dir_entry
    LD   DE, fs_temp_name       ; DE = component name
    LD   HL, (fs_trav_parent_ino)
    CALL fs_find_dir_entry
    POP  DE                     ; restore remaining path
    OR   A
    RET  NZ                     ; error (NOT_FOUND or IO)
    ; Must be a directory to traverse into
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_TYPE)
    AND  DIRENT_TYPE_DIR
    JP   Z, fs_trav_not_dir
    ; Descend: update parent inode
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_INODE)
    LD   (fs_trav_parent_ino), A
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_INODE + 1)
    LD   (fs_trav_parent_ino + 1), A
    JP   fs_trav_next

fs_trav_final:
    ; [SP] = final component pointer; parent inode is set
    POP  DE                     ; DE = final component name
    XOR  A                      ; A = ERR_SUCCESS
    RET

fs_trav_empty_comp:
    ; Empty intermediate component (e.g. "//" in path) — stack has [slash_pos]
    POP  HL                     ; balance stack (saved '/' position from line 279)
    LD   A, ERR_INVALID_PARAM
    RET

fs_trav_not_dir:
    LD   A, ERR_INVALID_PARAM
    RET

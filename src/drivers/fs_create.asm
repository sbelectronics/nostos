; ============================================================
; Filesystem Creation Helpers (8080 Compatible)
; ============================================================

fs_temp_create_name EQU KERN_TEMP_SPACE + 110   ; Pointer to name (2 bytes)
fs_temp_create_pdt  EQU KERN_TEMP_SPACE + 112   ; Pointer to assigned PDT slot (2 bytes)
fs_temp_create_id   EQU KERN_TEMP_SPACE + 114   ; Assigned logical ID (1 byte)
fs_temp_create_blk  EQU KERN_TEMP_SPACE + 115   ; Allocated data block (2 bytes)
fs_temp_create_ino  EQU KERN_TEMP_SPACE + 117   ; Allocated inode block (2 bytes)
fs_temp_create_parent_ino EQU KERN_TEMP_SPACE + 119 ; Parent directory inode (2 bytes)

; ------------------------------------------------------------
; fs_dcreate (slot 4 of dft_fs)
; Creates a directory.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated pathname (e.g. "DIR" or "A/B/DIR")
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - physical device ID of new handle on success, 0 on error
; ------------------------------------------------------------
fs_dcreate:
    PUSH BC                     ; preserve BC (B = device ID)
    PUSH DE                     ; preserve DE (params pointer)
    LD   A, HND_FLAG_DIR
    LD   (fs_temp_open_flags), A
    LD   HL, dft_dir
    LD   (fs_temp_open_dft), HL
    JP   fs_create_common

; ------------------------------------------------------------
; fs_fcreate (slot 2 of dft_fs)
; Creates a file.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated pathname (e.g. "FILE" or "DIR/FILE")
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - physical device ID of new handle on success, 0 on error
; ------------------------------------------------------------
fs_fcreate:
    PUSH BC                     ; preserve BC (B = device ID)
    PUSH DE                     ; preserve DE (params pointer)
    LD   A, HND_FLAG_WRITE      ; File opened for writing (enables size flush on close)
    LD   (fs_temp_open_flags), A
    LD   HL, dft_file
    LD   (fs_temp_open_dft), HL

fs_create_common:
    ; 1. Save name pointer and get block dev
    LD   (fs_temp_create_name), DE

    CALL fs_get_block_dev
    OR   A
    JP   NZ, fs_create_exit
    LD   A, L
    LD   (fs_temp_blk_id), A

    ; 1b. Path traversal: resolve to (parent_inode, final_component_name).
    LD   DE, (fs_temp_create_name)

    ; If path starts with '/', it's absolute — traverse directly
    LD   A, (DE)
    CP   '/'
    JP   Z, fs_create_do_traverse ; absolute path, traverse directly

    ; Relative path — only prepend CUR_DIR if target is CUR_DEVICE
    LD   A, (CUR_DEVICE)
    CP   B
    JP   NZ, fs_create_do_traverse ; different device — root-relative

    ; Same device: prepend CUR_DIR
    ; Build CUR_DIR/filename in PATH_WORK_PATH
    PUSH BC
    PUSH DE
    LD   HL, CUR_DIR
    LD   DE, PATH_WORK_PATH
    CALL strcpy                 ; copy CUR_DIR; DE = one past null
    DEC  DE                     ; DE = null terminator
    DEC  DE                     ; DE = last char of CUR_DIR
    LD   A, (DE)
    CP   '/'
    INC  DE                     ; DE = null terminator position
    JP   Z, fs_create_cwd_no_sep ; last char already '/', write at null
    LD   A, '/'
    LD   (DE), A
    INC  DE
fs_create_cwd_no_sep:
    POP  HL                     ; HL = bare filename
    POP  BC
fs_create_cwd_append:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    OR   A
    JP   NZ, fs_create_cwd_append
    LD   DE, PATH_WORK_PATH

fs_create_do_traverse:
    ; DE = path to traverse (absolute or CWD-prepended)
    CALL fs_path_traverse       ; A = status, DE = final name, (fs_trav_parent_ino) = parent
    OR   A
    JP   NZ, fs_create_exit
    LD   (fs_temp_create_name), DE
    ; Reject names longer than 16 characters
    PUSH DE
    LD   B, 17                  ; 16 chars + null must be found within 17
fs_create_chklen:
    LD   A, (DE)
    OR   A
    JP   Z, fs_create_len_ok
    INC  DE
    DEC  B
    JP   NZ, fs_create_chklen
    POP  DE
    LD   A, ERR_INVALID_PARAM   ; name too long
    JP   fs_create_exit
fs_create_len_ok:
    POP  DE
    ; Copy resolved parent inode to create and open vars
    LD   A, (fs_trav_parent_ino)
    LD   (fs_temp_create_parent_ino), A
    LD   (fs_temp_open_parent_ino), A
    LD   A, (fs_trav_parent_ino + 1)
    LD   (fs_temp_create_parent_ino + 1), A
    LD   (fs_temp_open_parent_ino + 1), A

    ; 2. Check if name already exists in parent directory
    LD   HL, (fs_temp_create_parent_ino)
    LD   DE, (fs_temp_create_name)
    CALL fs_find_dir_entry
    OR   A
    JP   Z, fs_create_err_exists ; Found it, error
    CP   ERR_NOT_FOUND
    JP   NZ, fs_create_exit     ; Other IO error

    ; 3. Allocate inode before data block so the data block gets
    ;    a higher block number.  Caller's sequential BWRITEs then
    ;    proceed forward on disk without seeking back past the inode.
    CALL fs_alloc_block
    OR   A
    JP   NZ, fs_create_exit
    LD   (fs_temp_create_ino), HL

    ; 4. Allocate a block for the data
    CALL fs_alloc_block
    OR   A
    JP   NZ, fs_create_rollback_ino
    LD   (fs_temp_create_blk), HL

    ; 5. Initialize data block for directories (must be zeroed so
    ;    unused entries read as type=0). Files skip this — size=0
    ;    means EOF before any read, so the block is never exposed.
    LD   HL, DISK_BUFFER
    LD   BC, FS_BLOCK_SIZE
    CALL memzero
    LD   A, (fs_temp_open_flags)
    AND  HND_FLAG_DIR
    JP   Z, fs_create_build_inode
    LD   HL, (fs_temp_create_blk)
    LD   DE, DISK_BUFFER
    CALL fs_write_block
    OR   A
    JP   NZ, fs_create_rollback_both
    ; Re-zero DISK_BUFFER (fs_write_block preserves it, but be safe)
    LD   HL, DISK_BUFFER
    LD   BC, FS_BLOCK_SIZE
    CALL memzero

    ; 6. Create the inode in DISK_BUFFER (zeroed above or by step 5)
fs_create_build_inode:
    ; SpanCount = 1
    LD   A, 1
    LD   (DISK_BUFFER + INODE_OFF_COUNT), A

    ; Span 0 FirstBlock = fs_temp_create_blk
    LD   HL, DISK_BUFFER + INODE_OFF_SPANS
    LD   DE, (fs_temp_create_blk)
    LD   (HL), E
    INC  HL
    LD   (HL), D
    INC  HL

    ; Span 0 LastBlock = fs_temp_create_blk
    LD   (HL), E
    INC  HL
    LD   (HL), D

    ; Write inode
    LD   HL, (fs_temp_create_ino)
    LD   DE, DISK_BUFFER
    CALL fs_write_block
    OR   A
    JP   NZ, fs_create_rollback_both

    ; 7. Add directory entry to root directory
    CALL fs_add_to_root
    OR   A
    JP   NZ, fs_create_rollback_both

    ; 8. Follow-up: We created the file. Now open it.
    ; Type
    LD   A, (fs_temp_open_flags)
    AND  HND_FLAG_DIR
    JP   NZ, fs_create_set_dir
    LD   A, DIRENT_TYPE_USED
    JP   fs_create_set_type
fs_create_set_dir:
    LD   A, DIRENT_TYPE_USED | DIRENT_TYPE_DIR
fs_create_set_type:
    LD   (fs_temp_dir_entry + DIRENT_OFF_TYPE), A

    ; Name is already in fs_temp_dir_entry via fs_add_to_root

    ; Inode
    LD   HL, fs_temp_dir_entry + DIRENT_OFF_INODE
    LD   DE, (fs_temp_create_ino)
    LD   (HL), E
    INC  HL
    LD   (HL), D

    ; Size (0)
    XOR  A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE + 1), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE + 2), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE + 3), A

    JP   fs_open_prep_slot      ; Continues to allocate PDT slot and return ID in HL
                                ; fs_open_exit will POP DE / POP BC matching our pushes

fs_create_not_a_dir:
    LD   A, ERR_INVALID_PARAM
    LD   HL, 0
    JP   fs_create_exit

fs_create_err_exists:
    LD   A, ERR_EXISTS
    LD   HL, 0
    JP   fs_create_exit

fs_create_rollback_both:
    PUSH AF                     ; save error code
    LD   HL, (fs_temp_create_blk)
    CALL fs_free_block
    POP  AF
fs_create_rollback_ino:
    PUSH AF                     ; save error code
    LD   HL, (fs_temp_create_ino)
    CALL fs_free_block
    POP  AF
    LD   HL, 0

fs_create_exit:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; fs_add_to_root
; Scans the Root Inode for a free 32-byte slot and writes the
; new directory entry.
; Inputs:
;   (fs_temp_create_ino)   - new inode block number
;   (fs_temp_create_name)  - pointer to new file/dir name
;   (fs_temp_open_flags)   - flags indicating file or directory
;   (fs_temp_blk_id)       - physical block device ID
; Outputs:
;   A  - ERR_SUCCESS or error code
;   (fs_temp_dir_entry)    - populated with the new directory entry
; ------------------------------------------------------------
fs_add_to_root:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE
    PUSH HL                     ; preserve HL

    ; Use fs_dir approach! Cache the spans of parent inode.
    LD   HL, (fs_temp_create_parent_ino)
    LD   (fs_temp_dir_inode), HL
    CALL fs_read_inode
    OR   A
    JP   NZ, fs_add_to_root_exit

    ; Cache spans from parent inode
    CALL fs_cache_inode_spans

    XOR  A
    LD   (fs_temp_dir_span), A

fs_add_span_loop:
    LD   A, (fs_temp_dir_spans)
    LD   B, A
    LD   A, (fs_temp_dir_span)
    CP   B
    JP   NC, fs_add_not_found   ; directory full (expansion not supported)

    ; If span index >= 13, re-read inode from disk
    CP   13
    JP   NC, fs_add_reload_span

    ; Load span from cache
    CALL fs_dir_load_span
    JP   fs_add_block_loop

fs_add_reload_span:
    ; Re-read the parent directory inode from disk
    PUSH AF                     ; save span index
    LD   HL, (fs_temp_create_parent_ino)
    CALL fs_read_inode
    POP  BC                     ; B = span index
    OR   A
    JP   NZ, fs_add_to_root_exit
    CALL fs_load_span_from_buffer

fs_add_block_loop:
    LD   HL, (fs_temp_dir_blk)
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    JP   NZ, fs_add_to_root_exit

    LD   HL, DISK_BUFFER
    LD   C, 0                   ; C = entry index

fs_add_entry_loop:
    ; Type byte
    LD   A, (HL)
    AND  DIRENT_TYPE_USED
    JP   Z, fs_add_slot_found   ; Unused! Found a spot!

    ; Used, skip 32 bytes
    LD   DE, 32
    ADD  HL, DE
    INC  C
    LD   A, C
    CP   16
    JP   C, fs_add_entry_loop

    ; Next block
    CALL fs_dir_advance_block
    JP   C, fs_add_advance_span
    JP   fs_add_block_loop

fs_add_advance_span:
    LD   A, (fs_temp_dir_span)
    INC  A
    LD   (fs_temp_dir_span), A
    JP   fs_add_span_loop

fs_add_slot_found:
    ; Fill the slot at (HL)
    PUSH HL                     ; Save start of entry

    ; 1. Type
    LD   A, (fs_temp_open_flags)
    AND  HND_FLAG_DIR
    JP   NZ, fs_add_set_dir
    LD   A, DIRENT_TYPE_USED
    JP   fs_add_set_type
fs_add_set_dir:
    LD   A, DIRENT_TYPE_USED | DIRENT_TYPE_DIR
fs_add_set_type:
    LD   (HL), A                ; Write type to DISK_BUFFER
    LD   (fs_temp_dir_entry + DIRENT_OFF_TYPE), A ; and temp copy

    ; 2. Name
    INC  HL                     ; HL points to DIRENT_OFF_NAME
    LD   DE, (fs_temp_create_name)
    LD   B, 16

    ; We need to write to HL, and also fs_temp_dir_entry + DIRENT_OFF_NAME.
    ; We can just write to HL (DISK_BUFFER), then copy from DISK_BUFFER to fs_temp_dir_entry at the end!
fs_add_name_loop:
    LD   A, (DE)
    LD   (HL), A
    INC  HL
    INC  DE
    OR   A
    JP   Z, fs_add_name_pad
    DEC  B
    JP   NZ, fs_add_name_loop
    JP   fs_add_name_done
fs_add_name_pad:
    ; Pad rest of 16-char name with zero
    DEC  B
    LD   A, B
    OR   A
    JP   Z, fs_add_name_done
    XOR  A
    LD   (HL), A
    INC  HL
    JP   fs_add_name_pad

fs_add_name_done:
    ; Name done. Jump to Inode field.
    POP  DE                     ; DE = start of entry (was PUSH HL earlier)

    ; Copy the name we just built in the block buffer to the temp dir entry buffer
    PUSH DE                     ; Save start of entry
    LD   HL, fs_temp_dir_entry + DIRENT_OFF_NAME
    LD   B, 16
    INC  DE                     ; Point DE to name inside entry block
fs_add_copy_name_temp:
    LD   A, (DE)
    LD   (HL), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, fs_add_copy_name_temp
    POP  HL                     ; Restore start of entry
    PUSH HL
    LD   BC, DIRENT_OFF_INODE
    ADD  HL, BC

    ; 3. Inode
    LD   A, (fs_temp_create_ino)
    LD   (HL), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_INODE), A
    INC  HL
    LD   A, (fs_temp_create_ino + 1)
    LD   (HL), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_INODE + 1), A

    ; 4. Size (Files initialize size to 0. Directories are 0 anyway)
    POP  HL                     ; Restore start
    PUSH HL
    LD   BC, DIRENT_OFF_SIZE
    ADD  HL, BC
    XOR  A
    LD   (HL), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE), A
    INC  HL
    LD   (HL), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE + 1), A
    INC  HL
    LD   (HL), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE + 2), A
    INC  HL
    LD   (HL), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE + 3), A

    POP  HL                     ; Clean up

    ; Write the modified block back to disk
    LD   HL, (fs_temp_dir_blk)
    LD   DE, DISK_BUFFER
    CALL fs_write_block

    ; A = result from fs_write_block (ERR_SUCCESS on success)
    JP   fs_add_to_root_exit

fs_add_not_found:
    ; All existing spans exhausted — allocate a new block and extend the dir inode.

    ; 1. Allocate a new directory block
    CALL fs_alloc_block
    OR   A
    JP   NZ, fs_add_expand_fail
    LD   (fs_temp_dir_blk), HL  ; save new block (also read by fs_add_slot_found)

    ; 2. Re-read parent inode (DISK_BUFFER was clobbered during the span scan)
    LD   HL, (fs_temp_create_parent_ino)
    CALL fs_read_inode
    OR   A
    JP   NZ, fs_add_expand_fail

    ; 3. Try to grow the last span if new block is contiguous; else add a new span.
    ;    Point HL to last span's LastBlock_low field.
    LD   A, (DISK_BUFFER + INODE_OFF_COUNT)
    LD   B, A                   ; B = current SpanCount
    DEC  A                      ; A = SpanCount - 1
    LD   L, A
    LD   H, 0
    ADD  HL, HL                 ; * 2
    ADD  HL, HL                 ; * 4  (HL = (SpanCount-1) * 4)
    LD   DE, DISK_BUFFER + INODE_OFF_SPANS + 2  ; +2 = offset of LastBlock in span
    ADD  HL, DE                 ; HL = &last_span.LastBlock_low
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = LastBlock of last span
    DEC  HL                     ; HL back to LastBlock_low
    PUSH HL                     ; save ptr for potential contiguous merge
    INC  DE                     ; DE = LastBlock + 1
    LD   HL, (fs_temp_dir_blk)  ; HL = new block
    LD   A, L
    CP   E
    JP   NZ, fs_add_new_span
    LD   A, H
    CP   D
    JP   NZ, fs_add_new_span
    ; Contiguous: extend last span's LastBlock to the new block
    POP  HL                     ; HL = &last_span.LastBlock_low
    LD   DE, (fs_temp_dir_blk)
    LD   (HL), E
    INC  HL
    LD   (HL), D
    JP   fs_add_write_inode

fs_add_new_span:
    POP  HL                     ; discard saved ptr (balance stack)
    LD   A, B                   ; A = SpanCount
    CP   126                    ; max spans per inode
    JP   NC, fs_add_expand_fail
    ; Append new span at index SpanCount
    LD   L, A
    LD   H, 0
    ADD  HL, HL                 ; * 2
    ADD  HL, HL                 ; * 4  (HL = SpanCount * 4)
    LD   DE, DISK_BUFFER + INODE_OFF_SPANS
    ADD  HL, DE                 ; HL = &new_span
    LD   DE, (fs_temp_dir_blk)
    LD   (HL), E                ; FirstBlock low
    INC  HL
    LD   (HL), D                ; FirstBlock high
    INC  HL
    LD   (HL), E                ; LastBlock low
    INC  HL
    LD   (HL), D                ; LastBlock high
    LD   A, B
    INC  A
    LD   (DISK_BUFFER + INODE_OFF_COUNT), A ; SpanCount++

fs_add_write_inode:
    ; 4. Write updated parent inode back to disk
    LD   HL, (fs_temp_create_parent_ino)
    LD   DE, DISK_BUFFER
    CALL fs_write_block
    OR   A
    JP   NZ, fs_add_expand_fail

    ; 5. Zero DISK_BUFFER for the new directory block; entry 0 is free
    LD   HL, DISK_BUFFER
    LD   BC, FS_BLOCK_SIZE
    CALL memzero
    ; fs_temp_dir_blk = new block (step 1); fs_add_slot_found writes it back
    LD   HL, DISK_BUFFER        ; HL = first (free) entry in new block
    JP   fs_add_slot_found

fs_add_expand_fail:
    LD   A, ERR_NO_SPACE

fs_add_to_root_exit:
    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

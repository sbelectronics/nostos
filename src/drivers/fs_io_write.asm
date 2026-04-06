; ------------------------------------------------------------
; fs_file_bwrite (slot 3 of dft_file)
; Writes a 512-byte block to an open file.
; Inputs:
;   B  - file device ID
;   DE - pointer to 512-byte source buffer
; Outputs:
;   A  - ERR_SUCCESS or ERR_EOF / ERR_IO / ERR_NO_SPACE
; ------------------------------------------------------------
fs_file_bwrite:
    PUSH BC                     ; preserve BC (B = device ID)
    PUSH DE                     ; preserve DE (source buffer pointer)
    LD   (fs_temp_io_buf), DE   ; save source buffer

    ; 1. Get user data & block dev
    CALL fs_get_slot_data
    OR   A
    JP   NZ, fs_file_bwrite_exit
    CALL fs_setup_block_dev
    OR   A
    JP   NZ, fs_file_bwrite_exit
    CALL fs_get_file_state

    ; 2. Block position IS the LBA
    LD   HL, (fs_temp_io_pos)
    LD   (fs_temp_io_lba), HL

    ; 3. Get Physical Block (uses span cache)
    CALL fs_resolve_pba
    OR   A
    JP   Z, fs_file_bwrite_do
    CP   ERR_EOF
    JP   NZ, fs_file_bwrite_exit    ; IO error — do not append
    JP   fs_file_bwrite_append

    ; 4. Write the block
fs_file_bwrite_do:
    LD   HL, (fs_temp_io_pba)
    LD   DE, (fs_temp_io_buf)
    CALL fs_write_block
    OR   A
    JP   NZ, fs_file_bwrite_exit

    ; 5. Advance block position by 1 and save to slot
    CALL fs_advance_block_pos

    ; 6. Update File Size if new byte position exceeds it.
    ;    new_byte_pos = block_pos * 512 (block_pos is already incremented)
    ;    new_byte_pos[0] = 0, [1] = block_pos_lo << 1, [2] = block_pos >> 7
    LD   HL, (fs_temp_io_pos)   ; HL = new block position (after increment)
    ; Compute byte position: shift left 9 = low byte is 0, then shift HL left 1
    ; byte[0] = 0, byte[1] = L << 1, byte[2] = (H << 1) | (L >> 7)
    LD   A, L
    ADD  A, A                   ; A = L << 1
    LD   E, A                   ; E = byte[1]
    LD   A, H
    RLA                         ; A = (H << 1) | carry from L << 1
    LD   D, A                   ; D = byte[2]
    ; New byte pos = 0:E:D (3 bytes LE: [0]=0, [1]=E, [2]=D)

    ; Compare with 3-byte filesize in handle
    LD   HL, (fs_temp_io_slot)
    LD   BC, PHYSDEV_OFF_DATA + HND_OFF_FILESIZE
    ADD  HL, BC                 ; HL = &filesize[0]

    ; Compare byte[2] vs filesize[2]
    PUSH HL
    INC  HL
    INC  HL                     ; HL = &filesize[2]
    LD   A, D                   ; new byte[2]
    CP   (HL)
    JP   C, fs_file_bwrite_done ; new[2] < size[2], no update
    JP   NZ, fs_file_bwrite_update ; new[2] > size[2], update
    DEC  HL                     ; &filesize[1]
    LD   A, E                   ; new byte[1]
    CP   (HL)
    JP   C, fs_file_bwrite_done ; new[1] < size[1], no update
    JP   NZ, fs_file_bwrite_update ; new[1] > size[1], update
    ; new byte[0] is always 0, filesize[0] could be > 0
    ; If filesize[0] > 0, new < old, no update
    DEC  HL                     ; &filesize[0]
    LD   A, (HL)
    OR   A
    JP   NZ, fs_file_bwrite_done ; filesize[0] > 0, new <= old
    ; Equal — no update needed
    JP   fs_file_bwrite_done

fs_file_bwrite_update:
    POP  HL                     ; HL = &filesize[0]
    XOR  A
    LD   (HL), A                ; filesize[0] = 0
    INC  HL
    LD   (HL), E                ; filesize[1] = byte[1]
    INC  HL
    LD   (HL), D                ; filesize[2] = byte[2]
    XOR  A
    JP   fs_file_bwrite_exit

fs_file_bwrite_done:
    POP  HL                     ; balance stack (pushed &filesize[0])
    XOR  A
    JP   fs_file_bwrite_exit

fs_file_bwrite_append:
    ; The LBA wasn't found (ERR_EOF).
    ; Allocate a new data block and append it to the inode's span table.

    ; 1. Allocate new block
    CALL fs_alloc_block
    OR   A
    JP   NZ, fs_file_bwrite_exit
    LD   (fs_temp_io_pba), HL      ; save new block as the PBA for bwrite_do

    ; 2. Read file's inode into DISK_BUFFER
    LD   HL, (fs_temp_io_inode)
    CALL fs_read_inode
    OR   A
    JP   NZ, fs_file_bwrite_exit

    ; 3. Get span count
    LD   A, (DISK_BUFFER + INODE_OFF_COUNT)
    OR   A
    JP   Z, fs_bwa_first_span      ; no spans yet

    ; 4. Navigate to last span (index = count-1, each span is 4 bytes)
    DEC  A                         ; A = last span index
    LD   C, A
    LD   B, 0
    LD   HL, DISK_BUFFER + INODE_OFF_SPANS
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC                    ; HL = &spans[last_index]
    ; HL = &last_span.FirstBlock; HL+2 = &last_span.LastBlock
    INC  HL
    INC  HL                        ; HL = &last_span.LastBlock (low byte)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                   ; DE = LastBlock of last span

    ; 5. Check adjacency: (new_block - 1) == LastBlock?
    LD   HL, (fs_temp_io_pba)
    DEC  HL                        ; HL = new_block - 1
    LD   A, H
    CP   D
    JP   NZ, fs_bwa_new_span
    LD   A, L
    CP   E
    JP   NZ, fs_bwa_new_span

    ; Adjacent! Extend last span: update LastBlock in DISK_BUFFER
    LD   A, (DISK_BUFFER + INODE_OFF_COUNT)
    DEC  A                         ; A = last span index
    LD   C, A
    LD   B, 0
    LD   HL, DISK_BUFFER + INODE_OFF_SPANS + 2  ; +2 to skip FirstBlock field
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC                    ; HL = &last_span.LastBlock
    LD   DE, (fs_temp_io_pba)
    LD   (HL), E
    INC  HL
    LD   (HL), D
    JP   fs_bwa_write_inode

fs_bwa_new_span:
    ; Not adjacent — add a new span (if inode has room: max 126 spans)
    LD   A, (DISK_BUFFER + INODE_OFF_COUNT)
    CP   126
    JP   NC, fs_bwa_no_space
    INC  A
    LD   (DISK_BUFFER + INODE_OFF_COUNT), A
    DEC  A                         ; A = old count = index of new span
    LD   C, A
    LD   B, 0
    LD   HL, DISK_BUFFER + INODE_OFF_SPANS
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC
    ADD  HL, BC                    ; HL = &spans[new_index]
    LD   DE, (fs_temp_io_pba)
    LD   (HL), E
    INC  HL
    LD   (HL), D                   ; FirstBlock = new_block
    INC  HL
    LD   (HL), E
    INC  HL
    LD   (HL), D                   ; LastBlock = new_block
    JP   fs_bwa_write_inode

fs_bwa_first_span:
    ; No spans: create first span {new_block, new_block}
    LD   A, 1
    LD   (DISK_BUFFER + INODE_OFF_COUNT), A
    LD   HL, DISK_BUFFER + INODE_OFF_SPANS
    LD   DE, (fs_temp_io_pba)
    LD   (HL), E
    INC  HL
    LD   (HL), D
    INC  HL
    LD   (HL), E
    INC  HL
    LD   (HL), D

fs_bwa_write_inode:
    ; Write modified inode back to disk
    LD   HL, (fs_temp_io_inode)
    LD   DE, DISK_BUFFER
    CALL fs_write_block
    OR   A
    JP   NZ, fs_file_bwrite_exit
    ; Continue to write the data block and update pos/size
    JP   fs_file_bwrite_do

fs_bwa_no_space:
    LD   A, ERR_NO_SPACE

fs_file_bwrite_exit:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; fs_flush_filesize
; Scan the root directory for the entry matching this file's inode
; and update its size field from the open handle.
; Inputs:
;   (fs_temp_io_slot)  - pointer to the open file PDT slot
;   (fs_temp_blk_id)   - block device ID
; Outputs:
;   A  - ERR_SUCCESS or error code
; Modifies: DISK_BUFFER, fs_temp_dir_* vars
; ------------------------------------------------------------
fs_flush_filesize:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Read file's inode from handle and save for searching
    LD   HL, (fs_temp_io_slot)
    LD   BC, PHYSDEV_OFF_DATA + HND_OFF_ROOT_INODE
    ADD  HL, BC
    LD   A, (HL)
    LD   (fs_temp_dir_inode), A
    INC  HL
    LD   A, (HL)
    LD   (fs_temp_dir_inode + 1), A

    ; Read parent dir inode into DISK_BUFFER (from handle's HND_OFF_PARENT_INO field)
    LD   HL, (fs_temp_io_slot)
    LD   BC, PHYSDEV_OFF_DATA + HND_OFF_PARENT_INO
    ADD  HL, BC
    LD   A, (HL)                ; A = parent inode low byte
    INC  HL                     ; advance pointer to high byte
    LD   H, (HL)                ; H = parent inode high byte
    LD   L, A                   ; L = parent inode low byte; HL = parent inode
    CALL fs_read_inode
    OR   A
    JP   NZ, fs_flush_exit

    ; Cache spans from parent directory inode
    CALL fs_cache_inode_spans
    XOR  A
    LD   (fs_temp_dir_span), A

fs_flush_span_loop:
    LD   A, (fs_temp_dir_spans)
    LD   B, A
    LD   A, (fs_temp_dir_span)
    CP   B
    JP   NC, fs_flush_not_found    ; exhausted all spans
    ; If span index >= 13, re-read parent inode from disk
    CP   13
    JP   NC, fs_flush_reload_span
    CALL fs_dir_load_span       ; load fs_temp_dir_blk / fs_temp_dir_lastblk
    JP   fs_flush_block_loop

fs_flush_reload_span:
    ; Re-read parent directory inode from disk
    PUSH AF                         ; save span index
    LD   HL, (fs_temp_io_slot)
    LD   BC, PHYSDEV_OFF_DATA + HND_OFF_PARENT_INO
    ADD  HL, BC
    LD   A, (HL)
    INC  HL
    LD   H, (HL)
    LD   L, A                       ; HL = parent inode
    CALL fs_read_inode
    POP  BC                         ; B = span index
    OR   A
    JP   NZ, fs_flush_exit
    CALL fs_load_span_from_buffer

fs_flush_block_loop:
    LD   HL, (fs_temp_dir_blk)
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    JP   NZ, fs_flush_exit

    ; Scan 16 entries in this block
    LD   HL, DISK_BUFFER
    LD   B, 16
fs_flush_scan_entry:
    ; Skip unused entries
    LD   A, (HL)
    AND  DIRENT_TYPE_USED
    JP   Z, fs_flush_entry_skip

    ; Compare inode
    PUSH HL
    PUSH BC
    LD   BC, DIRENT_OFF_INODE
    ADD  HL, BC
    LD   C, (HL)                   ; C = entry inode low
    INC  HL
    LD   B, (HL)                   ; B = entry inode high
    LD   HL, (fs_temp_dir_inode)   ; HL = target inode
    LD   A, L
    CP   C
    JP   NZ, fs_flush_inode_no
    LD   A, H
    CP   B
    JP   NZ, fs_flush_inode_no

    ; Inode matches — update size in DISK_BUFFER
    POP  BC
    POP  HL
    LD   BC, DIRENT_OFF_SIZE
    ADD  HL, BC                    ; HL = &entry.size in DISK_BUFFER

    ; Read 3-byte filesize from slot, zero-extend to 4 bytes, write to dirent
    PUSH HL
    LD   HL, (fs_temp_io_slot)
    LD   BC, PHYSDEV_OFF_DATA + HND_OFF_FILESIZE
    ADD  HL, BC
    LD   A, (HL)
    LD   B, A
    INC  HL
    LD   A, (HL)
    LD   C, A
    INC  HL
    LD   A, (HL)
    LD   D, A
    LD   E, 0                      ; BCDE = filesize (B=lo, C, D, E=0)
    POP  HL
    LD   (HL), B
    INC  HL
    LD   (HL), C
    INC  HL
    LD   (HL), D
    INC  HL
    LD   (HL), E

    ; Write block back
    LD   HL, (fs_temp_dir_blk)
    LD   DE, DISK_BUFFER
    CALL fs_write_block
    JP   fs_flush_exit             ; A = result

fs_flush_inode_no:
    POP  BC
    POP  HL
fs_flush_entry_skip:
    DEC  B
    JP   Z, fs_flush_next_block
    LD   DE, 32
    ADD  HL, DE
    JP   fs_flush_scan_entry

fs_flush_next_block:
    CALL fs_dir_advance_block
    JP   C, fs_flush_next_span
    JP   fs_flush_block_loop

fs_flush_next_span:
    LD   A, (fs_temp_dir_span)
    INC  A
    LD   (fs_temp_dir_span), A
    JP   fs_flush_span_loop

fs_flush_not_found:
    LD   A, ERR_NOT_FOUND

fs_flush_exit:
    POP  HL
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; fs_close (slot 6 of dft_fs / slot 8 of dft_file)
; Closes an open file/directory by freeing its PDT slot.
; For files opened with HND_FLAG_WRITE, flushes the size to disk first.
; Inputs:
;   B  - file device ID
; Outputs:
;   A  - ERR_SUCCESS or error code
; ------------------------------------------------------------
fs_close:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE
    PUSH HL                     ; preserve HL

    ; Find the slot
    LD   A, B
    CALL find_physdev_by_id
    LD   A, H
    OR   L
    JP   Z, fs_close_err

    ; Check if this is a writable file that needs size flushed
    LD   (fs_temp_io_slot), HL
    LD   DE, PHYSDEV_OFF_DATA + HND_OFF_FLAGS
    ADD  HL, DE
    LD   A, (HL)
    AND  HND_FLAG_WRITE
    JP   Z, fs_close_no_flush

    ; Set block device from slot's parent field
    LD   HL, (fs_temp_io_slot)
    LD   DE, PHYSDEV_OFF_PARENT
    ADD  HL, DE
    LD   A, (HL)
    LD   (fs_temp_blk_id), A

    CALL fs_flush_filesize       ; flush size to disk (ignore errors)

fs_close_no_flush:
    LD   HL, (fs_temp_io_slot)

    PUSH HL                     ; save physdev pointer

    ; Remove from linked list (PHYSDEV_LIST_HEAD)
    LD   HL, (PHYSDEV_LIST_HEAD)
    EX   DE, HL
    POP  HL
    PUSH HL                     ; save target node

    ; Are we the head?
    ; Compare target HL with DE
    LD   A, L
    SUB  E
    LD   A, H
    SBC  D
    JP   NZ, fs_close_list_find

    ; We're head. HEAD = HEAD->NEXT
    LD   DE, PHYSDEV_OFF_NEXT
    ADD  HL, DE
    LD   A, (HL)                ; L
    INC  HL
    LD   H, (HL)                ; H
    LD   L, A
    LD   (PHYSDEV_LIST_HEAD), HL
    JP   fs_close_free

fs_close_list_find:
    ; Walk the list DE->NEXT looking for target HL
    PUSH HL                     ; save target
    LD   HL, PHYSDEV_OFF_NEXT
    ADD  HL, DE
    LD   A, (HL)
    LD   C, A
    INC  HL
    LD   A, (HL)
    LD   B, A                   ; BC = DE->NEXT
    POP  HL

    ; Check if BC == target (HL)
    LD   A, L
    SUB  C
    LD   A, H
    SBC  B
    JP   Z, fs_close_list_found

    ; Not found, DE = BC
    LD   E, C
    LD   D, B
    ; Is DE 0?
    LD   A, D
    OR   E
    JP   Z, fs_close_free       ; Not in list? Still free it.
    JP   fs_close_list_find

fs_close_list_found:
    ; DE is previous node. Change DE->NEXT to Target->NEXT.
    PUSH DE                     ; save previous node
    LD   DE, PHYSDEV_OFF_NEXT
    ADD  HL, DE
    LD   A, (HL)
    LD   C, A
    INC  HL
    LD   A, (HL)
    LD   B, A                   ; BC = Target->NEXT

    POP  HL                     ; HL = previous node
    LD   DE, PHYSDEV_OFF_NEXT
    ADD  HL, DE
    LD   (HL), C
    INC  HL
    LD   (HL), B

fs_close_free:
    POP  HL                     ; restore target node
    ; Free the slot (ID = 0)
    LD   DE, PHYSDEV_OFF_ID
    ADD  HL, DE
    XOR  A
    LD   (HL), A

    XOR  A
    JP   fs_close_exit

fs_close_err:
    LD   A, ERR_INVALID_DEVICE

fs_close_exit:
    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

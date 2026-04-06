; ------------------------------------------------------------
; fs_dir_bread (slot 2 of dft_dir, overriding ReadBlock)
; Reads the next directory entry into the caller's buffer.
; Skips unused entries. Dirs use HND_OFF_POS to store entry index.
; Inputs:
;   B  - file device ID
;   DE - pointer to 32-byte destination buffer
; Outputs:
;   A  - ERR_SUCCESS or ERR_EOF / error
; ------------------------------------------------------------
fs_dir_bread:
    PUSH BC                     ; preserve BC (B = device ID)
    PUSH DE                     ; preserve DE (buffer pointer)
    LD   (fs_temp_io_buf), DE   ; save dest buffer

fs_dir_bread_loop:
    ; 1. Get user data & block dev
    CALL fs_get_slot_data
    OR   A
    JP   NZ, fs_dir_bread_exit

    PUSH HL                     ; preserve user data pointer
    CALL fs_setup_block_dev
    POP  HL
    OR   A
    JP   NZ, fs_dir_bread_exit

    CALL fs_get_file_state

    ; 2. Calculate LBA and Entry Index inside block
    ; HND_OFF_POS contains the absolute ENTRY INDEX.
    ; Each block has 512/32 = 16 entries.
    ; LBA = Pos / 16 (shift right 4)
    ; Entry Offset = (Pos % 16) * 32

    ; Load Pos (low 16 bits is enough, directories > 65535 entries = >2MB)
    LD   HL, (fs_temp_io_pos)
    ; We use HL for arithmetic

    ; Shift Right 4 times to get LBA
    LD   A, H
    LD   C, L
    ; Shift 1
    OR   A                      ; clear carry
    RRA
    LD   H, A
    LD   A, C
    RRA
    LD   C, A
    ; Shift 2
    OR   A
    LD   A, H
    RRA
    LD   H, A
    LD   A, C
    RRA
    LD   C, A
    ; Shift 3
    OR   A
    LD   A, H
    RRA
    LD   H, A
    LD   A, C
    RRA
    LD   C, A
    ; Shift 4
    OR   A
    LD   A, H
    RRA
    LD   H, A
    LD   A, C
    RRA
    LD   L, A
    ; HL = LBA
    LD   (fs_temp_io_lba), HL

    ; 3. Get Physical Block (uses span cache to avoid re-reading inode)
    CALL fs_resolve_pba
    OR   A
    JP   NZ, fs_dir_bread_exit  ; EOF or IO Error

    ; 4. Read the block into DISK_BUFFER
    ; We must use fs_read_block which needs HL = block number
    LD   HL, (fs_temp_io_pba)
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    JP   NZ, fs_dir_bread_exit

    ; 5. Get Entry Offset
    ; Pos % 16 = low 4 bits of original Pos
    LD   A, (fs_temp_io_pos)
    AND  0x0F
    ; Multiply by 32 (shift left 5)
    LD   L, A
    LD   H, 0
    ; Shift left 5 is add HL, HL 5 times
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL                 ; HL = Entry offset in block

    LD   DE, DISK_BUFFER
    ADD  HL, DE                 ; HL = pointer to entry in DISK_BUFFER

    ; 6. Check if entry is USED
    LD   A, (HL)
    AND  DIRENT_TYPE_USED
    JP   Z, fs_dir_bread_advance ; If unused, advance to next entry

    ; 7. Copy 32 bytes to caller's buffer
    LD   DE, (fs_temp_io_buf)
    LD   B, 32
fs_dir_bread_copy:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, fs_dir_bread_copy

    ; 8. Advance Pos by 1 (used entry)
    CALL fs_dir_advance_pos

    XOR  A
    JP   fs_dir_bread_exit

fs_dir_bread_advance:
    ; Entry unused. Advance Pos by 1 and retry.
    CALL fs_dir_advance_pos
    JP   fs_dir_bread_loop      ; B = device ID still valid; loop back

fs_dir_bread_exit:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; fs_dir_advance_pos
; Increments directory entry position by 1 and writes back to handle.
; Inputs:
;   (fs_temp_io_pos)  - current position
;   (fs_temp_io_slot) - PDT slot pointer
; Outputs:
;   (none — updates handle and fs_temp_io_pos)
; ------------------------------------------------------------
fs_dir_advance_pos:
    LD   HL, (fs_temp_io_pos)
    INC  HL                     ; HL = new pos
    LD   (fs_temp_io_pos), HL   ; update temp var for next iteration
    PUSH HL                     ; save new pos
    LD   HL, (fs_temp_io_slot)
    LD   DE, PHYSDEV_OFF_DATA + HND_OFF_POS
    ADD  HL, DE                 ; HL = &handle->pos
    POP  DE                     ; DE = new pos
    LD   A, E
    LD   (HL), A
    INC  HL
    LD   A, D
    LD   (HL), A
    RET

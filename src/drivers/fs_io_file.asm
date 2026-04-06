; ------------------------------------------------------------
; fs_file_bread (slot 2 of dft_file)
; Reads a 512-byte block from an open file.
; Inputs:
;   B  - file device ID
;   DE - pointer to 512-byte destination buffer
; Outputs:
;   A  - ERR_SUCCESS or ERR_EOF / error
; ------------------------------------------------------------
fs_file_bread:
    PUSH BC                     ; preserve BC (B = device ID)
    PUSH DE                     ; preserve DE (buffer pointer)
    LD   (fs_temp_io_buf), DE   ; save dest buffer

    ; 1. Get user data & block dev
    CALL fs_get_slot_data
    OR   A
    JP   NZ, fs_file_bread_exit
    CALL fs_setup_block_dev
    OR   A
    JP   NZ, fs_file_bread_exit
    CALL fs_get_file_state

    ; 2. EOF check: block_pos >= ceil(filesize / 512)
    ;    ceil(filesize/512) = (filesize + 511) >> 9
    ;    With 3-byte filesize [0,1,2]: add 0x01FF to [0,1]
    ;    Then bytes [1,2] >> 1 = block count (2 bytes)
    LD   HL, (fs_temp_io_slot)
    LD   DE, PHYSDEV_OFF_DATA + HND_OFF_FILESIZE
    ADD  HL, DE                 ; HL = &filesize[0]
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = filesize[0..1]
    INC  HL
    LD   C, (HL)                ; C = filesize[2]
    ; Add 511 (0x01FF) to DE:C
    LD   A, E
    ADD  A, 0xFF
    LD   E, A
    LD   A, D
    ADC  A, 0x01
    LD   D, A
    LD   A, C
    ADC  A, 0
    LD   C, A                   ; C:DE = filesize + 511
    ; Shift C:D right 1 to get block count in C:D
    ; (we only need bytes [1,2] >> 1 = D >> 1 with C as high)
    LD   A, C
    OR   A                      ; clear carry
    RRA
    LD   B, A                   ; B = block_count high byte
    LD   A, D
    RRA
    LD   C, A                   ; C = block_count low byte
    ; BC = ceil(filesize / 512)
    ; Compare block_pos (2 bytes) >= BC
    LD   HL, (fs_temp_io_pos)   ; HL = block_pos
    LD   A, H
    CP   B
    JP   C, fs_file_bread_not_eof ; pos_hi < count_hi, not EOF
    JP   NZ, fs_file_bread_eof   ; pos_hi > count_hi, EOF
    LD   A, L
    CP   C
    JP   C, fs_file_bread_not_eof ; pos_lo < count_lo, not EOF
    ; block_pos >= block_count → EOF
fs_file_bread_eof:
    LD   A, ERR_EOF
    JP   fs_file_bread_exit
fs_file_bread_not_eof:

    ; 3. Block position IS the LBA
    LD   HL, (fs_temp_io_pos)
    LD   (fs_temp_io_lba), HL

    ; 4. Get Physical Block (uses span cache to avoid re-reading inode)
    CALL fs_resolve_pba
    OR   A
    JP   NZ, fs_file_bread_exit ; EOF or IO Error

    ; 5. Read the block into caller's buffer
    LD   HL, (fs_temp_io_pba)
    LD   DE, (fs_temp_io_buf)
    CALL fs_read_block
    OR   A
    JP   NZ, fs_file_bread_exit

    ; 6. Advance block position by 1 and save to slot
    CALL fs_advance_block_pos

    XOR  A

fs_file_bread_exit:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; fs_file_bgetpos (slot 5 of dft_file / dft_dir)
; Gets the current block position.
; Inputs:
;   B  - file/dir device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - block position
; ------------------------------------------------------------
fs_file_bgetpos:
    LD   DE, PHYSDEV_OFF_DATA + HND_OFF_POS
    JP   common_bgetpos

; ------------------------------------------------------------
; fs_file_seek (slot 4 of dft_file)
; Sets file block position.
; Inputs:
;   B  - file device ID
;   DE - block number (0-based)
; Outputs:
;   A  - ERR_SUCCESS or error code
; ------------------------------------------------------------
fs_file_seek:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE (block number)
    PUSH HL                     ; preserve HL

    CALL fs_get_slot_data
    OR   A
    JP   NZ, fs_file_seek_exit

    LD   BC, HND_OFF_POS
    ADD  HL, BC                 ; HL = &handle->pos

    LD   (HL), E                ; write block number low byte
    INC  HL
    LD   (HL), D                ; write block number high byte

    XOR  A

fs_file_seek_exit:
    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; fs_file_bgetsize (slot 6 of dft_file)
; Reads the active file length.
; Inputs:
;   B  - file device ID
;   DE - pointer to 4-byte buffer for the filesize
; Outputs:
;   A  - ERR_SUCCESS or error code
; ------------------------------------------------------------
fs_file_bgetsize:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE (output buffer pointer)
    PUSH HL                     ; preserve HL

    CALL fs_get_slot_data
    OR   A
    JP   NZ, fs_file_bgetsize_exit

    LD   BC, HND_OFF_FILESIZE
    ADD  HL, BC                 ; HL = &handle->filesize

    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    LD   A, (HL)
    LD   (DE), A    ; 3 bytes read; zero-extend 4th for external interface
    INC  DE
    XOR  A
    LD   (DE), A

    XOR  A

fs_file_bgetsize_exit:
    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; fs_file_bsetsize (slot 7 of dft_file)
; Sets the active file length from a 4-byte buffer.
; Only the low 3 bytes are stored (max file size = 16 MB).
; Inputs:
;   B  - file device ID
;   DE - pointer to 4-byte new size in bytes (little-endian)
; Outputs:
;   A  - ERR_SUCCESS or error code
; ------------------------------------------------------------
fs_file_bsetsize:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE (input buffer pointer)
    PUSH HL                     ; preserve HL

    CALL fs_get_slot_data
    OR   A
    JP   NZ, fs_file_bsetsize_exit

    LD   BC, HND_OFF_FILESIZE
    ADD  HL, BC                 ; HL = &handle->filesize

    LD   A, (DE)
    LD   (HL), A
    INC  DE
    INC  HL
    LD   A, (DE)
    LD   (HL), A
    INC  DE
    INC  HL
    LD   A, (DE)
    LD   (HL), A                ; 3 bytes written from input buffer

    ; Mark handle as writable so fs_close flushes size to disk
    LD   HL, (fs_temp_io_slot)
    LD   DE, PHYSDEV_OFF_DATA + HND_OFF_FLAGS
    ADD  HL, DE
    LD   A, (HL)
    OR   HND_FLAG_WRITE
    LD   (HL), A

    XOR  A

fs_file_bsetsize_exit:
    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

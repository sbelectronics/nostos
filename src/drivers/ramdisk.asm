; ============================================================
; ramdisk.asm - RAM/ROM disk block device driver
; ============================================================
; Implements a block device backed by a contiguous range of
; memory pages mapped through window 1 (0x4000-0x7FFF).
;
; ROM and RAM disk share most code, but the ROM disk uses a
; separate DFT that returns ERR_READ_ONLY for block writes.
;
; Each 16KB page holds RD_BLOCKS_PER_PAGE (32) 512-byte blocks.
; Block numbers passed to bseek/bread/bwrite are zero-relative
; from block 0 of start_page.
;
; Temporary variables (KERN_TEMP_SPACE + 74..79)
; Offsets 80+ are used by fs_open (+80), fs_io (+90), fs_remove (+119), etc.
; Do not extend rd_temp_* past +79 without checking constants.asm.
rd_temp_slot        EQU KERN_TEMP_SPACE + 74   ; PDT slot pointer (2 bytes)
rd_temp_page        EQU KERN_TEMP_SPACE + 76   ; computed actual page (1 byte)
rd_temp_bip         EQU KERN_TEMP_SPACE + 77   ; block_in_page (1 byte)
rd_temp_start       EQU KERN_TEMP_SPACE + 78   ; start_page (1 byte)
rd_temp_end         EQU KERN_TEMP_SPACE + 79   ; end_page (1 byte)

; ============================================================
; Device Function Table
; ============================================================
dft_romdisk:
    DEFW null_init          ; slot 0: Initialize (shared, returns SUCCESS)
    DEFW null_init          ; slot 1: GetStatus (shared, returns SUCCESS)
    DEFW rd_bread           ; slot 2: ReadBlock
    DEFW rd_bwrite_readonly ; slot 3: WriteBlock (read-only, returns ERR_READ_ONLY)
    DEFW rd_bseek           ; slot 4: Seek
    DEFW rd_bgetpos         ; slot 5: GetPosition
    DEFW rd_bgetsize        ; slot 6: GetLength
    DEFW un_error           ; slot 7: SetSize (not supported)
    DEFW un_error           ; slot 8: Close (not supported)

dft_ramdisk:
    DEFW null_init          ; slot 0: Initialize (shared, returns SUCCESS)
    DEFW null_init          ; slot 1: GetStatus (shared, returns SUCCESS)
    DEFW rd_bread           ; slot 2: ReadBlock
    DEFW rd_bwrite          ; slot 3: WriteBlock
    DEFW rd_bseek           ; slot 4: Seek
    DEFW rd_bgetpos         ; slot 5: GetPosition
    DEFW rd_bgetsize        ; slot 6: GetLength
    DEFW un_error           ; slot 7: SetSize (not supported)
    DEFW un_error           ; slot 8: Close (not supported)

; ============================================================
; PDTENTRY_ROMDISK ID, NAME, START_PAGE, END_PAGE
; PDTENTRY_RAMDISK ID, NAME, START_PAGE, END_PAGE
; Macro: Declare a ROM PDT entry for a rom|ram disk block device.
; The difference between ROM and RAM disks is that the ROM disk
; lacks the capability bit for DEVCAP_BLOCK_OUT.
; Arguments:
;   ID         - physical device ID (PHYSDEV_ID_*)
;   NAME       - 4-character device name string (e.g. "ROMD")
;   START_PAGE - first page number
;   END_PAGE   - last page number (inclusive)
; ============================================================

PDTENTRY_ROMDISK macro ID, NAME, START_PAGE, END_PAGE
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes: 4-char name + 3 nulls)
    DEFB DEVCAP_BLOCK_IN                ; PHYSDEV_OFF_CAPS (read-only block device)
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_romdisk                    ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFB START_PAGE                     ; RD_OFF_START_PAGE
    DEFB END_PAGE                       ; RD_OFF_END_PAGE
    DEFW 0                              ; RD_OFF_CUR_BLOCK: seek position starts at 0
    DEFS 13, 0                          ; padding to fill 17-byte user data field
endm

PDTENTRY_RAMDISK macro ID, NAME, START_PAGE, END_PAGE
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes: 4-char name + 3 nulls)
    DEFB DEVCAP_BLOCK_IN | DEVCAP_BLOCK_OUT ; PHYSDEV_OFF_CAPS (read-write block device)
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_ramdisk                    ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFB START_PAGE                     ; RD_OFF_START_PAGE
    DEFB END_PAGE                       ; RD_OFF_END_PAGE
    DEFW 0                              ; RD_OFF_CUR_BLOCK: seek position starts at 0
    DEFS 13, 0                          ; padding to fill 17-byte user data field
endm

; rd_init / rd_getstatus share null_init (ERR_SUCCESS, HL=0)
; rd_not_supported shares un_error (ERR_NOT_SUPPORTED, HL=0)

; ------------------------------------------------------------
; rd_get_slot
; Find PDT slot for device B and load start/end page.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   (rd_temp_slot)  = slot pointer
;   (rd_temp_start) = start_page
;   (rd_temp_end)   = end_page
; Clobbers: HL, BC
; ------------------------------------------------------------
rd_get_slot:
    LD   A, B
    CALL find_physdev_by_id
    LD   A, H
    OR   L
    JP   Z, rd_get_slot_err
    LD   (rd_temp_slot), HL
    LD   BC, PHYSDEV_OFF_DATA + RD_OFF_START_PAGE
    ADD  HL, BC
    LD   A, (HL)
    LD   (rd_temp_start), A
    INC  HL
    LD   A, (HL)
    LD   (rd_temp_end), A
    XOR  A
    RET
rd_get_slot_err:
    LD   A, ERR_INVALID_DEVICE
    RET

; ------------------------------------------------------------
; rd_resolve_block
; Load cur_block from PDT, compute actual page and block-in-page,
; and check bounds. Must be called after rd_get_slot succeeds.
; Inputs:
;   (rd_temp_slot)  = PDT slot pointer
;   (rd_temp_start) = start_page
;   (rd_temp_end)   = end_page
; Outputs:
;   A  - ERR_SUCCESS or ERR_EOF
;   (rd_temp_page) = actual page number (if success)
;   (rd_temp_bip)  = block-in-page (if success)
; Clobbers: BC, HL
; ------------------------------------------------------------
rd_resolve_block:
    ; Load cur_block: C = low, B = high
    LD   HL, (rd_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + RD_OFF_CUR_BLOCK
    ADD  HL, BC
    LD   C, (HL)
    INC  HL
    LD   B, (HL)

    ; block_in_page = cur_block & 0x1F
    LD   A, C
    AND  0x1F
    LD   (rd_temp_bip), A

    ; page_offset = cur_block >> 5  (5 logical right shifts of BC into HL)
    LD   H, B
    LD   L, C
    LD   B, 5
rd_resolve_block_shift:
    OR   A                      ; clear carry for logical shift
    LD   A, H
    RRA                         ; H bit 0 -> carry
    LD   H, A
    LD   A, L
    RRA                         ; carry (old H bit 0) -> L bit 7
    LD   L, A
    DEC  B
    JP   NZ, rd_resolve_block_shift ; L = page_offset after 5 iterations

    ; actual_page = start_page + page_offset; check <= end_page
    LD   A, (rd_temp_start)
    ADD  L                      ; A = actual_page
    LD   (rd_temp_page), A
    LD   B, A
    LD   A, (rd_temp_end)
    CP   B                      ; carry set if end_page < actual_page
    JP   C, rd_resolve_block_eof
    XOR  A
    RET
rd_resolve_block_eof:
    LD   A, ERR_EOF
    RET

; ------------------------------------------------------------
; rd_inc_curblock
; Increment the 16-bit cur_block in the PDT slot.
; Inputs:
;   (rd_temp_slot) = PDT slot pointer
; Outputs:
;   (none)
; Clobbers: A, BC, HL
; ------------------------------------------------------------
rd_inc_curblock:
    LD   HL, (rd_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + RD_OFF_CUR_BLOCK
    ADD  HL, BC
    LD   A, (HL)
    INC  A
    LD   (HL), A
    JP   NZ, rd_inc_curblock_done
    INC  HL
    LD   A, (HL)
    INC  A
    LD   (HL), A
rd_inc_curblock_done:
    RET

; ------------------------------------------------------------
; rd_win2_addr
; Compute the window-2 base address for the current block-in-page.
; Inputs:
;   (rd_temp_bip) = block-in-page
; Outputs:
;   A  - high byte of WIN2 address (0x80 + bip * 2)
; Clobbers: C
; ------------------------------------------------------------
rd_win2_addr:
    LD   A, (rd_temp_bip)
    ADD  A                      ; block_in_page * 2
    LD   C, A
    LD   A, 0x80
    ADD  C                      ; 0x80 + block_in_page * 2
    RET

; ------------------------------------------------------------
; Shared error exits for rd_bread / rd_bwrite.
; Both functions push the caller's DE before calling helpers,
; so these exits pop it before returning.
; ------------------------------------------------------------
rd_eof_pop:
    POP  DE
    LD   A, ERR_EOF
    LD   HL, 0
    RET

rd_err_pop:
    POP  DE
    LD   HL, 0
    RET                         ; A = error code from rd_get_slot

; ------------------------------------------------------------
; rd_bgetpos
; Get the current block position.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - block position
; ------------------------------------------------------------
rd_bgetpos:
    LD   DE, PHYSDEV_OFF_DATA + RD_OFF_CUR_BLOCK
    JP   common_bgetpos

; ------------------------------------------------------------
; rd_bseek
; Set current block position.
; Inputs:
;   B  - device ID
;   DE - block number
; Outputs:
;   A  - ERR_SUCCESS or error
;   HL - 0
; ------------------------------------------------------------
rd_bseek:
    PUSH DE                     ; save block number across rd_get_slot
    CALL rd_get_slot
    POP  DE
    OR   A
    JP   NZ, rd_exit
    LD   HL, (rd_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + RD_OFF_CUR_BLOCK
    ADD  HL, BC
    LD   A, E
    LD   (HL), A                ; cur_block low
    INC  HL
    LD   A, D
    LD   (HL), A                ; cur_block high
    XOR  A
rd_exit:
    LD   HL, 0
    RET

; ------------------------------------------------------------
; rd_bread
; Read one 512-byte block from the disk into a buffer.
; Inputs:
;   B  - device ID
;   DE - 512-byte destination buffer
; Outputs:
;   A  - ERR_SUCCESS / ERR_EOF / ERR_INVALID_DEVICE
;   HL - 0
; ------------------------------------------------------------
rd_bread:
    PUSH DE                     ; [SP] = dest buffer

    CALL rd_get_slot
    OR   A
    JP   NZ, rd_err_pop

    CALL rd_resolve_block
    OR   A
    JP   NZ, rd_eof_pop

    ; WIN2 source address: high = 0x80 + bip*2, low = 0x00
    CALL rd_win2_addr           ; A = high byte
    LD   H, A
    LD   L, 0                   ; HL = WIN2 source

    ; Map page into WIN2, copy to DISK_BUFFER, restore WIN2
    DI
    LD   A, (rd_temp_page)
    OUT  (MAPPER_WIN2_PORT), A
    LD   DE, DISK_BUFFER
    CALL rd_copy_512            ; WIN2 (HL) -> DISK_BUFFER (DE)
    LD   A, MAPPER_WIN2_RAM
    OUT  (MAPPER_WIN2_PORT), A
    EI

    CALL rd_inc_curblock

    ; Copy DISK_BUFFER -> user dest (skip if dest IS DISK_BUFFER)
    POP  DE
    LD   HL, DISK_BUFFER
    LD   A, H
    CP   D
    JP   NZ, rd_bread_copy_out
    LD   A, L
    CP   E
    JP   Z, rd_bread_done
rd_bread_copy_out:
    CALL rd_copy_512            ; DISK_BUFFER (HL) -> user dest (DE)
rd_bread_done:
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; rd_bwrite_readonly
; Reject writes on read-only (ROM) disk devices.
; Inputs:
;   B  - device ID
;   DE - 512-byte source buffer (ignored)
; Outputs:
;   A  - ERR_READ_ONLY
;   HL - 0
; ------------------------------------------------------------
rd_bwrite_readonly:
    LD   A, ERR_READ_ONLY
    LD   HL, 0
    RET

; ------------------------------------------------------------
; rd_bwrite
; Write a 512-byte block to the RAM disk at the current position.
; Inputs:
;   B  - device ID
;   DE - 512-byte source buffer
; Outputs:
;   A  - ERR_SUCCESS / ERR_EOF / ERR_INVALID_DEVICE
;   HL - 0
; ------------------------------------------------------------
rd_bwrite:
    PUSH DE                     ; [SP] = source buffer

    CALL rd_get_slot
    OR   A
    JP   NZ, rd_err_pop

    CALL rd_resolve_block
    OR   A
    JP   NZ, rd_eof_pop

    ; Copy source buffer -> DISK_BUFFER (skip if source IS DISK_BUFFER)
    POP  DE                     ; DE = source buffer
    LD   HL, DISK_BUFFER
    LD   A, H
    CP   D
    JP   NZ, rd_bwrite_copy_in
    LD   A, L
    CP   E
    JP   Z, rd_bwrite_do        ; already in DISK_BUFFER
rd_bwrite_copy_in:
    EX   DE, HL                 ; HL = source, DE = DISK_BUFFER
    CALL rd_copy_512            ; source (HL) -> DISK_BUFFER (DE)

rd_bwrite_do:
    ; WIN2 dest address: high = 0x80 + bip*2, low = 0x00
    CALL rd_win2_addr           ; A = high byte
    LD   D, A
    LD   E, 0                   ; DE = WIN2 dest
    LD   HL, DISK_BUFFER        ; HL = source (always DISK_BUFFER)

    ; Map page into WIN2, copy DISK_BUFFER to WIN2, restore
    DI
    LD   A, (rd_temp_page)
    OUT  (MAPPER_WIN2_PORT), A
    CALL rd_copy_512            ; DISK_BUFFER (HL) -> WIN2 (DE)
    LD   A, MAPPER_WIN2_RAM
    OUT  (MAPPER_WIN2_PORT), A
    EI

    CALL rd_inc_curblock

    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; rd_bgetsize
; Write total device size in bytes (4-byte little-endian) to DE.
; Inputs:
;   B  - device ID
;   DE - pointer to 4-byte output buffer
; Outputs:
;   A  - ERR_SUCCESS or error
;   HL - 0
;
; size = num_pages * 16384 = num_pages * 0x4000
; As 4-byte LE: byte0=0, byte1=(num_pages&3)<<6, byte2=num_pages>>2, byte3=0
; ------------------------------------------------------------
rd_bgetsize:
    PUSH DE                     ; save output buffer pointer
    CALL rd_get_slot
    POP  DE
    OR   A
    JP   NZ, rd_exit

    ; num_pages = end_page - start_page + 1
    LD   A, (rd_temp_end)
    LD   B, A
    LD   A, (rd_temp_start)
    LD   C, A
    LD   A, B
    SUB  C
    INC  A                      ; A = num_pages

    PUSH AF                     ; save num_pages

    ; byte 0 = 0
    XOR  A
    LD   (DE), A
    INC  DE

    ; byte 1 = (num_pages & 0x03) << 6
    ; RRCA rotates right circular (bit 0 -> bit 7), so two rotations
    ; of a 2-bit value (0b000000ba) yield 0bba000000.
    POP  AF
    PUSH AF
    AND  0x03
    RRCA                        ; 0b000000ba -> 0ba00000b0
    RRCA                        ; 0ba00000b0 -> 0bba000000
    LD   (DE), A
    INC  DE

    ; byte 2 = num_pages >> 2
    POP  AF
    OR   A                      ; clear carry
    RRA                         ; >> 1
    OR   A
    RRA                         ; >> 2
    LD   (DE), A
    INC  DE

    ; byte 3 = 0
    XOR  A
    LD   (DE), A

    ; A already 0 = ERR_SUCCESS
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; rd_copy_512
; Copy 512 bytes from (HL) to (DE).
; Inputs:
;   HL - source address
;   DE - destination address
; Outputs:
;   (none)
; Clobbers: A, BC, HL, DE
; Uses two loops of 256 (no LDIR -- 8080 compatible).
; ------------------------------------------------------------
rd_copy_512:
    LD   C, 0                   ; C=0 -> DEC wraps to 255 -> 256 iterations
rd_copy_512_a:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  C
    JP   NZ, rd_copy_512_a
    LD   C, 0
rd_copy_512_b:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  C
    JP   NZ, rd_copy_512_b
    RET

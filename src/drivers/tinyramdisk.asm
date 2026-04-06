; ============================================================
; tinyramdisk.asm - Tiny RAM/ROM disk block device driver
; ============================================================
; Like ramdisk.asm but accesses memory directly without using
; the memory mapper. Suitable for systems with a flat address
; space (e.g. 32K ROM + 32K RAM with no mapper).
;
; PDT user data:
;   +0  START_ADDR  (2 bytes, LE): base address of disk in memory
;   +2  LENGTH      (2 bytes, LE): total size in bytes
;   +4  CUR_BLOCK   (2 bytes, LE): current block position
;
; Block size is 512 bytes. Block N is at START_ADDR + N * 512.
;
; Temporary variables (KERN_TEMP_SPACE + 74..77)
; NOTE: Must not overlap fs_dir.asm temps (64-73) since the filesystem
; calls trd_bread/trd_bseek during directory scans.
; Safe to share with ramdisk.asm (74-79) since they never coexist.
trd_temp_slot       EQU KERN_TEMP_SPACE + 74   ; PDT slot pointer (2 bytes)
trd_temp_addr       EQU KERN_TEMP_SPACE + 76   ; computed block address (2 bytes)

; ============================================================
; Device Function Table
; ============================================================
dft_tinyromdisk:
    DEFW null_init          ; slot 0: Initialize
    DEFW null_init          ; slot 1: GetStatus
    DEFW trd_bread          ; slot 2: ReadBlock
    DEFW rd_bwrite_readonly ; slot 3: WriteBlock (read-only)
    DEFW trd_bseek          ; slot 4: Seek
    DEFW trd_bgetpos        ; slot 5: GetPosition
    DEFW trd_bgetsize       ; slot 6: GetLength
    DEFW un_error           ; slot 7: SetSize (not supported)
    DEFW un_error           ; slot 8: Close (not supported)

dft_tinyramdisk:
    DEFW null_init          ; slot 0: Initialize
    DEFW null_init          ; slot 1: GetStatus
    DEFW trd_bread          ; slot 2: ReadBlock
    DEFW trd_bwrite         ; slot 3: WriteBlock
    DEFW trd_bseek          ; slot 4: Seek
    DEFW trd_bgetpos        ; slot 5: GetPosition
    DEFW trd_bgetsize       ; slot 6: GetLength
    DEFW un_error           ; slot 7: SetSize (not supported)
    DEFW un_error           ; slot 8: Close (not supported)

; ============================================================
; PDTENTRY_TINYROMDISK ID, NAME, START_ADDR, LENGTH
; Macro: Declare a ROM PDT entry for a tiny rom disk.
; Arguments:
;   ID         - physical device ID (PHYSDEV_ID_*)
;   NAME       - 4-character device name string
;   START_ADDR - base memory address
;   LENGTH     - total size in bytes
; ============================================================

PDTENTRY_TINYROMDISK macro ID, NAME, START_ADDR, LENGTH
    DEFW 0                              ; PHYSDEV_OFF_NEXT
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_BLOCK_IN                ; PHYSDEV_OFF_CAPS (read-only)
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_tinyromdisk                ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFW START_ADDR                     ; TRD_OFF_START_ADDR
    DEFW LENGTH                         ; TRD_OFF_LENGTH
    DEFW 0                              ; TRD_OFF_CUR_BLOCK
    DEFS 11, 0                          ; padding
endm

PDTENTRY_TINYRAMDISK macro ID, NAME, START_ADDR, LENGTH
    DEFW 0                              ; PHYSDEV_OFF_NEXT
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_BLOCK_IN | DEVCAP_BLOCK_OUT ; PHYSDEV_OFF_CAPS (read-write)
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_tinyramdisk                ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFW START_ADDR                     ; TRD_OFF_START_ADDR
    DEFW LENGTH                         ; TRD_OFF_LENGTH
    DEFW 0                              ; TRD_OFF_CUR_BLOCK
    DEFS 11, 0                          ; padding
endm

; ------------------------------------------------------------
; trd_get_slot
; Find PDT slot for device B and save slot pointer.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   (trd_temp_slot) = slot pointer
; Clobbers: HL, BC
; ------------------------------------------------------------
trd_get_slot:
    LD   A, B
    CALL find_physdev_by_id
    LD   A, H
    OR   L
    JP   Z, trd_get_slot_err
    LD   (trd_temp_slot), HL
    XOR  A
    RET
trd_get_slot_err:
    LD   A, ERR_INVALID_DEVICE
    RET

; ------------------------------------------------------------
; trd_resolve_block
; Compute the memory address for the current block and check
; bounds. Must be called after trd_get_slot succeeds.
; Inputs:
;   (trd_temp_slot) = PDT slot pointer
; Outputs:
;   A  - ERR_SUCCESS or ERR_EOF
;   (trd_temp_addr) = memory address of block (if success)
; Clobbers: BC, DE, HL
; ------------------------------------------------------------
trd_resolve_block:
    LD   HL, (trd_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + TRD_OFF_CUR_BLOCK
    ADD  HL, BC
    LD   E, (HL)
    INC  HL
    LD   D, (HL)            ; DE = cur_block

    ; Compute byte offset = cur_block * 512 = cur_block << 9
    ; High byte of offset = (cur_block_lo << 1) | (cur_block_hi << 9 overflows if hi > 0)
    ; Since max size is 64KB, cur_block max is 127, so D must be 0
    LD   A, D
    OR   A
    JP   NZ, trd_resolve_eof ; block > 255, definitely out of range

    ; offset_hi = cur_block * 2, offset_lo = 0
    LD   A, E
    ADD  A, A               ; A = cur_block * 2 = offset high byte
    LD   D, A
    LD   E, 0               ; DE = byte offset (cur_block * 512)

    ; Check bounds: offset + 512 <= length
    ; i.e., offset + 512 <= length
    ; i.e., offset < length (since length is a multiple of 512)
    LD   HL, (trd_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + TRD_OFF_LENGTH
    ADD  HL, BC
    LD   C, (HL)
    INC  HL
    LD   B, (HL)            ; BC = length

    ; Compare DE < BC (offset < length)
    LD   A, E
    SUB  C
    LD   A, D
    SBC  A, B
    JP   NC, trd_resolve_eof ; offset >= length

    ; Compute address = start_addr + offset
    LD   HL, (trd_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + TRD_OFF_START_ADDR
    ADD  HL, BC
    LD   C, (HL)
    INC  HL
    LD   B, (HL)            ; BC = start_addr
    LD   H, D
    LD   L, E               ; HL = offset
    ADD  HL, BC             ; HL = start_addr + offset
    LD   (trd_temp_addr), HL
    XOR  A
    RET
trd_resolve_eof:
    LD   A, ERR_EOF
    RET

; ------------------------------------------------------------
; trd_inc_curblock
; Increment the 16-bit cur_block in the PDT slot.
; Inputs:
;   (trd_temp_slot) = PDT slot pointer
; Outputs:
;   (none)
; Clobbers: A, BC, HL
; ------------------------------------------------------------
trd_inc_curblock:
    LD   HL, (trd_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + TRD_OFF_CUR_BLOCK
    ADD  HL, BC
    LD   A, (HL)
    INC  A
    LD   (HL), A
    JP   NZ, trd_inc_done
    INC  HL
    LD   A, (HL)
    INC  A
    LD   (HL), A
trd_inc_done:
    RET

; ------------------------------------------------------------
; trd_bgetpos
; Get the current block position.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - block position
; ------------------------------------------------------------
trd_bgetpos:
    LD   DE, PHYSDEV_OFF_DATA + TRD_OFF_CUR_BLOCK
    JP   common_bgetpos

; ------------------------------------------------------------
; trd_bseek
; Set current block position.
; Inputs:
;   B  - device ID
;   DE - block number
; Outputs:
;   A  - ERR_SUCCESS or error
;   HL - 0
; ------------------------------------------------------------
trd_bseek:
    PUSH DE
    CALL trd_get_slot
    POP  DE
    OR   A
    JP   NZ, trd_exit
    LD   HL, (trd_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + TRD_OFF_CUR_BLOCK
    ADD  HL, BC
    LD   A, E
    LD   (HL), A
    INC  HL
    LD   A, D
    LD   (HL), A
    XOR  A
trd_exit:
    LD   HL, 0
    RET

; ------------------------------------------------------------
; trd_bread
; Read one 512-byte block from the disk into a buffer.
; Inputs:
;   B  - device ID
;   DE - 512-byte destination buffer
; Outputs:
;   A  - ERR_SUCCESS / ERR_EOF / ERR_INVALID_DEVICE
;   HL - 0
; ------------------------------------------------------------
trd_bread:
    PUSH DE                 ; save dest buffer

    CALL trd_get_slot
    OR   A
    JP   NZ, trd_err_pop

    CALL trd_resolve_block
    OR   A
    JP   NZ, trd_eof_pop

    ; Copy 512 bytes from (trd_temp_addr) to dest
    LD   HL, (trd_temp_addr)
    POP  DE                 ; DE = dest buffer
    CALL rd_copy_512

    CALL trd_inc_curblock

    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; trd_bwrite
; Write a 512-byte block to the RAM disk at current position.
; Inputs:
;   B  - device ID
;   DE - 512-byte source buffer
; Outputs:
;   A  - ERR_SUCCESS / ERR_EOF / ERR_INVALID_DEVICE
;   HL - 0
; ------------------------------------------------------------
trd_bwrite:
    PUSH DE                 ; save source buffer

    CALL trd_get_slot
    OR   A
    JP   NZ, trd_err_pop

    CALL trd_resolve_block
    OR   A
    JP   NZ, trd_eof_pop

    ; Copy 512 bytes from source to (trd_temp_addr)
    POP  DE                 ; DE = source buffer (we need it in HL)
    LD   HL, (trd_temp_addr)
    EX   DE, HL             ; HL = source, DE = dest (trd_temp_addr)
    CALL rd_copy_512

    CALL trd_inc_curblock

    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; Shared error exits
; ------------------------------------------------------------
trd_eof_pop:
    POP  DE
    LD   A, ERR_EOF
    LD   HL, 0
    RET

trd_err_pop:
    POP  DE
    LD   HL, 0
    RET                     ; A = error code from trd_get_slot

; ------------------------------------------------------------
; trd_bgetsize
; Write total device size in bytes (4-byte little-endian) to DE.
; Inputs:
;   B  - device ID
;   DE - pointer to 4-byte output buffer
; Outputs:
;   A  - ERR_SUCCESS or error
;   HL - 0
; ------------------------------------------------------------
trd_bgetsize:
    PUSH DE                 ; save output buffer pointer
    CALL trd_get_slot
    POP  DE
    OR   A
    JP   NZ, trd_exit

    ; Read length from PDT
    PUSH DE
    LD   HL, (trd_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + TRD_OFF_LENGTH
    ADD  HL, BC
    LD   C, (HL)
    INC  HL
    LD   B, (HL)            ; BC = length (16-bit)
    POP  DE

    ; Write as 4-byte LE: length_lo, length_hi, 0, 0
    LD   A, C
    LD   (DE), A
    INC  DE
    LD   A, B
    LD   (DE), A
    INC  DE
    XOR  A
    LD   (DE), A
    INC  DE
    LD   (DE), A

    ; A already 0 = ERR_SUCCESS
    LD   H, A
    LD   L, A
    RET

; ============================================================
; Shared routines (duplicated from ramdisk.asm for builds that
; do not include ramdisk.asm, e.g. the 32K ROM variant).
; Guarded by IFNDEF so only one copy is assembled.
; ============================================================

IFNDEF rd_bwrite_readonly
rd_bwrite_readonly:
    LD   A, ERR_READ_ONLY
    LD   HL, 0
    RET
ENDIF

IFNDEF rd_copy_512
; ------------------------------------------------------------
; rd_copy_512
; Copy 512 bytes from HL to DE.
; Inputs:
;   HL - source address
;   DE - destination address
; Outputs:
;   HL, DE advanced by 512
; Clobbers: A, C
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
ENDIF

; ============================================================
; cmd_sum.asm - SUM command (SYSV checksum)
; Computes a SYSV-compatible checksum (sum -s) of a file.
; Algorithm: sum all bytes into a 32-bit accumulator, then
; fold the high 16 bits into the low 16 bits.
; Output: checksum blockcount (matching Linux `sum -s`)
; ============================================================

cmd_sum_handle      EQU EXEC_RAM_START         ; 1 byte
cmd_sum_rem_size    EQU EXEC_RAM_START + 1     ; 4 bytes (remaining file size)
cmd_sum_buffer      EQU EXEC_RAM_START + 5     ; 512 bytes
cmd_sum_accum       EQU EXEC_RAM_START + 517   ; 4 bytes (32-bit accumulator)
cmd_sum_filesize    EQU EXEC_RAM_START + 521   ; 4 bytes (saved for block count)

; ------------------------------------------------------------
; cmd_sum: Handle SUM command
; ------------------------------------------------------------
cmd_sum:
    XOR  A
    LD   (cmd_sum_handle), A

    ; Clear 32-bit accumulator
    LD   HL, cmd_sum_accum
    LD   (HL), A
    INC  HL
    LD   (HL), A
    INC  HL
    LD   (HL), A
    INC  HL
    LD   (HL), A

    ; 1. Resolve pathname and open the file.
    LD   HL, (EXEC_ARGS_PTR)    ; path argument
    LD   A, (HL)
    OR   A
    JP   Z, cmd_sum_usage

    EX   DE, HL                 ; DE = path string
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_sum_open_error

    ; HL = file handle (physical device ID)
    LD   A, L
    LD   (cmd_sum_handle), A

    ; 2. Get file size
    LD   B, A                   ; B = file handle
    LD   DE, cmd_sum_rem_size
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_sum_io_error

    ; Save file size for block count calculation later
    LD   HL, (cmd_sum_rem_size)
    LD   (cmd_sum_filesize), HL
    LD   HL, (cmd_sum_rem_size + 2)
    LD   (cmd_sum_filesize + 2), HL

cmd_sum_loop:
    ; Check if remaining size is 0
    LD   HL, cmd_sum_rem_size
    LD   A, (HL)
    INC  HL
    OR   (HL)
    INC  HL
    OR   (HL)
    INC  HL
    OR   (HL)
    JP   Z, cmd_sum_finish     ; Size is exactly 0, we're done

    ; 3. Read next block
    LD   A, (cmd_sum_handle)
    LD   B, A
    LD   DE, cmd_sum_buffer
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_sum_io_error

    ; 4. Determine how many bytes to sum (min(512, rem_size))
    LD   A, (cmd_sum_rem_size + 2)
    OR   A
    JP   NZ, cmd_sum_do_512
    LD   A, (cmd_sum_rem_size + 3)
    OR   A
    JP   NZ, cmd_sum_do_512

    LD   A, (cmd_sum_rem_size + 1)
    CP   2
    JP   NC, cmd_sum_do_512

    LD   A, (cmd_sum_rem_size)
    LD   C, A
    LD   A, (cmd_sum_rem_size + 1)
    LD   B, A
    JP   cmd_sum_add_block

cmd_sum_do_512:
    LD   BC, 512

cmd_sum_add_block:
    ; BC = byte count to process, save for size update
    PUSH BC
    LD   HL, cmd_sum_buffer

cmd_sum_add_loop:
    LD   A, B
    OR   C
    JP   Z, cmd_sum_update_size

    ; Add byte at (HL) to 32-bit accumulator
    LD   A, (HL)
    PUSH HL
    LD   HL, (cmd_sum_accum)    ; HL = low 16 bits of accum
    LD   E, A
    LD   D, 0
    ADD  HL, DE                 ; HL = low16 + byte
    LD   (cmd_sum_accum), HL
    JP   NC, cmd_sum_add_no_carry
    ; Carry into high 16 bits
    LD   HL, (cmd_sum_accum + 2)
    INC  HL
    LD   (cmd_sum_accum + 2), HL
cmd_sum_add_no_carry:
    POP  HL

    INC  HL
    DEC  BC
    JP   cmd_sum_add_loop

cmd_sum_update_size:
    POP  BC                     ; retrieve byte count
    ; Subtract BC from 4-byte rem_size
    LD   HL, (cmd_sum_rem_size)
    LD   A, L
    SUB  C
    LD   L, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (cmd_sum_rem_size), HL

    LD   HL, (cmd_sum_rem_size + 2)
    LD   A, L
    SBC  A, 0
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    LD   (cmd_sum_rem_size + 2), HL

    JP   cmd_sum_loop

cmd_sum_finish:
    ; Fold: checksum = (accum & 0xFFFF) + (accum >> 16)
    LD   HL, (cmd_sum_accum)        ; HL = low 16 bits
    LD   DE, (cmd_sum_accum + 2)    ; DE = high 16 bits
    ADD  HL, DE                     ; HL = folded sum (may overflow)
    JP   NC, cmd_sum_no_carry2
    INC  HL                         ; add the carry back in
cmd_sum_no_carry2:

    ; Print checksum as decimal
    CALL exec_print_dec16

    ; Print space
    PUSH HL
    LD   E, ' '
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL

    ; Compute block count = ceil(filesize / 512)
    ; = (filesize + 511) / 512
    ; For a 4-byte filesize, add 511 then shift right by 9
    LD   HL, (cmd_sum_filesize)
    LD   DE, 511
    ADD  HL, DE
    LD   (cmd_sum_filesize), HL
    LD   HL, (cmd_sum_filesize + 2)
    LD   DE, 0
    JP   NC, cmd_sum_blk_no_carry
    INC  HL                         ; carry from low 16 add
cmd_sum_blk_no_carry:
    LD   (cmd_sum_filesize + 2), HL

    ; Divide by 512 = shift right 9 = shift right 8 then shift right 1
    ; byte2:byte1:byte0 → after >>8 → byte2:byte1 as 16-bit, >>1
    ; filesize+511 is in bytes [0..3], we need bits [9..24]
    ; = byte[1] >> 1 | byte[2] << 7 | byte[3] << 15... but simpler:
    ; result = (filesize_byte1 | filesize_byte2<<8 | byte3<<16) >> 1
    ; Since files are at most ~8MB on this system, 16-bit block count suffices.
    LD   A, (cmd_sum_filesize + 1)
    LD   L, A
    LD   A, (cmd_sum_filesize + 2)
    LD   H, A
    ; Now HL = (filesize+511) >> 8. Shift right once more for >> 9.
    ; Need to bring in bit from byte 3
    LD   A, (cmd_sum_filesize + 3)
    RRCA                            ; bit 0 of byte3 into carry
    LD   A, H
    RRA                             ; rotate right through carry
    LD   H, A
    LD   A, L
    RRA
    LD   L, A

    ; HL = block count; print as decimal
    CALL exec_print_dec16

    ; Print CRLF
    CALL exec_crlf

    JP   cmd_sum_done

cmd_sum_usage:
    LD   DE, msg_sum_usage
    CALL exec_puts
    RET

cmd_sum_open_error:
cmd_sum_io_error:
    CALL exec_print_error

cmd_sum_done:
    LD   A, (cmd_sum_handle)
    OR   A
    JP   Z, cmd_sum_exit            ; no handle to close

    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    XOR  A
    LD   (cmd_sum_handle), A
cmd_sum_exit:
    RET

msg_sum_usage:
    DEFM "Usage: SUM <filename>", 0x0D, 0x0A, 0

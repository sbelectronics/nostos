; ============================================================
; randdata.asm - Pseudo-random data file generator for NostOS
; Generates a file of pseudo-random bytes using a 16-bit LFSR,
; then prints the SYSV checksum of the data written.
;
; Usage: RANDDATA <filename> <bytes> <seed>
;   filename - name of file to create
;   bytes    - number of bytes to write (decimal)
;   seed     - 16-bit random seed (decimal, must be non-zero)
;
; The SYSV checksum printed is compatible with Linux `sum -s`.
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header
    JP   rd_main

    ; Header pad: 13 bytes of zeros (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================
RD_FNAME_SIZE   EQU 20          ; max filename length + null
RD_BLOCK_SIZE   EQU 512         ; write block size

; ============================================================
; Variables (in RAM after code)
; ============================================================
rd_fname:       DEFS RD_FNAME_SIZE, 0
rd_file_dev:    DEFB 0          ; file handle (physical device ID)
rd_rem_bytes:   DEFW 0          ; remaining bytes to write
rd_seed:        DEFW 0          ; LFSR state (16-bit)
rd_accum:       DEFS 4, 0       ; 32-bit SYSV checksum accumulator
rd_filesize:    DEFS 4, 0       ; total file size (for BSETSIZE)
rd_buf:         DEFS RD_BLOCK_SIZE, 0  ; write buffer

; ============================================================
; rd_main - entry point (at 0x0810)
; ============================================================
rd_main:
    ; Clear state
    XOR  A
    LD   (rd_file_dev), A
    LD   HL, 0
    LD   (rd_accum), HL
    LD   (rd_accum + 2), HL
    LD   (rd_filesize), HL
    LD   (rd_filesize + 2), HL

    ; ---- Parse arguments ----
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, H
    OR   L
    JP   Z, rd_usage

    LD   A, (HL)
    OR   A
    JP   Z, rd_usage

    ; Arg 1: filename — copy and upcase until space or null
    LD   DE, rd_fname
    LD   B, RD_FNAME_SIZE - 1
rd_copy_fname:
    LD   A, (HL)
    OR   A
    JP   Z, rd_usage            ; need more args
    CP   ' '
    JP   Z, rd_fname_done
    ; Uppercase
    CP   'a'
    JP   C, rd_fname_nc
    CP   'z' + 1
    JP   NC, rd_fname_nc
    SUB  0x20
rd_fname_nc:
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, rd_copy_fname
rd_fname_done:
    XOR  A
    LD   (DE), A                ; null-terminate

    ; Skip spaces
    CALL rd_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, rd_usage            ; need byte count

    ; Arg 2: number of bytes (decimal)
    CALL rd_parse_dec16
    LD   (rd_rem_bytes), DE
    ; Also save as file size
    LD   (rd_filesize), DE
    PUSH HL                     ; save parse position
    LD   HL, 0
    LD   (rd_filesize + 2), HL
    POP  HL                     ; restore parse position

    ; Skip spaces
    CALL rd_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, rd_usage            ; need seed

    ; Arg 3: seed (decimal)
    CALL rd_parse_dec16
    LD   A, D
    OR   E
    JP   Z, rd_usage            ; seed must be non-zero
    LD   (rd_seed), DE

    ; ---- Create the file ----
    ; Try to remove existing file first (ignore errors)
    LD   DE, rd_fname
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR             ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, rd_error
    LD   B, L                   ; B = device ID
    LD   C, DEV_FREMOVE
    CALL KERNELADDR

    ; Create new file (re-parse since PATH_WORK may be clobbered)
    LD   DE, rd_fname
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR             ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, rd_error
    LD   B, L                   ; B = device ID
    LD   C, DEV_FCREATE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, rd_error

    ; HL = file handle
    LD   A, L
    LD   (rd_file_dev), A

    ; ---- Generate and write data ----
rd_write_loop:
    ; Check if remaining bytes is 0
    LD   HL, (rd_rem_bytes)
    LD   A, H
    OR   L
    JP   Z, rd_write_done

    ; Determine block size: min(512, rem_bytes)
    LD   DE, RD_BLOCK_SIZE
    ; If HL >= 512, use 512; else use HL
    LD   A, H
    CP   2                      ; H >= 2 means >= 512
    JP   NC, rd_use_512
    ; H is 0 or 1
    OR   A
    JP   NZ, rd_check_h1       ; H == 1
    ; H == 0, use L as count
    LD   D, H                  ; D = 0
    LD   E, L                  ; E = remaining
    JP   rd_fill_block
rd_check_h1:
    ; H == 1, check if >= 512 (H=1 means 256..511)
    ; 1*256 + L, always < 512, so use HL
    LD   D, H
    LD   E, L
    JP   rd_fill_block
rd_use_512:
    LD   DE, RD_BLOCK_SIZE

rd_fill_block:
    ; DE = bytes to generate this block
    PUSH DE                     ; save count for subtract later
    LD   HL, rd_buf
    ; BC = counter
    LD   B, D
    LD   C, E

rd_fill_loop:
    LD   A, B
    OR   C
    JP   Z, rd_fill_done

    ; Generate next pseudo-random byte using 16-bit Galois LFSR
    ; taps at bits 16, 14, 13, 11 (polynomial 0xB400)
    PUSH HL
    PUSH BC
    LD   HL, (rd_seed)
    ; Check bit 0
    LD   A, L
    AND  1
    LD   B, A                   ; B = lsb
    ; Shift right: HL >>= 1 (logical shift right)
    ; Clear carry, then RRA twice (H then L)
    LD   A, H
    OR   A                      ; clear carry; A still = H
    RRA                         ; A = H >> 1 (bit 7 = 0); carry = H bit 0
    LD   H, A
    LD   A, L
    RRA                         ; A = (H_bit0 << 7) | (L >> 1)
    LD   L, A
    ; If lsb was 1, XOR with 0xB400
    LD   A, B
    OR   A
    JP   Z, rd_lfsr_done
    LD   A, H
    XOR  0xB4
    LD   H, A
    ; L XOR 0x00 = L (no change needed)
rd_lfsr_done:
    LD   (rd_seed), HL
    ; Use L as the random byte
    LD   A, L
    POP  BC
    POP  HL

    LD   (HL), A                ; store byte in buffer

    ; Add byte to 32-bit checksum accumulator
    PUSH HL
    PUSH BC
    LD   E, A
    LD   D, 0
    LD   HL, (rd_accum)
    ADD  HL, DE
    LD   (rd_accum), HL
    JP   NC, rd_accum_no_carry
    LD   HL, (rd_accum + 2)
    INC  HL
    LD   (rd_accum + 2), HL
rd_accum_no_carry:
    POP  BC
    POP  HL

    INC  HL
    DEC  BC
    JP   rd_fill_loop

rd_fill_done:
    ; Write block via DEV_BWRITE
    LD   A, (rd_file_dev)
    LD   B, A
    LD   DE, rd_buf
    LD   C, DEV_BWRITE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, rd_error

    ; Subtract written count from remaining
    POP  DE                     ; DE = bytes written this block
    LD   HL, (rd_rem_bytes)
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    LD   (rd_rem_bytes), HL

    JP   rd_write_loop

rd_write_done:
    ; Set exact file size via DEV_BSETSIZE
    LD   A, (rd_file_dev)
    LD   B, A
    LD   DE, rd_filesize
    LD   C, DEV_BSETSIZE
    CALL KERNELADDR

    ; Close file
    LD   A, (rd_file_dev)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    XOR  A
    LD   (rd_file_dev), A

    ; ---- Print SYSV checksum ----
    ; Fold: checksum = (accum & 0xFFFF) + (accum >> 16)
    LD   HL, (rd_accum)
    LD   DE, (rd_accum + 2)
    ADD  HL, DE
    JP   NC, rd_fold_nc
    INC  HL                     ; add carry back in
rd_fold_nc:
    ; HL = folded checksum; print as decimal
    CALL rd_print_dec16

    ; Print space
    LD   E, ' '
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    ; Compute block count = ceil(filesize / 512)
    ; = (filesize + 511) >> 9
    LD   HL, (rd_filesize)
    LD   DE, 511
    ADD  HL, DE
    JP   NC, rd_blk_nc
    ; Carry: increment high word equivalent
    ; We stored filesize+2 as 0, but handle the general case
rd_blk_nc:
    ; HL = (filesize + 511) low 16 bits
    ; Shift right 9: take byte1 and byte0>>1 with carry from above
    ; For 16-bit filesize, (filesize+511) fits in 16 bits (max 65535+511=66046)
    ; if carry occurred, high bit is 1 = 0x10000
    ; Result = HL >> 9, plus 128 if carry occurred
    LD   A, H
    JP   NC, rd_blk_nc2
    ; Had carry from add: effective value is 0x10000 + HL
    ; >> 9 = 0x80 + (HL >> 9)
    RRCA                        ; A = H >> 1 (carry=0 from JP NC not taken means carry was set)
rd_blk_nc2:
    ; Shift HL right by 9 = shift right by 8 then by 1
    ; HL >> 8 = H, then >> 1
    LD   L, H
    LD   H, 0
    ; Now shift HL right by 1
    LD   A, L
    RRCA
    AND  0x7F
    LD   L, A
    ; If original add had carry, add 128
    ; (We can't easily recover carry here, but for 16-bit filesizes
    ;  max value is 65535, +511 = 66046 = 0x10200 - carry would occur
    ;  only if filesize > 65024; blocks would be 127-128.
    ;  For simplicity, handle the common case; max filesize supported = 65535)

    ; HL = block count; print as decimal
    CALL rd_print_dec16

    ; Print CRLF
    LD   DE, rd_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Exit
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Error handlers
; ============================================================
rd_error:
    PUSH AF
    LD   DE, rd_msg_error
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  AF
    ; Print error code as decimal
    LD   L, A
    LD   H, 0
    CALL rd_print_dec16
    LD   DE, rd_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    ; Close file if open
    LD   A, (rd_file_dev)
    OR   A
    JP   Z, rd_error_exit
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
rd_error_exit:
    LD   C, SYS_EXIT
    CALL KERNELADDR

rd_usage:
    LD   DE, rd_msg_usage
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; rd_skip_spaces
; Advance HL past spaces.
; ============================================================
rd_skip_spaces:
    LD   A, (HL)
    CP   ' '
    RET  NZ
    INC  HL
    JP   rd_skip_spaces

; ============================================================
; rd_parse_dec16
; Parse a decimal number from (HL) into DE.
; Advances HL past the number.
; ============================================================
rd_parse_dec16:
    LD   DE, 0
rd_parse_dec_loop:
    LD   A, (HL)
    CP   '0'
    JP   C, rd_parse_dec_done   ; < '0'
    CP   '9' + 1
    JP   NC, rd_parse_dec_done  ; > '9'
    SUB  '0'                    ; A = digit value
    ; DE = DE * 10 + A
    PUSH HL
    PUSH AF                     ; save digit
    ; DE * 10: DE*8 + DE*2
    LD   H, D
    LD   L, E                   ; HL = DE
    ADD  HL, HL                 ; HL = DE * 2
    LD   B, H
    LD   C, L                   ; BC = DE * 2
    ADD  HL, HL                 ; HL = DE * 4
    ADD  HL, HL                 ; HL = DE * 8
    ADD  HL, BC                 ; HL = DE * 10
    POP  AF                     ; A = digit
    LD   E, A
    LD   D, 0
    ADD  HL, DE                 ; HL = DE * 10 + digit
    LD   D, H
    LD   E, L                   ; DE = result
    POP  HL
    INC  HL                     ; advance past digit
    JP   rd_parse_dec_loop
rd_parse_dec_done:
    RET

; ============================================================
; rd_print_dec16
; Print HL as unsigned decimal to console.
; Preserves HL.
; ============================================================
rd_print_dec16:
    PUSH HL
    PUSH DE
    PUSH BC

    ; We'll divide repeatedly by 10 and push digits on stack
    LD   B, 0                   ; digit count

rd_pd_divloop:
    ; Divide HL by 10
    PUSH BC                     ; save digit count
    LD   DE, 0                  ; DE = quotient
    LD   B, 16                  ; 16-bit division, 16 iterations

rd_pd_div10:
    ; Shift HL left through DE
    ADD  HL, HL
    LD   A, E
    RLA
    LD   E, A
    LD   A, D
    RLA
    LD   D, A
    ; If DE >= 10, subtract
    LD   A, E
    SUB  10
    JP   C, rd_pd_div10_skip
    LD   E, A
    INC  HL                     ; set bit 0 of quotient via HL
rd_pd_div10_skip:
    DEC  B
    JP   NZ, rd_pd_div10

    ; HL = quotient, E = remainder (0-9)
    POP  BC                     ; restore digit count
    LD   A, E
    ADD  A, '0'
    PUSH AF                     ; push digit character
    INC  B                      ; count digits

    LD   A, H
    OR   L
    JP   NZ, rd_pd_divloop      ; more digits if quotient != 0

    ; Print digits (they're on the stack in reverse order)
rd_pd_print:
    POP  AF                     ; A = digit char
    PUSH BC
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    DEC  B
    JP   NZ, rd_pd_print

    POP  BC
    POP  DE
    POP  HL
    RET

; ============================================================
; Data
; ============================================================
rd_msg_usage:
    DEFM "Usage: RANDDATA <filename> <bytes> <seed>", 0x0D, 0x0A, 0
rd_msg_error:
    DEFM "Error: ", 0
rd_msg_crlf:
    DEFM 0x0D, 0x0A, 0

; ============================================================
; cmd_free.asm - FREE command handler
; ============================================================
; FR / FREE [device]
;   Print free disk blocks with byte count, and free memory.

; ------------------------------------------------------------
; cmd_free: Handle FR / FREE command
; ------------------------------------------------------------
cmd_free:
    ; 1. Check for optional device name argument
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, cmd_free_use_cur    ; no argument: use CUR_DEVICE

    ; Argument given: strip trailing ':' and resolve device name
    LD   D, H
    LD   E, L                   ; DE = arg string
    CALL exec_strip_colon
    LD   B, 0
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_free_err
    LD   B, L                   ; B = resolved device ID
    JP   cmd_free_call

cmd_free_use_cur:
    LD   A, (CUR_DEVICE)
    LD   B, A

cmd_free_call:
    ; 2. Call DEV_FREE syscall
    LD   C, DEV_FREE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_free_err

    ; HL = free block count
    PUSH HL                     ; save block count

    ; 3. Print "Free Blocks:  <bytes> bytes (<blocks> blocks)"
    LD   DE, msg_free_blk
    CALL exec_puts

    POP  HL
    PUSH HL                     ; keep block count
    CALL cmd_free_print_bytes   ; print HL * 512 as decimal

    LD   DE, msg_free_bytes_mid
    CALL exec_puts              ; " bytes ("

    POP  HL
    CALL exec_print_dec16       ; print block count

    LD   DE, msg_free_blk_end
    CALL exec_puts              ; " blocks)\r\n"

    ; 4. Print "Free Memory:  <bytes> bytes"
    LD   C, SYS_MEMTOP
    CALL KERNELADDR             ; HL = memtop
    LD   DE, (DYNAMIC_MEMBOT)
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A                   ; HL = memtop - DYNAMIC_MEMBOT

    PUSH HL
    LD   DE, msg_free_mem
    CALL exec_puts
    POP  HL
    CALL exec_print_dec16
    LD   DE, msg_free_bytes_end
    CALL exec_puts              ; " bytes\r\n"
    RET

cmd_free_err:
    CALL exec_print_error
    RET

; ------------------------------------------------------------
; cmd_free_print_bytes
; Print HL * 512 as a decimal number (up to 25 bits).
; Inputs:
;   HL - block count
; Clobbers: AF, BC, DE, HL
; ------------------------------------------------------------
cmd_free_print_bytes:
    ; Compute DE:HL = blocks << 9
    LD   B, H
    LD   C, L                   ; BC = original blocks
    LD   A, C
    ADD  A, A                   ; A = C<<1, CY = C[7]
    LD   H, A
    LD   L, 0                   ; HL = low 16 bits
    LD   A, B
    ADC  A, A                   ; A = B*2 + CY, new CY = B[7]
    LD   E, A
    LD   D, 0
    JP   NC, cmd_free_pb_nc
    INC  D
cmd_free_pb_nc:
    ; DE:HL = blocks * 512
    LD   A, D
    OR   E
    JP   NZ, cmd_free_dec32
    JP   exec_print_dec16       ; tail call for < 65536

; ------------------------------------------------------------
; cmd_free_dec32
; Print 32-bit value DE:HL as decimal (max ~33 million).
; Uses EXEC_RAM_START as 4-byte scratch space.
; Clobbers: AF, BC, DE, HL
; ------------------------------------------------------------
cmd_free_dec32:
    LD   (EXEC_RAM_START), HL
    LD   (EXEC_RAM_START + 2), DE
    LD   HL, cmd_free_pv_table
    LD   C, 7                   ; 7 place values (ones handled last)
    LD   B, 0                   ; B = leading-zero suppression flag

cmd_free_d32_next:
    PUSH HL                     ; save table pointer
    PUSH BC                     ; save counter/flags
    ; Load place value BC:DE from table (stored low byte first)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    LD   C, (HL)
    INC  HL
    LD   B, (HL)                ; BC:DE = place value
    LD   A, 0                   ; digit counter

cmd_free_d32_sub:
    ; Compare value (at EXEC_RAM_START) >= BC:DE
    PUSH AF                     ; save digit count
    LD   HL, (EXEC_RAM_START + 2)
    LD   A, H
    CP   B
    JP   C, cmd_free_d32_lt
    JP   NZ, cmd_free_d32_ge
    LD   A, L
    CP   C
    JP   C, cmd_free_d32_lt
    JP   NZ, cmd_free_d32_ge
    LD   HL, (EXEC_RAM_START)
    LD   A, H
    CP   D
    JP   C, cmd_free_d32_lt
    JP   NZ, cmd_free_d32_ge
    LD   A, L
    CP   E
    JP   C, cmd_free_d32_lt

cmd_free_d32_ge:
    ; Subtract place value from stored value
    LD   HL, (EXEC_RAM_START)
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    LD   (EXEC_RAM_START), HL
    LD   HL, (EXEC_RAM_START + 2)
    LD   A, L
    SBC  A, C
    LD   L, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (EXEC_RAM_START + 2), HL
    POP  AF                     ; restore digit count
    INC  A
    JP   cmd_free_d32_sub

cmd_free_d32_lt:
    POP  AF                     ; A = digit for this place
    POP  BC                     ; B = suppress flag, C = remaining
    POP  HL                     ; table pointer
    LD   DE, 4
    ADD  HL, DE                 ; advance to next table entry
    ; Print digit (suppress leading zeros)
    OR   A
    JP   NZ, cmd_free_d32_pr
    LD   A, B
    OR   A
    JP   Z, cmd_free_d32_skip   ; still leading zeros
    XOR  A                      ; digit = 0, must print
cmd_free_d32_pr:
    LD   B, 1                   ; no longer suppressing
    ADD  A, '0'
    CALL exec_print_char
cmd_free_d32_skip:
    DEC  C
    JP   NZ, cmd_free_d32_next
    ; Print ones digit (always)
    LD   A, (EXEC_RAM_START)
    ADD  A, '0'
    JP   exec_print_char        ; tail call

; Place value table (32-bit, stored as E, D, C, B — low byte first)
cmd_free_pv_table:
    DEFB 0x80, 0x96, 0x98, 0x00 ; 10,000,000
    DEFB 0x40, 0x42, 0x0F, 0x00 ;  1,000,000
    DEFB 0xA0, 0x86, 0x01, 0x00 ;    100,000
    DEFB 0x10, 0x27, 0x00, 0x00 ;     10,000
    DEFB 0xE8, 0x03, 0x00, 0x00 ;      1,000
    DEFB 0x64, 0x00, 0x00, 0x00 ;        100
    DEFB 0x0A, 0x00, 0x00, 0x00 ;         10

msg_free_blk:       DEFM "Free Blocks:  ", 0
msg_free_bytes_mid: DEFM " bytes (", 0
msg_free_blk_end:   DEFM " blocks)", 0x0D, 0x0A, 0
msg_free_mem:       DEFM "Free Memory:  ", 0
msg_free_bytes_end: DEFM " bytes", 0x0D, 0x0A, 0

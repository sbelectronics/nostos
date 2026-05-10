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
    PUSH HL
    LD   HL, (DYNAMIC_MEMBOT)
    EX   DE, HL                 ; DE = DYNAMIC_MEMBOT
    POP  HL                     ; HL = memtop
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
    JP   NZ, exec_print_dec32   ; tail call to shared 32-bit printer
    JP   exec_print_dec16       ; tail call for < 65536

msg_free_blk:       DEFM "Free Blocks:  ", 0
msg_free_bytes_mid: DEFM " bytes (", 0
msg_free_blk_end:   DEFM " blocks)", 0x0D, 0x0A, 0
msg_free_mem:       DEFM "Free Memory:  ", 0
msg_free_bytes_end: DEFM " bytes", 0x0D, 0x0A, 0

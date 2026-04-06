; ============================================================
; cmd_lf.asm - LF / TYPE command
; ============================================================

cmd_lf_handle       EQU EXEC_RAM_START         ; 1 byte
cmd_lf_rem_size     EQU EXEC_RAM_START + 1     ; 4 bytes
cmd_lf_buffer       EQU EXEC_RAM_START + 5     ; 512 bytes

; ------------------------------------------------------------
; cmd_lf: Handle LF / TYPE command
; ------------------------------------------------------------
cmd_lf:
    XOR  A
    LD   (cmd_lf_handle), A

    ; 1. Resolve pathname and open the file.
    LD   HL, (EXEC_ARGS_PTR)    ; path argument
    LD   A, (HL)
    OR   A
    JP   Z, cmd_lf_usage

    EX   DE, HL                 ; DE = path string
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_lf_open_error

    ; HL = file handle (physical device ID)
    LD   A, L
    LD   (cmd_lf_handle), A


    ; 2. Get file size
    LD   B, A                   ; B = file handle
    LD   DE, cmd_lf_rem_size
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_lf_io_error


cmd_lf_loop:
    ; Check if remaining size is 0
    LD   HL, cmd_lf_rem_size
    LD   A, (HL)
    INC  HL
    OR   (HL)
    INC  HL
    OR   (HL)
    INC  HL
    OR   (HL)
    JP   Z, cmd_lf_done         ; Size is exactly 0, we're done

    ; 3. Read next block
    LD   A, (cmd_lf_handle)
    LD   B, A
    LD   DE, cmd_lf_buffer
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_lf_io_error

    ; 4. Determine how many bytes to print (min(512, rem_size))
    LD   A, (cmd_lf_rem_size + 2)
    OR   A
    JP   NZ, cmd_lf_print_512
    LD   A, (cmd_lf_rem_size + 3)
    OR   A
    JP   NZ, cmd_lf_print_512
    
    LD   A, (cmd_lf_rem_size + 1)
    CP   2
    JP   NC, cmd_lf_print_512
    
    LD   A, (cmd_lf_rem_size)
    LD   C, A
    LD   A, (cmd_lf_rem_size + 1)
    LD   B, A
    JP   cmd_lf_print_block

cmd_lf_print_512:
    LD   BC, 512

cmd_lf_print_block:
    PUSH BC                     ; save count
    LD   HL, cmd_lf_buffer
cmd_lf_print_loop:
    LD   A, B
    OR   C
    JP   Z, cmd_lf_update_size
    
    LD   A, (HL)
    PUSH BC
    PUSH HL
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  BC
    
    INC  HL
    DEC  BC
    JP   cmd_lf_print_loop

cmd_lf_update_size:
    POP  BC                     ; retrieve printed count
    LD   HL, (cmd_lf_rem_size)
    LD   A, L
    SUB  C
    LD   L, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (cmd_lf_rem_size), HL
    
    LD   HL, (cmd_lf_rem_size + 2)
    LD   A, L
    SBC  A, 0
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    LD   (cmd_lf_rem_size + 2), HL
    
    JP   cmd_lf_loop

cmd_lf_usage:
    LD   DE, msg_lf_usage
    CALL exec_puts
    RET

cmd_lf_open_error:
cmd_lf_io_error:
    CALL exec_print_error
    
cmd_lf_done:
    LD   A, (cmd_lf_handle)
    OR   A
    JP   Z, cmd_lf_exit             ; no handle to close

    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    XOR  A
    LD   (cmd_lf_handle), A
cmd_lf_exit:
    RET

msg_lf_usage:
    DEFM "Usage: TYPE <filename>", 0x0D, 0x0A, 0

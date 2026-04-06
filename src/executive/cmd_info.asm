EXEC_INFO_BUFFER    EQU     EXEC_RAM_START  ; for getting SYS_INFO

; ============================================================
; cmd_info.asm - INFO command handler
; ============================================================
; INFO: display system information
cmd_info:
    ; Get system information into EXEC_INFO_BUFFER
    LD   DE, EXEC_INFO_BUFFER
    LD   C, SYS_INFO
    CALL KERNELADDR

    ; Print "NostOs v"
    LD   DE, msg_nostos_v
    CALL exec_puts

    ; Print Major.Minor.Patch
    LD   A, (EXEC_INFO_BUFFER + 0)
    CALL exec_print_dec8
    LD   DE, msg_dot
    CALL exec_puts
    
    LD   A, (EXEC_INFO_BUFFER + 1)
    CALL exec_print_dec8
    LD   DE, msg_dot
    CALL exec_puts
    
    LD   A, (EXEC_INFO_BUFFER + 2)
    CALL exec_print_dec8
    
    ; Print " built on "
    LD   DE, msg_built_on
    CALL exec_puts
    
    ; Print YYYY
    LD   HL, (EXEC_INFO_BUFFER + 3)
    CALL exec_print_dec16
    LD   DE, msg_dash
    CALL exec_puts
    
    ; Print MM
    LD   A, (EXEC_INFO_BUFFER + 5)
    CALL exec_print_dec8_pad2
    LD   DE, msg_dash
    CALL exec_puts
    
    ; Print DD
    LD   A, (EXEC_INFO_BUFFER + 6)
    CALL exec_print_dec8_pad2
    
    ; Print CRLF
    CALL exec_crlf
    RET

msg_nostos_v:
    DEFM "NostOs v", 0
msg_built_on:
    DEFM " built on ", 0
msg_dot:
    DEFM ".", 0
msg_dash:
    DEFM "-", 0

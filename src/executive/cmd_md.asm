; ============================================================
; cmd_md.asm - MD / MKDIR command handler
; ============================================================
; MD [device:][path/]dirname
;   Create a directory. Supports optional device prefix and multi-component
;   paths (e.g. MD MYDIR/SUB1). The name is uppercased in-place before
;   being passed to the kernel.
cmd_md:
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    CP   0
    JP   Z, cmd_md_no_arg
    CALL exec_upcase_delimit    ; upcase name in INPUT_BUFFER in-place (HL clobbered)
    LD   DE, (EXEC_ARGS_PTR)
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR             ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, cmd_md_error
    LD   B, L                   ; B = device ID for DEV_DCREATE
    LD   C, DEV_DCREATE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_md_error
    ; Close the directory handle returned by DEV_DCREATE (L = open handle ID)
    LD   B, L
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    RET
cmd_md_no_arg:
    LD   DE, msg_md_usage
    CALL exec_puts
    RET
cmd_md_error:
    CALL exec_print_error
    RET

msg_md_usage:   DEFM "Usage: MD [device:][path/]dirname", 0x0D, 0x0A, 0

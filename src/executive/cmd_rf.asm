; ============================================================
; cmd_rf.asm - RF / DELETE command handler
; ============================================================
; RF [device:][dir/]filename
;   Remove (delete) a file. Supports optional device prefix and path.
; Inputs:
;   (EXEC_ARGS_PTR) - pointer to argument string
; Outputs:
;   A - ERR_SUCCESS or error code
; ------------------------------------------------------------
cmd_rf:
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    CP   0
    JP   Z, cmd_rf_no_arg
    CALL exec_upcase_delimit
    ; Try to open as a directory — if it succeeds, the target is a
    ; directory and RF should refuse to delete it.
    LD   DE, (EXEC_ARGS_PTR)
    LD   C, SYS_GLOBAL_OPENDIR
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   Z, cmd_rf_is_dir      ; opened as dir → not a file
    ; Open-as-dir failed — resolve device and path, then DEV_FREMOVE
    LD   DE, (EXEC_ARGS_PTR)
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR             ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, cmd_rf_error
    LD   B, L                   ; B = device ID for DEV_FREMOVE
    LD   C, DEV_FREMOVE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_rf_error
    RET
cmd_rf_is_dir:
    ; Close the directory handle we just opened
    LD   B, L                   ; L = handle ID from SYS_GLOBAL_OPENDIR
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   A, ERR_NOT_FILE
    JP   cmd_rf_error

cmd_rf_no_arg:
    LD   DE, msg_rf_usage
    CALL exec_puts
    RET

cmd_rf_error:
    CALL exec_print_error
    RET

msg_rf_usage:   DEFM "Usage: RF filename", 0x0D, 0x0A, 0

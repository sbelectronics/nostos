; ============================================================
; cmd_rd.asm - RD / RMDIR command handler
; ============================================================
; RD [device:]dirname
;   Remove an empty directory. Supports optional device prefix.
;   The name is uppercased in-place before being passed to the kernel.
cmd_rd:
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    CP   0
    JP   Z, cmd_rd_no_arg
    CALL exec_upcase_delimit    ; upcase name in INPUT_BUFFER in-place
    ; Try to open as a file — if it succeeds, the target is a file,
    ; not a directory, so refuse.
    LD   DE, (EXEC_ARGS_PTR)
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   Z, cmd_rd_is_file     ; opened as file → not a directory
    ; Open failed — target is either a directory or doesn't exist.
    ; Resolve device and path, then DEV_FREMOVE.
    LD   DE, (EXEC_ARGS_PTR)
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR             ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, cmd_rd_error
    LD   B, L                   ; B = device ID for DEV_FREMOVE
    LD   C, DEV_FREMOVE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_rd_error
    RET
cmd_rd_is_file:
    ; Close the file handle we just opened
    LD   B, L                   ; L = handle ID from SYS_GLOBAL_OPENFILE
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   A, ERR_NOT_DIR
    JP   cmd_rd_error
cmd_rd_no_arg:
    LD   DE, msg_rd_usage
    CALL exec_puts
    RET
cmd_rd_error:
    CALL exec_print_error
    RET

msg_rd_usage:   DEFM "Usage: RD dirname", 0x0D, 0x0A, 0

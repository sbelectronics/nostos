; ============================================================
; cmd_cd.asm - CD / CHDIR command handler
; ============================================================
; CD [path]
;   Resolve path, validate the directory exists, then update
;   CUR_DEVICE and CUR_DIR.  With no argument, changes to the
;   root of the current device.
cmd_cd:
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    CP   0
    JP   Z, cmd_cd_root
    EX   DE, HL                 ; DE = path string
    JP   cmd_cd_do
cmd_cd_root:
    LD   DE, msg_cd_root        ; default: root of current device
cmd_cd_do:
    LD   C, SYS_SET_CWD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cd_error
    RET
cmd_cd_error:
    CALL exec_print_error
    RET

msg_cd_root:
    DEFM "/", 0

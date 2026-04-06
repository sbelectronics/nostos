; ------------------------------------------------------------
; syscall_entry
; Entry point for all kernel syscalls via CALL KERNELADDR or RST 0x10.
; Inputs:
;   B  - device identifier (physical or logical)
;   C  - function number
;   DE - parameter
; Outputs:
;   A  - status (0 = ERR_SUCCESS, non-zero = error code)
;   HL - return value
; Note: all other registers are preserved by the handler.
; ------------------------------------------------------------
syscall_entry:
    ; Validate function number
    LD   A, C
    CP   SYSCALL_COUNT
    JP   NC, syscall_entry_invalid

    ; Index into dispatch table: HL = syscall_table + C*2
    ; Save BC so B (device ID) and DE (parameter) are both preserved for the handler.
    LD   HL, syscall_table
    PUSH BC                     ; save B (device ID) + C (fn#); restore before tail-call
    ADD  A, C                   ; A = C*2 (C < 31, no overflow; A still = C from above)
    LD   C, A
    LD   B, 0
    ADD  HL, BC                 ; HL = &syscall_table[C*2]
    POP  BC                     ; restore B (device ID), C (fn#), DE untouched

    ; Load handler address into HL (BC and DE now intact)
    LD   A, (HL)
    INC  HL
    LD   H, (HL)
    LD   L, A                   ; HL = handler address

    JP   (HL)                   ; tail-call to handler; handler does RET

syscall_entry_invalid:
    LD   A, ERR_INVALID_PARAM
    LD   HL, 0
    RET

; ------------------------------------------------------------
; Syscall Dispatch Table (45 entries)
; ------------------------------------------------------------
syscall_table:
    DEFW sys_exit               ; 0:  SYS_EXIT
    DEFW sys_info               ; 1:  SYS_INFO
    DEFW sys_get_cwd            ; 2:  SYS_GET_CWD
    DEFW sys_set_cwd            ; 3:  SYS_SET_CWD
    DEFW sys_get_cmdline        ; 4:  SYS_GET_CMDLINE
    DEFW sys_memtop             ; 5:  SYS_MEMTOP
    DEFW sys_dev_log_assign     ; 6:  DEV_LOG_ASSIGN
    DEFW sys_dev_log_get        ; 7:  DEV_LOG_GET
    DEFW sys_dev_log_lookup     ; 8:  DEV_LOG_LOOKUP
    DEFW sys_dev_phys_lookup    ; 9:  DEV_PHYS_LOOKUP
    DEFW sys_dev_init           ; 10: DEV_INIT
    DEFW un_error               ; 11: DEV_SHUTDOWN (stub)
    DEFW sys_dev_stat           ; 12: DEV_STAT
    DEFW sys_dev_cread_raw      ; 13: DEV_CREAD_RAW
    DEFW sys_dev_cread          ; 14: DEV_CREAD
    DEFW sys_dev_cwrite         ; 15: DEV_CWRITE
    DEFW sys_dev_cwrite_str     ; 16: DEV_CWRITE_STR
    DEFW sys_dev_cread_str      ; 17: DEV_CREAD_STR
    DEFW sys_dev_bread          ; 18: DEV_BREAD
    DEFW sys_dev_bwrite         ; 19: DEV_BWRITE
    DEFW sys_dev_bseek          ; 20: DEV_BSEEK
    DEFW sys_dev_bsetsize       ; 21: DEV_BSETSIZE
    DEFW sys_dev_fopen          ; 22: DEV_FOPEN
    DEFW sys_dev_close          ; 23: DEV_CLOSE
    DEFW sys_dev_fcreate        ; 24: DEV_FCREATE
    DEFW sys_dev_fremove        ; 25: DEV_FREMOVE
    DEFW sys_dev_frename        ; 26: DEV_FRENAME
    DEFW sys_dev_dcreate        ; 27: DEV_DCREATE
    DEFW sys_dev_dopen          ; 28: DEV_DOPEN
    DEFW un_error               ; 29: DIR_FIRST (stub)
    DEFW un_error               ; 30: DIR_NEXT (stub)
    DEFW sys_dev_phys_get       ; 31: DEV_PHYS_GET
    DEFW sys_dev_bgetpos        ; 32: DEV_BGETPOS
    DEFW sys_dev_bgetsize       ; 33: DEV_BGETSIZE
    DEFW sys_dev_mount          ; 34: DEV_MOUNT
    DEFW sys_dev_log_create     ; 35: DEV_LOG_CREATE
    DEFW sys_dev_lookup         ; 36: DEV_LOOKUP
    DEFW sys_dev_get_name       ; 37: DEV_GET_NAME
    DEFW sys_dev_copy           ; 38: DEV_COPY
    DEFW sys_global_openfile    ; 39: SYS_GLOBAL_OPENFILE
    DEFW sys_global_opendir     ; 40: SYS_GLOBAL_OPENDIR
    DEFW sys_exec               ; 41: SYS_EXEC
    DEFW sys_dev_free           ; 42: DEV_FREE
    DEFW sys_path_parse         ; 43: SYS_PATH_PARSE
    DEFW sys_set_membot         ; 44: SYS_SET_MEMBOT

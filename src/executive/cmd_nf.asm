; ============================================================
; cmd_nf.asm - NF / RENAME command handler
; ============================================================
; NF [device:][dir/]oldname newname
;   Rename a file or directory. Supports optional device prefix and path
;   on oldname.  Newname must be a bare name (same directory as oldname).
;
; State in EXEC_RAM_START (safe while no user program is loaded):
cmd_nf_params   EQU EXEC_RAM_START + 0    ; 4 bytes: {src ptr (2B), dst ptr (2B)}

; ------------------------------------------------------------
; cmd_nf: Handle NF / RENAME command
; ------------------------------------------------------------
cmd_nf:
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    CP   0
    JP   Z, cmd_nf_usage

    ; ---- Token 1: oldname — upcase + null-terminate; DE = src pointer ----
    LD   D, H
    LD   E, L                       ; DE = src pointer
    CALL exec_upcase_delimit        ; HL = char after src null
    CALL exec_skip_spaces           ; HL = newname start

    LD   A, (HL)
    CP   0
    JP   Z, cmd_nf_usage            ; no newname arg

    ; ---- Token 2: newname — save pointer, upcase + null-terminate ----
    PUSH HL                         ; [SP] = dst pointer
    CALL exec_upcase_delimit        ; null-terminate dst token
    POP  HL                         ; HL = dst pointer

    ; ---- Resolve device from oldname via SYS_PATH_PARSE ----
    ; src in DE (oldname), dst in HL (newname)
    PUSH HL                         ; save dst pointer
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR                 ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, cmd_nf_parse_err
    LD   B, L                       ; B = device ID for DEV_FRENAME

cmd_nf_build_params:
    ; ---- Build params buffer: {src_ptr (2B), dst_ptr (2B)} ----
    LD   HL, cmd_nf_params
    LD   (HL), E                    ; src ptr low
    INC  HL
    LD   (HL), D                    ; src ptr high
    INC  HL
    POP  DE                         ; DE = dst ptr
    LD   (HL), E                    ; dst ptr low
    INC  HL
    LD   (HL), D                    ; dst ptr high

    ; ---- Call DEV_FRENAME on resolved device ----
    LD   DE, cmd_nf_params
    LD   C, DEV_FRENAME
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_nf_error
    RET

cmd_nf_parse_err:
    POP  DE                         ; discard saved dst
    JP   cmd_nf_error

cmd_nf_usage:
    LD   DE, msg_nf_usage
    CALL exec_puts
    RET

cmd_nf_error:
    CALL exec_print_error
    RET

msg_nf_usage:   DEFM "Usage: NF oldname newname", 0x0D, 0x0A, 0

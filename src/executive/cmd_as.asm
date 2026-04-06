; ============================================================
; cmd_as.asm - ASSIGN command handler
; ============================================================
; AS / ASSIGN <logdev> <physdev>
;   logdev  - logical device name (e.g. CON, SER, PRN)
;   physdev - physical device name (e.g. ACIA, NUL)
;
; Tokens are uppercased in-place in INPUT_BUFFER.
;
; Register / stack protocol:
;   After token 1 is parsed, DE = logname ptr (upcase'd in INPUT_BUFFER).
;   Before calling DEV_LOG_LOOKUP, physname ptr is saved on the stack.
;   EX (SP), HL is used to swap physname ptr <-> logdev ID on the stack.
; ============================================================
cmd_as:
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, cmd_as_usage            ; no args at all

    ; --- Token 1: logname ---
    ; HL = logname start.  Preserve start in DE for the DEV_LOG_LOOKUP call.
    LD   D, H
    LD   E, L                       ; DE = logname start
    CALL exec_upcase_delimit        ; upcase+null-terminate; HL = next; DE preserved
    CALL exec_strip_colon           ; strip trailing ':' if present
    CALL exec_skip_spaces           ; HL = physname start or null

    LD   A, (HL)
    OR   A
    JP   Z, cmd_as_usage            ; missing physname (stack clean here)

    ; --- Token 2: physname ---
    ; Save physname ptr across the DEV_LOG_LOOKUP call.
    PUSH HL                         ; [SP] = physname ptr
    ; DE = logname ptr (still valid - DEV_LOG_LOOKUP takes DE)
    LD   B, 0
    LD   C, DEV_LOG_LOOKUP
    CALL KERNELADDR                 ; A = status, HL = logdev ID
    CP   ERR_SUCCESS
    JP   Z, cmd_as_got_logdev
    ; Not found: create a new logical device with this name.
    ; DE = logname ptr (preserved by DEV_LOG_LOOKUP)
    LD   B, 0
    LD   C, DEV_LOG_CREATE
    CALL KERNELADDR                 ; A = status, HL = new logdev ID
    CP   ERR_SUCCESS
    JP   NZ, cmd_as_bad_logdev_pop  ; error: pop physname ptr before returning
cmd_as_got_logdev:
    ; Swap: save logdev ID on stack, retrieve physname ptr into HL.
    EX   (SP), HL                   ; HL = physname ptr; [SP] = logdev ID

    ; Upcase physname.  Preserve start in DE for DEV_PHYS_LOOKUP.
    LD   D, H
    LD   E, L                       ; DE = physname start
    CALL exec_upcase_delimit        ; upcase+null-terminate; DE preserved
    CALL exec_strip_colon           ; strip trailing ':' if present

    ; DE = physname ptr (for DEV_PHYS_LOOKUP)
    LD   B, 0
    LD   C, DEV_PHYS_LOOKUP
    CALL KERNELADDR                 ; A = status, HL = physdev id
    CP   ERR_SUCCESS
    JP   NZ, cmd_as_bad_physdev_pop ; error: pop logdev ID before returning

    ; --- Perform assignment ---
    ; HL = physdev id; [SP] = logdev ID
    LD   E, L                       ; E = physical device ID
    POP  BC                         ; C = logdev ID (B = 0 from above)
    LD   B, C                       ; B = logdev ID
    LD   C, DEV_LOG_ASSIGN
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_as_assign_error

    LD   DE, msg_as_ok
    CALL exec_puts
    RET

cmd_as_bad_logdev_pop:
    POP  HL                         ; discard physname ptr (clean stack)
    LD   DE, msg_as_bad_logdev
    CALL exec_puts
    RET

cmd_as_bad_physdev_pop:
    POP  HL                         ; discard logdev ID (clean stack)
    LD   DE, msg_as_bad_physdev
    CALL exec_puts
    RET

cmd_as_assign_error:
    LD   DE, msg_as_error
    CALL exec_puts
    RET

cmd_as_usage:
    LD   DE, msg_as_usage
    CALL exec_puts
    RET

msg_as_ok:
    DEFM "Assigned.", 0x0D, 0x0A, 0
msg_as_usage:
    DEFM "Usage: AS <logdev> <physdev>", 0x0D, 0x0A, 0
msg_as_bad_logdev:
    DEFM "Unknown logical device.", 0x0D, 0x0A, 0
msg_as_bad_physdev:
    DEFM "Unknown physical device.", 0x0D, 0x0A, 0
msg_as_error:
    DEFM "Assign failed.", 0x0D, 0x0A, 0

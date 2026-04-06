; ============================================================
; cmd_help.asm - HELP command handler
; ============================================================
; HP / HELP: walk the command descriptor table and print each
; command's short-name, name, and description in aligned columns.
;
; Output format (columns padded to fixed width):
;   <short 2> / <name 6> - <description>
;
; exec_puts and exec_puts_pad both preserve HL, so HL can hold
; the current entry base pointer throughout the loop.
; ============================================================
cmd_help:
    LD   DE, msg_help_header
    CALL exec_puts

    LD   HL, (EXEC_CMD_TABLE_HEAD)

cmd_help_loop:
    LD   A, H
    OR   L
    JP   Z, cmd_help_exit           ; null ptr = end of list

    ; --- short-name (pad to 2 chars) ---
    LD   D, H
    LD   E, L                       ; DE = entry base = short-name field (offset 0)
    LD   B, 2
    CALL exec_puts_pad              ; HL preserved = entry base

    ; --- " / " separator ---
    LD   DE, msg_help_sep1
    CALL exec_puts

    ; --- name (pad to 6 chars) ---
    PUSH HL
    LD   BC, CMDESC_OFF_NAME        ; = 3
    ADD  HL, BC
    LD   D, H
    LD   E, L                       ; DE = name field ptr
    POP  HL                         ; restore entry base
    LD   B, 6
    CALL exec_puts_pad              ; HL preserved = entry base

    ; --- " - " separator ---
    LD   DE, msg_help_sep2
    CALL exec_puts

    ; --- description (dereference 2-byte ptr at HL + CMDESC_OFF_DESC = +12) ---
    PUSH HL
    LD   BC, CMDESC_OFF_DESC        ; = 12
    ADD  HL, BC
    LD   E, (HL)                    ; low byte of desc ptr
    INC  HL
    LD   D, (HL)                    ; high byte of desc ptr
    POP  HL                         ; restore entry base
    CALL exec_puts                  ; no padding; last column

    CALL exec_crlf

    ; --- advance: follow next ptr at HL + CMDESC_OFF_NEXT (= 14) ---
    LD   BC, CMDESC_OFF_NEXT        ; = 14
    ADD  HL, BC
    LD   C, (HL)
    INC  HL
    LD   B, (HL)
    LD   H, B
    LD   L, C                       ; HL = next entry ptr
    JP   cmd_help_loop

cmd_help_exit:
    RET

msg_help_header:
    DEFM "NostOS commands:", 0x0D, 0x0A, 0
msg_help_sep1:
    DEFM " / ", 0
msg_help_sep2:
    DEFM " - ", 0

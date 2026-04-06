; ============================================================
; ansi.asm - Shared ANSI/VT100 terminal routines for NostOS apps
; ============================================================
; Include this file in native apps that need cursor control.
; Requires: LOGDEV_ID_CONI, LOGDEV_ID_CONO, DEV_STAT, DEV_CREAD_RAW,
;           DEV_CWRITE, DEV_CWRITE_STR, KERNELADDR
;
; All routines preserve BC, HL. DE is preserved unless it is an input parameter.
; ============================================================

; ============================================================
; ansi_putchar - Write character in E to console
; Inputs:  E = character
; Outputs: none (A clobbered)
; ============================================================
ansi_putchar:
    PUSH BC
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  BC
    RET

; ============================================================
; ansi_puts - Write null-terminated string at DE to console
; Inputs:  DE = pointer to string
; Outputs: none (A, DE clobbered)
; ============================================================
ansi_puts:
    PUSH BC
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    POP  BC
    RET

; ============================================================
; ansi_newline - Output CR+LF
; ============================================================
ansi_newline:
    PUSH DE
    LD   E, 0x0D
    CALL ansi_putchar
    LD   E, 0x0A
    CALL ansi_putchar
    POP  DE
    RET

; ============================================================
; ansi_cls - Clear screen (ESC[2J) and home cursor (ESC[H)
; ============================================================
ansi_cls:
    PUSH DE
    LD   DE, ansi_cls_str
    CALL ansi_puts
    POP  DE
    RET
ansi_cls_str:
    DEFB 0x1B, "[2J", 0x1B, "[H", 0

; ============================================================
; ansi_home - Move cursor to top-left (ESC[H)
; ============================================================
ansi_home:
    PUSH DE
    LD   DE, ansi_home_str
    CALL ansi_puts
    POP  DE
    RET
ansi_home_str:
    DEFB 0x1B, "[H", 0

; ============================================================
; ansi_hide_cursor - Hide cursor (ESC[?25l)
; ============================================================
ansi_hide_cursor:
    PUSH DE
    LD   DE, ansi_hide_str
    CALL ansi_puts
    POP  DE
    RET
ansi_hide_str:
    DEFB 0x1B, "[?25l", 0

; ============================================================
; ansi_show_cursor - Show cursor (ESC[?25h)
; ============================================================
ansi_show_cursor:
    PUSH DE
    LD   DE, ansi_show_str
    CALL ansi_puts
    POP  DE
    RET
ansi_show_str:
    DEFB 0x1B, "[?25h", 0

; ============================================================
; ansi_goto - Move cursor to row B, column C (1-based)
; Sends: ESC[<row>;<col>H
; Inputs:  B = row (1-255), C = column (1-255)
; Outputs: none (A clobbered)
; ============================================================
ansi_goto:
    PUSH DE
    PUSH HL
    PUSH BC
    ; Build ESC[ sequence
    LD   E, 0x1B
    CALL ansi_putchar
    LD   E, '['
    CALL ansi_putchar
    ; Output row number
    LD   A, B
    CALL ansi_put_decimal
    ; Semicolon
    LD   E, ';'
    CALL ansi_putchar
    ; Output column number
    POP  BC
    PUSH BC
    LD   A, C
    CALL ansi_put_decimal
    ; 'H' to finish
    LD   E, 'H'
    CALL ansi_putchar
    POP  BC
    POP  HL
    POP  DE
    RET

; ============================================================
; ansi_put_decimal - Output A as decimal (1-255) to console
; Inputs:  A = value (1-255)
; Outputs: none (A, DE clobbered)
; ============================================================
ansi_put_decimal:
    PUSH BC
    LD   C, 0               ; suppress leading zeros
    ; Hundreds
    LD   B, 100
    CALL ansi_pd_digit
    ; Tens
    LD   B, 10
    CALL ansi_pd_digit
    ; Ones (always print)
    ADD  A, '0'
    LD   E, A
    CALL ansi_putchar
    POP  BC
    RET

ansi_pd_digit:
    PUSH DE
    LD   E, 0               ; digit count
ansi_pd_div:
    CP   B
    JP   C, ansi_pd_done
    SUB  B
    INC  E
    JP   ansi_pd_div
ansi_pd_done:
    ; E = digit, A = remainder
    LD   D, A               ; save remainder
    LD   A, E
    OR   C                   ; C = suppress flag (0 = suppress)
    JP   Z, ansi_pd_skip    ; skip leading zero
    LD   C, 1               ; no longer suppressing
    LD   A, E
    ADD  A, '0'
    LD   E, A
    CALL ansi_putchar
ansi_pd_skip:
    LD   A, D               ; restore remainder
    POP  DE
    RET

; ============================================================
; ansi_check_key - Non-blocking check if a key is available
; Inputs:  none
; Outputs: A = 0 if no key, A = character if key pressed
;          (Z flag set if no key)
; ============================================================
ansi_check_key:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_STAT
    CALL KERNELADDR
    ; HL = 1 if char waiting, 0 otherwise
    LD   A, L
    OR   A
    JP   Z, ansi_ck_none
    ; Character available, read it
    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    LD   A, L               ; A = character
    OR   A                   ; clear Z if non-zero (it will be)
    JP   ansi_ck_exit
ansi_ck_none:
    XOR  A                   ; A = 0, Z flag set
ansi_ck_exit:
    POP  HL
    POP  DE
    POP  BC
    RET

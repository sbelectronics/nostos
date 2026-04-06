; ============================================================
; common.asm - Shared executive utility routines
; ============================================================

; ------------------------------------------------------------
; exec_upcase_delimit
; Upcase a token in a buffer in-place, null-terminating at
; the first space or CR.
; Inputs:
;   HL - start of token
; Outputs:
;   HL - pointer to char after the null terminator, or at
;        the null if end-of-string was already null (clobbered)
;   A  - clobbered
; ------------------------------------------------------------
exec_upcase_delimit:
    LD   A, (HL)
    OR   A
    JP   Z, exec_upcase_delimit_exit ; null: done; HL stays at null
    CP   0x0D                        ; CR: terminate
    JP   Z, exec_upcase_delimit_term
    CP   ' '                         ; space: terminate
    JP   Z, exec_upcase_delimit_term
    CP   'a'
    JP   C, exec_upcase_delimit_next ; < 'a': not lowercase
    CP   'z' + 1
    JP   NC, exec_upcase_delimit_next ; >= 'z'+1: not lowercase
    SUB  0x20
    LD   (HL), A
exec_upcase_delimit_next:
    INC  HL
    JP   exec_upcase_delimit
exec_upcase_delimit_term:
    LD   (HL), 0                    ; null-terminate at delimiter
    INC  HL                         ; step past the null
exec_upcase_delimit_exit:
    RET

; ------------------------------------------------------------
; exec_skip_spaces
; Advance HL past any space characters.
; Inputs:
;   HL - pointer into buffer
; Outputs:
;   HL - pointer to first non-space char (may be null/CR) (clobbered)
;   A  - clobbered
; ------------------------------------------------------------
exec_skip_spaces:
    LD   A, (HL)
    CP   ' '
    JP   NZ, exec_skip_spaces_exit
    INC  HL
    JP   exec_skip_spaces
exec_skip_spaces_exit:
    RET

; ------------------------------------------------------------
; exec_strip_colon
; Strip a trailing ':' from a null-terminated token in-place.
; Inputs:
;   DE - pointer to null-terminated token
; Outputs:
;   (buffer modified in place if ':' found)
; Preserves: HL, DE, BC
; ------------------------------------------------------------
exec_strip_colon:
    PUSH HL
    PUSH AF
    LD   H, D
    LD   L, E                       ; HL = start of token
exec_strip_colon_scan:
    LD   A, (HL)
    OR   A
    JP   Z, exec_strip_colon_found
    INC  HL
    JP   exec_strip_colon_scan
exec_strip_colon_found:
    ; Guard: if HL == DE, token is empty; nothing to strip.
    LD   A, H
    CP   D
    JP   NZ, exec_strip_colon_check
    LD   A, L
    CP   E
    JP   Z, exec_strip_colon_done
exec_strip_colon_check:
    DEC  HL                         ; HL = last char of token
    LD   A, (HL)
    CP   ':'
    JP   NZ, exec_strip_colon_done
    LD   (HL), 0                    ; replace ':' with null
exec_strip_colon_done:
    POP  AF
    POP  HL
    RET

; ------------------------------------------------------------
; exec_print_error
; Print a human-readable error message for a kernel error code.
; Inputs:
;   A  - error code (ERR_*)
; Outputs:
;   (none - prints to CON)
; ------------------------------------------------------------
exec_print_error:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL
    LD   H, 0
    LD   L, A                       ; HL = error code (exec_puts preserves HL)
    LD   DE, exec_err_prefix        ; "Error: "
    CALL exec_puts
    LD   A, L
    CP   16                         ; 16 known codes (0-15)
    JP   NC, exec_print_error_unknown
    ; Index into table: HL = exec_err_table + code*2
    ADD  HL, HL                     ; HL = code * 2
    LD   DE, exec_err_table
    ADD  HL, DE                     ; HL = &exec_err_table[code]
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                    ; DE = error string pointer
    CALL exec_puts
    JP   exec_print_error_done
exec_print_error_unknown:
    LD   DE, exec_err_unknown       ; "Unknown ("
    CALL exec_puts
    LD   A, L                       ; error code (HL preserved by exec_puts)
    CALL exec_print_dec8            ; print decimal value (preserves HL)
    LD   DE, exec_err_rparen        ; ")\r\n"
    CALL exec_puts
exec_print_error_done:
    POP  HL
    POP  DE
    POP  BC
    POP  AF
    RET

exec_err_prefix:    DEFM "Error: ", 0
exec_err_unknown:   DEFM "Unknown (", 0
exec_err_rparen:    DEFM ")", 0x0D, 0x0A, 0

exec_err_table:
    DEFW exec_err_0
    DEFW exec_err_1
    DEFW exec_err_2
    DEFW exec_err_3
    DEFW exec_err_4
    DEFW exec_err_5
    DEFW exec_err_6
    DEFW exec_err_7
    DEFW exec_err_8
    DEFW exec_err_9
    DEFW exec_err_10
    DEFW exec_err_11
    DEFW exec_err_12
    DEFW exec_err_13
    DEFW exec_err_14
    DEFW exec_err_15

exec_err_0:     DEFM "Success.", 0x0D, 0x0A, 0
exec_err_1:     DEFM "Not found.", 0x0D, 0x0A, 0
exec_err_2:     DEFM "Already exists.", 0x0D, 0x0A, 0
exec_err_3:     DEFM "Not supported.", 0x0D, 0x0A, 0
exec_err_4:     DEFM "Invalid parameter.", 0x0D, 0x0A, 0
exec_err_5:     DEFM "Invalid device.", 0x0D, 0x0A, 0
exec_err_6:     DEFM "No space.", 0x0D, 0x0A, 0
exec_err_7:     DEFM "I/O error.", 0x0D, 0x0A, 0
exec_err_8:     DEFM "Not open.", 0x0D, 0x0A, 0
exec_err_9:     DEFM "Too many open.", 0x0D, 0x0A, 0
exec_err_10:    DEFM "Read only.", 0x0D, 0x0A, 0
exec_err_11:    DEFM "Not a directory.", 0x0D, 0x0A, 0
exec_err_12:    DEFM "Not a file.", 0x0D, 0x0A, 0
exec_err_13:    DEFM "Directory not empty.", 0x0D, 0x0A, 0
exec_err_14:    DEFM "Bad filesystem.", 0x0D, 0x0A, 0
exec_err_15:    DEFM "EOF.", 0x0D, 0x0A, 0

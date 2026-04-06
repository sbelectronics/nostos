; ============================================================
; strutils.asm - String utilities for NostOS Z80 Assembler
; Based on Zealasm by Zeal 8-bit Computer (Apache 2.0)
; Ported to NostOS — 8080-only instructions
; ============================================================

; ------------------------------------------------------------
; strltrim
; Trim leading spaces and tabs from string
; Inputs:
;   HL - string pointer
; Outputs:
;   HL - pointer to first non-space character
;   A - first non-space character
; ------------------------------------------------------------
strltrim:
    DEC  HL
_strltrim_loop:
    INC  HL
    LD   A, (HL)
    CP   ' '
    JP   Z, _strltrim_loop
    CP   0x09               ; tab
    JP   Z, _strltrim_loop
    RET

; ------------------------------------------------------------
; strrtrim
; Trim trailing spaces and tabs from string (place \0 after
; last non-space character)
; Inputs:
;   HL - string pointer
; Alters:
;   A
; ------------------------------------------------------------
strrtrim:
    PUSH HL
    PUSH DE
    ; DE always points to last non-space char
    DEC  HL
    LD   D, H
    LD   E, L
_strrtrim_loop:
    INC  HL
    LD   A, (HL)
    OR   A
    JP   Z, _strrtrim_end
    CP   ' '
    JP   Z, _strrtrim_loop
    CP   0x09               ; tab
    JP   Z, _strrtrim_loop
    LD   D, H
    LD   E, L
    JP   _strrtrim_loop
_strrtrim_end:
    INC  DE
    LD   (DE), A            ; A is 0 here
    POP  DE
    POP  HL
    RET

; ------------------------------------------------------------
; strcmp
; Compare two NULL-terminated strings
; Inputs:
;   HL - first string
;   DE - second string
; Outputs:
;   A - 0 if equal, >0 if DE > HL, <0 if HL > DE
; Alters:
;   A
; ------------------------------------------------------------
strcmp:
    PUSH HL
    PUSH DE
    DEC  HL
    DEC  DE
_strcmp_compare:
    INC  HL
    INC  DE
    LD   A, (DE)
    SUB  (HL)
    JP   NZ, _strcmp_end
    ; Check if both reached null
    OR   (HL)
    JP   NZ, _strcmp_compare
_strcmp_end:
    POP  DE
    POP  HL
    RET

; ------------------------------------------------------------
; strncmp
; Compare at most BC bytes of two strings
; Inputs:
;   HL - first string
;   DE - second string
;   BC - max bytes to compare
; Outputs:
;   A - 0 if equal, >0 if DE > HL, <0 if HL > DE
; Alters:
;   A
; ------------------------------------------------------------
strncmp:
    PUSH HL
    PUSH DE
    PUSH BC
    DEC  HL
    DEC  DE
    INC  BC
_strncmp_compare:
    DEC  BC
    INC  HL
    INC  DE
    LD   A, B
    OR   C
    JP   Z, _strncmp_end
    LD   A, (DE)
    SUB  (HL)
    JP   NZ, _strncmp_end
    OR   (HL)
    JP   NZ, _strncmp_compare
_strncmp_end:
    POP  BC
    POP  DE
    POP  HL
    RET

; ------------------------------------------------------------
; strncmp_opt
; Compare A bytes of two strings (optimized, A must not be 0)
; Inputs:
;   HL - first string
;   DE - second string
;   A  - max bytes to compare (must not be 0)
; Outputs:
;   A - 0 if equal, >0 if DE > HL, <0 if HL > DE
; Alters:
;   A
; ------------------------------------------------------------
strncmp_opt:
    PUSH HL
    PUSH DE
    PUSH BC
    LD   B, A
_strncmp_opt_compare:
    LD   A, (DE)
    SUB  (HL)
    JP   NZ, _strncmp_opt_end
    DEC  B
    JP   Z, _strncmp_opt_end
    ; A is 0 here, check if (HL) is also 0
    OR   (HL)
    INC  DE
    INC  HL
    JP   NZ, _strncmp_opt_compare
_strncmp_opt_end:
    POP  BC
    POP  DE
    POP  HL
    RET

; ------------------------------------------------------------
; strsep
; Find delimiter A in string HL, null-terminate there
; Inputs:
;   HL - string pointer
;   A  - delimiter character
; Outputs:
;   DE - pointer past delimiter (or unchanged if not found)
;   A  - 0 if delimiter found, non-zero else
; Alters:
;   A, BC, DE
; ------------------------------------------------------------
strsep:
    PUSH HL
    LD   D, A               ; save delimiter in D
_strsep_loop:
    LD   A, (HL)
    CP   D
    JP   Z, _strsep_found
    INC  HL
    OR   A
    JP   NZ, _strsep_loop
    ; End of string, not found
    LD   A, 1
    POP  HL
    RET
_strsep_found:
    XOR  A
    LD   (HL), A            ; null-terminate
    INC  HL                 ; point past delimiter
    EX   DE, HL
    POP  HL
    RET

; ------------------------------------------------------------
; strsep_ws
; Split string at first whitespace (space or tab).
; Same interface as strsep but matches either delimiter.
; Inputs:
;   HL - string pointer
; Outputs:
;   DE - pointer past delimiter (or unchanged if not found)
;   A  - 0 if delimiter found, non-zero else
; Alters:
;   A, BC, DE
; ------------------------------------------------------------
strsep_ws:
    PUSH HL
_strsep_ws_loop:
    LD   A, (HL)
    CP   ' '
    JP   Z, _strsep_ws_found
    CP   0x09                   ; tab
    JP   Z, _strsep_ws_found
    INC  HL
    OR   A
    JP   NZ, _strsep_ws_loop
    ; End of string, not found
    LD   A, 1
    POP  HL
    RET
_strsep_ws_found:
    XOR  A
    LD   (HL), A                ; null-terminate
    INC  HL                     ; point past delimiter
    EX   DE, HL
    POP  HL
    RET

; ------------------------------------------------------------
; strlen
; Calculate length of NULL-terminated string
; Inputs:
;   HL - string pointer
; Outputs:
;   BC - length
; Alters:
;   A
; ------------------------------------------------------------
strlen:
    PUSH HL
    XOR  A
    LD   B, A
    LD   C, A
_strlen_loop:
    CP   (HL)
    JP   Z, _strlen_end
    INC  HL
    INC  BC
    JP   _strlen_loop
_strlen_end:
    POP  HL
    RET

; ------------------------------------------------------------
; strcpy
; Copy NULL-terminated string from HL to DE (including null)
; Inputs:
;   HL - source
;   DE - destination
; Alters:
;   A
; ------------------------------------------------------------
strcpy:
    PUSH HL
    PUSH DE
_strcpy_loop:
    LD   A, (HL)
    LD   (DE), A
    OR   A
    JP   Z, _strcpy_done
    INC  HL
    INC  DE
    JP   _strcpy_loop
_strcpy_done:
    POP  DE
    POP  HL
    RET

; ------------------------------------------------------------
; strncpy_unsaved
; Copy up to BC bytes from HL to DE; pad with zeros if source
; is shorter. DE advances past end.
; Inputs:
;   HL - source
;   DE - destination
;   BC - max bytes
; Outputs:
;   DE - destination + BC
; Alters:
;   A, BC, HL, DE
; ------------------------------------------------------------
strncpy_unsaved:
    LD   A, B
    OR   C
    RET  Z
_strncpy_loop:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  BC
    OR   A
    JP   Z, _strncpy_zero
    LD   A, B
    OR   C
    JP   NZ, _strncpy_loop
    RET
_strncpy_zero:
    ; Source ended, fill rest with zeros
    LD   A, B
    OR   C
    RET  Z
_strncpy_zero_loop:
    XOR  A
    LD   (DE), A
    INC  DE
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, _strncpy_zero_loop
    RET

; ------------------------------------------------------------
; strtolower
; Convert string to lowercase in-place
; Inputs:
;   HL - string pointer
; Alters:
;   A
; ------------------------------------------------------------
strtolower:
    PUSH HL
_strtolower_loop:
    LD   A, (HL)
    OR   A
    JP   Z, _strtolower_end
    CALL to_lower
    LD   (HL), A
    INC  HL
    JP   _strtolower_loop
_strtolower_end:
    POP  HL
    RET

; ------------------------------------------------------------
; to_lower
; Convert character to lowercase
; Inputs:
;   A - character
; Outputs:
;   A - lowercase character (or unchanged)
; ------------------------------------------------------------
to_lower:
    CP   'A'
    JP   C, _to_lower_ret
    CP   'Z' + 1
    JP   NC, _to_lower_ret
    ADD  A, 'a' - 'A'
_to_lower_ret:
    RET

; ------------------------------------------------------------
; is_alpha
; Check if A is a letter [A-Za-z]
; Outputs: carry set = NOT alpha
; ------------------------------------------------------------
is_alpha:
    CP   'a'
    JP   C, _is_alpha_upper
    CP   'z' + 1
    CCF
    RET
_is_alpha_upper:
    CP   'A'
    RET  C
    CP   'Z' + 1
    CCF
    RET

; ------------------------------------------------------------
; is_digit
; Check if A is a digit [0-9]
; Outputs: carry set = NOT digit
; ------------------------------------------------------------
is_digit:
    CP   '0'
    RET  C
    CP   '9' + 1
    CCF
    RET

; ------------------------------------------------------------
; is_alpha_numeric
; Check if A is alphanumeric [A-Za-z0-9]
; Outputs: carry set = NOT alphanumeric
; ------------------------------------------------------------
is_alpha_numeric:
    CALL is_alpha
    RET  NC
    JP   is_digit

; ------------------------------------------------------------
; parse_int
; Parse string as integer (hex with $, 0x prefix, or decimal)
; Inputs:
;   HL - NULL-terminated string
; Outputs:
;   HL - parsed value
;   A  - 0=success, 1=overflow, 2=bad char
; Alters:
;   A, HL
; ------------------------------------------------------------
parse_int:
    LD   A, (HL)
    CP   '$'
    JP   Z, _parse_hex_prefix
    CP   '0'
    JP   NZ, parse_dec
    INC  HL
    LD   A, (HL)
    CP   'x'
    JP   Z, _parse_hex_prefix
    CP   'X'
    JP   Z, _parse_hex_prefix
    DEC  HL
    JP   parse_dec

_parse_hex_prefix:
    INC  HL                 ; skip prefix

; ------------------------------------------------------------
; parse_hex
; Parse hex string at HL
; Inputs:
;   HL - hex digits string
; Outputs:
;   HL - parsed value
;   A  - 0=success, 1=overflow, 2=bad char
; ------------------------------------------------------------
parse_hex:
    PUSH DE
    EX   DE, HL
    LD   H, 0
    LD   L, 0
    LD   A, (DE)
    OR   A
    JP   Z, _parse_hex_bad
_parse_hex_loop:
    CALL _parse_hex_digit
    JP   C, _parse_hex_bad
    ; Shift HL left 4 times
    ADD  HL, HL
    JP   C, _parse_hex_big
    ADD  HL, HL
    JP   C, _parse_hex_big
    ADD  HL, HL
    JP   C, _parse_hex_big
    ADD  HL, HL
    JP   C, _parse_hex_big
    OR   L
    LD   L, A
    INC  DE
    LD   A, (DE)
    OR   A
    JP   Z, _parse_hex_end
    JP   _parse_hex_loop
_parse_hex_big:
    LD   A, 1
    POP  DE
    RET
_parse_hex_bad:
    LD   A, 2
_parse_hex_end:
    POP  DE
    RET

; Parse a single hex digit
; Input: A = character
; Output: A = value 0-15, carry set if invalid
_parse_hex_digit:
    CP   '0'
    JP   C, _parse_not_hex
    CP   '9' + 1
    JP   C, _parse_hex_dec_d
    CP   'A'
    JP   C, _parse_not_hex
    CP   'F' + 1
    JP   C, _parse_upper_hex_d
    CP   'a'
    JP   C, _parse_not_hex
    CP   'f' + 1
    JP   NC, _parse_not_hex
    SUB  'a' - 10
    RET
_parse_upper_hex_d:
    SUB  'A' - 10
    RET
_parse_hex_dec_d:
    SUB  '0'
    RET
_parse_not_hex:
    SCF
    RET

; ------------------------------------------------------------
; parse_dec
; Parse decimal string at HL
; Inputs:
;   HL - decimal digits string
; Outputs:
;   HL - parsed value
;   A  - 0=success, 1=overflow, 2=bad char
; ------------------------------------------------------------
parse_dec:
    PUSH DE
    PUSH BC
    EX   DE, HL
    LD   H, 0
    LD   L, 0
    LD   A, (DE)
    OR   A
    JP   Z, _parse_dec_bad
_parse_dec_loop:
    ; Check if digit
    CP   '0'
    JP   C, _parse_dec_bad
    CP   '9' + 1
    JP   NC, _parse_dec_bad
    SUB  '0'
    ; Multiply HL by 10: HL = HL*2 + HL*8
    ADD  HL, HL             ; HL * 2
    JP   C, _parse_dec_big
    PUSH HL                 ; save HL * 2
    ADD  HL, HL             ; HL * 4
    JP   C, _parse_dec_big_pop
    ADD  HL, HL             ; HL * 8
    JP   C, _parse_dec_big_pop
    POP  BC                 ; BC = HL * 2
    ADD  HL, BC             ; HL = 10 * original
    JP   C, _parse_dec_big
    LD   B, 0
    LD   C, A
    ADD  HL, BC             ; add digit
    JP   C, _parse_dec_big
    INC  DE
    LD   A, (DE)
    OR   A
    JP   Z, _parse_dec_end
    JP   _parse_dec_loop
_parse_dec_big_pop:
    POP  BC
_parse_dec_big:
    LD   A, 1
    POP  BC
    POP  DE
    RET
_parse_dec_bad:
    LD   A, 2
_parse_dec_end:
    POP  BC
    POP  DE
    RET

; ------------------------------------------------------------
; parse_str
; Parse quoted string: "text" with escape sequences
; Modifies the string in-place (removes quotes, processes escapes)
; Inputs:
;   HL - string starting with "
; Outputs:
;   HL - modified string (same address)
;   BC - length of parsed string
;   A  - 0 on success, non-zero on error
; Alters:
;   A, BC
; ------------------------------------------------------------
parse_str:
    LD   A, (HL)
    CP   '"'
    JP   NZ, _parse_str_err
    PUSH HL
    LD   D, H
    LD   E, L               ; DE = write pointer
    LD   BC, 0
    INC  HL
_parse_str_loop:
    LD   A, (HL)
    CP   '"'
    JP   Z, _parse_str_end
    CP   0x5C               ; backslash
    JP   Z, _parse_str_esc
    ; Normal character
_parse_str_store:
    LD   (DE), A
    INC  HL
    INC  DE
    INC  BC
    JP   _parse_str_loop
_parse_str_end:
    ; Verify next char is null
    INC  HL
    LD   A, (HL)
    LD   (DE), A            ; store null if it is
    POP  HL
    RET
_parse_str_esc:
    INC  HL
    LD   A, (HL)
    CP   0x5C               ; backslash
    JP   Z, _parse_str_store
    CP   '"'
    JP   Z, _parse_str_store
    ; Check escape sequences
    CP   '0'
    JP   Z, _parse_str_esc_0
    CP   'n'
    JP   Z, _parse_str_esc_n
    CP   'r'
    JP   Z, _parse_str_esc_r
    CP   't'
    JP   Z, _parse_str_esc_t
    CP   'a'
    JP   Z, _parse_str_esc_a
    ; Unknown escape: keep both characters
    LD   A, 0x5C
    LD   (DE), A
    INC  DE
    INC  BC
    LD   A, (HL)
    JP   _parse_str_store
_parse_str_esc_0:
    LD   A, 0
    JP   _parse_str_store
_parse_str_esc_n:
    LD   A, 0x0A
    JP   _parse_str_store
_parse_str_esc_r:
    LD   A, 0x0D
    JP   _parse_str_store
_parse_str_esc_t:
    LD   A, 0x09
    JP   _parse_str_store
_parse_str_esc_a:
    LD   A, 0x07
    JP   _parse_str_store
_parse_str_err:
    LD   A, 1
    RET

; ------------------------------------------------------------
; word_to_ascii
; Convert 16-bit value to decimal ASCII string
; Inputs:
;   DE - buffer to store result
;   HL - value to convert
; Outputs:
;   HL - address past last digit
; Alters:
;   A, BC, DE, HL
; ------------------------------------------------------------
word_to_ascii:
    LD   C, 10              ; divisor constant
    ; Save buffer start
    LD   (za_w2a_buf), DE
    LD   D, 0               ; digit count
_word_to_ascii_loop:
    CALL _divide_hl_c
    ; Remainder in A, convert to ASCII
    ADD  A, '0'
    PUSH AF
    INC  D
    ; Check if HL is 0
    LD   A, H
    OR   L
    JP   NZ, _word_to_ascii_loop
    ; Pop digits in reverse order into buffer
    LD   B, D               ; digit count
    LD   HL, (za_w2a_buf)
_word_to_ascii_pop:
    POP  AF
    LD   (HL), A
    INC  HL
    DEC  B
    JP   NZ, _word_to_ascii_pop
    RET

; Divide HL by C
; Returns: HL = quotient, A = remainder
_divide_hl_c:
    XOR  A
    LD   B, 16
_divide_hl_c_loop:
    ADD  HL, HL
    RLA
    JP   C, _divide_hl_carry
    CP   C
    JP   C, _divide_hl_next
_divide_hl_carry:
    SUB  C
    INC  L
_divide_hl_next:
    DEC  B
    JP   NZ, _divide_hl_c_loop
    RET

; Temp variable for word_to_ascii
za_w2a_buf: DEFW 0

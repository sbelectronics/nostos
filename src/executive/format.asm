; ============================================================
; Formatting Utilities
; ============================================================

; exec_print_char
; Print character in A to console
exec_print_char:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  DE
    POP  BC
    RET

; exec_print_dec8_pad2 (e.g. for MM, DD, etc.)
; Print 8-bit value in A as exactly 2 decimal digits
exec_print_dec8_pad2:
    PUSH AF
    PUSH BC
    LD   B, 0                   ; B = quotient (tens)
exec_print_dec8_pad2_tens:
    CP   10
    JP   C, exec_print_dec8_pad2_ones
    SUB  10
    INC  B
    JP   exec_print_dec8_pad2_tens
exec_print_dec8_pad2_ones:
    LD   C, A                   ; C = remainder (ones)
    LD   A, B
    ADD  A, '0'
    CALL exec_print_char
    LD   A, C
    ADD  A, '0'
    CALL exec_print_char
    POP  BC
    POP  AF
    RET

; exec_print_dec8
; Print 8-bit value in A as decimal string (1 to 3 digits) without leading zeros
exec_print_dec8:
    PUSH AF
    PUSH BC
    PUSH DE
    LD   E, 0                   ; E = digit printed flag
    
    ; Hundreds
    LD   B, 0
exec_print_dec8_100:
    CP   100
    JP   C, exec_print_dec8_100_done
    SUB  100
    INC  B
    JP   exec_print_dec8_100
exec_print_dec8_100_done:
    LD   C, A                   ; save remainder in C
    LD   A, B
    OR   A
    JP   Z, exec_print_dec8_10_start ; skip if 0
    LD   E, 1                   ; mark digit printed
    ADD  A, '0'
    CALL exec_print_char
    
exec_print_dec8_10_start:
    LD   A, C                   ; restore remainder
    LD   B, 0
exec_print_dec8_10:
    CP   10
    JP   C, exec_print_dec8_10_done
    SUB  10
    INC  B
    JP   exec_print_dec8_10
exec_print_dec8_10_done:
    LD   C, A                   ; save remainder in C
    LD   A, B
    OR   A
    JP   NZ, exec_print_dec8_10_print
    LD   A, E
    OR   A
    JP   Z, exec_print_dec8_1_start ; skip if 0 and no previous digit
exec_print_dec8_10_print:
    LD   A, B
    ADD  A, '0'
    CALL exec_print_char

exec_print_dec8_1_start:
    LD   A, C                   ; restore remainder
    ADD  A, '0'
    CALL exec_print_char
    
    POP  DE
    POP  BC
    POP  AF
    RET

; exec_print_dec16_w6
; Print 16-bit value in HL as decimal, right-justified in a 6-character wide field.
; Leading positions are filled with spaces.  Values 0–65535 (max 5 digits).
; Inputs:
;   HL - value to print (preserved)
; Outputs:
;   (none)
exec_print_dec16_w6:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL                     ; saved so we can call exec_print_dec16 at end
    LD   B, 5                   ; default: 5 leading spaces (1-digit number)

    ; Is HL >= 10?
    LD   A, H
    CP   0
    JP   NZ, exec_dec16_w6_ge10 ; H > 0 → HL >= 256 >= 10
    LD   A, L
    CP   10
    JP   C, exec_dec16_w6_pad   ; HL < 10 → 1 digit
exec_dec16_w6_ge10:
    DEC  B                      ; 2+ digits

    ; Is HL >= 100?
    LD   A, H
    CP   0
    JP   NZ, exec_dec16_w6_ge100 ; H > 0 → HL >= 256 >= 100
    LD   A, L
    CP   100
    JP   C, exec_dec16_w6_pad   ; HL < 100 → 2 digits
exec_dec16_w6_ge100:
    DEC  B                      ; 3+ digits

    ; Is HL >= 1000? (0x03E8: D=3, E=0xE8)
    LD   DE, 1000
    LD   A, H
    CP   D
    JP   C, exec_dec16_w6_pad   ; H < 3 → HL < 768 < 1000
    JP   NZ, exec_dec16_w6_ge1000 ; H > 3 → HL >= 1024 >= 1000
    LD   A, L
    CP   E
    JP   C, exec_dec16_w6_pad   ; H==3, L < 232 → HL < 1000
exec_dec16_w6_ge1000:
    DEC  B                      ; 4+ digits

    ; Is HL >= 10000? (0x2710: D=0x27, E=0x10)
    LD   DE, 10000
    LD   A, H
    CP   D
    JP   C, exec_dec16_w6_pad   ; H < 0x27 → HL < 10000
    JP   NZ, exec_dec16_w6_ge10000 ; H > 0x27 → HL >= 10000
    LD   A, L
    CP   E
    JP   C, exec_dec16_w6_pad   ; H==0x27, L < 0x10 → HL < 10000
exec_dec16_w6_ge10000:
    DEC  B                      ; 5 digits → 1 leading space

exec_dec16_w6_pad:
    LD   A, B
    OR   A
    JP   Z, exec_dec16_w6_num
exec_dec16_w6_pad_loop:
    LD   A, ' '
    CALL exec_print_char
    DEC  B
    JP   NZ, exec_dec16_w6_pad_loop
exec_dec16_w6_num:
    POP  HL                     ; restore value
    CALL exec_print_dec16       ; HL preserved by callee
    POP  DE
    POP  BC
    POP  AF
    RET

; exec_print_dec16
; Print 16-bit value in HL as decimal string (1 to 5 digits) without leading zeros
exec_print_dec16:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL
    
    LD   C, 0                   ; C = digit printed flag
    
    ; 10000
    LD   DE, 10000
    CALL exec_print_dec16_digit
    
    ; 1000
    LD   DE, 1000
    CALL exec_print_dec16_digit
    
    ; 100
    LD   DE, 100
    CALL exec_print_dec16_digit
    
    ; 10
    LD   DE, 10
    CALL exec_print_dec16_digit
    
    ; 1s and final 0 check
    LD   A, L                   ; whatever remains is < 10
    ADD  A, '0'
    CALL exec_print_char

    POP  HL
    POP  DE
    POP  BC
    POP  AF
    RET

; Helper for exec_print_dec16
; Subtracts DE from HL repeatedly, prints quotient
; C = leading digit flag (1 = print 0s, 0 = suppress 0s)
exec_print_dec16_digit:
    LD   B, 0                   ; B = quotient
exec_print_dec16_digit_loop:
    ; Compare HL and DE. If HL < DE, we are done
    LD   A, H
    CP   D
    JP   C, exec_print_dec16_digit_done
    JP   NZ, exec_print_dec16_digit_sub
    LD   A, L
    CP   E
    JP   C, exec_print_dec16_digit_done
exec_print_dec16_digit_sub:
    ; HL = HL - DE
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    INC  B
    JP   exec_print_dec16_digit_loop
exec_print_dec16_digit_done:
    LD   A, B
    OR   A
    JP   NZ, exec_print_dec16_digit_print
    LD   A, C
    OR   A
    JP   Z, exec_print_dec16_digit_exit ; skip 0 if leading
exec_print_dec16_digit_print:
    LD   C, 1                   ; set flag: 0s no longer leading
    LD   A, B
    ADD  A, '0'
    CALL exec_print_char
exec_print_dec16_digit_exit:
    RET

; ------------------------------------------------------------
; exec_print_dec32_w6
; Print 32-bit value DE:HL as decimal, right-justified in a
; 6-character wide field.  Field overflows (no padding) for
; values >= 1,000,000.  Falls back to exec_print_dec16_w6 when
; the high word is zero so 1-5 digit values get the same
; spacing as before.
; Inputs:
;   DE:HL - value (D = MSB byte, L = LSB byte)
; ------------------------------------------------------------
exec_print_dec32_w6:
    LD   A, D
    OR   E
    JP   Z, exec_print_dec16_w6 ; high word zero: 16-bit path
    ; high word non-zero → value >= 65536 → 5+ digits.
    ; Pad with one space iff value < 100,000 (= 0x000186A0).
    LD   A, D
    OR   A
    JP   NZ, exec_dec32_w6_no_pad   ; D != 0 → value >= 16M, no padding
    LD   A, E
    CP   2
    JP   NC, exec_dec32_w6_no_pad   ; E >= 2 → value >= 131072 >= 100000
    ; D=0, E=1; compare HL against 0x86A0
    LD   A, H
    CP   0x86
    JP   C, exec_dec32_w6_pad_one
    JP   NZ, exec_dec32_w6_no_pad
    LD   A, L
    CP   0xA0
    JP   C, exec_dec32_w6_pad_one
exec_dec32_w6_no_pad:
    JP   exec_print_dec32       ; tail-call: print without padding
exec_dec32_w6_pad_one:
    PUSH HL
    PUSH DE
    LD   A, ' '
    CALL exec_print_char
    POP  DE
    POP  HL
    JP   exec_print_dec32       ; tail-call

; ------------------------------------------------------------
; exec_print_dec32
; Print 32-bit value DE:HL as decimal (no padding, max ~4
; billion).  Uses EXEC_DEC32_SCRATCH as 4-byte scratch.
; Inputs:
;   DE:HL - value (D = MSB byte)
; Clobbers: AF, BC, DE, HL
; ------------------------------------------------------------
exec_print_dec32:
    LD   (EXEC_DEC32_SCRATCH), HL
    EX   DE, HL
    LD   (EXEC_DEC32_SCRATCH + 2), HL
    LD   HL, exec_dec32_pv_table
    LD   C, 9                   ; 9 place values (ones handled last)
    LD   B, 0                   ; B = leading-zero suppression flag

exec_d32_next:
    PUSH HL                     ; save table pointer
    PUSH BC                     ; save counter/flags
    ; Load place value BC:DE from table (stored low byte first)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    LD   C, (HL)
    INC  HL
    LD   B, (HL)                ; BC:DE = place value
    LD   A, 0                   ; digit counter

exec_d32_sub:
    ; Compare value (at EXEC_DEC32_SCRATCH) >= BC:DE
    PUSH AF                     ; save digit count
    LD   HL, (EXEC_DEC32_SCRATCH + 2)
    LD   A, H
    CP   B
    JP   C, exec_d32_lt
    JP   NZ, exec_d32_ge
    LD   A, L
    CP   C
    JP   C, exec_d32_lt
    JP   NZ, exec_d32_ge
    LD   HL, (EXEC_DEC32_SCRATCH)
    LD   A, H
    CP   D
    JP   C, exec_d32_lt
    JP   NZ, exec_d32_ge
    LD   A, L
    CP   E
    JP   C, exec_d32_lt

exec_d32_ge:
    ; Subtract place value from stored value
    LD   HL, (EXEC_DEC32_SCRATCH)
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    LD   (EXEC_DEC32_SCRATCH), HL
    LD   HL, (EXEC_DEC32_SCRATCH + 2)
    LD   A, L
    SBC  A, C
    LD   L, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (EXEC_DEC32_SCRATCH + 2), HL
    POP  AF                     ; restore digit count
    INC  A
    JP   exec_d32_sub

exec_d32_lt:
    POP  AF                     ; A = digit for this place
    POP  BC                     ; B = suppress flag, C = remaining
    POP  HL                     ; table pointer
    LD   DE, 4
    ADD  HL, DE                 ; advance to next table entry
    ; Print digit (suppress leading zeros)
    OR   A
    JP   NZ, exec_d32_pr
    LD   A, B
    OR   A
    JP   Z, exec_d32_skip       ; still leading zeros
    XOR  A                      ; digit = 0, must print
exec_d32_pr:
    LD   B, 1                   ; no longer suppressing
    ADD  A, '0'
    CALL exec_print_char
exec_d32_skip:
    DEC  C
    JP   NZ, exec_d32_next
    ; Print ones digit (always)
    LD   A, (EXEC_DEC32_SCRATCH)
    ADD  A, '0'
    JP   exec_print_char        ; tail call

; Place value table (32-bit, stored as E, D, C, B — low byte first)
exec_dec32_pv_table:
    DEFB 0x00, 0xCA, 0x9A, 0x3B ; 1,000,000,000
    DEFB 0x00, 0xE1, 0xF5, 0x05 ;   100,000,000
    DEFB 0x80, 0x96, 0x98, 0x00 ;    10,000,000
    DEFB 0x40, 0x42, 0x0F, 0x00 ;     1,000,000
    DEFB 0xA0, 0x86, 0x01, 0x00 ;       100,000
    DEFB 0x10, 0x27, 0x00, 0x00 ;        10,000
    DEFB 0xE8, 0x03, 0x00, 0x00 ;         1,000
    DEFB 0x64, 0x00, 0x00, 0x00 ;           100
    DEFB 0x0A, 0x00, 0x00, 0x00 ;            10

; exec_print_devname
; Print up to 4 characters starting at HL, stopping at null or space, and append ':'
exec_print_devname:
    PUSH AF
    PUSH BC
    PUSH HL
    LD   B, 4
exec_print_devname_loop:
    LD   A, (HL)
    OR   A
    JP   Z, exec_print_devname_done ; stop at null terminator
    CP   ' '
    JP   Z, exec_print_devname_done ; stop at space
    CALL exec_print_char
    INC  HL
    DEC  B
    JP   NZ, exec_print_devname_loop
exec_print_devname_done:
    LD   A, ':'
    CALL exec_print_char
    POP  HL
    POP  BC
    POP  AF
    RET

; exec_print_space
; Print a single space
exec_print_space:
    PUSH AF
    LD   A, ' '
    CALL exec_print_char
    POP  AF
    RET

; exec_print_hex_nibble
; Convert low nibble of A to uppercase hex ASCII and print it to console.
; Inputs:
;   A  - value (only low nibble used)
; Outputs:
;   A  - clobbered
exec_print_hex_nibble:
    AND  0x0F
    ADD  A, '0'
    CP   '9' + 1
    JP   C, exec_print_hex_nibble_print
    ADD  A, 'A' - ('9' + 1)
exec_print_hex_nibble_print:
    CALL exec_print_char
    RET

; exec_print_hex8
; Print byte in A as 2 uppercase hex ASCII digits to console.
; Inputs:
;   A  - byte to print
; Outputs:
;   (none)
exec_print_hex8:
    PUSH AF
    PUSH BC
    PUSH HL
    LD   B, A                   ; save byte in B
    RRCA
    RRCA
    RRCA
    RRCA                        ; high nibble in low bits
    CALL exec_print_hex_nibble  ; prints high nibble (A clobbered)
    LD   A, B                   ; restore original byte
    CALL exec_print_hex_nibble  ; prints low nibble
    POP  HL
    POP  BC
    POP  AF
    RET

; exec_print_hex16
; Print 16-bit value in HL as 4 uppercase hex ASCII digits to console.
; Inputs:
;   HL - value to print
; Outputs:
;   (none)
exec_print_hex16:
    PUSH AF
    PUSH HL
    LD   A, H
    CALL exec_print_hex8        ; prints high byte; HL preserved by exec_print_hex8
    LD   A, L
    CALL exec_print_hex8        ; prints low byte
    POP  HL
    POP  AF
    RET

; exec_puts_pad
; Print null-terminated string at DE, then pad with spaces until B characters
; have been output in total.  If the string is longer than B, it is printed in
; full with no padding (no truncation).  Preserves HL.
exec_puts_pad:
    PUSH HL
    LD   H, D
    LD   L, E                       ; HL = string pointer
exec_puts_pad_char:
    LD   A, (HL)
    OR   A
    JP   Z, exec_puts_pad_fill      ; null terminator: pad remaining width
    ; Print character in A
    PUSH BC
    PUSH HL
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  BC
    INC  HL
    DEC  B                          ; one fewer column remaining
    JP   NZ, exec_puts_pad_char     ; field not yet full
    JP   exec_puts_pad_done         ; field full (string may be longer; stop here)
exec_puts_pad_fill:
    ; B = spaces still needed
    LD   A, B
    OR   A
    JP   Z, exec_puts_pad_done      ; nothing to pad
exec_puts_pad_fill_loop:
    PUSH BC
    PUSH HL
    LD   E, ' '
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  BC
    DEC  B
    JP   NZ, exec_puts_pad_fill_loop
exec_puts_pad_done:
    POP  HL                         ; restore entry base
    RET

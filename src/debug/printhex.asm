; ============================================================
; Debug Utilities
; ============================================================

; ------------------------------------------------------------
; debug_print_mem16_hex addr
; Macro: print 16-bit memory value at addr in hex followed by CR/LF.
; Inputs:
;   addr - memory address of 16-bit value
; ------------------------------------------------------------
debug_print_mem16_hex macro addr
    PUSH HL
    LD   HL, (addr)
    CALL debug_print_hl_hex
    POP  HL
endm

; ------------------------------------------------------------
; debug_print_mem32_hex addr
; Macro: print 32-bit memory value at addr in hex (high word first) followed by CR/LF.
; Inputs:
;   addr - memory address of 32-bit value (little-endian)
; ------------------------------------------------------------
debug_print_mem32_hex macro addr
    PUSH HL
    LD   HL, (addr + 2)
    CALL debug_print_hl_hex
    LD   HL, (addr)
    CALL debug_print_hl_hex
    POP  HL
endm

; ------------------------------------------------------------
; debug_print_char
; Output a single character to ACIA, waiting for TDRE first.
; Inputs:
;   A  - character to output
; Outputs:
;   (none)
; Preserves: AF, BC, DE, HL
; ------------------------------------------------------------
debug_print_char:
    PUSH AF                     ; save character + flags
debug_print_char_wait:
    IN   A, (ACIA_CONTROL)     ; read status register
    AND  ACIA_TDRE             ; transmit data register empty?
    JP   Z, debug_print_char_wait
    POP  AF                     ; restore character
    OUT  (ACIA_DATA), A
    RET

; ------------------------------------------------------------
; debug_print_hl_hex
; Print HL as 4 hex digits followed by CR/LF.
; Inputs:
;   HL - value to print
; Outputs:
;   (none)
; Preserves: AF, BC, DE, HL
; ------------------------------------------------------------
debug_print_hl_hex:
    PUSH AF
    PUSH BC
    PUSH HL
    LD   B, H
    CALL debug_print_byte_hex
    LD   B, L
    CALL debug_print_byte_hex
    LD   A, 0x0D
    CALL debug_print_char
    LD   A, 0x0A
    CALL debug_print_char
    POP  HL
    POP  BC
    POP  AF
    RET

; ------------------------------------------------------------
; debug_print_byte_hex
; Print byte in B as 2 hex ASCII digits to ACIA.
; Inputs:
;   B  - byte to print
; Outputs:
;   (none)
; Preserves: AF, BC, DE, HL
; ------------------------------------------------------------
debug_print_byte_hex:
    PUSH AF                     ; preserve AF
    LD   A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x0F
    CALL debug_nibble_to_hex
    CALL debug_print_char
    LD   A, B
    AND  0x0F
    CALL debug_nibble_to_hex
    CALL debug_print_char
    POP  AF                     ; restore AF
    RET

; ------------------------------------------------------------
; debug_nibble_to_hex
; Convert low nibble of A to ASCII hex character in A.
; Inputs:
;   A  - value (low nibble used)
; Outputs:
;   A  - ASCII hex character ('0'-'9' or 'A'-'F')
; ------------------------------------------------------------
debug_nibble_to_hex:
    ADD  A, '0'
    CP   '9' + 1
    JP   C, debug_nibble_done
    ADD  A, 'A' - ('9' + 1)
debug_nibble_done:
    RET

; ------------------------------------------------------------
; debug_print_newline
; Print CR/LF to ACIA.
; Inputs:
;   (none)
; Outputs:
;   (none)
; Preserves: AF, BC, DE, HL
; ------------------------------------------------------------
debug_print_newline:
    PUSH AF
    LD   A, 0x0D
    CALL debug_print_char
    LD   A, 0x0A
    CALL debug_print_char
    POP  AF
    RET

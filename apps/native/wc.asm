; ============================================================
; wc.asm - Word, line, and byte count
; ============================================================
; Usage: WC <filename>
;
; Reads a file and displays the number of lines, words, and
; bytes. A word is any run of non-whitespace characters
; separated by spaces, tabs, CR, or LF.
;
; Output format: "  <lines>  <words>  <bytes> <filename>"
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point -- jump over the header
    JP   wc_main

    ; Header pad: 13 bytes (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; Entry point
; ============================================================
wc_main:
    ; Parse args: filename
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, wc_usage

    ; Upcase filename in-place
    LD   D, H
    LD   E, L
    LD   (wc_fname), DE
wc_upcase:
    LD   A, (HL)
    OR   A
    JP   Z, wc_upcase_done
    CP   ' '
    JP   Z, wc_upcase_term
    CP   'a'
    JP   C, wc_upcase_store
    CP   'z' + 1
    JP   NC, wc_upcase_store
    AND  0x5F
wc_upcase_store:
    LD   (HL), A
    INC  HL
    JP   wc_upcase
wc_upcase_term:
    LD   (HL), 0
wc_upcase_done:

    ; Open file
    LD   DE, (wc_fname)
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, wc_err_open

    ; Save handle
    LD   A, L
    LD   (wc_handle), A

    ; Get file size
    LD   B, A
    LD   DE, wc_filesize
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, wc_err_close

    ; Initialize counters
    LD   HL, 0
    LD   (wc_lines), HL
    LD   (wc_words), HL
    LD   (wc_bytes), HL
    XOR  A
    LD   (wc_bytes + 2), A
    LD   A, 1
    LD   (wc_in_space), A       ; start "in space" so first non-ws starts a word

    ; Copy filesize to bytes_left
    LD   HL, (wc_filesize)
    LD   (wc_bytes_left), HL
    LD   A, (wc_filesize + 2)
    LD   (wc_bytes_left + 2), A

    ; Copy filesize to byte count
    LD   HL, (wc_filesize)
    LD   (wc_bytes), HL
    LD   A, (wc_filesize + 2)
    LD   (wc_bytes + 2), A

    ; Set bufpos to 512 to force first read
    LD   HL, 512
    LD   (wc_bufpos), HL

; ============================================================
; Main counting loop
; ============================================================
wc_loop:
    ; Check if bytes_left == 0
    LD   HL, (wc_bytes_left)
    LD   A, (wc_bytes_left + 2)
    OR   H
    OR   L
    JP   Z, wc_print

    ; Get next byte
    CALL wc_getbyte
    JP   NZ, wc_err_close       ; I/O error

    ; Decrement bytes_left (3-byte)
    LD   HL, (wc_bytes_left)
    LD   A, L
    SUB  1
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    LD   (wc_bytes_left), HL
    LD   A, (wc_bytes_left + 2)
    SBC  A, 0
    LD   (wc_bytes_left + 2), A

    ; Process the character
    LD   A, (wc_char)

    ; Check for LF (newline)
    CP   0x0A
    JP   NZ, wc_not_lf
    ; Increment line count
    LD   HL, (wc_lines)
    INC  HL
    LD   (wc_lines), HL
wc_not_lf:

    ; Check if whitespace (space, tab, CR, LF)
    LD   A, (wc_char)
    CP   ' '
    JP   Z, wc_is_space
    CP   0x09                   ; tab
    JP   Z, wc_is_space
    CP   0x0D                   ; CR
    JP   Z, wc_is_space
    CP   0x0A                   ; LF
    JP   Z, wc_is_space

    ; Non-whitespace: if we were in space, this starts a new word
    LD   A, (wc_in_space)
    OR   A
    JP   Z, wc_loop             ; already in a word
    ; Transition from space to word
    XOR  A
    LD   (wc_in_space), A
    LD   HL, (wc_words)
    INC  HL
    LD   (wc_words), HL
    JP   wc_loop

wc_is_space:
    LD   A, 1
    LD   (wc_in_space), A
    JP   wc_loop

; ============================================================
; Print results
; ============================================================
wc_print:
    ; Close file first
    LD   A, (wc_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    ; Print "  <lines>  <words>  <bytes> <filename>\r\n"
    LD   DE, wc_spaces_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Print lines (16-bit)
    LD   HL, (wc_lines)
    CALL wc_print_u16

    LD   DE, wc_spaces_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Print words (16-bit)
    LD   HL, (wc_words)
    CALL wc_print_u16

    LD   DE, wc_spaces_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Print bytes (24-bit)
    LD   HL, (wc_bytes)
    LD   A, (wc_bytes + 2)
    CALL wc_print_u24

wc_print_name:
    ; Print " filename"
    LD   E, ' '
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    LD   DE, (wc_fname)
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Print CRLF
    LD   DE, wc_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; wc_print_u16 - Print unsigned 16-bit number in HL as decimal
; ============================================================
wc_print_u16:
    PUSH BC
    PUSH DE
    PUSH HL
    ; Convert to decimal digits on stack
    LD   DE, wc_numbuf + 5
    LD   (DE), A                ; doesn't matter, we'll null-terminate
    XOR  A
    LD   (DE), A                ; null terminator
    DEC  DE

    ; Special case: HL == 0
    LD   A, H
    OR   L
    JP   NZ, wc_p16_divloop
    LD   A, '0'
    LD   (DE), A
    JP   wc_p16_do_print

wc_p16_divloop:
    ; Divide HL by 10, remainder is next digit
    LD   A, H
    OR   L
    JP   Z, wc_p16_print

    ; HL / 10: repeated subtraction is simplest for 8080
    ; Use a proper 16-bit divide
    PUSH DE
    LD   DE, 10
    CALL wc_div16
    ; HL = quotient, A = remainder
    POP  DE
    ADD  A, '0'
    LD   (DE), A
    DEC  DE
    JP   wc_p16_divloop

wc_p16_print:
    INC  DE                      ; divloop leaves DE one before first digit
wc_p16_do_print:
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; wc_div16 - Divide HL by DE
; Returns: HL = quotient, A = remainder (low byte)
; Destroys: BC
; ============================================================
wc_div16:
    PUSH DE
    LD   B, H
    LD   C, L               ; BC = dividend
    LD   HL, 0              ; HL = quotient
    ; 16-bit division by repeated subtraction is too slow
    ; Use shift-and-subtract (long division)
    ; Actually for dividing by 10, let's use a proper algorithm
    ; BC = dividend, DE = divisor, HL = quotient
    LD   HL, 0              ; quotient
    LD   A, B               ; work with BC as dividend
    ; Standard 16/16 division
    ; Dividend in BC, divisor in DE, quotient in HL
    PUSH DE
    POP  DE                 ; DE = divisor (already there)
    ; Use restoring division: 16 bits
    LD   HL, 0              ; remainder
    LD   A, 16              ; bit counter
    LD   (wc_div_count), A
wc_div_loop:
    ; Shift BC left, shifting top bit into HL
    LD   A, C
    ADD  A, A               ; shift C left
    LD   C, A
    LD   A, B
    ADC  A, A               ; shift B left with carry
    LD   B, A
    LD   A, L
    ADC  A, A               ; shift L left with carry
    LD   L, A
    LD   A, H
    ADC  A, A
    LD   H, A
    ; Try subtract divisor from remainder (HL - DE)
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    JP   NC, wc_div_fits
    ; Doesn't fit, restore remainder
    ADD  HL, DE
    JP   wc_div_next
wc_div_fits:
    ; Fits: set bit 0 of quotient (C)
    INC  C
wc_div_next:
    LD   A, (wc_div_count)
    DEC  A
    LD   (wc_div_count), A
    JP   NZ, wc_div_loop
    ; BC = quotient, HL = remainder
    LD   A, L               ; remainder low byte
    LD   H, B
    LD   L, C               ; HL = quotient
    POP  DE
    RET

; ============================================================
; wc_print_u24 - Print unsigned 24-bit number as decimal
; Inputs: A = high byte, HL = low 16 bits
; ============================================================
wc_print_u24:
    PUSH BC
    PUSH DE
    PUSH HL
    ; Store 24-bit value
    LD   (wc_d24_val), HL
    LD   (wc_d24_val + 2), A
    ; Set up numbuf pointer at end
    LD   DE, wc_numbuf + 8
    XOR  A
    LD   (DE), A                ; null terminator
    DEC  DE
    ; Check if value == 0
    LD   A, (wc_d24_val + 2)
    LD   HL, (wc_d24_val)
    OR   H
    OR   L
    JP   NZ, wc_p24_divloop
    LD   A, '0'
    LD   (DE), A
    JP   wc_p24_do_print
wc_p24_divloop:
    ; Check if value == 0
    LD   A, (wc_d24_val + 2)
    LD   HL, (wc_d24_val)
    OR   H
    OR   L
    JP   Z, wc_p24_print
    ; Divide wc_d24_val by 10, remainder in A
    CALL wc_div24by10
    ADD  A, '0'
    LD   (DE), A
    DEC  DE
    JP   wc_p24_divloop
wc_p24_print:
    INC  DE                      ; divloop leaves DE one before first digit
wc_p24_do_print:
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; wc_div24by10 - Divide 24-bit wc_d24_val by 10 in place
; Returns: A = remainder
; Destroys: BC, HL
; ============================================================
wc_div24by10:
    ; 24-bit restoring division by 10
    ; Dividend in wc_d24_val (3 bytes, little-endian)
    ; Quotient replaces dividend, remainder returned in A
    ; Use HL as 16-bit remainder, shift dividend bits in from top
    LD   HL, 0              ; remainder
    LD   A, 24              ; bit counter
    LD   (wc_div_count), A
wc_d24_loop:
    ; Shift wc_d24_val left by 1 bit, top bit into carry
    LD   A, (wc_d24_val)
    ADD  A, A
    LD   (wc_d24_val), A
    LD   A, (wc_d24_val + 1)
    ADC  A, A
    LD   (wc_d24_val + 1), A
    LD   A, (wc_d24_val + 2)
    ADC  A, A
    LD   (wc_d24_val + 2), A
    ; Shift carry into remainder (HL)
    LD   A, L
    ADC  A, A
    LD   L, A
    LD   A, H
    ADC  A, A
    LD   H, A
    ; Try subtract 10 from remainder
    LD   A, L
    SUB  10
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    JP   NC, wc_d24_fits
    ; Doesn't fit, restore
    LD   A, L
    ADD  A, 10
    LD   L, A
    LD   A, H
    ADC  A, 0
    LD   H, A
    JP   wc_d24_next
wc_d24_fits:
    ; Fits: set bit 0 of quotient (lowest byte)
    LD   A, (wc_d24_val)
    INC  A
    LD   (wc_d24_val), A
wc_d24_next:
    LD   A, (wc_div_count)
    DEC  A
    LD   (wc_div_count), A
    JP   NZ, wc_d24_loop
    ; Remainder in L
    LD   A, L
    RET

; ============================================================
; wc_getbyte - Read next byte into wc_char
; Returns: Z if success, NZ if error
; ============================================================
wc_getbyte:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   HL, (wc_bufpos)
    LD   A, H
    CP   2
    JP   NC, wc_readblock
wc_gb_ready:
    LD   DE, wc_buf
    ADD  HL, DE
    LD   A, (HL)
    LD   (wc_char), A
    LD   HL, (wc_bufpos)
    INC  HL
    LD   (wc_bufpos), HL
    XOR  A                      ; Z = success
    POP  HL
    POP  DE
    POP  BC
    RET

wc_readblock:
    LD   A, (wc_handle)
    LD   B, A
    LD   DE, wc_buf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, wc_gb_err
    LD   HL, 0
    LD   (wc_bufpos), HL
    JP   wc_gb_ready

wc_gb_err:
    POP  HL
    POP  DE
    POP  BC
    OR   0xFF
    RET

; ============================================================
; Error handlers
; ============================================================
wc_err_open:
    LD   DE, wc_err_open_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

wc_err_close:
    LD   A, (wc_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, wc_err_read_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

wc_usage:
    LD   DE, wc_usage_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Strings
; ============================================================
wc_usage_str:     DEFB "Usage: WC <filename>", 0x0D, 0x0A, 0
wc_err_open_str:  DEFB "Error: cannot open file", 0x0D, 0x0A, 0
wc_err_read_str:  DEFB "Error: read failed", 0x0D, 0x0A, 0
wc_spaces_str:    DEFB "  ", 0
wc_crlf:          DEFB 0x0D, 0x0A, 0

; ============================================================
; Variables
; ============================================================
wc_fname:         DEFW 0
wc_handle:        DEFB 0
wc_filesize:      DEFS 3, 0
wc_bytes_left:    DEFS 3, 0
wc_lines:         DEFW 0
wc_words:         DEFW 0
wc_bytes:         DEFS 3, 0
wc_in_space:      DEFB 1
wc_bufpos:        DEFW 512
wc_char:          DEFB 0
wc_numbuf:        DEFS 9, 0
wc_div_count:     DEFB 0
wc_d24_val:       DEFS 3, 0
wc_buf:           DEFS 512, 0

; ============================================================
; debug.asm - Memory/IO Debug Tool for NostOS
; Provides DOS DEBUG-like commands for memory inspection,
; modification, and I/O port access.
;
; Commands:
;   D [addr]        - Dump 128 bytes of memory
;   E addr bb [..]  - Enter (write) bytes to memory
;   F start end bb  - Fill memory range with byte
;   G addr          - Go (call address, returns on RET)
;   I port          - Input: read byte from I/O port
;   O port bb       - Output: write byte to I/O port
;   Q               - Quit
;   ?               - Help
; ============================================================

    INCLUDE "../../src/include/syscall.asm"

    ORG 0

; ============================================================
; App header
; ============================================================
    JP   debug_main
    DEFS 13, 0

; ============================================================
; debug_main - entry point
; ============================================================
debug_main:
    LD   B, LOGDEV_ID_CONO
    LD   DE, debug_banner
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

; ============================================================
; debug_loop - main command loop
; ============================================================
debug_loop:
    LD   B, LOGDEV_ID_CONO
    LD   E, '-'
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    LD   B, LOGDEV_ID_CONI
    LD   DE, debug_buf
    LD   C, DEV_CREAD_STR
    CALL KERNELADDR
    CALL debug_crlf

    LD   HL, debug_buf
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_loop

    ; Uppercase
    CP   'a'
    JP   C, debug_dispatch
    CP   'z'+1
    JP   NC, debug_dispatch
    SUB  0x20

debug_dispatch:
    INC  HL
    CP   'D'
    JP   Z, debug_cmd_d
    CP   'E'
    JP   Z, debug_cmd_e
    CP   'F'
    JP   Z, debug_cmd_f
    CP   'G'
    JP   Z, debug_cmd_g
    CP   'I'
    JP   Z, debug_cmd_i
    CP   'O'
    JP   Z, debug_cmd_o
    CP   'Q'
    JP   Z, debug_cmd_q
    CP   '?'
    JP   Z, debug_cmd_help
    CP   'H'
    JP   Z, debug_cmd_help

    LD   DE, debug_msg_unknown
    CALL debug_puts
    JP   debug_loop

; ============================================================
; Common error handler
; ============================================================
debug_err_syntax:
    LD   DE, debug_msg_syntax
    CALL debug_puts
    JP   debug_loop

debug_err_range:
    LD   DE, debug_msg_range
    CALL debug_puts
    JP   debug_loop

; ============================================================
; Q - Quit
; ============================================================
debug_cmd_q:
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; ? / H - Help
; ============================================================
debug_cmd_help:
    LD   DE, debug_msg_help
    CALL debug_puts
    JP   debug_loop

; ============================================================
; D [address] - Dump 128 bytes of memory
; 8 lines of 16 bytes each, with hex and ASCII display.
; If no address given, continues from last dump position.
; ============================================================
debug_cmd_d:
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_d_go
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    PUSH HL
    EX   DE, HL
    LD   (debug_dump_addr), HL
    POP  HL

debug_d_go:
    LD   A, 8
    LD   (debug_d_count), A

debug_d_line:
    ; Print address
    LD   HL, (debug_dump_addr)
    CALL debug_print_hex16
    LD   A, ':'
    CALL debug_putchar
    LD   A, ' '
    CALL debug_putchar

    ; Print 16 hex bytes
    LD   HL, (debug_dump_addr)
    LD   C, 0

debug_d_hex:
    LD   A, (HL)
    INC  HL
    CALL debug_print_hex8
    INC  C
    LD   A, C
    CP   16
    JP   Z, debug_d_ascii_start
    CP   8
    JP   Z, debug_d_dash
    LD   A, ' '
    CALL debug_putchar
    JP   debug_d_hex

debug_d_dash:
    LD   A, '-'
    CALL debug_putchar
    JP   debug_d_hex

debug_d_ascii_start:
    LD   A, ' '
    CALL debug_putchar
    CALL debug_putchar

    ; Print ASCII representation
    LD   HL, (debug_dump_addr)
    LD   C, 16

debug_d_ascii:
    LD   A, (HL)
    INC  HL
    CP   0x20
    JP   C, debug_d_dot
    CP   0x7F
    JP   C, debug_d_printable

debug_d_dot:
    LD   A, '.'

debug_d_printable:
    CALL debug_putchar
    DEC  C
    JP   NZ, debug_d_ascii

    CALL debug_crlf

    ; Advance dump address by 16
    LD   HL, (debug_dump_addr)
    LD   DE, 16
    ADD  HL, DE
    LD   (debug_dump_addr), HL

    ; Decrement line counter
    LD   A, (debug_d_count)
    DEC  A
    LD   (debug_d_count), A
    JP   NZ, debug_d_line

    JP   debug_loop

; ============================================================
; E address byte [byte ...] - Enter bytes into memory
; Writes one or more bytes starting at the given address.
; ============================================================
debug_cmd_e:
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; Store target address
    PUSH HL
    EX   DE, HL
    LD   (debug_e_addr), HL
    POP  HL

debug_e_loop:
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_loop
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; Validate byte fits in 8 bits
    LD   A, D
    OR   A
    JP   NZ, debug_err_range
    ; Write byte at target address
    PUSH HL
    LD   HL, (debug_e_addr)
    LD   (HL), E
    INC  HL
    LD   (debug_e_addr), HL
    POP  HL
    JP   debug_e_loop

; ============================================================
; F start end byte - Fill memory range
; Fills memory from start through end (inclusive) with byte.
; ============================================================
debug_cmd_f:
    ; Parse start address
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    PUSH HL
    EX   DE, HL
    LD   (debug_f_start), HL
    POP  HL

    ; Parse end address
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    PUSH HL
    EX   DE, HL
    LD   (debug_f_end), HL
    POP  HL

    ; Parse fill byte
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; Validate byte fits in 8 bits
    LD   A, D
    OR   A
    JP   NZ, debug_err_range
    LD   A, E               ; fill byte value

    ; Verify start <= end
    PUSH AF
    LD   HL, (debug_f_end)
    EX   DE, HL             ; DE = end
    LD   HL, (debug_f_start) ; HL = start
    ; Compare: if end (DE) < start (HL), error
    LD   A, D
    CP   H
    JP   C, debug_f_err     ; end_hi < start_hi → error
    JP   NZ, debug_f_ok     ; end_hi > start_hi → ok
    LD   A, E
    CP   L
    JP   C, debug_f_err     ; end_lo < start_lo → error
debug_f_ok:
    POP  AF

debug_f_loop:
    LD   (HL), A
    ; Check if HL == DE (end reached)
    PUSH AF
    LD   A, H
    CP   D
    JP   NZ, debug_f_next
    LD   A, L
    CP   E
    JP   Z, debug_f_done

debug_f_next:
    POP  AF
    INC  HL
    JP   debug_f_loop

debug_f_done:
    POP  AF
    JP   debug_loop

debug_f_err:
    POP  AF
    JP   debug_err_syntax

; ============================================================
; G address - Go (call address)
; Calls the given address. If the code executes a RET,
; control returns to the debug prompt. SP is saved/restored.
; ============================================================
debug_cmd_g:
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; Save SP
    LD   HL, 0
    ADD  HL, SP
    LD   (debug_save_sp), HL
    ; Patch CALL target address
    LD   A, E
    LD   (debug_g_target+1), A
    LD   A, D
    LD   (debug_g_target+2), A

debug_g_target:
    CALL 0x0000

    ; Restore SP on return
    LD   HL, (debug_save_sp)
    LD   SP, HL
    JP   debug_loop

; ============================================================
; I port - Input from I/O port
; Reads a byte from the given port and displays it.
; ============================================================
debug_cmd_i:
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; Validate port fits in 8 bits
    LD   A, D
    OR   A
    JP   NZ, debug_err_range
    ; Self-modify IN instruction with port number
    LD   A, E
    LD   (debug_in_instr+1), A

debug_in_instr:
    IN   A, (0)

    CALL debug_print_hex8
    CALL debug_crlf
    JP   debug_loop

; ============================================================
; O port byte - Output to I/O port
; Writes a byte to the given port.
; ============================================================
debug_cmd_o:
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; Validate port fits in 8 bits
    LD   A, D
    OR   A
    JP   NZ, debug_err_range
    PUSH DE                  ; save port
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_o_err_syn  ; pop DE and report syntax error
    ; Validate byte fits in 8 bits
    LD   A, D
    OR   A
    JP   NZ, debug_o_err_rng ; pop DE and report range error
    POP  BC                  ; C = port (from saved E)
    ; Self-modify OUT instruction with port number
    LD   A, C
    LD   (debug_out_instr+1), A
    LD   A, E                ; value to write

debug_out_instr:
    OUT  (0), A

    JP   debug_loop

debug_o_err_syn:
    POP  DE
    JP   debug_err_syntax

debug_o_err_rng:
    POP  DE
    JP   debug_err_range

; ============================================================
; Utility: print character in A to console
; Preserves: BC, DE, HL
; ============================================================
debug_putchar:
    PUSH AF
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
    POP  AF
    RET

; ============================================================
; Utility: print null-terminated string at DE to console
; Preserves: BC, HL
; ============================================================
debug_puts:
    PUSH BC
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    POP  BC
    RET

; ============================================================
; Utility: print CR LF
; ============================================================
debug_crlf:
    LD   A, 0x0D
    CALL debug_putchar
    LD   A, 0x0A
    CALL debug_putchar
    RET

; ============================================================
; Utility: print A as 2-digit uppercase hex
; Preserves: BC, DE, HL
; ============================================================
debug_print_hex8:
    PUSH AF
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x0F
    CALL debug_print_nib
    POP  AF
    AND  0x0F
    CALL debug_print_nib
    RET

; ------------------------------------------------------------
; debug_print_nib - print low nibble of A as hex digit
; ------------------------------------------------------------
debug_print_nib:
    CP   10
    JP   C, debug_pn_dec
    ADD  A, 'A' - 10
    JP   debug_pn_out

debug_pn_dec:
    ADD  A, '0'

debug_pn_out:
    CALL debug_putchar
    RET

; ============================================================
; Utility: print HL as 4-digit uppercase hex
; Preserves: BC, DE, HL
; ============================================================
debug_print_hex16:
    LD   A, H
    CALL debug_print_hex8
    LD   A, L
    CALL debug_print_hex8
    RET

; ============================================================
; Utility: skip space characters at (HL)
; Advances HL past any spaces.
; ============================================================
debug_skip_spaces:
    LD   A, (HL)
    CP   ' '
    RET  NZ
    INC  HL
    JP   debug_skip_spaces

; ============================================================
; Utility: parse hex number from text at (HL)
; Inputs:
;   HL - pointer into text buffer
; Outputs:
;   DE - parsed value
;   HL - advanced past last hex digit
;   B  - digit count (0 = no digits found)
; ============================================================
debug_parse_hex:
    LD   DE, 0
    LD   B, 0

debug_ph_loop:
    LD   A, (HL)
    CP   '0'
    JP   C, debug_ph_done
    CP   '9'+1
    JP   C, debug_ph_digit
    ; Check A-F / a-f
    AND  0xDF
    CP   'A'
    JP   C, debug_ph_done
    CP   'F'+1
    JP   NC, debug_ph_done
    SUB  'A' - 10
    JP   debug_ph_add

debug_ph_digit:
    SUB  '0'

debug_ph_add:
    ; DE = DE * 16 + A
    PUSH AF
    EX   DE, HL             ; HL = accumulated value
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    EX   DE, HL             ; DE = shifted value, HL = buffer ptr
    POP  AF
    ADD  A, E
    LD   E, A
    LD   A, 0
    ADC  A, D
    LD   D, A
    INC  HL
    INC  B
    JP   debug_ph_loop

debug_ph_done:
    RET

; ============================================================
; String data
; ============================================================
debug_banner:
    DEFM "NostOS Debug"
    DEFB 0x0D, 0x0A
    DEFM "Type ? for help"
    DEFB 0x0D, 0x0A, 0

debug_msg_help:
    DEFM "D [addr]        Dump memory"
    DEFB 0x0D, 0x0A
    DEFM "E addr bb [..]  Enter bytes"
    DEFB 0x0D, 0x0A
    DEFM "F start end bb  Fill memory"
    DEFB 0x0D, 0x0A
    DEFM "G addr          Go (call)"
    DEFB 0x0D, 0x0A
    DEFM "I port          Input port"
    DEFB 0x0D, 0x0A
    DEFM "O port bb       Output port"
    DEFB 0x0D, 0x0A
    DEFM "Q               Quit"
    DEFB 0x0D, 0x0A, 0

debug_msg_unknown:
    DEFM "Unknown command"
    DEFB 0x0D, 0x0A, 0

debug_msg_syntax:
    DEFM "Syntax error"
    DEFB 0x0D, 0x0A, 0

debug_msg_range:
    DEFM "Out of range"
    DEFB 0x0D, 0x0A, 0

; ============================================================
; Variables
; ============================================================
debug_dump_addr: DEFW 0x0000
debug_e_addr:    DEFW 0x0000
debug_f_start:   DEFW 0x0000
debug_f_end:     DEFW 0x0000
debug_save_sp:   DEFW 0x0000
debug_d_count:   DEFB 0

debug_buf:       DEFS 256, 0

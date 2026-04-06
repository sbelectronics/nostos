; ============================================================
; cmd_hf.asm - HF / HEXDUMP command
; Displays a file as a traditional hex dump:
;   XXXX: XX XX XX XX XX XX XX XX XX XX XX XX XX XX XX XX  AAAAAAAAAAAAAAAA
; ============================================================

cmd_hf_handle       EQU EXEC_RAM_START         ; 1 byte: file handle
cmd_hf_rem_size     EQU EXEC_RAM_START + 1     ; 4 bytes: remaining bytes (little-endian)
cmd_hf_offset       EQU EXEC_RAM_START + 5     ; 2 bytes: current display address
cmd_hf_buffer       EQU EXEC_RAM_START + 7     ; 512 bytes: read buffer

; ------------------------------------------------------------
; cmd_hf: Handle HF / HEXDUMP command
; Inputs:
;   EXEC_ARGS_PTR - null-terminated filename argument
; Outputs:
;   (none)
; ------------------------------------------------------------
cmd_hf:
    XOR  A
    LD   (cmd_hf_handle), A
    LD   HL, 0
    LD   (cmd_hf_offset), HL

    ; Check for filename argument
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, cmd_hf_usage

    ; Open the file
    EX   DE, HL                     ; DE = path string
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_hf_open_error

    ; HL = file handle (physical device ID)
    LD   A, L
    LD   (cmd_hf_handle), A

    ; Get file size into cmd_hf_rem_size (4 bytes)
    LD   B, A                       ; B = file handle
    LD   DE, cmd_hf_rem_size
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_hf_io_error

; ---------------------------------------------------------------
; Outer loop: read 512-byte blocks until rem_size reaches zero.
; ---------------------------------------------------------------
cmd_hf_loop:
    ; Check rem_size == 0
    LD   HL, cmd_hf_rem_size
    LD   A, (HL)
    INC  HL
    OR   (HL)
    INC  HL
    OR   (HL)
    INC  HL
    OR   (HL)
    JP   Z, cmd_hf_done

    ; Read next block
    LD   A, (cmd_hf_handle)
    LD   B, A
    LD   DE, cmd_hf_buffer
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_hf_io_error

    ; bytes_in_block = min(512, rem_size)
    LD   A, (cmd_hf_rem_size + 2)
    OR   A
    JP   NZ, cmd_hf_blk_512
    LD   A, (cmd_hf_rem_size + 3)
    OR   A
    JP   NZ, cmd_hf_blk_512
    LD   A, (cmd_hf_rem_size + 1)
    CP   2
    JP   NC, cmd_hf_blk_512
    ; rem_size < 512: use exact count
    LD   A, (cmd_hf_rem_size)
    LD   C, A
    LD   A, (cmd_hf_rem_size + 1)
    LD   B, A
    JP   cmd_hf_process_blk

cmd_hf_blk_512:
    LD   BC, 512

cmd_hf_process_blk:
    ; BC = bytes_in_block; save for rem_size update after all rows processed
    PUSH BC                         ; stack: [block_count]
    LD   HL, cmd_hf_buffer          ; HL = current position in buffer

; ---------------------------------------------------------------
; Row loop: process BC bytes from buffer, 16 bytes per row.
; Stack: [block_count]
; HL = current buffer position
; BC = remaining bytes in block
; ---------------------------------------------------------------
cmd_hf_row_loop:
    LD   A, B
    OR   C
    JP   Z, cmd_hf_blk_done

    ; row_len = min(BC, 16)
    LD   A, B
    OR   A
    JP   NZ, cmd_hf_row16           ; B != 0 means BC >= 256; use 16
    ; B == 0: check C
    LD   A, C
    CP   17
    JP   NC, cmd_hf_row16           ; C >= 17; use 16
    ; A = C = row_len (1..16)
    JP   cmd_hf_have_rowlen

cmd_hf_row16:
    LD   A, 16

cmd_hf_have_rowlen:
    ; A = row_len (1..16), HL = row start, BC = remaining in block
    ; Stack: [block_count]
    PUSH BC                         ; stack: [remaining, block_count]
    LD   D, A                       ; D = row_len (preserved across putc/print_byte_hex calls)

    ; --- Print 4-digit hex address ---
    PUSH HL                         ; stack: [row_start, remaining, block_count]
    LD   HL, (cmd_hf_offset)
    CALL cmd_hf_print_word_hex      ; prints 4 hex digits; preserves all
    LD   E, ':'
    CALL cmd_hf_putc
    LD   E, ' '
    CALL cmd_hf_putc
    POP  HL                         ; HL = row_start; stack: [remaining, block_count]

    ; --- Print hex bytes (D iterations) ---
    PUSH HL                         ; stack: [row_start, remaining, block_count] (save for ASCII pass)
    LD   C, D                       ; C = loop counter = row_len
cmd_hf_hex_loop:
    LD   A, (HL)
    CALL cmd_hf_print_byte_hex      ; prints "XX"; preserves all registers
    LD   E, ' '
    CALL cmd_hf_putc                ; trailing space; preserves BC, DE, HL
    INC  HL
    DEC  C
    JP   NZ, cmd_hf_hex_loop
    ; HL = row_start + D (next row start position)

    ; --- Hex padding: (16-D)*3 spaces ---
    LD   A, 16
    SUB  D
    LD   C, A                       ; C = number of missing columns
    JP   cmd_hf_hex_pad_done
cmd_hf_hex_pad_loop:
    LD   E, ' '
    CALL cmd_hf_putc
    CALL cmd_hf_putc
    CALL cmd_hf_putc
    DEC  C
cmd_hf_hex_pad_done:
    LD   A, C
    OR   A
    JP   NZ, cmd_hf_hex_pad_loop

    ; --- 2 separator spaces ---
    LD   E, ' '
    CALL cmd_hf_putc
    CALL cmd_hf_putc

    ; --- Print ASCII chars (D iterations) ---
    POP  HL                         ; HL = row_start; stack: [remaining, block_count]
    LD   C, D                       ; C = loop counter = row_len
cmd_hf_ascii_loop:
    LD   A, (HL)
    CP   0x20
    JP   C, cmd_hf_ascii_dot        ; < 0x20: non-printable
    CP   0x7F
    JP   NC, cmd_hf_ascii_dot       ; >= 0x7F: non-printable
    LD   E, A
    JP   cmd_hf_ascii_emit
cmd_hf_ascii_dot:
    LD   E, '.'
cmd_hf_ascii_emit:
    CALL cmd_hf_putc                ; preserves BC, DE, HL
    INC  HL
    DEC  C
    JP   NZ, cmd_hf_ascii_loop
    ; HL = row_start + D (next row start position)

    ; --- ASCII padding: (16-D) spaces ---
    LD   A, 16
    SUB  D
    LD   C, A
    JP   cmd_hf_asc_pad_done
cmd_hf_asc_pad_loop:
    LD   E, ' '
    CALL cmd_hf_putc
    DEC  C
cmd_hf_asc_pad_done:
    LD   A, C
    OR   A
    JP   NZ, cmd_hf_asc_pad_loop

    ; --- CRLF ---
    ; exec_crlf clobbers DE (and possibly BC); save row_len (D) via stack
    LD   A, D
    PUSH AF                         ; stack: [AF(row_len), remaining, block_count]
    CALL exec_crlf                  ; preserves HL (via exec_puts)
    POP  AF                         ; stack: [remaining, block_count]
    LD   D, A                       ; restore row_len

    ; HL = next_row_start (preserved by exec_crlf via exec_puts)

    ; --- Advance display offset by D, without clobbering D ---
    ; Save next_row_start in BC (outer remaining is on stack, BC is free)
    LD   B, H
    LD   C, L                       ; BC = next_row_start
    LD   HL, (cmd_hf_offset)
    LD   A, L
    ADD  A, D
    LD   L, A
    JP   NC, cmd_hf_offset_nc
    INC  H
cmd_hf_offset_nc:
    LD   (cmd_hf_offset), HL
    ; Restore next_row_start to HL
    LD   H, B
    LD   L, C                       ; HL = next_row_start

    ; --- Restore outer remaining and subtract row_len ---
    POP  BC                         ; BC = remaining; stack: [block_count]
    LD   A, C
    SUB  D
    LD   C, A
    JP   NC, cmd_hf_row_nc
    DEC  B
cmd_hf_row_nc:
    JP   cmd_hf_row_loop

; ---------------------------------------------------------------
; Done with one block; update rem_size and continue outer loop.
; Stack: [block_count]
; ---------------------------------------------------------------
cmd_hf_blk_done:
    POP  BC                         ; BC = block_count; stack: []

    ; rem_size -= BC (32-bit little-endian subtract)
    LD   HL, (cmd_hf_rem_size)
    LD   A, L
    SUB  C
    LD   L, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (cmd_hf_rem_size), HL

    LD   HL, (cmd_hf_rem_size + 2)
    LD   A, L
    SBC  A, 0
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    LD   (cmd_hf_rem_size + 2), HL

    JP   cmd_hf_loop

cmd_hf_usage:
    LD   DE, msg_hf_usage
    CALL exec_puts
    RET

cmd_hf_open_error:
cmd_hf_io_error:
    CALL exec_print_error

cmd_hf_done:
    LD   A, (cmd_hf_handle)
    OR   A
    JP   Z, cmd_hf_exit             ; no handle to close

    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    XOR  A
    LD   (cmd_hf_handle), A
cmd_hf_exit:
    RET

; ---------------------------------------------------------------
; cmd_hf_putc
; Output a single character to CON.
; Inputs:
;   E  - character to output
; Outputs:
;   (none)
; Preserves: BC, DE, HL
; ---------------------------------------------------------------
cmd_hf_putc:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  DE
    POP  BC
    RET

; ---------------------------------------------------------------
; cmd_hf_print_word_hex
; Print HL as 4 hex ASCII digits to CON.
; Inputs:
;   HL - 16-bit value to print
; Outputs:
;   (none)
; Preserves: all registers
; ---------------------------------------------------------------
cmd_hf_print_word_hex:
    PUSH AF
    LD   A, H
    CALL cmd_hf_print_byte_hex
    LD   A, L
    CALL cmd_hf_print_byte_hex
    POP  AF
    RET

; ---------------------------------------------------------------
; cmd_hf_print_byte_hex
; Print byte in A as 2 hex ASCII digits to CON.
; Inputs:
;   A  - byte to print
; Outputs:
;   (none)
; Preserves: all registers
; ---------------------------------------------------------------
cmd_hf_print_byte_hex:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL
    ; Print high nibble
    PUSH AF                         ; save original byte on stack
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x0F
    CALL cmd_hf_nibble_to_ascii
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  AF                         ; restore original byte to A
    ; Print low nibble
    AND  0x0F
    CALL cmd_hf_nibble_to_ascii
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  DE
    POP  BC
    POP  AF
    RET

; ---------------------------------------------------------------
; cmd_hf_nibble_to_ascii
; Convert low nibble of A to ASCII hex character.
; Inputs:
;   A  - value (low nibble used)
; Outputs:
;   A  - ASCII character ('0'-'9' or 'A'-'F')
; ---------------------------------------------------------------
cmd_hf_nibble_to_ascii:
    ADD  A, '0'
    CP   '9' + 1
    JP   C, cmd_hf_nibble_done
    ADD  A, 'A' - ('9' + 1)
cmd_hf_nibble_done:
    RET

msg_hf_usage:
    DEFM "Usage: HEXDUMP <filename>", 0x0D, 0x0A, 0

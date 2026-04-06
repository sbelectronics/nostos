; ============================================================
; file.asm - NostOS block-buffered file I/O for Zealasm
; ============================================================
;
; NostOS uses 512-byte block I/O (DEV_BREAD/DEV_BWRITE).
; This module provides line-oriented input reading and
; buffered binary output writing on top of block I/O.
;
; Input: reads 512-byte blocks, extracts lines delimited by
;   LF (0x0A) or CR+LF (0x0D 0x0A). Returns one line at a
;   time via file_read_input_line.
;
; Output: buffers bytes in a 512-byte write buffer, flushing
;   to disk with DEV_BWRITE when full or when explicitly
;   flushed.
; ============================================================

; ------------------------------------------------------------
; file_open_input
; Open a source file for reading
; Inputs:
;   DE - null-terminated filename
; Outputs:
;   A - 0 on success, error code on failure
; ------------------------------------------------------------
file_open_input:
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    OR   A
    RET  NZ
    LD   A, L
    LD   (file_input_dev), A
    ; Initialize read buffer state
    LD   HL, 0
    LD   (file_buf_rem16), HL
    XOR  A
    RET

; ------------------------------------------------------------
; file_open_output
; Create an output file for writing
; Inputs:
;   DE - null-terminated filename (may include drive prefix)
; Outputs:
;   A - 0 on success, error code on failure
; ------------------------------------------------------------
file_open_output:
    ; Parse drive letter and path component from filename
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR
    OR   A
    RET  NZ
    ; L = device ID, DE = path component (filename without drive)
    LD   B, L
    LD   C, DEV_FCREATE
    CALL KERNELADDR
    OR   A
    RET  NZ
    LD   A, L
    LD   (file_output_dev), A
    LD   HL, 0
    LD   (file_wbuf_pos), HL
    XOR  A
    RET

; ------------------------------------------------------------
; file_read_input_line
; Read the next line from the input file
; Inputs: none
; Outputs:
;   HL - pointer to line buffer (null-terminated)
;   C  - length of line (without null)
;   A  - 0 on success, ERR_EOF if no more lines
; Alters:
;   A, BC, DE, HL
; ------------------------------------------------------------
file_read_input_line:
    LD   C, 0               ; character count
    LD   DE, file_line_buf
_file_readline_loop:
    CALL _file_read_next_char
    CP   ERR_EOF
    JP   Z, _file_readline_eof
    OR   A
    JP   NZ, _file_readline_err
    ; B = character read
    LD   A, B
    CP   0x0A               ; LF = end of line
    JP   Z, _file_readline_end
    CP   0x0D               ; CR = skip
    JP   Z, _file_readline_loop
    ; Store character if room
    LD   A, C
    CP   ZA_LINE_MAX - 1
    JP   NC, _file_readline_loop
    LD   A, B
    LD   (DE), A
    INC  DE
    INC  C
    JP   _file_readline_loop
_file_readline_eof:
    LD   A, C
    OR   A
    JP   Z, _file_readline_real_eof
_file_readline_end:
    XOR  A
    LD   (DE), A
    LD   HL, file_line_buf
    RET
_file_readline_real_eof:
    LD   A, ERR_EOF
    RET
_file_readline_err:
    RET

; ------------------------------------------------------------
; _file_read_next_char
; Read next character from input (16-bit block-buffered)
; Outputs:
;   A - 0 on success, ERR_EOF on end of file, error code else
;   B - character read (if success)
; Alters:
;   A, B, HL
; ------------------------------------------------------------
_file_read_next_char:
    LD   HL, (file_buf_rem16)
    LD   A, H
    OR   L
    JP   Z, _file_read_reload
    ; Decrement remaining
    DEC  HL
    LD   (file_buf_rem16), HL
    ; Get next char from buffer
    LD   HL, (file_buf_ptr)
    LD   B, (HL)
    INC  HL
    LD   (file_buf_ptr), HL
    XOR  A
    RET
_file_read_reload:
    ; Read next 512-byte block from file
    PUSH DE
    PUSH BC
    LD   A, (file_input_dev)
    LD   B, A
    LD   C, DEV_BREAD
    LD   DE, file_read_buf
    CALL KERNELADDR
    CP   ERR_EOF
    JP   Z, _file_read_eof
    OR   A
    JP   NZ, _file_read_err
    ; Block read successful — 512 bytes available
    LD   HL, 512
    LD   (file_buf_rem16), HL
    LD   HL, file_read_buf
    LD   (file_buf_ptr), HL
    POP  BC
    POP  DE
    JP   _file_read_next_char
_file_read_eof:
    POP  BC
    POP  DE
    LD   A, ERR_EOF
    RET
_file_read_err:
    POP  BC
    POP  DE
    RET

; ------------------------------------------------------------
; file_write_output
; Write bytes to the output file (block-buffered)
; Inputs:
;   HL - buffer of bytes to write
;   BC - number of bytes
; Outputs:
;   A - 0 on success, error code on failure
; Alters:
;   A, BC, DE, HL
; ------------------------------------------------------------
file_write_output:
    LD   A, B
    OR   C
    RET  Z
_file_write_byte_loop:
    ; Copy one byte into write buffer
    LD   A, (HL)
    PUSH HL
    PUSH BC
    ; Get write position in buffer
    LD   HL, file_write_buf
    LD   BC, (file_wbuf_pos)
    ADD  HL, BC
    LD   (HL), A
    ; Increment position
    INC  BC
    LD   (file_wbuf_pos), BC
    ; Check if buffer full (pos >= 512 = 0x0200)
    LD   A, B
    CP   2
    JP   C, _file_write_not_full
    ; Flush full block
    CALL _file_flush_block
    OR   A
    JP   NZ, _file_write_fail
_file_write_not_full:
    POP  BC
    POP  HL
    INC  HL
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, _file_write_byte_loop
    XOR  A
    RET
_file_write_fail:
    POP  BC
    POP  HL
    RET

; Flush write buffer as one 512-byte block
_file_flush_block:
    LD   A, (file_output_dev)
    LD   B, A
    LD   C, DEV_BWRITE
    LD   DE, file_write_buf
    CALL KERNELADDR
    OR   A
    RET  NZ
    LD   HL, 0
    LD   (file_wbuf_pos), HL
    XOR  A
    RET

; ------------------------------------------------------------
; file_flush_output
; Flush remaining bytes (zero-pad to 512, then write block)
; Outputs:
;   A - 0 on success, error code on failure
; ------------------------------------------------------------
file_flush_output:
    LD   HL, (file_wbuf_pos)
    LD   A, H
    OR   L
    RET  Z                  ; nothing to flush
    ; Zero-pad remainder of buffer
    LD   DE, file_write_buf
    ADD  HL, DE             ; HL = first empty byte
    ; Calculate bytes to zero: 512 - pos
    LD   BC, (file_wbuf_pos)
    PUSH HL
    LD   HL, 512
    LD   A, L
    SUB  C
    LD   C, A
    LD   A, H
    SBC  A, B
    LD   B, A               ; BC = bytes to zero
    POP  HL
_file_flush_zero:
    LD   A, B
    OR   C
    JP   Z, _file_flush_write
    XOR  A
    LD   (HL), A
    INC  HL
    DEC  BC
    JP   _file_flush_zero
_file_flush_write:
    JP   _file_flush_block

; ------------------------------------------------------------
; file_set_output_size
; Set the output file size after writing
; Inputs:
;   DE - file size in bytes (16-bit)
; Outputs:
;   A - 0 on success
; ------------------------------------------------------------
file_set_output_size:
    ; DE = size (16-bit). DEV_BSETSIZE expects DE = pointer to 4-byte buffer.
    LD   A, E
    LD   (file_size_buf), A
    LD   A, D
    LD   (file_size_buf + 1), A
    XOR  A
    LD   (file_size_buf + 2), A
    LD   (file_size_buf + 3), A
    LD   A, (file_output_dev)
    LD   B, A
    LD   C, DEV_BSETSIZE
    LD   DE, file_size_buf
    CALL KERNELADDR
    RET

; ------------------------------------------------------------
; file_close_input_output
; Close both input and output files
; ------------------------------------------------------------
file_close_input_output:
    LD   A, (file_input_dev)
    OR   A
    JP   Z, _file_close_output
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
_file_close_output:
    LD   A, (file_output_dev)
    OR   A
    RET  Z
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    RET

; ============================================================
; Data
; ============================================================
file_input_dev:     DEFB 0
file_output_dev:    DEFB 0
file_size_buf:      DEFS 4, 0   ; 4-byte buffer for DEV_BSETSIZE
file_buf_rem16:     DEFW 0      ; bytes remaining in read buffer
file_buf_ptr:       DEFW 0      ; pointer into read buffer
file_wbuf_pos:      DEFW 0      ; current position in write buffer
file_line_buf:      DEFS ZA_LINE_MAX + 1, 0
file_read_buf:      DEFS 512, 0
file_write_buf:     DEFS 512, 0

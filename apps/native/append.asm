; ============================================================
; append.asm - APPEND command: append text to a file
; ============================================================
; Usage: APPEND <filename> <text...>
;
; If the file does not exist, it is created. If it exists, it
; is opened. The remaining argument text is appended at the
; byte level, followed by CR/LF. This may involve reading a
; partial last block, inserting bytes, and writing back.
;
; Algorithm:
;   1. Parse filename (upcase, null-terminate) and text
;   2. Open or create file
;   3. BGETSIZE to get current filesize (3 bytes)
;   4. Compute block = filesize >> 9, byte_offset = filesize & 0x1FF
;   5. BSEEK to that block
;   6. If byte_offset > 0: BREAD to read partial block, BSEEK back
;   7. Copy text bytes into buffer at byte_offset, BWRITE on overflow
;   8. Append CR/LF the same way
;   9. BWRITE final partial block (zero-fill remainder)
;  10. BSETSIZE to old_filesize + bytes_written
;  11. Close and exit
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header
    JP   ap_main

    ; Header pad: 13 bytes (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; Entry point (0x0810)
; ============================================================
ap_main:
    ; Parse args: first token = filename, rest = text
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, ap_usage

    ; --- Token 1: filename ---
    ; Upcase and null-terminate the filename in the input buffer
    LD   D, H
    LD   E, L                       ; DE = filename start
    ; Save filename pointer
    LD   (ap_fname_ptr), DE
ap_upcase_fname:
    LD   A, (HL)
    OR   A
    JP   Z, ap_fname_done           ; end of args (no text)
    CP   ' '
    JP   Z, ap_fname_delim
    ; Upcase a-z
    CP   'a'
    JP   C, ap_upcase_store
    CP   'z' + 1
    JP   NC, ap_upcase_store
    AND  0x5F                       ; make uppercase
ap_upcase_store:
    LD   (HL), A
    INC  HL
    JP   ap_upcase_fname

ap_fname_delim:
    LD   (HL), 0                    ; null-terminate filename
    INC  HL
    ; Skip spaces to find text start
ap_skip_spaces:
    LD   A, (HL)
    CP   ' '
    JP   NZ, ap_text_found
    INC  HL
    JP   ap_skip_spaces

ap_fname_done:
    ; No text provided - just append CR/LF
    ; HL points to the null terminator

ap_text_found:
    ; HL = start of text (or null if no text)
    LD   (ap_text_ptr), HL

    ; --- Open or create file ---
    ; Try SYS_GLOBAL_OPENFILE first
    LD   DE, (ap_fname_ptr)
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   Z, ap_file_opened

    ; Not found - create it
    CP   ERR_NOT_FOUND
    JP   NZ, ap_error

    ; Resolve device from filename, then create
    LD   DE, (ap_fname_ptr)
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR             ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, ap_error
    LD   B, L                   ; B = device ID for DEV_FCREATE
    LD   C, DEV_FCREATE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ap_error

ap_file_opened:
    ; L = file handle (device ID)
    LD   A, L
    LD   (ap_handle), A

    ; --- Get current file size (3 bytes) ---
    LD   B, A
    LD   DE, ap_filesize
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ap_error_close

    ; --- Compute block number and byte offset ---
    ; block = filesize >> 9 = filesize[1..2] >> 1 (with filesize[0] high bit into [1])
    ; byte_offset = filesize & 0x1FF = { filesize[1] & 0x01, filesize[0] }
    LD   A, (ap_filesize + 1)
    LD   L, A
    LD   A, (ap_filesize + 2)
    LD   H, A
    ; HL = filesize[2:1]; shift right 1 to get block number
    ; (filesize >> 9) = (filesize[2:1] >> 1)
    LD   A, H
    RRA                              ; carry = bit0 of H
    LD   H, A
    LD   A, L
    RRA                              ; shift in carry from H
    LD   L, A
    ; HL = block number (filesize >> 9)
    ; But we need to also handle bit 0 of filesize[1] as part of byte offset
    ; Redo: byte_offset = filesize[0] + (filesize[1] & 1) * 256
    ; Let's compute byte_offset first
    LD   A, (ap_filesize + 1)
    AND  0x01                        ; high bit of byte offset
    LD   (ap_bufpos + 1), A
    LD   A, (ap_filesize)
    LD   (ap_bufpos), A
    ; ap_bufpos = byte offset within block (0-511)

    ; Now compute block number properly
    LD   A, (ap_filesize + 1)
    LD   L, A
    LD   A, (ap_filesize + 2)
    LD   H, A
    ; Shift HL right by 1: block = filesize[2:1] >> 1
    LD   A, H
    OR   A                           ; clear carry
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A
    ; HL = block number

    ; --- BSEEK to block ---
    LD   D, H
    LD   E, L                       ; DE = block number
    LD   A, (ap_handle)
    LD   B, A
    LD   C, DEV_BSEEK
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ap_error_close

    ; --- If byte_offset > 0, read the partial block ---
    LD   HL, (ap_bufpos)
    LD   A, H
    OR   L
    JP   Z, ap_start_write          ; offset is 0, no partial block to read

    ; Read the current last block into ap_buf
    LD   A, (ap_handle)
    LD   B, A
    LD   DE, ap_buf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ap_error_close

    ; Seek back to same block (BREAD auto-advanced)
    ; Recompute block number
    LD   A, (ap_filesize + 1)
    LD   L, A
    LD   A, (ap_filesize + 2)
    LD   H, A
    OR   A                           ; clear carry
    LD   A, H
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A
    LD   D, H
    LD   E, L
    LD   A, (ap_handle)
    LD   B, A
    LD   C, DEV_BSEEK
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ap_error_close

ap_start_write:
    ; --- Initialize bytes-written counter ---
    LD   HL, 0
    LD   (ap_written), HL
    LD   (ap_written + 2), A        ; A=0 from CP ERR_SUCCESS

    ; --- Write text bytes ---
    LD   HL, (ap_text_ptr)
ap_write_loop:
    LD   A, (HL)
    OR   A
    JP   Z, ap_write_crlf           ; end of text string
    PUSH HL
    CALL ap_putbyte
    POP  HL
    INC  HL
    JP   ap_write_loop

ap_write_crlf:
    ; Append CR
    LD   A, 0x0D
    CALL ap_putbyte
    ; Append LF
    LD   A, 0x0A
    CALL ap_putbyte

    ; --- Flush final partial block ---
    CALL ap_flush

    ; --- Update filesize: new_size = old_size + bytes_written ---
    ; 3-byte addition
    LD   A, (ap_filesize)
    LD   C, A
    LD   A, (ap_written)
    ADD  A, C
    LD   (ap_newsize), A

    LD   A, (ap_filesize + 1)
    LD   C, A
    LD   A, (ap_written + 1)
    ADC  A, C
    LD   (ap_newsize + 1), A

    LD   A, (ap_filesize + 2)
    LD   C, A
    LD   A, (ap_written + 2)
    ADC  A, C
    LD   (ap_newsize + 2), A

    ; BSETSIZE
    LD   A, (ap_handle)
    LD   B, A
    LD   DE, ap_newsize
    LD   C, DEV_BSETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ap_error_close

    ; --- Close file ---
    LD   A, (ap_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    ; Done
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; ap_putbyte - Write one byte to the buffer, flushing if full
; Input: A = byte to write
; ============================================================
ap_putbyte:
    PUSH AF
    ; Store byte at ap_buf[ap_bufpos]
    LD   HL, (ap_bufpos)
    LD   DE, ap_buf
    ADD  HL, DE                     ; HL = &ap_buf[bufpos]
    POP  AF
    LD   (HL), A

    ; Increment bytes-written counter (3 bytes)
    LD   HL, ap_written
    INC  (HL)
    JP   NZ, ap_putbyte_noinc1
    INC  HL
    INC  (HL)
    JP   NZ, ap_putbyte_noinc1
    INC  HL
    INC  (HL)
ap_putbyte_noinc1:

    ; Increment bufpos
    LD   HL, (ap_bufpos)
    INC  HL
    LD   (ap_bufpos), HL

    ; Check if bufpos == 512 (H == 2, L == 0)
    LD   A, H
    CP   2
    RET  NZ                         ; not full yet

    ; Buffer full - flush it
    CALL ap_flush_block
    RET

; ============================================================
; ap_flush_block - Write a full 512-byte block and reset bufpos
; ============================================================
ap_flush_block:
    LD   A, (ap_handle)
    LD   B, A
    LD   DE, ap_buf
    LD   C, DEV_BWRITE
    CALL KERNELADDR
    LD   HL, 0
    LD   (ap_bufpos), HL
    RET

; ============================================================
; ap_flush - Flush remaining bytes in buffer (zero-fill rest)
; ============================================================
ap_flush:
    LD   HL, (ap_bufpos)
    LD   A, H
    OR   L
    RET  Z                          ; nothing to flush

    ; Zero-fill from bufpos to 512
    LD   DE, ap_buf
    ADD  HL, DE                     ; HL = &ap_buf[bufpos]

    ; Calculate remaining = 512 - bufpos
    LD   A, (ap_bufpos)
    LD   C, A
    LD   A, 0
    SUB  C
    LD   C, A                       ; C = 256 - bufpos_low (low byte of remaining)
    LD   A, (ap_bufpos + 1)
    LD   B, A
    LD   A, 1
    SBC  A, B
    LD   B, A                       ; B = high byte of remaining

    ; If remaining == 0 (bufpos was 0), skip — already checked above
    ; Zero-fill loop
ap_flush_zero:
    LD   (HL), 0
    INC  HL
    DEC  C
    JP   NZ, ap_flush_zero
    DEC  B
    JP   P, ap_flush_zero

    ; Write the block
    JP   ap_flush_block

; ============================================================
; Error handlers
; ============================================================
ap_error_close:
    PUSH AF
    LD   A, (ap_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    POP  AF
ap_error:
    ; Print error message
    PUSH AF
    LD   DE, ap_msg_error
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  AF
    ; Print error code as decimal
    LD   L, A
    LD   H, 0
    CALL ap_print_dec16
    LD   DE, ap_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

ap_usage:
    LD   DE, ap_msg_usage
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; ap_print_dec16 - Print HL as unsigned decimal
; ============================================================
ap_print_dec16:
    PUSH HL
    PUSH DE
    PUSH BC
    LD   B, 0                       ; digit count
ap_pd_divloop:
    PUSH BC
    LD   DE, 0                      ; quotient
    LD   B, 16                      ; 16 iterations
ap_pd_div10:
    ADD  HL, HL
    LD   A, E
    RLA
    LD   E, A
    LD   A, D
    RLA
    LD   D, A
    LD   A, E
    SUB  10
    JP   C, ap_pd_skip
    LD   E, A
    INC  HL
ap_pd_skip:
    DEC  B
    JP   NZ, ap_pd_div10
    POP  BC
    LD   A, E
    ADD  A, '0'
    PUSH AF
    INC  B
    LD   A, H
    OR   L
    JP   NZ, ap_pd_divloop
ap_pd_print:
    POP  AF
    PUSH BC
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    DEC  B
    JP   NZ, ap_pd_print
    POP  BC
    POP  DE
    POP  HL
    RET

; ============================================================
; Variables
; ============================================================
ap_fname_ptr:   DEFW 0              ; pointer to filename in input buffer
ap_text_ptr:    DEFW 0              ; pointer to text in input buffer
ap_handle:      DEFB 0              ; file handle (device ID)
ap_filesize:    DEFS 3, 0           ; original file size (3 bytes)
ap_newsize:     DEFS 3, 0           ; new file size (3 bytes)
ap_bufpos:      DEFW 0              ; current position in write buffer (0-511)
ap_written:     DEFS 3, 0           ; bytes written counter (3 bytes)

; ============================================================
; String data
; ============================================================
ap_msg_usage:   DEFM "Usage: APPEND <file> <text>", 0x0D, 0x0A, 0
ap_msg_error:   DEFM "Error: ", 0
ap_msg_crlf:    DEFM 0x0D, 0x0A, 0

; ============================================================
; I/O buffer (512 bytes) - must be last
; ============================================================
ap_buf:         DEFS 512, 0

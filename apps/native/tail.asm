; ============================================================
; tail.asm - Display last N lines of a file
; ============================================================
; Usage: TAIL [-N] <filename>
;
; Displays the last N lines of a file (default 10).
;
; Algorithm:
;   1. Parse optional -N and filename from args
;   2. Open file, get file size
;   3. First pass: scan file counting newlines, recording byte
;      offset of each line start in a circular buffer
;   4. Second pass: seek to the right position, print to EOF
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    JP   tail_main
    DEFS 13, 0

TAIL_DEFAULT_LINES  EQU 10
TAIL_MAX_LINES      EQU 50      ; max lines we can track

; ============================================================
; Entry point
; ============================================================
tail_main:
    ; Default line count
    LD   A, TAIL_DEFAULT_LINES
    LD   (tail_nlines), A

    ; Parse args
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, tail_usage

    ; Check for -N option
    CP   '-'
    JP   NZ, tail_parse_fname
    INC  HL
    ; Parse decimal number after '-'
    XOR  A
    LD   (tail_nlines), A
tail_parse_num:
    LD   A, (HL)
    CP   '0'
    JP   C, tail_num_done
    CP   '9' + 1
    JP   NC, tail_num_done
    ; digit: nlines = nlines * 10 + digit
    SUB  '0'
    LD   B, A               ; B = new digit
    LD   A, (tail_nlines)
    ; Multiply by 10: A*10 = A*8 + A*2
    LD   C, A
    ADD  A, A               ; A*2
    JP   C, tail_num_clamp
    ADD  A, A               ; A*4
    JP   C, tail_num_clamp
    ADD  A, C               ; A*5
    JP   C, tail_num_clamp
    ADD  A, A               ; A*10
    JP   C, tail_num_clamp
    ADD  A, B               ; A*10 + digit
    JP   C, tail_num_clamp
    LD   (tail_nlines), A
    INC  HL
    JP   tail_parse_num
tail_num_clamp:
    LD   A, TAIL_MAX_LINES
    LD   (tail_nlines), A
    INC  HL
    JP   tail_parse_num
tail_num_done:
    ; Skip space between -N and filename
    LD   A, (HL)
    CP   ' '
    JP   NZ, tail_parse_fname
    INC  HL
    JP   tail_num_done

tail_parse_fname:
    ; HL points to filename
    LD   A, (HL)
    OR   A
    JP   Z, tail_usage
    LD   D, H
    LD   E, L
    LD   (tail_fname), DE
    ; Upcase filename in-place
tail_upcase:
    LD   A, (HL)
    OR   A
    JP   Z, tail_upcase_done
    CP   ' '
    JP   Z, tail_upcase_term
    CP   'a'
    JP   C, tail_upcase_store
    CP   'z' + 1
    JP   NC, tail_upcase_store
    AND  0x5F
tail_upcase_store:
    LD   (HL), A
    INC  HL
    JP   tail_upcase
tail_upcase_term:
    LD   (HL), 0
tail_upcase_done:

    ; Clamp nlines to TAIL_MAX_LINES
    LD   A, (tail_nlines)
    OR   A
    JP   Z, tail_usage          ; -0 makes no sense
    CP   TAIL_MAX_LINES + 1
    JP   C, tail_nlines_ok
    LD   A, TAIL_MAX_LINES
    LD   (tail_nlines), A
tail_nlines_ok:

    ; Open file
    LD   DE, (tail_fname)
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, tail_err_open
    LD   A, L
    LD   (tail_handle), A

    ; Get file size
    LD   B, A
    LD   DE, tail_filesize
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, tail_err_close

    ; Check for empty file
    LD   HL, (tail_filesize)
    LD   A, (tail_filesize + 2)
    OR   H
    OR   L
    JP   Z, tail_done

    ; Initialize circular buffer
    ; Each entry is 3 bytes (file byte offset of line start)
    ; We track up to nlines entries; entry 0 = offset 0 (start of file)
    LD   HL, 0
    LD   (tail_cbuf), HL
    XOR  A
    LD   (tail_cbuf + 2), A
    LD   (tail_cb_idx), A       ; current write index = 0
    LD   A, (tail_nlines)
    LD   (tail_cb_size), A      ; circular buffer size = nlines
    LD   A, 1
    LD   (tail_cb_count), A     ; 1 entry so far (offset 0)

    ; Initialize bytes_left = filesize
    LD   HL, (tail_filesize)
    LD   (tail_bytes_left), HL
    LD   A, (tail_filesize + 2)
    LD   (tail_bytes_left + 2), A

    ; Initialize file position counter
    LD   HL, 0
    LD   (tail_fpos), HL
    XOR  A
    LD   (tail_fpos + 2), A

    ; Set bufpos to 512 to force first read
    LD   HL, 512
    LD   (tail_bufpos), HL

    ; ============================================================
    ; Pass 1: scan file for newlines, record line starts
    ; ============================================================
tail_scan:
    ; Check bytes_left
    LD   HL, (tail_bytes_left)
    LD   A, (tail_bytes_left + 2)
    OR   H
    OR   L
    JP   Z, tail_scan_done

    ; Get next byte
    CALL tail_getbyte
    JP   NZ, tail_err_close

    ; Decrement bytes_left
    LD   HL, (tail_bytes_left)
    LD   A, L
    SUB  1
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    LD   (tail_bytes_left), HL
    LD   A, (tail_bytes_left + 2)
    SBC  A, 0
    LD   (tail_bytes_left + 2), A

    ; Increment file position
    LD   HL, (tail_fpos)
    INC  HL
    LD   (tail_fpos), HL
    LD   A, H
    OR   L
    JP   NZ, tail_scan_check     ; no overflow of low 16 bits
    LD   A, (tail_fpos + 2)
    INC  A
    LD   (tail_fpos + 2), A
tail_scan_check:

    ; Check for LF
    LD   A, (tail_char)
    CP   0x0A
    JP   NZ, tail_scan

    ; Record the NEXT byte's position as a line start
    ; (the byte after this LF is the start of the next line)
    ; But only if there are bytes left (otherwise it's trailing newline)
    LD   HL, (tail_bytes_left)
    LD   A, (tail_bytes_left + 2)
    OR   H
    OR   L
    JP   Z, tail_scan           ; at end, don't record

    ; Advance circular buffer index
    LD   A, (tail_cb_idx)
    INC  A
    LD   B, A
    LD   A, (tail_cb_size)
    CP   B
    JP   NZ, tail_no_wrap
    LD   B, 0                   ; wrap around
tail_no_wrap:
    LD   A, B
    LD   (tail_cb_idx), A

    ; Store fpos at cbuf[idx]
    ; Offset in buffer = idx * 3
    LD   A, (tail_cb_idx)
    LD   L, A
    LD   H, 0
    LD   D, H
    LD   E, L                   ; DE = idx
    ADD  HL, HL                 ; HL = idx*2
    ADD  HL, DE                 ; HL = idx*3
    LD   DE, tail_cbuf
    ADD  HL, DE                 ; HL = &cbuf[idx]

    ; Store 3-byte fpos
    LD   A, (tail_fpos)
    LD   (HL), A
    INC  HL
    LD   A, (tail_fpos + 1)
    LD   (HL), A
    INC  HL
    LD   A, (tail_fpos + 2)
    LD   (HL), A

    ; Increment entry count (cap at cb_size)
    LD   A, (tail_cb_count)
    LD   B, A
    LD   A, (tail_cb_size)
    CP   B
    JP   Z, tail_scan           ; already full, count stays at max
    LD   A, B
    INC  A
    LD   (tail_cb_count), A
    JP   tail_scan

    ; ============================================================
    ; Pass 1 done: determine where to start printing
    ; ============================================================
tail_scan_done:
    ; If total lines <= nlines, print from start (offset 0)
    ; cb_count = min(total_lines+1, cb_size)
    ; The oldest entry in the circular buffer is the start position
    ; If cb_count < cb_size, the oldest is at index 0
    ; If cb_count == cb_size, the oldest is at (cb_idx + 1) % cb_size

    LD   A, (tail_cb_count)
    LD   B, A
    LD   A, (tail_cb_size)
    CP   B
    JP   NZ, tail_use_zero      ; not full, start from offset 0

    ; Buffer is full: oldest = (cb_idx + 1) % cb_size
    LD   A, (tail_cb_idx)
    INC  A
    LD   B, A
    LD   A, (tail_cb_size)
    CP   B
    JP   NZ, tail_oldest_ok
    LD   B, 0                   ; wrap
tail_oldest_ok:
    ; B = oldest index, read cbuf[B]
    LD   A, B
    JP   tail_read_start

tail_use_zero:
    XOR  A                      ; index 0
tail_read_start:
    ; A = index into cbuf
    LD   L, A
    LD   H, 0
    LD   D, H
    LD   E, L
    ADD  HL, HL                 ; *2
    ADD  HL, DE                 ; *3
    LD   DE, tail_cbuf
    ADD  HL, DE                 ; HL = &cbuf[idx]

    ; Read 3-byte start offset
    LD   A, (HL)
    LD   (tail_start_off), A
    INC  HL
    LD   A, (HL)
    LD   (tail_start_off + 1), A
    INC  HL
    LD   A, (HL)
    LD   (tail_start_off + 2), A

    ; ============================================================
    ; Pass 2: seek to start_off and print to EOF
    ; ============================================================
    ; Compute block number = start_off >> 9
    LD   A, (tail_start_off + 1)
    LD   L, A
    LD   A, (tail_start_off + 2)
    LD   H, A
    ; Shift HL right by 1
    OR   A                      ; clear carry
    LD   A, H
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A
    ; HL = block number

    ; Seek to block
    LD   D, H
    LD   E, L
    LD   A, (tail_handle)
    LD   B, A
    LD   C, DEV_BSEEK
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, tail_err_close

    ; Compute byte offset within block = start_off & 0x1FF
    LD   A, (tail_start_off)
    LD   (tail_skip_bytes), A
    LD   A, (tail_start_off + 1)
    AND  0x01
    LD   (tail_skip_bytes + 1), A

    ; Compute bytes to read = filesize - block_aligned_start
    ; block_aligned_start = start_off - skip_bytes
    ; So bytes_left = filesize - start_off + skip_bytes
    LD   A, (tail_filesize)
    LD   L, A
    LD   A, (tail_start_off)
    LD   B, A
    LD   A, L
    SUB  B
    LD   L, A
    LD   A, (tail_filesize + 1)
    LD   H, A
    LD   A, (tail_start_off + 1)
    LD   B, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (tail_bytes_left), HL
    LD   A, (tail_filesize + 2)
    LD   B, A
    LD   A, (tail_start_off + 2)
    LD   C, A
    LD   A, B
    SBC  A, C
    LD   (tail_bytes_left + 2), A
    ; Add skip_bytes to bytes_left (need to read+skip those too)
    LD   HL, (tail_bytes_left)
    LD   DE, (tail_skip_bytes)
    ADD  HL, DE
    LD   (tail_bytes_left), HL
    JP   NC, tail_no_carry
    LD   A, (tail_bytes_left + 2)
    INC  A
    LD   (tail_bytes_left + 2), A
tail_no_carry:

    ; Force buffer reload
    LD   HL, 512
    LD   (tail_bufpos), HL

    ; ============================================================
    ; Print loop
    ; ============================================================
tail_print:
    ; Check bytes_left
    LD   HL, (tail_bytes_left)
    LD   A, (tail_bytes_left + 2)
    OR   H
    OR   L
    JP   Z, tail_done

    ; Get byte
    CALL tail_getbyte
    JP   NZ, tail_err_close

    ; Decrement bytes_left
    LD   HL, (tail_bytes_left)
    LD   A, L
    SUB  1
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    LD   (tail_bytes_left), HL
    LD   A, (tail_bytes_left + 2)
    SBC  A, 0
    LD   (tail_bytes_left + 2), A

    ; Skip bytes within first block if needed
    LD   HL, (tail_skip_bytes)
    LD   A, H
    OR   L
    JP   Z, tail_print_ch

    ; Decrement skip counter
    DEC  HL
    LD   (tail_skip_bytes), HL
    JP   tail_print

tail_print_ch:
    ; Print character
    LD   A, (tail_char)
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    JP   tail_print

; ============================================================
; Done
; ============================================================
tail_done:
    LD   A, (tail_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; tail_getbyte - Read next byte into tail_char
; Returns: Z=success, NZ=error
; ============================================================
tail_getbyte:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   HL, (tail_bufpos)
    LD   A, H
    CP   2
    JP   NC, tail_readblock
tail_gb_ready:
    LD   DE, tail_buf
    ADD  HL, DE
    LD   A, (HL)
    LD   (tail_char), A
    LD   HL, (tail_bufpos)
    INC  HL
    LD   (tail_bufpos), HL
    XOR  A
    POP  HL
    POP  DE
    POP  BC
    RET

tail_readblock:
    LD   A, (tail_handle)
    LD   B, A
    LD   DE, tail_buf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, tail_gb_err
    LD   HL, 0
    LD   (tail_bufpos), HL
    JP   tail_gb_ready

tail_gb_err:
    POP  HL
    POP  DE
    POP  BC
    OR   0xFF
    RET

; ============================================================
; Error handlers
; ============================================================
tail_err_open:
    LD   DE, tail_err_open_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

tail_err_close:
    LD   A, (tail_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, tail_err_read_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

tail_usage:
    LD   DE, tail_usage_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Strings
; ============================================================
tail_usage_str:     DEFB "Usage: TAIL [-N] <filename>", 0x0D, 0x0A, 0
tail_err_open_str:  DEFB "Error: cannot open file", 0x0D, 0x0A, 0
tail_err_read_str:  DEFB "Error: read failed", 0x0D, 0x0A, 0

; ============================================================
; Variables
; ============================================================
tail_fname:       DEFW 0
tail_handle:      DEFB 0
tail_filesize:    DEFS 3, 0
tail_bytes_left:  DEFS 3, 0
tail_fpos:        DEFS 3, 0
tail_start_off:   DEFS 3, 0
tail_skip_bytes:  DEFW 0
tail_bufpos:      DEFW 512
tail_char:        DEFB 0
tail_nlines:      DEFB TAIL_DEFAULT_LINES

; Circular buffer: (TAIL_MAX_LINES + 1) * 3 = 153 bytes
tail_cb_size:     DEFB 0        ; nlines
tail_cb_idx:      DEFB 0        ; current write position
tail_cb_count:    DEFB 0        ; entries used
tail_cbuf:        DEFS (TAIL_MAX_LINES + 1) * 3, 0

; I/O buffer
tail_buf:         DEFS 512, 0

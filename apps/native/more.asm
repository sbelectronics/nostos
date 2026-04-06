; ============================================================
; more.asm - Paged file viewer
; ============================================================
; Usage: MORE <filename>
;
; Displays a file one screenful at a time (23 lines), then
; shows a "--MORE--" prompt. Press any key for the next page,
; or Q to quit.
;
; Algorithm:
;   1. Parse filename from args (upcase)
;   2. Open file with SYS_GLOBAL_OPENFILE
;   3. Get file size with DEV_BGETSIZE
;   4. Read 512-byte blocks, display char by char
;   5. Count lines; at 23 lines show "--MORE--" and wait
;   6. On Q quit, on any other key continue
;   7. Close file and exit
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point -- jump over the header
    JP   more_main

    ; Header pad: 13 bytes (offsets 3-15 reserved)
    DEFS 13, 0

MORE_PAGE_LINES EQU 23          ; lines per page (leave 1 for prompt)

; ============================================================
; Entry point
; ============================================================
more_main:
    ; Parse args: filename
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, more_usage

    ; Upcase filename in-place
    LD   D, H
    LD   E, L                   ; DE = filename start
    LD   (more_fname), DE
more_upcase:
    LD   A, (HL)
    OR   A
    JP   Z, more_upcase_done
    CP   ' '
    JP   Z, more_upcase_term
    CP   'a'
    JP   C, more_upcase_store
    CP   'z' + 1
    JP   NC, more_upcase_store
    AND  0x5F
more_upcase_store:
    LD   (HL), A
    INC  HL
    JP   more_upcase
more_upcase_term:
    LD   (HL), 0                ; null-terminate at space
more_upcase_done:

    ; Open file
    LD   DE, (more_fname)
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, more_err_open

    ; Save file handle
    LD   A, L
    LD   (more_handle), A

    ; Get file size (3 bytes)
    LD   B, A
    LD   DE, more_filesize
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, more_err_close

    ; Initialize state
    XOR  A
    LD   (more_line_count), A
    LD   HL, 0
    LD   (more_bytes_left), HL
    LD   (more_bytes_left + 2), A
    ; Copy filesize to bytes_left
    LD   HL, (more_filesize)
    LD   (more_bytes_left), HL
    LD   A, (more_filesize + 2)
    LD   (more_bytes_left + 2), A

    ; Set bufpos to 512 so first iteration reads a block
    LD   HL, 512
    LD   (more_bufpos), HL

; ============================================================
; Main display loop
; ============================================================
more_loop:
    ; Check if bytes_left == 0
    LD   HL, (more_bytes_left)
    LD   A, (more_bytes_left + 2)
    OR   H
    OR   L
    JP   Z, more_done

    ; Get next byte (may read a new block)
    CALL more_getbyte
    JP   NZ, more_err_close     ; I/O error

    ; Decrement bytes_left (3-byte)
    LD   HL, (more_bytes_left)
    LD   A, L
    SUB  1
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    LD   (more_bytes_left), HL
    LD   A, (more_bytes_left + 2)
    SBC  A, 0
    LD   (more_bytes_left + 2), A

    ; Print the character
    LD   A, (more_char)
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    ; Check for newline (LF = 0x0A)
    LD   A, (more_char)
    CP   0x0A
    JP   NZ, more_loop

    ; Increment line count
    LD   A, (more_line_count)
    INC  A
    LD   (more_line_count), A
    CP   MORE_PAGE_LINES
    JP   C, more_loop           ; not at page boundary yet

    ; Page full -- show prompt
    XOR  A
    LD   (more_line_count), A   ; reset line count
    LD   DE, more_prompt_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Wait for keypress
    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    LD   A, L

    ; Erase the --MORE-- prompt (CR + spaces + CR)
    PUSH AF
    LD   DE, more_erase_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  AF

    ; Check for Q/q to quit
    CP   'Q'
    JP   Z, more_done
    CP   'q'
    JP   Z, more_done

    JP   more_loop

; ============================================================
; Done -- close file and exit
; ============================================================
more_done:
    LD   A, (more_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; more_getbyte - Read next byte into more_char
; Returns: Z if success, NZ if error/EOF
; ============================================================
more_getbyte:
    PUSH BC
    PUSH DE
    PUSH HL
    ; Check if we need to read a new block
    LD   HL, (more_bufpos)
    LD   A, H
    CP   2                      ; bufpos >= 512?
    JP   NC, more_readblock
    ; Also check if bufpos == 512 exactly for first time
more_gb_ready:
    ; Get byte from buffer at more_buf + bufpos
    LD   DE, more_buf
    ADD  HL, DE                 ; HL = more_buf + bufpos
    LD   A, (HL)
    LD   (more_char), A
    ; Increment bufpos
    LD   HL, (more_bufpos)
    INC  HL
    LD   (more_bufpos), HL
    ; Return Z = success
    XOR  A
    POP  HL
    POP  DE
    POP  BC
    RET

more_readblock:
    ; Read next 512-byte block
    LD   A, (more_handle)
    LD   B, A
    LD   DE, more_buf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, more_gb_err
    ; Reset bufpos to 0
    LD   HL, 0
    LD   (more_bufpos), HL
    JP   more_gb_ready

more_gb_err:
    POP  HL
    POP  DE
    POP  BC
    OR   0xFF                   ; NZ = error
    RET

; ============================================================
; Error handlers
; ============================================================
more_err_open:
    LD   DE, more_err_open_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

more_err_close:
    LD   A, (more_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, more_err_read_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

more_usage:
    LD   DE, more_usage_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Strings
; ============================================================
more_prompt_str:  DEFB "--MORE--", 0
more_erase_str:   DEFB 0x0D, "        ", 0x0D, 0
more_usage_str:   DEFB "Usage: MORE <filename>", 0x0D, 0x0A, 0
more_err_open_str:  DEFB "Error: cannot open file", 0x0D, 0x0A, 0
more_err_read_str:  DEFB "Error: read failed", 0x0D, 0x0A, 0

; ============================================================
; Variables
; ============================================================
more_fname:       DEFW 0
more_handle:      DEFB 0
more_filesize:    DEFS 3, 0
more_bytes_left:  DEFS 3, 0
more_bufpos:      DEFW 512      ; start at 512 to force first read
more_line_count:  DEFB 0
more_char:        DEFB 0
more_buf:         DEFS 512, 0

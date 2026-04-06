; ============================================================
; head.asm - Display first N lines of a file
; ============================================================
; Usage: HEAD [-N] <filename>
;
; Displays the first N lines of a file (default 10).
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    JP   head_main
    DEFS 13, 0

HEAD_DEFAULT_LINES  EQU 10

; ============================================================
; Entry point
; ============================================================
head_main:
    LD   A, HEAD_DEFAULT_LINES
    LD   (head_nlines), A

    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, head_usage

    ; Check for -N option
    CP   '-'
    JP   NZ, head_parse_fname
    INC  HL
    XOR  A
    LD   (head_nlines), A
head_parse_num:
    LD   A, (HL)
    CP   '0'
    JP   C, head_num_done
    CP   '9' + 1
    JP   NC, head_num_done
    SUB  '0'
    LD   B, A               ; B = new digit
    LD   A, (head_nlines)
    LD   C, A
    ADD  A, A               ; *2
    JP   C, head_num_clamp
    ADD  A, A               ; *4
    JP   C, head_num_clamp
    ADD  A, C               ; *5
    JP   C, head_num_clamp
    ADD  A, A               ; *10
    JP   C, head_num_clamp
    ADD  A, B               ; *10 + digit
    JP   C, head_num_clamp
    LD   (head_nlines), A
    INC  HL
    JP   head_parse_num
head_num_clamp:
    LD   A, 255
    LD   (head_nlines), A
    INC  HL
    JP   head_parse_num
head_num_done:
    LD   A, (HL)
    CP   ' '
    JP   NZ, head_parse_fname
    INC  HL
    JP   head_num_done

head_parse_fname:
    LD   A, (HL)
    OR   A
    JP   Z, head_usage
    LD   D, H
    LD   E, L
    LD   (head_fname), DE
head_upcase:
    LD   A, (HL)
    OR   A
    JP   Z, head_upcase_done
    CP   ' '
    JP   Z, head_upcase_term
    CP   'a'
    JP   C, head_upcase_store
    CP   'z' + 1
    JP   NC, head_upcase_store
    AND  0x5F
head_upcase_store:
    LD   (HL), A
    INC  HL
    JP   head_upcase
head_upcase_term:
    LD   (HL), 0
head_upcase_done:

    LD   A, (head_nlines)
    OR   A
    JP   Z, head_usage

    ; Open file
    LD   DE, (head_fname)
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, head_err_open
    LD   A, L
    LD   (head_handle), A

    ; Get file size
    LD   B, A
    LD   DE, head_filesize
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, head_err_close

    ; Initialize
    LD   HL, (head_filesize)
    LD   (head_bytes_left), HL
    LD   A, (head_filesize + 2)
    LD   (head_bytes_left + 2), A
    LD   HL, 512
    LD   (head_bufpos), HL
    XOR  A
    LD   (head_line_count), A

; ============================================================
; Main print loop
; ============================================================
head_loop:
    ; Check bytes_left
    LD   HL, (head_bytes_left)
    LD   A, (head_bytes_left + 2)
    OR   H
    OR   L
    JP   Z, head_done

    ; Get next byte
    CALL head_getbyte
    JP   NZ, head_err_close

    ; Decrement bytes_left
    LD   HL, (head_bytes_left)
    LD   A, L
    SUB  1
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    LD   (head_bytes_left), HL
    LD   A, (head_bytes_left + 2)
    SBC  A, 0
    LD   (head_bytes_left + 2), A

    ; Print character
    LD   A, (head_char)
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    ; Check for LF
    LD   A, (head_char)
    CP   0x0A
    JP   NZ, head_loop

    ; Increment line count
    LD   A, (head_line_count)
    INC  A
    LD   (head_line_count), A
    LD   B, A
    LD   A, (head_nlines)
    CP   B
    JP   NZ, head_loop          ; not yet at limit

; ============================================================
; Done
; ============================================================
head_done:
    LD   A, (head_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; head_getbyte
; ============================================================
head_getbyte:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   HL, (head_bufpos)
    LD   A, H
    CP   2
    JP   NC, head_readblock
head_gb_ready:
    LD   DE, head_buf
    ADD  HL, DE
    LD   A, (HL)
    LD   (head_char), A
    LD   HL, (head_bufpos)
    INC  HL
    LD   (head_bufpos), HL
    XOR  A
    POP  HL
    POP  DE
    POP  BC
    RET

head_readblock:
    LD   A, (head_handle)
    LD   B, A
    LD   DE, head_buf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, head_gb_err
    LD   HL, 0
    LD   (head_bufpos), HL
    JP   head_gb_ready

head_gb_err:
    POP  HL
    POP  DE
    POP  BC
    OR   0xFF
    RET

; ============================================================
; Error handlers
; ============================================================
head_err_open:
    LD   DE, head_err_open_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

head_err_close:
    LD   A, (head_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, head_err_read_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

head_usage:
    LD   DE, head_usage_str
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Strings
; ============================================================
head_usage_str:     DEFB "Usage: HEAD [-N] <filename>", 0x0D, 0x0A, 0
head_err_open_str:  DEFB "Error: cannot open file", 0x0D, 0x0A, 0
head_err_read_str:  DEFB "Error: read failed", 0x0D, 0x0A, 0

; ============================================================
; Variables
; ============================================================
head_fname:       DEFW 0
head_handle:      DEFB 0
head_filesize:    DEFS 3, 0
head_bytes_left:  DEFS 3, 0
head_bufpos:      DEFW 512
head_char:        DEFB 0
head_nlines:      DEFB HEAD_DEFAULT_LINES
head_line_count:  DEFB 0
head_buf:         DEFS 512, 0

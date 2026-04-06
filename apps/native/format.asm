; ============================================================
; format.asm - FORMAT application for NostOS
; ============================================================
; Usage: FORMAT <device:> <blocks>
;   device - physical block device name (colon optional)
;   blocks - number of blocks to format (5-4096)
;
; Writes a fresh NostOS filesystem to the named block device:
;   Block 0: filesystem header (signature, block count, pointers)
;   Block 1: root directory inode (1 span: block 3 to block 3)
;   Block 2: free-space bitmap (all 1=free, blocks 0-3 and
;            blocks>=numBlocks marked 0=used)
;   Block 3: root directory data block (all zeros, no entries)
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header
    JP   fmt_main

    ; Header pad: 13 bytes reserved (offsets 3-15)
    DEFS 13, 0

; Inode offsets (mirrors fs.asm — not exported to apps via includes)
FMT_INODE_OFF_COUNT EQU 0      ; span count (1 byte)
FMT_INODE_OFF_NEXT  EQU 2      ; next inode block (2 bytes)
FMT_INODE_OFF_SPANS EQU 8      ; first span pair (First, Last each 2 bytes)

; ============================================================
; fmt_main - entry point (at 0x0810)
; ============================================================
fmt_main:
    ; --- Parse first argument: device name ---
    LD   HL, (EXEC_ARGS_PTR)

    ; Copy device name chars until ':', ' ', or null
    LD   DE, fmt_dev_name
    LD   B, 8                   ; safety limit
fmt_copy_dev:
    LD   A, (HL)
    OR   A
    JP   Z, fmt_err_usage       ; end of line before block count
    CP   ' '
    JP   Z, fmt_no_colon
    CP   ':'
    JP   Z, fmt_had_colon
    LD   (DE), A
    INC  DE
    INC  HL
    DEC  B
    JP   NZ, fmt_copy_dev
    JP   fmt_err_usage          ; name too long
fmt_had_colon:
    INC  HL                     ; skip ':'
fmt_no_colon:
    LD   (DE), 0                ; null-terminate device name

    ; --- Skip spaces between device name and block count ---
fmt_skip_sp:
    LD   A, (HL)
    CP   ' '
    JP   NZ, fmt_got_count
    INC  HL
    JP   fmt_skip_sp

fmt_got_count:
    LD   A, (HL)
    OR   A
    JP   Z, fmt_err_usage       ; no block count argument

    ; --- Parse decimal block count into BC ---
    LD   BC, 0
fmt_parse_digit:
    LD   A, (HL)
    OR   A
    JP   Z, fmt_count_done
    CP   ' '
    JP   Z, fmt_count_done
    CP   '0'
    JP   C, fmt_err_usage
    CP   '9' + 1
    JP   NC, fmt_err_usage
    SUB  '0'                    ; A = digit 0-9
    ; BC = BC * 10 + digit
    PUSH HL                     ; save string pointer
    PUSH AF                     ; save digit
    ; HL = BC * 8
    LD   H, B
    LD   L, C
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL                 ; HL = BC * 8
    PUSH HL
    ; HL = BC * 2
    LD   H, B
    LD   L, C
    ADD  HL, HL                 ; HL = BC * 2
    POP  DE                     ; DE = BC * 8
    ADD  HL, DE                 ; HL = BC * 10
    POP  AF                     ; A = digit
    LD   D, 0
    LD   E, A
    ADD  HL, DE                 ; HL = BC*10 + digit
    LD   B, H
    LD   C, L
    POP  HL                     ; restore string pointer
    INC  HL
    JP   fmt_parse_digit

fmt_count_done:
    ; --- Validate 5 <= BC <= 4096 ---
    LD   A, B
    OR   C
    JP   Z, fmt_err_range       ; BC == 0
    LD   A, B
    OR   A
    JP   NZ, fmt_check_max      ; BC >= 256, above minimum
    LD   A, C
    CP   5
    JP   C, fmt_err_range       ; C < 5
fmt_check_max:
    LD   A, B
    CP   0x11
    JP   NC, fmt_err_range      ; B >= 17: BC > 4096
    CP   0x10
    JP   C, fmt_val_ok          ; B < 16: BC <= 4095
    ; B == 0x10: valid only if C == 0 (BC == exactly 4096)
    LD   A, C
    OR   A
    JP   NZ, fmt_err_range      ; BC == 0x10xx > 4096
fmt_val_ok:
    LD   H, B
    LD   L, C
    LD   (fmt_numblocks), HL    ; save validated numBlocks

    ; --- Resolve physical device ID ---
    LD   DE, fmt_dev_name
    LD   B, 0
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, fmt_err_dev
    LD   A, L
    LD   (fmt_dev_id), A

    ; ============================================================
    ; Block 0: filesystem header
    ; Layout: sig(4), numBlocks(2), rootInode(2), bitmapStart(2)
    ; ============================================================
    CALL fmt_zero_buf

    LD   HL, DISK_BUFFER
    LD   (HL), FS_SIG_0         ; offset 0
    INC  HL
    LD   (HL), FS_SIG_1         ; offset 1
    INC  HL
    LD   (HL), FS_SIG_2         ; offset 2
    INC  HL
    LD   (HL), FS_SIG_3         ; offset 3

    ; Write numBlocks (LE) at offset 4
    LD   HL, (fmt_numblocks)    ; HL = numBlocks
    LD   DE, DISK_BUFFER + 4
    LD   A, L
    LD   (DE), A                ; low byte
    INC  DE
    LD   A, H
    LD   (DE), A                ; high byte

    ; rootInode = 1 at offset 6
    LD   HL, DISK_BUFFER + 6
    LD   (HL), 1
    INC  HL
    LD   (HL), 0

    ; bitmapStart = 2 at offset 8
    LD   HL, DISK_BUFFER + 8
    LD   (HL), 2
    INC  HL
    LD   (HL), 0

    LD   DE, 0                  ; block 0
    CALL fmt_seek_write
    JP   NZ, fmt_err_io

    ; ============================================================
    ; Block 1: root directory inode
    ; spanCount=1, nextInode=0, span[0]=(3,3)
    ; ============================================================
    CALL fmt_zero_buf

    LD   HL, DISK_BUFFER + FMT_INODE_OFF_COUNT
    LD   (HL), 1                ; spanCount = 1

    ; nextInode = 0 (offset 2): already zero from fmt_zero_buf

    ; span[0].first = 3, span[0].last = 3 at offset 8
    LD   HL, DISK_BUFFER + FMT_INODE_OFF_SPANS
    LD   (HL), 3                ; first low
    INC  HL
    LD   (HL), 0                ; first high
    INC  HL
    LD   (HL), 3                ; last low
    INC  HL
    LD   (HL), 0                ; last high

    LD   DE, 1                  ; block 1
    CALL fmt_seek_write
    JP   NZ, fmt_err_io

    ; ============================================================
    ; Block 2: free-space bitmap
    ; 1 bit per block; 1=free, 0=used
    ; Initially all 0xFF; then:
    ;   byte 0 = 0xF0  (blocks 0-3 used, blocks 4-7 free)
    ;   bits for blocks >= numBlocks zeroed
    ; ============================================================
    ; Fill bitmap block with 0xFF
    LD   HL, DISK_BUFFER
    LD   B, 0                   ; 256 iterations (wraps 0->255)
fmt_fill_ff_a:
    LD   (HL), 0xFF
    INC  HL
    DEC  B
    JP   NZ, fmt_fill_ff_a
    LD   B, 0
fmt_fill_ff_b:
    LD   (HL), 0xFF
    INC  HL
    DEC  B
    JP   NZ, fmt_fill_ff_b

    ; Mark blocks 0-3 as used: byte 0 = 0xF0
    LD   HL, DISK_BUFFER
    LD   (HL), 0xF0

    ; Trim bits for blocks >= numBlocks (not needed if numBlocks == 4096)
    LD   HL, (fmt_numblocks)
    LD   A, H
    CP   0x10
    JP   Z, fmt_bitmap_write    ; numBlocks == 4096: all bits valid, skip trim

    ; bit_pos = numBlocks & 7  (which bit within the last byte is first invalid)
    LD   A, L
    AND  7
    PUSH AF                     ; save bit_pos

    ; Compute last_byte_idx = numBlocks >> 3 (logical shift right 3)
    ; Three 1-bit logical right shifts of HL:
    OR   A                      ; clear carry (OR A always clears C)
    LD   A, H
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A
    OR   A
    LD   A, H
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A
    OR   A
    LD   A, H
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A                   ; HL = numBlocks / 8 = last_byte_idx

    ; HL = &DISK_BUFFER[last_byte_idx]
    LD   DE, DISK_BUFFER
    ADD  HL, DE

    POP  AF                     ; A = bit_pos
    OR   A
    JP   Z, fmt_zero_tail       ; bit_pos == 0: zero from this byte onward

    ; Mask partial last byte: keep only the lower bit_pos bits
    ; mask = 0xFF >> (8 - bit_pos)
    LD   B, A                   ; B = bit_pos
    LD   A, 8
    SUB  B                      ; A = 8 - bit_pos
    LD   B, A                   ; B = shift count
    LD   A, 0xFF
fmt_make_mask:
    OR   A                      ; clear carry
    RRA
    DEC  B
    JP   NZ, fmt_make_mask      ; A = 0xFF >> (8 - bit_pos)

    LD   (HL), A                ; write mask to partial byte
    INC  HL                     ; advance to first fully-invalid byte

fmt_zero_tail:
    ; Zero bytes from HL through end of DISK_BUFFER
    LD   A, H
    CP   (DISK_BUFFER + 512) >> 8
    JP   NC, fmt_bitmap_write   ; HL >= end of DISK_BUFFER: done
    LD   (HL), 0
    INC  HL
    JP   fmt_zero_tail

fmt_bitmap_write:
    LD   DE, 2                  ; block 2
    CALL fmt_seek_write
    JP   NZ, fmt_err_io

    ; ============================================================
    ; Block 3: root directory data (all zeros, no entries yet)
    ; ============================================================
    CALL fmt_zero_buf
    LD   DE, 3                  ; block 3
    CALL fmt_seek_write
    JP   NZ, fmt_err_io

    ; ============================================================
    ; Success: print "Formatted N-block filesystem."
    ; ============================================================
    LD   DE, msg_formatted
    CALL fmt_puts
    LD   HL, (fmt_numblocks)
    CALL fmt_print_dec16
    LD   DE, msg_blk_suffix
    CALL fmt_puts

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Error handlers
; ============================================================
fmt_err_usage:
    LD   DE, msg_usage
    JP   fmt_err_print
fmt_err_range:
    LD   DE, msg_range
    JP   fmt_err_print
fmt_err_dev:
    LD   DE, msg_bad_dev
    JP   fmt_err_print
fmt_err_io:
    LD   DE, msg_io_err
fmt_err_print:
    CALL fmt_puts
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; fmt_zero_buf
; Zero all 512 bytes of DISK_BUFFER.
; Destroys: HL, B
; ============================================================
fmt_zero_buf:
    LD   HL, DISK_BUFFER
    LD   B, 0                   ; 256 iterations
fmt_zero_buf_a:
    LD   (HL), 0
    INC  HL
    DEC  B
    JP   NZ, fmt_zero_buf_a
    LD   B, 0
fmt_zero_buf_b:
    LD   (HL), 0
    INC  HL
    DEC  B
    JP   NZ, fmt_zero_buf_b
    RET

; ============================================================
; fmt_seek_write
; Seek to block DE on the format device, then write DISK_BUFFER.
; Inputs:  DE = block number
; Outputs: A = ERR_SUCCESS or error code; NZ on error
; Destroys: BC
; ============================================================
fmt_seek_write:
    LD   A, (fmt_dev_id)
    LD   B, A
    LD   C, DEV_BSEEK
    CALL KERNELADDR
    CP   ERR_SUCCESS
    RET  NZ
    LD   A, (fmt_dev_id)
    LD   B, A
    LD   DE, DISK_BUFFER
    LD   C, DEV_BWRITE
    CALL KERNELADDR
    OR   A                      ; set Z if A == ERR_SUCCESS
    RET

; ============================================================
; fmt_puts
; Print null-terminated string at DE to CON.
; Preserves HL.
; ============================================================
fmt_puts:
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    RET

; ============================================================
; fmt_print_dec16
; Print HL as an unsigned decimal integer to CON.
; Uses fmt_dec_buf (6 bytes: up to 5 digits + null terminator).
; Preserves BC, DE, HL.
; ============================================================
fmt_print_dec16:
    PUSH BC
    PUSH DE
    PUSH HL
    ; Build string right-to-left in fmt_dec_buf
    LD   DE, fmt_dec_buf + 5    ; point past last byte (null terminator slot)
    LD   A, 0
    LD   (DE), A                ; write null terminator
fmt_pdec_loop:
    DEC  DE                     ; move left one byte
    CALL fmt_div10              ; HL = quotient, A = remainder
    ADD  '0'
    LD   (DE), A                ; store ASCII digit
    LD   A, H
    OR   L
    JP   NZ, fmt_pdec_loop      ; continue while quotient > 0
    ; DE now points to the most-significant digit
    CALL fmt_puts               ; print the digit string (DE = start)
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; fmt_div10
; Divide HL by 10 using successive subtraction.
; Inputs:  HL = dividend
; Outputs: HL = quotient, A = remainder
; Destroys: BC
; ============================================================
fmt_div10:
    LD   BC, 0                  ; BC = quotient
fmt_div10_loop:
    LD   A, H
    OR   A
    JP   NZ, fmt_div10_sub      ; H != 0: HL >= 256 >= 10
    LD   A, L
    CP   10
    JP   C, fmt_div10_done      ; L < 10: remainder in A, quotient in BC
fmt_div10_sub:
    ; HL -= 10
    LD   A, L
    SUB  10
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    INC  BC
    JP   fmt_div10_loop
fmt_div10_done:
    LD   A, L                   ; A = remainder
    LD   H, B
    LD   L, C                   ; HL = quotient
    RET

; ============================================================
; Application data
; ============================================================
fmt_dev_id:
    DEFB 0                      ; resolved physical device ID
fmt_numblocks:
    DEFW 0                      ; validated block count
fmt_dev_name:
    DEFS 8, 0                   ; device name string (null-terminated)
fmt_dec_buf:
    DEFS 6, 0                   ; decimal print buffer (5 digits + null)

; Messages
msg_usage:
    DEFM "Usage: FORMAT <device:> <blocks>", 0x0D, 0x0A, 0
msg_range:
    DEFM "Error: blocks must be 5-4096", 0x0D, 0x0A, 0
msg_bad_dev:
    DEFM "Error: unknown device", 0x0D, 0x0A, 0
msg_io_err:
    DEFM "Error: write failed", 0x0D, 0x0A, 0
msg_formatted:
    DEFM "Formatted ", 0
msg_blk_suffix:
    DEFM "-block filesystem.", 0x0D, 0x0A, 0

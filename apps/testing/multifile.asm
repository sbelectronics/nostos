; ============================================================
; multifile.asm - Multiple open file and interleaved I/O test
; ============================================================
; Tests:
;   1 = Open 4 files simultaneously, read each, print byte-sum
;   2 = Interleaved reads from 2 two-block files, verify vs sequential
;   3 = Handle exhaustion: open until failure, close all, verify recovery
;
; Prerequisites: test script creates files with RANDDATA before running
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header
    JP   mf_main

    ; Header pad: 13 bytes (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; Entry point (0x0810)
; ============================================================
mf_main:
    ; Clear state
    XOR  A
    LD   (mf_num_open), A

    ; Parse test number from args
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    CP   '1'
    JP   Z, mf_test1
    CP   '2'
    JP   Z, mf_test2
    CP   '3'
    JP   Z, mf_test3

    LD   DE, mf_msg_usage
    CALL mf_print_str
    JP   mf_exit

; ============================================================
; Test 1: Open 4 files simultaneously, read+checksum each
; ============================================================
mf_test1:
    LD   DE, mf_msg_test1
    CALL mf_print_str

    ; Open 4 files
    LD   DE, mf_file1
    CALL mf_open_and_store
    JP   NZ, mf_error
    LD   DE, mf_file2
    CALL mf_open_and_store
    JP   NZ, mf_error
    LD   DE, mf_file3
    CALL mf_open_and_store
    JP   NZ, mf_error
    LD   DE, mf_file4
    CALL mf_open_and_store
    JP   NZ, mf_error

    ; Read and print checksum for each (all 4 still open)
    LD   A, (mf_handles)
    CALL mf_read_sum_print
    JP   NZ, mf_error
    LD   A, (mf_handles + 1)
    CALL mf_read_sum_print
    JP   NZ, mf_error
    LD   A, (mf_handles + 2)
    CALL mf_read_sum_print
    JP   NZ, mf_error
    LD   A, (mf_handles + 3)
    CALL mf_read_sum_print
    JP   NZ, mf_error

    CALL mf_close_all
    LD   DE, mf_msg_ok
    CALL mf_print_str
    JP   mf_exit

; ============================================================
; Test 2: Interleaved reads from 2 two-block files
;   Read pattern: A0, B0, A1, B1 (interleaved)
;   Then seek back, read A0, A1, B0, B1 (sequential)
;   Compare sums to verify interleaving didn't corrupt state
; ============================================================
mf_test2:
    LD   DE, mf_msg_test2
    CALL mf_print_str

    ; Open both files
    LD   DE, mf_filea
    CALL mf_open_and_store
    JP   NZ, mf_error
    LD   DE, mf_fileb
    CALL mf_open_and_store
    JP   NZ, mf_error

    ; --- Interleaved reads ---
    LD   HL, 0
    LD   (mf_sum_a), HL
    LD   (mf_sum_b), HL

    ; Read A block 0
    LD   A, (mf_handles)
    CALL mf_read_block
    JP   NZ, mf_error
    CALL mf_sum_buf
    LD   HL, (mf_sum)
    LD   (mf_sum_a), HL

    ; Read B block 0
    LD   A, (mf_handles + 1)
    CALL mf_read_block
    JP   NZ, mf_error
    CALL mf_sum_buf
    LD   HL, (mf_sum)
    LD   (mf_sum_b), HL

    ; Read A block 1
    LD   A, (mf_handles)
    CALL mf_read_block
    JP   NZ, mf_error
    CALL mf_sum_buf
    LD   DE, (mf_sum_a)
    LD   HL, (mf_sum)
    ADD  HL, DE
    LD   (mf_sum_a), HL

    ; Read B block 1
    LD   A, (mf_handles + 1)
    CALL mf_read_block
    JP   NZ, mf_error
    CALL mf_sum_buf
    LD   DE, (mf_sum_b)
    LD   HL, (mf_sum)
    ADD  HL, DE
    LD   (mf_sum_b), HL

    ; Print interleaved sums
    LD   DE, mf_msg_ilv_a
    CALL mf_print_str
    LD   HL, (mf_sum_a)
    CALL mf_print_dec16
    CALL mf_crlf

    LD   DE, mf_msg_ilv_b
    CALL mf_print_str
    LD   HL, (mf_sum_b)
    CALL mf_print_dec16
    CALL mf_crlf

    ; --- Seek both back to block 0 ---
    LD   A, (mf_handles)
    LD   B, A
    LD   DE, 0                     ; block number 0
    LD   C, DEV_BSEEK
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, mf_error

    LD   A, (mf_handles + 1)
    LD   B, A
    LD   DE, 0                     ; block number 0
    LD   C, DEV_BSEEK
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, mf_error

    ; --- Sequential reads: A0, A1, then B0, B1 ---
    LD   HL, 0
    LD   (mf_sum_a), HL
    LD   (mf_sum_b), HL

    ; A block 0
    LD   A, (mf_handles)
    CALL mf_read_block
    JP   NZ, mf_error
    CALL mf_sum_buf
    LD   HL, (mf_sum)
    LD   (mf_sum_a), HL

    ; A block 1
    LD   A, (mf_handles)
    CALL mf_read_block
    JP   NZ, mf_error
    CALL mf_sum_buf
    LD   DE, (mf_sum_a)
    LD   HL, (mf_sum)
    ADD  HL, DE
    LD   (mf_sum_a), HL

    ; B block 0
    LD   A, (mf_handles + 1)
    CALL mf_read_block
    JP   NZ, mf_error
    CALL mf_sum_buf
    LD   HL, (mf_sum)
    LD   (mf_sum_b), HL

    ; B block 1
    LD   A, (mf_handles + 1)
    CALL mf_read_block
    JP   NZ, mf_error
    CALL mf_sum_buf
    LD   DE, (mf_sum_b)
    LD   HL, (mf_sum)
    ADD  HL, DE
    LD   (mf_sum_b), HL

    ; Print sequential sums
    LD   DE, mf_msg_seq_a
    CALL mf_print_str
    LD   HL, (mf_sum_a)
    CALL mf_print_dec16
    CALL mf_crlf

    LD   DE, mf_msg_seq_b
    CALL mf_print_str
    LD   HL, (mf_sum_b)
    CALL mf_print_dec16
    CALL mf_crlf

    CALL mf_close_all
    LD   DE, mf_msg_ok
    CALL mf_print_str
    JP   mf_exit

; ============================================================
; Test 3: Handle exhaustion
;   Open FILE1.TMP repeatedly until failure, then close all
;   and verify recovery by opening one more.
; ============================================================
mf_test3:
    LD   DE, mf_msg_test3
    CALL mf_print_str

mf_test3_loop:
    LD   DE, mf_file1
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, mf_test3_full

    ; Store handle
    PUSH HL                    ; L = handle
    LD   A, (mf_num_open)
    LD   E, A
    LD   D, 0
    LD   HL, mf_handles
    ADD  HL, DE
    POP  DE                    ; E = handle (was L)
    LD   (HL), E
    LD   A, (mf_num_open)
    INC  A
    LD   (mf_num_open), A
    CP   16                    ; safety limit (handles array size)
    JP   C, mf_test3_loop

    ; Hit safety limit without error — still report
    LD   A, 0                  ; fake "no error"

mf_test3_full:
    ; A = error code from failed open
    PUSH AF

    ; Print handle count
    LD   DE, mf_msg_opened
    CALL mf_print_str
    LD   A, (mf_num_open)
    LD   L, A
    LD   H, 0
    CALL mf_print_dec16
    CALL mf_crlf

    ; Print error code
    LD   DE, mf_msg_errcode
    CALL mf_print_str
    POP  AF
    LD   L, A
    LD   H, 0
    CALL mf_print_dec16
    CALL mf_crlf

    ; Close all
    CALL mf_close_all

    ; Verify recovery: open one file, close it
    LD   DE, mf_file1
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, mf_error
    LD   B, L
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    LD   DE, mf_msg_recovered
    CALL mf_print_str
    LD   DE, mf_msg_ok
    CALL mf_print_str
    JP   mf_exit

; ============================================================
; Common exit and error
; ============================================================
mf_error:
    PUSH AF
    LD   DE, mf_msg_error
    CALL mf_print_str
    POP  AF
    LD   L, A
    LD   H, 0
    CALL mf_print_dec16
    CALL mf_crlf
    CALL mf_close_all
    JP   mf_exit

mf_exit:
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Helper: mf_open_and_store
; Open file via SYS_GLOBAL_OPENFILE and store handle
; Input: DE = null-terminated filename
; Output: Z = success, NZ = error (A = error code)
; ============================================================
mf_open_and_store:
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    RET  NZ
    ; Store handle at mf_handles[mf_num_open]
    PUSH HL                    ; L = handle
    LD   A, (mf_num_open)
    LD   E, A
    LD   D, 0
    LD   HL, mf_handles
    ADD  HL, DE
    POP  DE                    ; E = handle (was L)
    LD   (HL), E
    LD   A, (mf_num_open)
    INC  A
    LD   (mf_num_open), A
    XOR  A                     ; set Z (success)
    RET

; ============================================================
; Helper: mf_read_block
; Read one 512-byte block into mf_buf
; Input: A = handle ID
; Output: Z = success, NZ = error
; ============================================================
mf_read_block:
    LD   B, A
    LD   DE, mf_buf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    RET

; ============================================================
; Helper: mf_sum_buf
; Compute 16-bit byte sum of 512 bytes in mf_buf
; Output: (mf_sum) = sum
; Preserves: none (clobbers A, BC, DE, HL)
; ============================================================
mf_sum_buf:
    LD   HL, mf_buf
    LD   DE, 0                 ; DE = running sum
    LD   B, 0                  ; outer counter (0 = 256 iterations)
    LD   C, 0                  ; pass counter
mf_sum_loop:
    LD   A, (HL)
    INC  HL
    ADD  A, E
    LD   E, A
    JP   NC, mf_sum_nc
    INC  D
mf_sum_nc:
    DEC  B
    JP   NZ, mf_sum_loop
    ; Done 256 bytes; check if second pass needed
    INC  C
    LD   A, C
    CP   2
    JP   NZ, mf_sum_loop      ; do second pass of 256 = 512 total
    LD   (mf_sum), DE
    RET

; ============================================================
; Helper: mf_read_sum_print
; Read one block, checksum it, print sum + CRLF
; Input: A = handle ID
; Output: Z = success
; ============================================================
mf_read_sum_print:
    CALL mf_read_block
    RET  NZ
    CALL mf_sum_buf
    LD   HL, (mf_sum)
    CALL mf_print_dec16
    CALL mf_crlf
    XOR  A                     ; set Z (success)
    RET

; ============================================================
; Helper: mf_close_all
; Close all handles in mf_handles[0..mf_num_open-1]
; ============================================================
mf_close_all:
    LD   A, (mf_num_open)
    OR   A
    RET  Z
    LD   B, A
    LD   HL, mf_handles
mf_close_loop:
    PUSH BC
    PUSH HL
    LD   B, (HL)
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    POP  HL
    POP  BC
    INC  HL
    DEC  B
    JP   NZ, mf_close_loop
    XOR  A
    LD   (mf_num_open), A
    RET

; ============================================================
; Helper: mf_print_str
; Print null-terminated string at DE to console
; ============================================================
mf_print_str:
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    RET

; ============================================================
; Helper: mf_crlf
; Print CR+LF to console
; ============================================================
mf_crlf:
    LD   DE, mf_msg_crlf
    CALL mf_print_str
    RET

; ============================================================
; Helper: mf_print_dec16
; Print HL as unsigned decimal to console.
; ============================================================
mf_print_dec16:
    PUSH HL
    PUSH DE
    PUSH BC
    LD   B, 0                  ; digit count
mf_pd_divloop:
    ; Divide HL by 10
    PUSH BC
    LD   DE, 0                 ; quotient
    LD   B, 16                 ; 16 iterations
mf_pd_div10:
    ADD  HL, HL
    LD   A, E
    RLA
    LD   E, A
    LD   A, D
    RLA
    LD   D, A
    LD   A, E
    SUB  10
    JP   C, mf_pd_skip
    LD   E, A
    INC  HL
mf_pd_skip:
    DEC  B
    JP   NZ, mf_pd_div10
    ; HL = quotient, E = remainder
    POP  BC
    LD   A, E
    ADD  A, '0'
    PUSH AF                    ; push digit
    INC  B
    LD   A, H
    OR   L
    JP   NZ, mf_pd_divloop
    ; Print digits from stack
mf_pd_print:
    POP  AF
    PUSH BC
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    DEC  B
    JP   NZ, mf_pd_print
    POP  BC
    POP  DE
    POP  HL
    RET

; ============================================================
; Variables
; ============================================================
mf_handles:   DEFS 16, 0      ; up to 16 file handle IDs
mf_num_open:  DEFB 0          ; count of currently open handles
mf_sum:       DEFW 0          ; scratch checksum
mf_sum_a:     DEFW 0          ; file A cumulative checksum (test 2)
mf_sum_b:     DEFW 0          ; file B cumulative checksum (test 2)

; ============================================================
; String data
; ============================================================
mf_file1:     DEFM "FILE1.TMP", 0
mf_file2:     DEFM "FILE2.TMP", 0
mf_file3:     DEFM "FILE3.TMP", 0
mf_file4:     DEFM "FILE4.TMP", 0
mf_filea:     DEFM "FILEA.TMP", 0
mf_fileb:     DEFM "FILEB.TMP", 0

mf_msg_usage:     DEFM "Usage: MULTIFILE <1|2|3>", 0x0D, 0x0A, 0
mf_msg_test1:     DEFM "Test 1: Multi-open read", 0x0D, 0x0A, 0
mf_msg_test2:     DEFM "Test 2: Interleaved I/O", 0x0D, 0x0A, 0
mf_msg_test3:     DEFM "Test 3: Handle exhaustion", 0x0D, 0x0A, 0
mf_msg_ok:        DEFM "OK", 0x0D, 0x0A, 0
mf_msg_error:     DEFM "FAIL: error ", 0
mf_msg_ilv_a:     DEFM "Interleaved sum A: ", 0
mf_msg_ilv_b:     DEFM "Interleaved sum B: ", 0
mf_msg_seq_a:     DEFM "Sequential  sum A: ", 0
mf_msg_seq_b:     DEFM "Sequential  sum B: ", 0
mf_msg_opened:    DEFM "Handles opened: ", 0
mf_msg_errcode:   DEFM "Exhaustion error: ", 0
mf_msg_recovered: DEFM "Recovery: open after close succeeded", 0x0D, 0x0A, 0
mf_msg_crlf:      DEFM 0x0D, 0x0A, 0

; ============================================================
; I/O buffer (512 bytes) - must be last
; ============================================================
mf_buf:       DEFS 512, 0

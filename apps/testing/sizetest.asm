; ============================================================
; sizetest.asm - Test BGETSIZE and BSETSIZE syscalls
; ============================================================
; Tests:
;   1 = BGETSIZE on known file, verify size matches
;   2 = BSETSIZE then BGETSIZE round-trip
;   3 = BSETSIZE to 0, verify; BSETSIZE large, verify
;   4 = BSETSIZE, close, reopen, BGETSIZE to verify persistence
;
; Prerequisites: test script creates SIZE1.TMP (512 bytes)
;   and SIZE2.TMP (1500 bytes) via RANDDATA before running
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header
    JP   st_main

    ; Header pad: 13 bytes (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; Entry point (0x0810)
; ============================================================
st_main:
    ; Parse test number from args
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    CP   '1'
    JP   Z, st_test1
    CP   '2'
    JP   Z, st_test2
    CP   '3'
    JP   Z, st_test3
    CP   '4'
    JP   Z, st_test4

    LD   DE, st_msg_usage
    CALL st_print_str
    JP   st_exit

; ============================================================
; Test 1: BGETSIZE on files with known sizes
;   SIZE1.TMP = 512 bytes, SIZE2.TMP = 1500 bytes
; ============================================================
st_test1:
    LD   DE, st_msg_test1
    CALL st_print_str

    ; Open SIZE1.TMP and get its size
    LD   DE, st_file1
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error
    LD   A, L
    LD   (st_handle), A

    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    ; Print "SIZE1: " then size
    LD   DE, st_msg_size1
    CALL st_print_str
    CALL st_print_sizebuf
    CALL st_crlf

    ; Close
    LD   A, (st_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    ; Open SIZE2.TMP and get its size
    LD   DE, st_file2
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error
    LD   A, L
    LD   (st_handle), A

    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    LD   DE, st_msg_size2
    CALL st_print_str
    CALL st_print_sizebuf
    CALL st_crlf

    ; Close
    LD   A, (st_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    LD   DE, st_msg_ok
    CALL st_print_str
    JP   st_exit

; ============================================================
; Test 2: BSETSIZE then BGETSIZE round-trip
;   Open SIZE1.TMP, set size to 12345, read back, print
; ============================================================
st_test2:
    LD   DE, st_msg_test2
    CALL st_print_str

    ; Open SIZE1.TMP
    LD   DE, st_file1
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error
    LD   A, L
    LD   (st_handle), A

    ; Set size to 12345 (0x3039)
    LD   HL, 12345
    LD   (st_sizebuf), HL
    LD   HL, 0
    LD   (st_sizebuf + 2), HL

    LD   A, (st_handle)
    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BSETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    ; Read it back
    ; Zero the buffer first to prove BGETSIZE fills it
    LD   HL, 0
    LD   (st_sizebuf), HL
    LD   (st_sizebuf + 2), HL

    LD   A, (st_handle)
    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    LD   DE, st_msg_after_set
    CALL st_print_str
    CALL st_print_sizebuf
    CALL st_crlf

    ; Close
    LD   A, (st_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    LD   DE, st_msg_ok
    CALL st_print_str
    JP   st_exit

; ============================================================
; Test 3: BSETSIZE to 0 and to a large value (60000)
; ============================================================
st_test3:
    LD   DE, st_msg_test3
    CALL st_print_str

    ; Open SIZE1.TMP
    LD   DE, st_file1
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error
    LD   A, L
    LD   (st_handle), A

    ; Set size to 0
    LD   HL, 0
    LD   (st_sizebuf), HL
    LD   (st_sizebuf + 2), HL

    LD   A, (st_handle)
    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BSETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    ; Read back
    LD   A, (st_handle)
    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    LD   DE, st_msg_zero
    CALL st_print_str
    CALL st_print_sizebuf
    CALL st_crlf

    ; Set size to 60000 (0xEA60)
    LD   HL, 60000
    LD   (st_sizebuf), HL
    LD   HL, 0
    LD   (st_sizebuf + 2), HL

    LD   A, (st_handle)
    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BSETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    ; Read back
    LD   A, (st_handle)
    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    LD   DE, st_msg_large
    CALL st_print_str
    CALL st_print_sizebuf
    CALL st_crlf

    ; Close
    LD   A, (st_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    LD   DE, st_msg_ok
    CALL st_print_str
    JP   st_exit

; ============================================================
; Test 4: BSETSIZE persists across close/reopen
;   Set size to 9999, close, reopen, BGETSIZE
; ============================================================
st_test4:
    LD   DE, st_msg_test4
    CALL st_print_str

    ; Open SIZE1.TMP
    LD   DE, st_file1
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error
    LD   A, L
    LD   (st_handle), A

    ; Set size to 9999 (0x270F)
    LD   HL, 9999
    LD   (st_sizebuf), HL
    LD   HL, 0
    LD   (st_sizebuf + 2), HL

    LD   A, (st_handle)
    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BSETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    ; Close the file
    LD   A, (st_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    ; Reopen
    LD   DE, st_file1
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error
    LD   A, L
    LD   (st_handle), A

    ; Clear buffer and read size
    LD   HL, 0
    LD   (st_sizebuf), HL
    LD   (st_sizebuf + 2), HL

    LD   A, (st_handle)
    LD   B, A
    LD   DE, st_sizebuf
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, st_error

    LD   DE, st_msg_persist
    CALL st_print_str
    CALL st_print_sizebuf
    CALL st_crlf

    ; Close
    LD   A, (st_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    LD   DE, st_msg_ok
    CALL st_print_str
    JP   st_exit

; ============================================================
; Common exit and error
; ============================================================
st_error:
    PUSH AF
    LD   DE, st_msg_error
    CALL st_print_str
    POP  AF
    LD   L, A
    LD   H, 0
    CALL st_print_dec16
    CALL st_crlf
    JP   st_exit

st_exit:
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Helper: st_print_sizebuf
; Print the 32-bit value in st_sizebuf as decimal
; (only handles 16-bit range since max file = 16MB but our
;  test values fit in 16 bits; checks high word = 0)
; ============================================================
st_print_sizebuf:
    LD   A, (st_sizebuf + 2)
    OR   A
    JP   NZ, st_print_sizebuf_large
    LD   A, (st_sizebuf + 3)
    OR   A
    JP   NZ, st_print_sizebuf_large
    ; High word is 0, print low 16 bits
    LD   HL, (st_sizebuf)
    JP   st_print_dec16

st_print_sizebuf_large:
    ; For values > 65535, print "LARGE" (shouldn't happen in our tests)
    LD   DE, st_msg_large_val
    CALL st_print_str
    RET

; ============================================================
; Helper: st_print_str
; Print null-terminated string at DE to console
; ============================================================
st_print_str:
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    RET

; ============================================================
; Helper: st_crlf
; ============================================================
st_crlf:
    LD   DE, st_msg_crlf
    CALL st_print_str
    RET

; ============================================================
; Helper: st_print_dec16
; Print HL as unsigned decimal to console.
; ============================================================
st_print_dec16:
    PUSH HL
    PUSH DE
    PUSH BC
    LD   B, 0                  ; digit count
st_pd_divloop:
    PUSH BC
    LD   DE, 0                 ; quotient
    LD   B, 16                 ; 16 iterations
st_pd_div10:
    ADD  HL, HL
    LD   A, E
    RLA
    LD   E, A
    LD   A, D
    RLA
    LD   D, A
    LD   A, E
    SUB  10
    JP   C, st_pd_skip
    LD   E, A
    INC  HL
st_pd_skip:
    DEC  B
    JP   NZ, st_pd_div10
    ; HL = quotient, E = remainder
    POP  BC
    LD   A, E
    ADD  A, '0'
    PUSH AF                    ; push digit
    INC  B
    LD   A, H
    OR   L
    JP   NZ, st_pd_divloop
    ; Print digits from stack
st_pd_print:
    POP  AF
    PUSH BC
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    DEC  B
    JP   NZ, st_pd_print
    POP  BC
    POP  DE
    POP  HL
    RET

; ============================================================
; Variables
; ============================================================
st_handle:    DEFB 0          ; current file handle
st_sizebuf:   DEFS 4, 0      ; 4-byte size buffer for BGETSIZE/BSETSIZE

; ============================================================
; String data
; ============================================================
st_file1:         DEFM "SIZE1.TMP", 0
st_file2:         DEFM "SIZE2.TMP", 0

st_msg_usage:     DEFM "Usage: SIZETEST <1|2|3|4>", 0x0D, 0x0A, 0
st_msg_test1:     DEFM "Test 1: BGETSIZE known files", 0x0D, 0x0A, 0
st_msg_test2:     DEFM "Test 2: BSETSIZE round-trip", 0x0D, 0x0A, 0
st_msg_test3:     DEFM "Test 3: BSETSIZE zero and large", 0x0D, 0x0A, 0
st_msg_test4:     DEFM "Test 4: BSETSIZE persists", 0x0D, 0x0A, 0
st_msg_ok:        DEFM "OK", 0x0D, 0x0A, 0
st_msg_error:     DEFM "FAIL: error ", 0
st_msg_size1:     DEFM "SIZE1: ", 0
st_msg_size2:     DEFM "SIZE2: ", 0
st_msg_after_set: DEFM "After set: ", 0
st_msg_zero:      DEFM "After zero: ", 0
st_msg_large:     DEFM "After large: ", 0
st_msg_persist:   DEFM "After reopen: ", 0
st_msg_large_val: DEFM "LARGE", 0
st_msg_crlf:      DEFM 0x0D, 0x0A, 0

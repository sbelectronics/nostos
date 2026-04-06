; ============================================================
; exttorture.asm - Extension relocation torture test
; Built as a relocatable .EXT file via mkreloc.py.
; Designed to thoroughly test the EXTEND relocation system:
;   - Many JP/CALL/LD instructions with absolute addresses
;   - Code exceeds 3 blocks (>1536 bytes) for multi-block load testing
;   - Each test prints PASS/FAIL so broken relocations are visible
;   - Data tables with absolute pointers that must be relocated
;   - Addresses at various alignments (even and odd offsets)
; ============================================================

    INCLUDE "../../src/include/syscall.asm"

    ORG  0

; ============================================================
; Entry point
; ============================================================
exttorture_main:
    ; Print banner
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_banner
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 1: JP forward to a label ---
    LD   DE, msg_test1
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test1_target
exttorture_test1_fail:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_fail
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test2
exttorture_test1_target:
    LD   DE, msg_pass
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 2: CALL and RET ---
exttorture_test2:
    LD   DE, msg_test2
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    CALL exttorture_sub_ret
    LD   DE, msg_pass
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 3: LD HL with data pointer, verify contents ---
exttorture_test3:
    LD   DE, msg_test3
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   HL, exttorture_magic_data
    LD   A, (HL)
    CP   0xDE
    JP   NZ, exttorture_test3_fail
    INC  HL
    LD   A, (HL)
    CP   0xAD
    JP   NZ, exttorture_test3_fail
    INC  HL
    LD   A, (HL)
    CP   0xBE
    JP   NZ, exttorture_test3_fail
    INC  HL
    LD   A, (HL)
    CP   0xEF
    JP   NZ, exttorture_test3_fail
    LD   DE, msg_pass
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test4
exttorture_test3_fail:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_fail
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 4: JP through a pointer table ---
exttorture_test4:
    LD   DE, msg_test4
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    ; Load pointer from table entry 0
    LD   HL, exttorture_jp_table
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    ; DE = exttorture_test4_ok
    PUSH DE
    POP  HL
    JP   (HL)
exttorture_test4_fail:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_fail
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test5
exttorture_test4_ok:
    LD   DE, msg_pass
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 5: Multiple CALLs to different subroutines ---
exttorture_test5:
    LD   DE, msg_test5
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    ; Call three subroutines that each set a register to a known value
    CALL exttorture_sub_setA
    CP   0x42
    JP   NZ, exttorture_test5_fail
    CALL exttorture_sub_setB
    LD   A, B
    CP   0x55
    JP   NZ, exttorture_test5_fail
    CALL exttorture_sub_setC
    LD   A, C
    CP   0x77
    JP   NZ, exttorture_test5_fail
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_pass
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test6
exttorture_test5_fail:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_fail
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 6: JP backward ---
exttorture_test6:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_test6
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   A, 1
    JP   exttorture_test6_loop
exttorture_test6_resume:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_pass
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test7
exttorture_test6_loop:
    ; Jump backward to resume after verifying we got here
    OR   A
    JP   Z, exttorture_test6_fail
    JP   exttorture_test6_resume
exttorture_test6_fail:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_fail
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 7: CALL through pointer table entry ---
exttorture_test7:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_test7
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    ; Load function pointer from call_table[0]
    LD   HL, exttorture_call_table
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    PUSH DE
    POP  HL
    ; HL = address of exttorture_sub_setA
    ; We can't CALL (HL) in 8080, so use a JP (HL) trick with return address
    LD   DE, exttorture_test7_return
    PUSH DE              ; push return address
    JP   (HL)            ; "call" through pointer
exttorture_test7_return:
    CP   0x42
    JP   NZ, exttorture_test7_fail
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_pass
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test8
exttorture_test7_fail:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_fail
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 8: Chain of JP instructions ---
exttorture_test8:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_test8
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_chain1
exttorture_chain4:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_pass
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test9
exttorture_chain1:
    JP   exttorture_chain2
exttorture_chain2:
    JP   exttorture_chain3
exttorture_chain3:
    JP   exttorture_chain4

    ; --- Test 9: Conditional JP with address relocation ---
exttorture_test9:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_test9
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   A, 0
    OR   A               ; set Z flag
    JP   Z, exttorture_test9_ok
    JP   exttorture_test9_fail
exttorture_test9_fail:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_fail
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test10
exttorture_test9_ok:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_pass
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 10: LD DE with string pointers from a table ---
exttorture_test10:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_test10
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    ; Read pointer from string table
    LD   HL, exttorture_str_table
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    ; DE should point to msg_str_table_ok
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    ; If it printed "STR OK" then the relocation worked

    ; --- Test 11: Deep CALL chain ---
exttorture_test11:
    LD   DE, msg_test11
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    CALL exttorture_deep1
    CP   0xAA
    JP   NZ, exttorture_test11_fail
    LD   DE, msg_pass
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test12
exttorture_test11_fail:
    LD   DE, msg_fail
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 12: Read 16-bit value from data and verify ---
exttorture_test12:
    LD   DE, msg_test12
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   HL, exttorture_word_data
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    ; DE should be 0xCAFE
    LD   A, E
    CP   0xFE
    JP   NZ, exttorture_test12_fail
    LD   A, D
    CP   0xCA
    JP   NZ, exttorture_test12_fail
    LD   DE, msg_pass
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test13
exttorture_test12_fail:
    LD   DE, msg_fail
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 13: Multiple data pointers ---
exttorture_test13:
    LD   DE, msg_test13
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    ; Verify magic_data pointer via pointer table
    LD   HL, exttorture_ptr_table
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    ; DE = pointer to exttorture_magic_data
    PUSH DE
    POP  HL
    LD   A, (HL)
    CP   0xDE
    JP   NZ, exttorture_test13_fail
    ; Verify second pointer in table
    LD   HL, exttorture_ptr_table + 2
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    ; DE = pointer to exttorture_word_data
    PUSH DE
    POP  HL
    LD   A, (HL)
    CP   0xFE
    JP   NZ, exttorture_test13_fail
    LD   DE, msg_pass
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_test14
exttorture_test13_fail:
    LD   DE, msg_fail
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Test 14: Self-address verification ---
    ; The extension knows its own label addresses; verify they match
    ; what the EXTEND loader set up.
exttorture_test14:
    LD   DE, msg_test14
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    ; Load address of exttorture_main from pointer
    LD   HL, exttorture_self_ptr
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    ; DE = relocated address of exttorture_main
    ; Read first instruction byte at that address to verify
    PUSH DE
    POP  HL
    LD   A, (HL)
    ; First instruction is LD B, LOGDEV_ID_CONO = 0x06 (LD B, imm8 opcode)
    CP   0x06
    JP   NZ, exttorture_test14_fail
    LD   DE, msg_pass
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    JP   exttorture_done
exttorture_test14_fail:
    LD   DE, msg_fail
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- All tests done ---
exttorture_done:
    LD   DE, msg_done
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Subroutines (provide CALL targets for relocation testing)
; ============================================================

exttorture_sub_ret:
    RET

exttorture_sub_setA:
    LD   A, 0x42
    RET

exttorture_sub_setB:
    LD   B, 0x55
    RET

exttorture_sub_setC:
    LD   C, 0x77
    RET

; Deep call chain: each calls the next, final one returns 0xAA in A
exttorture_deep1:
    CALL exttorture_deep2
    RET

exttorture_deep2:
    CALL exttorture_deep3
    RET

exttorture_deep3:
    CALL exttorture_deep4
    RET

exttorture_deep4:
    LD   A, 0xAA
    RET

; ============================================================
; Data section — pointers here must be relocated
; ============================================================

exttorture_magic_data:
    DEFB 0xDE, 0xAD, 0xBE, 0xEF

exttorture_word_data:
    DEFW 0xCAFE

; Jump table — each entry is a 16-bit pointer (must be relocated)
exttorture_jp_table:
    DEFW exttorture_test4_ok
    DEFW exttorture_test4_fail

; Call table — function pointers (must be relocated)
exttorture_call_table:
    DEFW exttorture_sub_setA
    DEFW exttorture_sub_setB
    DEFW exttorture_sub_setC

; String pointer table (must be relocated)
exttorture_str_table:
    DEFW msg_str_table_ok

; Pointer-to-data table (must be relocated)
exttorture_ptr_table:
    DEFW exttorture_magic_data
    DEFW exttorture_word_data

; Self-reference pointer (must be relocated)
exttorture_self_ptr:
    DEFW exttorture_main

; ============================================================
; Messages — many string pointers to generate relocations
; ============================================================

msg_banner:
    DEFM "=== Extension Relocation Torture Test ===", 0x0D, 0x0A, 0

msg_test1:
    DEFM "Test 1  JP forward:       ", 0
msg_test2:
    DEFM "Test 2  CALL/RET:         ", 0
msg_test3:
    DEFM "Test 3  LD HL data ptr:   ", 0
msg_test4:
    DEFM "Test 4  JP via table:     ", 0
msg_test5:
    DEFM "Test 5  Multi CALL:       ", 0
msg_test6:
    DEFM "Test 6  JP backward:      ", 0
msg_test7:
    DEFM "Test 7  CALL via ptr:     ", 0
msg_test8:
    DEFM "Test 8  JP chain:         ", 0
msg_test9:
    DEFM "Test 9  Cond JP:          ", 0
msg_test10:
    DEFM "Test 10 Str ptr table:    ", 0
msg_test11:
    DEFM "Test 11 Deep CALL chain:  ", 0
msg_test12:
    DEFM "Test 12 Word data:        ", 0
msg_test13:
    DEFM "Test 13 Ptr-to-data tbl:  ", 0
msg_test14:
    DEFM "Test 14 Self-addr verify: ", 0

msg_pass:
    DEFM "PASS", 0x0D, 0x0A, 0
msg_fail:
    DEFM "FAIL", 0x0D, 0x0A, 0

msg_str_table_ok:
    DEFM "PASS", 0x0D, 0x0A, 0

msg_done:
    DEFM "=== All tests complete ===", 0x0D, 0x0A, 0

; ============================================================
; Padding to ensure binary exceeds 3 blocks (1536 bytes)
; The code + data above is substantial but we pad to guarantee it.
; ============================================================

exttorture_padding:
    DEFS 1536 - (exttorture_padding - exttorture_main), 0xFF

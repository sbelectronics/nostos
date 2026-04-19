; ============================================================
; dbgtest.asm - Debug torture test application
; ============================================================
; Purpose-built program for exercising debug.app features:
;   - Breakpoints (B/BC/G)
;   - Single-step trace (T) and proceed (P)
;   - Disassembly (U)
;   - Register dump and modify (R)
;
; Designed to be loaded at a fixed address (L DBGTEST.APP 8000)
; so test output is stable across debug.app size changes.
;
; Contains:
;   - Multiple subroutines (nested calls for T vs P testing)
;   - Conditional branches (taken and not-taken paths)
;   - A counted loop (breakpoint-in-loop testing)
;   - Stack operations (PUSH/POP sequences)
;   - A variety of 8080-compatible instructions for U testing
;   - A data area with known bytes for memory inspection
; ============================================================

    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point - jump over header
    JP   dbgt_main

    ; Header pad (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; dbgt_main - entry point (offset 0x10, loaded at 0x8012)
; ============================================================
dbgt_main:
    ; --- Phase 1: Register initialization ---
    LD   A, 0x42
    LD   BC, 0x1234
    LD   DE, 0x5678
    LD   HL, 0x9ABC

    ; --- Phase 2: Arithmetic sequence ---
    ADD  A, B               ; A = 0x42 + 0x12 = 0x54
    SUB  C                  ; A = 0x54 - 0x34 = 0x20
    INC  A                  ; A = 0x21
    DEC  A                  ; A = 0x20

    ; --- Phase 3: Subroutine call ---
    CALL dbgt_add_ten       ; A = 0x20 + 0x10 = 0x30

    ; --- Phase 4: Conditional branch (taken) ---
    CP   0x30
    JP   Z, dbgt_taken1
    LD   A, 0xFF            ; not reached
    JP   dbgt_after1
dbgt_taken1:
    LD   A, 0xAA
dbgt_after1:

    ; --- Phase 5: Conditional branch (not taken) ---
    CP   0x00               ; A=0xAA, not zero
    JP   Z, dbgt_taken2
    LD   A, 0xBB
    JP   dbgt_after2
dbgt_taken2:
    LD   A, 0xFF            ; not reached
dbgt_after2:

    ; --- Phase 6: Counted loop ---
    LD   B, 3
dbgt_loop:
    DEC  B
    JP   NZ, dbgt_loop      ; loops 3 times

    ; --- Phase 7: Stack operations ---
    LD   HL, 0x1111
    PUSH HL
    LD   HL, 0x2222
    PUSH HL
    POP  DE                 ; DE = 0x2222
    POP  BC                 ; BC = 0x1111

    ; --- Phase 8: Nested calls ---
    CALL dbgt_outer         ; calls dbgt_inner internally

    ; --- Phase 9: Misc instructions ---
    XOR  A                  ; A = 0x00
    CPL                     ; A = 0xFF
    SCF                     ; set carry
    CCF                     ; complement carry
    RLCA                    ; rotate left
    RRCA                    ; rotate right
    RLA                     ; rotate left through carry
    RRA                     ; rotate right through carry
    DAA                     ; decimal adjust

    ; --- Phase 10: More register loads ---
    LD   A, 0x55
    LD   B, A
    LD   C, B
    LD   D, C
    LD   E, D
    LD   H, E
    LD   L, H

    ; --- Phase 11: 16-bit arithmetic ---
    LD   HL, 0x1000
    LD   BC, 0x0234
    ADD  HL, BC             ; HL = 0x1234
    LD   DE, 0x0100
    ADD  HL, DE             ; HL = 0x1334

    ; --- Phase 12: Immediate ALU ---
    LD   A, 0x80
    ADD  A, 0x10            ; A = 0x90
    ADC  A, 0x00            ; A = 0x90 (or 0x91 with carry)
    SUB  0x10               ; A = 0x80
    SBC  A, 0x00            ; A = 0x80
    AND  0x0F               ; A = 0x00
    OR   0xA5               ; A = 0xA5
    XOR  0xFF               ; A = 0x5A
    CP   0x5A               ; Z set

    ; --- Phase 13: Memory access ---
    LD   HL, dbgt_data
    LD   A, (HL)            ; A = 0xDE
    INC  HL
    LD   A, (HL)            ; A = 0xAD
    INC  HL
    LD   A, (HL)            ; A = 0xBE
    INC  HL
    LD   A, (HL)            ; A = 0xEF

    ; --- Phase 14: EX and more stack ---
    LD   HL, 0xAAAA
    LD   DE, 0x5555
    EX   DE, HL             ; HL=0x5555, DE=0xAAAA
    PUSH HL
    PUSH DE
    POP  HL                 ; HL = 0xAAAA
    POP  DE                 ; DE = 0x5555

    ; --- Exit ---
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; dbgt_add_ten - Add 0x10 to A
; Inputs:  A = value
; Outputs: A = value + 0x10
; ============================================================
dbgt_add_ten:
    ADD  A, 0x10
    RET

; ============================================================
; dbgt_outer - Outer subroutine (calls dbgt_inner)
; Outputs: A = 0x89
; ============================================================
dbgt_outer:
    LD   A, 0x77
    CALL dbgt_inner
    INC  A                  ; A = 0x89
    RET

; ============================================================
; dbgt_inner - Inner subroutine
; Outputs: A = 0x88
; ============================================================
dbgt_inner:
    LD   A, 0x88
    INC  A                  ; A = 0x89
    DEC  A                  ; A = 0x88
    RET

; ============================================================
; dbgt_data - Known data bytes for memory inspection
; ============================================================
dbgt_data:
    DEFB 0xDE, 0xAD, 0xBE, 0xEF
    DEFB 0xCA, 0xFE, 0xBA, 0xBE

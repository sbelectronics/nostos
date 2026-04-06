; ============================================================================
; parser.asm — Z80 Instruction Parser and Opcode Encoder for NostOS Assembler
; Ported from Zealasm (Apache 2.0 License)
;
; This module parses a single line of Z80 assembly and returns encoded opcode
; bytes. The assembler's own code uses 8080-compatible instructions only, but
; it can assemble the full Z80 instruction set.
;
; Copyright (C) 2024 Zeal 8-bit Computer (original Zealasm)
; Copyright (C) 2026 Scott Baker (NostOS port)
; Licensed under Apache License 2.0
; ============================================================================

; Operand type constants
PARSER_REG8_B       EQU 0
PARSER_REG8_C       EQU 1
PARSER_REG8_D       EQU 2
PARSER_REG8_E       EQU 3
PARSER_REG8_H       EQU 4
PARSER_REG8_L       EQU 5
PARSER_REG8_HLI     EQU 6       ; (HL) as 8-bit operand slot
PARSER_REG8_A       EQU 7
PARSER_REG8_I       EQU 8
PARSER_REG8_R       EQU 9
PARSER_LABEL        EQU 10      ; label name
PARSER_CONSTANT     EQU 15      ; numeric constant

; 16-bit register indices
PARSER_REG16_BC     EQU 0x10
PARSER_REG16_DE     EQU 0x11
PARSER_REG16_HL     EQU 0x12
PARSER_REG16_SP     EQU 0x13
PARSER_REG16_IX     EQU 0x14
PARSER_REG16_IY     EQU 0x15
PARSER_REG16_AFP    EQU 0x16    ; AF'
PARSER_REG16_AF     EQU 0x17

; Memory operand types
PARSER_MEM_BC       EQU 0x20    ; (BC)
PARSER_MEM_DE       EQU 0x21    ; (DE)
PARSER_MEM_HL       EQU 0x22    ; (HL) as 16-bit context
PARSER_MEM_SP       EQU 0x23    ; (SP)
PARSER_MEM_IXD      EQU 0x24    ; (IX+d)
PARSER_MEM_IYD      EQU 0x25    ; (IY+d)
PARSER_MEM_NN       EQU 0x28    ; (nn) absolute memory
PARSER_MEM_C_PORT   EQU 0x29    ; (C) for IN/OUT

; Flag condition codes
PARSER_FLAG_NZ      EQU 0x40
PARSER_FLAG_Z       EQU 0x41
PARSER_FLAG_NC      EQU 0x42
PARSER_FLAG_C       EQU 0x43
PARSER_FLAG_PO      EQU 0x44
PARSER_FLAG_PE      EQU 0x45
PARSER_FLAG_P       EQU 0x46
PARSER_FLAG_M       EQU 0x47

; Type mask bits
PARSER_TYPE_REG16   EQU 0x10
PARSER_TYPE_MEM     EQU 0x20
PARSER_TYPE_FLAG    EQU 0x40

; Error codes
PARSER_ERR_UNKNOWN  EQU 0x80
PARSER_ERR_INVALID  EQU 0x81
PARSER_ERR_SYNTAX   EQU 0x82
PARSER_ERR_RANGE    EQU 0x83

; Prefix bytes
PARSER_PREFIX_CB    EQU 0xCB
PARSER_PREFIX_ED    EQU 0xED
PARSER_PREFIX_IX    EQU 0xDD
PARSER_PREFIX_IY    EQU 0xFD


; ============================================================================
; parser_parse_line
; Parse an assembly line and return encoded instruction bytes
; Inputs:
;   HL - pointer to trimmed instruction mnemonic (null-terminated, lowercase)
;   DE - pointer to operands string (null-terminated, may be empty)
; Outputs:
;   A - 0 on success, error code on failure
;   B - number of bytes generated (0-4)
;   (za_parse_buf) - encoded bytes stored here
; Alters: all registers
; ============================================================================
parser_parse_line:
    ; Clear reference type for this instruction
    XOR A
    LD (za_parse_ref_type), A
    PUSH DE                     ; save operands pointer
    ; Binary search the instruction table for the mnemonic in HL
    ; HL = mnemonic to find
    PUSH HL                     ; save mnemonic pointer
    ; Set up binary search: lo=0, hi=PARSER_INSTR_COUNT-1
    LD A, 0
    LD (parser_bsearch_lo), A
    LD A, PARSER_INSTR_COUNT - 1
    LD (parser_bsearch_hi), A
parser_bsearch_loop:
    LD A, (parser_bsearch_lo)
    LD B, A
    LD A, (parser_bsearch_hi)
    CP B
    JP C, parser_not_found      ; lo > hi means not found
    ; mid = (lo + hi) / 2
    ADD A, B
    RRA                         ; A = (lo+hi)/2, carry cleared by ADD if no overflow
    AND 0x7F                    ; clear any high bit from RRA
    LD (parser_bsearch_mid), A
    ; Compute table entry address: base + mid * 9
    LD L, A
    LD H, 0
    ; HL = mid, need mid*9 = mid*8 + mid
    PUSH HL                     ; save mid
    ADD HL, HL                  ; *2
    ADD HL, HL                  ; *4
    ADD HL, HL                  ; *8
    POP DE                      ; DE = mid
    ADD HL, DE                  ; HL = mid*9
    LD DE, parser_instr_table
    ADD HL, DE                  ; HL = &table[mid]
    ; HL points to 7-byte mnemonic in table
    EX DE, HL                   ; DE = table entry mnemonic
    ; Recover search mnemonic
    POP HL                      ; HL = search mnemonic
    PUSH HL                     ; re-save it
    ; Compare: HL=search, DE=table entry, 7 bytes
    LD A, 7
    CALL strncmp_opt
    OR A
    JP Z, parser_found          ; match!
    ; Not equal: recompute table entry address and compare for ordering
    POP HL                      ; HL = search mnemonic
    PUSH HL
    LD A, (parser_bsearch_mid)
    ; Recompute table address
    LD C, A
    LD B, 0
    PUSH BC                     ; save mid
    LD L, C
    LD H, 0
    ADD HL, HL
    ADD HL, HL
    ADD HL, HL
    POP DE
    ADD HL, DE
    LD DE, parser_instr_table
    ADD HL, DE                  ; HL = &table[mid]
    EX DE, HL                   ; DE = table entry
    POP HL                      ; HL = search mnemonic
    PUSH HL
    ; Compare byte by byte to determine ordering
    CALL parser_strcmp7
    ; CP (HL) in strcmp7: A=(DE)-(HL) = table-search
    ; carry set if table < search → need to search higher
    JP C, parser_bsearch_go_high
    ; table > search, so hi = mid - 1
    LD A, (parser_bsearch_mid)
    DEC A
    LD (parser_bsearch_hi), A
    JP parser_bsearch_loop
parser_bsearch_go_high:
    ; table < search, so lo = mid + 1
    LD A, (parser_bsearch_mid)
    INC A
    LD (parser_bsearch_lo), A
    JP parser_bsearch_loop

parser_found:
    ; Match found. Get handler address from table[mid]+7
    POP HL                      ; discard saved mnemonic
    LD A, (parser_bsearch_mid)
    LD L, A
    LD H, 0
    ADD HL, HL
    ADD HL, HL
    ADD HL, HL
    EX DE, HL                   ; DE = mid*8
    LD L, A
    LD H, 0
    ADD HL, DE                  ; HL = mid*9
    LD DE, parser_instr_table
    ADD HL, DE                  ; HL = &table[mid]
    ; Skip 7 bytes of mnemonic
    LD DE, 7
    ADD HL, DE
    ; Read handler address
    LD E, (HL)
    INC HL
    LD D, (HL)                  ; DE = handler address
    POP HL                      ; HL = operands string pointer
    ; Split operands
    PUSH DE                     ; save handler
    CALL parser_split_operands
    POP HL                      ; HL = handler address
    ; Call the handler via JP (HL) — but we need to CALL it
    ; Push return address, then JP (HL)
    LD DE, parser_handler_return
    PUSH DE
    JP (HL)
parser_handler_return:
    ; A = result from handler, B = byte count
    RET

parser_not_found:
    POP HL                      ; discard saved mnemonic
    POP DE                      ; discard saved operands
    LD A, PARSER_ERR_UNKNOWN
    LD B, 0
    RET

; ------------------------------------------------------------
; parser_strcmp7
; Compare up to 7 bytes of strings at HL and DE
; Returns: carry set if (DE) < (HL), carry clear if (DE) >= (HL)
;          A=0 if equal (all 7 bytes match)
; ------------------------------------------------------------
parser_strcmp7:
    LD B, 7
parser_strcmp7_loop:
    LD A, (DE)
    CP (HL)
    RET NZ                      ; carry set if (DE) < (HL)
    INC HL
    INC DE
    DEC B
    JP NZ, parser_strcmp7_loop
    ; All 7 bytes equal
    XOR A
    RET

; Binary search workspace
parser_bsearch_lo:   DEFB 0
parser_bsearch_hi:   DEFB 0
parser_bsearch_mid:  DEFB 0


; ============================================================================
; parser_split_operands
; Split operand string at comma into op1 and op2
; Input:  HL - operand string
; Output: (za_parse_op1) and (za_parse_op2) set
; ============================================================================
parser_split_operands:
    ; Check for empty operand string
    LD A, (HL)
    OR A
    JP Z, parser_split_none
    ; Trim leading whitespace
    CALL strltrim
    LD A, (HL)
    OR A
    JP Z, parser_split_none
    ; Store start as op1
    LD (za_parse_op1), HL
    ; Search for comma
    LD A, ','
    CALL strsep
    OR A
    JP NZ, parser_split_one     ; no comma found
    ; DE = rest after comma
    ; Trim trailing whitespace from op1 (e.g. "A " in "LD A ,B")
    LD HL, (za_parse_op1)
    CALL strrtrim
    ; Trim leading whitespace from op2
    EX DE, HL
    CALL strltrim
    LD (za_parse_op2), HL
    RET
parser_split_one:
    ; Trim trailing whitespace from op1
    CALL strrtrim
    LD HL, 0
    LD (za_parse_op2), HL
    RET
parser_split_none:
    LD HL, 0
    LD (za_parse_op1), HL
    LD (za_parse_op2), HL
    RET


; ============================================================================
; parser_parse_operand
; Parse a single operand string into type + value
; Input:  HL - pointer to operand string (null-terminated)
; Output: A - operand type (PARSER_REG8_*, PARSER_REG16_*, etc.)
;         HL - value (for constants/labels: the value or pointer)
;         (parser_op_disp) - displacement for (IX+d)/(IY+d)
; Alters: BC, DE
; ============================================================================
parser_parse_operand:
    ; Check for null
    LD A, (HL)
    OR A
    JP Z, parser_op_err_unknown
    ; Trim whitespace
    CALL strltrim
    LD A, (HL)
    OR A
    JP Z, parser_op_err_unknown
    ; Check for memory operand (starts with '(')
    CP '('
    JP Z, parser_op_memory
    ; Check for register or flag name
    CALL parser_try_register
    ; A = type or 0xFF if not a register
    CP 0xFF
    JP NZ, parser_op_done       ; found a register or flag
    ; Not a register - try to parse as a number
    ; Restore HL to operand string
    ; (parser_try_register may have changed HL, need to re-pass)
    LD HL, (parser_op_save)
    CALL parse_int
    OR A
    JP Z, parser_op_is_const
    ; Not a number - must be a label
    LD HL, (parser_op_save)
    ; Look up label in symbol table
    CALL data_get
    OR   A
    JP   NZ, _parser_op_fwdref
    ; Label found: DE = value
    ; Check if this is an EQU constant (not relocatable)
    LD   A, (data_get_flags)
    AND  SYM_FLAG_EQU
    JP   NZ, _parser_op_equ_const
    LD   A, ZA_REF_ABS_FOUND
    LD   (za_parse_ref_type), A
    EX   DE, HL              ; HL = label value
    LD   A, PARSER_CONSTANT
    RET
_parser_op_equ_const:
    ; EQU constant: no relocation needed
    LD   A, ZA_REF_NONE
    LD   (za_parse_ref_type), A
    EX   DE, HL              ; HL = label value
    LD   A, PARSER_CONSTANT
    RET
_parser_op_fwdref:
    ; Forward reference: copy name, return 0
    LD   HL, (parser_op_save)
    LD   DE, za_parse_label_name
    CALL strcpy
    LD   A, ZA_REF_ABS_FWDREF
    LD   (za_parse_ref_type), A
    LD   HL, 0               ; placeholder value
    LD   A, PARSER_CONSTANT
    RET
parser_op_is_const:
    ; HL = parsed value
    LD A, PARSER_CONSTANT
    RET
parser_op_done:
    ; A = register/flag type, HL unchanged or irrelevant
    RET
parser_op_err_unknown:
    LD A, PARSER_ERR_UNKNOWN
    RET

; Saved operand pointer for re-parse
parser_op_save: DEFW 0
; Displacement byte for IX+d / IY+d
parser_op_disp: DEFB 0

; ============================================================================
; parser_try_register
; Try to match HL as a register name, flag, or special register
; Input:  HL - string pointer
; Output: A - register type or 0xFF if not a register
;         HL - preserved
; ============================================================================
parser_try_register:
    LD (parser_op_save), HL     ; save for later
    ; Get string length
    PUSH HL
    CALL strlen
    POP HL
    ; BC = length
    ; Check single-char registers first
    LD A, C
    CP 1
    JP Z, parser_try_reg1
    CP 2
    JP Z, parser_try_reg2
    CP 3
    JP Z, parser_try_reg3
    ; Longer strings - not a register
    LD A, 0xFF
    RET

parser_try_reg1:
    LD A, (HL)
    ; Single character registers
    CP 'a'
    JP Z, parser_r1_a
    CP 'b'
    JP Z, parser_r1_b
    CP 'c'
    JP Z, parser_r1_c
    CP 'd'
    JP Z, parser_r1_d
    CP 'e'
    JP Z, parser_r1_e
    CP 'h'
    JP Z, parser_r1_h
    CP 'l'
    JP Z, parser_r1_l
    CP 'i'
    JP Z, parser_r1_i
    CP 'r'
    JP Z, parser_r1_r
    ; Could be flag C
    ; But 'c' is register C - context-dependent. Return as register.
    ; Uppercase variants
    CP 'A'
    JP Z, parser_r1_a
    CP 'B'
    JP Z, parser_r1_b
    CP 'C'
    JP Z, parser_r1_c
    CP 'D'
    JP Z, parser_r1_d
    CP 'E'
    JP Z, parser_r1_e
    CP 'H'
    JP Z, parser_r1_h
    CP 'L'
    JP Z, parser_r1_l
    CP 'I'
    JP Z, parser_r1_i
    CP 'R'
    JP Z, parser_r1_r
    ; Single char flags: Z, P, M
    CP 'z'
    JP Z, parser_r1_fz
    CP 'Z'
    JP Z, parser_r1_fz
    CP 'p'
    JP Z, parser_r1_fp
    CP 'P'
    JP Z, parser_r1_fp
    CP 'm'
    JP Z, parser_r1_fm
    CP 'M'
    JP Z, parser_r1_fm
    LD A, 0xFF
    RET
parser_r1_a:
    LD A, PARSER_REG8_A
    RET
parser_r1_b:
    LD A, PARSER_REG8_B
    RET
parser_r1_c:
    LD A, PARSER_REG8_C
    RET
parser_r1_d:
    LD A, PARSER_REG8_D
    RET
parser_r1_e:
    LD A, PARSER_REG8_E
    RET
parser_r1_h:
    LD A, PARSER_REG8_H
    RET
parser_r1_l:
    LD A, PARSER_REG8_L
    RET
parser_r1_i:
    LD A, PARSER_REG8_I
    RET
parser_r1_r:
    LD A, PARSER_REG8_R
    RET
parser_r1_fz:
    LD A, PARSER_FLAG_Z
    RET
parser_r1_fp:
    LD A, PARSER_FLAG_P
    RET
parser_r1_fm:
    LD A, PARSER_FLAG_M
    RET

parser_try_reg2:
    ; Two character: BC, DE, HL, SP, IX, IY, AF, NZ, NC, PO, PE
    LD A, (HL)
    INC HL
    LD C, A                     ; C = first char
    LD A, (HL)
    DEC HL
    LD B, A                     ; B = second char
    ; Convert to lowercase
    LD A, C
    CP 'A'
    JP C, parser_r2_check       ; not uppercase
    CP 'Z'+1
    JP NC, parser_r2_check
    OR 0x20                     ; to lowercase
    LD C, A
parser_r2_check:
    LD A, B
    CP 'A'
    JP C, parser_r2_dispatch
    CP 'Z'+1
    JP NC, parser_r2_dispatch
    OR 0x20
    LD B, A
parser_r2_dispatch:
    ; C=first, B=second (both lowercase)
    LD A, C
    CP 'b'
    JP Z, parser_r2_b
    CP 'd'
    JP Z, parser_r2_d
    CP 'h'
    JP Z, parser_r2_h
    CP 's'
    JP Z, parser_r2_s
    CP 'i'
    JP Z, parser_r2_i
    CP 'a'
    JP Z, parser_r2_a
    CP 'n'
    JP Z, parser_r2_n
    CP 'p'
    JP Z, parser_r2_p
    LD A, 0xFF
    RET
parser_r2_b:
    LD A, B
    CP 'c'
    JP NZ, parser_r2_fail
    LD A, PARSER_REG16_BC
    RET
parser_r2_d:
    LD A, B
    CP 'e'
    JP NZ, parser_r2_fail
    LD A, PARSER_REG16_DE
    RET
parser_r2_h:
    LD A, B
    CP 'l'
    JP NZ, parser_r2_fail
    LD A, PARSER_REG16_HL
    RET
parser_r2_s:
    LD A, B
    CP 'p'
    JP NZ, parser_r2_fail
    LD A, PARSER_REG16_SP
    RET
parser_r2_i:
    LD A, B
    CP 'x'
    JP Z, parser_r2_ix
    CP 'y'
    JP Z, parser_r2_iy
    LD A, 0xFF
    RET
parser_r2_ix:
    LD A, PARSER_REG16_IX
    RET
parser_r2_iy:
    LD A, PARSER_REG16_IY
    RET
parser_r2_a:
    LD A, B
    CP 'f'
    JP NZ, parser_r2_fail
    LD A, PARSER_REG16_AF
    RET
parser_r2_n:
    LD A, B
    CP 'z'
    JP Z, parser_r2_nz
    CP 'c'
    JP Z, parser_r2_nc
    LD A, 0xFF
    RET
parser_r2_nz:
    LD A, PARSER_FLAG_NZ
    RET
parser_r2_nc:
    LD A, PARSER_FLAG_NC
    RET
parser_r2_p:
    LD A, B
    CP 'o'
    JP Z, parser_r2_po
    CP 'e'
    JP Z, parser_r2_pe
    LD A, 0xFF
    RET
parser_r2_po:
    LD A, PARSER_FLAG_PO
    RET
parser_r2_pe:
    LD A, PARSER_FLAG_PE
    RET
parser_r2_fail:
    LD A, 0xFF
    RET

parser_try_reg3:
    ; Three characters: AF' (af')
    LD A, (HL)
    INC HL
    LD C, A
    LD A, (HL)
    INC HL
    LD B, A
    LD A, (HL)
    DEC HL
    DEC HL
    ; A = third char, B = second, C = first
    ; Check for AF'
    CP 0x27                     ; apostrophe
    JP NZ, parser_r3_fail
    ; Lower-case first two
    LD A, C
    OR 0x20
    CP 'a'
    JP NZ, parser_r3_fail
    LD A, B
    OR 0x20
    CP 'f'
    JP NZ, parser_r3_fail
    LD A, PARSER_REG16_AFP
    RET
parser_r3_fail:
    LD A, 0xFF
    RET


; ============================================================================
; parser_op_memory
; Parse a memory operand starting with '('
; Input:  HL - pointing at '('
; Output: A - operand type
;         HL - value for (nn)
;         (parser_op_disp) - displacement for IX+d / IY+d
; ============================================================================
parser_op_memory:
    INC HL                      ; skip '('
    ; Trim whitespace after (
    CALL strltrim
    LD (parser_op_save), HL     ; save for later
    ; Find closing ')'
    PUSH HL
    ; Scan for ')'
    LD B, 0                     ; position counter
parser_mem_find_paren:
    LD A, (HL)
    OR A
    JP Z, parser_mem_no_close
    CP ')'
    JP Z, parser_mem_got_close
    INC HL
    INC B
    JP parser_mem_find_paren
parser_mem_no_close:
    POP HL
    LD A, PARSER_ERR_SYNTAX
    RET
parser_mem_got_close:
    ; Null-terminate at the ')'
    LD (HL), 0
    POP HL                      ; HL = content inside parens
    ; Trim trailing whitespace of content (already null-terminated)
    ; Try to match register names
    PUSH HL
    CALL parser_try_register
    POP HL
    CP 0xFF
    JP Z, parser_mem_not_reg
    ; Got a register inside parens
    CP PARSER_REG16_BC
    JP Z, parser_mem_bc
    CP PARSER_REG16_DE
    JP Z, parser_mem_de
    CP PARSER_REG16_HL
    JP Z, parser_mem_hl
    CP PARSER_REG16_SP
    JP Z, parser_mem_sp
    CP PARSER_REG16_IX
    JP Z, parser_mem_ix_check
    CP PARSER_REG16_IY
    JP Z, parser_mem_iy_check
    CP PARSER_REG8_C
    JP Z, parser_mem_c_port
    ; Other register in parens = error
    LD A, PARSER_ERR_INVALID
    RET
parser_mem_bc:
    LD A, PARSER_MEM_BC
    RET
parser_mem_de:
    LD A, PARSER_MEM_DE
    RET
parser_mem_hl:
    LD A, PARSER_MEM_HL
    RET
parser_mem_sp:
    LD A, PARSER_MEM_SP
    RET
parser_mem_c_port:
    LD A, PARSER_MEM_C_PORT
    RET

parser_mem_ix_check:
    ; Could be (IX) or (IX+d) or (IX-d)
    ; HL points to content. Check if there's a '+' or '-' after "ix"
    LD (parser_op_save), HL
    INC HL
    INC HL                      ; skip "ix"
    LD A, (HL)
    OR A
    JP Z, parser_mem_ixd_zero   ; just (IX), displacement = 0
    CP '+'
    JP Z, parser_mem_ixd_pos
    CP '-'
    JP Z, parser_mem_ixd_neg
    ; Unexpected char
    LD A, PARSER_ERR_SYNTAX
    RET
parser_mem_ixd_zero:
    XOR A
    LD (parser_op_disp), A
    LD A, PARSER_MEM_IXD
    RET
parser_mem_ixd_pos:
    INC HL                      ; skip '+'
    CALL strltrim
    CALL parse_int
    OR A
    JP NZ, parser_mem_ixd_label
    ; HL = value
    LD A, L
    LD (parser_op_disp), A
    LD A, PARSER_MEM_IXD
    RET
parser_mem_ixd_neg:
    INC HL                      ; skip '-'
    CALL strltrim
    CALL parse_int
    OR A
    JP NZ, parser_mem_ixd_label
    ; HL = parsed positive value. Negate L for negative displacement.
    LD A, L
    CPL
    INC A                       ; A = -L (two's complement, 8080 compatible)
    LD (parser_op_disp), A
    LD A, PARSER_MEM_IXD
    RET
parser_mem_ixd_label:
    ; Label as IX/IY displacement is not supported — error
    LD A, PARSER_ERR_SYNTAX
    RET

parser_mem_iy_check:
    ; Same logic as IX but for IY
    LD (parser_op_save), HL
    INC HL
    INC HL                      ; skip "iy"
    LD A, (HL)
    OR A
    JP Z, parser_mem_iyd_zero
    CP '+'
    JP Z, parser_mem_iyd_pos
    CP '-'
    JP Z, parser_mem_iyd_neg
    LD A, PARSER_ERR_SYNTAX
    RET
parser_mem_iyd_zero:
    XOR A
    LD (parser_op_disp), A
    LD A, PARSER_MEM_IYD
    RET
parser_mem_iyd_pos:
    INC HL
    CALL strltrim
    CALL parse_int
    OR A
    JP NZ, parser_mem_iyd_label
    LD A, L
    LD (parser_op_disp), A
    LD A, PARSER_MEM_IYD
    RET
parser_mem_iyd_neg:
    INC HL
    CALL strltrim
    CALL parse_int
    OR A
    JP NZ, parser_mem_iyd_label
    LD A, L
    CPL
    INC A
    LD (parser_op_disp), A
    LD A, PARSER_MEM_IYD
    RET
parser_mem_iyd_label:
    XOR A
    LD (parser_op_disp), A
    LD A, PARSER_MEM_IYD
    RET

parser_mem_not_reg:
    ; Not a register - should be (nn), a numeric address or label
    LD HL, (parser_op_save)
    PUSH HL
    CALL parse_int
    OR A
    JP NZ, parser_mem_nn_label
    ; HL = parsed address value
    POP DE                      ; discard saved
    LD A, PARSER_MEM_NN
    RET
parser_mem_nn_label:
    POP HL                      ; HL = label string
    ; Look up label in symbol table
    PUSH HL
    CALL data_get
    POP  HL
    OR   A
    JP   NZ, _parser_mem_nn_fwdref
    ; Label found: DE = value
    LD   A, (data_get_flags)
    AND  SYM_FLAG_EQU
    JP   NZ, _parser_mem_nn_equ
    LD   A, ZA_REF_ABS_FOUND
    LD   (za_parse_ref_type), A
    EX   DE, HL              ; HL = label value
    LD   A, PARSER_MEM_NN
    RET
_parser_mem_nn_equ:
    LD   A, ZA_REF_NONE
    LD   (za_parse_ref_type), A
    EX   DE, HL              ; HL = label value
    LD   A, PARSER_MEM_NN
    RET
_parser_mem_nn_fwdref:
    ; Forward reference: copy name, return placeholder
    LD   DE, za_parse_label_name
    CALL strcpy
    LD   A, ZA_REF_ABS_FWDREF
    LD   (za_parse_ref_type), A
    LD   HL, 0               ; placeholder
    LD   A, PARSER_MEM_NN
    RET


; ============================================================================
; parser_emit1 / parser_emit2 / parser_emit3
; Helper: store 1-4 bytes into za_parse_buf
; ============================================================================
parser_emit1:
    ; A = byte
    LD HL, za_parse_buf
    LD (HL), A
    LD B, 1
    XOR A
    RET

parser_emit2:
    ; D = byte1, E = byte2
    LD HL, za_parse_buf
    LD (HL), D
    INC HL
    LD (HL), E
    LD B, 2
    XOR A
    RET

parser_emit3:
    ; D = byte1, E = byte2, C = byte3
    LD HL, za_parse_buf
    LD (HL), D
    INC HL
    LD (HL), E
    INC HL
    LD (HL), C
    LD B, 3
    XOR A
    RET



; ============================================================================
; parser_get_op1 / parser_get_op2
; Parse operand 1 or 2, returning type in A and value in HL
; ============================================================================
parser_get_op1:
    LD HL, (za_parse_op1)
    LD A, H
    OR L
    JP Z, parser_op_err_unknown
    JP parser_parse_operand

parser_get_op2:
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP Z, parser_op_err_unknown
    JP parser_parse_operand


; ============================================================================
; INSTRUCTION HANDLERS
; Each handler is called with operands already split into za_parse_op1/op2.
; Must return A=0 on success with B=byte count, or A=error code.
; ============================================================================

; ============================================================================
; _parse_simple — NOP, HALT, DI, EI, SCF, CCF, CPL, DAA, EXX, RETI, RETN,
;                 RLD, RRD, NEG
; These are handled by lookup in a small table of mnemonic->opcode(s).
; But since we already matched the mnemonic, the dispatch is by handler.
; We'll use separate handlers for each to keep it simple via the table.
; ============================================================================

_parse_nop:
    LD A, 0x00
    JP parser_emit1

_parse_halt:
    LD A, 0x76
    JP parser_emit1

_parse_di:
    LD A, 0xF3
    JP parser_emit1

_parse_ei:
    LD A, 0xFB
    JP parser_emit1

_parse_scf:
    LD A, 0x37
    JP parser_emit1

_parse_ccf:
    LD A, 0x3F
    JP parser_emit1

_parse_cpl:
    LD A, 0x2F
    JP parser_emit1

_parse_daa:
    LD A, 0x27
    JP parser_emit1

_parse_exx:
    ; EXX = 0xD9
    LD A, 0xD9
    JP parser_emit1

_parse_neg:
    ; NEG = ED 44
    LD D, PARSER_PREFIX_ED
    LD E, 0x44
    JP parser_emit2

_parse_reti:
    ; RETI = ED 4D
    LD D, PARSER_PREFIX_ED
    LD E, 0x4D
    JP parser_emit2

_parse_retn:
    ; RETN = ED 45
    LD D, PARSER_PREFIX_ED
    LD E, 0x45
    JP parser_emit2

_parse_rld:
    ; RLD = ED 6F
    LD D, PARSER_PREFIX_ED
    LD E, 0x6F
    JP parser_emit2

_parse_rrd:
    ; RRD = ED 67
    LD D, PARSER_PREFIX_ED
    LD E, 0x67
    JP parser_emit2


; ============================================================================
; _parse_rlca, _parse_rrca, _parse_rla, _parse_rra
; Single-byte rotate instructions (non-CB prefix)
; ============================================================================
_parse_rlca:
    LD A, 0x07
    JP parser_emit1

_parse_rrca:
    LD A, 0x0F
    JP parser_emit1

_parse_rla:
    LD A, 0x17
    JP parser_emit1

_parse_rra:
    LD A, 0x1F
    JP parser_emit1


; ============================================================================
; _parse_ex — EX DE,HL / EX AF,AF' / EX (SP),HL / EX (SP),IX / EX (SP),IY
; ============================================================================
_parse_ex:
    CALL parser_get_op1
    CP PARSER_ERR_UNKNOWN
    JP NC, _parse_ex_err
    ; Check what op1 is
    CP PARSER_REG16_DE
    JP Z, _parse_ex_de
    CP PARSER_REG16_AF
    JP Z, _parse_ex_af
    CP PARSER_MEM_SP
    JP Z, _parse_ex_sp
    JP _parse_ex_err

_parse_ex_de:
    ; EX DE,HL -> 0xEB
    ; Verify op2 is HL
    PUSH AF
    CALL parser_get_op2
    CP PARSER_REG16_HL
    JP NZ, _parse_ex_err2
    POP AF
    LD A, 0xEB
    JP parser_emit1

_parse_ex_af:
    ; EX AF,AF' -> 0x08
    PUSH AF
    CALL parser_get_op2
    CP PARSER_REG16_AFP
    JP NZ, _parse_ex_err2
    POP AF
    LD A, 0x08
    JP parser_emit1

_parse_ex_sp:
    ; EX (SP),HL/IX/IY
    PUSH AF
    CALL parser_get_op2
    CP PARSER_REG16_HL
    JP Z, _parse_ex_sp_hl
    CP PARSER_REG16_IX
    JP Z, _parse_ex_sp_ix
    CP PARSER_REG16_IY
    JP Z, _parse_ex_sp_iy
    JP _parse_ex_err2

_parse_ex_sp_hl:
    POP AF
    LD A, 0xE3
    JP parser_emit1

_parse_ex_sp_ix:
    POP AF
    LD D, PARSER_PREFIX_IX
    LD E, 0xE3
    JP parser_emit2

_parse_ex_sp_iy:
    POP AF
    LD D, PARSER_PREFIX_IY
    LD E, 0xE3
    JP parser_emit2

_parse_ex_err2:
    POP AF
_parse_ex_err:
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET


; ============================================================================
; _parse_push_pop — PUSH/POP rr (BC, DE, HL, AF, IX, IY)
; PUSH: base opcode 0xC5 + rr*16, POP: base 0xC1 + rr*16
; rr: BC=0, DE=1, HL=2, AF=3
; IX/IY: prefix + HL opcode
; ============================================================================
_parse_push:
    LD C, 0xC5                  ; PUSH base
    JP _parse_push_pop_common

_parse_pop:
    LD C, 0xC1                  ; POP base

_parse_push_pop_common:
    LD A, C
    LD (parser_base_op), A
    CALL parser_get_op1
    CP PARSER_ERR_UNKNOWN
    JP NC, _parse_pp_err
    ; Determine register pair
    CP PARSER_REG16_BC
    JP Z, _parse_pp_bc
    CP PARSER_REG16_DE
    JP Z, _parse_pp_de
    CP PARSER_REG16_HL
    JP Z, _parse_pp_hl
    CP PARSER_REG16_AF
    JP Z, _parse_pp_af
    CP PARSER_REG16_IX
    JP Z, _parse_pp_ix
    CP PARSER_REG16_IY
    JP Z, _parse_pp_iy
    JP _parse_pp_err

_parse_pp_bc:
    LD A, (parser_base_op)      ; base + 0*16
    JP parser_emit1
_parse_pp_de:
    LD A, (parser_base_op)
    ADD A, 0x10
    JP parser_emit1
_parse_pp_hl:
    LD A, (parser_base_op)
    ADD A, 0x20
    JP parser_emit1
_parse_pp_af:
    LD A, (parser_base_op)
    ADD A, 0x30
    JP parser_emit1
_parse_pp_ix:
    LD D, PARSER_PREFIX_IX
    LD A, (parser_base_op)
    ADD A, 0x20
    LD E, A
    JP parser_emit2
_parse_pp_iy:
    LD D, PARSER_PREFIX_IY
    LD A, (parser_base_op)
    ADD A, 0x20
    LD E, A
    JP parser_emit2
_parse_pp_err:
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET


; ============================================================================
; _parse_arith8 — ADD/ADC/SUB/SBC/AND/OR/XOR/CP A,operand
; The instruction table dispatches here with a base opcode stored separately.
; We use wrapper handlers that set the base then call common code.
; Base opcodes: ADD=0x80, ADC=0x88, SUB=0x90, SBC=0x98
;               AND=0xA0, XOR=0xA8, OR=0xB0, CP=0xB8
; With immediate: ADD=0xC6, ADC=0xCE, SUB=0xD6, SBC=0xDE
;                 AND=0xE6, XOR=0xEE, OR=0xF6, CP=0xFE
; ============================================================================
_parse_add:
    ; ADD can be 8-bit (ADD A,r) or 16-bit (ADD HL,rr / ADD IX,rr / ADD IY,rr)
    ; Check if op1 is A, HL, IX, or IY
    CALL parser_get_op1
    CP PARSER_REG8_A
    JP Z, _parse_add_a
    CP PARSER_REG16_HL
    JP Z, _parse_add16_hl
    CP PARSER_REG16_IX
    JP Z, _parse_add16_ix
    CP PARSER_REG16_IY
    JP Z, _parse_add16_iy
    ; If only one operand, it's ADD A,op (implicit A)
    ; Check if there's an op2
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP Z, _parse_add_implicit_a
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

_parse_add_implicit_a:
    ; Single operand ADD - treat as ADD A,op1
    LD C, 0x80                  ; base for reg
    LD A, 0xC6                  ; base for immediate
    LD (parser_arith_imm), A
    JP _parse_arith8_op1_already

_parse_add_a:
    LD C, 0x80
    LD A, 0xC6
    LD (parser_arith_imm), A
    JP _parse_arith8_common

_parse_adc:
    ; ADC can be 8-bit or 16-bit (ADC HL,rr)
    CALL parser_get_op1
    CP PARSER_REG8_A
    JP Z, _parse_adc_a
    CP PARSER_REG16_HL
    JP Z, _parse_adc16_hl
    ; Implicit A
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP Z, _parse_adc_implicit_a
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

_parse_adc_implicit_a:
    LD C, 0x88
    LD A, 0xCE
    LD (parser_arith_imm), A
    JP _parse_arith8_op1_already

_parse_adc_a:
    LD C, 0x88
    LD A, 0xCE
    LD (parser_arith_imm), A
    JP _parse_arith8_common

_parse_sub:
    LD C, 0x90
    LD A, 0xD6
    LD (parser_arith_imm), A
    ; SUB has no 16-bit form. Check for implicit A.
    CALL parser_get_op1
    CP PARSER_REG8_A
    JP Z, _parse_sub_check_op2
    ; No 'A' prefix, treat as SUB A,op1
    JP _parse_arith8_op1_already

_parse_sub_check_op2:
    ; If there's op2, it's SUB A,op2; if not, it's SUB A (which is SUB A,A)
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP Z, _parse_sub_a_a
    JP _parse_arith8_common

_parse_sub_a_a:
    ; SUB A = SUB A,A -> 0x97
    LD A, 0x97
    JP parser_emit1

_parse_sbc:
    ; SBC can be 8-bit or 16-bit (SBC HL,rr)
    CALL parser_get_op1
    CP PARSER_REG8_A
    JP Z, _parse_sbc_a
    CP PARSER_REG16_HL
    JP Z, _parse_sbc16_hl
    ; Implicit A
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP Z, _parse_sbc_implicit_a
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

_parse_sbc_implicit_a:
    LD C, 0x98
    LD A, 0xDE
    LD (parser_arith_imm), A
    JP _parse_arith8_op1_already

_parse_sbc_a:
    LD C, 0x98
    LD A, 0xDE
    LD (parser_arith_imm), A
    JP _parse_arith8_common

_parse_and:
    LD C, 0xA0
    LD A, 0xE6
    LD (parser_arith_imm), A
    CALL parser_get_op1
    CP PARSER_REG8_A
    JP Z, _parse_and_check
    JP _parse_arith8_op1_already
_parse_and_check:
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP NZ, _parse_arith8_common
    ; AND A = AND A,A -> 0xA7
    LD A, 0xA7
    JP parser_emit1

_parse_xor:
    LD C, 0xA8
    LD A, 0xEE
    LD (parser_arith_imm), A
    CALL parser_get_op1
    CP PARSER_REG8_A
    JP Z, _parse_xor_check
    JP _parse_arith8_op1_already
_parse_xor_check:
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP NZ, _parse_arith8_common
    LD A, 0xAF
    JP parser_emit1

_parse_or:
    LD C, 0xB0
    LD A, 0xF6
    LD (parser_arith_imm), A
    CALL parser_get_op1
    CP PARSER_REG8_A
    JP Z, _parse_or_check
    JP _parse_arith8_op1_already
_parse_or_check:
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP NZ, _parse_arith8_common
    LD A, 0xB7
    JP parser_emit1

_parse_cp:
    LD C, 0xB8
    LD A, 0xFE
    LD (parser_arith_imm), A
    CALL parser_get_op1
    CP PARSER_REG8_A
    JP Z, _parse_cp_check
    JP _parse_arith8_op1_already
_parse_cp_check:
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP NZ, _parse_arith8_common
    ; CP A = CP A,A -> 0xBF
    LD A, 0xBF
    JP parser_emit1

parser_arith_imm: DEFB 0       ; immediate opcode for current arith op
parser_base_op:   DEFB 0       ; register-base opcode (saved from C)

; Common 8-bit arithmetic: op2 is the operand
_parse_arith8_common:
    ; C = register-base opcode, parser_arith_imm = immediate opcode
    LD A, C
    LD (parser_base_op), A
    ; Parse op2
    CALL parser_get_op2
    JP _parse_arith8_encode

; Op1 is the operand (no A prefix)
_parse_arith8_op1_already:
    LD A, C
    LD (parser_base_op), A
    ; Re-parse op1 as the actual operand
    CALL parser_get_op1

_parse_arith8_encode:
    ; A = operand type, HL = value
    ; parser_base_op = register base opcode
    CP PARSER_CONSTANT
    JP Z, _parse_arith8_imm
    CP PARSER_LABEL
    JP Z, _parse_arith8_imm
    CP PARSER_MEM_IXD
    JP Z, _parse_arith8_ixd
    CP PARSER_MEM_IYD
    JP Z, _parse_arith8_iyd
    ; Map (HL) memory operand to register slot 6
    CP PARSER_MEM_HL
    JP NZ, _parse_arith8_reg_check
    LD A, PARSER_REG8_HLI
_parse_arith8_reg_check:
    ; Must be 8-bit register (0-7)
    CP 8
    JP NC, _parse_arith8_err
    ; opcode = base + reg
    LD C, A
    LD A, (parser_base_op)
    ADD A, C
    JP parser_emit1

_parse_arith8_imm:
    ; Immediate value in HL (low byte)
    LD A, (parser_arith_imm)
    LD D, A
    LD E, L
    JP parser_emit2

_parse_arith8_ixd:
    ; DD base+6 disp
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD A, (parser_base_op)
    ADD A, 6                    ; (HL) slot
    LD (HL), A
    INC HL
    LD A, (parser_op_disp)
    LD (HL), A
    LD B, 3
    XOR A
    RET

_parse_arith8_iyd:
    ; FD base+6 disp
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD A, (parser_base_op)
    ADD A, 6
    LD (HL), A
    INC HL
    LD A, (parser_op_disp)
    LD (HL), A
    LD B, 3
    XOR A
    RET

_parse_arith8_err:
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET


; ============================================================================
; _parse_add16_hl / _parse_add16_ix / _parse_add16_iy
; ADD HL,rr -> 09/19/29/39
; ADD IX,rr -> DD 09/19/29/39
; ADD IY,rr -> FD 09/19/29/39
; rr: BC=0, DE=1, HL=2(or IX/IY), SP=3
; ============================================================================
_parse_add16_hl:
    CALL parser_get_op2
    CALL _parse_rr_index        ; A = rr index (0-3)
    CP 0xFF
    JP Z, _parse_add16_err
    ; opcode = 0x09 + rr*16
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, A                    ; A = rr*16
    ADD A, 0x09
    JP parser_emit1

_parse_add16_ix:
    CALL parser_get_op2
    ; For ADD IX,rr: if op2 is IX, treat as HL slot
    CP PARSER_REG16_IX
    JP Z, _parse_add16_ix_self
    CALL _parse_rr_index
    CP 0xFF
    JP Z, _parse_add16_err
    JP _parse_add16_ix_emit
_parse_add16_ix_self:
    LD A, 2                     ; HL slot
_parse_add16_ix_emit:
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0x09
    LD E, A
    LD D, PARSER_PREFIX_IX
    JP parser_emit2

_parse_add16_iy:
    CALL parser_get_op2
    CP PARSER_REG16_IY
    JP Z, _parse_add16_iy_self
    CALL _parse_rr_index
    CP 0xFF
    JP Z, _parse_add16_err
    JP _parse_add16_iy_emit
_parse_add16_iy_self:
    LD A, 2
_parse_add16_iy_emit:
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0x09
    LD E, A
    LD D, PARSER_PREFIX_IY
    JP parser_emit2

_parse_add16_err:
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

; ADC HL,rr -> ED 4A/5A/6A/7A
_parse_adc16_hl:
    CALL parser_get_op2
    CALL _parse_rr_index
    CP 0xFF
    JP Z, _parse_add16_err
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0x4A
    LD E, A
    LD D, PARSER_PREFIX_ED
    JP parser_emit2

; SBC HL,rr -> ED 42/52/62/72
_parse_sbc16_hl:
    CALL parser_get_op2
    CALL _parse_rr_index
    CP 0xFF
    JP Z, _parse_add16_err
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0x42
    LD E, A
    LD D, PARSER_PREFIX_ED
    JP parser_emit2

; Convert register type in A to rr index (BC=0, DE=1, HL=2, SP=3)
; Returns A = index or 0xFF on error
_parse_rr_index:
    CP PARSER_REG16_BC
    JP Z, _parse_rr_bc
    CP PARSER_REG16_DE
    JP Z, _parse_rr_de
    CP PARSER_REG16_HL
    JP Z, _parse_rr_hl
    CP PARSER_REG16_SP
    JP Z, _parse_rr_sp
    LD A, 0xFF
    RET
_parse_rr_bc:
    LD A, 0
    RET
_parse_rr_de:
    LD A, 1
    RET
_parse_rr_hl:
    LD A, 2
    RET
_parse_rr_sp:
    LD A, 3
    RET


; ============================================================================
; _parse_inc_dec — INC/DEC r (8-bit) or INC/DEC rr (16-bit)
; INC r: 04/0C/14/1C/24/2C/34/3C  (r*8 + 0x04)
; DEC r: 05/0D/15/1D/25/2D/35/3D  (r*8 + 0x05)
; INC rr: 03/13/23/33  (rr*16 + 0x03)
; DEC rr: 0B/1B/2B/3B  (rr*16 + 0x0B)
; ============================================================================
_parse_inc:
    LD C, 0x04                  ; 8-bit base
    LD A, 0x03
    LD (parser_incdec16), A     ; 16-bit base
    JP _parse_inc_dec_common

_parse_dec:
    LD C, 0x05
    LD A, 0x0B
    LD (parser_incdec16), A

_parse_inc_dec_common:
    LD A, C
    LD (parser_base_op), A
    CALL parser_get_op1
    ; Check if 16-bit register
    CP PARSER_REG16_BC
    JP Z, _parse_incdec16
    CP PARSER_REG16_DE
    JP Z, _parse_incdec16
    CP PARSER_REG16_HL
    JP Z, _parse_incdec16
    CP PARSER_REG16_SP
    JP Z, _parse_incdec16
    CP PARSER_REG16_IX
    JP Z, _parse_incdec_ix
    CP PARSER_REG16_IY
    JP Z, _parse_incdec_iy
    ; Check if 8-bit register
    CP PARSER_MEM_HL
    JP NZ, _parse_incdec_not_mhl
    LD A, PARSER_REG8_HLI
_parse_incdec_not_mhl:
    CP PARSER_MEM_IXD
    JP Z, _parse_incdec_ixd
    CP PARSER_MEM_IYD
    JP Z, _parse_incdec_iyd
    CP 8
    JP NC, _parse_incdec_err
    ; 8-bit: opcode = r*8 + base
    ADD A, A
    ADD A, A
    ADD A, A                    ; A = r*8
    LD C, A
    LD A, (parser_base_op)
    ADD A, C
    JP parser_emit1

_parse_incdec16:
    ; A = register type. Convert to rr index.
    CALL _parse_rr_index
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, A                    ; rr*16
    LD B, A
    LD A, (parser_incdec16)
    ADD A, B
    JP parser_emit1

_parse_incdec_ix:
    ; DD 23 (inc) or DD 2B (dec)
    LD A, (parser_incdec16)
    ADD A, 0x20                 ; HL slot rr=2
    LD E, A
    LD D, PARSER_PREFIX_IX
    JP parser_emit2

_parse_incdec_iy:
    LD A, (parser_incdec16)
    ADD A, 0x20
    LD E, A
    LD D, PARSER_PREFIX_IY
    JP parser_emit2

_parse_incdec_ixd:
    ; DD 34/35 disp
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD A, (parser_base_op)
    ADD A, 0x30                 ; (HL) slot = 6, 6*8=48=0x30
    LD (HL), A
    INC HL
    LD A, (parser_op_disp)
    LD (HL), A
    LD B, 3
    XOR A
    RET

_parse_incdec_iyd:
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD A, (parser_base_op)
    ADD A, 0x30
    LD (HL), A
    INC HL
    LD A, (parser_op_disp)
    LD (HL), A
    LD B, 3
    XOR A
    RET

_parse_incdec_err:
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

parser_incdec16: DEFB 0


; ============================================================================
; _parse_ld — all LD variants
; This is the most complex handler, covering:
;   LD r,r'    LD r,n    LD r,(HL)   LD r,(IX+d)   LD r,(IY+d)
;   LD (HL),r  LD (IX+d),r  LD (IY+d),r  LD (HL),n  LD (IX+d),n  LD (IY+d),n
;   LD A,(BC)  LD A,(DE)  LD A,(nn)   LD (BC),A  LD (DE),A  LD (nn),A
;   LD rr,nn   LD rr,(nn)  LD (nn),rr
;   LD SP,HL   LD SP,IX   LD SP,IY
;   LD I,A     LD R,A     LD A,I     LD A,R
; ============================================================================
_parse_ld:
    ; Parse first operand
    CALL parser_get_op1
    LD (parser_ld_op1_type), A
    LD (parser_ld_op1_val), HL
    ; Parse second operand
    CALL parser_get_op2
    LD (parser_ld_op2_type), A
    LD (parser_ld_op2_val), HL
    LD A, (parser_op_disp)
    LD (parser_ld_op2_disp), A

    ; Dispatch based on op1 type
    LD A, (parser_ld_op1_type)

    ; 8-bit register destinations (0-7)
    CP 8
    JP C, _parse_ld_r_dest

    ; Special registers I and R
    CP PARSER_REG8_I
    JP Z, _parse_ld_i_dest
    CP PARSER_REG8_R
    JP Z, _parse_ld_r_dest_special

    ; 16-bit register destinations
    CP PARSER_REG16_BC
    JP Z, _parse_ld_rr_dest
    CP PARSER_REG16_DE
    JP Z, _parse_ld_rr_dest
    CP PARSER_REG16_HL
    JP Z, _parse_ld_rr_dest
    CP PARSER_REG16_SP
    JP Z, _parse_ld_sp_dest
    CP PARSER_REG16_IX
    JP Z, _parse_ld_ix_dest
    CP PARSER_REG16_IY
    JP Z, _parse_ld_iy_dest

    ; Memory destinations
    CP PARSER_MEM_BC
    JP Z, _parse_ld_mbc
    CP PARSER_MEM_DE
    JP Z, _parse_ld_mde
    CP PARSER_MEM_HL
    JP Z, _parse_ld_mhl
    CP PARSER_MEM_IXD
    JP Z, _parse_ld_mixd
    CP PARSER_MEM_IYD
    JP Z, _parse_ld_miyd
    CP PARSER_MEM_NN
    JP Z, _parse_ld_mnn

    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

parser_ld_op1_type: DEFB 0
parser_ld_op1_val:  DEFW 0
parser_ld_op2_type: DEFB 0
parser_ld_op2_val:  DEFW 0
parser_ld_op2_disp: DEFB 0

; LD r, <source> where r is 8-bit register (0-7)
_parse_ld_r_dest:
    LD A, (parser_ld_op1_type)
    LD C, A                     ; C = dest register
    LD A, (parser_ld_op2_type)

    ; LD r, r' (including (HL))
    CP 8
    JP C, _parse_ld_r_r
    ; Map (HL) memory operand to register slot 6
    CP PARSER_MEM_HL
    JP Z, _parse_ld_r_hli

    CP PARSER_CONSTANT
    JP Z, _parse_ld_r_n
    CP PARSER_LABEL
    JP Z, _parse_ld_r_n

    CP PARSER_MEM_BC
    JP Z, _parse_ld_a_mbc
    CP PARSER_MEM_DE
    JP Z, _parse_ld_a_mde
    CP PARSER_MEM_NN
    JP Z, _parse_ld_a_mnn
    CP PARSER_MEM_IXD
    JP Z, _parse_ld_r_ixd
    CP PARSER_MEM_IYD
    JP Z, _parse_ld_r_iyd
    CP PARSER_REG8_I
    JP Z, _parse_ld_a_i
    CP PARSER_REG8_R
    JP Z, _parse_ld_a_r

    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

; Map (HL) to register slot 6 for LD r, (HL)
_parse_ld_r_hli:
    LD A, PARSER_REG8_HLI
    JP _parse_ld_r_r

; LD r, r' -> 0x40 + dest*8 + src
_parse_ld_r_r:
    ; A = src register, C = dest register
    LD B, A                     ; B = src
    LD A, C
    ADD A, A
    ADD A, A
    ADD A, A                    ; A = dest*8
    ADD A, B                    ; A = dest*8 + src
    ADD A, 0x40
    JP parser_emit1

; LD r, n -> 0x06 + r*8, n
_parse_ld_r_n:
    LD A, C
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0x06
    LD D, A
    LD HL, (parser_ld_op2_val)
    LD E, L
    JP parser_emit2

; LD A, (BC) -> 0x0A (only valid for A)
_parse_ld_a_mbc:
    LD A, C
    CP PARSER_REG8_A
    JP NZ, _parse_ld_invalid
    LD A, 0x0A
    JP parser_emit1

; LD A, (DE) -> 0x1A
_parse_ld_a_mde:
    LD A, C
    CP PARSER_REG8_A
    JP NZ, _parse_ld_invalid
    LD A, 0x1A
    JP parser_emit1

; LD A, (nn) -> 0x3A nn nn
_parse_ld_a_mnn:
    LD A, C
    CP PARSER_REG8_A
    JP NZ, _parse_ld_invalid
    LD HL, za_parse_buf
    LD (HL), 0x3A
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 3
    XOR A
    RET

; LD A, I -> ED 57
_parse_ld_a_i:
    LD A, C
    CP PARSER_REG8_A
    JP NZ, _parse_ld_invalid
    LD D, PARSER_PREFIX_ED
    LD E, 0x57
    JP parser_emit2

; LD A, R -> ED 5F
_parse_ld_a_r:
    LD A, C
    CP PARSER_REG8_A
    JP NZ, _parse_ld_invalid
    LD D, PARSER_PREFIX_ED
    LD E, 0x5F
    JP parser_emit2

; LD r, (IX+d) -> DD 46+r*8 d
_parse_ld_r_ixd:
    LD A, C
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0x46
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD (HL), A
    INC HL
    LD A, (parser_ld_op2_disp)
    LD (HL), A
    LD B, 3
    XOR A
    RET

; LD r, (IY+d) -> FD 46+r*8 d
_parse_ld_r_iyd:
    LD A, C
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0x46
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD (HL), A
    INC HL
    LD A, (parser_ld_op2_disp)
    LD (HL), A
    LD B, 3
    XOR A
    RET

; LD I, A -> ED 47
_parse_ld_i_dest:
    LD A, (parser_ld_op2_type)
    CP PARSER_REG8_A
    JP NZ, _parse_ld_invalid
    LD D, PARSER_PREFIX_ED
    LD E, 0x47
    JP parser_emit2

; LD R, A -> ED 4F
_parse_ld_r_dest_special:
    LD A, (parser_ld_op2_type)
    CP PARSER_REG8_A
    JP NZ, _parse_ld_invalid
    LD D, PARSER_PREFIX_ED
    LD E, 0x4F
    JP parser_emit2

; LD SP, HL/IX/IY -> F9 / DD F9 / FD F9
_parse_ld_sp_dest:
    LD A, (parser_ld_op2_type)
    CP PARSER_REG16_HL
    JP Z, _parse_ld_sp_hl
    CP PARSER_REG16_IX
    JP Z, _parse_ld_sp_ix
    CP PARSER_REG16_IY
    JP Z, _parse_ld_sp_iy
    CP PARSER_CONSTANT
    JP Z, _parse_ld_sp_nn
    CP PARSER_LABEL
    JP Z, _parse_ld_sp_nn
    CP PARSER_MEM_NN
    JP Z, _parse_ld_sp_mnn
    JP _parse_ld_invalid

_parse_ld_sp_hl:
    LD A, 0xF9
    JP parser_emit1
_parse_ld_sp_ix:
    LD D, PARSER_PREFIX_IX
    LD E, 0xF9
    JP parser_emit2
_parse_ld_sp_iy:
    LD D, PARSER_PREFIX_IY
    LD E, 0xF9
    JP parser_emit2
_parse_ld_sp_nn:
    ; LD SP, nn -> 31 nn nn
    LD HL, za_parse_buf
    LD (HL), 0x31
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 3
    XOR A
    RET
_parse_ld_sp_mnn:
    ; LD SP, (nn) -> ED 7B nn nn
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_ED
    INC HL
    LD (HL), 0x7B
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 4
    XOR A
    RET

; LD rr, nn / LD rr, (nn) — BC, DE, HL
_parse_ld_rr_dest:
    LD A, (parser_ld_op1_type)
    CALL _parse_rr_index        ; A = 0-3
    LD C, A                     ; save rr index
    LD A, (parser_ld_op2_type)
    CP PARSER_CONSTANT
    JP Z, _parse_ld_rr_nn
    CP PARSER_LABEL
    JP Z, _parse_ld_rr_nn
    CP PARSER_MEM_NN
    JP Z, _parse_ld_rr_mnn
    JP _parse_ld_invalid

; LD rr, nn -> 01/11/21/31 nn nn
_parse_ld_rr_nn:
    LD A, C
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, A                    ; rr*16
    ADD A, 0x01
    LD HL, za_parse_buf
    LD (HL), A
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 3
    XOR A
    RET

; LD rr, (nn) -> for HL: 2A nn nn, others: ED 4B/5B/6B nn nn
_parse_ld_rr_mnn:
    LD A, C
    CP 2                        ; HL?
    JP Z, _parse_ld_hl_mnn
    ; ED prefix version
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, A                    ; rr*16
    ADD A, 0x4B
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_ED
    INC HL
    LD (HL), A
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 4
    XOR A
    RET
_parse_ld_hl_mnn:
    LD HL, za_parse_buf
    LD (HL), 0x2A
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 3
    XOR A
    RET

; LD IX, nn / LD IX, (nn)
_parse_ld_ix_dest:
    LD A, (parser_ld_op2_type)
    CP PARSER_CONSTANT
    JP Z, _parse_ld_ix_nn
    CP PARSER_LABEL
    JP Z, _parse_ld_ix_nn
    CP PARSER_MEM_NN
    JP Z, _parse_ld_ix_mnn
    JP _parse_ld_invalid
_parse_ld_ix_nn:
    ; DD 21 nn nn
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD (HL), 0x21
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 4
    XOR A
    RET
_parse_ld_ix_mnn:
    ; DD 2A nn nn
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD (HL), 0x2A
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 4
    XOR A
    RET

; LD IY, nn / LD IY, (nn)
_parse_ld_iy_dest:
    LD A, (parser_ld_op2_type)
    CP PARSER_CONSTANT
    JP Z, _parse_ld_iy_nn
    CP PARSER_LABEL
    JP Z, _parse_ld_iy_nn
    CP PARSER_MEM_NN
    JP Z, _parse_ld_iy_mnn
    JP _parse_ld_invalid
_parse_ld_iy_nn:
    ; FD 21 nn nn
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD (HL), 0x21
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 4
    XOR A
    RET
_parse_ld_iy_mnn:
    ; FD 2A nn nn
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD (HL), 0x2A
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 4
    XOR A
    RET

; LD (BC), A -> 02
_parse_ld_mbc:
    LD A, (parser_ld_op2_type)
    CP PARSER_REG8_A
    JP NZ, _parse_ld_invalid
    LD A, 0x02
    JP parser_emit1

; LD (DE), A -> 12
_parse_ld_mde:
    LD A, (parser_ld_op2_type)
    CP PARSER_REG8_A
    JP NZ, _parse_ld_invalid
    LD A, 0x12
    JP parser_emit1

; LD (HL), r -> 70+r  /  LD (HL), n -> 36 n
_parse_ld_mhl:
    LD A, (parser_ld_op2_type)
    CP 8
    JP C, _parse_ld_mhl_r
    CP PARSER_CONSTANT
    JP Z, _parse_ld_mhl_n
    CP PARSER_LABEL
    JP Z, _parse_ld_mhl_n
    JP _parse_ld_invalid
_parse_ld_mhl_r:
    ADD A, 0x70
    JP parser_emit1
_parse_ld_mhl_n:
    LD HL, (parser_ld_op2_val)
    LD D, 0x36
    LD E, L
    JP parser_emit2

; LD (IX+d), r -> DD 70+r d  /  LD (IX+d), n -> DD 36 d n
_parse_ld_mixd:
    LD A, (parser_ld_op1_type)
    ; op1 disp was parsed when op1 was parsed, but we saved op2 disp
    ; We need op1's displacement. It was parsed first, so it's in parser_op_disp
    ; before op2 parsing overwrote it. We need to handle this properly.
    ; Actually, the parse of op1 set parser_op_disp, then parse of op2 may overwrite.
    ; We should save op1's displacement. Let's use a workaround:
    ; parser_ld_op2_disp has op2's disp. op1's disp was lost.
    ; Fix: we need to save op1 disp right after parsing op1.
    ; For now, let's re-parse op1 to get its disp.
    PUSH AF
    CALL parser_get_op1         ; re-parse to get displacement
    LD A, (parser_op_disp)
    LD (parser_ld_op1_disp), A
    POP AF

    LD A, (parser_ld_op2_type)
    CP 8
    JP C, _parse_ld_mixd_r
    CP PARSER_CONSTANT
    JP Z, _parse_ld_mixd_n
    CP PARSER_LABEL
    JP Z, _parse_ld_mixd_n
    JP _parse_ld_invalid

_parse_ld_mixd_r:
    ; DD 70+r d
    ADD A, 0x70
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD (HL), A
    INC HL
    LD A, (parser_ld_op1_disp)
    LD (HL), A
    LD B, 3
    XOR A
    RET

_parse_ld_mixd_n:
    ; DD 36 d n
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD (HL), 0x36
    INC HL
    LD A, (parser_ld_op1_disp)
    LD (HL), A
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    LD B, 4
    XOR A
    RET

; LD (IY+d), r / LD (IY+d), n
_parse_ld_miyd:
    PUSH AF
    CALL parser_get_op1
    LD A, (parser_op_disp)
    LD (parser_ld_op1_disp), A
    POP AF

    LD A, (parser_ld_op2_type)
    CP 8
    JP C, _parse_ld_miyd_r
    CP PARSER_CONSTANT
    JP Z, _parse_ld_miyd_n
    CP PARSER_LABEL
    JP Z, _parse_ld_miyd_n
    JP _parse_ld_invalid

_parse_ld_miyd_r:
    ADD A, 0x70
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD (HL), A
    INC HL
    LD A, (parser_ld_op1_disp)
    LD (HL), A
    LD B, 3
    XOR A
    RET

_parse_ld_miyd_n:
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD (HL), 0x36
    INC HL
    LD A, (parser_ld_op1_disp)
    LD (HL), A
    INC HL
    LD DE, (parser_ld_op2_val)
    LD (HL), E
    LD B, 4
    XOR A
    RET

parser_ld_op1_disp: DEFB 0

; LD (nn), A -> 32 nn nn
; LD (nn), HL -> 22 nn nn
; LD (nn), rr -> ED 43/53/63/73 nn nn
; LD (nn), IX -> DD 22 nn nn
; LD (nn), IY -> FD 22 nn nn
_parse_ld_mnn:
    LD A, (parser_ld_op2_type)
    CP PARSER_REG8_A
    JP Z, _parse_ld_mnn_a
    CP PARSER_REG16_HL
    JP Z, _parse_ld_mnn_hl
    CP PARSER_REG16_BC
    JP Z, _parse_ld_mnn_rr
    CP PARSER_REG16_DE
    JP Z, _parse_ld_mnn_rr
    CP PARSER_REG16_SP
    JP Z, _parse_ld_mnn_rr
    CP PARSER_REG16_IX
    JP Z, _parse_ld_mnn_ix
    CP PARSER_REG16_IY
    JP Z, _parse_ld_mnn_iy
    JP _parse_ld_invalid

_parse_ld_mnn_a:
    LD HL, za_parse_buf
    LD (HL), 0x32
    INC HL
    LD DE, (parser_ld_op1_val)  ; (nn) address from op1
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 3
    XOR A
    RET

_parse_ld_mnn_hl:
    LD HL, za_parse_buf
    LD (HL), 0x22
    INC HL
    LD DE, (parser_ld_op1_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 3
    XOR A
    RET

_parse_ld_mnn_rr:
    ; ED 43/53/63/73 nn nn
    LD A, (parser_ld_op2_type)
    CALL _parse_rr_index        ; A = rr
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, A                    ; rr*16
    ADD A, 0x43
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_ED
    INC HL
    LD (HL), A
    INC HL
    LD DE, (parser_ld_op1_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 4
    XOR A
    RET

_parse_ld_mnn_ix:
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD (HL), 0x22
    INC HL
    LD DE, (parser_ld_op1_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 4
    XOR A
    RET

_parse_ld_mnn_iy:
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD (HL), 0x22
    INC HL
    LD DE, (parser_ld_op1_val)
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 4
    XOR A
    RET

_parse_ld_invalid:
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET


; ============================================================================
; _parse_jp — JP nn / JP cc,nn / JP (HL) / JP (IX) / JP (IY)
; JP nn:    C3 nn nn
; JP cc,nn: C2/CA/D2/DA/E2/EA/F2/FA nn nn  (cc*8 + 0xC2)
; JP (HL):  E9
; JP (IX):  DD E9
; JP (IY):  FD E9
; ============================================================================
_parse_jp:
    CALL parser_get_op1
    ; Check for JP (HL)/(IX)/(IY)
    CP PARSER_MEM_HL
    JP Z, _parse_jp_hl
    CP PARSER_MEM_IXD
    JP Z, _parse_jp_ix
    CP PARSER_MEM_IYD
    JP Z, _parse_jp_iy
    CP PARSER_REG16_HL
    JP Z, _parse_jp_hl          ; Some assemblers accept JP HL as JP (HL)

    ; Check for condition code
    ; 'c' is parsed as PARSER_REG8_C by parser_try_reg1, not PARSER_FLAG_C
    CP PARSER_REG8_C
    JP NZ, _parse_jp_cc_check
    LD A, PARSER_FLAG_C         ; convert register C to flag C
_parse_jp_cc_check:
    CP PARSER_TYPE_FLAG
    JP C, _parse_jp_no_cc
    CP PARSER_FLAG_M + 1
    JP NC, _parse_jp_no_cc
    ; It's a flag - check for op2
    LD HL, (za_parse_op2)
    LD B, A                     ; save flag
    LD A, H
    OR L
    JP Z, _parse_jp_no_cc_restore  ; no op2, treat op1 as address
    ; JP cc, nn
    LD A, B
    AND 0x07                    ; cc index
    ADD A, A
    ADD A, A
    ADD A, A                    ; cc*8
    ADD A, 0xC2
    LD (za_parse_buf), A
    CALL parser_get_op2
    ; HL = address value
    LD A, L
    LD (za_parse_buf + 1), A
    LD A, H
    LD (za_parse_buf + 2), A
    LD B, 3
    XOR A
    RET

_parse_jp_no_cc_restore:
    LD A, B
_parse_jp_no_cc:
    ; op1 is address (constant or label)
    ; Re-parse op1 to get value
    CALL parser_get_op1
    ; JP nn: C3 nn nn
    LD HL, za_parse_buf
    LD (HL), 0xC3
    INC HL
    ; Get op1 value
    PUSH HL
    CALL parser_get_op1
    ; A=type, HL=value
    LD D, H
    LD E, L
    POP HL
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 3
    XOR A
    RET

_parse_jp_hl:
    LD A, 0xE9
    JP parser_emit1
_parse_jp_ix:
    LD D, PARSER_PREFIX_IX
    LD E, 0xE9
    JP parser_emit2
_parse_jp_iy:
    LD D, PARSER_PREFIX_IY
    LD E, 0xE9
    JP parser_emit2


; ============================================================================
; _parse_jr — JR e / JR cc,e
; JR e:    18 e
; JR cc,e: 20/28/30/38 e  (only NZ, Z, NC, C)
; Emits opcode + placeholder byte. Caller handles relative fixup.
; ============================================================================
_parse_jr:
    CALL parser_get_op1
    ; Check for condition code
    CP PARSER_FLAG_NZ
    JP Z, _parse_jr_cc
    CP PARSER_FLAG_Z
    JP Z, _parse_jr_cc
    CP PARSER_FLAG_NC
    JP Z, _parse_jr_cc
    CP PARSER_FLAG_C
    JP Z, _parse_jr_cc
    ; 'c' is parsed as PARSER_REG8_C by parser_try_reg1, not PARSER_FLAG_C
    ; Detect this case and convert to the correct flag value
    CP PARSER_REG8_C
    JP NZ, _parse_jr_nocc
    LD A, PARSER_FLAG_C     ; convert register C to flag C
    JP _parse_jr_cc
_parse_jr_nocc:
    ; No condition - JR e
    ; Re-parse op1 for value
    CALL parser_get_op1
    CALL parser_fix_jr_ref      ; convert abs ref to relative displacement
    LD D, 0x18
    LD E, L
    JP parser_emit2

_parse_jr_cc:
    ; A = flag type
    LD B, A
    ; Map: NZ=0x40->0, Z=0x41->1, NC=0x42->2, C=0x43->3
    AND 0x03
    ADD A, A
    ADD A, A
    ADD A, A                    ; cc*8
    ADD A, 0x20                 ; base opcode
    LD (parser_base_op), A      ; save opcode (C gets clobbered by parser_get_op2)
    ; Get displacement from op2
    CALL parser_get_op2
    CALL parser_fix_jr_ref      ; convert abs ref to relative displacement
    LD A, (parser_base_op)
    LD D, A
    LD E, L
    JP parser_emit2


; ============================================================================
; _parse_djnz — DJNZ e  (opcode 0x10 + displacement)
; ============================================================================
_parse_djnz:
    CALL parser_get_op1
    CALL parser_fix_jr_ref      ; convert abs ref to relative displacement
    LD D, 0x10
    LD E, L
    JP parser_emit2


; ============================================================================
; parser_fix_jr_ref — Convert absolute reference to relative for JR/DJNZ
; Called after parser_get_op1/op2 for relative branch instructions.
; For known labels: computes displacement = target - (bin_size + 2)
; For forward refs: changes ref type from ABS_FWDREF to REL_FWDREF
; Inputs:
;   HL - operand value from parser_get_op
; Outputs:
;   L  - displacement byte (or 0 placeholder for forward refs)
;   za_parse_ref_type updated
; ============================================================================
parser_fix_jr_ref:
    LD A, (za_parse_ref_type)
    CP ZA_REF_ABS_FWDREF
    JP Z, _parser_fix_jr_fwd
    ; Known label or constant: compute displacement
    ; disp = target - (bin_size + org + 2)
    ; ORG is added because target includes ORG, bin_size does not
    EX DE, HL               ; DE = target value
    LD HL, (za_bin_size)
    PUSH DE                  ; save target
    LD DE, (za_org)
    ADD HL, DE               ; HL = bin_size + org
    POP DE                   ; DE = target
    INC HL
    INC HL                   ; HL = bin_size + org + 2 (= PC after instr)
    ; Full 16-bit subtraction: DE - HL
    LD A, E
    SUB L
    LD L, A
    LD A, D
    SBC A, H
    ; A = high byte of displacement; validate signed 8-bit range
    OR A
    JP Z, _parser_fix_jr_pos
    CP 0xFF
    JP Z, _parser_fix_jr_neg
    JP _parser_fix_jr_oor
_parser_fix_jr_pos:
    ; Positive: L must be <= 127 (bit 7 clear)
    LD A, L
    AND 0x80
    JP NZ, _parser_fix_jr_oor
    JP _parser_fix_jr_ok
_parser_fix_jr_neg:
    ; Negative: L must be >= 128 (bit 7 set)
    LD A, L
    AND 0x80
    JP Z, _parser_fix_jr_oor
_parser_fix_jr_ok:
    ; Clear ref type so main loop won't add relocation
    LD A, ZA_REF_NONE
    LD (za_parse_ref_type), A
    RET
_parser_fix_jr_oor:
    ; Out of range — report error, return 0 placeholder
    PUSH HL
    LD DE, za_msg_rel_range
    CALL za_print_error
    POP HL
    LD L, 0
    LD A, ZA_REF_NONE
    LD (za_parse_ref_type), A
    RET
_parser_fix_jr_fwd:
    ; Forward reference: change to relative type
    LD A, ZA_REF_REL_FWDREF
    LD (za_parse_ref_type), A
    LD L, 0                  ; placeholder displacement
    RET


; ============================================================================
; _parse_call — CALL nn / CALL cc,nn
; CALL nn:    CD nn nn
; CALL cc,nn: C4/CC/D4/DC/E4/EC/F4/FC nn nn  (cc*8 + 0xC4)
; ============================================================================
_parse_call:
    CALL parser_get_op1
    ; 'c' is parsed as PARSER_REG8_C, not PARSER_FLAG_C
    CP PARSER_REG8_C
    JP NZ, _parse_call_cc_check
    LD A, PARSER_FLAG_C
_parse_call_cc_check:
    ; Check for condition code
    CP PARSER_TYPE_FLAG
    JP C, _parse_call_no_cc
    CP PARSER_FLAG_M + 1
    JP NC, _parse_call_no_cc
    ; Condition code
    LD B, A
    ; Check if op2 exists
    LD HL, (za_parse_op2)
    LD A, H
    OR L
    JP Z, _parse_call_no_cc_b   ; no op2, treat as address
    LD A, B
    AND 0x07
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0xC4
    LD (za_parse_buf), A
    CALL parser_get_op2
    LD A, L
    LD (za_parse_buf + 1), A
    LD A, H
    LD (za_parse_buf + 2), A
    LD B, 3
    XOR A
    RET

_parse_call_no_cc_b:
    LD A, B
_parse_call_no_cc:
    ; CALL nn
    PUSH AF
    LD HL, za_parse_buf
    LD (HL), 0xCD
    POP AF
    ; Re-get value from op1
    PUSH HL
    CALL parser_get_op1
    LD D, H
    LD E, L
    POP HL
    INC HL
    LD (HL), E
    INC HL
    LD (HL), D
    LD B, 3
    XOR A
    RET


; ============================================================================
; _parse_ret — RET / RET cc
; RET:    C9
; RET cc: C0/C8/D0/D8/E0/E8/F0/F8  (cc*8 + 0xC0)
; ============================================================================
_parse_ret:
    ; Check if there's an operand
    LD HL, (za_parse_op1)
    LD A, H
    OR L
    JP Z, _parse_ret_plain
    CALL parser_get_op1
    ; 'c' is parsed as PARSER_REG8_C, not PARSER_FLAG_C
    CP PARSER_REG8_C
    JP NZ, _parse_ret_cc_check
    LD A, PARSER_FLAG_C
_parse_ret_cc_check:
    ; Should be a flag
    CP PARSER_TYPE_FLAG
    JP C, _parse_ret_plain_val
    CP PARSER_FLAG_M + 1
    JP NC, _parse_ret_plain_val
    AND 0x07
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0xC0
    JP parser_emit1
_parse_ret_plain_val:
    ; Not a flag - error or just RET
_parse_ret_plain:
    LD A, 0xC9
    JP parser_emit1


; ============================================================================
; _parse_rst — RST n (n = 0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38)
; Opcode: 0xC7 + n
; ============================================================================
_parse_rst:
    CALL parser_get_op1
    ; HL = value, should be 0, 8, 16, 24, 32, 40, 48, 56
    LD A, L
    ; Validate: must be multiple of 8, 0-56
    AND 0x07                    ; low 3 bits must be 0
    JP NZ, _parse_rst_err
    LD A, L
    CP 0x40                     ; max is 0x38
    JP NC, _parse_rst_err
    ; opcode = 0xC7 + n
    ADD A, 0xC7
    JP parser_emit1
_parse_rst_err:
    LD A, PARSER_ERR_RANGE
    LD B, 0
    RET


; ============================================================================
; _parse_im — IM 0 / IM 1 / IM 2
; IM 0: ED 46
; IM 1: ED 56
; IM 2: ED 5E
; ============================================================================
_parse_im:
    CALL parser_get_op1
    ; HL = value (0, 1, or 2)
    LD A, L
    CP 0
    JP Z, _parse_im_0
    CP 1
    JP Z, _parse_im_1
    CP 2
    JP Z, _parse_im_2
    LD A, PARSER_ERR_RANGE
    LD B, 0
    RET
_parse_im_0:
    LD D, PARSER_PREFIX_ED
    LD E, 0x46
    JP parser_emit2
_parse_im_1:
    LD D, PARSER_PREFIX_ED
    LD E, 0x56
    JP parser_emit2
_parse_im_2:
    LD D, PARSER_PREFIX_ED
    LD E, 0x5E
    JP parser_emit2


; ============================================================================
; _parse_in_out — IN/OUT instructions
; IN A, (n):   DB n
; IN r, (C):   ED 40+r*8
; OUT (n), A:  D3 n
; OUT (C), r:  ED 41+r*8
; ============================================================================
_parse_in:
    CALL parser_get_op1
    LD (parser_io_op1_type), A
    ; Must be a register
    CP 8
    JP NC, _parse_in_err
    LD C, A                     ; C = register
    CALL parser_get_op2
    CP PARSER_MEM_C_PORT
    JP Z, _parse_in_r_c
    CP PARSER_MEM_NN
    JP Z, _parse_in_a_n
    ; Could be (n) parsed as constant in parens
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

_parse_in_a_n:
    ; IN A, (n) -> DB n  (only valid for A)
    LD A, C
    CP PARSER_REG8_A
    JP NZ, _parse_in_err
    LD HL, (parser_ld_op2_val)  ; reuse — actually we need op2 value
    ; op2 value from parse is in HL from parser_get_op2
    ; Actually, parser_parse_operand returned HL=value. Let's re-get:
    PUSH BC
    CALL parser_get_op2
    ; A=type, HL=value
    POP BC
    LD D, 0xDB
    LD E, L
    JP parser_emit2

_parse_in_r_c:
    ; IN r, (C) -> ED 40+r*8
    LD A, C
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0x40
    LD E, A
    LD D, PARSER_PREFIX_ED
    JP parser_emit2

_parse_in_err:
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

parser_io_op1_type: DEFB 0

_parse_out:
    CALL parser_get_op1
    ; op1 should be (n) or (C)
    CP PARSER_MEM_C_PORT
    JP Z, _parse_out_c
    CP PARSER_MEM_NN
    JP Z, _parse_out_n
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET

_parse_out_n:
    ; OUT (n), A -> D3 n
    ; Get the address value
    PUSH HL
    CALL parser_get_op2
    CP PARSER_REG8_A
    JP NZ, _parse_out_err
    POP HL                      ; HL = (n) value from op1
    ; Need to re-parse op1 for value
    PUSH AF
    CALL parser_get_op1
    ; HL = address value
    LD E, L
    POP AF
    LD D, 0xD3
    JP parser_emit2

_parse_out_c:
    ; OUT (C), r -> ED 41+r*8
    CALL parser_get_op2
    ; A = register type
    CP 8
    JP NC, _parse_out_err2
    ADD A, A
    ADD A, A
    ADD A, A
    ADD A, 0x41
    LD E, A
    LD D, PARSER_PREFIX_ED
    JP parser_emit2

_parse_out_err:
    POP HL
_parse_out_err2:
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET


; ============================================================================
; _parse_rotate — CB-prefix rotate/shift instructions
; RLC r:  CB 00+r    RRC r: CB 08+r
; RL r:   CB 10+r    RR r:  CB 18+r
; SLA r:  CB 20+r    SRA r: CB 28+r
; SRL r:  CB 38+r    SLL r: CB 30+r (undocumented)
; With (IX+d): DD CB d opcode
; With (IY+d): FD CB d opcode
; ============================================================================
_parse_rlc:
    LD C, 0x00
    JP _parse_cb_shift_common
_parse_rrc:
    LD C, 0x08
    JP _parse_cb_shift_common
_parse_rl:
    LD C, 0x10
    JP _parse_cb_shift_common
_parse_rr:
    LD C, 0x18
    JP _parse_cb_shift_common
_parse_sla:
    LD C, 0x20
    JP _parse_cb_shift_common
_parse_sra:
    LD C, 0x28
    JP _parse_cb_shift_common
_parse_sll:
    LD C, 0x30
    JP _parse_cb_shift_common
_parse_srl:
    LD C, 0x38
    JP _parse_cb_shift_common

_parse_cb_shift_common:
    ; C = base opcode within CB page
    LD A, C
    LD (parser_base_op), A
    CALL parser_get_op1
    CP PARSER_MEM_IXD
    JP Z, _parse_cb_shift_ixd
    CP PARSER_MEM_IYD
    JP Z, _parse_cb_shift_iyd
    ; Map (HL) memory operand to register slot 6
    CP PARSER_MEM_HL
    JP NZ, _parse_cb_shift_reg_check
    LD A, PARSER_REG8_HLI
_parse_cb_shift_reg_check:
    ; Must be 8-bit register (0-7)
    CP 8
    JP NC, _parse_cb_shift_err
    ; CB base+r
    LD HL, parser_base_op
    ADD A, (HL)
    LD E, A
    LD D, PARSER_PREFIX_CB
    JP parser_emit2

_parse_cb_shift_ixd:
    ; DD CB d (base+6)
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD (HL), PARSER_PREFIX_CB
    INC HL
    LD A, (parser_op_disp)
    LD (HL), A
    INC HL
    LD A, (parser_base_op)
    ADD A, 6                    ; (HL) slot
    LD (HL), A
    LD B, 4
    XOR A
    RET

_parse_cb_shift_iyd:
    ; FD CB d (base+6)
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD (HL), PARSER_PREFIX_CB
    INC HL
    LD A, (parser_op_disp)
    LD (HL), A
    INC HL
    LD A, (parser_base_op)
    ADD A, 6
    LD (HL), A
    LD B, 4
    XOR A
    RET

_parse_cb_shift_err:
    LD A, PARSER_ERR_INVALID
    LD B, 0
    RET


; ============================================================================
; _parse_bit_op — BIT/SET/RES n,r
; BIT n,r: CB 40+n*8+r
; RES n,r: CB 80+n*8+r
; SET n,r: CB C0+n*8+r
; With (IX+d): DD CB d opcode
; With (IY+d): FD CB d opcode
; ============================================================================
_parse_bit:
    LD C, 0x40
    JP _parse_bit_common
_parse_res:
    LD C, 0x80
    JP _parse_bit_common
_parse_set:
    LD C, 0xC0
    JP _parse_bit_common

_parse_bit_common:
    ; C = base (BIT=0x40, RES=0x80, SET=0xC0)
    ; op1 = bit number (0-7), op2 = register
    LD A, C
    LD (parser_base_op), A
    CALL parser_get_op1
    ; HL = bit number
    LD A, L
    CP 8
    JP NC, _parse_bit_err
    ; A = bit number
    ADD A, A
    ADD A, A
    ADD A, A                    ; n*8
    LD HL, parser_base_op
    ADD A, (HL)                 ; base + n*8
    LD (parser_base_op), A      ; save partial opcode

    CALL parser_get_op2
    CP PARSER_MEM_IXD
    JP Z, _parse_bit_ixd
    CP PARSER_MEM_IYD
    JP Z, _parse_bit_iyd
    ; Map (HL) memory operand to register slot 6
    CP PARSER_MEM_HL
    JP NZ, _parse_bit_reg_check
    LD A, PARSER_REG8_HLI
_parse_bit_reg_check:
    ; Must be 8-bit register
    CP 8
    JP NC, _parse_bit_err
    LD HL, parser_base_op
    ADD A, (HL)                 ; complete opcode
    LD E, A
    LD D, PARSER_PREFIX_CB
    JP parser_emit2

_parse_bit_ixd:
    ; DD CB d opcode
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IX
    INC HL
    LD (HL), PARSER_PREFIX_CB
    INC HL
    LD A, (parser_op_disp)
    LD (HL), A
    INC HL
    LD A, (parser_base_op)
    ADD A, 6                    ; (HL) slot for IX+d
    LD (HL), A
    LD B, 4
    XOR A
    RET

_parse_bit_iyd:
    LD HL, za_parse_buf
    LD (HL), PARSER_PREFIX_IY
    INC HL
    LD (HL), PARSER_PREFIX_CB
    INC HL
    LD A, (parser_op_disp)
    LD (HL), A
    INC HL
    LD A, (parser_base_op)
    ADD A, 6
    LD (HL), A
    LD B, 4
    XOR A
    RET

_parse_bit_err:
    LD A, PARSER_ERR_RANGE
    LD B, 0
    RET


; ============================================================================
; _parse_block — Block transfer and search instructions (ED prefix)
; LDI:  ED A0    LDIR: ED B0
; LDD:  ED A8    LDDR: ED B8
; CPI:  ED A1    CPIR: ED B1
; CPD:  ED A9    CPDR: ED B9
; INI:  ED A2    INIR: ED B2
; IND:  ED AA    INDR: ED BA
; OUTI: ED A3    OTIR: ED B3
; OUTD: ED AB    OTDR: ED BB
; Each is dispatched directly from the instruction table.
; ============================================================================
_parse_ldi:
    LD D, PARSER_PREFIX_ED
    LD E, 0xA0
    JP parser_emit2
_parse_ldir:
    LD D, PARSER_PREFIX_ED
    LD E, 0xB0
    JP parser_emit2
_parse_ldd:
    LD D, PARSER_PREFIX_ED
    LD E, 0xA8
    JP parser_emit2
_parse_lddr:
    LD D, PARSER_PREFIX_ED
    LD E, 0xB8
    JP parser_emit2
_parse_cpi:
    LD D, PARSER_PREFIX_ED
    LD E, 0xA1
    JP parser_emit2
_parse_cpir:
    LD D, PARSER_PREFIX_ED
    LD E, 0xB1
    JP parser_emit2
_parse_cpd:
    LD D, PARSER_PREFIX_ED
    LD E, 0xA9
    JP parser_emit2
_parse_cpdr:
    LD D, PARSER_PREFIX_ED
    LD E, 0xB9
    JP parser_emit2
_parse_ini:
    LD D, PARSER_PREFIX_ED
    LD E, 0xA2
    JP parser_emit2
_parse_inir:
    LD D, PARSER_PREFIX_ED
    LD E, 0xB2
    JP parser_emit2
_parse_ind:
    LD D, PARSER_PREFIX_ED
    LD E, 0xAA
    JP parser_emit2
_parse_indr:
    LD D, PARSER_PREFIX_ED
    LD E, 0xBA
    JP parser_emit2
_parse_outi:
    LD D, PARSER_PREFIX_ED
    LD E, 0xA3
    JP parser_emit2
_parse_otir:
    LD D, PARSER_PREFIX_ED
    LD E, 0xB3
    JP parser_emit2
_parse_outd:
    LD D, PARSER_PREFIX_ED
    LD E, 0xAB
    JP parser_emit2
_parse_otdr:
    LD D, PARSER_PREFIX_ED
    LD E, 0xBB
    JP parser_emit2


; ============================================================================
; Instruction Name Table
; Each entry: 7 bytes mnemonic (null-padded) + 2 bytes handler pointer
; MUST be sorted alphabetically for binary search
; ============================================================================
parser_instr_table:
    ; ADC
    DEFB "adc", 0, 0, 0, 0
    DEFW _parse_adc
    ; ADD
    DEFB "add", 0, 0, 0, 0
    DEFW _parse_add
    ; AND
    DEFB "and", 0, 0, 0, 0
    DEFW _parse_and
    ; BIT
    DEFB "bit", 0, 0, 0, 0
    DEFW _parse_bit
    ; CALL
    DEFB "call", 0, 0, 0
    DEFW _parse_call
    ; CCF
    DEFB "ccf", 0, 0, 0, 0
    DEFW _parse_ccf
    ; CP
    DEFB "cp", 0, 0, 0, 0, 0
    DEFW _parse_cp
    ; CPD
    DEFB "cpd", 0, 0, 0, 0
    DEFW _parse_cpd
    ; CPDR
    DEFB "cpdr", 0, 0, 0
    DEFW _parse_cpdr
    ; CPI
    DEFB "cpi", 0, 0, 0, 0
    DEFW _parse_cpi
    ; CPIR
    DEFB "cpir", 0, 0, 0
    DEFW _parse_cpir
    ; CPL
    DEFB "cpl", 0, 0, 0, 0
    DEFW _parse_cpl
    ; DAA
    DEFB "daa", 0, 0, 0, 0
    DEFW _parse_daa
    ; DEC
    DEFB "dec", 0, 0, 0, 0
    DEFW _parse_dec
    ; DI
    DEFB "di", 0, 0, 0, 0, 0
    DEFW _parse_di
    ; DJNZ
    DEFB "djnz", 0, 0, 0
    DEFW _parse_djnz
    ; EI
    DEFB "ei", 0, 0, 0, 0, 0
    DEFW _parse_ei
    ; EX
    DEFB "ex", 0, 0, 0, 0, 0
    DEFW _parse_ex
    ; EXX
    DEFB "exx", 0, 0, 0, 0
    DEFW _parse_exx
    ; HALT
    DEFB "halt", 0, 0, 0
    DEFW _parse_halt
    ; IM
    DEFB "im", 0, 0, 0, 0, 0
    DEFW _parse_im
    ; IN
    DEFB "in", 0, 0, 0, 0, 0
    DEFW _parse_in
    ; INC
    DEFB "inc", 0, 0, 0, 0
    DEFW _parse_inc
    ; IND
    DEFB "ind", 0, 0, 0, 0
    DEFW _parse_ind
    ; INDR
    DEFB "indr", 0, 0, 0
    DEFW _parse_indr
    ; INI
    DEFB "ini", 0, 0, 0, 0
    DEFW _parse_ini
    ; INIR
    DEFB "inir", 0, 0, 0
    DEFW _parse_inir
    ; JP
    DEFB "jp", 0, 0, 0, 0, 0
    DEFW _parse_jp
    ; JR
    DEFB "jr", 0, 0, 0, 0, 0
    DEFW _parse_jr
    ; LD
    DEFB "ld", 0, 0, 0, 0, 0
    DEFW _parse_ld
    ; LDD
    DEFB "ldd", 0, 0, 0, 0
    DEFW _parse_ldd
    ; LDDR
    DEFB "lddr", 0, 0, 0
    DEFW _parse_lddr
    ; LDI
    DEFB "ldi", 0, 0, 0, 0
    DEFW _parse_ldi
    ; LDIR
    DEFB "ldir", 0, 0, 0
    DEFW _parse_ldir
    ; NEG
    DEFB "neg", 0, 0, 0, 0
    DEFW _parse_neg
    ; NOP
    DEFB "nop", 0, 0, 0, 0
    DEFW _parse_nop
    ; OR
    DEFB "or", 0, 0, 0, 0, 0
    DEFW _parse_or
    ; OTDR
    DEFB "otdr", 0, 0, 0
    DEFW _parse_otdr
    ; OTIR
    DEFB "otir", 0, 0, 0
    DEFW _parse_otir
    ; OUT
    DEFB "out", 0, 0, 0, 0
    DEFW _parse_out
    ; OUTD
    DEFB "outd", 0, 0, 0
    DEFW _parse_outd
    ; OUTI
    DEFB "outi", 0, 0, 0
    DEFW _parse_outi
    ; POP
    DEFB "pop", 0, 0, 0, 0
    DEFW _parse_pop
    ; PUSH
    DEFB "push", 0, 0, 0
    DEFW _parse_push
    ; RES
    DEFB "res", 0, 0, 0, 0
    DEFW _parse_res
    ; RET
    DEFB "ret", 0, 0, 0, 0
    DEFW _parse_ret
    ; RETI
    DEFB "reti", 0, 0, 0
    DEFW _parse_reti
    ; RETN
    DEFB "retn", 0, 0, 0
    DEFW _parse_retn
    ; RL
    DEFB "rl", 0, 0, 0, 0, 0
    DEFW _parse_rl
    ; RLA
    DEFB "rla", 0, 0, 0, 0
    DEFW _parse_rla
    ; RLC
    DEFB "rlc", 0, 0, 0, 0
    DEFW _parse_rlc
    ; RLCA
    DEFB "rlca", 0, 0, 0
    DEFW _parse_rlca
    ; RLD
    DEFB "rld", 0, 0, 0, 0
    DEFW _parse_rld
    ; RR
    DEFB "rr", 0, 0, 0, 0, 0
    DEFW _parse_rr
    ; RRA
    DEFB "rra", 0, 0, 0, 0
    DEFW _parse_rra
    ; RRC
    DEFB "rrc", 0, 0, 0, 0
    DEFW _parse_rrc
    ; RRCA
    DEFB "rrca", 0, 0, 0
    DEFW _parse_rrca
    ; RRD
    DEFB "rrd", 0, 0, 0, 0
    DEFW _parse_rrd
    ; RST
    DEFB "rst", 0, 0, 0, 0
    DEFW _parse_rst
    ; SBC
    DEFB "sbc", 0, 0, 0, 0
    DEFW _parse_sbc
    ; SCF
    DEFB "scf", 0, 0, 0, 0
    DEFW _parse_scf
    ; SET
    DEFB "set", 0, 0, 0, 0
    DEFW _parse_set
    ; SLA
    DEFB "sla", 0, 0, 0, 0
    DEFW _parse_sla
    ; SLL
    DEFB "sll", 0, 0, 0, 0
    DEFW _parse_sll
    ; SRA
    DEFB "sra", 0, 0, 0, 0
    DEFW _parse_sra
    ; SRL
    DEFB "srl", 0, 0, 0, 0
    DEFW _parse_srl
    ; SUB
    DEFB "sub", 0, 0, 0, 0
    DEFW _parse_sub
    ; XOR
    DEFB "xor", 0, 0, 0, 0
    DEFW _parse_xor

PARSER_INSTR_COUNT EQU 68       ; total number of entries in the table


; ============================================================================
; End of parser.asm
; ============================================================================

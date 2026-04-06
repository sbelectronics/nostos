; ============================================================
; zealasm.asm - NostOS Z80 Assembler
; Based on Zealasm by Zeal 8-bit Computer (Apache 2.0)
; Ported to NostOS with .APP relocation output support
;
; Usage: ZEALASM input.asm output.app
;
; Outputs NostOS .APP relocatable format:
;   [2 bytes: code_length]
;   [N bytes: binary (ORG 0)]
;   [2 bytes: reloc_count]
;   [R*2 bytes: relocation offsets]
; ============================================================

    INCLUDE "../../../src/include/constants.asm"
    INCLUDE "../../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header
    JP   za_main

    ; Header pad: 13 bytes of zeros (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================

ZA_LINE_MAX         EQU 128     ; max source line length
ZA_MAX_RELOCS       EQU 2048    ; max relocation entries
ZA_LABEL_MAX        EQU 15      ; max label length (must be < LIST_KEY_SIZE for null terminator)

; Symbol table entry layout
LIST_KEY_SIZE       EQU 16
LIST_VALUE_OFF      EQU 16
LIST_NEXT_OFF       EQU 18
LIST_FLAGS_OFF      EQU 20
LIST_ENTRY_SIZE     EQU 21

; Symbol flags
SYM_FLAG_EQU        EQU 1       ; label defined by EQU (not relocatable)

; Parser output flags
ZA_REF_NONE         EQU 0       ; no label reference
ZA_REF_ABS_FOUND    EQU 1       ; absolute ref, label resolved
ZA_REF_ABS_FWDREF   EQU 2       ; absolute ref, forward reference
ZA_REF_REL_FOUND    EQU 3       ; relative ref, label resolved
ZA_REF_REL_FWDREF   EQU 4       ; relative ref, forward reference

; Forward reference value encoding (in list entry value field)
; bit 15 = 1 for relative, 0 for absolute
; bits 14-0 = binary offset
ZA_FWDREF_REL_BIT   EQU 0x80   ; high byte bit 7

; ============================================================
; za_main - Entry point
; ============================================================
za_main:
    ; Debug: print version to confirm correct binary
    LD   DE, za_msg_version
    CALL za_print_str
    CALL za_print_crlf
    ; --- Parse command-line arguments ---
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, H
    OR   L
    JP   Z, za_err_usage
    LD   A, (HL)
    OR   A
    JP   Z, za_err_usage

    ; First arg: input filename
    LD   DE, za_input_name
    CALL za_copy_arg
    ; HL now points past first arg
    ; Skip spaces
    CALL strltrim
    OR   A
    JP   Z, za_err_usage

    ; Second arg: output filename
    LD   DE, za_output_name
    CALL za_copy_arg

    ; --- Initialize state ---
    LD   HL, 0
    LD   (za_bin_size), HL
    LD   (za_org), HL
    LD   (za_line_num), HL
    LD   (za_reloc_count), HL
    LD   (za_ref_list), HL
    LD   (za_err_count), HL
    XOR  A
    LD   (za_org_set), A

    ; Get top of memory for heap
    LD   C, SYS_MEMTOP
    CALL KERNELADDR
    ; Reserve 1024 bytes for stack
    LD   DE, 1024
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    LD   (za_heap_top), HL

    ; Set heap bottom limit (binary buffer start + some margin)
    LD   HL, za_bin_buffer
    LD   (za_heap_bottom), HL

    ; Initialize symbol table
    CALL data_init

    ; --- Open files ---
    LD   DE, za_input_name
    CALL file_open_input
    OR   A
    JP   NZ, za_err_open_in

    LD   DE, za_output_name
    CALL file_open_output
    OR   A
    JP   NZ, za_err_open_out

    ; --- Print assembling message ---
    LD   DE, za_msg_assembling
    CALL za_print_str
    LD   DE, za_input_name
    CALL za_print_str
    CALL za_print_crlf

    ; === Assembly pass ===
    CALL za_assemble_file

    ; === Fixup forward references ===
    CALL za_fixup_references

    ; === Write output ===
    LD   HL, (za_err_count)
    LD   A, H
    OR   L
    JP   NZ, za_skip_output

    CALL za_write_app_output

    JP   za_done

za_skip_output:
    LD   DE, za_msg_errors
    CALL za_print_str

za_done:
    ; Close files
    CALL file_close_input_output

    ; Print summary
    CALL za_print_summary

    ; Exit
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; za_assemble_file - Main assembly loop
; Read lines, parse labels, directives, and instructions
; ============================================================
za_assemble_file:
_za_asm_loop:
    ; Read next line
    CALL file_read_input_line
    CP   ERR_EOF
    RET  Z
    OR   A
    JP   NZ, za_err_read

    ; Increment line number
    LD   HL, (za_line_num)
    INC  HL
    LD   (za_line_num), HL

    ; Reload line buffer pointer (HL was clobbered by line_num increment)
    LD   HL, file_line_buf
    ; Check if line starts with whitespace (no label possible)
    LD   A, (HL)
    CP   ' '
    JP   Z, _za_asm_indented
    CP   0x09               ; tab
    JP   Z, _za_asm_indented
    XOR  A
    JP   _za_asm_save_indent
_za_asm_indented:
    LD   A, 1
_za_asm_save_indent:
    LD   (za_had_indent), A

    ; Trim leading whitespace
    CALL strltrim
    ; Check for empty line or comment
    LD   A, (HL)
    OR   A
    JP   Z, _za_asm_loop    ; empty line
    CP   ';'
    JP   Z, _za_asm_loop    ; comment line

    ; Strip trailing comment: find ';' and null-terminate
    PUSH HL
    CALL za_strip_comment
    POP  HL

    ; Trim trailing whitespace
    CALL strrtrim

    ; Check for label: only if line was NOT indented
    LD   A, (za_had_indent)
    OR   A
    JP   NZ, _za_asm_no_label
    ; Starts with alpha or underscore?
    LD   A, (HL)
    CP   '_'
    JP   Z, _za_asm_has_label
    CALL is_alpha
    JP   C, _za_asm_no_label

_za_asm_has_label:
    ; Parse label: read until ':', space, or end
    PUSH HL                 ; save line start
    CALL za_parse_label
    ; DE = pointer past label (at ':' or space or end)
    ; za_label_buf has the label name
    POP  HL

    ; Define the label at current binary position
    PUSH DE
    LD   HL, za_label_buf
    LD   DE, (za_bin_size)
    ; Add ORG offset
    LD   A, (za_org_set)
    OR   A
    JP   Z, _za_asm_def_label_noorg
    PUSH HL
    LD   HL, (za_org)
    ADD  HL, DE
    EX   DE, HL
    POP  HL
_za_asm_def_label_noorg:
    CALL data_insert
    CP   2
    JP   Z, za_err_dup_label
    POP  HL                 ; HL = pointer past label

    ; Skip past ':' if present
    LD   A, (HL)
    CP   ':'
    JP   NZ, _za_asm_after_label
    INC  HL
_za_asm_after_label:
    ; Trim whitespace after label
    CALL strltrim
    ; If nothing after label, continue
    LD   A, (HL)
    OR   A
    JP   Z, _za_asm_loop

_za_asm_no_label:
    ; HL points to instruction or directive
    ; Make a lowercase copy for matching
    LD   (za_inst_ptr), HL

    ; Check for directives first
    CALL za_check_directive
    OR   A
    JP   Z, _za_asm_loop    ; directive handled

    ; Not a directive — parse as instruction
    LD   HL, (za_inst_ptr)

    ; Split into mnemonic and operands at first whitespace (space or tab)
    PUSH HL
    CALL strsep_ws
    ; After strsep_ws: A=0 if found (DE=past delim), A!=0 if not found
    POP  HL
    ; HL = mnemonic, DE = operands (or garbage if not found)
    OR   A
    JP   NZ, _za_asm_no_operands
    ; DE points to operands
    JP   _za_asm_has_operands
_za_asm_no_operands:
    LD   DE, za_empty_str
_za_asm_has_operands:
    ; Save operand pointer
    LD   (za_operand_ptr), DE

    ; Lowercase the mnemonic
    CALL strtolower

    ; Call parser
    LD   DE, (za_operand_ptr)
    CALL parser_parse_line
    OR   A
    JP   NZ, za_err_parse

    ; B = number of bytes generated in za_parse_buf
    ; Emit the bytes to binary output
    LD   A, B
    OR   A
    JP   Z, _za_asm_loop    ; no bytes (shouldn't happen for valid instruction)

    ; Copy bytes from za_parse_buf to binary output
    LD   C, B               ; save count
    LD   HL, za_parse_buf
    LD   DE, (za_bin_size)
    PUSH DE                 ; save starting binary offset
    PUSH BC

    ; Get destination address in binary buffer
    PUSH HL
    LD   HL, za_bin_buffer
    ADD  HL, DE             ; HL = dest addr in bin buffer
    EX   DE, HL             ; DE = dest
    POP  HL                 ; HL = parse_buf

    ; Copy C bytes from HL to DE
    LD   B, 0               ; BC = count
_za_emit_copy:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  C
    JP   NZ, _za_emit_copy

    POP  BC                 ; B = byte count
    POP  DE                 ; DE = starting binary offset

    ; Update binary size
    LD   HL, (za_bin_size)
    LD   C, B
    LD   B, 0
    ADD  HL, BC
    LD   (za_bin_size), HL

    ; Handle label references from parser
    LD   A, (za_parse_ref_type)
    OR   A
    JP   Z, _za_asm_loop    ; no label reference

    ; DE = starting binary offset of this instruction
    ; Compute ref_off from byte count and ref type:
    ;   absolute refs: address is last 2 bytes → ref_off = bytecount - 2
    ;   relative refs: displacement is last byte → ref_off = bytecount - 1
    ; C still has the byte count from earlier
    LD   A, (za_parse_ref_type)
    CP   ZA_REF_REL_FOUND
    JP   Z, _za_asm_ref_rel_off
    CP   ZA_REF_REL_FWDREF
    JP   Z, _za_asm_ref_rel_off
    ; Absolute: ref_off = C - 2
    LD   A, C
    SUB  2
    JP   _za_asm_ref_calc
_za_asm_ref_rel_off:
    ; Relative: ref_off = C - 1
    LD   A, C
    DEC  A
_za_asm_ref_calc:
    LD   C, A
    LD   B, 0
    EX   DE, HL             ; HL = starting bin offset
    ADD  HL, BC             ; HL = binary offset of the address bytes

    LD   A, (za_parse_ref_type)
    CP   ZA_REF_ABS_FOUND
    JP   Z, _za_asm_add_reloc
    CP   ZA_REF_ABS_FWDREF
    JP   Z, _za_asm_add_fwdref_abs
    CP   ZA_REF_REL_FWDREF
    JP   Z, _za_asm_add_fwdref_rel
    ; ZA_REF_REL_FOUND: relative ref already resolved, no action needed
    JP   _za_asm_loop

_za_asm_add_reloc:
    ; Add relocation entry for absolute reference
    ; HL = binary offset of address
    EX   DE, HL
    CALL za_add_reloc_entry
    JP   _za_asm_loop

_za_asm_add_fwdref_abs:
    ; Add forward reference (absolute)
    ; HL = binary offset
    PUSH HL
    LD   HL, za_parse_label_name
    POP  DE                 ; DE = binary offset (value for list entry)
    ; bit 15 clear = absolute
    CALL za_add_fwd_ref
    JP   _za_asm_loop

_za_asm_add_fwdref_rel:
    ; Add forward reference (relative)
    ; HL = binary offset
    PUSH HL
    LD   HL, za_parse_label_name
    POP  DE                 ; DE = binary offset
    ; Set bit 15 = relative
    LD   A, D
    OR   ZA_FWDREF_REL_BIT
    LD   D, A
    CALL za_add_fwd_ref
    JP   _za_asm_loop

; ============================================================
; za_check_directive - Check and handle assembler directives
; Input: HL = instruction text (not lowercased yet)
; Output: A = 0 if directive handled, non-zero if not a directive
; ============================================================
za_check_directive:
    ; Save original pointer
    LD   (za_dir_ptr), HL

    ; Make lowercase copy in temp buffer for matching
    LD   DE, za_dir_buf
    LD   B, 7                   ; max chars (za_dir_buf is 8 bytes)
    PUSH HL
_za_dir_copy:
    LD   A, (HL)
    CP   ' '
    JP   Z, _za_dir_copy_end
    CP   0x09                   ; tab
    JP   Z, _za_dir_copy_end
    OR   A
    JP   Z, _za_dir_copy_end
    CALL to_lower
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, _za_dir_copy
    ; Buffer full — skip remaining chars to whitespace/end
_za_dir_copy_skip:
    LD   A, (HL)
    CP   ' '
    JP   Z, _za_dir_copy_end
    CP   0x09
    JP   Z, _za_dir_copy_end
    OR   A
    JP   Z, _za_dir_copy_end
    INC  HL
    JP   _za_dir_copy_skip
_za_dir_copy_end:
    XOR  A
    LD   (DE), A            ; null-terminate
    POP  HL

    ; Try matching directives
    LD   DE, za_dir_buf

    ; Check "org"
    PUSH HL
    LD   HL, za_str_org
    CALL strcmp
    POP  HL
    JP   Z, _za_dir_org

    ; Check "equ"
    PUSH HL
    PUSH DE
    LD   HL, za_str_equ
    CALL strcmp
    POP  DE
    POP  HL
    JP   Z, _za_dir_equ

    ; Check "db" / "defb"
    PUSH HL
    PUSH DE
    LD   HL, za_str_db
    CALL strcmp
    POP  DE
    POP  HL
    JP   Z, _za_dir_db
    PUSH HL
    PUSH DE
    LD   HL, za_str_defb
    CALL strcmp
    POP  DE
    POP  HL
    JP   Z, _za_dir_db

    ; Check "dw" / "defw"
    PUSH HL
    PUSH DE
    LD   HL, za_str_dw
    CALL strcmp
    POP  DE
    POP  HL
    JP   Z, _za_dir_dw
    PUSH HL
    PUSH DE
    LD   HL, za_str_defw
    CALL strcmp
    POP  DE
    POP  HL
    JP   Z, _za_dir_dw

    ; Check "dm" / "defm"
    PUSH HL
    PUSH DE
    LD   HL, za_str_dm
    CALL strcmp
    POP  DE
    POP  HL
    JP   Z, _za_dir_dm
    PUSH HL
    PUSH DE
    LD   HL, za_str_defm
    CALL strcmp
    POP  DE
    POP  HL
    JP   Z, _za_dir_dm

    ; Check "ds" / "defs"
    PUSH HL
    PUSH DE
    LD   HL, za_str_ds
    CALL strcmp
    POP  DE
    POP  HL
    JP   Z, _za_dir_ds
    PUSH HL
    PUSH DE
    LD   HL, za_str_defs
    CALL strcmp
    POP  DE
    POP  HL
    JP   Z, _za_dir_ds

    ; Not a directive
    LD   A, 1
    RET

; --- ORG directive ---
; ORG sets a base address added to all subsequent label values.
; It does NOT pad the binary or adjust za_bin_size — the output
; file always starts at offset 0. This is correct for NostOS
; .APP relocatable binaries, where the loader places code at a
; runtime address. Label value = za_bin_size + za_org.
_za_dir_org:
    ; Skip past "org" in original text and get value
    LD   HL, (za_dir_ptr)
    CALL _za_skip_keyword
    CALL strltrim
    CALL parse_int
    OR   A
    JP   NZ, za_err_bad_value
    LD   (za_org), HL
    LD   A, 1
    LD   (za_org_set), A
    XOR  A
    RET

; --- EQU directive ---
; Note: EQU must follow a label on the same line
; The label was already defined with current bin position
; We need to REDEFINE it with the EQU value
_za_dir_equ:
    LD   HL, (za_dir_ptr)
    CALL _za_skip_keyword
    CALL strltrim
    CALL parse_int
    OR   A
    JP   NZ, za_err_bad_value
    ; HL = value
    ; Need to update the label that was just defined
    ; The label is in za_label_buf
    ; Re-insert will fail with "already exists" — we need to update
    ; For now: look it up and patch the value in the entry
    PUSH HL                 ; save value
    LD   HL, za_label_buf
    LD   A, (HL)
    OR   A
    JP   Z, _za_dir_equ_nolabel
    CALL _za_data_find_entry
    ; HL = entry or error
    OR   A
    JP   NZ, _za_dir_equ_nolabel
    ; HL = entry, patch value at offset LIST_VALUE_OFF
    LD   DE, LIST_VALUE_OFF
    ADD  HL, DE
    POP  DE                 ; DE = new value
    LD   (HL), E
    INC  HL
    LD   (HL), D
    ; Set EQU flag at LIST_FLAGS_OFF (= value+2 bytes, next+2 bytes, flags)
    INC  HL                 ; skip next_lo
    INC  HL                 ; skip next_hi
    INC  HL                 ; flags byte
    LD   (HL), SYM_FLAG_EQU
    XOR  A
    RET
_za_dir_equ_nolabel:
    POP  HL
    ; EQU without preceding label — error
    LD   DE, za_msg_equ_nolabel
    CALL za_print_error
    XOR  A
    RET

; --- DB directive ---
_za_dir_db:
    LD   HL, (za_dir_ptr)
    CALL _za_skip_keyword
    CALL strltrim
    ; Parse value
    CALL parse_int
    OR   A
    JP   NZ, za_err_bad_value
    ; HL = value, emit low byte
    LD   A, L
    CALL za_emit_byte
    XOR  A
    RET

; --- DW directive ---
_za_dir_dw:
    LD   HL, (za_dir_ptr)
    CALL _za_skip_keyword
    CALL strltrim
    ; Check if it's a label reference (starts with alpha or '_')
    LD   A, (HL)
    CALL is_alpha
    JP   NC, _za_dir_dw_label  ; alpha → label
    CP   '_'
    JP   NZ, _za_dir_dw_num   ; not alpha, not '_' → number
_za_dir_dw_label:
    ; It's a label — resolve it
    PUSH HL
    CALL data_get
    POP  HL
    OR   A
    JP   NZ, _za_dir_dw_fwd
    ; Defined: emit value and record relocation
    LD   A, E
    CALL za_emit_byte
    LD   A, D
    CALL za_emit_byte
    ; Check if EQU constant (no relocation needed)
    LD   A, (data_get_flags)
    AND  SYM_FLAG_EQU
    JP   NZ, _za_dir_dw_done
    ; Record relocation at bin_pos - 2
    LD   DE, (za_bin_size)
    DEC  DE
    DEC  DE
    CALL za_add_reloc_entry
_za_dir_dw_done:
    XOR  A
    RET
_za_dir_dw_fwd:
    ; Forward reference: emit 0x0000, add to forward ref list
    XOR  A
    CALL za_emit_byte
    XOR  A
    CALL za_emit_byte
    ; Record forward ref at bin_pos - 2
    PUSH HL                 ; save label name
    LD   DE, (za_bin_size)
    DEC  DE
    DEC  DE                 ; DE = offset of the address
    POP  HL                 ; HL = label name
    ; Copy label name to za_parse_label_name for fwd ref
    PUSH DE
    LD   DE, za_parse_label_name
    CALL strcpy
    POP  DE
    LD   HL, za_parse_label_name
    ; DE = binary offset (absolute)
    CALL za_add_fwd_ref
    XOR  A
    RET
_za_dir_dw_num:
    ; Numeric constant
    CALL parse_int
    OR   A
    JP   NZ, za_err_bad_value
    ; HL = value, emit little-endian
    LD   A, L
    CALL za_emit_byte
    LD   A, H
    CALL za_emit_byte
    XOR  A
    RET

; --- DM directive (define message/string) ---
_za_dir_dm:
    LD   HL, (za_dir_ptr)
    CALL _za_skip_keyword
    CALL strltrim
    ; Parse quoted string
    CALL parse_str
    OR   A
    JP   NZ, za_err_bad_str
    ; HL = string data, BC = length
    ; Emit all bytes
_za_dir_dm_loop:
    LD   A, B
    OR   C
    JP   Z, _za_dir_dm_done
    LD   A, (HL)
    CALL za_emit_byte
    INC  HL
    DEC  BC
    JP   _za_dir_dm_loop
_za_dir_dm_done:
    XOR  A
    RET

; --- DS directive (define space) ---
_za_dir_ds:
    LD   HL, (za_dir_ptr)
    CALL _za_skip_keyword
    CALL strltrim
    CALL parse_int
    OR   A
    JP   NZ, za_err_bad_value
    ; HL = count
    LD   B, H
    LD   C, L
_za_dir_ds_loop:
    LD   A, B
    OR   C
    JP   Z, _za_dir_ds_done
    XOR  A
    CALL za_emit_byte
    DEC  BC
    JP   _za_dir_ds_loop
_za_dir_ds_done:
    XOR  A
    RET

; Skip past keyword in original text (advance past non-space chars)
_za_skip_keyword:
    LD   A, (HL)
    OR   A
    RET  Z
    CP   ' '
    RET  Z
    CP   0x09
    RET  Z
    INC  HL
    JP   _za_skip_keyword

; ============================================================
; za_fixup_references - Resolve forward references
; Walk the forward reference list and patch binary output
; ============================================================
za_fixup_references:
    LD   HL, (za_ref_list)
_za_fixup_loop:
    LD   A, H
    OR   L
    RET  Z                  ; end of list

    PUSH HL                 ; save current entry

    ; Look up the label (entry key = label name)
    ; HL already points to the entry, which starts with the key
    CALL data_get
    OR   A
    JP   NZ, _za_fixup_undefined

    ; DE = label value
    ; Get the binary offset from the entry's value field
    POP  HL                 ; HL = entry
    PUSH HL
    PUSH DE                 ; save label value

    ; Read packed offset from entry value field
    LD   BC, LIST_VALUE_OFF
    ADD  HL, BC
    LD   C, (HL)
    INC  HL
    LD   B, (HL)            ; BC = packed offset

    ; Check relative flag (bit 15 = high byte bit 7)
    LD   A, B
    AND  ZA_FWDREF_REL_BIT
    LD   (za_fixup_is_rel), A
    ; Clear the flag to get actual offset
    LD   A, B
    AND  0x7F
    LD   B, A               ; BC = actual binary offset

    POP  DE                 ; DE = label value

    ; Get address in binary buffer
    LD   HL, za_bin_buffer
    ADD  HL, BC             ; HL = address to patch

    LD   A, (za_fixup_is_rel)
    OR   A
    JP   NZ, _za_fixup_relative

    ; Absolute reference: write label value, add relocation
    LD   (HL), E
    INC  HL
    LD   (HL), D
    ; Add relocation entry for this offset
    PUSH BC
    EX   DE, HL
    LD   D, B
    LD   E, C               ; DE = binary offset
    CALL za_add_reloc_entry
    POP  BC
    JP   _za_fixup_next

_za_fixup_relative:
    ; Relative reference (JR/DJNZ): compute displacement
    ; displacement = target - (disp_byte_offset + 1)
    ; BC = binary offset of displacement byte (= JR_start + 1)
    ; PC after instruction = BC + 1 = JR_start + 2
    ; DE = target label value
    PUSH BC
    INC  BC                 ; BC = PC after instruction
    ; displacement = DE - BC
    LD   A, E
    SUB  C
    LD   E, A
    LD   A, D
    SBC  A, B
    ; Check if displacement fits in signed byte (-128..+127)
    ; If D != 0 and D != 0xFF, it's out of range
    OR   A
    JP   Z, _za_fixup_rel_pos
    CP   0xFF
    JP   Z, _za_fixup_rel_neg
    ; Out of range
    POP  BC
    LD   DE, za_msg_rel_range
    CALL za_print_error
    JP   _za_fixup_next
_za_fixup_rel_pos:
    ; Positive displacement, check E <= 127
    LD   A, E
    AND  0x80
    JP   NZ, _za_fixup_rel_oor
    JP   _za_fixup_rel_ok
_za_fixup_rel_neg:
    ; Negative displacement, check E >= 128
    LD   A, E
    AND  0x80
    JP   Z, _za_fixup_rel_oor
_za_fixup_rel_ok:
    POP  BC
    ; Write displacement
    LD   (HL), E
    JP   _za_fixup_next
_za_fixup_rel_oor:
    POP  BC
    LD   DE, za_msg_rel_range
    CALL za_print_error
    JP   _za_fixup_next

_za_fixup_undefined:
    ; Label not found — error
    POP  HL                 ; HL = entry (label name is at start)
    LD   DE, za_msg_undef
    CALL za_print_error
    ; Also print the label name
    EX   DE, HL
    CALL za_print_str
    CALL za_print_crlf

_za_fixup_next:
    ; Advance to next entry in forward reference list
    POP  HL                 ; HL = current entry
    CALL data_list_get_next
    JP   _za_fixup_loop

; ============================================================
; za_write_app_output - Write .APP relocatable format
; ============================================================
za_write_app_output:
    ; Write code_length (2 bytes, little-endian)
    LD   HL, (za_bin_size)
    LD   A, L
    LD   (za_temp_word), A
    LD   A, H
    LD   (za_temp_word + 1), A
    LD   HL, za_temp_word
    LD   BC, 2
    CALL file_write_output
    OR   A
    JP   NZ, za_err_write

    ; Write binary code
    LD   HL, za_bin_buffer
    LD   BC, (za_bin_size)
    CALL file_write_output
    OR   A
    JP   NZ, za_err_write

    ; Write reloc_count (2 bytes)
    LD   HL, (za_reloc_count)
    LD   A, L
    LD   (za_temp_word), A
    LD   A, H
    LD   (za_temp_word + 1), A
    LD   HL, za_temp_word
    LD   BC, 2
    CALL file_write_output
    OR   A
    JP   NZ, za_err_write

    ; Write relocation entries (each 2 bytes)
    LD   HL, za_reloc_buf
    LD   DE, (za_reloc_count)
    ; Total bytes = reloc_count * 2
    LD   A, D
    OR   E
    JP   Z, _za_write_done
    ; BC = DE * 2
    EX   DE, HL             ; HL = count
    ADD  HL, HL             ; HL = count * 2
    LD   B, H
    LD   C, L
    LD   HL, za_reloc_buf
    CALL file_write_output
    OR   A
    JP   NZ, za_err_write

_za_write_done:
    ; Flush remaining bytes
    CALL file_flush_output
    OR   A
    JP   NZ, za_err_write

    ; Set file size
    ; Total = 2 + bin_size + 2 + reloc_count * 2
    LD   HL, (za_bin_size)
    LD   DE, 4              ; header (2) + reloc header (2)
    ADD  HL, DE
    LD   DE, (za_reloc_count)
    EX   DE, HL
    ADD  HL, HL             ; reloc_count * 2
    ADD  HL, DE             ; total size
    EX   DE, HL             ; DE = total size
    CALL file_set_output_size

    XOR  A
    RET

; ============================================================
; Helper routines
; ============================================================

; Emit a single byte to binary output
; Input: A = byte to emit
; NOTE: No collision check between binary buffer (growing up) and
; symbol heap (growing down). For very large programs these regions
; could overlap, silently corrupting data. Adding a check here would
; cost ~10 instructions on every emitted byte — not done for now.
za_emit_byte:
    PUSH HL
    PUSH DE
    LD   HL, (za_bin_size)
    LD   DE, za_bin_buffer
    ADD  HL, DE
    LD   (HL), A
    LD   HL, (za_bin_size)
    INC  HL
    LD   (za_bin_size), HL
    POP  DE
    POP  HL
    RET

; Add a relocation entry
; Input: DE = binary offset
za_add_reloc_entry:
    PUSH HL
    LD   HL, (za_reloc_count)
    ; Check max
    LD   A, H
    CP   ZA_MAX_RELOCS >> 8
    JP   NC, _za_reloc_full
    ; Store at za_reloc_buf + count * 2
    ADD  HL, HL             ; offset = count * 2
    PUSH DE
    LD   DE, za_reloc_buf
    ADD  HL, DE             ; HL = address in reloc buf
    POP  DE
    LD   (HL), E
    INC  HL
    LD   (HL), D
    ; Increment count
    LD   HL, (za_reloc_count)
    INC  HL
    LD   (za_reloc_count), HL
    POP  HL
    RET
_za_reloc_full:
    POP  HL
    LD   DE, za_msg_reloc_full
    CALL za_print_error
    RET

; Add a forward reference entry
; Input: HL = label name, DE = packed binary offset (bit15 = relative flag)
za_add_fwd_ref:
    ; Allocate list entry: key=label name, value=packed offset
    CALL data_list_new_entry
    OR   A
    RET  NZ                 ; out of memory
    ; DE = new entry
    ; Prepend to forward reference list
    LD   HL, (za_ref_list)
    EX   DE, HL             ; HL = new entry, DE = old list head
    CALL data_list_prepend_entry
    LD   (za_ref_list), HL
    RET

; Find a data entry by key (for EQU patching)
; Input: HL = key
; Output: HL = entry address, A = 0 if found
_za_data_find_entry:
    LD   D, H
    LD   E, L
    CALL _data_hashmap_get_list
    LD   A, H
    OR   L
    JP   Z, _za_data_find_fail
    CALL _data_list_search
    RET                     ; A = 0 if found, HL = entry
_za_data_find_fail:
    LD   A, 1
    RET

; Copy argument from command line
; Input: HL = source (command line), DE = dest buffer
; Output: HL = advanced past arg and spaces
za_copy_arg:
    LD   B, 16              ; max filename length
_za_copy_arg_loop:
    LD   A, (HL)
    OR   A
    JP   Z, _za_copy_arg_end
    CP   ' '
    JP   Z, _za_copy_arg_end
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, _za_copy_arg_loop
    ; Buffer full — skip remaining chars to whitespace/end
_za_copy_arg_skip:
    LD   A, (HL)
    OR   A
    JP   Z, _za_copy_arg_end
    CP   ' '
    JP   Z, _za_copy_arg_end
    INC  HL
    JP   _za_copy_arg_skip
_za_copy_arg_end:
    XOR  A
    LD   (DE), A            ; null-terminate
    ; Skip whitespace to next argument
    CALL strltrim
    RET

; Parse label from current position
; Input: HL = line position
; Output: za_label_buf = label name, DE = position after label
za_parse_label:
    LD   DE, za_label_buf
    LD   B, ZA_LABEL_MAX
_za_parse_label_loop:
    LD   A, (HL)
    CALL is_alpha_numeric
    JP   NC, _za_parse_label_char
    CP   '_'
    JP   Z, _za_parse_label_char
    ; End of label
    JP   _za_parse_label_end
_za_parse_label_char:
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, _za_parse_label_loop
_za_parse_label_end:
    XOR  A
    LD   (DE), A            ; null-terminate
    EX   DE, HL             ; DE = position after label
    RET

; Strip comment from line (find ';' outside quotes, null-terminate)
za_strip_comment:
    LD   B, 0               ; in-quotes flag
_za_strip_loop:
    LD   A, (HL)
    OR   A
    RET  Z
    CP   '"'
    JP   NZ, _za_strip_not_quote
    LD   A, B
    XOR  1
    LD   B, A
    INC  HL
    JP   _za_strip_loop
_za_strip_not_quote:
    LD   A, B
    OR   A
    JP   NZ, _za_strip_in_quote
    LD   A, (HL)
    CP   ';'
    JP   Z, _za_strip_found
_za_strip_in_quote:
    INC  HL
    JP   _za_strip_loop
_za_strip_found:
    XOR  A
    LD   (HL), A            ; null-terminate at ';'
    RET


; ============================================================
; Console output helpers
; ============================================================

; Print null-terminated string
; Input: DE = string pointer
za_print_str:
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    RET

; Print CRLF
za_print_crlf:
    LD   B, LOGDEV_ID_CONO
    LD   E, 0x0D
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    LD   B, LOGDEV_ID_CONO
    LD   E, 0x0A
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    RET

; Print error with line number
; Input: DE = error message
za_print_error:
    PUSH DE
    ; Print "Error on line "
    LD   DE, za_msg_err_line
    CALL za_print_str
    ; Print line number
    LD   HL, (za_line_num)
    LD   DE, za_num_buf
    CALL word_to_ascii
    ; Null-terminate
    LD   (HL), 0
    LD   DE, za_num_buf
    CALL za_print_str
    ; Print ": "
    LD   DE, za_msg_colon_sp
    CALL za_print_str
    POP  DE
    CALL za_print_str
    CALL za_print_crlf
    ; Increment error count
    LD   HL, (za_err_count)
    INC  HL
    LD   (za_err_count), HL
    RET

; Print assembly summary
za_print_summary:
    ; Print binary size
    LD   DE, za_msg_size
    CALL za_print_str
    LD   HL, (za_bin_size)
    LD   DE, za_num_buf
    CALL word_to_ascii
    LD   (HL), 0
    LD   DE, za_num_buf
    CALL za_print_str
    LD   DE, za_msg_bytes
    CALL za_print_str

    ; Print relocation count
    LD   DE, za_msg_relocs
    CALL za_print_str
    LD   HL, (za_reloc_count)
    LD   DE, za_num_buf
    CALL word_to_ascii
    LD   (HL), 0
    LD   DE, za_num_buf
    CALL za_print_str
    CALL za_print_crlf

    ; Print error count if any
    LD   HL, (za_err_count)
    LD   A, H
    OR   L
    RET  Z
    LD   DE, za_msg_errcnt
    CALL za_print_str
    LD   HL, (za_err_count)
    LD   DE, za_num_buf
    CALL word_to_ascii
    LD   (HL), 0
    LD   DE, za_num_buf
    CALL za_print_str
    LD   DE, za_msg_errs
    CALL za_print_str
    RET

; ============================================================
; Error handlers
; ============================================================

za_err_usage:
    LD   DE, za_msg_usage
    CALL za_print_str
    LD   C, SYS_EXIT
    CALL KERNELADDR

za_err_open_in:
    LD   DE, za_msg_open_in
    CALL za_print_str
    LD   C, SYS_EXIT
    CALL KERNELADDR

za_err_open_out:
    LD   DE, za_msg_open_out
    CALL za_print_str
    CALL file_close_input_output
    LD   C, SYS_EXIT
    CALL KERNELADDR

za_err_read:
    LD   DE, za_msg_read_err
    CALL za_print_error
    RET

za_err_parse:
    LD   DE, za_msg_syntax
    CALL za_print_error
    JP   _za_asm_loop

za_err_dup_label:
    POP  HL                 ; clean stack
    LD   DE, za_msg_dup
    CALL za_print_error
    JP   _za_asm_loop

za_err_bad_value:
    LD   DE, za_msg_badval
    CALL za_print_error
    XOR  A
    RET

za_err_bad_str:
    LD   DE, za_msg_badstr
    CALL za_print_error
    XOR  A
    RET

za_err_write:
    LD   DE, za_msg_write_err
    CALL za_print_str
    CALL za_print_crlf
    RET

; ============================================================
; String constants
; ============================================================

za_msg_usage:
    DEFM "Usage: ZEALASM input.asm output.app", 0x0D, 0x0A, 0
za_msg_assembling:
    DEFM "Assembling ", 0
za_msg_open_in:
    DEFM "Error: Cannot open input file", 0x0D, 0x0A, 0
za_msg_open_out:
    DEFM "Error: Cannot create output file", 0x0D, 0x0A, 0
za_msg_err_line:
    DEFM "Line ", 0
za_msg_colon_sp:
    DEFM ": ", 0
za_msg_syntax:
    DEFM "Syntax error", 0
za_msg_dup:
    DEFM "Duplicate label", 0
za_msg_undef:
    DEFM "Undefined label: ", 0
za_msg_badval:
    DEFM "Bad value", 0
za_msg_badstr:
    DEFM "Bad string", 0
za_msg_rel_range:
    DEFM "Relative jump out of range", 0
za_msg_errors:
    DEFM "Assembly failed — errors detected", 0x0D, 0x0A, 0
za_msg_size:
    DEFM "Code: ", 0
za_msg_bytes:
    DEFM " bytes, ", 0
za_msg_relocs:
    DEFM "Relocs: ", 0
za_msg_errcnt:
    DEFM "Errors: ", 0
za_msg_errs:
    DEFM " error(s)", 0x0D, 0x0A, 0
za_msg_read_err:
    DEFM "Read error", 0
za_msg_write_err:
    DEFM "Write error", 0
za_msg_equ_nolabel:
    DEFM "EQU without label", 0
za_msg_reloc_full:
    DEFM "Too many relocations", 0
za_msg_version:
    DEFM "Zealasm v0.2", 0

za_str_org:     DEFM "org", 0
za_str_equ:     DEFM "equ", 0
za_str_db:      DEFM "db", 0
za_str_defb:    DEFM "defb", 0
za_str_dw:      DEFM "dw", 0
za_str_defw:    DEFM "defw", 0
za_str_dm:      DEFM "dm", 0
za_str_defm:    DEFM "defm", 0
za_str_ds:      DEFM "ds", 0
za_str_defs:    DEFM "defs", 0
za_empty_str:   DEFB 0

; ============================================================
; Variables
; ============================================================

za_input_name:      DEFS 17, 0
za_output_name:     DEFS 17, 0
za_bin_size:        DEFW 0
za_org:             DEFW 0
za_org_set:         DEFB 0
za_line_num:        DEFW 0
za_err_count:       DEFW 0
za_ref_list:        DEFW 0      ; forward reference list head
za_reloc_count:     DEFW 0
za_heap_top:        DEFW 0      ; current heap top (grows down)
za_heap_bottom:     DEFW 0      ; heap bottom limit

za_label_buf:       DEFS ZA_LABEL_MAX + 1, 0
za_dir_ptr:         DEFW 0
za_dir_buf:         DEFS 8, 0   ; directive name buffer
za_inst_ptr:        DEFW 0
za_operand_ptr:     DEFW 0

za_temp_word:       DEFW 0
za_num_buf:         DEFS 8, 0
za_fixup_is_rel:    DEFB 0
za_had_indent:      DEFB 0

; Parser communication variables
za_parse_buf:       DEFS 4, 0   ; encoded instruction bytes
za_parse_temp:      DEFS 16, 0  ; parser temp buffer
za_parse_op1:       DEFW 0      ; first operand pointer
za_parse_op2:       DEFW 0      ; second operand pointer
za_parse_ref_type:  DEFB 0      ; label reference type (ZA_REF_*)
za_parse_ref_off:   DEFB 0      ; offset of address in parse_buf
za_parse_label_name: DEFS ZA_LABEL_MAX + 1, 0  ; label name for fwd refs

; ============================================================
; Hashmap (256 entries x 2 bytes = 512 bytes)
; ============================================================
za_hashmap:         DEFS 512, 0

; ============================================================
; Include modules
; ============================================================

    INCLUDE "strutils.asm"
    INCLUDE "data.asm"
    INCLUDE "file.asm"
    INCLUDE "parser.asm"

; ============================================================
; Relocation buffer (after all code and includes)
; ============================================================
za_reloc_buf:       DEFS ZA_MAX_RELOCS * 2, 0

; ============================================================
; Binary output buffer (at the very end — grows upward)
; The heap grows downward from memtop toward this buffer.
; ============================================================
za_bin_buffer:
    ; This label marks the start of the binary output area.
    ; No DEFS here — the buffer extends to the heap.

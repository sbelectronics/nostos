; ============================================================
; debug.asm - Interactive Debugger for NostOS
;
; DOS DEBUG-style commands for memory inspection, breakpoints,
; register display, program loading, and disassembly.
;
; Commands:
;   B               List breakpoints
;   B addr          Set breakpoint at addr
;   BC addr         Clear breakpoint at addr
;   BC *            Clear all breakpoints
;   D [addr]        Dump 128 bytes of memory
;   E addr bb [..]  Enter (write) bytes to memory
;   F start end bb  Fill memory range with byte
;   G [addr]        Go (run target from addr or current PC)
;   I port          Input: read byte from I/O port
;   L file [addr]   Load program (does not run it)
;   O port bb       Output: write byte to I/O port
;   P               Proceed (step over CALLs)
;   Q               Quit
;   R               Register dump
;   R reg=value     Modify register
;   T               Trace (single-step)
;   U [addr]        Unassemble / disassemble
;   ?               Help
;
; Breakpoints use RST 6 (opcode 0xF7).  The debugger installs
; itself as the RST 6 handler at startup via RST6_RAM_VEC.
; ============================================================

    INCLUDE "../../src/include/syscall.asm"

; Workspace addresses we need (from constants.asm, but we don't
; include it to avoid pulling in IFDEF-gated blocks).
RST6_RAM_VEC        EQU 0xF809  ; RST 6 JP thunk in workspace RAM


    ORG 0

; ============================================================
; App header
; ============================================================
debug_app_base:
    JP   debug_main
    DEFS 13, 0

; Max breakpoints supported
DEBUG_MAX_BP        EQU 8
DEBUG_BP_SIZE       EQU 4       ; per-entry: addr(2) + orig_byte(1) + flags(1)
DEBUG_BPF_ACTIVE    EQU 0x01    ; flag bit: breakpoint is active
DEBUG_BPF_TEMP      EQU 0x02    ; flag bit: temporary (single-step)
DEBUG_BPF_ARMED     EQU 0x04    ; flag bit: orig_byte is valid (BP written to memory)
DEBUG_STACK_SIZE    EQU 64      ; private stack for break handler

; ============================================================
; debug_main - entry point
; ============================================================
debug_main:
    ; Save our base address (= USER_PROGRAM_BASE after relocation)
    ; for ROM boundary checks in T/P commands.
    LD   HL, debug_app_base
    LD   (debug_rom_boundary), HL

    ; Save the current RST 6 target so we can restore it on exit.
    LD   A, (RST6_RAM_VEC + 1)
    LD   (debug_saved_rst6), A
    LD   A, (RST6_RAM_VEC + 2)
    LD   (debug_saved_rst6 + 1), A

    ; Install ourselves as the RST 6 handler.
    LD   HL, debug_break_handler
    LD   A, L
    LD   (RST6_RAM_VEC + 1), A
    LD   A, H
    LD   (RST6_RAM_VEC + 2), A

    ; Initialize register save block to defaults
    LD   HL, 0
    LD   (debug_save_af), HL
    LD   (debug_save_bc), HL
    LD   (debug_save_de), HL
    LD   (debug_save_hl), HL
    LD   (debug_save_pc), HL
    ; SP = DYNAMIC_MEMTOP + 1
    LD   C, SYS_MEMTOP
    CALL KERNELADDR             ; HL = DYNAMIC_MEMTOP
    INC  HL
    LD   (debug_save_sp), HL

    ; Clear the breakpoint table
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP * DEBUG_BP_SIZE
debug_init_bp:
    LD   (HL), 0
    INC  HL
    DEC  B
    JP   NZ, debug_init_bp

    ; No target loaded yet
    XOR  A
    LD   (debug_has_target), A
    LD   (debug_go_pending), A

    ; Print banner
    LD   DE, debug_banner
    CALL debug_puts

; ============================================================
; debug_prompt - main command loop
; ============================================================
debug_prompt:
    LD   B, LOGDEV_ID_CONO
    LD   E, '-'
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    LD   B, LOGDEV_ID_CONI
    LD   DE, debug_buf
    LD   C, DEV_CREAD_STR
    CALL KERNELADDR
    CALL debug_crlf

    LD   HL, debug_buf
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_prompt

    ; Uppercase
    CP   'a'
    JP   C, debug_dispatch
    CP   'z'+1
    JP   NC, debug_dispatch
    SUB  0x20

debug_dispatch:
    INC  HL
    CP   'B'
    JP   Z, debug_cmd_b
    CP   'D'
    JP   Z, debug_cmd_d
    CP   'E'
    JP   Z, debug_cmd_e
    CP   'F'
    JP   Z, debug_cmd_f
    CP   'G'
    JP   Z, debug_cmd_g
    CP   'I'
    JP   Z, debug_cmd_i
    CP   'L'
    JP   Z, debug_cmd_l
    CP   'O'
    JP   Z, debug_cmd_o
    CP   'P'
    JP   Z, debug_cmd_p
    CP   'Q'
    JP   Z, debug_cmd_q
    CP   'R'
    JP   Z, debug_cmd_r
    CP   'T'
    JP   Z, debug_cmd_t
    CP   'U'
    JP   Z, debug_cmd_u
    CP   '?'
    JP   Z, debug_cmd_help
    CP   'H'
    JP   Z, debug_cmd_help

    LD   DE, debug_msg_unknown
    CALL debug_puts
    JP   debug_prompt

; ============================================================
; Common error handlers
; ============================================================
debug_err_syntax:
    LD   DE, debug_msg_syntax
    CALL debug_puts
    JP   debug_prompt

debug_err_range:
    LD   DE, debug_msg_range
    CALL debug_puts
    JP   debug_prompt

; ============================================================
; RST 6 Break Handler
;
; Entry: app's registers are live.  SP points at the return
; address (byte after the RST 6 opcode).  We must save
; everything before touching any register.
;
; 8080-compatible: saves SP via ADD HL,SP (no LD (nn),SP).
; ============================================================
debug_break_handler:
    ; Save HL first (we need HL to capture SP)
    LD   (debug_save_hl), HL
    LD   HL, 0
    ADD  HL, SP                 ; HL = app's SP (8080-compatible)
    LD   (debug_save_sp), HL
    ; Switch to our private stack
    LD   SP, debug_stack_top
    ; Save remaining registers via push/pop into memory.
    ; Can't use LD (nn),rr for BC/DE/AF — those are Z80-only (ED prefix).
    ; Instead, push to our stack, pop into HL, store HL.
    PUSH AF
    PUSH BC
    PUSH DE
    POP  HL
    LD   (debug_save_de), HL
    POP  HL
    LD   (debug_save_bc), HL
    POP  HL
    LD   (debug_save_af), HL
    ; Compute breakpoint address = return_addr - 1
    LD   HL, (debug_save_sp)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = return address (byte after RST 6)
    DEC  DE                     ; DE = address of the RST 6 opcode
    LD   (debug_save_pc), DE
    ; Pop the return address off the app's saved SP (the app doesn't
    ; need it — we'll push the resume address when G runs)
    LD   HL, (debug_save_sp)
    INC  HL
    INC  HL
    LD   (debug_save_sp), HL
    ; Restore the original byte at the breakpoint address
    CALL debug_bp_restore_at_pc
    ; Clear any remaining temp breakpoints (from conditional step)
    CALL debug_disarm_temp_bps
    ; Check if G is pending (silent step-past-BP before free run)
    LD   A, (debug_go_pending)
    OR   A
    JP   NZ, debug_go_continue
    ; Normal entry: disarm all BPs so memory shows original bytes
    CALL debug_disarm_breakpoints
    ; Re-enable interrupts (may have been DI'd for single-step)
    EI
    ; Print register dump
    CALL debug_print_regs
    ; Enter the debugger prompt
    JP   debug_prompt

; ------------------------------------------------------------
; debug_go_continue
; Called from break handler when debug_go_pending is set.
; We just stepped past a BP at the previous PC.  Now arm all
; BPs (including the one we skipped) and continue running.
; ------------------------------------------------------------
debug_go_continue:
    XOR  A
    LD   (debug_go_pending), A
    ; Disarm first — permanent BPs from the prior arm still have F7
    ; in memory; re-arming without disarming would save F7 as the
    ; "original byte", corrupting the restore on the next break.
    CALL debug_disarm_breakpoints
    ; Arm all breakpoints — PC has moved past the BP now, so
    ; arm_breakpoints won't skip it (PC != BP address).
    CALL debug_arm_breakpoints
    ; Re-enable interrupts
    EI
    JP   debug_resume_target

; ------------------------------------------------------------
; debug_bp_restore_at_pc
; Find the breakpoint entry for (debug_save_pc) and restore the
; original byte.  If it was a temp breakpoint, remove it.
; ------------------------------------------------------------
debug_bp_restore_at_pc:
    LD   DE, (debug_save_pc)
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP
debug_bpr_loop:
    LD   A, (HL)
    INC  HL
    LD   C, A                   ; C = addr low
    LD   A, (HL)
    INC  HL                     ; A = addr high, HL -> orig_byte
    ; Check if this entry matches DE
    CP   D
    JP   NZ, debug_bpr_next
    LD   A, C
    CP   E
    JP   NZ, debug_bpr_next
    ; Match found.  Restore original byte.
    LD   A, (HL)                ; A = original byte
    LD   (DE), A                ; write it back to the code
    INC  HL                     ; HL -> flags
    ; If temp breakpoint, clear the entry
    LD   A, (HL)
    AND  DEBUG_BPF_TEMP
    JP   Z, debug_bpr_perm
    ; Clear entire entry (temp BP)
    DEC  HL
    DEC  HL
    DEC  HL
    XOR  A
    LD   (HL), A
    INC  HL
    LD   (HL), A
    INC  HL
    LD   (HL), A
    INC  HL
    LD   (HL), A
    RET
debug_bpr_perm:
    ; Permanent BP: clear ARMED flag since we just restored the byte.
    ; The G command will re-arm it.
    LD   A, (HL)
    AND  ~DEBUG_BPF_ARMED & 0xFF
    LD   (HL), A
    RET
debug_bpr_next:
    INC  HL                     ; skip orig_byte
    INC  HL                     ; skip flags
    DEC  B
    JP   NZ, debug_bpr_loop
    ; No matching breakpoint found (shouldn't happen in normal use)
    RET

; ============================================================
; debug_arm_breakpoints
; Write RST 6 (0xF7) into all active breakpoint addresses,
; saving the original bytes.  Called before resuming the target.
; Skips the BP at debug_save_pc so we don't immediately
; re-trigger when resuming from a breakpoint.
; ============================================================
debug_arm_breakpoints:
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP
debug_arm_loop:
    ; Read flags first (offset +3)
    PUSH HL
    INC  HL
    INC  HL
    INC  HL
    LD   A, (HL)                ; flags
    POP  HL
    AND  DEBUG_BPF_ACTIVE
    JP   Z, debug_arm_skip
    ; Read address
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL                     ; HL -> orig_byte
    ; Skip if this BP is at current PC (avoid re-trigger)
    PUSH HL
    LD   HL, (debug_save_pc)
    LD   A, D
    CP   H
    JP   NZ, debug_arm_not_pc
    LD   A, E
    CP   L
    JP   NZ, debug_arm_not_pc
    ; BP is at PC — skip it
    POP  HL
    INC  HL                     ; skip flags
    INC  HL
    DEC  B
    JP   NZ, debug_arm_loop
    RET
debug_arm_not_pc:
    POP  HL
    ; Save current byte at (DE) into orig_byte
    LD   A, (DE)
    LD   (HL), A
    ; Write RST 6 opcode
    LD   A, 0xF7
    LD   (DE), A
    INC  HL                     ; HL -> flags
    ; Mark as armed so disarm knows orig_byte is valid
    LD   A, (HL)
    OR   DEBUG_BPF_ARMED
    LD   (HL), A
    INC  HL
    DEC  B
    JP   NZ, debug_arm_loop
    RET
debug_arm_skip:
    LD   DE, DEBUG_BP_SIZE
    ADD  HL, DE
    DEC  B
    JP   NZ, debug_arm_loop
    RET

; ============================================================
; debug_disarm_breakpoints
; Restore original bytes at all active breakpoint addresses.
; Called when entering the debugger (except at specific BPs,
; which are handled by debug_bp_restore_at_pc).
; ============================================================
debug_disarm_breakpoints:
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP
debug_disarm_loop:
    PUSH HL
    INC  HL
    INC  HL
    INC  HL
    LD   A, (HL)                ; flags
    POP  HL
    AND  DEBUG_BPF_ARMED
    JP   Z, debug_disarm_skip  ; not armed — orig_byte not valid, skip
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    LD   A, (HL)                ; orig_byte
    LD   (DE), A                ; restore
    INC  HL
    ; Clear the ARMED flag
    LD   A, (HL)
    AND  ~DEBUG_BPF_ARMED & 0xFF
    LD   (HL), A
    INC  HL
    DEC  B
    JP   NZ, debug_disarm_loop
    RET
debug_disarm_skip:
    LD   DE, DEBUG_BP_SIZE
    ADD  HL, DE
    DEC  B
    JP   NZ, debug_disarm_loop
    RET

; ------------------------------------------------------------
; debug_check_pc_at_bp
; Check if debug_save_pc matches any active (non-temp) BP.
; Returns: Z set = PC is at a BP, Z clear = not at a BP.
; Preserves HL.
; ------------------------------------------------------------
debug_check_pc_at_bp:
    PUSH HL
    LD   DE, (debug_save_pc)
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP
debug_cpb_loop:
    ; Check flags
    PUSH HL
    INC  HL
    INC  HL
    INC  HL
    LD   A, (HL)
    POP  HL
    AND  DEBUG_BPF_ACTIVE
    JP   Z, debug_cpb_skip
    ; Check for temp — only care about permanent BPs
    PUSH HL
    INC  HL
    INC  HL
    INC  HL
    LD   A, (HL)
    POP  HL
    AND  DEBUG_BPF_TEMP
    JP   NZ, debug_cpb_skip
    ; Compare address with DE
    LD   A, (HL)
    CP   E
    JP   NZ, debug_cpb_skip
    PUSH HL
    INC  HL
    LD   A, (HL)
    POP  HL
    CP   D
    JP   NZ, debug_cpb_skip
    ; Match — return Z set
    POP  HL
    XOR  A                      ; Z=1
    RET
debug_cpb_skip:
    PUSH DE
    LD   DE, DEBUG_BP_SIZE
    ADD  HL, DE
    POP  DE
    DEC  B
    JP   NZ, debug_cpb_loop
    ; No match — return Z clear
    POP  HL
    LD   A, 1
    OR   A                      ; Z=0
    RET

; ============================================================
; Q - Quit
; ============================================================
debug_cmd_q:
    ; Disarm all breakpoints before exiting
    CALL debug_disarm_breakpoints
    ; Restore RST 6 to the handler that was installed before we ran.
    LD   A, (debug_saved_rst6)
    LD   (RST6_RAM_VEC + 1), A
    LD   A, (debug_saved_rst6 + 1)
    LD   (RST6_RAM_VEC + 2), A
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; ? / H - Help
; ============================================================
debug_cmd_help:
    LD   DE, debug_msg_help
    CALL debug_puts
    JP   debug_prompt

; ============================================================
; R - Register dump or modify
; ============================================================
debug_cmd_r:
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_cmd_r_dump    ; no args: dump all registers

    ; Parse register name for modify: R reg=value
    ; First char is already uppercase from dispatcher; get second char
    LD   A, (HL)
    ; Uppercase it
    CP   'a'
    JP   C, debug_r_have_first
    CP   'z'+1
    JP   NC, debug_r_have_first
    SUB  0x20
debug_r_have_first:
    LD   C, A                   ; C = first char of reg name
    INC  HL
    LD   A, (HL)
    ; Could be '=' (single-char reg like A, B, etc.) or another letter
    CP   '='
    JP   Z, debug_r_single      ; single-char register
    ; Uppercase second char
    CP   'a'
    JP   C, debug_r_have_second
    CP   'z'+1
    JP   NC, debug_r_have_second
    SUB  0x20
debug_r_have_second:
    LD   D, A                   ; D = second char
    INC  HL
    LD   A, (HL)
    CP   '='
    JP   NZ, debug_err_syntax
    INC  HL                     ; skip '='
    ; Save register name before parse_hex clobbers DE
    LD   A, C
    LD   (debug_r_name), A      ; first char
    LD   A, D
    LD   (debug_r_name+1), A    ; second char
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; DE = 16-bit value to set
    ; Dispatch on register pair name
    LD   A, (debug_r_name)
    LD   B, A
    LD   A, (debug_r_name+1)
    LD   C, A                   ; BC = register name chars
    LD   A, B
    CP   'A'
    JP   NZ, debug_rm_not_af
    LD   A, C
    CP   'F'
    JP   NZ, debug_err_syntax
    LD   (debug_save_af), DE
    JP   debug_prompt
debug_rm_not_af:
    CP   'B'
    JP   NZ, debug_rm_not_bc
    LD   A, C
    CP   'C'
    JP   NZ, debug_err_syntax
    LD   (debug_save_bc), DE
    JP   debug_prompt
debug_rm_not_bc:
    CP   'D'
    JP   NZ, debug_rm_not_de
    LD   A, C
    CP   'E'
    JP   NZ, debug_err_syntax
    LD   (debug_save_de), DE
    JP   debug_prompt
debug_rm_not_de:
    CP   'H'
    JP   NZ, debug_rm_not_hl
    LD   A, C
    CP   'L'
    JP   NZ, debug_err_syntax
    LD   (debug_save_hl), DE
    JP   debug_prompt
debug_rm_not_hl:
    CP   'S'
    JP   NZ, debug_rm_not_sp
    LD   A, C
    CP   'P'
    JP   NZ, debug_err_syntax
    LD   (debug_save_sp), DE
    JP   debug_prompt
debug_rm_not_sp:
    CP   'P'
    JP   NZ, debug_err_syntax
    LD   A, C
    CP   'C'
    JP   NZ, debug_err_syntax
    LD   (debug_save_pc), DE
    JP   debug_prompt

debug_r_single:
    INC  HL                     ; skip '='
    ; C = register char, save it
    LD   A, C
    LD   (debug_r_name), A
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    LD   A, D
    OR   A
    JP   NZ, debug_err_range    ; must be 8-bit value
    ; E = value.  Dispatch on register name.
    LD   A, (debug_r_name)
    CP   'A'
    JP   Z, debug_rs_a
    CP   'F'
    JP   Z, debug_rs_f
    CP   'B'
    JP   Z, debug_rs_b
    CP   'C'
    JP   Z, debug_rs_c
    CP   'D'
    JP   Z, debug_rs_d
    CP   'E'
    JP   Z, debug_rs_e
    CP   'H'
    JP   Z, debug_rs_h
    CP   'L'
    JP   Z, debug_rs_l
    JP   debug_err_syntax
    ; A is high byte of AF pair (offset +1), F is low byte (offset +0)
debug_rs_a:
    LD   A, E
    LD   (debug_save_af+1), A
    JP   debug_prompt
debug_rs_f:
    LD   A, E
    LD   (debug_save_af), A
    JP   debug_prompt
debug_rs_b:
    LD   A, E
    LD   (debug_save_bc+1), A
    JP   debug_prompt
debug_rs_c:
    LD   A, E
    LD   (debug_save_bc), A
    JP   debug_prompt
debug_rs_d:
    LD   A, E
    LD   (debug_save_de+1), A
    JP   debug_prompt
debug_rs_e:
    LD   A, E
    LD   (debug_save_de), A
    JP   debug_prompt
debug_rs_h:
    LD   A, E
    LD   (debug_save_hl+1), A
    JP   debug_prompt
debug_rs_l:
    LD   A, E
    LD   (debug_save_hl), A
    JP   debug_prompt

debug_cmd_r_dump:
    CALL debug_print_regs
    JP   debug_prompt

; ------------------------------------------------------------
; debug_print_regs
; Print all saved registers and disassemble instruction at PC.
; Format: AF=XXXX BC=XXXX DE=XXXX HL=XXXX SP=XXXX PC=XXXX
; ------------------------------------------------------------
debug_print_regs:
    LD   DE, debug_str_af
    CALL debug_puts
    LD   HL, (debug_save_af)
    CALL debug_print_hex16
    LD   A, ' '
    CALL debug_putchar

    LD   DE, debug_str_bc
    CALL debug_puts
    LD   HL, (debug_save_bc)
    CALL debug_print_hex16
    LD   A, ' '
    CALL debug_putchar

    LD   DE, debug_str_de
    CALL debug_puts
    LD   HL, (debug_save_de)
    CALL debug_print_hex16
    LD   A, ' '
    CALL debug_putchar

    LD   DE, debug_str_hl
    CALL debug_puts
    LD   HL, (debug_save_hl)
    CALL debug_print_hex16
    LD   A, ' '
    CALL debug_putchar

    LD   DE, debug_str_sp
    CALL debug_puts
    LD   HL, (debug_save_sp)
    CALL debug_print_hex16
    LD   A, ' '
    CALL debug_putchar

    LD   DE, debug_str_pc
    CALL debug_puts
    LD   HL, (debug_save_pc)
    CALL debug_print_hex16
    CALL debug_crlf

    ; Disassemble instruction at PC
    LD   HL, (debug_save_pc)
    CALL debug_disasm_one
    RET

; ============================================================
; B - Breakpoint commands
;   B        = list
;   B addr   = set
;   BC addr  = clear
;   BC *     = clear all
; ============================================================
debug_cmd_b:
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_bp_list       ; no args → list

    ; Uppercase
    CP   'a'
    JP   C, debug_b_check
    CP   'z'+1
    JP   NC, debug_b_check
    SUB  0x20
debug_b_check:
    CP   'C'
    JP   NZ, debug_bp_set_addr
    ; 'C' — could be BC (clear) or an address like C000.
    ; Peek at next char: hex digit means address, anything else means BC.
    INC  HL
    LD   A, (HL)
    DEC  HL
    CP   '0'
    JP   C, debug_bp_clear
    CP   '9'+1
    JP   C, debug_bp_set_addr
    CP   'A'
    JP   C, debug_bp_clear
    CP   'F'+1
    JP   C, debug_bp_set_addr
    JP   debug_bp_clear
debug_bp_set_addr:
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; DE = address to set breakpoint at
    ; Find a free slot in the table
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP
debug_bp_set_find:
    PUSH HL
    INC  HL
    INC  HL
    INC  HL
    LD   A, (HL)                ; flags
    POP  HL
    AND  DEBUG_BPF_ACTIVE
    JP   Z, debug_bp_set_here   ; found free slot
    ; Check if there's already a BP at this address
    LD   A, (HL)
    CP   E
    JP   NZ, debug_bp_set_next
    INC  HL
    LD   A, (HL)
    DEC  HL
    CP   D
    JP   NZ, debug_bp_set_next
    ; Already set at this address
    LD   DE, debug_msg_bp_exists
    CALL debug_puts
    JP   debug_prompt
debug_bp_set_next:
    PUSH DE
    LD   DE, DEBUG_BP_SIZE
    ADD  HL, DE
    POP  DE
    DEC  B
    JP   NZ, debug_bp_set_find
    ; Table full
    LD   DE, debug_msg_bp_full
    CALL debug_puts
    JP   debug_prompt

debug_bp_set_here:
    ; HL = free slot, DE = address
    LD   (HL), E
    INC  HL
    LD   (HL), D
    INC  HL
    LD   (HL), 0               ; orig_byte (filled when armed)
    INC  HL
    LD   (HL), DEBUG_BPF_ACTIVE
    JP   debug_prompt

; --- BC addr / BC * ---
debug_bp_clear:
    INC  HL                     ; skip the 'C'
    CALL debug_skip_spaces
    LD   A, (HL)
    CP   '*'
    JP   Z, debug_bp_clear_all
    ; Parse address
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; DE = address to clear
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP
debug_bp_clr_find:
    LD   A, (HL)
    CP   E
    JP   NZ, debug_bp_clr_next
    INC  HL
    LD   A, (HL)
    DEC  HL
    CP   D
    JP   NZ, debug_bp_clr_next
    ; Found it — clear the entry
    XOR  A
    LD   (HL), A
    INC  HL
    LD   (HL), A
    INC  HL
    LD   (HL), A
    INC  HL
    LD   (HL), A
    JP   debug_prompt
debug_bp_clr_next:
    PUSH DE
    LD   DE, DEBUG_BP_SIZE
    ADD  HL, DE
    POP  DE
    DEC  B
    JP   NZ, debug_bp_clr_find
    LD   DE, debug_msg_bp_notfound
    CALL debug_puts
    JP   debug_prompt

debug_bp_clear_all:
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP * DEBUG_BP_SIZE
debug_bp_clr_all:
    LD   (HL), 0
    INC  HL
    DEC  B
    JP   NZ, debug_bp_clr_all
    JP   debug_prompt

; --- B (no args) → list ---
debug_bp_list:
    LD   HL, debug_bp_table
    LD   C, 0                   ; count of listed BPs
    LD   B, DEBUG_MAX_BP
debug_bp_list_loop:
    PUSH HL
    INC  HL
    INC  HL
    INC  HL
    LD   A, (HL)                ; flags
    POP  HL
    AND  DEBUG_BPF_ACTIVE
    JP   Z, debug_bp_list_skip
    ; Print address
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    INC  HL                     ; skip orig_byte
    INC  HL                     ; skip flags
    PUSH HL
    PUSH BC
    EX   DE, HL
    CALL debug_print_hex16
    CALL debug_crlf
    POP  BC
    POP  HL
    INC  C
    DEC  B
    JP   NZ, debug_bp_list_loop
    JP   debug_bp_list_done
debug_bp_list_skip:
    PUSH DE
    LD   DE, DEBUG_BP_SIZE
    ADD  HL, DE
    POP  DE
    DEC  B
    JP   NZ, debug_bp_list_loop
debug_bp_list_done:
    LD   A, C
    OR   A
    JP   NZ, debug_prompt
    LD   DE, debug_msg_bp_none
    CALL debug_puts
    JP   debug_prompt

; ============================================================
; G [addr] - Go (resume target execution)
; ============================================================
debug_cmd_g:
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_g_resume      ; no arg: resume from current PC
    ; Parse address
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    ; Set PC to the given address
    LD   (debug_save_pc), DE

debug_g_resume:
    ; Check if PC is sitting on an active breakpoint.
    ; If so, we must single-step past it first, then continue.
    CALL debug_check_pc_at_bp
    JP   NZ, debug_g_direct
    ; PC is at a BP — do a silent step past it, then continue
    LD   A, 1
    LD   (debug_go_pending), A
    LD   (debug_step_mode), A   ; proceed mode (step over)
    JP   debug_step_common
debug_g_direct:
    ; No BP at PC — arm all breakpoints and go
    CALL debug_arm_breakpoints
    JP   debug_resume_target

; ------------------------------------------------------------
; debug_resume_target
; Shared resume logic for G, T, and P commands.
; Restores all saved registers, switches to app stack, RETs
; into the target at debug_save_pc.
; ------------------------------------------------------------
debug_resume_target:
    ; Build return frame on the app's stack:
    ; push the saved PC so RET will jump there
    LD   HL, (debug_save_sp)
    DEC  HL
    DEC  HL
    PUSH HL                     ; save new app SP
    LD   HL, (debug_save_pc)
    EX   DE, HL                 ; DE = saved PC
    POP  HL                     ; HL = new app SP
    LD   (HL), E
    INC  HL
    LD   (HL), D
    DEC  HL                     ; HL = new app SP (with PC pushed)
    ; Restore registers.  Use the debugger stack to stage everything.
    PUSH HL                     ; [1] save new app SP
    LD   HL, (debug_save_de)
    PUSH HL                     ; [2] saved DE
    LD   HL, (debug_save_bc)
    PUSH HL                     ; [3] saved BC
    LD   HL, (debug_save_af)
    PUSH HL                     ; [4] saved AF
    POP  AF                     ; [4] AF restored
    POP  BC                     ; [3] BC restored
    POP  DE                     ; [2] DE restored
    POP  HL                     ; [1] new app SP
    LD   SP, HL                 ; switch to app stack (PC on top)
    LD   HL, (debug_save_hl)    ; restore app's HL
    RET                         ; pop PC, resume target

; ============================================================
; L filename [addr] - Load program (read + relocate, do not run)
;   L HELLO.APP       — load at debug_end (default)
;   L HELLO.APP 8000  — load at 0x8000
; ============================================================
debug_cmd_l:
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_err_syntax

    ; HL points to the filename.  Find the end of the filename
    ; (next space or null) to check for an optional address arg.
    PUSH HL                     ; save filename start
debug_l_scan_name:
    LD   A, (HL)
    OR   A
    JP   Z, debug_l_name_end
    CP   ' '
    JP   Z, debug_l_name_end
    INC  HL
    JP   debug_l_scan_name
debug_l_name_end:
    ; If we stopped at a space, null-terminate the filename and
    ; parse the optional address that follows.
    LD   DE, debug_end          ; default load address
    OR   A
    JP   Z, debug_l_no_addr     ; null = end of input, no address
    LD   (HL), 0                ; null-terminate filename
    INC  HL
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_l_no_addr     ; nothing after filename
    ; Parse hex address
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_l_no_addr_pop ; not a valid hex number, use default
    ; DE = user-specified load address — reject if below debug_end
    PUSH HL
    LD   HL, debug_end
    LD   A, D
    CP   H
    JP   C, debug_l_addr_bad
    JP   NZ, debug_l_addr_ok
    LD   A, E
    CP   L
    JP   C, debug_l_addr_bad
debug_l_addr_ok:
    POP  HL
    POP  HL                     ; filename start
    JP   debug_l_open
debug_l_addr_bad:
    POP  HL
    POP  HL                     ; filename start
    LD   DE, debug_msg_range
    CALL debug_puts
    JP   debug_prompt
debug_l_no_addr_pop:
    LD   DE, debug_end
debug_l_no_addr:
    POP  HL                     ; HL = filename start
debug_l_open:
    LD   (debug_load_addr), DE
    ; Open the file.  HL = filename, or we need DE = filename.
    EX   DE, HL                 ; DE = filename
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    OR   A
    JP   NZ, debug_l_open_err
    ; L = device/handle ID
    LD   A, L
    LD   (debug_l_handle), A

    ; Read blocks into memory at load address.
    ; No upper-bound check — loading a file that extends into kernel
    ; workspace will crash, same as CP/M DDT.  User's responsibility.
    LD   HL, (debug_load_addr)

debug_l_read_loop:
    PUSH HL                     ; save load pointer
    LD   D, H
    LD   E, L                   ; DE = destination
    LD   A, (debug_l_handle)
    LD   B, A                   ; B = handle
    LD   C, DEV_BREAD
    CALL KERNELADDR
    POP  HL                     ; restore load pointer
    CP   ERR_EOF
    JP   Z, debug_l_loaded
    OR   A
    JP   NZ, debug_l_io_err
    LD   DE, 512
    ADD  HL, DE
    JP   debug_l_read_loop

debug_l_loaded:
    ; Close the file
    LD   A, (debug_l_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    ; Parse the header: first 2 bytes = code_length
    LD   HL, (debug_load_addr)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = code_length
    INC  HL                     ; HL = program_base (load_addr + 2)
    LD   (debug_target_base), HL
    LD   (debug_target_len), DE

    ; Locate relocation table: program_base + code_length
    ADD  HL, DE                 ; HL = reloc table start
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = reloc_count
    INC  HL                     ; HL = first reloc entry
    LD   (debug_reloc_cnt), DE
    LD   (debug_reloc_ptr), HL

    ; Apply relocations (same algorithm as kernel's SYS_EXEC)
debug_l_reloc_loop:
    LD   HL, (debug_reloc_cnt)
    LD   A, H
    OR   L
    JP   Z, debug_l_reloc_done
    DEC  HL
    LD   (debug_reloc_cnt), HL

    ; Read offset from reloc table
    LD   HL, (debug_reloc_ptr)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = offset within program
    INC  HL
    LD   (debug_reloc_ptr), HL

    ; target = program_base + offset
    LD   HL, (debug_target_base)
    ADD  HL, DE                 ; HL = target address in RAM

    ; Read 16-bit value at target, add program_base, write back
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = original value
    PUSH HL                     ; save target+1

    LD   HL, (debug_target_base)
    ADD  HL, DE                 ; HL = relocated value

    POP  DE                     ; DE = target+1
    LD   A, H
    LD   (DE), A                ; write high byte
    DEC  DE
    LD   A, L
    LD   (DE), A                ; write low byte

    JP   debug_l_reloc_loop

debug_l_reloc_done:
    ; Set initial register state
    LD   HL, (debug_target_base)
    LD   (debug_save_pc), HL    ; entry point
    LD   HL, 0
    LD   (debug_save_af), HL
    LD   (debug_save_bc), HL
    LD   (debug_save_de), HL
    LD   (debug_save_hl), HL
    ; SP = DYNAMIC_MEMTOP + 1
    LD   C, SYS_MEMTOP
    CALL KERNELADDR
    INC  HL
    LD   (debug_save_sp), HL

    LD   A, 1
    LD   (debug_has_target), A

    ; Print summary
    LD   DE, debug_msg_loaded
    CALL debug_puts
    LD   HL, (debug_target_base)
    CALL debug_print_hex16
    LD   DE, debug_msg_entry
    CALL debug_puts
    LD   HL, (debug_target_base)
    CALL debug_print_hex16
    LD   DE, debug_msg_len
    CALL debug_puts
    LD   HL, (debug_target_len)
    CALL debug_print_hex16
    LD   DE, debug_msg_bytes
    CALL debug_puts
    JP   debug_prompt

debug_l_open_err:
    LD   DE, debug_msg_open_err
    CALL debug_puts
    JP   debug_prompt

debug_l_io_err:
    ; Close handle on error
    PUSH AF
    LD   A, (debug_l_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    POP  AF
    LD   DE, debug_msg_io_err
    CALL debug_puts
    JP   debug_prompt

; ============================================================
; D [address] - Dump 128 bytes of memory (existing, unchanged)
; ============================================================
debug_cmd_d:
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_d_go
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    PUSH HL
    EX   DE, HL
    LD   (debug_dump_addr), HL
    POP  HL

debug_d_go:
    LD   A, 8
    LD   (debug_d_count), A

debug_d_line:
    LD   HL, (debug_dump_addr)
    CALL debug_print_hex16
    LD   A, ':'
    CALL debug_putchar
    LD   A, ' '
    CALL debug_putchar

    LD   HL, (debug_dump_addr)
    LD   C, 0

debug_d_hex:
    LD   A, (HL)
    INC  HL
    CALL debug_print_hex8
    INC  C
    LD   A, C
    CP   16
    JP   Z, debug_d_ascii_start
    CP   8
    JP   Z, debug_d_dash
    LD   A, ' '
    CALL debug_putchar
    JP   debug_d_hex

debug_d_dash:
    LD   A, '-'
    CALL debug_putchar
    JP   debug_d_hex

debug_d_ascii_start:
    LD   A, ' '
    CALL debug_putchar
    CALL debug_putchar

    LD   HL, (debug_dump_addr)
    LD   C, 16

debug_d_ascii:
    LD   A, (HL)
    INC  HL
    CP   0x20
    JP   C, debug_d_dot
    CP   0x7F
    JP   C, debug_d_printable
debug_d_dot:
    LD   A, '.'
debug_d_printable:
    CALL debug_putchar
    DEC  C
    JP   NZ, debug_d_ascii

    CALL debug_crlf

    LD   HL, (debug_dump_addr)
    LD   DE, 16
    ADD  HL, DE
    LD   (debug_dump_addr), HL

    LD   A, (debug_d_count)
    DEC  A
    LD   (debug_d_count), A
    JP   NZ, debug_d_line

    JP   debug_prompt

; ============================================================
; E address byte [byte ...] - Enter bytes (existing, unchanged)
; ============================================================
debug_cmd_e:
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    PUSH HL
    EX   DE, HL
    LD   (debug_e_addr), HL
    POP  HL

debug_e_loop:
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_prompt
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    LD   A, D
    OR   A
    JP   NZ, debug_err_range
    PUSH HL
    LD   HL, (debug_e_addr)
    LD   (HL), E
    INC  HL
    LD   (debug_e_addr), HL
    POP  HL
    JP   debug_e_loop

; ============================================================
; F start end byte - Fill memory (existing, unchanged)
; ============================================================
debug_cmd_f:
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    PUSH HL
    EX   DE, HL
    LD   (debug_f_start), HL
    POP  HL

    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    PUSH HL
    EX   DE, HL
    LD   (debug_f_end), HL
    POP  HL

    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    LD   A, D
    OR   A
    JP   NZ, debug_err_range
    LD   A, E

    PUSH AF
    LD   HL, (debug_f_end)
    EX   DE, HL
    LD   HL, (debug_f_start)
    LD   A, D
    CP   H
    JP   C, debug_f_err
    JP   NZ, debug_f_ok
    LD   A, E
    CP   L
    JP   C, debug_f_err
debug_f_ok:
    POP  AF

debug_f_loop:
    LD   (HL), A
    PUSH AF
    LD   A, H
    CP   D
    JP   NZ, debug_f_next
    LD   A, L
    CP   E
    JP   Z, debug_f_done
debug_f_next:
    POP  AF
    INC  HL
    JP   debug_f_loop
debug_f_done:
    POP  AF
    JP   debug_prompt

debug_f_err:
    POP  AF
    JP   debug_err_syntax

; ============================================================
; I port - Input from I/O port (existing, unchanged)
; ============================================================
debug_cmd_i:
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    LD   A, D
    OR   A
    JP   NZ, debug_err_range
    LD   A, E
    LD   (debug_in_instr+1), A
debug_in_instr:
    IN   A, (0)
    CALL debug_print_hex8
    CALL debug_crlf
    JP   debug_prompt

; ============================================================
; O port byte - Output to I/O port (existing, unchanged)
; ============================================================
debug_cmd_o:
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    LD   A, D
    OR   A
    JP   NZ, debug_err_range
    PUSH DE
    CALL debug_skip_spaces
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_o_err_syn
    LD   A, D
    OR   A
    JP   NZ, debug_o_err_rng
    POP  BC
    LD   A, C
    LD   (debug_out_instr+1), A
    LD   A, E
debug_out_instr:
    OUT  (0), A
    JP   debug_prompt

debug_o_err_syn:
    POP  DE
    JP   debug_err_syntax

debug_o_err_rng:
    POP  DE
    JP   debug_err_range

; ============================================================
; T - Trace (single-step, step into RAM calls)
; ============================================================
debug_cmd_t:
    XOR  A
    LD   (debug_step_mode), A   ; 0 = trace (step into)
    JP   debug_step_common

; ============================================================
; P - Proceed (step over calls)
; ============================================================
debug_cmd_p:
    LD   A, 1
    LD   (debug_step_mode), A   ; 1 = proceed (step over)
    JP   debug_step_common

; ============================================================
; U [addr] - Unassemble / disassemble
; ============================================================
debug_cmd_u:
    CALL debug_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, debug_u_continue
    CALL debug_parse_hex
    LD   A, B
    OR   A
    JP   Z, debug_err_syntax
    LD   (debug_u_addr), DE
debug_u_continue:
    ; If u_addr is 0 and we have a target, start from PC
    LD   HL, (debug_u_addr)
    LD   A, H
    OR   L
    JP   NZ, debug_u_go
    LD   HL, (debug_save_pc)
    LD   (debug_u_addr), HL
debug_u_go:
    LD   B, 8
debug_u_loop:
    PUSH BC
    LD   HL, (debug_u_addr)
    CALL debug_disasm_one
    LD   (debug_u_addr), HL
    POP  BC
    DEC  B
    JP   NZ, debug_u_loop
    JP   debug_prompt

; ============================================================
; debug_step_common - shared T/P step logic
; Decode instruction at PC, set temp BPs, DI, resume.
; ============================================================
debug_step_common:
    ; Clear step BP addresses
    LD   HL, 0
    LD   (debug_step_bp1), HL
    LD   (debug_step_bp2), HL
    ; Decode instruction at saved PC
    LD   HL, (debug_save_pc)
    LD   A, (HL)
    LD   (debug_step_opcode), A
    ; Look up in opcode info table
    LD   D, 0
    LD   E, A
    LD   HL, debug_opcode_tbl
    ADD  HL, DE
    LD   A, (HL)
    LD   (debug_step_info), A
    ; Extract length
    AND  0x0F
    JP   NZ, debug_sc_got_len
    ; Length 0 = prefix byte.  Handle CB/DD/ED/FD.
    LD   A, (debug_step_opcode)
    CP   0xCB
    JP   Z, debug_sc_len2
    CP   0xED
    JP   Z, debug_sc_ed_prefix
    ; DD or FD: compute length via helper
    LD   HL, (debug_save_pc)
    INC  HL
    CALL debug_ddfd_len
    JP   debug_sc_got_len
debug_sc_ed_prefix:
    ; Check for RETI (ED 4D) / RETN (ED 45)
    LD   HL, (debug_save_pc)
    INC  HL
    LD   A, (HL)
    CP   0x4D
    JP   Z, debug_sc_ed_ret
    CP   0x45
    JP   Z, debug_sc_ed_ret
    ; Default ED: 2 bytes, no branch
    LD   A, 2
    JP   debug_sc_got_len
debug_sc_ed_ret:
    ; RETI/RETN: unconditional return, 2 bytes
    LD   A, 0x42                ; override info: uncond, none, len 2
    LD   (debug_step_info), A
    LD   A, 2
    JP   debug_sc_got_len
debug_sc_len2:
    LD   A, 2
    ; fall through
debug_sc_got_len:
    LD   (debug_step_len), A
    ; Compute fall-through = PC + length
    LD   HL, (debug_save_pc)
    LD   D, 0
    LD   E, A
    ADD  HL, DE
    LD   (debug_step_bp1), HL   ; default: temp BP at fall-through
    ; Check branch type (bits 7:6 of info)
    LD   A, (debug_step_info)
    AND  0xC0
    JP   Z, debug_step_set      ; 00 = no branch
    CP   0x80
    JP   Z, debug_sc_cond       ; 10 = conditional
    CP   0x40
    JP   Z, debug_sc_uncond     ; 01 = unconditional
    ; 11 = special (RST, JP (HL), HALT)
    JP   debug_sc_special

; --- Unconditional branch ---
debug_sc_uncond:
    LD   A, (debug_step_opcode)
    CP   0xC9
    JP   Z, debug_sc_ret        ; RET
    CP   0xE9
    JP   Z, debug_sc_jp_hl      ; JP (HL)
    CP   0xC3
    JP   Z, debug_sc_jp_nn      ; JP nn
    CP   0xCD
    JP   Z, debug_sc_call_nn    ; CALL nn
    CP   0x18
    JP   Z, debug_sc_jr         ; JR e
    ; RETI/RETN (info was overridden)
    LD   A, (debug_step_len)
    CP   2
    JP   Z, debug_sc_ret
    ; Unknown: fall-through
    JP   debug_step_set

debug_sc_ret:
    ; Target = word at saved SP
    LD   HL, (debug_save_sp)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    CALL debug_check_rom
    JP   C, debug_sc_ret_rom
    LD   (debug_step_bp1), DE
    JP   debug_step_set
debug_sc_ret_rom:
    LD   DE, debug_msg_returned
    CALL debug_puts
    JP   debug_prompt

debug_sc_jp_hl:
    LD   DE, (debug_save_hl)
    CALL debug_check_rom
    JP   C, debug_sc_jp_rom
    LD   (debug_step_bp1), DE
    JP   debug_step_set

debug_sc_jp_nn:
    LD   HL, (debug_save_pc)
    INC  HL
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    CALL debug_check_rom
    JP   C, debug_sc_jp_rom
    LD   (debug_step_bp1), DE
    JP   debug_step_set
debug_sc_jp_rom:
    LD   DE, debug_msg_rom_jp
    CALL debug_puts
    JP   debug_prompt

debug_sc_call_nn:
    LD   HL, (debug_save_pc)
    INC  HL
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    ; In proceed mode: always step over
    LD   A, (debug_step_mode)
    OR   A
    JP   NZ, debug_step_set     ; BP stays at fall-through
    ; Trace: step into if RAM
    CALL debug_check_rom
    JP   C, debug_step_set      ; ROM target: step over
    LD   (debug_step_bp1), DE   ; RAM: step into
    JP   debug_step_set

debug_sc_jr:
    ; JR e: target = PC + 2 + signed offset
    LD   HL, (debug_save_pc)
    INC  HL
    LD   A, (HL)                ; signed offset
    LD   HL, (debug_save_pc)
    LD   DE, 2
    ADD  HL, DE
    LD   E, A
    RLA
    SBC  A, A
    LD   D, A                   ; DE = sign-extended offset
    ADD  HL, DE                 ; HL = target
    EX   DE, HL
    CALL debug_check_rom
    JP   C, debug_sc_jp_rom
    LD   (debug_step_bp1), DE
    JP   debug_step_set

; --- Conditional branch ---
debug_sc_cond:
    LD   A, (debug_step_opcode)
    LD   B, A
    AND  0xC7
    ; RET cc (C0,C8,...): opcode & C7 == C0
    CP   0xC0
    JP   Z, debug_sc_cond_ret
    ; JP cc,nn: opcode & C7 == C2
    CP   0xC2
    JP   Z, debug_sc_cond_jp
    ; CALL cc,nn: opcode & C7 == C4
    CP   0xC4
    JP   Z, debug_sc_cond_call
    ; JR cc / DJNZ (Z80)
    LD   A, (debug_step_opcode)
    CP   0x10
    JP   Z, debug_sc_cond_jr
    AND  0xE7
    CP   0x20
    JP   Z, debug_sc_cond_jr
    ; Unknown conditional: just fall-through
    JP   debug_step_set

debug_sc_cond_ret:
    LD   HL, (debug_save_sp)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    CALL debug_check_rom
    JP   C, debug_step_set      ; ROM: only fall-through BP
    LD   (debug_step_bp2), DE
    JP   debug_step_set

debug_sc_cond_jp:
    LD   HL, (debug_save_pc)
    INC  HL
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    CALL debug_check_rom
    JP   C, debug_step_set
    LD   (debug_step_bp2), DE
    JP   debug_step_set

debug_sc_cond_call:
    ; Proceed: only fall-through.  Trace: also target if RAM.
    LD   A, (debug_step_mode)
    OR   A
    JP   NZ, debug_step_set
    LD   HL, (debug_save_pc)
    INC  HL
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    CALL debug_check_rom
    JP   C, debug_step_set
    LD   (debug_step_bp2), DE
    JP   debug_step_set

debug_sc_cond_jr:
    ; JR cc,e / DJNZ: target = PC + 2 + signed offset
    LD   HL, (debug_save_pc)
    INC  HL
    LD   A, (HL)
    LD   HL, (debug_save_pc)
    LD   DE, 2
    ADD  HL, DE
    LD   E, A
    RLA
    SBC  A, A
    LD   D, A
    ADD  HL, DE
    EX   DE, HL
    CALL debug_check_rom
    JP   C, debug_step_set
    LD   (debug_step_bp2), DE
    JP   debug_step_set

; --- Special: RST, JP (HL), HALT ---
debug_sc_special:
    LD   A, (debug_step_opcode)
    CP   0xE9
    JP   Z, debug_sc_jp_hl
    CP   0x76
    JP   Z, debug_sc_halt
    ; RST: always step over (targets are ROM).  BP at fall-through.
    JP   debug_step_set
debug_sc_halt:
    LD   DE, debug_msg_halt
    CALL debug_puts
    JP   debug_prompt

; ------------------------------------------------------------
; debug_check_rom
; Check if address in DE is below our app base (ROM).
; Returns: carry set = ROM, carry clear = RAM.
; Preserves DE.
; ------------------------------------------------------------
debug_check_rom:
    PUSH HL
    LD   HL, (debug_rom_boundary)
    LD   A, D
    CP   H
    JP   C, debug_cr_rom
    JP   NZ, debug_cr_ram
    LD   A, E
    CP   L
    JP   C, debug_cr_rom
debug_cr_ram:
    POP  HL
    OR   A                      ; clear carry
    RET
debug_cr_rom:
    POP  HL
    SCF
    RET

; ------------------------------------------------------------
; debug_step_set - Set temp breakpoints and resume with DI
; debug_step_bp1 = primary, debug_step_bp2 = secondary (0=none)
; ------------------------------------------------------------
debug_step_set:
    ; Set primary temp BP
    LD   DE, (debug_step_bp1)
    LD   A, D
    OR   E
    JP   Z, debug_step_err
    CALL debug_set_temp_bp
    ; Set secondary if non-zero and different from primary
    LD   DE, (debug_step_bp2)
    LD   A, D
    OR   E
    JP   Z, debug_step_arm
    LD   HL, (debug_step_bp1)
    LD   A, H
    CP   D
    JP   NZ, debug_ss_set2
    LD   A, L
    CP   E
    JP   Z, debug_step_arm
debug_ss_set2:
    CALL debug_set_temp_bp
debug_step_arm:
    ; Arm all breakpoints (permanent + temp)
    CALL debug_arm_breakpoints
    ; Suppress ISR during the single instruction so it hits the BP
    ; before any interrupt handler fires
    DI
    JP   debug_resume_target

debug_step_err:
    LD   DE, debug_msg_step_err
    CALL debug_puts
    JP   debug_prompt

; ------------------------------------------------------------
; debug_set_temp_bp
; Record a temporary breakpoint at address DE.
; Does NOT write 0xF7 yet — debug_arm_breakpoints does that.
; ------------------------------------------------------------
debug_set_temp_bp:
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP
debug_stb_find:
    ; Check if already a BP at this address
    LD   A, (HL)
    CP   E
    JP   NZ, debug_stb_not_match
    PUSH HL
    INC  HL
    LD   A, (HL)
    POP  HL
    CP   D
    JP   NZ, debug_stb_not_match
    ; Already a BP here (permanent) — it will be armed normally
    RET
debug_stb_not_match:
    ; Check if slot is free
    PUSH HL
    INC  HL
    INC  HL
    INC  HL
    LD   A, (HL)
    POP  HL
    AND  DEBUG_BPF_ACTIVE
    JP   Z, debug_stb_set
    ; Slot in use, next
    PUSH DE
    LD   DE, DEBUG_BP_SIZE
    ADD  HL, DE
    POP  DE
    DEC  B
    JP   NZ, debug_stb_find
    ; Table full
    LD   DE, debug_msg_bp_full
    CALL debug_puts
    JP   debug_prompt
debug_stb_set:
    LD   (HL), E
    INC  HL
    LD   (HL), D
    INC  HL
    LD   A, (DE)                ; save original byte
    LD   (HL), A
    INC  HL
    LD   (HL), DEBUG_BPF_ACTIVE | DEBUG_BPF_TEMP
    RET

; ------------------------------------------------------------
; debug_disarm_temp_bps
; Find and clear ALL temporary breakpoints.  Restores original
; bytes and zeros the table entries.
; ------------------------------------------------------------
debug_disarm_temp_bps:
    LD   HL, debug_bp_table
    LD   B, DEBUG_MAX_BP
debug_dt_loop:
    PUSH HL
    INC  HL
    INC  HL
    INC  HL
    LD   A, (HL)                ; flags
    POP  HL
    AND  DEBUG_BPF_TEMP
    JP   Z, debug_dt_skip
    ; Temp BP — restore original byte and clear entry
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    LD   A, (HL)                ; orig_byte
    LD   (DE), A                ; restore
    ; Zero the entry (we're at orig_byte field)
    XOR  A
    LD   (HL), A                ; clear orig_byte
    DEC  HL
    LD   (HL), A                ; clear addr high
    DEC  HL
    LD   (HL), A                ; clear addr low
    INC  HL
    INC  HL
    INC  HL
    LD   (HL), A                ; clear flags
    INC  HL                     ; next entry
    DEC  B
    JP   NZ, debug_dt_loop
    RET
debug_dt_skip:
    PUSH DE
    LD   DE, DEBUG_BP_SIZE
    ADD  HL, DE
    POP  DE
    DEC  B
    JP   NZ, debug_dt_loop
    RET

; ------------------------------------------------------------
; debug_ddfd_len - compute length of DD/FD prefixed instruction
; Input: HL = address of byte AFTER the DD/FD prefix
; Output: A = total instruction length (including prefix)
; ------------------------------------------------------------
debug_ddfd_len:
    LD   A, (HL)
    ; DD CB d op = 4 bytes
    CP   0xCB
    JP   Z, debug_ddfd_4
    ; Chained prefix (DD DD, DD FD, DD ED) = 2 bytes
    CP   0xDD
    JP   Z, debug_ddfd_2
    CP   0xFD
    JP   Z, debug_ddfd_2
    CP   0xED
    JP   Z, debug_ddfd_2
    ; Look up base instruction length
    PUSH HL
    LD   D, 0
    LD   E, A
    LD   C, A                   ; save base opcode
    LD   HL, debug_opcode_tbl
    ADD  HL, DE
    LD   A, (HL)
    AND  0x0F                   ; base length
    POP  HL
    LD   B, A                   ; B = base length
    ; Check if base instruction uses (HL) → add displacement byte
    LD   A, C                   ; recover base opcode
    CALL debug_needs_disp
    LD   A, B                   ; base length
    JP   NC, debug_ddfd_nodisp
    INC  A                      ; add displacement byte
debug_ddfd_nodisp:
    INC  A                      ; add prefix byte
    RET
debug_ddfd_4:
    LD   A, 4
    RET
debug_ddfd_2:
    LD   A, 2
    RET

; ------------------------------------------------------------
; debug_needs_disp - does this opcode use (HL) in a DD/FD context?
; Input: A = opcode (byte after DD/FD prefix)
; Output: carry set if displacement byte needed
; ------------------------------------------------------------
debug_needs_disp:
    CP   0x34                   ; INC (HL)
    SCF
    RET  Z
    CP   0x35                   ; DEC (HL)
    SCF
    RET  Z
    CP   0x36                   ; LD (HL),n
    SCF
    RET  Z
    ; LD (HL),r: 70-77
    PUSH AF
    AND  0xF8
    CP   0x70
    JP   Z, debug_nd_yes
    POP  AF
    ; Range 0x40-0xBF with src field == 6
    CP   0x40
    JP   C, debug_nd_no
    CP   0xC0
    JP   NC, debug_nd_no
    PUSH AF
    AND  0x07
    CP   6
    JP   Z, debug_nd_yes
    POP  AF
    ; For 0x40-0x7F: also check dst field == 6
    CP   0x80
    JP   NC, debug_nd_no
    PUSH AF
    RRCA
    RRCA
    RRCA
    AND  0x07
    CP   6
    JP   Z, debug_nd_yes
    POP  AF
debug_nd_no:
    OR   A
    RET
debug_nd_yes:
    POP  AF
    SCF
    RET

; ============================================================
; debug_disasm_one - disassemble one instruction
; Input: HL = instruction address
; Output: HL = next instruction address
; Prints: "XXXX: XX XX XX    MNEMONIC\r\n"
; ============================================================
debug_disasm_one:
    LD   (debug_da_addr), HL
    ; Print address
    CALL debug_print_hex16
    LD   A, ':'
    CALL debug_putchar
    LD   A, ' '
    CALL debug_putchar
    ; Read opcode and determine length
    LD   HL, (debug_da_addr)
    LD   A, (HL)
    LD   (debug_da_opcode), A
    ; Look up length from table
    LD   D, 0
    LD   E, A
    LD   HL, debug_opcode_tbl
    ADD  HL, DE
    LD   A, (HL)
    AND  0x0F
    JP   NZ, debug_da_got_len
    ; Prefix: determine length
    LD   A, (debug_da_opcode)
    CP   0xCB
    JP   Z, debug_da_len2
    CP   0xED
    JP   Z, debug_da_len2
    ; DD/FD
    LD   HL, (debug_da_addr)
    INC  HL
    CALL debug_ddfd_len
    JP   debug_da_got_len
debug_da_len2:
    LD   A, 2
debug_da_got_len:
    LD   (debug_da_len), A
    ; Print hex bytes (up to 4)
    LD   HL, (debug_da_addr)
    LD   B, A                   ; B = byte count
    LD   C, 0                   ; C = chars printed
debug_da_hex_loop:
    LD   A, (HL)
    INC  HL
    CALL debug_print_hex8
    LD   A, ' '
    CALL debug_putchar
    INC  C
    INC  C
    INC  C                      ; 3 chars per byte
    DEC  B
    JP   NZ, debug_da_hex_loop
    ; Pad to column 14 (4 bytes * 3 = 12 chars max, pad to 14)
debug_da_pad:
    LD   A, C
    CP   14
    JP   NC, debug_da_mnemonic
    LD   A, ' '
    CALL debug_putchar
    INC  C
    JP   debug_da_pad
debug_da_mnemonic:
    ; Print mnemonic
    LD   A, (debug_da_opcode)
    CALL debug_print_mnemonic
    CALL debug_crlf
    ; Return HL = next instruction
    LD   HL, (debug_da_addr)
    LD   A, (debug_da_len)
    LD   D, 0
    LD   E, A
    ADD  HL, DE
    RET

; ============================================================
; debug_print_mnemonic - print mnemonic for opcode
; Input: A = first opcode byte
;        debug_da_addr = instruction address
; ============================================================
debug_print_mnemonic:
    ; Route to handler based on opcode range
    CP   0x40
    JP   C, debug_mn_00_3f
    CP   0x80
    JP   C, debug_mn_40_7f
    CP   0xC0
    JP   C, debug_mn_80_bf
    JP   debug_mn_c0_ff

; --- 0x40-0x7F: LD r,r' and HALT ---
debug_mn_40_7f:
    CP   0x76
    JP   Z, debug_mn_halt
    PUSH AF
    LD   DE, debug_str_ld
    CALL debug_puts
    POP  AF
    PUSH AF
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_regname    ; dst
    LD   A, ','
    CALL debug_putchar
    POP  AF
    AND  0x07
    CALL debug_print_regname    ; src
    RET
debug_mn_halt:
    LD   DE, debug_str_halt
    CALL debug_puts
    RET

; --- 0x80-0xBF: ALU r ---
debug_mn_80_bf:
    PUSH AF
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_aluname    ; prints "ADD A," etc.
    POP  AF
    AND  0x07
    CALL debug_print_regname
    RET

; --- 0xC0-0xFF ---
debug_mn_c0_ff:
    LD   B, A                   ; save opcode in B
    AND  0x07
    JP   Z, debug_mn_cx0        ; RET cc
    CP   1
    JP   Z, debug_mn_cx1        ; POP/special
    CP   2
    JP   Z, debug_mn_cx2        ; JP cc,nn
    CP   3
    JP   Z, debug_mn_cx3        ; JP nn/OUT/IN/EX/DI/EI/prefix
    CP   4
    JP   Z, debug_mn_cx4        ; CALL cc,nn
    CP   5
    JP   Z, debug_mn_cx5        ; PUSH/CALL/prefix
    CP   6
    JP   Z, debug_mn_cx6        ; ALU A,n
    JP   debug_mn_cx7           ; RST

; RET cc
debug_mn_cx0:
    LD   DE, debug_str_ret
    CALL debug_puts
    LD   A, ' '
    CALL debug_putchar
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_ccname
    RET

; POP rr / RET / EXX / JP (HL) / LD SP,HL
debug_mn_cx1:
    LD   A, B
    CP   0xC9
    JP   Z, debug_mn_ret_plain
    CP   0xD9
    JP   Z, debug_mn_exx
    CP   0xE9
    JP   Z, debug_mn_jphl
    CP   0xF9
    JP   Z, debug_mn_ldsphl
    ; POP rr
    LD   DE, debug_str_pop
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x03
    CALL debug_print_rp2name    ; BC/DE/HL/AF
    RET
debug_mn_ret_plain:
    LD   DE, debug_str_ret
    CALL debug_puts
    RET
debug_mn_exx:
    LD   DE, debug_str_exx
    CALL debug_puts
    RET
debug_mn_jphl:
    LD   DE, debug_str_jphl
    CALL debug_puts
    RET
debug_mn_ldsphl:
    LD   DE, debug_str_ldsphl
    CALL debug_puts
    RET

; JP cc,nn
debug_mn_cx2:
    LD   DE, debug_str_jp
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_ccname
    LD   A, ','
    CALL debug_putchar
    JP   debug_mn_print_addr    ; print inline 16-bit address

; JP nn / OUT / IN / EX / DI / EI / prefix
debug_mn_cx3:
    LD   A, B
    CP   0xC3
    JP   Z, debug_mn_jp_nn
    CP   0xD3
    JP   Z, debug_mn_out
    CP   0xDB
    JP   Z, debug_mn_in
    CP   0xE3
    JP   Z, debug_mn_exsphl
    CP   0xEB
    JP   Z, debug_mn_exdehl
    CP   0xF3
    JP   Z, debug_mn_di
    CP   0xFB
    JP   Z, debug_mn_ei
    ; CB/DD/ED/FD prefix — show as DB
    JP   debug_mn_db
debug_mn_jp_nn:
    LD   DE, debug_str_jp
    CALL debug_puts
    JP   debug_mn_print_addr
debug_mn_out:
    LD   DE, debug_str_out
    CALL debug_puts
    CALL debug_mn_print_byte    ; port
    LD   DE, debug_str_rparena
    CALL debug_puts
    RET
debug_mn_in:
    LD   DE, debug_str_in
    CALL debug_puts
    CALL debug_mn_print_byte
    LD   A, ')'
    CALL debug_putchar
    RET
debug_mn_exsphl:
    LD   DE, debug_str_exsphl
    CALL debug_puts
    RET
debug_mn_exdehl:
    LD   DE, debug_str_exdehl
    CALL debug_puts
    RET
debug_mn_di:
    LD   DE, debug_str_di
    CALL debug_puts
    RET
debug_mn_ei:
    LD   DE, debug_str_ei
    CALL debug_puts
    RET

; CALL cc,nn
debug_mn_cx4:
    LD   DE, debug_str_call
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_ccname
    LD   A, ','
    CALL debug_putchar
    JP   debug_mn_print_addr

; PUSH rr / CALL nn / prefix
debug_mn_cx5:
    LD   A, B
    CP   0xCD
    JP   Z, debug_mn_call_nn
    ; Check for prefix (DD, ED, FD)
    CP   0xDD
    JP   Z, debug_mn_db
    CP   0xED
    JP   Z, debug_mn_ed
    CP   0xFD
    JP   Z, debug_mn_db
    ; PUSH rr
    LD   DE, debug_str_push
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x03
    CALL debug_print_rp2name
    RET
debug_mn_call_nn:
    LD   DE, debug_str_call
    CALL debug_puts
    JP   debug_mn_print_addr

; ED prefix disassembly
debug_mn_ed:
    LD   HL, (debug_da_addr)
    INC  HL
    LD   A, (HL)
    CP   0x46
    JP   Z, debug_mn_im0
    CP   0x56
    JP   Z, debug_mn_im1
    CP   0x5E
    JP   Z, debug_mn_im2
    CP   0x4D
    JP   Z, debug_mn_reti
    CP   0x45
    JP   Z, debug_mn_retn
    ; Default: DB ED,XX
    JP   debug_mn_db
debug_mn_im0:
    LD   DE, debug_str_im
    CALL debug_puts
    LD   A, '0'
    CALL debug_putchar
    RET
debug_mn_im1:
    LD   DE, debug_str_im
    CALL debug_puts
    LD   A, '1'
    CALL debug_putchar
    RET
debug_mn_im2:
    LD   DE, debug_str_im
    CALL debug_puts
    LD   A, '2'
    CALL debug_putchar
    RET
debug_mn_reti:
    LD   DE, debug_str_reti
    CALL debug_puts
    RET
debug_mn_retn:
    LD   DE, debug_str_retn
    CALL debug_puts
    RET

; ALU A,n
debug_mn_cx6:
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_aluname
    JP   debug_mn_print_byte

; RST n
debug_mn_cx7:
    LD   DE, debug_str_rst
    CALL debug_puts
    LD   A, B
    AND  0x38                   ; RST address
    CALL debug_print_hex8
    RET

; --- 0x00-0x3F ---
debug_mn_00_3f:
    LD   B, A
    AND  0x07
    CP   1
    JP   Z, debug_mn_0x1
    CP   2
    JP   Z, debug_mn_0x2
    CP   3
    JP   Z, debug_mn_0x3
    CP   4
    JP   Z, debug_mn_0x4
    CP   5
    JP   Z, debug_mn_0x5
    CP   6
    JP   Z, debug_mn_0x6
    CP   7
    JP   Z, debug_mn_0x7
    ; x0: NOP, EX AF, JR/DJNZ
    LD   A, B
    OR   A
    JP   Z, debug_mn_nop
    CP   0x08
    JP   Z, debug_mn_exaf
    CP   0x10
    JP   Z, debug_mn_djnz
    ; JR [cc,] offset
    CP   0x18
    JP   Z, debug_mn_jr_uncond
    ; JR cc,offset (20,28,30,38)
    LD   DE, debug_str_jr
    CALL debug_puts
    LD   A, B
    SUB  0x20
    RRCA
    RRCA
    RRCA
    AND  0x03
    CALL debug_print_ccname
    LD   A, ','
    CALL debug_putchar
    JP   debug_mn_jr_target

debug_mn_nop:
    LD   DE, debug_str_nop
    CALL debug_puts
    RET
debug_mn_exaf:
    LD   DE, debug_str_exafaf
    CALL debug_puts
    RET
debug_mn_djnz:
    LD   DE, debug_str_djnz
    CALL debug_puts
    JP   debug_mn_jr_target
debug_mn_jr_uncond:
    LD   DE, debug_str_jr
    CALL debug_puts
    ; fall through
debug_mn_jr_target:
    ; Print target = addr + 2 + signed offset
    LD   HL, (debug_da_addr)
    INC  HL
    LD   A, (HL)                ; signed offset
    LD   HL, (debug_da_addr)
    LD   DE, 2
    ADD  HL, DE
    LD   E, A
    RLA
    SBC  A, A
    LD   D, A
    ADD  HL, DE
    CALL debug_print_hex16
    RET

; x1: LD rr,nn (01,11,21,31) / ADD HL,rr (09,19,29,39)
debug_mn_0x1:
    LD   A, B
    AND  0x08
    JP   NZ, debug_mn_addhl
    ; LD rr,nn
    LD   DE, debug_str_ld
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x03
    CALL debug_print_rpname
    LD   A, ','
    CALL debug_putchar
    JP   debug_mn_print_addr
debug_mn_addhl:
    LD   DE, debug_str_addhl
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x03
    CALL debug_print_rpname
    RET

; x2: LD (BC/DE),A / LD A,(BC/DE) / LD (nn),HL/A / LD HL/A,(nn)
debug_mn_0x2:
    LD   A, B
    CP   0x22
    JP   Z, debug_mn_ld_nn_hl
    CP   0x2A
    JP   Z, debug_mn_ld_hl_nn
    CP   0x32
    JP   Z, debug_mn_ld_nn_a
    CP   0x3A
    JP   Z, debug_mn_ld_a_nn
    ; 02/0A/12/1A: LD (BC/DE),A / LD A,(BC/DE)
    LD   DE, debug_str_ld
    CALL debug_puts
    LD   A, B
    AND  0x08
    JP   NZ, debug_mn_0x2_load
    ; Store: LD (rr),A
    LD   A, '('
    CALL debug_putchar
    LD   A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x01                   ; 0=BC, 1=DE
    CALL debug_print_rpname
    LD   DE, debug_str_rparena
    CALL debug_puts
    RET
debug_mn_0x2_load:
    ; Load: LD A,(rr)
    LD   DE, debug_str_a_lp
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x01
    CALL debug_print_rpname
    LD   A, ')'
    CALL debug_putchar
    RET
debug_mn_ld_nn_hl:
    LD   DE, debug_str_ld
    CALL debug_puts
    LD   A, '('
    CALL debug_putchar
    CALL debug_mn_print_addr_raw
    LD   DE, debug_str_rp_hl
    CALL debug_puts
    RET
debug_mn_ld_hl_nn:
    LD   DE, debug_str_ldhl_lp
    CALL debug_puts
    CALL debug_mn_print_addr_raw
    LD   A, ')'
    CALL debug_putchar
    RET
debug_mn_ld_nn_a:
    LD   DE, debug_str_ld
    CALL debug_puts
    LD   A, '('
    CALL debug_putchar
    CALL debug_mn_print_addr_raw
    LD   DE, debug_str_rp_a
    CALL debug_puts
    RET
debug_mn_ld_a_nn:
    LD   DE, debug_str_a_lp
    CALL debug_puts
    CALL debug_mn_print_addr_raw
    LD   A, ')'
    CALL debug_putchar
    RET

; x3: INC rr (03,13,23,33) / DEC rr (0B,1B,2B,3B)
debug_mn_0x3:
    LD   A, B
    AND  0x08
    JP   NZ, debug_mn_decrr
    LD   DE, debug_str_inc
    JP   debug_mn_rr_op
debug_mn_decrr:
    LD   DE, debug_str_dec
debug_mn_rr_op:
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x03
    CALL debug_print_rpname
    RET

; x4: INC r (04,0C,14,1C,24,2C,34,3C)
debug_mn_0x4:
    LD   DE, debug_str_inc
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_regname
    RET

; x5: DEC r
debug_mn_0x5:
    LD   DE, debug_str_dec
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_regname
    RET

; x6: LD r,n
debug_mn_0x6:
    LD   DE, debug_str_ld
    CALL debug_puts
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_regname
    LD   A, ','
    CALL debug_putchar
    JP   debug_mn_print_byte

; x7: RLCA/RRCA/RLA/RRA/DAA/CPL/SCF/CCF
debug_mn_0x7:
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    CALL debug_print_miscname
    RET

; DB XX — fallback for unrecognized opcodes
debug_mn_db:
    LD   DE, debug_str_db
    CALL debug_puts
    LD   A, (debug_da_opcode)
    CALL debug_print_hex8
    RET

; --- Helpers: print inline byte/address from instruction ---
debug_mn_print_byte:
    LD   HL, (debug_da_addr)
    INC  HL
    LD   A, (HL)
    CALL debug_print_hex8
    RET

debug_mn_print_addr:
    LD   HL, (debug_da_addr)
    INC  HL
    LD   A, (HL)
    INC  HL
    LD   H, (HL)
    LD   L, A
    CALL debug_print_hex16
    RET

; Print raw address (no prefix) for LD (nn),HL etc.
debug_mn_print_addr_raw:
    JP   debug_mn_print_addr

; ============================================================
; Name lookup helpers
; ============================================================

; --- Print register name from 3-bit index in A ---
debug_print_regname:
    PUSH HL
    PUSH DE
    LD   E, A
    LD   D, 0
    LD   HL, debug_regname_off
    ADD  HL, DE
    LD   A, (HL)
    LD   E, A
    LD   HL, debug_regname_str
    ADD  HL, DE
    EX   DE, HL
    CALL debug_puts
    POP  DE
    POP  HL
    RET

; --- Print register pair name from 2-bit index in A (SP variant) ---
debug_print_rpname:
    PUSH HL
    PUSH DE
    LD   E, A
    LD   D, 0
    LD   HL, debug_rpname_off
    ADD  HL, DE
    LD   A, (HL)
    LD   E, A
    LD   HL, debug_rpname_str
    ADD  HL, DE
    EX   DE, HL
    CALL debug_puts
    POP  DE
    POP  HL
    RET

; --- Print register pair name from 2-bit index in A (AF variant) ---
debug_print_rp2name:
    PUSH HL
    PUSH DE
    LD   E, A
    LD   D, 0
    LD   HL, debug_rp2name_off
    ADD  HL, DE
    LD   A, (HL)
    LD   E, A
    LD   HL, debug_rp2name_str
    ADD  HL, DE
    EX   DE, HL
    CALL debug_puts
    POP  DE
    POP  HL
    RET

; --- Print condition code name from 3-bit index in A ---
debug_print_ccname:
    PUSH HL
    PUSH DE
    LD   E, A
    LD   D, 0
    LD   HL, debug_ccname_off
    ADD  HL, DE
    LD   A, (HL)
    LD   E, A
    LD   HL, debug_ccname_str
    ADD  HL, DE
    EX   DE, HL
    CALL debug_puts
    POP  DE
    POP  HL
    RET

; --- Print ALU operation name from 3-bit index in A ---
debug_print_aluname:
    PUSH HL
    PUSH DE
    LD   E, A
    LD   D, 0
    LD   HL, debug_aluname_off
    ADD  HL, DE
    LD   A, (HL)
    LD   E, A
    LD   HL, debug_aluname_str
    ADD  HL, DE
    EX   DE, HL
    CALL debug_puts
    POP  DE
    POP  HL
    RET

; --- Print misc 0x00-0x3F xxx111 name from 3-bit index in A ---
debug_print_miscname:
    PUSH HL
    PUSH DE
    LD   E, A
    LD   D, 0
    LD   HL, debug_miscname_off
    ADD  HL, DE
    LD   A, (HL)
    LD   E, A
    LD   HL, debug_miscname_str
    ADD  HL, DE
    EX   DE, HL
    CALL debug_puts
    POP  DE
    POP  HL
    RET

; ============================================================
; Utilities
; ============================================================

; --- Print character in A to console ---
debug_putchar:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  DE
    POP  BC
    POP  AF
    RET

; --- Print null-terminated string at DE to console ---
debug_puts:
    PUSH BC
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    POP  BC
    RET

; --- Print CR LF ---
debug_crlf:
    LD   A, 0x0D
    CALL debug_putchar
    LD   A, 0x0A
    CALL debug_putchar
    RET

; --- Print A as 2-digit hex ---
debug_print_hex8:
    PUSH AF
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x0F
    CALL debug_print_nib
    POP  AF
    AND  0x0F
    CALL debug_print_nib
    RET

debug_print_nib:
    CP   10
    JP   C, debug_pn_dec
    ADD  A, 'A' - 10
    JP   debug_pn_out
debug_pn_dec:
    ADD  A, '0'
debug_pn_out:
    CALL debug_putchar
    RET

; --- Print HL as 4-digit hex ---
debug_print_hex16:
    LD   A, H
    CALL debug_print_hex8
    LD   A, L
    CALL debug_print_hex8
    RET

; --- Skip spaces at (HL) ---
debug_skip_spaces:
    LD   A, (HL)
    CP   ' '
    RET  NZ
    INC  HL
    JP   debug_skip_spaces

; --- Parse hex number from (HL) → DE, digit count in B ---
debug_parse_hex:
    LD   DE, 0
    LD   B, 0
debug_ph_loop:
    LD   A, (HL)
    CP   '0'
    JP   C, debug_ph_done
    CP   '9'+1
    JP   C, debug_ph_digit
    AND  0xDF
    CP   'A'
    JP   C, debug_ph_done
    CP   'F'+1
    JP   NC, debug_ph_done
    SUB  'A' - 10
    JP   debug_ph_add
debug_ph_digit:
    SUB  '0'
debug_ph_add:
    PUSH AF
    EX   DE, HL
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    EX   DE, HL
    POP  AF
    ADD  A, E
    LD   E, A
    LD   A, 0
    ADC  A, D
    LD   D, A
    INC  HL
    INC  B
    JP   debug_ph_loop
debug_ph_done:
    RET

; ============================================================
; String data
; ============================================================
debug_banner:
    DEFM "NostOS Debug"
    DEFB 0x0D, 0x0A
    DEFM "Type ? for help"
    DEFB 0x0D, 0x0A, 0

debug_msg_help:
    DEFM "B               List breakpoints"
    DEFB 0x0D, 0x0A
    DEFM "B addr          Set breakpoint"
    DEFB 0x0D, 0x0A
    DEFM "BC addr|*       Clear breakpoint(s)"
    DEFB 0x0D, 0x0A
    DEFM "D [addr]        Dump memory"
    DEFB 0x0D, 0x0A
    DEFM "E addr bb [..]  Enter bytes"
    DEFB 0x0D, 0x0A
    DEFM "F start end bb  Fill memory"
    DEFB 0x0D, 0x0A
    DEFM "G [addr]        Go (run)"
    DEFB 0x0D, 0x0A
    DEFM "I port          Input port"
    DEFB 0x0D, 0x0A
    DEFM "L file [addr]   Load program"
    DEFB 0x0D, 0x0A
    DEFM "O port bb       Output port"
    DEFB 0x0D, 0x0A
    DEFM "P               Proceed (step over)"
    DEFB 0x0D, 0x0A
    DEFM "Q               Quit"
    DEFB 0x0D, 0x0A
    DEFM "R               Register dump"
    DEFB 0x0D, 0x0A
    DEFM "R reg=val       Modify register"
    DEFB 0x0D, 0x0A
    DEFM "T               Trace (step into)"
    DEFB 0x0D, 0x0A
    DEFM "U [addr]        Unassemble"
    DEFB 0x0D, 0x0A, 0

debug_str_af:   DEFM "AF=", 0
debug_str_bc:   DEFM "BC=", 0
debug_str_de:   DEFM "DE=", 0
debug_str_hl:   DEFM "HL=", 0
debug_str_sp:   DEFM "SP=", 0
debug_str_pc:   DEFM "PC=", 0

debug_msg_unknown:
    DEFM "Unknown command"
    DEFB 0x0D, 0x0A, 0

debug_msg_syntax:
    DEFM "Syntax error"
    DEFB 0x0D, 0x0A, 0

debug_msg_range:
    DEFM "Out of range"
    DEFB 0x0D, 0x0A, 0

debug_msg_bp_exists:
    DEFM "Breakpoint already set"
    DEFB 0x0D, 0x0A, 0

debug_msg_bp_full:
    DEFM "Breakpoint table full"
    DEFB 0x0D, 0x0A, 0

debug_msg_bp_notfound:
    DEFM "Breakpoint not found"
    DEFB 0x0D, 0x0A, 0

debug_msg_bp_none:
    DEFM "No breakpoints set"
    DEFB 0x0D, 0x0A, 0

debug_msg_loaded:
    DEFM "Loaded at ", 0

debug_msg_entry:
    DEFM ", entry ", 0

debug_msg_len:
    DEFM ", ", 0

debug_msg_bytes:
    DEFM " bytes"
    DEFB 0x0D, 0x0A, 0

debug_msg_open_err:
    DEFM "Cannot open file"
    DEFB 0x0D, 0x0A, 0

debug_msg_io_err:
    DEFM "I/O error"
    DEFB 0x0D, 0x0A, 0

debug_msg_no_target:
    DEFM "No program loaded"
    DEFB 0x0D, 0x0A, 0

debug_msg_returned:
    DEFM "Program returned to system"
    DEFB 0x0D, 0x0A, 0

debug_msg_rom_jp:
    DEFM "Cannot trace into ROM"
    DEFB 0x0D, 0x0A, 0

debug_msg_halt:
    DEFM "CPU HALT"
    DEFB 0x0D, 0x0A, 0

debug_msg_step_err:
    DEFM "Step error"
    DEFB 0x0D, 0x0A, 0

; --- Disassembler mnemonic strings ---
debug_str_nop:     DEFM "NOP", 0
debug_str_halt:    DEFM "HALT", 0
debug_str_ld:      DEFM "LD ", 0
debug_str_inc:     DEFM "INC ", 0
debug_str_dec:     DEFM "DEC ", 0
debug_str_addhl:   DEFM "ADD HL,", 0
debug_str_push:    DEFM "PUSH ", 0
debug_str_pop:     DEFM "POP ", 0
debug_str_jp:      DEFM "JP ", 0
debug_str_call:    DEFM "CALL ", 0
debug_str_ret:     DEFM "RET", 0
debug_str_rst:     DEFM "RST ", 0
debug_str_jr:      DEFM "JR ", 0
debug_str_djnz:    DEFM "DJNZ ", 0
debug_str_in:      DEFM "IN A,(", 0
debug_str_out:     DEFM "OUT (", 0
debug_str_di:      DEFM "DI", 0
debug_str_ei:      DEFM "EI", 0
debug_str_exx:     DEFM "EXX", 0
debug_str_exsphl:  DEFM "EX (SP),HL", 0
debug_str_exdehl:  DEFM "EX DE,HL", 0
debug_str_exafaf:  DEFM "EX AF,AF'", 0
debug_str_jphl:    DEFM "JP (HL)", 0
debug_str_ldsphl:  DEFM "LD SP,HL", 0
debug_str_db:      DEFM "DB ", 0
debug_str_rparena: DEFM "),A", 0
debug_str_a_lp:    DEFM "LD A,(", 0
debug_str_rp_hl:   DEFM "),HL", 0
debug_str_rp_a:    DEFM "),A", 0
debug_str_ldhl_lp: DEFM "LD HL,(", 0
debug_str_im:      DEFM "IM ", 0
debug_str_reti:    DEFM "RETI", 0
debug_str_retn:    DEFM "RETN", 0

; --- Name lookup tables ---
debug_regname_str:
    DEFM "B", 0                ; 0
    DEFM "C", 0                ; 2
    DEFM "D", 0                ; 4
    DEFM "E", 0                ; 6
    DEFM "H", 0                ; 8
    DEFM "L", 0                ; 10
    DEFM "(HL)", 0             ; 12
    DEFM "A", 0                ; 17
debug_regname_off:
    DEFB 0, 2, 4, 6, 8, 10, 12, 17

debug_rpname_str:
    DEFM "BC", 0               ; 0
    DEFM "DE", 0               ; 3
    DEFM "HL", 0               ; 6
    DEFM "SP", 0               ; 9
debug_rpname_off:
    DEFB 0, 3, 6, 9

debug_rp2name_str:
    DEFM "BC", 0               ; 0
    DEFM "DE", 0               ; 3
    DEFM "HL", 0               ; 6
    DEFM "AF", 0               ; 9
debug_rp2name_off:
    DEFB 0, 3, 6, 9

debug_ccname_str:
    DEFM "NZ", 0               ; 0
    DEFM "Z", 0                ; 3
    DEFM "NC", 0               ; 5
    DEFM "C", 0                ; 8
    DEFM "PO", 0               ; 10
    DEFM "PE", 0               ; 13
    DEFM "P", 0                ; 16
    DEFM "M", 0                ; 18
debug_ccname_off:
    DEFB 0, 3, 5, 8, 10, 13, 16, 18

debug_aluname_str:
    DEFM "ADD A,", 0           ; 0
    DEFM "ADC A,", 0           ; 7
    DEFM "SUB ", 0             ; 14
    DEFM "SBC A,", 0           ; 19
    DEFM "AND ", 0             ; 26
    DEFM "XOR ", 0             ; 31
    DEFM "OR ", 0              ; 36
    DEFM "CP ", 0              ; 40
debug_aluname_off:
    DEFB 0, 7, 14, 19, 26, 31, 36, 40

debug_miscname_str:
    DEFM "RLCA", 0             ; 0
    DEFM "RRCA", 0             ; 5
    DEFM "RLA", 0              ; 10
    DEFM "RRA", 0              ; 14
    DEFM "DAA", 0              ; 18
    DEFM "CPL", 0              ; 22
    DEFM "SCF", 0              ; 26
    DEFM "CCF", 0              ; 30
debug_miscname_off:
    DEFB 0, 5, 10, 14, 18, 22, 26, 30

; ============================================================
; Opcode info table (256 bytes)
; Encoding per byte:
;   bits 7:6 = branch type: 00=none, 01=unconditional, 10=conditional, 11=special
;   bits 5:4 = operand type: 00=none, 01=imm8, 10=imm16, 11=special
;   bits 3:0 = instruction length (0 = prefix byte)
; ============================================================
debug_opcode_tbl:
    ; 0x00-0x0F: NOP, LD BC,nn, LD (BC),A, INC BC, INC B, DEC B, LD B,n, RLCA
    ;            EX AF,AF', ADD HL,BC, LD A,(BC), DEC BC, INC C, DEC C, LD C,n, RRCA
    DEFB 0x01, 0x23, 0x01, 0x01, 0x01, 0x01, 0x12, 0x01
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x12, 0x01
    ; 0x10-0x1F: DJNZ, LD DE,nn, LD (DE),A, INC DE, INC D, DEC D, LD D,n, RLA
    ;            JR e, ADD HL,DE, LD A,(DE), DEC DE, INC E, DEC E, LD E,n, RRA
    DEFB 0x92, 0x23, 0x01, 0x01, 0x01, 0x01, 0x12, 0x01
    DEFB 0x52, 0x01, 0x01, 0x01, 0x01, 0x01, 0x12, 0x01
    ; 0x20-0x2F: JR NZ, LD HL,nn, LD (nn),HL, INC HL, INC H, DEC H, LD H,n, DAA
    ;            JR Z, ADD HL,HL, LD HL,(nn), DEC HL, INC L, DEC L, LD L,n, CPL
    DEFB 0x92, 0x23, 0x23, 0x01, 0x01, 0x01, 0x12, 0x01
    DEFB 0x92, 0x01, 0x23, 0x01, 0x01, 0x01, 0x12, 0x01
    ; 0x30-0x3F: JR NC, LD SP,nn, LD (nn),A, INC SP, INC (HL), DEC (HL), LD (HL),n, SCF
    ;            JR C, ADD HL,SP, LD A,(nn), DEC SP, INC A, DEC A, LD A,n, CCF
    DEFB 0x92, 0x23, 0x23, 0x01, 0x01, 0x01, 0x12, 0x01
    DEFB 0x92, 0x01, 0x23, 0x01, 0x01, 0x01, 0x12, 0x01
    ; 0x40-0x4F: LD B,B..LD B,A  LD C,B..LD C,A (all len 1, no branch)
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ; 0x50-0x5F: LD D,r..LD E,r
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ; 0x60-0x6F: LD H,r..LD L,r
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ; 0x70-0x7F: LD (HL),r..LD A,r  (0x76 = HALT = special)
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xC1, 0x01
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ; 0x80-0x8F: ADD/ADC A,r (all len 1, no branch)
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ; 0x90-0x9F: SUB/SBC A,r
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ; 0xA0-0xAF: AND/XOR r
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ; 0xB0-0xBF: OR/CP r
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    DEFB 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ; 0xC0-0xCF: RET NZ, POP BC, JP NZ, JP nn, CALL NZ, PUSH BC, ADD A,n, RST 00
    ;            RET Z, RET, JP Z, CB pfx, CALL Z, CALL nn, ADC A,n, RST 08
    DEFB 0x81, 0x01, 0xA3, 0x63, 0xA3, 0x01, 0x12, 0xC1
    DEFB 0x81, 0x41, 0xA3, 0x00, 0xA3, 0x63, 0x12, 0xC1
    ; 0xD0-0xDF: RET NC, POP DE, JP NC, OUT, CALL NC, PUSH DE, SUB n, RST 10
    ;            RET C, EXX, JP C, IN, CALL C, DD pfx, SBC A,n, RST 18
    DEFB 0x81, 0x01, 0xA3, 0x12, 0xA3, 0x01, 0x12, 0xC1
    DEFB 0x81, 0x01, 0xA3, 0x12, 0xA3, 0x00, 0x12, 0xC1
    ; 0xE0-0xEF: RET PO, POP HL, JP PO, EX(SP)HL, CALL PO, PUSH HL, AND n, RST 20
    ;            RET PE, JP (HL), JP PE, EX DE,HL, CALL PE, ED pfx, XOR n, RST 28
    DEFB 0x81, 0x01, 0xA3, 0x01, 0xA3, 0x01, 0x12, 0xC1
    DEFB 0x81, 0xC1, 0xA3, 0x01, 0xA3, 0x00, 0x12, 0xC1
    ; 0xF0-0xFF: RET P, POP AF, JP P, DI, CALL P, PUSH AF, OR n, RST 30
    ;            RET M, LD SP,HL, JP M, EI, CALL M, FD pfx, CP n, RST 38
    DEFB 0x81, 0x01, 0xA3, 0x01, 0xA3, 0x01, 0x12, 0xC1
    DEFB 0x81, 0x01, 0xA3, 0x01, 0xA3, 0x00, 0x12, 0xC1

; ============================================================
; Variables
; ============================================================

; Saved register state (the target program's registers)
debug_save_af:   DEFW 0
debug_save_bc:   DEFW 0
debug_save_de:   DEFW 0
debug_save_hl:   DEFW 0
debug_save_sp:   DEFW 0
debug_save_pc:   DEFW 0

; Breakpoint table: DEBUG_MAX_BP entries of DEBUG_BP_SIZE bytes
; Each: addr(2) + orig_byte(1) + flags(1)
debug_bp_table:  DEFS DEBUG_MAX_BP * DEBUG_BP_SIZE, 0

; Loader state
debug_l_handle:  DEFB 0
debug_load_addr: DEFW 0
debug_has_target: DEFB 0
debug_target_base: DEFW 0
debug_target_len: DEFW 0
debug_reloc_cnt: DEFW 0
debug_reloc_ptr: DEFW 0

; Existing command variables
debug_dump_addr: DEFW 0x0000
debug_e_addr:    DEFW 0x0000
debug_f_start:   DEFW 0x0000
debug_f_end:     DEFW 0x0000
debug_d_count:   DEFB 0

; Step/trace state
debug_go_pending: DEFB 0       ; 1 = G is pending after silent step past BP
debug_step_mode:  DEFB 0       ; 0=trace, 1=proceed
debug_step_opcode: DEFB 0
debug_step_info:  DEFB 0
debug_step_len:   DEFB 0
debug_step_bp1:   DEFW 0       ; primary temp BP address
debug_step_bp2:   DEFW 0       ; secondary temp BP address (conditional)
debug_rom_boundary: DEFW 0     ; USER_PROGRAM_BASE (saved at startup)
debug_saved_rst6:   DEFW 0     ; original RST 6 target (restored on quit)

; Disassembler state
debug_u_addr:     DEFW 0
debug_da_addr:    DEFW 0
debug_da_opcode:  DEFB 0
debug_da_len:     DEFB 0

; Register modify temp
debug_r_name:     DEFS 2, 0

; Input buffer
debug_buf:       DEFS 256, 0

; Private stack for break handler (grows down from debug_stack_top)
debug_stack:     DEFS DEBUG_STACK_SIZE, 0
debug_stack_top:

; Everything above this point is the debugger.  The L command loads
; the target program starting at debug_end.
debug_end:

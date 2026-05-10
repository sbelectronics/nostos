; ============================================================
; term.asm - Dumb terminal: bidirectional byte pipe between the
; local console (CONI/CONO) and a named serial device.
;
; Usage: TERM <device>
;   <device>  logical or physical device name resolved via
;             DEV_LOOKUP. The device must support both
;             DEVCAP_CHAR_IN and DEVCAP_CHAR_OUT.
;
; Keys (interpreted on console input only; remote bytes are
; never interpreted):
;   Ctrl-X            exit
;   Ctrl-A E          toggle local echo (default off)
;   Ctrl-A B          toggle hex display of non-printable
;                     bytes received from the remote (default off)
;   Ctrl-A D          open dialing directory (TERM.DIR in CWD)
;   Ctrl-A H          modem hangup (+++ guard, ATH<CR>)
;   Ctrl-A ?          one-line help
;   Ctrl-A Ctrl-A     send a literal Ctrl-A byte to the remote
;   Ctrl-A <other>    error
;
; Hex display: when on, bytes received from the remote that are
; not 0x09/0x0A/0x0D and not in 0x20..0x7E are rendered as <XX>.
; The console->remote direction is always raw.
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point - jump over header to main
    JP   term_main

    ; Header pad: 13 bytes of zeros (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================
TERM_CTRL_A        EQU 0x01
TERM_CTRL_X        EQU 0x18

TERM_STATE_ESCAPED EQU 1

; ============================================================
; term_main
; ============================================================
term_main:
    ; --- Parse argument ---
    LD   HL, (EXEC_ARGS_PTR)

    ; Skip leading spaces (executive usually strips, but be safe)
term_main_skipsp:
    LD   A, (HL)
    CP   ' '
    JP   NZ, term_main_have_arg
    INC  HL
    JP   term_main_skipsp

term_main_have_arg:
    LD   A, (HL)
    OR   A
    JP   Z, term_err_usage

    ; Save argument start
    LD   (term_argname_ptr), HL

    ; Walk to end-of-token; null-terminate at first space if any
term_main_termloop:
    LD   A, (HL)
    OR   A
    JP   Z, term_main_termdone
    CP   ' '
    JP   Z, term_main_termspace
    INC  HL
    JP   term_main_termloop
term_main_termspace:
    LD   (HL), 0                ; null-terminate token
term_main_termdone:

    ; --- Resolve device by name ---
    LD   DE, (term_argname_ptr)
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    OR   A
    JP   NZ, term_err_notfound
    LD   A, L
    LD   (term_remote_id), A

    ; --- Capability check: get PDT entry, verify CHAR_IN+CHAR_OUT ---
    LD   B, A                   ; B = device ID
    AND  0x80
    JP   NZ, term_caps_logical

    ; Physical: DEV_PHYS_GET -> HL = PDT entry
    LD   C, DEV_PHYS_GET
    CALL KERNELADDR
    OR   A
    JP   NZ, term_err_no_chario
    JP   term_caps_check_hl

term_caps_logical:
    ; Logical: DEV_LOG_GET -> HL = logdev entry; follow physptr
    LD   C, DEV_LOG_GET
    CALL KERNELADDR
    OR   A
    JP   NZ, term_err_no_chario
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    LD   A, D
    OR   E
    JP   Z, term_err_no_chario
    EX   DE, HL                 ; HL = PDT entry

term_caps_check_hl:
    LD   DE, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  0x03                   ; CHAR_IN | CHAR_OUT
    CP   0x03
    JP   NZ, term_err_no_chario

    ; --- Initialize state ---
    XOR  A
    LD   (term_state), A
    LD   (term_echo), A
    LD   (term_hex), A

    ; --- Print connect banner: "[term: connected to <NAME>. ..." ---
    LD   DE, term_msg_connect1
    CALL term_emit_str
    LD   DE, (term_argname_ptr)
    CALL term_emit_str
    LD   DE, term_msg_connect2
    CALL term_emit_str

    ; --- Main poll loop ---
    ; DEV_STAT returns A = status, HL = readiness (1 if char waiting,
    ; else 0). On a non-success A the L value is undefined, so we
    ; skip that side this iteration rather than blindly acting on L.
term_loop:
    ; Poll remote: any byte waiting?
    LD   A, (term_remote_id)
    LD   B, A
    LD   C, DEV_STAT
    CALL KERNELADDR
    OR   A
    JP   NZ, term_loop_console          ; remote DEV_STAT errored — skip
    LD   A, L
    OR   A
    CALL NZ, term_handle_remote

term_loop_console:
    ; Poll console: any byte waiting?
    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_STAT
    CALL KERNELADDR
    OR   A
    JP   NZ, term_loop                  ; console DEV_STAT errored — skip
    LD   A, L
    OR   A
    JP   Z, term_loop
    CALL term_handle_console
    JP   term_loop

; ============================================================
; term_handle_remote
; A byte is waiting on the remote. Read it and emit to the
; console, with optional hex translation when term_hex is set.
; ============================================================
term_handle_remote:
    LD   A, (term_remote_id)
    LD   B, A
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    OR   A                      ; check status — only L is valid on success
    RET  NZ                     ; read errored; drop the iteration silently
    LD   A, L                   ; A = byte received
    LD   B, A                   ; save byte in B
    LD   A, (term_hex)
    OR   A
    JP   Z, term_handle_remote_raw  ; hex mode off: emit raw

    ; Hex mode: pass through 0x09 (TAB), 0x0A (LF), 0x0D (CR)
    ; and printable ASCII 0x20..0x7E. Render everything else
    ; as <XX>.
    LD   A, B
    CP   0x09
    JP   Z, term_handle_remote_raw
    CP   0x0A
    JP   Z, term_handle_remote_raw
    CP   0x0D
    JP   Z, term_handle_remote_raw
    CP   0x20
    JP   C, term_handle_remote_hex   ; A < 0x20 -> hex
    CP   0x7F
    JP   NC, term_handle_remote_hex  ; A >= 0x7F -> hex
    ; printable: fall through to raw

term_handle_remote_raw:
    LD   A, B
    CALL term_emit_byte
    RET

term_handle_remote_hex:
    LD   A, '<'
    CALL term_emit_byte
    LD   A, B
    CALL term_emit_hex
    LD   A, '>'
    CALL term_emit_byte
    RET

; ============================================================
; term_handle_console
; A byte is waiting on the console. Read it, dispatch via the
; state machine.
; ============================================================
term_handle_console:
    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    OR   A                      ; check status — only L is valid on success
    RET  NZ                     ; read errored; drop the iteration silently
    LD   A, L                   ; A = byte from console

    ; Dispatch on current state
    LD   B, A                   ; save byte in B
    LD   A, (term_state)
    OR   A
    JP   NZ, term_state_escaped

    ; --- NORMAL state ---
    LD   A, B
    CP   TERM_CTRL_X
    JP   Z, term_exit
    CP   TERM_CTRL_A
    JP   Z, term_enter_escaped

    ; Forward byte to remote
    CALL term_send_remote
    ; If echo is on, also emit locally
    LD   A, (term_echo)
    OR   A
    RET  Z
    LD   A, B
    CALL term_emit_byte
    RET

term_enter_escaped:
    LD   A, TERM_STATE_ESCAPED
    LD   (term_state), A
    RET

; --- ESCAPED state: B = the second byte ---
term_state_escaped:
    ; Reset to NORMAL up front; every escaped key returns there.
    XOR  A
    LD   (term_state), A

    LD   A, B
    CP   TERM_CTRL_A
    JP   Z, term_esc_literal
    CP   '?'
    JP   Z, term_esc_help

    ; Upcase letters for command match
    CP   'a'
    JP   C, term_esc_after_upcase
    CP   'z' + 1
    JP   NC, term_esc_after_upcase
    AND  0x5F
term_esc_after_upcase:
    CP   'E'
    JP   Z, term_esc_echo
    CP   'B'
    JP   Z, term_esc_hex
    CP   'D'
    JP   Z, term_esc_dial
    CP   'H'
    JP   Z, term_esc_hangup

    ; Unknown command
    LD   DE, term_msg_unknown
    JP   term_emit_str          ; tail-call

term_esc_literal:
    ; Send a literal Ctrl-A byte to the remote.
    LD   A, TERM_CTRL_A
    CALL term_send_remote
    LD   A, (term_echo)
    OR   A
    RET  Z
    LD   A, TERM_CTRL_A
    CALL term_emit_byte
    RET

term_esc_help:
    LD   DE, term_msg_help
    JP   term_emit_str

term_esc_echo:
    ; Toggle term_echo (0<->1) and report state
    LD   A, (term_echo)
    XOR  1
    LD   (term_echo), A
    OR   A
    JP   Z, term_esc_echo_off
    LD   DE, term_msg_echo_on
    JP   term_emit_str
term_esc_echo_off:
    LD   DE, term_msg_echo_off
    JP   term_emit_str

term_esc_hex:
    LD   A, (term_hex)
    XOR  1
    LD   (term_hex), A
    OR   A
    JP   Z, term_esc_hex_off
    LD   DE, term_msg_hex_on
    JP   term_emit_str
term_esc_hex_off:
    LD   DE, term_msg_hex_off
    JP   term_emit_str

; ============================================================
; term_esc_dial
; Ctrl-A D: open TERM.DIR, list its entries, prompt for a
; selection, and send the chosen dial string to the remote.
; ============================================================
term_esc_dial:
    ; Open and read TERM.DIR (block 0 -> term_block_buf).
    CALL term_dir_load
    OR   A
    JP   NZ, term_esc_dial_no_file

    ; --- Pass 1: list ---
    XOR  A
    LD   (term_dir_mode), A             ; 0 = list mode
    LD   DE, term_msg_dial_header
    CALL term_emit_str
    CALL term_scan_buffer

    ; If the file has no entries, warn and return.
    LD   A, (term_dir_count)
    OR   A
    JP   Z, term_esc_dial_empty

    ; --- Prompt ---
    CALL term_dial_prompt
    CP   0xFF
    RET  Z                              ; cancelled or invalid (msg already shown)

    ; --- Pass 2: dial the chosen index ---
    LD   (term_dir_target), A
    LD   A, 1
    LD   (term_dir_mode), A             ; 1 = dial mode
    XOR  A
    LD   (term_dir_dialed), A
    CALL term_scan_buffer

    ; Print "[term: dialing <name>]"
    LD   DE, term_msg_dial_prefix
    CALL term_emit_str
    LD   HL, (term_dial_match_name)
    CALL term_emit_token
    LD   DE, term_msg_dial_suffix
    JP   term_emit_str

term_esc_dial_no_file:
    LD   DE, term_msg_no_dir
    JP   term_emit_str

term_esc_dial_empty:
    LD   DE, term_msg_no_entries
    JP   term_emit_str

; ============================================================
; term_dir_load
; Open TERM.DIR in CWD, read block 0 into term_block_buf, then
; close the file. After return, the buffer holds the file's
; content, zero-padded past EOF by the FS layer.
; Outputs:
;   A - 0 on success, nonzero on failure (file missing, etc.)
; ============================================================
term_dir_load:
    LD   DE, term_dir_filename
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    OR   A
    RET  NZ                             ; couldn't open
    LD   A, L
    LD   (term_dir_handle), A

    ; Read block 0 into the buffer.
    LD   B, A
    LD   DE, term_block_buf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    PUSH AF                             ; preserve read result across close

    LD   A, (term_dir_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    POP  AF
    RET                                 ; A = read status (0 if ok)

; ============================================================
; term_scan_buffer
; Walk term_block_buf, parsing one entry per non-blank,
; non-comment line. For each valid entry:
;   - If term_dir_mode == 0 (list): print a numbered line.
;   - If term_dir_mode == 1 (dial): when the entry's index
;     matches term_dir_target, send its dial string to the
;     remote and stop.
; Walks until the first null byte (the FS layer pads block 0
; with zeros past EOF, giving us a natural sentinel).
; ============================================================
term_scan_buffer:
    XOR  A
    LD   (term_dir_count), A
    LD   HL, term_block_buf

term_scan_main:
    ; Skip leading whitespace within a line (space, tab).
    CALL term_skip_inline_ws
    LD   A, (HL)
    OR   A
    RET  Z                              ; null = EOF
    CP   0x0D
    JP   Z, term_scan_eat_eol
    CP   0x0A
    JP   Z, term_scan_eat_eol
    CP   '#'
    JP   Z, term_scan_skip_line

    ; Real entry: HL points at first char of name.
    LD   (term_name_ptr), HL
    CALL term_find_name_end             ; advances HL past name

    ; Skip whitespace before the dial string.
    CALL term_skip_inline_ws
    LD   A, (HL)
    OR   A
    JP   Z, term_scan_done              ; ran off file
    CP   0x0D
    JP   Z, term_scan_eat_eol
    CP   0x0A
    JP   Z, term_scan_eat_eol

    LD   (term_dial_ptr), HL

    ; Cap at 35 entries (single-keystroke selection range 1-9, A-Z).
    ; Once we reach the cap, silently ignore further entries — no list
    ; output, no count increment.
    LD   A, (term_dir_count)
    CP   35
    JP   NC, term_scan_skip_line
    PUSH HL                             ; preserve buffer pos across handler
    CALL term_handle_entry
    POP  HL

    ; Did we just dial a match? If so, stop scanning early.
    LD   A, (term_dir_mode)
    CP   1
    JP   NZ, term_scan_advance
    LD   A, (term_dir_dialed)
    OR   A
    JP   NZ, term_scan_done

term_scan_advance:
    ; Count this entry and skip to end-of-line.
    LD   A, (term_dir_count)
    INC  A
    LD   (term_dir_count), A
    CALL term_skip_to_eol
    LD   A, (HL)
    OR   A
    JP   Z, term_scan_done
    CALL term_eat_eol_chars
    JP   term_scan_main

term_scan_skip_line:
    CALL term_skip_to_eol
    LD   A, (HL)
    OR   A
    JP   Z, term_scan_done
    CALL term_eat_eol_chars
    JP   term_scan_main

term_scan_eat_eol:
    CALL term_eat_eol_chars
    JP   term_scan_main

term_scan_done:
    RET

; --- Buffer-walk helpers ---

; Advance HL past spaces and tabs.
term_skip_inline_ws:
    LD   A, (HL)
    CP   ' '
    JP   Z, term_skip_inline_ws_inc
    CP   0x09
    RET  NZ
term_skip_inline_ws_inc:
    INC  HL
    JP   term_skip_inline_ws

; Advance HL until non-name byte (whitespace, CR, LF, or null).
term_find_name_end:
    LD   A, (HL)
    OR   A
    RET  Z
    CP   ' '
    RET  Z
    CP   0x09
    RET  Z
    CP   0x0D
    RET  Z
    CP   0x0A
    RET  Z
    INC  HL
    JP   term_find_name_end

; Advance HL until CR, LF, or null.
term_skip_to_eol:
    LD   A, (HL)
    OR   A
    RET  Z
    CP   0x0D
    RET  Z
    CP   0x0A
    RET  Z
    INC  HL
    JP   term_skip_to_eol

; Consume one CR (if present) and one LF (if present).
term_eat_eol_chars:
    LD   A, (HL)
    CP   0x0D
    JP   NZ, term_eat_eol_lf
    INC  HL
term_eat_eol_lf:
    LD   A, (HL)
    CP   0x0A
    RET  NZ
    INC  HL
    RET

; ============================================================
; term_handle_entry
; Invoked once per valid entry by term_scan_buffer.
; Inputs:
;   term_dir_count - this entry's index
;   term_name_ptr  - points to the entry's name in term_block_buf
;   term_dial_ptr  - points to the entry's dial string in
;                    term_block_buf
; ============================================================
term_handle_entry:
    LD   A, (term_dir_mode)
    OR   A
    JP   Z, term_handle_list

    ; Dial mode: only act when index matches the target.
    LD   A, (term_dir_count)
    LD   B, A
    LD   A, (term_dir_target)
    CP   B
    RET  NZ

    ; Match: save the matched name pointer and stream the dial bytes.
    LD   HL, (term_name_ptr)
    LD   (term_dial_match_name), HL
    LD   HL, (term_dial_ptr)
    CALL term_send_dial_string
    LD   A, 1
    LD   (term_dir_dialed), A
    RET

term_handle_list:
    ; Print: <slot> <space> <name padded to 12> <space> <dial> <CRLF>
    LD   A, (term_dir_count)
    CALL term_slot_char
    CALL term_emit_byte
    LD   A, ' '
    CALL term_emit_byte

    ; Print name, count chars, pad to 12 columns.
    LD   HL, (term_name_ptr)
    LD   B, 12
term_handle_list_name:
    LD   A, (HL)
    OR   A
    JP   Z, term_handle_list_pad
    CP   ' '
    JP   Z, term_handle_list_pad
    CP   0x09
    JP   Z, term_handle_list_pad
    CP   0x0D
    JP   Z, term_handle_list_pad
    CP   0x0A
    JP   Z, term_handle_list_pad
    CALL term_emit_byte
    INC  HL
    DEC  B
    JP   NZ, term_handle_list_name
    JP   term_handle_list_dial          ; truncated at 12; no padding

term_handle_list_pad:
    LD   A, B
    OR   A
    JP   Z, term_handle_list_dial
    LD   A, ' '
    CALL term_emit_byte
    DEC  B
    JP   term_handle_list_pad

term_handle_list_dial:
    LD   A, ' '
    CALL term_emit_byte
    LD   HL, (term_dial_ptr)
    CALL term_emit_line
    LD   DE, term_msg_crlf
    JP   term_emit_str

; ============================================================
; term_emit_token
; Write bytes from (HL) to CONO, stopping at whitespace, CR,
; LF, or null. Used to echo a single name token.
; Inputs:
;   HL - pointer to first byte
; ============================================================
term_emit_token:
    LD   A, (HL)
    OR   A
    RET  Z
    CP   ' '
    RET  Z
    CP   0x09
    RET  Z
    CP   0x0D
    RET  Z
    CP   0x0A
    RET  Z
    CALL term_emit_byte
    INC  HL
    JP   term_emit_token

; ============================================================
; term_emit_line
; Write bytes from (HL) to CONO until CR, LF, or null. Used
; to print a dial string in the directory listing (spaces are
; preserved).
; Inputs:
;   HL - pointer to first byte
; ============================================================
term_emit_line:
    LD   A, (HL)
    OR   A
    RET  Z
    CP   0x0D
    RET  Z
    CP   0x0A
    RET  Z
    CALL term_emit_byte
    INC  HL
    JP   term_emit_line

; ============================================================
; term_send_dial_string
; Write the dial bytes from (HL) to the remote, stopping at
; CR, LF, or null. Append a single 0x0D when done.
; Inputs:
;   HL - pointer to first byte of the dial string
; ============================================================
term_send_dial_string:
    LD   A, (HL)
    OR   A
    JP   Z, term_send_dial_done
    CP   0x0D
    JP   Z, term_send_dial_done
    CP   0x0A
    JP   Z, term_send_dial_done
    CALL term_send_remote
    INC  HL
    JP   term_send_dial_string
term_send_dial_done:
    LD   A, 0x0D
    JP   term_send_remote               ; tail-call

; ============================================================
; term_slot_char
; Convert an entry index in 0..34 to its display character:
;   0..8  -> '1'..'9'
;   9..34 -> 'A'..'Z'
; Inputs:
;   A - index
; Outputs:
;   A - slot character
; ============================================================
term_slot_char:
    CP   9
    JP   NC, term_slot_alpha
    ADD  A, '1'
    RET
term_slot_alpha:
    SUB  9
    ADD  A, 'A'
    RET

; ============================================================
; term_dial_prompt
; Emit the dial prompt, read one keystroke from CONI (blocking),
; and convert it to an entry index. Prints "[cancelled]" or
; "[invalid]" feedback when the keystroke is rejected.
; Outputs:
;   A - entry index (0..count-1) on valid choice
;   A - 0xFF on ESC, invalid char, or out-of-range
; ============================================================
term_dial_prompt:
    LD   DE, term_msg_dial_prompt
    CALL term_emit_str

    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    OR   A
    JP   NZ, term_prompt_cancelled  ; read errored — bail out as if cancelled
    LD   A, L

    ; ESC?
    CP   0x1B
    JP   Z, term_prompt_cancelled

    ; Echo the keystroke + CRLF for visual confirmation.
    PUSH AF
    CALL term_emit_byte
    LD   DE, term_msg_crlf
    CALL term_emit_str
    POP  AF

    ; '1'..'9' -> 0..8
    CP   '1'
    JP   C, term_prompt_invalid
    CP   '9' + 1
    JP   NC, term_prompt_try_alpha
    SUB  '1'
    JP   term_prompt_check_count

term_prompt_try_alpha:
    ; Lowercase a..z -> uppercase A..Z
    CP   'a'
    JP   C, term_prompt_alpha_check
    CP   'z' + 1
    JP   NC, term_prompt_alpha_check
    AND  0x5F
term_prompt_alpha_check:
    CP   'A'
    JP   C, term_prompt_invalid
    CP   'Z' + 1
    JP   NC, term_prompt_invalid
    SUB  'A'
    ADD  A, 9                           ; index = 9 + (letter - 'A')

term_prompt_check_count:
    ; A = candidate index; verify it is in 0..count-1.
    LD   B, A
    LD   A, (term_dir_count)
    CP   B
    JP   Z, term_prompt_invalid         ; count == index -> out of range
    JP   C, term_prompt_invalid         ; count <  index -> out of range
    LD   A, B
    RET

term_prompt_cancelled:
    LD   DE, term_msg_cancelled
    CALL term_emit_str
    LD   A, 0xFF
    RET

term_prompt_invalid:
    LD   DE, term_msg_invalid
    CALL term_emit_str
    LD   A, 0xFF
    RET

; ============================================================
; term_esc_hangup
; Ctrl-A H: run the standard Hayes hangup sequence.
;   1. ~2 sec guard delay
;   2. send "+++"
;   3. ~2 sec guard delay
;   4. send "ATH<CR>"
; The delay is strictly blocking; no Ctrl-X polling during it.
; ============================================================
term_esc_hangup:
    LD   DE, term_msg_hangup_start
    CALL term_emit_str

    CALL term_delay_2sec

    LD   A, '+'
    CALL term_send_remote
    LD   A, '+'
    CALL term_send_remote
    LD   A, '+'
    CALL term_send_remote

    CALL term_delay_2sec

    LD   A, 'A'
    CALL term_send_remote
    LD   A, 'T'
    CALL term_send_remote
    LD   A, 'H'
    CALL term_send_remote
    LD   A, 0x0D
    CALL term_send_remote

    LD   DE, term_msg_hung_up
    JP   term_emit_str

; ============================================================
; term_delay_2sec
; Busy-loop for ~2 seconds at 14.7 MHz (Z180-class), or about
; 4 seconds at 7.3728 MHz (stock RC2014). The loop is tuned
; for the fastest expected CPU; slower CPUs run longer, which
; is safe — Hayes only requires a 1-second guard time.
;
; T-state math: inner loop body (DCX H + MOV A,H + ORA L + JNZ)
; is ~25 T per iteration. HL = 0 wraps to 0xFFFF, giving 65536
; iterations and ~1.64M T per outer pass. With outer count 20,
; total ~32.8M T, ~2.2 sec at 14.7 MHz.
; ============================================================
term_delay_2sec:
    PUSH BC
    PUSH HL
    LD   B, 20
term_delay_outer:
    LD   HL, 0
term_delay_inner:
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, term_delay_inner
    DEC  B
    JP   NZ, term_delay_outer
    POP  HL
    POP  BC
    RET

; ============================================================
; term_send_remote
; Send a single byte to the remote device.
; Inputs:
;   A - byte to send
; Preserves: BC, HL.  KERNELADDR returns a value in HL, so the
; caller's HL would be clobbered if we did not save it here;
; several callers iterate a buffer through HL across this call.
; ============================================================
term_send_remote:
    PUSH HL
    PUSH BC
    LD   E, A
    LD   A, (term_remote_id)
    LD   B, A
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    POP  HL
    RET

; ============================================================
; term_emit_byte
; Write a single byte to the console.
; Inputs:
;   A - byte
; Preserves: BC, HL.  See term_send_remote for the rationale.
; ============================================================
term_emit_byte:
    PUSH HL
    PUSH BC
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    POP  HL
    RET

; ============================================================
; term_emit_str
; Write a null-terminated string to the console.
; Inputs:
;   DE - pointer to string
; ============================================================
term_emit_str:
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    RET

; ============================================================
; term_emit_hex
; Write a byte as two uppercase hex digits to the console.
; Inputs:
;   A - byte
; ============================================================
term_emit_hex:
    PUSH AF
    RRCA
    RRCA
    RRCA
    RRCA
    CALL term_emit_hex_nyb
    POP  AF
    CALL term_emit_hex_nyb
    RET

term_emit_hex_nyb:
    AND  0x0F
    ADD  A, '0'
    CP   '9' + 1
    JP   C, term_emit_hex_d
    ADD  A, 'A' - '0' - 10
term_emit_hex_d:
    JP   term_emit_byte         ; tail-call

; ============================================================
; Error / exit paths
; ============================================================
term_err_usage:
    LD   DE, term_msg_usage
    CALL term_emit_str
    JP   term_exit_now

term_err_notfound:
    LD   DE, term_msg_notfound
    CALL term_emit_str
    JP   term_exit_now

term_err_no_chario:
    LD   DE, term_msg_no_chario
    CALL term_emit_str
    JP   term_exit_now

term_exit:
    LD   DE, term_msg_disconnect
    CALL term_emit_str
term_exit_now:
    LD   C, SYS_EXIT
    CALL KERNELADDR
    ; should not return

; ============================================================
; Messages
; ============================================================
term_msg_usage:
    DEFM "term: usage: TERM <device>", 0x0D, 0x0A, 0

term_msg_notfound:
    DEFM "term: device not found", 0x0D, 0x0A, 0

term_msg_no_chario:
    DEFM "term: device has no char I/O", 0x0D, 0x0A, 0

term_msg_connect1:
    DEFM "[term: connected to ", 0
term_msg_connect2:
    DEFM ". Ctrl-X exit, Ctrl-A ? help]", 0x0D, 0x0A, 0

term_msg_disconnect:
    DEFM 0x0D, 0x0A, "[term: disconnected]", 0x0D, 0x0A, 0

term_msg_unknown:
    DEFM "[term: unknown command]", 0

term_msg_help:
    DEFM "[Ctrl-X exit | Ctrl-A E=echo B=hex D=dial H=hangup ^A=literal]", 0

term_msg_echo_on:
    DEFM "[echo on]", 0
term_msg_echo_off:
    DEFM "[echo off]", 0
term_msg_hex_on:
    DEFM "[hex on]", 0
term_msg_hex_off:
    DEFM "[hex off]", 0

term_msg_crlf:
    DEFM 0x0D, 0x0A, 0

term_dir_filename:
    DEFM "TERM.DIR", 0

term_msg_no_dir:
    DEFM 0x0D, 0x0A, "[term: no TERM.DIR in CWD]", 0x0D, 0x0A, 0
term_msg_no_entries:
    DEFM 0x0D, 0x0A, "[term: no entries]", 0x0D, 0x0A, 0
term_msg_dial_header:
    DEFM 0x0D, 0x0A, "[term: dialing directory]", 0x0D, 0x0A, 0
term_msg_dial_prompt:
    DEFM "Dial (1-9,A-Z, ESC=cancel)> ", 0
term_msg_cancelled:
    DEFM "[cancelled]", 0x0D, 0x0A, 0
term_msg_invalid:
    DEFM "[invalid]", 0x0D, 0x0A, 0
term_msg_dial_prefix:
    DEFM "[term: dialing ", 0
term_msg_dial_suffix:
    DEFM "]", 0x0D, 0x0A, 0

term_msg_hangup_start:
    DEFM 0x0D, 0x0A, "[term: hanging up...]", 0x0D, 0x0A, 0
term_msg_hung_up:
    DEFM "[term: hung up]", 0x0D, 0x0A, 0

; ============================================================
; State (initialized at runtime)
; ============================================================
term_argname_ptr:   DEFS 2
term_remote_id:     DEFS 1
term_state:         DEFS 1
term_echo:          DEFS 1
term_hex:           DEFS 1

; --- Dialing-directory state ---
term_dir_handle:        DEFS 1          ; file handle while reading TERM.DIR
term_dir_mode:          DEFS 1          ; 0 = list pass, 1 = dial pass
term_dir_count:         DEFS 1          ; entries scanned so far
term_dir_target:        DEFS 1          ; target index in dial pass
term_dir_dialed:        DEFS 1          ; 1 once dial pass found and sent
term_name_ptr:          DEFS 2          ; current entry's name in block_buf
term_dial_ptr:          DEFS 2          ; current entry's dial in block_buf
term_dial_match_name:   DEFS 2          ; saved name pointer of matched entry
term_block_buf:         DEFS 512        ; one-block read buffer for TERM.DIR

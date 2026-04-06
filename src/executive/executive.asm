; NostOS Executive
; Included by nostos.asm; assembled as part of the single 16KB ROM image.
;
; ============================================================

    ; Prompt buffer for device name
    EXEC_PROMPT_BUF EQU EXEC_RAM_START    ; Buffer for holding device name in executive prompt

; ============================================================
; exec_main
; Main executive loop.  Called by the kernel after init, and
; re-entered after each user program exits via SYS_EXIT.
; ============================================================
exec_main:
    LD   HL, (DYNAMIC_MEMTOP)
    INC  HL
    LD   SP, HL                 ; SP = DYNAMIC_MEMTOP + 1 (stack grows down)

    ; On first entry (EXEC_CMD_TABLE_HEAD = 0 after workspace_init), point
    ; the command table head at the first ROM command descriptor.
    LD   HL, (EXEC_CMD_TABLE_HEAD)
    LD   A, H
    OR   L
    JP   NZ, exec_autoplay_check
    LD   HL, cmdesc_hp
    LD   (EXEC_CMD_TABLE_HEAD), HL

exec_autoplay_check:
    ; On first boot (PLAY_AUTORUN = 0), try to open AUTO.PLY
    LD   A, (PLAY_AUTORUN)
    OR   A
    JP   NZ, exec_main_loop
    LD   A, 1
    LD   (PLAY_AUTORUN), A
    ; Try to open AUTO.PLY — silently ignore if not found
    LD   DE, exec_autoplay_name
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    OR   A
    JP   Z, exec_autoplay_ok
    CP   ERR_NOT_FOUND
    JP   Z, exec_main_loop     ; not found: silently skip
    CALL exec_print_error       ; other error: report it
    JP   exec_main_loop
exec_autoplay_ok:
    ; File exists — set up PLAY state
    LD   A, L
    LD   (PLAY_HANDLE), A
    LD   HL, 0
    LD   (PLAY_BLOCK), HL
    LD   (PLAY_OFFSET), HL

exec_main_loop:
    ; Check if PLAY (batch) mode is active
    LD   A, (PLAY_HANDLE)
    OR   A
    JP   NZ, exec_play_next

    ; Normal interactive path
    CALL exec_print_prompt
    CALL exec_read_line         ; read into INPUT_BUFFER
    CALL exec_parse_and_run
    JP   exec_main_loop

; --- PLAY batch execution ---
exec_play_next:
    CALL play_read_line         ; read next line into INPUT_BUFFER
    OR   A
    JP   NZ, exec_play_done    ; EOF or error

    ; Echo the command with prompt so output looks like interactive use
    CALL exec_print_prompt
    LD   DE, INPUT_BUFFER
    CALL exec_puts
    CALL exec_crlf

    ; Execute the command
    CALL exec_parse_and_run
    JP   exec_main_loop

exec_play_done:
    ; Close the file handle (if not already closed by last-line path)
    LD   A, (PLAY_HANDLE)
    OR   A
    JP   Z, exec_main_loop     ; already closed
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    XOR  A
    LD   (PLAY_HANDLE), A
    JP   exec_main_loop

; ============================================================
; exec_print_prompt
; Emits the current device and directory followed by '>'.
; Example: "C:/>  "
; ============================================================
exec_print_prompt:
    ; Get current device name via DEV_GET_NAME into a temp buffer
    LD   A, (CUR_DEVICE)
    LD   B, A                       ; B = device identifier (top bit set = logical)
    LD   DE, EXEC_PROMPT_BUF       ; DE = 8-byte scratch buffer for name
    LD   C, DEV_GET_NAME
    CALL KERNELADDR
    ; Print the null-terminated name
    LD   DE, EXEC_PROMPT_BUF
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   E, ':'
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    ; Print current directory
    LD   DE, CUR_DIR
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   E, '>'
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    LD   E, ' '
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    RET

; ============================================================
; exec_read_line
; Reads a line of input into INPUT_BUFFER using DEV_CREAD_STR.
; Also echoes CRLF at end of input.
; ============================================================
exec_read_line:
    LD   DE, INPUT_BUFFER
    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_CREAD_STR
    CALL KERNELADDR
    ; Print CRLF
    CALL exec_crlf
    RET

; ============================================================
; exec_parse_and_run
; Parses INPUT_BUFFER for a command and dispatches it.
; Uppercases the command in-place and null-terminates it at
; the first space, then matches against each entry's short-name
; and name in the command descriptor linked list.
; ============================================================
exec_parse_and_run:
    LD   HL, INPUT_BUFFER

    ; Skip leading spaces
exec_parse_skip_spaces:
    LD   A, (HL)
    CP   ' '
    JP   NZ, exec_parse_have_cmd
    INC  HL
    JP   exec_parse_skip_spaces

exec_parse_have_cmd:
    ; Empty line?
    CP   0
    JP   Z, exec_parse_and_run_exit

    ; Save command start in BC (HL points to first non-space char)
    LD   B, H
    LD   C, L

    ; Scan forward: uppercase letters in-place, stop at space or null
exec_parse_scan_cmd:
    LD   A, (HL)
    CP   0
    JP   Z, exec_parse_save_args    ; end of string: args ptr = current pos
    CP   ' '
    JP   Z, exec_parse_found_space
    ; Uppercase: if 'a'-'z' subtract 0x20 and write back
    CP   'a'
    JP   C, exec_parse_not_lower
    CP   'z' + 1
    JP   NC, exec_parse_not_lower
    SUB  0x20
    LD   (HL), A
exec_parse_not_lower:
    INC  HL
    JP   exec_parse_scan_cmd

exec_parse_found_space:
    LD   (HL), 0                    ; null-terminate command at the space
    INC  HL
    ; Skip any additional spaces to find the argument string
exec_parse_skip_arg_spaces:
    LD   A, (HL)
    CP   ' '
    JP   NZ, exec_parse_save_args
    INC  HL
    JP   exec_parse_skip_arg_spaces

exec_parse_save_args:
    LD   (EXEC_ARGS_PTR), HL        ; save pointer to argument string

    ; DE = command start (saved in BC above)
    LD   D, B
    LD   E, C

    ; Check if the command ends with ':' (device change request).
    LD   H, D
    LD   L, E                       ; HL = command start
exec_chk_colon_scan:
    LD   A, (HL)
    OR   A
    JP   Z, exec_chk_colon_done
    INC  HL
    JP   exec_chk_colon_scan
exec_chk_colon_done:
    DEC  HL                         ; HL = last char (scan stopped at null, so one DEC suffices)
    LD   A, (HL)
    CP   ':'
    JP   NZ, exec_dispatch_start
    LD   (HL), 0                    ; strip ':' — DE still points to name
    JP   exec_change_device

exec_dispatch_start:
    ; HL = head of command descriptor linked list
    LD   HL, (EXEC_CMD_TABLE_HEAD)

; Walk the linked list of command descriptors.
; DE = null-terminated command string in INPUT_BUFFER (constant across iterations).
; HL = current entry pointer (0 = end of list).
exec_dispatch_loop:
    LD   A, H
    OR   L
    JP   Z, exec_not_builtin        ; null ptr = end of list

    ; Try short-name (at HL + CMDESC_OFF_SHORTNAME = HL + 0)
    CALL exec_cmd_match_str         ; Z set if (HL)==(DE); HL and DE preserved
    JP   Z, exec_dispatch_found

    ; Try name (at HL + CMDESC_OFF_NAME = HL + 3)
    PUSH HL
    LD   BC, CMDESC_OFF_NAME
    ADD  HL, BC
    CALL exec_cmd_match_str
    POP  HL
    JP   Z, exec_dispatch_found

    ; Follow next pointer (at HL + CMDESC_OFF_NEXT = HL + 14)
    LD   BC, CMDESC_OFF_NEXT
    ADD  HL, BC
    LD   C, (HL)
    INC  HL
    LD   B, (HL)
    LD   H, B
    LD   L, C
    JP   exec_dispatch_loop

exec_dispatch_found:
    ; HL = matched entry base; fn ptr at CMDESC_OFF_FN (= 10)
    LD   BC, CMDESC_OFF_FN
    ADD  HL, BC
    LD   C, (HL)
    INC  HL
    LD   B, (HL)
    LD   H, B
    LD   L, C
    JP   (HL)                       ; tail-call handler; handler RET -> exec_main_loop

exec_not_builtin:
    ; DE = null-terminated program name in INPUT_BUFFER
    CALL exec_run_program
exec_parse_and_run_exit:
    RET

; ============================================================
; exec_change_device
; Handles "DEVNAME:" input: looks up DEVNAME as a logical device
; and sets CUR_DEVICE to its index.
; Inputs:
;   DE - null-terminated device name (uppercased, no ':')
; Outputs:
;   (none)
; ============================================================
exec_change_device:
    LD   A, (DE)
    OR   A
    JP   Z, exec_change_dev_notfound ; empty name
    LD   B, 0
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, exec_change_dev_notfound
    LD   A, L                       ; L = device identifier (0x80|index or physical ID)
    LD   (CUR_DEVICE), A
    RET
exec_change_dev_notfound:
    LD   DE, msg_exec_bad_device
    CALL exec_puts
    RET

; ============================================================
; exec_cmd_match_str
; Compare null-terminated string at HL with null-terminated
; string at DE (case-sensitive).  Sets Z if equal.
; Preserves all registers.
; ============================================================
exec_cmd_match_str:
    PUSH HL
    PUSH DE
    PUSH BC
exec_cmd_match_str_loop:
    LD   A, (DE)
    LD   B, A                       ; B = char from input command
    LD   A, (HL)                    ; A = char from table entry
    CP   B
    JP   NZ, exec_cmd_match_str_no
    CP   0                          ; both chars equal; zero means both strings ended
    JP   Z, exec_cmd_match_str_yes
    INC  HL
    INC  DE
    JP   exec_cmd_match_str_loop
exec_cmd_match_str_yes:
    POP  BC
    POP  DE
    POP  HL
    ; Z is set (from CP 0 with A=0); PUSH/POP do not change flags
    RET
exec_cmd_match_str_no:
    POP  BC
    POP  DE
    POP  HL
    ; Z is clear (from JP NZ branch); PUSH/POP do not change flags
    RET

; ============================================================
; Built-in Command Descriptors (linked list in ROM)
; Each entry is exactly 16 bytes:
;   3 bytes: short-name (null-terminated, max 2 chars)
;   7 bytes: name       (null-terminated, max 6 chars, zero-padded)
;   2 bytes: function pointer
;   2 bytes: description pointer
;   2 bytes: next entry pointer (0 = end of list)
; EXEC_CMD_TABLE_HEAD in workspace RAM is initialised to cmdesc_hp by
; exec_main.  User programs may prepend entries by updating that pointer.
; ============================================================

cmdesc_hp:                              ; HP / HELP
    DEFM "HP", 0                        ; short-name  (3 bytes)
    DEFM "HELP", 0, 0, 0               ; name        (7 bytes)
    DEFW cmd_help                       ; fn ptr
    DEFW desc_hp                        ; desc ptr
    DEFW cmdesc_in                      ; next

cmdesc_in:                              ; IN / INFO
    DEFM "IN", 0
    DEFM "INFO", 0, 0, 0
    DEFW cmd_info
    DEFW desc_in
    DEFW cmdesc_ht

cmdesc_ht:                              ; HT / HALT
    DEFM "HT", 0
    DEFM "HALT", 0, 0, 0
    DEFW cmd_halt
    DEFW desc_ht
    DEFW cmdesc_ll

cmdesc_ll:                              ; LL / LISTL
    DEFM "LL", 0
    DEFM "LISTL", 0, 0                 ; 5 chars + null + 1 pad = 7
    DEFW cmd_ll
    DEFW desc_ll
    DEFW cmdesc_lp

cmdesc_lp:                              ; LP / LISTP
    DEFM "LP", 0
    DEFM "LISTP", 0, 0
    DEFW cmd_lp
    DEFW desc_lp
    DEFW cmdesc_as

cmdesc_as:                              ; AS / ASSIGN
    DEFM "AS", 0
    DEFM "ASSIGN", 0                   ; 6 chars + null = 7
    DEFW cmd_as
    DEFW desc_as
    DEFW cmdesc_cd

cmdesc_cd:                              ; CD / CHDIR
    DEFM "CD", 0
    DEFM "CHDIR", 0, 0
    DEFW cmd_cd
    DEFW desc_cd
    DEFW cmdesc_ld

cmdesc_ld:                              ; LD / DIR
    DEFM "LD", 0
    DEFM "DIR", 0, 0, 0, 0            ; 3 chars + null + 3 pad = 7
    DEFW cmd_ld
    DEFW desc_ld
    DEFW cmdesc_md

cmdesc_md:                              ; MD / MKDIR
    DEFM "MD", 0
    DEFM "MKDIR", 0, 0
    DEFW cmd_md
    DEFW desc_md
    DEFW cmdesc_rd

cmdesc_rd:                              ; RD / RMDIR
    DEFM "RD", 0
    DEFM "RMDIR", 0, 0
    DEFW cmd_rd
    DEFW desc_rd
    DEFW cmdesc_cf

cmdesc_cf:                              ; CF / COPY
    DEFM "CF", 0
    DEFM "COPY", 0, 0, 0
    DEFW cmd_cf
    DEFW desc_cf
    DEFW cmdesc_rf

cmdesc_rf:                              ; RF / DELETE
    DEFM "RF", 0
    DEFM "DELETE", 0                   ; 6 chars + null = 7
    DEFW cmd_rf
    DEFW desc_rf
    DEFW cmdesc_nf

cmdesc_nf:                              ; NF / RENAME
    DEFM "NF", 0
    DEFM "RENAME", 0                   ; 6 chars + null = 7
    DEFW cmd_nf
    DEFW desc_nf
    DEFW cmdesc_lf

cmdesc_lf:                              ; LF / TYPE
    DEFM "LF", 0
    DEFM "TYPE", 0, 0, 0
    DEFW cmd_lf
    DEFW desc_lf
    DEFW cmdesc_hf

cmdesc_hf:                              ; HF / HEXDUMP
    DEFM "HF", 0
    DEFM "HEXDMP", 0                   ; 6 chars + null = 7
    DEFW cmd_hf
    DEFW desc_hf
    DEFW cmdesc_mt

cmdesc_mt:                              ; MT / MOUNT
    DEFM "MT", 0
    DEFM "MOUNT", 0, 0                 ; 5 chars + null + 1 pad = 7
    DEFW cmd_mt
    DEFW desc_mt
    DEFW cmdesc_st

cmdesc_st:                              ; ST / STAT
    DEFM "ST", 0
    DEFM "STAT", 0, 0, 0
    DEFW cmd_st
    DEFW desc_st
    DEFW cmdesc_rm

cmdesc_rm:                              ; # / REMARK
    DEFM "#", 0, 0                      ; short-name (3 bytes)
    DEFM "REMARK", 0                    ; name (7 bytes)
    DEFW cmd_rm
    DEFW desc_rm
    DEFW cmdesc_sm                      ; next

cmdesc_sm:                              ; SM / SUM
    DEFM "SM", 0
    DEFM "SUM", 0, 0, 0, 0             ; 3 chars + null + 3 pad = 7
    DEFW cmd_sum
    DEFW desc_sm
    DEFW cmdesc_fr                      ; next

cmdesc_fr:                              ; FR / FREE
    DEFM "FR", 0
    DEFM "FREE", 0, 0, 0               ; 4 chars + null + 2 pad = 7
    DEFW cmd_free
    DEFW desc_fr
    DEFW cmdesc_pl                      ; next

cmdesc_pl:                              ; PL / PLAY
    DEFM "PL", 0
    DEFM "PLAY", 0, 0, 0               ; 4 chars + null + 2 pad = 7
    DEFW cmd_play
    DEFW desc_pl
    DEFW 0                              ; end of ROM list

; ============================================================
; Built-in Command Handlers
; On entry: exec_args_ptr points to argument string (may be empty).
; Return via RET to exec_parse_and_run -> exec_main_loop.
; ============================================================

    INCLUDE "src/executive/common.asm"
    INCLUDE "src/executive/cmd_as.asm"
    INCLUDE "src/executive/cmd_ld.asm"
    INCLUDE "src/executive/cmd_help.asm"
    INCLUDE "src/executive/cmd_info.asm"
    INCLUDE "src/executive/cmd_ll.asm"
    INCLUDE "src/executive/cmd_lp.asm"
    INCLUDE "src/executive/cmd_cd.asm"
    INCLUDE "src/executive/cmd_mt.asm"
    INCLUDE "src/executive/cmd_lf.asm"
    INCLUDE "src/executive/cmd_hf.asm"
    INCLUDE "src/executive/cmd_st.asm"
    INCLUDE "src/executive/cmd_md.asm"
    INCLUDE "src/executive/cmd_rd.asm"
    INCLUDE "src/executive/cmd_cf.asm"
    INCLUDE "src/executive/cmd_rf.asm"
    INCLUDE "src/executive/cmd_nf.asm"
    INCLUDE "src/executive/cmd_free.asm"
    INCLUDE "src/executive/cmd_sum.asm"
    INCLUDE "src/executive/cmd_play.asm"

; # / REMARK: do nothing (comment line)
cmd_rm:
    RET

; HALT: execute HALT instruction
cmd_halt:
    HALT
    RET

; ============================================================
; exec_run_program
; Attempts to load and execute the command as a program file.
; If the name has no '.', ".APP" is appended automatically so
; the user can type "helloworld" instead of "helloworld.app".
; Opens the file, then calls SYS_EXEC (B=handle, DE=load_addr).
; ============================================================
exec_run_program:
    ; DE = null-terminated program name (uppercased, in INPUT_BUFFER).
    ; Scan for '.' to decide whether to append ".APP".
    LD   H, D
    LD   L, E                       ; HL = scan pointer
exec_run_dot_scan:
    LD   A, (HL)
    OR   A
    JP   Z, exec_run_no_dot         ; end of string — no dot found
    CP   '.'
    JP   Z, exec_run_do_open        ; dot found — use name as-is
    INC  HL
    JP   exec_run_dot_scan

exec_run_no_dot:
    ; No extension: copy name from DE into EXEC_RAM_START and append ".APP"
    LD   HL, EXEC_RAM_START
exec_run_copy_loop:
    LD   A, (DE)
    LD   (HL), A
    OR   A
    JP   Z, exec_run_appended       ; null copied — now overwrite with ".APP\0"
    INC  DE
    INC  HL
    JP   exec_run_copy_loop
exec_run_appended:
    LD   (HL), '.'
    INC  HL
    LD   (HL), 'A'
    INC  HL
    LD   (HL), 'P'
    INC  HL
    LD   (HL), 'P'
    INC  HL
    LD   (HL), 0
    LD   DE, EXEC_RAM_START           ; DE = modified name with ".APP"

exec_run_do_open:
    ; DE = pathname to open.  Use SYS_GLOBAL_OPENFILE for path resolution.
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    OR   A
    JP   Z, exec_run_do_exec
    CP   ERR_NOT_FOUND
    JP   Z, exec_run_not_found
    CALL exec_print_error
    RET

exec_run_do_exec:
    ; L = file handle from open
    LD   B, L                       ; B = file handle
    LD   DE, (DYNAMIC_MEMBOT)
    LD   C, SYS_EXEC
    CALL KERNELADDR
    ; Reached only on failure; A = error code.
    CALL exec_print_error
    RET
exec_run_not_found:
    LD   DE, msg_unknown_cmd
    CALL exec_puts
    RET

; ============================================================
; Executive Utilities
; ============================================================

; exec_puts: write null-terminated string at DE to CONO
exec_puts:
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    RET

; exec_crlf: emit CR+LF to CONO
exec_crlf:
    LD   DE, msg_crlf
    CALL exec_puts
    RET


    INCLUDE "src/executive/format.asm"

; ============================================================
; Executive Data
; ============================================================

; Messages
msg_crlf:
    DEFM 0x0D, 0x0A, 0

exec_autoplay_name:
    DEFM "AUTO.PLY", 0
msg_exec_bad_device:
    DEFM "Unknown device.", 0x0D, 0x0A, 0
msg_unknown_cmd:
    DEFM "Unknown command. Type HP or HELP for command list.", 0x0D, 0x0A, 0

; Command description strings (used by cmdesc entries; available for table-driven help)
desc_hp:    DEFM "Display help text", 0
desc_in:    DEFM "Display system information", 0
desc_ht:    DEFM "Execute HALT instruction", 0
desc_ll:    DEFM "List logical devices", 0
desc_lp:    DEFM "List physical devices", 0
desc_as:    DEFM "Assign logical device to physical device", 0
desc_cd:    DEFM "Change directory", 0
desc_ld:    DEFM "List directory", 0
desc_md:    DEFM "Make directory", 0
desc_rd:    DEFM "Remove directory", 0
desc_cf:    DEFM "Copy file", 0
desc_rf:    DEFM "Delete file", 0
desc_nf:    DEFM "Rename file", 0
desc_lf:    DEFM "Display file contents", 0
desc_hf:    DEFM "Display file as hex dump", 0
desc_mt:    DEFM "Mount filesystem device on block device", 0
desc_st:    DEFM "Display file status and block map", 0
desc_rm:    DEFM "Remark (comment line, ignored)", 0
desc_sm:    DEFM "SYSV checksum", 0
desc_fr:    DEFM "Display free block count", 0
desc_pl:    DEFM "Execute commands from a script file", 0

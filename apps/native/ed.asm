; ============================================================
; ed.asm - Line editor for NostOS
; An ed-style line editor for creating and modifying text files.
;
; Commands:
;   [n]p          Print line n (default: current)
;   [n1,n2]p      Print lines n1 through n2
;   [n]d          Delete line n (default: current)
;   [n1,n2]d      Delete lines n1 through n2
;   [n]i          Insert before line n (default: current)
;   [n]a          Append after line n (default: current)
;   [n]c          Change line n (replace = delete + insert)
;   w [filename]  Write to file
;   q             Quit (warn if unsaved changes)
;   Q             Quit without saving
;   .             Print current line number
;   $             Print last line number
;   [n]           Set current line to n
;
; Assembled as a flat binary, origin 0x0800.
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header
    JP   ed_main

    ; Header pad: 13 bytes of zeros (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================

ED_CR       EQU 0x0D
ED_LF       EQU 0x0A
ED_BS       EQU 0x08
ED_TAB      EQU 0x09
ED_CTRLC    EQU 0x03
ED_DEL      EQU 0x7F

ED_LINEBUF_SIZE EQU 256    ; max input line length
ED_FNAME_SIZE   EQU 17     ; 16 chars + null

; ============================================================
; ed_main - Entry point (at 0x0810)
; ============================================================
ed_main:
    ; Initialize variables
    LD   HL, 0
    LD   (ed_buf_used), HL
    LD   (ed_cur_line), HL
    LD   (ed_line_count), HL
    LD   A, 0
    LD   (ed_dirty), A
    LD   (ed_fname), A

    ; Get top of memory for buffer limit
    LD   C, SYS_MEMTOP
    CALL KERNELADDR
    LD   (ed_buf_end), HL

    ; Check for command line filename argument
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, H
    OR   L
    JP   Z, ed_cmd_loop     ; No args pointer

    ; Check if args string is empty
    LD   A, (HL)
    OR   A
    JP   Z, ed_cmd_loop     ; Empty args

    ; Copy filename from args
    LD   DE, ed_fname
    LD   B, ED_FNAME_SIZE - 1
ed_copy_fname:
    LD   A, (HL)
    OR   A
    JP   Z, ed_copy_fname_done
    CP   ' '
    JP   Z, ed_copy_fname_done
    ; Uppercase it
    CP   'a'
    JP   C, ed_copy_fname_nc
    CP   'z' + 1
    JP   NC, ed_copy_fname_nc
    AND  0x5F               ; to uppercase
ed_copy_fname_nc:
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, ed_copy_fname
ed_copy_fname_done:
    XOR  A
    LD   (DE), A            ; null terminate

    ; Try to load the file
    CALL ed_read_file
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_loop - Main command loop
; Read a command line, parse, and dispatch.
; ============================================================
ed_cmd_loop:
    ; Print prompt
    LD   A, '*'
    CALL ed_putchar

    ; Read command line
    LD   HL, ed_cmdbuf
    LD   B, ED_LINEBUF_SIZE - 1
    CALL ed_getline
    OR   A
    JP   Z, ed_cmd_loop     ; empty line, reprompt

    ; Parse address(es) from ed_cmdbuf
    LD   HL, ed_cmdbuf
    CALL ed_parse_addrs      ; sets ed_addr1, ed_addr2, ed_addr_count
    ; HL now points to the command character (or end)

    LD   A, (HL)
    OR   A
    JP   Z, ed_cmd_set_line  ; bare number = set current line

    ; Dispatch on command character
    CP   'p'
    JP   Z, ed_cmd_print
    CP   'P'
    JP   Z, ed_cmd_print
    CP   'd'
    JP   Z, ed_cmd_delete
    CP   'D'
    JP   Z, ed_cmd_delete
    CP   'i'
    JP   Z, ed_cmd_insert
    CP   'I'
    JP   Z, ed_cmd_insert
    CP   'a'
    JP   Z, ed_cmd_append
    CP   'A'
    JP   Z, ed_cmd_append
    CP   'c'
    JP   Z, ed_cmd_change
    CP   'C'
    JP   Z, ed_cmd_change
    CP   'w'
    JP   Z, ed_cmd_write
    CP   'W'
    JP   Z, ed_cmd_write
    CP   'q'
    JP   Z, ed_cmd_quit
    CP   'Q'
    JP   Z, ed_cmd_quit_force
    CP   '.'
    JP   Z, ed_cmd_dot
    CP   '$'
    JP   Z, ed_cmd_dollar
    CP   'n'
    JP   Z, ed_cmd_print_num
    CP   'N'
    JP   Z, ed_cmd_print_num
    CP   'h'
    JP   Z, ed_cmd_help
    CP   'H'
    JP   Z, ed_cmd_help

    ; Unknown command
    LD   DE, ed_msg_huh
    CALL ed_print_str
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_set_line - Set current line (bare number entered)
; ============================================================
ed_cmd_set_line:
    LD   A, (ed_addr_count)
    OR   A
    JP   Z, ed_cmd_loop     ; no address, ignore

    LD   HL, (ed_addr1)
    CALL ed_validate_line
    JP   C, ed_err_range
    LD   (ed_cur_line), HL
    ; Print the line
    LD   (ed_addr2), HL
    LD   A, 1
    LD   (ed_addr_count), A
    JP   ed_do_print

; ============================================================
; ed_cmd_print - Print line(s)
; ============================================================
ed_cmd_print:
    CALL ed_default_cur_line
ed_do_print:
    CALL ed_resolve_range    ; DE=addr1, HL=addr2
    JP   C, ed_err_range

    ; DE = start line, HL = end line
    PUSH HL                  ; save end
    EX   DE, HL              ; HL = start line
ed_print_loop:
    POP  DE                  ; DE = end line
    PUSH DE
    ; Check if HL > DE
    PUSH HL
    LD   A, E
    SUB  L
    LD   A, D
    SBC  A, H
    POP  HL
    JP   C, ed_print_done    ; past end

    PUSH HL                  ; save current line#
    CALL ed_find_line        ; HL=ptr to line start, DE=ptr to line end (LF)
    JP   C, ed_print_done2   ; line not found
    ; Print from HL to DE (exclusive of LF)
    CALL ed_print_line_content
    POP  HL                  ; restore line#
    INC  HL                  ; next line
    JP   ed_print_loop

ed_print_done2:
    POP  HL                  ; discard saved line#
ed_print_done:
    POP  DE                  ; discard saved end
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_print_num - Print line(s) with line numbers (n command)
; ============================================================
ed_cmd_print_num:
    CALL ed_default_cur_line
    CALL ed_resolve_range
    JP   C, ed_err_range

    PUSH HL                  ; save end
    EX   DE, HL              ; HL = start line
ed_pn_loop:
    POP  DE
    PUSH DE
    PUSH HL
    LD   A, E
    SUB  L
    LD   A, D
    SBC  A, H
    POP  HL
    JP   C, ed_pn_done

    PUSH HL
    ; Print line number
    PUSH HL
    CALL ed_print_decimal
    LD   A, ED_TAB
    CALL ed_putchar
    POP  HL

    CALL ed_find_line
    JP   C, ed_pn_done2
    CALL ed_print_line_content
    POP  HL
    INC  HL
    JP   ed_pn_loop

ed_pn_done2:
    POP  HL
ed_pn_done:
    POP  DE
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_delete - Delete line(s)
; ============================================================
ed_cmd_delete:
    CALL ed_default_cur_line
    CALL ed_resolve_range
    JP   C, ed_err_range

    ; DE=start line, HL=end line
    PUSH HL                  ; save end line
    PUSH DE                  ; save start line

    ; Find start of first line to delete
    EX   DE, HL              ; HL = start line#
    CALL ed_find_line        ; HL=start ptr, DE=end ptr (LF)
    JP   C, ed_err_range_pop2
    PUSH HL                  ; save start ptr

    ; Find end of last line to delete (after LF)
    POP  HL                  ; start ptr
    PUSH HL
    POP  BC                  ; BC = start ptr (save it)
    ; Get end line number
    POP  DE                  ; start line#
    POP  HL                  ; end line#
    PUSH DE                  ; re-save start line# for cur_line update
    PUSH BC                  ; re-save start ptr
    CALL ed_find_line        ; HL=line start, DE=past LF
    JP   C, ed_err_range_pop2
    ; DE points to char after LF of last line
    INC  DE                  ; point past the LF

    ; Now shift buffer: remove from start_ptr to DE
    POP  HL                  ; HL = start ptr (where deleted region begins)
    PUSH HL
    ; Bytes to remove = DE - HL
    PUSH DE
    LD   A, E
    SUB  L
    LD   C, A
    LD   A, D
    SBC  A, H
    LD   B, A               ; BC = bytes to remove
    POP  DE                  ; DE = source (after deleted region)

    ; Destination = start ptr (HL)
    POP  HL                  ; HL = destination (start ptr)
    PUSH BC                  ; save bytes removed

    ; Calculate bytes to move = buf_end_ptr - source
    PUSH HL                  ; save dest
    LD   HL, (ed_buf_used)
    LD   DE, ed_textbuf
    ADD  HL, DE              ; HL = buf_start + buf_used = end of data
    POP  DE                  ; DE = dest (start ptr)
    PUSH DE

    ; source = dest + bytes_removed
    POP  HL                  ; HL = dest
    POP  BC                  ; BC = bytes removed
    PUSH BC
    PUSH HL
    ADD  HL, BC              ; HL = source (dest + bytes_removed)
    EX   DE, HL              ; DE = source
    POP  HL                  ; HL = dest

    ; Total data end
    PUSH HL
    PUSH DE
    LD   HL, (ed_buf_used)
    PUSH HL
    POP  BC                  ; BC = buf_used
    LD   HL, ed_textbuf
    ADD  HL, BC              ; HL = absolute end of data
    ; bytes to copy = end_of_data - source
    LD   A, L
    SUB  E
    LD   C, A
    LD   A, H
    SBC  A, D
    LD   B, A               ; BC = bytes to copy
    POP  DE                  ; DE = source
    POP  HL                  ; HL = dest

    LD   A, B
    OR   C
    JP   Z, ed_del_no_copy
    ; Copy bytes (DE=source, HL=dest, BC=count)
    EX   DE, HL              ; DE=dest, HL=source
ed_del_copy:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, ed_del_copy
ed_del_no_copy:

    ; Update buf_used
    POP  BC                  ; BC = bytes removed
    LD   HL, (ed_buf_used)
    LD   A, L
    SUB  C
    LD   L, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (ed_buf_used), HL

    ; Update line count
    POP  HL                  ; HL = start line#
    PUSH HL
    ; Count deleted lines = end_line - start_line + 1
    ; We need the end line# but we already consumed it
    ; Recalculate from addr1/addr2
    LD   HL, (ed_addr2)
    LD   DE, (ed_addr1)
    LD   A, L
    SUB  E
    LD   C, A
    LD   A, H
    SBC  A, D
    LD   B, A
    INC  BC                  ; BC = lines deleted

    LD   HL, (ed_line_count)
    LD   A, L
    SUB  C
    LD   L, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (ed_line_count), HL

    ; Update current line
    POP  HL                  ; start line# (discard, we use addr1)
    LD   HL, (ed_addr1)
    LD   DE, (ed_line_count)
    ; If addr1 > line_count, set cur_line = line_count
    LD   A, E
    SUB  L
    LD   A, D
    SBC  A, H
    JP   NC, ed_del_cur_ok
    LD   HL, DE              ; actually: HL = line_count
    EX   DE, HL
    LD   HL, DE
ed_del_cur_ok:
    LD   (ed_cur_line), HL

    ; Mark dirty
    LD   A, 1
    LD   (ed_dirty), A

    JP   ed_cmd_loop

ed_err_range_pop2:
    POP  HL
    POP  HL
ed_err_range:
    LD   DE, ed_msg_range
    CALL ed_print_str
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_insert - Insert before line n
; ============================================================
ed_cmd_insert:
    CALL ed_default_cur_line_ins
    LD   HL, (ed_addr1)
    ; Validate: allow insert at line_count+1 (append at end)
    PUSH HL
    LD   DE, (ed_line_count)
    INC  DE                  ; allow one past end
    LD   A, L
    OR   H
    JP   Z, ed_ins_range_err ; line 0 not allowed
    ; Check HL <= DE+1 (line_count+1)
    LD   A, E
    SUB  L
    LD   A, D
    SBC  A, H
    POP  HL
    JP   C, ed_ins_range_err_nr

    ; HL = line number to insert before
    JP   ed_insert_mode

ed_ins_range_err:
    POP  HL
ed_ins_range_err_nr:
    JP   ed_err_range

; ============================================================
; ed_cmd_append - Append after line n
; ============================================================
ed_cmd_append:
    CALL ed_default_cur_line_app
    LD   HL, (ed_addr1)
    ; Append after line N = insert before line N+1
    INC  HL
    LD   (ed_addr1), HL
    JP   ed_insert_mode

; ============================================================
; ed_cmd_change - Change line(s): delete then insert
; ============================================================
ed_cmd_change:
    CALL ed_default_cur_line
    CALL ed_resolve_range
    JP   C, ed_err_range

    ; Save insert position before delete
    PUSH DE                  ; start line

    ; Do the delete (inline, reusing delete logic)
    ; We need to re-parse since we consumed the range
    POP  HL
    LD   (ed_addr1), HL
    PUSH HL
    ; Delete the range first, then insert at the same position
    POP  HL
    PUSH HL
    CALL ed_do_delete_range  ; delete addr1..addr2

    ; Now insert at addr1
    POP  HL
    LD   (ed_addr1), HL
    JP   ed_insert_mode

; ============================================================
; ed_do_delete_range - Delete lines addr1..addr2
; Updates buf_used, line_count. Does not update cur_line.
; ============================================================
ed_do_delete_range:
    ; Find start of first line
    LD   HL, (ed_addr1)
    CALL ed_find_line
    RET  C                   ; error
    PUSH HL                  ; save start ptr
    PUSH DE                  ; save end-of-first-line ptr (unused directly)

    ; Find end of last line
    LD   HL, (ed_addr2)
    CALL ed_find_line
    ; DE = ptr past LF of last line
    POP  BC                  ; discard
    POP  BC                  ; BC = start ptr
    RET  C

    INC  DE                  ; point past LF

    ; Shift buffer down
    ; src = DE (after deleted region)
    ; dst = BC (start of deleted region)
    ; end of data = ed_textbuf + ed_buf_used
    PUSH BC                  ; save dst
    PUSH DE                  ; save src

    LD   HL, (ed_buf_used)
    LD   DE, ed_textbuf
    ADD  HL, DE              ; HL = end of data

    POP  DE                  ; DE = src
    PUSH DE

    ; bytes_to_copy = end_of_data - src
    LD   A, L
    SUB  E
    LD   C, A
    LD   A, H
    SBC  A, D
    LD   B, A               ; BC = bytes to copy

    POP  HL                  ; HL = src
    POP  DE                  ; DE = dst

    ; HL=src, DE=dst, BC=bytes_to_copy
    ; Save src and dst so we can compute bytes_removed after the copy
    PUSH HL                  ; save src
    PUSH DE                  ; save dst

    ; Copy bytes_to_copy bytes from src (HL) to dst (DE)
    LD   A, B
    OR   C
    JP   Z, ed_ddr_no_copy
ed_ddr_copy:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, ed_ddr_copy
ed_ddr_no_copy:

    ; Compute bytes_removed = src - dst from saved values
    POP  DE                  ; dst (original start of deleted region)
    POP  HL                  ; src (original end of deleted region + 1)
    LD   A, L
    SUB  E
    LD   C, A
    LD   A, H
    SBC  A, D
    LD   B, A               ; BC = bytes_removed

    ; Update buf_used -= bytes_removed
    LD   HL, (ed_buf_used)
    LD   A, L
    SUB  C
    LD   L, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (ed_buf_used), HL

    ; Update line_count
    LD   HL, (ed_addr2)
    LD   DE, (ed_addr1)
    LD   A, L
    SUB  E
    LD   C, A
    LD   A, H
    SBC  A, D
    LD   B, A
    INC  BC                  ; BC = lines deleted

    LD   HL, (ed_line_count)
    LD   A, L
    SUB  C
    LD   L, A
    LD   A, H
    SBC  A, B
    LD   H, A
    LD   (ed_line_count), HL

    LD   A, 1
    LD   (ed_dirty), A
    RET

; ============================================================
; ed_insert_mode - Read lines from console, insert into buffer
; Insert before the line in ed_addr1.
; Lines terminated by a line containing only "."
; ============================================================
ed_insert_mode:
    LD   HL, (ed_addr1)

    ; Find insertion point in buffer
    ; If inserting at line_count+1, insertion point = end of buffer
    LD   DE, (ed_line_count)
    INC  DE
    LD   A, L
    SUB  E
    LD   A, H
    SBC  A, D
    JP   NC, ed_ins_at_end   ; addr1 >= line_count+1, append

    ; addr1 == 0 and line_count == 0 also goes to end
    LD   A, H
    OR   L
    JP   Z, ed_ins_at_end

    ; Find start of line addr1
    PUSH HL
    CALL ed_find_line        ; HL = ptr to start of line
    POP  DE                  ; discard line# (we don't need it again)
    JP   C, ed_ins_at_end    ; line not found — insert at end
    ; HL = insertion point
    JP   ed_ins_read_lines

ed_ins_at_end:
    LD   HL, (ed_buf_used)
    LD   DE, ed_textbuf
    ADD  HL, DE              ; HL = end of buffer data

ed_ins_read_lines:
    LD   (ed_ins_point), HL  ; save insertion point

ed_ins_next_line:
    ; Read a line from console
    LD   HL, ed_linebuf
    LD   B, ED_LINEBUF_SIZE - 2  ; leave room for LF + null
    CALL ed_getline

    ; Skip empty lines (CR+LF artifacts from emulator)
    OR   A
    JP   Z, ed_ins_next_line

    ; Check for "." alone (end of insert mode)
    LD   HL, ed_linebuf
    LD   A, (HL)
    CP   '.'
    JP   NZ, ed_ins_not_dot
    INC  HL
    LD   A, (HL)
    OR   A
    JP   Z, ed_ins_done      ; single "." = end insert mode
ed_ins_not_dot:

    ; Calculate line length (add LF)
    LD   HL, ed_linebuf
    LD   BC, 0
ed_ins_len:
    LD   A, (HL)
    OR   A
    JP   Z, ed_ins_len_done
    INC  HL
    INC  BC
    JP   ed_ins_len
ed_ins_len_done:
    INC  BC                  ; +1 for LF we'll append

    ; Check if buffer has room
    PUSH BC                  ; save line length (with LF)
    LD   HL, (ed_buf_used)
    ADD  HL, BC              ; new total size
    LD   DE, ed_textbuf
    ADD  HL, DE              ; absolute end after insert
    LD   DE, (ed_buf_end)
    ; Check if HL > DE (overflow)
    LD   A, E
    SUB  L
    LD   A, D
    SBC  A, H
    POP  BC
    JP   C, ed_ins_full      ; buffer full

    ; Shift existing data up by BC bytes from insertion point
    PUSH BC                  ; save line length

    ; Calculate bytes to shift = end_of_data - ins_point
    LD   HL, (ed_buf_used)
    LD   DE, ed_textbuf
    ADD  HL, DE              ; HL = end of data
    LD   DE, (ed_ins_point)
    ; bytes_to_shift = HL - DE
    PUSH HL                  ; save end_of_data
    LD   A, L
    SUB  E
    LD   C, A
    LD   A, H
    SBC  A, D
    LD   B, A               ; BC = bytes to shift

    POP  HL                  ; HL = end of data (last byte + 1)

    LD   A, B
    OR   C
    JP   Z, ed_ins_no_shift

    ; Copy backwards: src = end-1, dst = end-1+line_len
    ; We need line_len from stack
    POP  DE                  ; DE = line length
    PUSH DE

    ; src_end = end_of_data - 1
    DEC  HL                  ; HL = last byte of data

    ; dst_end = HL + line_length
    PUSH HL                  ; save src_end
    ADD  HL, DE              ; HL = dst_end
    EX   DE, HL              ; DE = dst_end
    POP  HL                  ; HL = src_end

    ; Copy BC bytes backwards (8080-compatible LDDR)
ed_ins_lddr:
    LD   A, (HL)
    LD   (DE), A
    DEC  HL
    DEC  DE
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, ed_ins_lddr

ed_ins_no_shift:
    POP  BC                  ; BC = line length (with LF)

    ; Copy line text into buffer at ins_point
    LD   DE, (ed_ins_point)
    LD   HL, ed_linebuf
ed_ins_copy:
    LD   A, (HL)
    OR   A
    JP   Z, ed_ins_copy_lf
    LD   (DE), A
    INC  HL
    INC  DE
    JP   ed_ins_copy
ed_ins_copy_lf:
    LD   A, ED_LF
    LD   (DE), A
    INC  DE

    ; Update ins_point for next line
    LD   (ed_ins_point), DE

    ; Update buf_used += line_length
    LD   HL, (ed_buf_used)
    ADD  HL, BC
    LD   (ed_buf_used), HL

    ; Update line_count++
    LD   HL, (ed_line_count)
    INC  HL
    LD   (ed_line_count), HL

    ; Update cur_line to the inserted line
    LD   HL, (ed_addr1)
    LD   (ed_cur_line), HL
    ; Increment addr1 for next insert
    INC  HL
    LD   (ed_addr1), HL

    ; Mark dirty
    LD   A, 1
    LD   (ed_dirty), A

    JP   ed_ins_next_line

ed_ins_full:
    LD   DE, ed_msg_full
    CALL ed_print_str
    ; Fall through to done (stop inserting)

ed_ins_done:
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_write - Write buffer to file
; ============================================================
ed_cmd_write:
    ; Check if filename follows 'w'
    INC  HL                  ; skip 'w'
    LD   A, (HL)
    CP   ' '
    JP   NZ, ed_write_use_current
    ; Skip spaces
ed_write_skip_sp:
    INC  HL
    LD   A, (HL)
    CP   ' '
    JP   Z, ed_write_skip_sp
    OR   A
    JP   Z, ed_write_use_current

    ; Copy new filename
    LD   DE, ed_fname
    LD   B, ED_FNAME_SIZE - 1
ed_write_cp_fn:
    LD   A, (HL)
    OR   A
    JP   Z, ed_write_cp_done
    CP   ' '
    JP   Z, ed_write_cp_done
    ; Uppercase
    CP   'a'
    JP   C, ed_write_cp_nc
    CP   'z' + 1
    JP   NC, ed_write_cp_nc
    AND  0x5F
ed_write_cp_nc:
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, ed_write_cp_fn
ed_write_cp_done:
    XOR  A
    LD   (DE), A

ed_write_use_current:
    ; Check we have a filename
    LD   A, (ed_fname)
    OR   A
    JP   Z, ed_write_no_name

    CALL ed_write_file
    JP   ed_cmd_loop

ed_write_no_name:
    LD   DE, ed_msg_no_fname
    CALL ed_print_str
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_quit - Quit (warn if dirty)
; ============================================================
ed_cmd_quit:
    LD   A, (ed_dirty)
    OR   A
    JP   Z, ed_exit
    LD   DE, ed_msg_unsaved
    CALL ed_print_str
    ; Set dirty to 0 so second q will quit
    XOR  A
    LD   (ed_dirty), A
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_quit_force - Quit without saving
; ============================================================
ed_cmd_quit_force:
ed_exit:
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; ed_cmd_dot - Print current line number
; ============================================================
ed_cmd_dot:
    LD   HL, (ed_cur_line)
    CALL ed_print_decimal
    CALL ed_newline
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_dollar - Print total line count
; ============================================================
ed_cmd_dollar:
    LD   HL, (ed_line_count)
    CALL ed_print_decimal
    CALL ed_newline
    JP   ed_cmd_loop

; ============================================================
; ed_cmd_help - Print help text
; ============================================================
ed_cmd_help:
    LD   DE, ed_msg_help
    CALL ed_print_str
    JP   ed_cmd_loop

; ============================================================
; ed_read_file - Read file into buffer
; Uses ed_fname as the filename.
; ============================================================
ed_read_file:
    ; Open file
    LD   DE, ed_fname
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ed_read_new     ; File not found = new file

    LD   A, L
    LD   (ed_file_dev), A

    ; Get file size via DEV_BGETSIZE
    LD   B, A
    LD   DE, ed_filesize_out
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    ; ed_filesize_out now holds 4-byte file size
    ; We only use the low 16 bits as our read limit
    LD   HL, (ed_filesize_out)
    LD   (ed_read_remain), HL

    ; Initialize read position
    LD   HL, 512
    LD   (ed_iobuf_pos), HL ; force first block read

    ; Read file into text buffer
    LD   HL, 0
    LD   (ed_buf_used), HL
    LD   (ed_line_count), HL

    LD   DE, ed_textbuf      ; write pointer

ed_read_loop:
    ; Check if we've read all bytes
    LD   HL, (ed_read_remain)
    LD   A, H
    OR   L
    JP   Z, ed_read_done

    ; Read a byte via block buffer
    PUSH DE
    CALL ed_fgetc            ; A = byte, carry = EOF/error
    POP  DE
    JP   C, ed_read_done

    ; Decrement remaining byte count
    LD   HL, (ed_read_remain)
    DEC  HL
    LD   (ed_read_remain), HL

    ; Check for CR (skip it, we use LF only internally)
    CP   ED_CR
    JP   Z, ed_read_loop

    ; Store byte
    LD   (DE), A
    INC  DE

    ; Update buf_used
    LD   HL, (ed_buf_used)
    INC  HL
    LD   (ed_buf_used), HL

    ; If LF, increment line count
    CP   ED_LF
    JP   NZ, ed_read_no_lf
    LD   HL, (ed_line_count)
    INC  HL
    LD   (ed_line_count), HL
ed_read_no_lf:

    ; Check buffer space
    PUSH DE
    LD   HL, (ed_buf_end)
    LD   A, E
    SUB  L
    LD   A, D
    SBC  A, H
    POP  DE
    JP   NC, ed_read_done    ; buffer full

    JP   ed_read_loop

ed_read_done:
    ; Ensure last line has LF
    LD   HL, (ed_buf_used)
    LD   A, H
    OR   L
    JP   Z, ed_read_close    ; empty file
    LD   DE, ed_textbuf
    ADD  HL, DE
    DEC  HL                  ; point to last byte
    LD   A, (HL)
    CP   ED_LF
    JP   Z, ed_read_close
    ; Add trailing LF
    INC  HL
    LD   (HL), ED_LF
    LD   HL, (ed_buf_used)
    INC  HL
    LD   (ed_buf_used), HL
    LD   HL, (ed_line_count)
    INC  HL
    LD   (ed_line_count), HL

ed_read_close:
    ; Close file
    LD   A, (ed_file_dev)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    ; Print byte count
    LD   HL, (ed_buf_used)
    CALL ed_print_decimal
    CALL ed_newline

    ; Set current line to 1 if we have lines
    LD   HL, (ed_line_count)
    LD   A, H
    OR   L
    JP   Z, ed_read_ret
    LD   HL, 1
    LD   (ed_cur_line), HL
ed_read_ret:
    RET

ed_read_new:
    ; File not found - new file message
    LD   DE, ed_fname
    CALL ed_print_str
    LD   DE, ed_msg_new
    CALL ed_print_str
    RET

; ============================================================
; ed_write_file - Write buffer to file
; ============================================================
ed_write_file:
    ; Resolve device and create file
    LD   DE, ed_fname
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR             ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, ed_write_err
    LD   B, L                   ; B = device ID
    LD   C, DEV_FCREATE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   Z, ed_write_created

    ; If file already exists, remove it and retry (re-parse each time)
    CP   ERR_EXISTS
    JP   NZ, ed_write_err
    LD   DE, ed_fname
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR             ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, ed_write_err
    LD   B, L                   ; B = device ID
    LD   C, DEV_FREMOVE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ed_write_err
    LD   DE, ed_fname
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR             ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, ed_write_err
    LD   B, L                   ; B = device ID
    LD   C, DEV_FCREATE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ed_write_err

ed_write_created:
    ; DEV_FCREATE returns file handle in L
    LD   A, L
    LD   (ed_file_dev), A

    ; Write buffer contents in 512-byte blocks
    LD   HL, 0
    LD   (ed_iobuf_pos), HL
    LD   (ed_bytes_written), HL

    LD   HL, ed_textbuf      ; source pointer
    LD   DE, (ed_buf_used)   ; total bytes to write

ed_write_loop:
    ; Check if done
    LD   A, D
    OR   E
    JP   Z, ed_write_flush

    ; Copy byte to iobuf
    LD   A, (HL)
    PUSH HL
    PUSH DE

    ; Convert LF to CR+LF for file output
    CP   ED_LF
    JP   NZ, ed_write_not_lf

    ; Write CR first
    LD   A, ED_CR
    CALL ed_fputc
    LD   A, ED_LF
    CALL ed_fputc
    JP   ed_write_next

ed_write_not_lf:
    CALL ed_fputc

ed_write_next:
    POP  DE
    POP  HL
    INC  HL
    DEC  DE
    JP   ed_write_loop

ed_write_flush:
    ; Flush remaining bytes in iobuf
    CALL ed_fflush

    ; Set exact file size
    LD   A, (ed_file_dev)
    LD   B, A
    LD   DE, ed_filesize_out
    LD   C, DEV_BSETSIZE
    CALL KERNELADDR

    ; Close file
    LD   A, (ed_file_dev)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    ; Print byte count
    LD   HL, (ed_bytes_written)
    CALL ed_print_decimal
    CALL ed_newline

    ; Clear dirty flag
    XOR  A
    LD   (ed_dirty), A

    JP   ed_cmd_loop

ed_write_err:
    LD   DE, ed_msg_write_err
    CALL ed_print_str
    JP   ed_cmd_loop

; ============================================================
; ed_fgetc - Read one byte from file via block buffer
; Outputs: A = byte (carry clear), or carry set on read error
; ============================================================
ed_fgetc:
    PUSH HL
    PUSH DE
    PUSH BC

    ; Check if we need to read a new block
    LD   HL, (ed_iobuf_pos)
    LD   A, H
    CP   2                   ; pos >= 512?
    JP   C, ed_fgetc_rd

    ; Read next block
    LD   A, (ed_file_dev)
    LD   B, A
    LD   DE, ed_iobuf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, ed_fgetc_eof
    LD   HL, 0
    LD   (ed_iobuf_pos), HL

ed_fgetc_rd:
    ; Read byte from iobuf[pos]
    LD   DE, ed_iobuf
    ADD  HL, DE              ; HL = &iobuf[pos]
    LD   A, (HL)

    ; Increment pos
    LD   HL, (ed_iobuf_pos)
    INC  HL
    LD   (ed_iobuf_pos), HL

    POP  BC
    POP  DE
    POP  HL
    OR   A                   ; clear carry
    RET

ed_fgetc_eof:
    POP  BC
    POP  DE
    POP  HL
    SCF                      ; set carry = EOF
    RET

; ============================================================
; ed_fputc - Write one byte to iobuf, flush when full
; Input: A = byte to write
; ============================================================
ed_fputc:
    PUSH HL
    PUSH DE
    PUSH BC

    LD   C, A                ; save byte

    ; Store byte
    LD   HL, (ed_iobuf_pos)
    LD   DE, ed_iobuf
    ADD  HL, DE
    LD   (HL), C

    ; Increment pos
    LD   HL, (ed_iobuf_pos)
    INC  HL
    LD   (ed_iobuf_pos), HL

    ; Increment bytes_written
    LD   HL, (ed_bytes_written)
    INC  HL
    LD   (ed_bytes_written), HL

    ; Check if block full (pos >= 512)
    LD   HL, (ed_iobuf_pos)
    LD   A, H
    CP   2
    JP   C, ed_fputc_done

    ; Flush block
    LD   A, (ed_file_dev)
    LD   B, A
    LD   DE, ed_iobuf
    LD   C, DEV_BWRITE
    CALL KERNELADDR
    LD   HL, 0
    LD   (ed_iobuf_pos), HL

ed_fputc_done:
    POP  BC
    POP  DE
    POP  HL
    RET

; ============================================================
; ed_fflush - Flush partial block, pad with zeros
; Also sets ed_filesize_out for BSETSIZE.
; ============================================================
ed_fflush:
    ; Save bytes_written as filesize for BSETSIZE
    LD   HL, (ed_bytes_written)
    LD   (ed_filesize_out), HL
    LD   HL, 0
    LD   (ed_filesize_out + 2), HL

    ; Check if anything to flush
    LD   HL, (ed_iobuf_pos)
    LD   A, H
    OR   L
    RET  Z                   ; nothing to flush

    ; Zero-fill rest of block
    LD   DE, ed_iobuf
    ADD  HL, DE              ; HL = &iobuf[pos]
    ; remaining = 512 - pos
    LD   BC, (ed_iobuf_pos)
    PUSH HL
    LD   HL, 512
    LD   A, L
    SUB  C
    LD   C, A
    LD   A, H
    SBC  A, B
    LD   B, A               ; BC = 512 - pos
    POP  HL

    LD   A, B
    OR   C
    JP   Z, ed_fflush_wr
ed_fflush_zf:
    LD   (HL), 0
    INC  HL
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, ed_fflush_zf

ed_fflush_wr:
    LD   A, (ed_file_dev)
    LD   B, A
    LD   DE, ed_iobuf
    LD   C, DEV_BWRITE
    CALL KERNELADDR
    LD   HL, 0
    LD   (ed_iobuf_pos), HL
    RET

; ============================================================
; ed_find_line - Find the Nth line in the text buffer
; Input: HL = line number (1-based)
; Output: HL = pointer to start of line
;         DE = pointer to LF at end of line
;         Carry set if line not found
; ============================================================
ed_find_line:
    ; Validate line number
    LD   A, H
    OR   L
    JP   Z, ed_fl_err        ; line 0 invalid

    PUSH HL                  ; save target line#
    LD   DE, ed_textbuf      ; start of buffer
    LD   HL, (ed_buf_used)
    LD   BC, ed_textbuf
    ADD  HL, BC              ; HL = end of buffer
    LD   (ed_fl_end), HL
    EX   DE, HL              ; HL = buffer start
    POP  DE                  ; DE = target line#
    DEC  DE                  ; make 0-based

    ; Skip DE lines
ed_fl_skip:
    LD   A, D
    OR   E
    JP   Z, ed_fl_found      ; reached target line

    ; Scan for next LF
ed_fl_scan_lf:
    ; Check if past end
    PUSH DE
    LD   DE, (ed_fl_end)
    LD   A, L
    SUB  E
    LD   A, H
    SBC  A, D
    POP  DE
    JP   NC, ed_fl_err       ; past end of buffer

    LD   A, (HL)
    INC  HL
    CP   ED_LF
    JP   NZ, ed_fl_scan_lf
    DEC  DE
    JP   ed_fl_skip

ed_fl_found:
    ; HL = start of target line
    PUSH HL                  ; save start
    ; Find end of line (LF)
ed_fl_find_end:
    PUSH DE
    LD   DE, (ed_fl_end)
    LD   A, L
    SUB  E
    LD   A, H
    SBC  A, D
    POP  DE
    JP   NC, ed_fl_at_end

    LD   A, (HL)
    CP   ED_LF
    JP   Z, ed_fl_got_end
    INC  HL
    JP   ed_fl_find_end

ed_fl_at_end:
    ; No LF found, end is at buffer end
    DEC  HL
ed_fl_got_end:
    EX   DE, HL              ; DE = ptr to LF (or end)
    POP  HL                  ; HL = start of line
    OR   A                   ; clear carry
    RET

ed_fl_err:
    SCF
    RET

; ============================================================
; ed_parse_addrs - Parse address range from command line
; Input: HL = pointer to command string
; Output: HL = pointer past addresses to command char
;         ed_addr1, ed_addr2, ed_addr_count set
; ============================================================
ed_parse_addrs:
    LD   A, 0
    LD   (ed_addr_count), A
    LD   (ed_addr1), A
    LD   (ed_addr1 + 1), A
    LD   (ed_addr2), A
    LD   (ed_addr2 + 1), A

    ; Try to parse first address
    CALL ed_parse_one_addr
    JP   C, ed_pa_done       ; no address found

    LD   (ed_addr1), DE
    LD   (ed_addr2), DE      ; default: addr2 = addr1
    LD   A, 1
    LD   (ed_addr_count), A

    ; Check for comma
    LD   A, (HL)
    CP   ','
    JP   NZ, ed_pa_done

    INC  HL                  ; skip comma
    CALL ed_parse_one_addr
    JP   C, ed_pa_done       ; no second address

    LD   (ed_addr2), DE
    LD   A, 2
    LD   (ed_addr_count), A

ed_pa_done:
    RET

; ============================================================
; ed_parse_one_addr - Parse one address value
; Input: HL = string pointer
; Output: DE = parsed value, HL advanced
;         Carry set if no valid address found
; ============================================================
ed_parse_one_addr:
    LD   A, (HL)

    ; Check for '.'
    CP   '.'
    JP   NZ, ed_poa_not_dot
    INC  HL
    LD   DE, (ed_cur_line)
    OR   A                   ; clear carry
    RET

ed_poa_not_dot:
    ; Check for '$'
    CP   '$'
    JP   NZ, ed_poa_not_dollar
    INC  HL
    LD   DE, (ed_line_count)
    OR   A
    RET

ed_poa_not_dollar:
    ; Check for digit
    CP   '0'
    JP   C, ed_poa_none
    CP   '9' + 1
    JP   NC, ed_poa_none

    ; Parse decimal number
    LD   DE, 0
ed_poa_digit:
    LD   A, (HL)
    CP   '0'
    JP   C, ed_poa_num_done
    CP   '9' + 1
    JP   NC, ed_poa_num_done

    ; DE = DE * 10 + digit
    PUSH HL
    PUSH AF                  ; save digit
    ; DE * 10 = DE * 8 + DE * 2
    LD   H, D
    LD   L, E               ; HL = DE
    ADD  HL, HL              ; *2
    PUSH HL                  ; save *2
    ADD  HL, HL              ; *4
    ADD  HL, HL              ; *8
    POP  DE                  ; DE = *2
    ADD  HL, DE              ; HL = *10
    EX   DE, HL              ; DE = *10
    POP  AF                  ; restore digit
    SUB  '0'
    LD   L, A
    LD   H, 0
    ADD  HL, DE
    EX   DE, HL              ; DE = result
    POP  HL
    INC  HL
    JP   ed_poa_digit

ed_poa_num_done:
    OR   A                   ; clear carry
    RET

ed_poa_none:
    SCF
    RET

; ============================================================
; ed_validate_line - Check if HL is valid line number (1..line_count)
; Output: carry set if invalid
; ============================================================
ed_validate_line:
    LD   A, H
    OR   L
    SCF
    RET  Z                   ; 0 is invalid

    LD   DE, (ed_line_count)
    LD   A, E
    SUB  L
    LD   A, D
    SBC  A, H
    RET                      ; carry set if line_count < HL

; ============================================================
; ed_resolve_range - Validate and return range from addr1,addr2
; Output: DE = addr1, HL = addr2 (validated)
;         Carry set on error
; ============================================================
ed_resolve_range:
    LD   HL, (ed_addr1)
    CALL ed_validate_line
    RET  C
    LD   HL, (ed_addr2)
    CALL ed_validate_line
    RET  C

    ; Check addr1 <= addr2
    LD   DE, (ed_addr1)
    LD   HL, (ed_addr2)
    LD   A, L
    SUB  E
    LD   A, H
    SBC  A, D
    RET                      ; carry set if addr2 < addr1

; ============================================================
; ed_default_cur_line - Set addr1=addr2=cur_line if no addr given
; ============================================================
ed_default_cur_line:
    LD   A, (ed_addr_count)
    OR   A
    RET  NZ
    LD   HL, (ed_cur_line)
    LD   (ed_addr1), HL
    LD   (ed_addr2), HL
    LD   A, 1
    LD   (ed_addr_count), A
    RET

; ============================================================
; ed_default_cur_line_ins - Default for insert: cur_line
; ============================================================
ed_default_cur_line_ins:
    LD   A, (ed_addr_count)
    OR   A
    RET  NZ
    LD   HL, (ed_cur_line)
    ; If cur_line is 0 and buffer is empty, use 1
    LD   A, H
    OR   L
    JP   NZ, ed_dci_set
    INC  HL
ed_dci_set:
    LD   (ed_addr1), HL
    LD   A, 1
    LD   (ed_addr_count), A
    RET

; ============================================================
; ed_default_cur_line_app - Default for append: cur_line
; ============================================================
ed_default_cur_line_app:
    LD   A, (ed_addr_count)
    OR   A
    RET  NZ
    LD   HL, (ed_cur_line)
    LD   (ed_addr1), HL
    LD   A, 1
    LD   (ed_addr_count), A
    RET

; ============================================================
; Console I/O helpers
; ============================================================

; ------------------------------------------------------------
; ed_putchar - Write character in A to console
; ------------------------------------------------------------
ed_putchar:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   E, A
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; ed_getchar - Read one character from console (blocking)
; Output: A = character
; ------------------------------------------------------------
ed_getchar:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    LD   A, L
    POP  HL
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; ed_print_str - Print null-terminated string at DE
; ------------------------------------------------------------
ed_print_str:
    PUSH BC
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    POP  BC
    RET

; ------------------------------------------------------------
; ed_newline - Print CR+LF
; ------------------------------------------------------------
ed_newline:
    LD   A, ED_CR
    CALL ed_putchar
    LD   A, ED_LF
    CALL ed_putchar
    RET

; ------------------------------------------------------------
; ed_getline - Read a line from console with editing
; Input: HL = buffer pointer, B = max length
; Output: A = length of string (0 = empty)
;         Buffer is null-terminated
; ------------------------------------------------------------
ed_getline:
    PUSH DE
    LD   D, B                ; D = max length
    LD   E, 0                ; E = current length
ed_gl_loop:
    CALL ed_getchar

    ; Check for CR or LF (end of line)
    CP   ED_CR
    JP   Z, ed_gl_cr
    CP   ED_LF
    JP   Z, ed_gl_done

    ; Check for backspace
    CP   ED_BS
    JP   Z, ed_gl_bs
    CP   ED_DEL
    JP   Z, ed_gl_bs

    ; Check for Ctrl-C (cancel)
    CP   ED_CTRLC
    JP   Z, ed_gl_cancel

    ; Normal character - check room
    LD   B, A
    LD   A, E
    CP   D
    JP   NC, ed_gl_loop      ; buffer full, ignore
    LD   A, B

    ; Store and echo
    LD   (HL), A
    INC  HL
    INC  E
    CALL ed_putchar
    JP   ed_gl_loop

ed_gl_bs:
    LD   A, E
    OR   A
    JP   Z, ed_gl_loop       ; nothing to delete
    DEC  HL
    DEC  E
    ; Erase: BS + space + BS
    LD   A, ED_BS
    CALL ed_putchar
    LD   A, ' '
    CALL ed_putchar
    LD   A, ED_BS
    CALL ed_putchar
    JP   ed_gl_loop

ed_gl_cancel:
    ; Cancel current input
    LD   A, E
    LD   E, 0
    ; Reset buffer pointer
    PUSH AF
    LD   A, E               ; E is now 0
    POP  AF
    ; Subtract E chars from HL to reset pointer
    PUSH DE
    LD   D, 0
    ; We need original HL, but we've advanced it.
    ; Easier: just set length to 0 and go to done
    POP  DE
    ; Rewind HL by old length
    ; Actually HL-E would be wrong since E is 0 now, use old value in A
    PUSH DE
    LD   E, A                ; A had old length
    LD   D, 0
    ; HL = HL - old_length
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    POP  DE
    LD   E, 0
    CALL ed_newline
    ; Fall through to done

ed_gl_cr:
ed_gl_done:
    LD   (HL), 0             ; null terminate
    LD   A, E                ; return length
    PUSH AF
    CALL ed_newline
    POP  AF
    POP  DE
    RET

; ------------------------------------------------------------
; ed_print_line_content - Print text from HL to DE (LF)
; Prints chars from HL up to (not including) the char at DE,
; then prints CR+LF.
; HL = start, DE = ptr to LF
; ------------------------------------------------------------
ed_print_line_content:
    PUSH BC
    PUSH DE
    PUSH HL
ed_plc_loop:
    ; Check if HL >= DE
    LD   A, L
    SUB  E
    LD   A, H
    SBC  A, D
    JP   NC, ed_plc_done     ; reached end

    LD   A, (HL)
    CP   ED_LF
    JP   Z, ed_plc_done
    CALL ed_putchar
    INC  HL
    JP   ed_plc_loop

ed_plc_done:
    CALL ed_newline
    POP  HL
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; ed_print_decimal - Print HL as decimal number
; ------------------------------------------------------------
ed_print_decimal:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Handle 0
    LD   A, H
    OR   L
    JP   NZ, ed_pd_nonzero
    LD   A, '0'
    CALL ed_putchar
    JP   ed_pd_ret

ed_pd_nonzero:
    ; Convert to decimal digits in ed_decbuf (reversed)
    LD   DE, ed_decbuf
    LD   B, 0                ; digit count
ed_pd_div:
    ; HL = HL / 10, remainder in A
    CALL ed_div10
    ADD  A, '0'
    LD   (DE), A
    INC  DE
    INC  B
    LD   A, H
    OR   L
    JP   NZ, ed_pd_div

    ; Print digits in reverse
    DEC  DE
ed_pd_print:
    LD   A, (DE)
    CALL ed_putchar
    DEC  DE
    DEC  B
    JP   NZ, ed_pd_print

ed_pd_ret:
    POP  HL
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; ed_div10 - Divide HL by 10
; Output: HL = quotient, A = remainder
; ------------------------------------------------------------
ed_div10:
    PUSH BC
    LD   BC, 0               ; quotient
    ; Repeated subtraction (simple, fine for small numbers)
ed_d10_loop:
    LD   A, L
    SUB  10
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    JP   C, ed_d10_done
    INC  BC
    JP   ed_d10_loop
ed_d10_done:
    ; Restore remainder (HL went negative)
    LD   A, L
    ADD  A, 10
    ; HL = quotient
    LD   H, B
    LD   L, C
    POP  BC
    RET

; ============================================================
; Messages
; ============================================================
ed_msg_huh:      DEFM "?", ED_CR, ED_LF, 0
ed_msg_range:    DEFM "?", ED_CR, ED_LF, 0
ed_msg_full:     DEFM "Buffer full", ED_CR, ED_LF, 0
ed_msg_unsaved:  DEFM "Unsaved changes (q again to quit)", ED_CR, ED_LF, 0
ed_msg_no_fname: DEFM "No filename", ED_CR, ED_LF, 0
ed_msg_write_err: DEFM "Write error", ED_CR, ED_LF, 0
ed_msg_new:      DEFM ": new file", ED_CR, ED_LF, 0
ed_msg_help:
    DEFM "[n]p      print line", ED_CR, ED_LF
    DEFM "[n,m]p    print lines n-m", ED_CR, ED_LF
    DEFM "[n]n      print with numbers", ED_CR, ED_LF
    DEFM "[n]d      delete line", ED_CR, ED_LF
    DEFM "[n,m]d    delete lines n-m", ED_CR, ED_LF
    DEFM "[n]i      insert before (. to end)", ED_CR, ED_LF
    DEFM "[n]a      append after (. to end)", ED_CR, ED_LF
    DEFM "[n]c      change (. to end)", ED_CR, ED_LF
    DEFM "w [file]  write to file", ED_CR, ED_LF
    DEFM "q         quit", ED_CR, ED_LF
    DEFM "Q         quit no save", ED_CR, ED_LF
    DEFM ".         current line #", ED_CR, ED_LF
    DEFM "$         last line #", ED_CR, ED_LF
    DEFM "h         this help", ED_CR, ED_LF, 0

; ============================================================
; Variables
; ============================================================
ed_cur_line:     DEFW 0      ; current line number (1-based, 0 = none)
ed_line_count:   DEFW 0      ; total number of lines
ed_buf_used:     DEFW 0      ; bytes used in text buffer
ed_buf_end:      DEFW 0      ; top of available memory
ed_dirty:        DEFB 0      ; 1 = unsaved changes
ed_addr1:        DEFW 0      ; parsed address 1
ed_addr2:        DEFW 0      ; parsed address 2
ed_addr_count:   DEFB 0      ; 0, 1, or 2 addresses parsed
ed_ins_point:    DEFW 0      ; insertion point in buffer
ed_file_dev:     DEFB 0      ; file device handle
ed_iobuf_pos:   DEFW 0      ; position in I/O buffer
ed_bytes_written: DEFW 0     ; total bytes written to file
ed_filesize_out: DEFS 4, 0   ; output file size for BSETSIZE
ed_fl_end:       DEFW 0      ; find_line: end of buffer ptr
ed_read_remain:  DEFW 0      ; bytes remaining to read from file
ed_fname:        DEFS ED_FNAME_SIZE, 0  ; filename buffer
ed_decbuf:       DEFS 6, 0   ; decimal conversion buffer
ed_cmdbuf:       DEFS ED_LINEBUF_SIZE, 0  ; command input buffer
ed_linebuf:      DEFS ED_LINEBUF_SIZE, 0  ; line input buffer (for insert mode)
ed_iobuf:        DEFS 512, 0 ; 512-byte I/O block buffer

; ============================================================
; Text buffer starts here and extends to ed_buf_end
; ============================================================
ed_textbuf:

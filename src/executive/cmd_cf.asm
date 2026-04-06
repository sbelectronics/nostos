; ============================================================
; cmd_cf.asm - CF / COPY command handler
; ============================================================
; CF src dest
;   Copy a file. src and dest may include a device prefix (e.g. A:FOO.TXT).
;   dest may be a bare device ("A:") to copy using the source filename.
;   If dest file already exists it is silently overwritten.
;   src or dest may be a character device (e.g. CON:) for terminal I/O.
;   For character src, input ends at Ctrl-Z (0x1A).
;   CR (0x0D) from a character src is expanded to CR+LF when writing to a file.
;
; State in EXEC_RAM_START (safe while no user program is loaded):
cmd_cf_src_id   EQU EXEC_RAM_START + 0    ; 1 byte  - source file handle ID
cmd_cf_dst_id   EQU EXEC_RAM_START + 1    ; 1 byte  - dest file handle ID
cmd_cf_filesize EQU EXEC_RAM_START + 2    ; 4 bytes - source file size / char byte count
cmd_cf_copybuf  EQU EXEC_RAM_START + 6    ; 512 bytes - block copy buffer
cmd_cf_destbuf  EQU EXEC_RAM_START + 518  ; 56 bytes - constructed dest path buffer
cmd_cf_flags    EQU EXEC_RAM_START + 574  ; 1 byte  - bit0=src-is-char, bit1=dst-is-char
cmd_cf_src_dev  EQU EXEC_RAM_START + 575  ; 1 byte  - char source device ID
cmd_cf_dst_dev  EQU EXEC_RAM_START + 576  ; 1 byte  - dest device ID
cmd_cf_buf_pos  EQU EXEC_RAM_START + 577  ; 2 bytes - bytes in copybuf (CHAR->FILE)

; ------------------------------------------------------------
; cmd_cf: Handle CF / COPY command
; ------------------------------------------------------------
cmd_cf:
    XOR  A
    LD   (cmd_cf_src_id), A
    LD   (cmd_cf_dst_id), A
    LD   (cmd_cf_flags), A
    LD   (cmd_cf_src_dev), A
    LD   (cmd_cf_dst_dev), A

    ; ---- 1. Parse args ----
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    CP   0
    JP   Z, cmd_cf_usage

    ; Token 1: src — upcase + null-terminate; keep DE = src pointer
    LD   D, H
    LD   E, L                       ; DE = src pointer
    CALL exec_upcase_delimit        ; HL = char after src null
    CALL exec_skip_spaces           ; HL = dest string start

    LD   A, (HL)
    CP   0
    JP   Z, cmd_cf_usage            ; no dest arg

    ; Token 2: dest — save pointer, then upcase + null-terminate
    PUSH HL                         ; [SP] = dest pointer
    CALL exec_upcase_delimit        ; null-terminate dest token
    POP  HL                         ; HL = dest pointer

    ; DE = src path, HL = dest path

    ; ---- 2. Parse dest: resolve device and path component ----
    PUSH DE                         ; [SP] = src pointer
    LD   D, H
    LD   E, L                       ; DE = dest string
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR                 ; A = status, HL = device ID, DE = path component
    OR   A
    JP   NZ, cmd_cf_dest_err_pop
    LD   B, L                       ; B = device ID
    LD   A, B
    LD   (cmd_cf_dst_dev), A        ; save dest device ID for later use

    ; ---- 2a. Check dest device capabilities ----
    ; If DEVCAP_CHAR_OUT is set and DEVCAP_FILESYSTEM is not: dest is a char device.
    CALL cmd_cf_get_caps            ; B=dest_dev_id -> A=caps; BC,DE,HL preserved
    LD   C, A                       ; C = caps
    AND  DEVCAP_CHAR_OUT
    JP   Z, cmd_cf_dest_cap_done    ; no char output -> not a char dest
    LD   A, C
    AND  DEVCAP_FILESYSTEM
    JP   NZ, cmd_cf_dest_cap_done   ; filesystem device -> treat as file dest
    ; Pure char output device: set bit1 in flags
    LD   A, (cmd_cf_flags)
    OR   0x02
    LD   (cmd_cf_flags), A
cmd_cf_dest_cap_done:

    ; B = dest device ID; DE = dest filename (may be empty "")
    PUSH BC                         ; [SP2] = dest device (B)
    PUSH DE                         ; [SP3] = dest filename pointer

    ; ---- 3. Extract src basename (used when dest filename is empty) ----
    POP  DE                         ; DE = dest filename
    POP  BC                         ; B = dest device ID
    POP  HL                         ; HL = src pointer

    ; ---- 3a. Check src device capabilities ----
    ; If DEVCAP_CHAR_IN is set and DEVCAP_FILESYSTEM is not: src is a char device.
    CALL cmd_cf_check_src_char      ; HL=src -> sets flags+cmd_cf_src_dev if char

    PUSH BC                         ; re-save dest device
    PUSH DE                         ; re-save dest filename

    ; Scan src for ':' and '/'; basename = everything after the last separator
    LD   D, H
    LD   E, L                       ; DE = src basename (default = start)
cmd_cf_src_sep_scan:
    LD   A, (HL)
    CP   0
    JP   Z, cmd_cf_src_basename_ready
    CP   ':'
    JP   Z, cmd_cf_src_sep_found
    CP   '/'
    JP   Z, cmd_cf_src_sep_found
    INC  HL
    JP   cmd_cf_src_sep_scan
cmd_cf_src_sep_found:
    INC  HL
    LD   D, H
    LD   E, L                       ; DE = basename start (after this separator)
    JP   cmd_cf_src_sep_scan
cmd_cf_src_basename_ready:
    ; DE = src basename string pointer

    ; ---- 4. Determine final dest path ----
    ; If dst-is-char: skip path construction (no dest filename needed).
    ; If dest filename is empty: use src basename (root-relative: "/basename").
    ; If dest filename ends with '/': construct dest_prefix + src_basename.
    ; Otherwise: use dest filename as-is.
    POP  HL                         ; HL = dest filename pointer
    PUSH DE                         ; [SP] = src basename; [SP+2] = dest device

    ; If dst-is-char: skip dest path construction
    LD   A, (cmd_cf_flags)
    AND  0x02
    JP   NZ, cmd_cf_skip_dest_path

    ; Check if dest_filename is empty
    LD   A, (HL)
    CP   0
    JP   Z, cmd_cf_dest_use_src     ; empty: fall back to src basename

    ; Find end of dest_filename, checking last char for trailing '/'
    PUSH HL                         ; [SP] = dest_filename start
    LD   D, H
    LD   E, L
cmd_cf_dest_end_scan:
    LD   A, (DE)
    CP   0
    JP   Z, cmd_cf_dest_end_done
    INC  DE
    JP   cmd_cf_dest_end_scan
cmd_cf_dest_end_done:
    ; DE = NUL; check last char
    DEC  DE
    LD   A, (DE)                    ; A = last char of dest_filename
    CP   '/'
    JP   Z, cmd_cf_dest_trail_slash

    ; No trailing slash: copy dest_filename to destbuf (survives later syscalls)
    POP  HL                         ; HL = dest_filename start
    POP  BC                         ; discard src_basename
    LD   DE, cmd_cf_destbuf
    LD   B, 55                      ; max chars
cmd_cf_dest_copy_asis:
    LD   A, (HL)
    LD   (DE), A
    CP   0
    JP   Z, cmd_cf_dest_copied
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, cmd_cf_dest_copy_asis
    XOR  A
    LD   (DE), A                    ; force NUL termination
cmd_cf_dest_copied:
    LD   HL, cmd_cf_destbuf
    JP   cmd_cf_have_dest_path

cmd_cf_dest_trail_slash:
    ; dest_filename ends with '/': build dest_filename + src_basename in destbuf.
    ; Limit total to 55 chars + NUL to stay within the 56-byte destbuf.
    POP  HL                         ; HL = dest_filename start
    LD   DE, cmd_cf_destbuf
    LD   B, 55                      ; max chars (56-byte buf, 1 reserved for NUL)
cmd_cf_dest_copy_prefix:
    LD   A, B
    OR   A
    JP   Z, cmd_cf_dest_pfx_full    ; buffer full before prefix ended
    LD   A, (HL)
    CP   0
    JP   Z, cmd_cf_dest_append_src
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   cmd_cf_dest_copy_prefix
cmd_cf_dest_pfx_full:
    POP  HL                         ; discard src_basename from stack
    JP   cmd_cf_dest_buf_full

cmd_cf_dest_append_src:
    ; DE = position after prefix; append src_basename (B = remaining capacity)
    POP  HL                         ; HL = src_basename
cmd_cf_dest_append_loop:
    LD   A, B
    OR   A
    JP   Z, cmd_cf_dest_buf_full    ; buffer full
    LD   A, (HL)
    LD   (DE), A
    CP   0
    JP   Z, cmd_cf_dest_buf_ok      ; NUL written — done
    INC  HL
    INC  DE
    DEC  B
    JP   cmd_cf_dest_append_loop

cmd_cf_dest_use_src:
    ; Empty dest filename: use src basename as dest filename.
    ; If dest device == CUR_DEVICE, use bare basename (CUR_DIR will be prepended).
    ; If dest device != CUR_DEVICE, force root-relative "/basename" to avoid
    ; CUR_DIR being prepended (CUR_DIR belongs to the current device, not dest).
    POP  HL                         ; HL = src_basename; [SP] = dest device still on stack
    LD   DE, cmd_cf_destbuf
    LD   A, (cmd_cf_dst_dev)        ; A = dest device ID (saved at parse time)
    LD   B, A
    LD   A, (CUR_DEVICE)
    CP   B
    JP   Z, cmd_cf_dest_use_src_bare ; same device — use bare name
    ; Different device: prepend '/' to force root-relative
    LD   A, '/'
    LD   (DE), A
    INC  DE
    LD   B, 54                      ; 55 max chars - 1 already used for '/'
    JP   cmd_cf_dest_use_src_copy
cmd_cf_dest_use_src_bare:
    LD   B, 55                      ; full 55 chars available
cmd_cf_dest_use_src_copy:
    LD   A, B
    OR   A
    JP   Z, cmd_cf_dest_buf_full    ; buffer full
    LD   A, (HL)
    LD   (DE), A
    CP   0
    JP   Z, cmd_cf_dest_buf_ok      ; NUL written — done
    INC  HL
    INC  DE
    DEC  B
    JP   cmd_cf_dest_use_src_copy

cmd_cf_dest_buf_full:
    XOR  A
    LD   (DE), A                    ; force NUL termination at buffer limit
cmd_cf_dest_buf_ok:
    LD   HL, cmd_cf_destbuf
    JP   cmd_cf_have_dest_path

cmd_cf_skip_dest_path:
    ; Dst is char: discard src_basename from stack, push dummy dest path = 0
    POP  BC                         ; discard src_basename (BC used as scratch)
    LD   HL, 0

cmd_cf_have_dest_path:
    ; HL = final dest path (or 0 if dst-is-char)
    PUSH HL                         ; [SP] = final dest path; [SP+2] = dest device

    ; ---- 5. Open source file (or skip if src-is-char) ----
    LD   A, (cmd_cf_flags)
    AND  0x01
    JP   NZ, cmd_cf_skip_open_src   ; src is a char device

    LD   DE, (EXEC_ARGS_PTR)        ; src path (already null-terminated)
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_open_src_err

    LD   A, L
    LD   (cmd_cf_src_id), A

    ; ---- 6. Get source file size ----
    LD   B, A
    LD   DE, cmd_cf_filesize
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_open_src_err
    JP   cmd_cf_src_opened

cmd_cf_skip_open_src:
    ; Src is a char device: initialize filesize and buf_pos to 0
    XOR  A
    LD   (cmd_cf_filesize), A
    LD   (cmd_cf_filesize + 1), A
    LD   (cmd_cf_filesize + 2), A
    LD   (cmd_cf_filesize + 3), A
    LD   HL, 0
    LD   (cmd_cf_buf_pos), HL

cmd_cf_src_opened:
    ; ---- 7. Create dest file (or skip if dst-is-char) ----
    POP  DE                         ; DE = final dest filename (or 0)
    POP  BC                         ; B = dest device ID

    LD   A, (cmd_cf_flags)
    AND  0x02
    JP   NZ, cmd_cf_skip_create_dest

    CALL cmd_cf_create_dest         ; B=devID, DE=filename
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_create_err
    JP   cmd_cf_dest_ready

cmd_cf_skip_create_dest:
    ; Dst is char device: no file creation needed (cmd_cf_dst_id remains 0)

cmd_cf_dest_ready:
    ; ---- 8. Copy: dispatch on src/dst type flags ----
    LD   A, (cmd_cf_flags)
    AND  0x03
    JP   Z,  cmd_cf_loop_ff         ; 00: FILE->FILE
    CP   0x01
    JP   Z,  cmd_cf_loop_cf         ; 01: CHAR->FILE
    CP   0x02
    JP   Z,  cmd_cf_loop_fc         ; 10: FILE->CHAR
    JP       cmd_cf_loop_cc         ; 11: CHAR->CHAR

; ---- 8a. FILE->FILE copy loop ----
cmd_cf_loop_ff:
    LD   A, (cmd_cf_src_id)
    LD   B, A
    LD   DE, cmd_cf_copybuf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_EOF
    JP   Z, cmd_cf_copy_done
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err

    LD   A, (cmd_cf_dst_id)
    LD   B, A
    LD   DE, cmd_cf_copybuf
    LD   C, DEV_BWRITE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err
    JP   cmd_cf_loop_ff

; ---- 8b. CHAR->FILE copy loop ----
; Read bytes from src char device into copybuf; flush to dest file every 512
; bytes or on Ctrl-Z (0x1A). cmd_cf_filesize accumulates the exact byte count
; for the size fixup step.
; CR (0x0D) is expanded to CR+LF (0x0D, 0x0A) to match the platform file convention.
cmd_cf_loop_cf:
cmd_cf_cf_read_byte:
    LD   A, (cmd_cf_src_dev)
    LD   B, A
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err
    LD   A, L                       ; A = byte received
    CP   0x1A                       ; Ctrl-Z = EOF marker
    JP   Z, cmd_cf_cf_eof
    CP   0x0D                       ; CR? expand to CR+LF
    JP   NZ, cmd_cf_cf_do_store
    CALL cmd_cf_cf_store_byte       ; store 0x0D
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err
    LD   A, 0x0A                    ; follow with LF
cmd_cf_cf_do_store:
    CALL cmd_cf_cf_store_byte       ; store byte (or the LF after CR)
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err
    JP   cmd_cf_cf_read_byte

cmd_cf_cf_eof:
    ; Ctrl-Z received: flush partial buffer if non-empty, then done
    LD   HL, (cmd_cf_buf_pos)
    LD   A, H
    OR   L
    JP   Z, cmd_cf_copy_done        ; empty buffer — nothing to flush
    LD   A, (cmd_cf_dst_id)
    LD   B, A
    LD   DE, cmd_cf_copybuf
    LD   C, DEV_BWRITE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err
    JP   cmd_cf_copy_done

; ------------------------------------------------------------
; cmd_cf_cf_store_byte
; Store byte A into copybuf at buf_pos; update buf_pos and filesize;
; flush the full 512-byte block to the dest file if buf_pos reaches 512.
; Inputs:
;   A  - byte to store
; Outputs:
;   A  - ERR_SUCCESS or error code from DEV_BWRITE flush
; ------------------------------------------------------------
cmd_cf_cf_store_byte:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   C, A                       ; C = byte to store (survives register clobbers)
    ; Write byte into copybuf[buf_pos]
    LD   HL, (cmd_cf_buf_pos)
    LD   DE, cmd_cf_copybuf
    ADD  HL, DE                     ; HL = &copybuf[buf_pos]
    LD   (HL), C
    ; Increment buf_pos
    LD   HL, (cmd_cf_buf_pos)
    INC  HL
    LD   (cmd_cf_buf_pos), HL
    ; Increment filesize (3-byte little-endian)
    LD   HL, cmd_cf_filesize
    LD   A, (HL)
    INC  A
    LD   (HL), A
    JP   NZ, cmd_cf_csb_fs_ok
    INC  HL
    LD   A, (HL)
    INC  A
    LD   (HL), A
    JP   NZ, cmd_cf_csb_fs_ok
    INC  HL
    LD   A, (HL)
    INC  A
    LD   (HL), A
cmd_cf_csb_fs_ok:
    ; Flush if buf_pos == 512 (0x0200)
    LD   HL, (cmd_cf_buf_pos)
    LD   A, H
    CP   2
    JP   NZ, cmd_cf_csb_ok
    LD   A, L
    OR   A
    JP   NZ, cmd_cf_csb_ok
    ; Buffer full: write 512 bytes to dest file
    LD   A, (cmd_cf_dst_id)
    LD   B, A
    LD   DE, cmd_cf_copybuf
    LD   C, DEV_BWRITE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_csb_done        ; return error in A
    LD   HL, 0
    LD   (cmd_cf_buf_pos), HL
cmd_cf_csb_ok:
    XOR  A                          ; ERR_SUCCESS
cmd_cf_csb_done:
    POP  HL
    POP  DE
    POP  BC
    RET

; ---- 8c. FILE->CHAR copy loop ----
; Write exactly filesize bytes from src file to dest char device.
cmd_cf_loop_fc:
    ; Check if filesize == 0
    LD   HL, cmd_cf_filesize
    LD   A, (HL)
    INC  HL
    OR   (HL)
    INC  HL
    OR   (HL)
    JP   Z, cmd_cf_copy_done        ; zero filesize — nothing to write
cmd_cf_fc_next_block:
    ; Read next block from src file
    LD   A, (cmd_cf_src_id)
    LD   B, A
    LD   DE, cmd_cf_copybuf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_EOF
    JP   Z, cmd_cf_copy_done
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err
    ; Compute bytes to write: min(filesize, 512)
    LD   A, (cmd_cf_filesize + 2)
    OR   A
    JP   NZ, cmd_cf_fc_full_block   ; high byte nonzero -> >= 512
    LD   A, (cmd_cf_filesize + 1)
    CP   2
    JP   NC, cmd_cf_fc_full_block   ; mid byte >= 2 -> >= 512 (0x0200)
    ; Partial last block: DE = filesize[1:0]
    LD   D, A                       ; D = filesize[1] (mid byte)
    LD   A, (cmd_cf_filesize)
    LD   E, A                       ; E = filesize[0] (low byte)
    JP   cmd_cf_fc_sub_filesize
cmd_cf_fc_full_block:
    LD   D, 2                       ; 512 = 0x0200
    LD   E, 0
cmd_cf_fc_sub_filesize:
    ; Subtract DE from cmd_cf_filesize (3-byte) before the write loop
    LD   HL, cmd_cf_filesize
    LD   A, (HL)
    SUB  E
    LD   (HL), A
    INC  HL
    LD   A, (HL)
    SBC  A, D
    LD   (HL), A
    INC  HL
    LD   A, (HL)
    SBC  A, 0
    LD   (HL), A
    ; Write DE bytes from copybuf to char dest
    LD   HL, cmd_cf_copybuf
cmd_cf_fc_write:
    LD   A, D
    OR   E
    JP   Z, cmd_cf_fc_block_done
    PUSH DE                         ; save count before loading byte into E
    LD   A, (HL)                    ; A = byte to write
    INC  HL
    PUSH HL                         ; save ptr (CALL clobbers HL)
    LD   E, A                       ; E = byte for DEV_CWRITE
    LD   A, (cmd_cf_dst_dev)
    LD   B, A
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  DE
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err
    DEC  DE
    JP   cmd_cf_fc_write
cmd_cf_fc_block_done:
    ; Check if filesize reached 0
    LD   HL, cmd_cf_filesize
    LD   A, (HL)
    INC  HL
    OR   (HL)
    INC  HL
    OR   (HL)
    JP   NZ, cmd_cf_fc_next_block
    JP   cmd_cf_copy_done

; ---- 8d. CHAR->CHAR copy loop ----
; Read from src char device, write to dest char device, until Ctrl-Z.
cmd_cf_loop_cc:
cmd_cf_cc_loop:
    LD   A, (cmd_cf_src_dev)
    LD   B, A
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err
    LD   E, L                       ; E = byte (save for DEV_CWRITE)
    LD   A, L
    CP   0x1A                       ; Ctrl-Z = EOF
    JP   Z, cmd_cf_copy_done
    LD   A, (cmd_cf_dst_dev)
    LD   B, A
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_rw_err
    JP   cmd_cf_cc_loop

cmd_cf_copy_done:
    ; ---- 9. Fix dest file size (DEV_BWRITE rounds to 512 bytes) ----
    ; Skip if dst is a char device (no file to fix)
    LD   A, (cmd_cf_flags)
    AND  0x02
    JP   NZ, cmd_cf_close_both

    LD   A, (cmd_cf_dst_id)
    LD   B, A
    LD   DE, cmd_cf_filesize
    LD   C, DEV_BSETSIZE
    CALL KERNELADDR

cmd_cf_close_both:
    ; ---- 10. Close dest then src ----
    LD   A, (cmd_cf_dst_id)
    OR   A
    JP   Z, cmd_cf_close_src
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    XOR  A
    LD   (cmd_cf_dst_id), A

cmd_cf_close_src:
    LD   A, (cmd_cf_src_id)
    OR   A
    JP   Z, cmd_cf_exit
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    XOR  A
    LD   (cmd_cf_src_id), A

cmd_cf_exit:
    RET

; ---- Error paths ----
cmd_cf_open_src_err:
    POP  DE                         ; clean [SP] dest filename
    POP  BC                         ; clean [SP+2] dest device
    JP   cmd_cf_error

cmd_cf_create_err:
cmd_cf_rw_err:
cmd_cf_error:
    CALL exec_print_error
    JP   cmd_cf_close_both

cmd_cf_dest_err_pop:
    POP  DE                         ; clean [SP] src pointer
    JP   cmd_cf_error

cmd_cf_usage:
    LD   DE, msg_cf_usage
    CALL exec_puts
    RET


; ------------------------------------------------------------
; cmd_cf_create_dest
; Create dest file, overwriting silently if it already exists.
; Inputs:
;   B  - dest filesystem device ID
;   DE - pointer to null-terminated dest filename
; Outputs:
;   A  - ERR_SUCCESS or error code
;   (cmd_cf_dst_id) set on success
; ------------------------------------------------------------
cmd_cf_create_dest:
    PUSH BC
    PUSH DE
    LD   C, DEV_FCREATE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   Z, cmd_cf_cd_ok

    ; File already exists — remove it and retry
    CP   ERR_EXISTS
    JP   NZ, cmd_cf_cd_fail

    POP  DE
    POP  BC
    PUSH BC
    PUSH DE
    LD   C, DEV_FREMOVE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_cd_fail

    POP  DE
    POP  BC
    PUSH BC
    PUSH DE
    LD   C, DEV_FCREATE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_cd_fail

cmd_cf_cd_ok:
    LD   A, L
    LD   (cmd_cf_dst_id), A
    POP  DE
    POP  BC
    LD   A, ERR_SUCCESS
    RET

cmd_cf_cd_fail:
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; cmd_cf_get_caps
; Return capability bits for a device (logical or physical).
; Inputs:
;   B  - device ID (logical 0x80+ or physical 0x00-0x7F)
; Outputs:
;   A  - capability bits from PHYSDEV_OFF_CAPS (0 on error)
; Preserves: BC, DE, HL
; ------------------------------------------------------------
cmd_cf_get_caps:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   A, B
    AND  0x80
    JP   Z, cmd_cf_gc_physical
    ; Logical device: index = B & 0x7F; physptr = LOGDEV_TABLE[index].physptr
    LD   A, B
    AND  0x7F                       ; A = logical index
    LD   L, A
    LD   H, 0
    ADD  HL, HL                     ; * 2
    ADD  HL, HL                     ; * 4
    ADD  HL, HL                     ; * 8 (each entry is 8 bytes)
    LD   BC, LOGDEV_TABLE
    ADD  HL, BC                     ; HL = &logdev_table[index]
    LD   BC, LOGDEV_OFF_PHYSPTR
    ADD  HL, BC                     ; HL = &entry.physptr
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                    ; DE = physical device entry pointer
    EX   DE, HL                     ; HL = physdev pointer
    LD   A, H
    OR   L
    JP   Z, cmd_cf_gc_fail          ; null physptr — unassigned slot
    JP   cmd_cf_gc_have_phys
cmd_cf_gc_physical:
    ; Physical device: use DEV_PHYS_GET to get entry pointer
    LD   C, DEV_PHYS_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_gc_fail
cmd_cf_gc_have_phys:
    ; HL = physical device entry; caps at offset PHYSDEV_OFF_CAPS (= 10)
    LD   BC, PHYSDEV_OFF_CAPS
    ADD  HL, BC
    LD   A, (HL)                    ; A = caps byte
    POP  HL
    POP  DE
    POP  BC
    RET
cmd_cf_gc_fail:
    XOR  A
    POP  HL
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; cmd_cf_check_src_char
; Determine if the source path refers to a char device by extracting
; the device name prefix (up to ':'), looking it up, and checking caps.
; If DEVCAP_CHAR_IN is set and DEVCAP_FILESYSTEM is not, sets bit0 in
; cmd_cf_flags and stores the device ID in cmd_cf_src_dev.
; Inputs:
;   HL - null-terminated source path string (already uppercased)
; Outputs:
;   (cmd_cf_flags) bit0 set if src is a char device
;   (cmd_cf_src_dev) set to device ID if src is a char device
; Preserves: BC, DE, HL
; ------------------------------------------------------------
cmd_cf_check_src_char:
    PUSH BC
    PUSH DE
    PUSH HL
    ; Copy device name part (chars before ':') into PATH_WORK_DEVNAME
    LD   DE, PATH_WORK_DEVNAME
    LD   B, 7                       ; max 7 chars (8-byte scratch, 1 for NUL)
cmd_cf_csc_copy:
    LD   A, (HL)
    CP   0
    JP   Z, cmd_cf_csc_no_colon     ; end of string without ':' — use CUR_DEVICE
    CP   ':'
    JP   Z, cmd_cf_csc_got_colon
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, cmd_cf_csc_copy
    ; Device name exceeds 7 chars — scan forward to look for ':'
cmd_cf_csc_scan_long:
    LD   A, (HL)
    CP   0
    JP   Z, cmd_cf_csc_no_colon
    CP   ':'
    JP   Z, cmd_cf_csc_no_colon     ; name too long to be a real device name
    INC  HL
    JP   cmd_cf_csc_scan_long
cmd_cf_csc_got_colon:
    ; NUL-terminate the device name in PATH_WORK_DEVNAME
    XOR  A
    LD   (DE), A
    ; Look up the device by name
    LD   DE, PATH_WORK_DEVNAME
    LD   B, 0
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_cf_csc_done        ; device not found — treat as file src
    LD   B, L                       ; B = device ID
    JP   cmd_cf_csc_check_caps
cmd_cf_csc_no_colon:
    ; No ':' in src — use CUR_DEVICE
    LD   A, (CUR_DEVICE)
    LD   B, A
cmd_cf_csc_check_caps:
    CALL cmd_cf_get_caps            ; B = device ID -> A = caps; BC preserved
    LD   C, A                       ; C = caps
    AND  DEVCAP_CHAR_IN
    JP   Z, cmd_cf_csc_done         ; no char input -> not a char src
    LD   A, C
    AND  DEVCAP_FILESYSTEM
    JP   NZ, cmd_cf_csc_done        ; filesystem device -> treat as file src
    ; Pure char input device: set bit0 of flags, store device ID
    LD   A, (cmd_cf_flags)
    OR   0x01
    LD   (cmd_cf_flags), A
    LD   A, B
    LD   (cmd_cf_src_dev), A
cmd_cf_csc_done:
    POP  HL
    POP  DE
    POP  BC
    RET

msg_cf_usage:   DEFM "Usage: CF src dest", 0x0D, 0x0A, 0

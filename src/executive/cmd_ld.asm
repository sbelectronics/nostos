; ============================================================
; cmd_ld.asm - LD / DIR command
; ============================================================

; Buffer spaces in WORKSPACE RAM
cmd_ld_dirent   EQU EXEC_RAM_START  ; 32-byte directory entry buffer
cmd_ld_handle   EQU EXEC_RAM_START+0x30  ; 1 byte directory handle 
cmd_ld_temp_str EQU EXEC_RAM_START+0x40  ; Temp string space (64 bytes)

; ------------------------------------------------------------
; cmd_ld: Handle LD / DIR command
; ------------------------------------------------------------
cmd_ld:
    ; 1. Resolve pathname and open the directory.
    ;    EXEC_ARGS_PTR points to the path argument (empty = root).
    LD   HL, (EXEC_ARGS_PTR)    ; path argument (empty string = root)
    EX   DE, HL                 ; DE = path string
    LD   C, SYS_GLOBAL_OPENDIR
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_ld_open_error

    ; HL = directory handle (physical device ID)
    LD   A, L
    LD   (cmd_ld_handle), A

    ; Print header
    LD   DE, msg_ld_header
    CALL exec_puts

cmd_ld_loop:
    ; 2. Read next directory entry via DEV_BREAD on the dir handle.
    ;    dft_dir slot 2 = fs_dir_bread, which returns ERR_EOF at end.
    LD   A, (cmd_ld_handle)
    LD   B, A
    LD   DE, cmd_ld_dirent
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_EOF
    JP   Z, cmd_ld_done
    CP   ERR_SUCCESS
    JP   NZ, cmd_ld_io_error

    ; Check DIRENT_TYPE_USED (bit7); fs_dir_bread skips unused entries,
    ; but verify here in case the kernel contract changes.
    LD   A, (cmd_ld_dirent + DIRENT_OFF_TYPE)
    AND  DIRENT_TYPE_USED
    JP   Z, cmd_ld_loop

    ; Is it a directory (bit6)?
    LD   A, (cmd_ld_dirent + DIRENT_OFF_TYPE)
    AND  DIRENT_TYPE_DIR
    JP   Z, cmd_ld_print_file

    ; Directory: print "<DIR>    " tag
    LD   DE, msg_ld_dir
    CALL exec_puts
    JP   cmd_ld_print_name

cmd_ld_io_error:
    CALL exec_print_error
    JP   cmd_ld_done

cmd_ld_print_file:
    ; Print size (low 16 bits at DIRENT_OFF_SIZE), right-justified in 6 chars
    LD   A, (cmd_ld_dirent + DIRENT_OFF_SIZE)
    LD   L, A
    LD   A, (cmd_ld_dirent + DIRENT_OFF_SIZE + 1)
    LD   H, A
    CALL exec_print_dec16_w6
    LD   DE, msg_space
    CALL exec_puts

cmd_ld_print_name:
    ; Copy name (up to 16 bytes at DIRENT_OFF_NAME, null-terminated) to temp buffer
    LD   HL, cmd_ld_dirent + DIRENT_OFF_NAME
    LD   DE, cmd_ld_temp_str
    LD   B, 16
cmd_ld_copy_name:
    LD   A, (HL)
    OR   A
    JP   Z, cmd_ld_copy_name_done
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, cmd_ld_copy_name
cmd_ld_copy_name_done:
    XOR  A
    LD   (DE), A                ; null-terminate
    LD   DE, cmd_ld_temp_str
    CALL exec_puts
    CALL exec_crlf
    JP   cmd_ld_loop

cmd_ld_done:
    ; 3. Close directory handle
    LD   A, (cmd_ld_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    RET

cmd_ld_open_error:
    CALL exec_print_error
    RET

; Data
msg_ld_header:    DEFM "Directory Listing:", 0x0D, 0x0A, 0
msg_ld_dir:       DEFM " <DIR> ", 0
msg_space:        DEFM " ", 0

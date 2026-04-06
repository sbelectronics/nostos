; ============================================================
; cmd_st.asm - STAT command handler
; ============================================================
; ST / STAT <filename>
;   Opens the named file on CUR_DEVICE, prints all handle
;   fields, then walks the inode chain and prints every span.

cmd_st_handle   EQU EXEC_RAM_START + 0    ; 1 byte: physical handle ID
cmd_st_blk_dev  EQU EXEC_RAM_START + 1    ; 1 byte: underlying block device ID
cmd_st_inode    EQU EXEC_RAM_START + 2    ; 2 bytes: inode block being walked

; Inode layout offsets (must match INODE_OFF_* in src/drivers/fs.asm)
CMD_ST_INODE_COUNT  EQU 0               ; span count (1 byte)
CMD_ST_INODE_NEXT   EQU 2               ; next inode block (2 bytes LE)
CMD_ST_INODE_SPANS  EQU 8               ; start of spans array

; ------------------------------------------------------------
; cmd_st: Handle ST / STAT command
; ------------------------------------------------------------
cmd_st:
    XOR  A
    LD   (cmd_st_handle), A

    ; 1. Require a filename argument
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, cmd_st_usage

    ; 2. Resolve pathname and open the file
    EX   DE, HL                         ; DE = path
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_st_open_error

    LD   A, L                           ; A = physical handle ID
    LD   (cmd_st_handle), A

    ; 3. Get PDT entry for handle and verify it's a file (not a bare device)
    LD   B, A
    LD   C, DEV_PHYS_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_st_io_error
    ; File handles have DEVCAP_HANDLE set; bare devices do not
    PUSH HL                             ; save PDT entry ptr
    LD   DE, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  DEVCAP_HANDLE
    POP  HL                             ; restore PDT entry ptr
    JP   NZ, cmd_st_is_file
    ; Bare device — no file handle was opened, so clear before exiting
    XOR  A
    LD   (cmd_st_handle), A
    JP   cmd_st_usage
cmd_st_is_file:

    ; 4. Save underlying block device ID from parent field
    PUSH HL                             ; save PDT entry ptr
    LD   DE, PHYSDEV_OFF_PARENT         ; = 11
    ADD  HL, DE
    LD   A, (HL)
    LD   (cmd_st_blk_dev), A
    POP  HL                             ; restore PDT entry ptr

    ; 5. Point HL to handle user data
    LD   DE, PHYSDEV_OFF_DATA           ; = 15
    ADD  HL, DE                         ; HL = handle user data base

    ; 6. Print all handle fields sequentially (HL = cursor)

    ; --- Flags (HND_OFF_FLAGS = 0, 1 byte) ---
    LD   DE, msg_st_flags
    CALL exec_puts
    LD   A, (HL)
    CALL exec_print_hex8
    CALL exec_crlf
    INC  HL

    ; --- Root Inode (HND_OFF_ROOT_INODE = 1, 2 bytes LE) ---
    LD   DE, msg_st_root_inode
    CALL exec_puts
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    ; Save root inode for later block walk
    LD   A, E
    LD   (cmd_st_inode), A
    LD   A, D
    LD   (cmd_st_inode + 1), A
    ; Print as hex16
    PUSH HL
    EX   DE, HL
    CALL exec_print_hex16
    POP  HL
    CALL exec_crlf

    ; --- File Size (HND_OFF_FILESIZE = 3, 3 bytes LE) ---
    LD   DE, msg_st_filesize
    CALL exec_puts
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    LD   C, (HL)
    INC  HL
    ; Print as 00CC DDEE (zero-extend MSB to 4 bytes)
    PUSH HL
    LD   H, 0
    LD   L, C
    CALL exec_print_hex16
    POP  HL
    PUSH HL
    EX   DE, HL
    CALL exec_print_hex16
    POP  HL
    CALL exec_crlf

    ; --- Block Position (HND_OFF_POS = 6, 2 bytes LE) ---
    LD   DE, msg_st_pos
    CALL exec_puts
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    PUSH HL
    EX   DE, HL
    CALL exec_print_hex16
    POP  HL
    CALL exec_crlf

    ; --- Span First PBA (HND_OFF_SPAN_FIRST = 8, 2 bytes LE) ---
    LD   DE, msg_st_span_first
    CALL exec_puts
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    PUSH HL
    EX   DE, HL
    CALL exec_print_hex16
    POP  HL
    CALL exec_crlf

    ; --- Span Last PBA (HND_OFF_SPAN_LAST = 10, 2 bytes LE) ---
    LD   DE, msg_st_span_last
    CALL exec_puts
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    PUSH HL
    EX   DE, HL
    CALL exec_print_hex16
    POP  HL
    CALL exec_crlf

    ; --- Span LBA Offset (HND_OFF_SPAN_LBA_OFF = 12, 2 bytes LE) ---
    LD   DE, msg_st_span_lbaoff
    CALL exec_puts
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    PUSH HL
    EX   DE, HL
    CALL exec_print_hex16
    POP  HL
    CALL exec_crlf

    ; 7. Print header for block list
    LD   DE, msg_st_blocks
    CALL exec_puts

    ; 8. Walk the inode chain and print each span
cmd_st_inode_loop:
    ; Seek block device to inode block
    LD   HL, (cmd_st_inode)
    LD   A, (cmd_st_blk_dev)
    LD   B, A
    EX   DE, HL                         ; DE = block number
    LD   C, DEV_BSEEK
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_st_io_error

    ; Read inode block into DISK_BUFFER
    LD   A, (cmd_st_blk_dev)
    LD   B, A
    LD   DE, DISK_BUFFER
    LD   C, DEV_BREAD
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_st_io_error

    ; Read span count (INODE_OFF_COUNT = 0)
    LD   HL, DISK_BUFFER + CMD_ST_INODE_COUNT
    LD   B, (HL)                        ; B = span count for this inode

    ; Read next inode block ptr (CMD_ST_INODE_NEXT = 2, 2 bytes LE)
    LD   HL, DISK_BUFFER + CMD_ST_INODE_NEXT
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    ; Save next inode block (0 = no more inodes)
    LD   A, E
    LD   (cmd_st_inode), A
    LD   A, D
    LD   (cmd_st_inode + 1), A

    ; Point HL to spans array (CMD_ST_INODE_SPANS = 8)
    LD   HL, DISK_BUFFER + CMD_ST_INODE_SPANS

    ; Print each span: "  FFFF-LLLL\r\n"
cmd_st_span_loop:
    LD   A, B
    OR   A
    JP   Z, cmd_st_spans_done

    ; Print "  " indent (preserving B = span counter)
    PUSH BC
    LD   DE, msg_st_indent
    CALL exec_puts
    POP  BC

    ; Read first block (2 bytes LE) from spans array
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    ; Print first block as hex16
    PUSH HL                             ; save spans array ptr
    EX   DE, HL
    CALL exec_print_hex16               ; preserves BC
    POP  HL                             ; restore spans array ptr

    ; Print '-'
    LD   A, '-'
    CALL exec_print_char                ; preserves BC

    ; Read last block (2 bytes LE) from spans array
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    ; Print last block as hex16 then CRLF
    PUSH HL                             ; save spans array ptr
    PUSH BC                             ; save span counter (exec_crlf clobbers B)
    EX   DE, HL
    CALL exec_print_hex16               ; preserves BC
    CALL exec_crlf                      ; clobbers B
    POP  BC                             ; restore span counter
    POP  HL                             ; restore spans array ptr

    DEC  B
    JP   cmd_st_span_loop

cmd_st_spans_done:
    ; If next inode is non-zero, continue with next inode block
    LD   HL, (cmd_st_inode)
    LD   A, H
    OR   L
    JP   NZ, cmd_st_inode_loop

cmd_st_done:
    ; Close file handle if open
    LD   A, (cmd_st_handle)
    OR   A
    JP   Z, cmd_st_exit
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    XOR  A
    LD   (cmd_st_handle), A
cmd_st_exit:
    RET

cmd_st_usage:
    LD   DE, msg_st_usage
    CALL exec_puts
    RET

cmd_st_open_error:
cmd_st_io_error:
    CALL exec_print_error
    JP   cmd_st_done

msg_st_usage:      DEFM "Usage: STAT <filename>", 0x0D, 0x0A, 0
msg_st_flags:      DEFM "Flags:      0x", 0
msg_st_root_inode: DEFM "Root Inode: 0x", 0
msg_st_filesize:   DEFM "File Size:  0x", 0
msg_st_pos:        DEFM "Blk Pos:    0x", 0
msg_st_span_first: DEFM "Span First: 0x", 0
msg_st_span_last:  DEFM "Span Last:  0x", 0
msg_st_span_lbaoff: DEFM "Span Off:   0x", 0
msg_st_blocks:     DEFM "Blocks:", 0x0D, 0x0A, 0
msg_st_indent:     DEFM "  ", 0

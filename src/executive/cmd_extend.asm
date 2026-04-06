; ============================================================
; cmd_extend.asm - EXTEND command handler
; ============================================================
; XE / EXTEND filename
;   Load a kernel extension into low memory and execute it.
;   Uses SYS_EXEC (B=handle, DE=load_addr) to read, relocate,
;   and jump to the extension.  The extension calls SYS_EXIT
;   to return to the executive.
;
; Extensions load at DYNAMIC_MEMBOT and grow upward.  Before
; calling SYS_EXEC, DYNAMIC_MEMBOT is set to
; load_addr + 2 + code_length, discarding the relocation
; trailer and the 2-byte code_length prefix.  To learn
; code_length before SYS_EXEC (which does not return on
; success), the first block is read directly into the load
; address, code_length extracted, the file seeked back to
; block 0, and then SYS_EXEC overwrites from the beginning.
;
; Scratch space at EXEC_RAM_START:
;   +0: file handle (1 byte)
;   +1: load address (2 bytes)

cmd_extend_handle    EQU EXEC_RAM_START
cmd_extend_loadaddr  EQU EXEC_RAM_START + 1

; ------------------------------------------------------------
; cmd_extend: Handle XE / EXTEND command
; ------------------------------------------------------------
cmd_extend:
    ; 1. Get filename from arguments
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, cmd_extend_usage

    ; Upcase the filename in place
    CALL exec_upcase_delimit

    ; 2. Open file using SYS_GLOBAL_OPENFILE (handles path resolution)
    LD   HL, (EXEC_ARGS_PTR)
    LD   D, H
    LD   E, L
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_extend_err

    ; 3. Save handle and load_addr, then read first block into
    ;    the load address to extract code_length.
    LD   A, L
    LD   (cmd_extend_handle), A
    LD   DE, (DYNAMIC_MEMBOT)
    LD   (cmd_extend_loadaddr), DE
    LD   B, L                   ; B = file handle
    LD   C, DEV_BREAD           ; DE = load_addr (DYNAMIC_MEMBOT)
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_extend_close_err

    ; Extract code_length from first 2 bytes at load_addr
    LD   HL, (cmd_extend_loadaddr)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = code_length
    LD   A, D
    OR   E
    JP   Z, cmd_extend_empty

    ; 4. Seek back to block 0
    LD   A, (cmd_extend_handle)
    LD   B, A
    PUSH DE                     ; save code_length
    LD   DE, 0
    LD   C, DEV_BSEEK
    CALL KERNELADDR
    POP  DE                     ; DE = code_length

    ; 5. Set DYNAMIC_MEMBOT = load_addr + 2 + code_length.
    ;    Must do this before SYS_EXEC because SYS_EXIT
    ;    jumps to exec_main (we never get control back).
    ;    This discards the 2-byte prefix and relocation trailer.
    LD   HL, (cmd_extend_loadaddr)
    INC  HL
    INC  HL                     ; HL = load_addr + 2
    ADD  HL, DE                 ; HL = load_addr + 2 + code_length
    LD   (DYNAMIC_MEMBOT), HL

    ; 6. Call SYS_EXEC: B=handle, DE=load_addr
    LD   A, (cmd_extend_handle)
    LD   B, A
    LD   DE, (cmd_extend_loadaddr)
    LD   C, SYS_EXEC
    CALL KERNELADDR

    ; If we get here, SYS_EXEC failed (file already closed by kernel).
    ; Roll back DYNAMIC_MEMBOT.
    LD   DE, (cmd_extend_loadaddr)
    LD   (DYNAMIC_MEMBOT), DE
    CALL exec_print_error
    RET

; --- Error paths (all can RET normally) ---

cmd_extend_usage:
    LD   DE, msg_extend_usage
    CALL exec_puts
    RET

cmd_extend_empty:
    LD   DE, msg_extend_empty
    JP   cmd_extend_close_msg

cmd_extend_close_msg:
    ; DE = message to print after closing
    PUSH DE
    LD   A, (cmd_extend_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    POP  DE
    CALL exec_puts
    RET

cmd_extend_close_err:
    ; Close file, then print error code in A
    PUSH AF
    LD   A, (cmd_extend_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    POP  AF
cmd_extend_err:
    CALL exec_print_error
    RET

msg_extend_usage:   DEFM "Usage: EXTEND filename", 0x0D, 0x0A, 0
msg_extend_empty:   DEFM "File is empty.", 0x0D, 0x0A, 0

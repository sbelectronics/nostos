; ============================================================
; cmd_play.asm - PL / PLAY command (batch file executor)
; ============================================================

play_buffer     EQU EXEC_RAM_START        ; 512 bytes (safe: read before any command runs)

; ------------------------------------------------------------
; cmd_play
; Open a script file and begin batch execution.
; Each line is fed to exec_parse_and_run as if typed interactively.
; Inputs:
;   EXEC_ARGS_PTR - pointer to filename argument
; Outputs:
;   Sets PLAY_HANDLE/PLAY_BLOCK/PLAY_OFFSET for exec_main_loop.
; ------------------------------------------------------------
cmd_play:
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, cmd_play_usage

    ; If PLAY already active, close old handle first
    LD   A, (PLAY_HANDLE)
    OR   A
    JP   Z, cmd_play_open
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    XOR  A
    LD   (PLAY_HANDLE), A

cmd_play_open:
    ; Open the file via SYS_GLOBAL_OPENFILE (handles device/path resolution)
    LD   HL, (EXEC_ARGS_PTR)
    EX   DE, HL                 ; DE = path string
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_play_error

    ; HL = file handle device ID
    LD   A, L
    LD   (PLAY_HANDLE), A

    ; Initialize position to start of file
    LD   HL, 0
    LD   (PLAY_BLOCK), HL
    LD   (PLAY_OFFSET), HL
    RET

cmd_play_error:
    CALL exec_print_error
    RET

cmd_play_usage:
    LD   DE, msg_play_usage
    CALL exec_puts
    RET

msg_play_usage:
    DEFM "Usage: PLAY <filename>", 0x0D, 0x0A, 0

; ------------------------------------------------------------
; play_read_line
; Read the next line from the PLAY script file into INPUT_BUFFER.
; Seeks and reads one block at a time from the file, scanning
; for LF (line terminator) or null bytes (EOF in padding).
; CR bytes are silently dropped to handle CR+LF line endings.
; Inputs:
;   PLAY_HANDLE, PLAY_BLOCK, PLAY_OFFSET must be valid
; Outputs:
;   A  - 0 if line read successfully, non-zero if EOF/error
;   INPUT_BUFFER contains the null-terminated line
; ------------------------------------------------------------
play_read_line:
    LD   DE, INPUT_BUFFER       ; DE = write pointer

play_rl_load:
    ; Seek to current block
    PUSH DE                     ; save write ptr
    LD   A, (PLAY_HANDLE)
    LD   B, A
    LD   HL, (PLAY_BLOCK)
    EX   DE, HL                 ; DE = block number
    LD   C, DEV_BSEEK
    CALL KERNELADDR
    OR   A
    JP   NZ, play_rl_error_pop

    ; Read block into temp buffer
    LD   A, (PLAY_HANDLE)
    LD   B, A
    LD   DE, play_buffer
    LD   C, DEV_BREAD
    CALL KERNELADDR
    POP  DE                     ; restore write ptr
    CP   ERR_EOF
    JP   Z, play_rl_eof
    OR   A
    JP   NZ, play_rl_error      ; real I/O error: report and abort

    ; Set up source pointer: HL = play_buffer + PLAY_OFFSET
    LD   HL, (PLAY_OFFSET)
    LD   BC, play_buffer
    ADD  HL, BC                 ; HL = &play_buffer[offset]

    ; Compute remaining bytes in block: BC = 512 - PLAY_OFFSET
    PUSH HL                     ; save source ptr
    LD   HL, (PLAY_OFFSET)
    LD   B, H
    LD   C, L
    LD   A, 0
    SUB  C
    LD   C, A
    LD   A, 2
    SBC  A, B
    LD   B, A                   ; BC = 512 - offset
    POP  HL                     ; restore source ptr

play_rl_scan:
    ; HL = source ptr, DE = dest ptr, BC = remaining bytes in block
    LD   A, B
    OR   C
    JP   Z, play_rl_next_block  ; block exhausted mid-line

    LD   A, (HL)
    OR   A
    JP   Z, play_rl_eof         ; null byte = end of file content
    CP   0x0D
    JP   Z, play_rl_skip_cr         ; silently drop CR (LF is the line terminator)
    CP   0x0A
    JP   Z, play_rl_eol

    ; Regular character: store and advance
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  BC
    JP   play_rl_scan

play_rl_skip_cr:
    ; Skip CR: advance source without storing
    INC  HL
    DEC  BC
    JP   play_rl_scan

play_rl_eol:
    ; Line terminator found. Skip past it and update PLAY state.
    DEC  BC                     ; consumed the terminator byte

    ; Compute new offset = 512 - remaining (BC)
    PUSH DE                     ; save write ptr
    LD   A, 0
    SUB  C
    LD   E, A
    LD   A, 2
    SBC  A, B
    LD   D, A                   ; DE = 512 - BC = new offset
    EX   DE, HL                 ; HL = new offset
    LD   (PLAY_OFFSET), HL
    POP  DE                     ; restore write ptr

    ; If remaining (BC) is 0, we consumed the last byte of the block
    LD   A, B
    OR   C
    JP   NZ, play_rl_term

    ; At block boundary: advance to next block, reset offset
    LD   HL, 0
    LD   (PLAY_OFFSET), HL
    LD   HL, (PLAY_BLOCK)
    INC  HL
    LD   (PLAY_BLOCK), HL

play_rl_term:
    ; Null-terminate the line and return success
    LD   A, 0
    LD   (DE), A
    XOR  A                      ; A = 0 = success
    RET

play_rl_next_block:
    ; Line spans block boundary. Advance to next block and continue.
    LD   HL, (PLAY_BLOCK)
    INC  HL
    LD   (PLAY_BLOCK), HL
    LD   HL, 0
    LD   (PLAY_OFFSET), HL
    JP   play_rl_load           ; read next block, continue scanning

play_rl_eof:
    ; EOF or read error. Null-terminate whatever we have.
    LD   A, 0
    LD   (DE), A

    ; If we collected any characters, return this last line.
    ; Close the handle now so next call goes to interactive mode.
    LD   HL, INPUT_BUFFER
    LD   A, (HL)
    OR   A
    JP   Z, play_rl_eof_empty

    ; Have content: close handle, return success for this last line
    PUSH DE
    LD   A, (PLAY_HANDLE)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    XOR  A
    LD   (PLAY_HANDLE), A
    POP  DE
    XOR  A                      ; A = 0 = success (line available)
    RET

play_rl_eof_empty:
    ; No content: return EOF indicator
    LD   A, 1                   ; A != 0 = EOF
    RET

play_rl_error_pop:
    POP  DE                     ; clean up stacked write ptr
play_rl_error:
    ; I/O error during BSEEK/BREAD. Print error, close handle, abort playback.
    CALL exec_print_error       ; A = error code
    LD   A, (PLAY_HANDLE)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    XOR  A
    LD   (PLAY_HANDLE), A
    LD   A, 1                   ; A != 0 = error/EOF
    RET

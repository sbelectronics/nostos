; ------------------------------------------------------------
; Misc Syscall Implementations
; ------------------------------------------------------------

; ------------------------------------------------------------
; sys_exit
; Exit the user program and restart the executive.
; Inputs:
;   (none)
; Outputs:
;   (does not return)
; ------------------------------------------------------------
sys_exit:
    LD   HL, (DYNAMIC_MEMTOP)
    INC  HL
    LD   SP, HL                 ; SP = DYNAMIC_MEMTOP + 1 (stack grows down from top of free memory)
    JP   exec_main              ; restart executive

; ------------------------------------------------------------
; sys_info
; Fill a 64-byte buffer with system information.
; See specification/README.md for SYS_INFO buffer layout.
; Inputs:
;   DE - pointer to 64-byte destination buffer
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
sys_info:
    LD   H, D
    LD   L, E                   ; HL = buffer pointer
    ; Major, minor, patch version
    LD   (HL), NOSTOS_VER_MAJOR
    INC  HL
    LD   (HL), NOSTOS_VER_MINOR
    INC  HL
    LD   (HL), NOSTOS_VER_PATCH
    INC  HL
    ; Build date: year (2 bytes), month, day
    LD   (HL), NOSTOS_BUILD_YEAR & 0xFF
    INC  HL
    LD   (HL), NOSTOS_BUILD_YEAR >> 8
    INC  HL
    LD   (HL), NOSTOS_BUILD_MONTH
    INC  HL
    LD   (HL), NOSTOS_BUILD_DAY
    INC  HL
    ; Kernel size (2 bytes)
    LD   (HL), kernel_size & 0xFF
    INC  HL
    LD   (HL), kernel_size >> 8
    ; Remaining bytes are already zeroed (workspace_init zeroed everything;
    ; for user programs this buffer is in their own space so zero-fill
    ; via the caller's responsibility)
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; sys_get_cwd
; Copy the current device index and directory path into a buffer.
; Buffer layout: 1 byte device index, then null-terminated path.
; Inputs:
;   DE - pointer to destination buffer (min 33 bytes)
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
sys_get_cwd:
    PUSH DE                     ; preserve DE (caller's buffer pointer)
    LD   H, D
    LD   L, E                   ; HL = destination buffer
    LD   A, (CUR_DEVICE)
    LD   (HL), A
    INC  HL
    LD   DE, CUR_DIR
    CALL strcpy                 ; copy null-terminated directory string
    XOR  A
    LD   H, A
    LD   L, A
    POP  DE                     ; restore DE
    RET

; ------------------------------------------------------------
; sys_set_cwd
; Resolve a pathname and change the current directory.
; Validates the directory exists before updating CUR_DEVICE
; and CUR_DIR.  No-arg (bare "/") goes to root of current device.
; Inputs:
;   DE - pointer to null-terminated pathname string
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - 0
; ------------------------------------------------------------
sys_set_cwd:
    PUSH BC
    PUSH DE
    CALL path_parse             ; A=status, B=device_id, DE=path_component
    OR   A
    JP   NZ, sys_set_cwd_err

    ; Open the directory to validate it exists
    PUSH BC                     ; save B=device_id across call
    PUSH DE                     ; save path_component across call
    CALL sys_dev_dopen          ; B=device_id, DE=path_component; A=status, HL=dir_handle
    POP  DE                     ; restore path_component
    POP  BC                     ; restore B=device_id
    OR   A
    JP   NZ, sys_set_cwd_err

    ; Close the handle (only needed for existence check)
    PUSH BC
    PUSH DE
    LD   B, L                   ; B = dir handle
    CALL sys_dev_close
    POP  DE
    POP  BC

    ; Update CUR_DEVICE
    LD   A, B
    LD   (CUR_DEVICE), A

    ; Update CUR_DIR: if path component is empty, store "/"
    LD   A, (DE)
    OR   A
    JP   NZ, sys_set_cwd_copy
    LD   HL, CUR_DIR
    LD   (HL), '/'
    INC  HL
    LD   (HL), 0
    JP   sys_set_cwd_ok

sys_set_cwd_copy:
    ; Copy path component to CUR_DIR, capped at 31 chars + null
    LD   H, D
    LD   L, E                   ; HL = src (path component)
    LD   DE, CUR_DIR            ; DE = dst
    LD   C, 31                  ; max chars before forced null
sys_set_cwd_copy_loop:
    LD   A, (HL)
    LD   (DE), A
    OR   A
    JP   Z, sys_set_cwd_ok
    INC  HL
    INC  DE
    DEC  C
    JP   NZ, sys_set_cwd_copy_loop
    LD   (DE), 0                ; truncated: force null terminator

sys_set_cwd_ok:
    XOR  A
    LD   H, A
    LD   L, A
    POP  DE
    POP  BC
    RET

sys_set_cwd_err:
    LD   HL, 0
    POP  DE
    POP  BC
    RET                         ; A = error code already set

; ------------------------------------------------------------
; sys_get_cmdline
; Return the address of the executive input buffer.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_SUCCESS
;   HL - pointer to INPUT_BUFFER
; ------------------------------------------------------------
sys_get_cmdline:
    LD   HL, INPUT_BUFFER
    XOR  A
    RET

; ------------------------------------------------------------
; sys_memtop
; Return the address of the top of user program memory.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_SUCCESS
;   HL - top of user memory address
; ------------------------------------------------------------
sys_memtop:
    LD   HL, (DYNAMIC_MEMTOP)
    XOR  A
    RET

; ------------------------------------------------------------
; sys_set_membot
; Set the bottom of user program memory.  Used by kernel
; extensions to make themselves resident: the extension sets
; DYNAMIC_MEMBOT past its own code before calling SYS_EXIT,
; so subsequent programs load above it.
; Inputs:
;   DE - new DYNAMIC_MEMBOT value
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
sys_set_membot:
    LD   (DYNAMIC_MEMBOT), DE
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; sys_exec
; Load a relocatable executable and transfer control to it.
; The caller (executive) opens the file and passes the handle.
; File format:
;   [code_length:2][program binary, ORG 0][reloc_count:2][reloc_entries:2*N]
; Inputs:
;   B  - open file handle
;   DE - load address (where the file will be read)
; Outputs:
;   Does not return on success (jumps to loaded program)
;   A  - error code on failure
;   HL - 0
; Scratch:
;   SYS_EXEC_STATE (8 bytes, dedicated workspace outside KERN_TEMP_SPACE)
; ------------------------------------------------------------

sys_exec_load_addr  EQU SYS_EXEC_STATE + 0      ; 2 bytes
sys_exec_prog_base  EQU SYS_EXEC_STATE + 2      ; 2 bytes
sys_exec_reloc_cnt  EQU SYS_EXEC_STATE + 4      ; 2 bytes
sys_exec_reloc_ptr  EQU SYS_EXEC_STATE + 6      ; 2 bytes

sys_exec:
    ; Save load address
    LD   (sys_exec_load_addr), DE

    ; 1. Read file blocks into memory at DE
    LD   H, D
    LD   L, E                   ; HL = load pointer
sys_exec_read_loop:
    PUSH BC                     ; save B=handle
    PUSH HL                     ; save load pointer
    LD   D, H
    LD   E, L                   ; DE = destination for this block
    CALL sys_dev_bread          ; B=handle, DE=dest
    POP  HL                     ; restore load pointer
    POP  BC                     ; restore B=handle
    CP   ERR_EOF
    JP   Z, sys_exec_loaded
    OR   A
    JP   NZ, sys_exec_io_err
    LD   DE, 512
    ADD  HL, DE                 ; advance by one block
    JP   sys_exec_read_loop

sys_exec_loaded:
    ; 2. Close file handle
    CALL sys_dev_close

    ; 3. Compute program_base = load_addr + 2
    LD   HL, (sys_exec_load_addr)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = code_length
    INC  HL                     ; HL = load_addr + 2 = program_base
    LD   (sys_exec_prog_base), HL

    ; 4. Locate relocation table = program_base + code_length
    ADD  HL, DE                 ; HL = reloc table start
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = reloc_count
    INC  HL                     ; HL = first reloc entry
    LD   (sys_exec_reloc_cnt), DE
    LD   (sys_exec_reloc_ptr), HL

    ; 5. Apply relocations
sys_exec_reloc_loop:
    LD   HL, (sys_exec_reloc_cnt)
    LD   A, H
    OR   L
    JP   Z, sys_exec_reloc_done
    DEC  HL
    LD   (sys_exec_reloc_cnt), HL

    ; Read offset from reloc table
    LD   HL, (sys_exec_reloc_ptr)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = offset within program
    INC  HL
    LD   (sys_exec_reloc_ptr), HL

    ; target = program_base + offset
    LD   HL, (sys_exec_prog_base)
    ADD  HL, DE                 ; HL = target address

    ; Read 16-bit value at target
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = original value
    PUSH HL                     ; save target+1

    ; Add program_base to value
    LD   HL, (sys_exec_prog_base)
    ADD  HL, DE                 ; HL = relocated value

    ; Write back
    POP  DE                     ; DE = target+1
    LD   A, H
    LD   (DE), A                ; write high byte
    DEC  DE
    LD   A, L
    LD   (DE), A                ; write low byte

    JP   sys_exec_reloc_loop

sys_exec_reloc_done:
    ; 6. Jump to program_base with HL = program_base
    LD   HL, (sys_exec_prog_base)
    JP   (HL)

sys_exec_io_err:
    ; Read failed; close handle and return error
    PUSH AF                     ; save error code
    CALL sys_dev_close          ; B still holds file handle
    POP  AF                     ; restore error code
    LD   HL, 0
    RET
; ------------------------------------------------------------
; Device I/O Syscall Implementations
; Resolve device B to a physical entry then dispatch via the DFT.
; ------------------------------------------------------------

; ------------------------------------------------------------
; sys_dev_init
; Initialise a device.
; Inputs:
;   B  - device ID
;   DE - (device-specific)
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_init:
    LD   A, FNIDX_INITIALIZE
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_stat
; Get device status.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_stat:
    LD   A, FNIDX_GETSTATUS
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_cread_raw
; Read one byte from a character device without echo.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - status, HL - character (L = byte, H = 0)
; ------------------------------------------------------------
sys_dev_cread_raw:
_dev_cread_byte:
    LD   A, FNIDX_READBYTE
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_cread
; Read one byte from a character device with echo.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - status, HL - character (L = byte, H = 0)
; ------------------------------------------------------------
sys_dev_cread:
    PUSH BC                     ; preserve BC (B=device, C=fn#)
    LD   A, FNIDX_READBYTE
    CALL resolve_and_call       ; A=status, HL=char
    POP  BC                     ; restore BC
    OR   A
    JP   NZ, sys_dev_cread_exit
    ; Echo the character back to the same device
    PUSH BC                     ; preserve BC
    PUSH HL                     ; preserve HL (character)
    LD   E, L                   ; E = character
    CALL _dev_cwrite_byte
    POP  HL                     ; restore HL = character
    XOR  A
    POP  BC                     ; restore BC
sys_dev_cread_exit:
    RET

; ------------------------------------------------------------
; sys_dev_cwrite
; Write one byte to a character device.
; Inputs:
;   B  - device ID
;   DE - E = byte to write
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_cwrite:
_dev_cwrite_byte:
    LD   A, FNIDX_WRITEBYTE
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_cwrite_str
; Write a null-terminated string to a character device.
; Inputs:
;   B  - device ID
;   DE - pointer to null-terminated string
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
sys_dev_cwrite_str:
    PUSH BC                     ; save caller's BC (B = device ID)
sys_dev_cwrite_str_loop:
    LD   A, (DE)
    OR   A
    JP   Z, sys_dev_cwrite_str_done
    POP  BC                     ; restore B = device ID
    PUSH BC                     ; re-save
    PUSH DE                     ; save string ptr
    LD   E, A                   ; E = character to write
    CALL _dev_cwrite_byte
    POP  DE                     ; restore string ptr
    INC  DE
    JP   sys_dev_cwrite_str_loop
sys_dev_cwrite_str_done:
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; sys_dev_cread_str
; Read a line from the console into a buffer (blocking).
; Terminates on CR or LF; handles backspace (0x08) and DEL (0x7F).
; Inputs:
;   B  - device ID
;   DE - pointer to 256-byte destination buffer
; Outputs:
;   A  - ERR_SUCCESS
;   HL - number of characters read (max 255, excluding null terminator)
; ------------------------------------------------------------
sys_dev_cread_str:
    PUSH BC                     ; preserve BC (B=device, C=fn#)
    PUSH DE                     ; preserve DE (caller's buffer pointer)
    LD   H, D
    LD   L, E                   ; HL = current write position in buffer
    LD   BC, 0                  ; BC = char count (internal; clobbers caller's BC)

sys_dev_cread_str_loop:
    ; Read a raw character (no auto-echo).
    PUSH HL                     ; save write ptr
    PUSH BC                     ; save count
    LD   B, LOGDEV_ID_CONI
    CALL _dev_cread_byte        ; HL = char (L = byte)
    POP  BC                     ; restore count
    POP  DE                     ; restore write ptr (was pushed as HL)
    LD   A, L                   ; A = character

    CP   0x0D                   ; CR -> end of line
    JP   Z, sys_dev_cread_str_done
    CP   0x0A                   ; LF -> end of line
    JP   Z, sys_dev_cread_str_done

    CP   0x08                   ; BS
    JP   Z, sys_dev_cread_str_bs
    CP   0x7F                   ; DEL (sent by many terminals as backspace)
    JP   Z, sys_dev_cread_str_bs

    ; Printable (or other) character: echo it, then store.
    PUSH DE                     ; save write ptr
    PUSH BC                     ; save count
    PUSH AF                     ; save character
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    CALL _dev_cwrite_byte
    POP  AF                     ; restore A = character
    POP  BC
    POP  DE

    LD   (DE), A                ; store in buffer
    INC  DE
    INC  BC
    LD   H, D
    LD   L, E                   ; HL = new write ptr
    LD   A, C
    CP   0xFF                   ; 255-char buffer limit
    JP   NZ, sys_dev_cread_str_loop

sys_dev_cread_str_done:
    LD   (DE), 0                ; null terminate
    LD   H, B
    LD   L, C                   ; HL = char count (captured before restoring caller's BC)
    XOR  A
    POP  DE                     ; restore caller's DE
    POP  BC                     ; restore caller's BC
    RET

sys_dev_cread_str_bs:
    ; Ignore backspace if the buffer is already empty.
    LD   A, B
    OR   C
    JP   Z, sys_dev_cread_str_bs_done

    ; Send BS SP BS to visually erase the character from the terminal.
    PUSH DE                     ; save write ptr
    PUSH BC                     ; save count
    LD   E, 0x08
    LD   B, LOGDEV_ID_CONO
    CALL _dev_cwrite_byte
    LD   E, ' '
    LD   B, LOGDEV_ID_CONO
    CALL _dev_cwrite_byte
    LD   E, 0x08
    LD   B, LOGDEV_ID_CONO
    CALL _dev_cwrite_byte
    POP  BC
    POP  DE

    DEC  DE                     ; back up write ptr one byte
    DEC  BC                     ; decrement 16-bit count

sys_dev_cread_str_bs_done:
    LD   H, D
    LD   L, E                   ; HL = write ptr for next iteration
    JP   sys_dev_cread_str_loop

; ------------------------------------------------------------
; sys_dev_bread
; Read one block from a block device.
; Inputs:
;   B  - device ID
;   DE - pointer to block buffer
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_bread:
    LD   A, FNIDX_READBLOCK
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_bwrite
; Write one block to a block device.
; Inputs:
;   B  - device ID
;   DE - pointer to block buffer
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_bwrite:
    LD   A, FNIDX_WRITEBLOCK
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_bseek
; Seek to a block number on a device.
; Inputs:
;   B  - device ID
;   DE - block number (16-bit, 0-based)
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_bseek:
    LD   A, FNIDX_SEEK
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_bsetsize
; Set the file size of an open file handle.
; Inputs:
;   B  - device ID (file handle)
;   DE - pointer to 4-byte new size in bytes (little-endian)
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_bsetsize:
    LD   A, FNIDX_SETSIZE
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_fopen
; Open a file by name on a filesystem device.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated filename
; Outputs:
;   A  - status
;   HL - physical device ID of the opened file pseudo-device
; ------------------------------------------------------------
sys_dev_fopen:
    LD   A, FNIDX_OPENFILE
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_close
; Close an open file or directory handle.
; Only calls the driver's Close function if the PDT entry has
; DEVCAP_HANDLE set; otherwise returns success (no-op for raw
; character/block devices).
; Inputs:
;   B  - physical device ID of file/directory handle
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_close:
    PUSH BC
    PUSH DE
    LD   A, B
    CALL find_physdev_by_id     ; HL = PDT entry or 0
    LD   A, H
    OR   L
    JP   Z, sys_dev_close_noop
    LD   DE, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  DEVCAP_HANDLE
    JP   Z, sys_dev_close_noop
    POP  DE
    POP  BC
    LD   A, FNIDX_CLOSE
    JP   resolve_and_call
sys_dev_close_noop:
    XOR  A
    LD   H, A
    LD   L, A
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; sys_dev_fcreate
; Create a new file on a filesystem device.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated filename
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_fcreate:
    LD   A, FNIDX_CREATEFILE
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_fremove
; Remove a file from a filesystem device.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated filename
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_fremove:
    LD   A, FNIDX_REMOVE
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_frename
; Rename a file on a filesystem device.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to a pair of pointers {src name ptr, dst name ptr}
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_frename:
    LD   A, FNIDX_RENAME
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_dcreate
; Create a directory on a filesystem device.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated directory name
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_dcreate:
    LD   A, FNIDX_CREATEDIR
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_dopen
; Open a directory on a filesystem device.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated directory name
; Outputs:
;   A  - status, HL - return value (from driver)
; ------------------------------------------------------------
sys_dev_dopen:
    LD   A, FNIDX_OPENDIR
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_phys_get
; Return a pointer to the physical device entry for a given ID.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - pointer to physical device entry, or 0 on error
; ------------------------------------------------------------
sys_dev_phys_get:
    LD   A, B
    CALL find_physdev_by_id     ; HL = entry pointer or 0
    LD   A, H
    OR   L
    JP   Z, sys_err_invalid_device
    XOR  A
    RET

; ------------------------------------------------------------
; sys_dev_bgetsize
; Get the file size of an open file handle.
; Inputs:
;   B  - device ID (file handle)
;   DE - pointer to 4-byte buffer for the size in bytes (little-endian)
; Outputs:
;   A  - status (ERR_SUCCESS or error code)
; ------------------------------------------------------------
sys_dev_bgetsize:
    LD   A, FNIDX_GETLENGTH
    JP   resolve_and_call

; ------------------------------------------------------------
; sys_dev_bgetpos
; Get the current block position of a device.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - status, HL - block position (from driver)
; ------------------------------------------------------------
sys_dev_bgetpos:
    LD   A, FNIDX_GETPOSITION
    JP   resolve_and_call

; ------------------------------------------------------------
; common_bgetpos
; Read a 2-byte block position from a PDT entry's user data.
; Intended to be called by DFT GetPosition slot implementations.
; Inputs:
;   B  - physical device ID
;   DE - offset from start of PDT entry to position field
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - block position (2 bytes, little-endian)
; Preserves: BC, DE
; ------------------------------------------------------------
common_bgetpos:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id     ; HL = PDT entry or 0
    LD   A, H
    OR   L
    JP   Z, common_bgetpos_err
    ADD  HL, DE                 ; HL = &position field
    LD   A, (HL)
    INC  HL
    LD   H, (HL)
    LD   L, A                   ; HL = position (little-endian)
    POP  DE
    POP  BC
    XOR  A                      ; A = ERR_SUCCESS
    RET
common_bgetpos_err:
    POP  DE
    POP  BC
    LD   A, ERR_INVALID_DEVICE
    LD   HL, 0
    RET

; ------------------------------------------------------------
; sys_dev_free
; Get the number of free blocks on a filesystem device.
; Inputs:
;   B  - filesystem device ID
; Outputs:
;   A  - status, HL - free block count (from driver)
; ------------------------------------------------------------
sys_dev_free:
    LD   A, FNIDX_FREECOUNT
    JP   resolve_and_call


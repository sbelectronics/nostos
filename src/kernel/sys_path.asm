; ============================================================
; sys_path.asm - Pathname Resolution Syscalls
; ============================================================
;
; path_parse: internal helper that splits a pathname string
; into a device ID and a path component.
;
; Supported formats:
;   "name"             -> CUR_DEVICE, prepend CUR_DIR if no '/'
;   "device:name"      -> named device, absolute path
;   "device:/abs/name" -> named device, absolute path
;   "device:"          -> named device, empty path (root/bare)
;   ""                 -> CUR_DEVICE, empty path
;
; Syscalls:
;   SYS_GLOBAL_OPENFILE (39) - resolve path, open file or return device ID
;   SYS_GLOBAL_OPENDIR  (40) - resolve path, open directory

; ------------------------------------------------------------
; path_parse
; Parse a pathname into a device ID and path component.
; Inputs:
;   DE - pointer to null-terminated pathname string
; Outputs:
;   A  - ERR_SUCCESS or ERR_NOT_FOUND
;   B  - device ID (if ERR_SUCCESS)
;   DE - pointer to path component string (if ERR_SUCCESS);
;        may point into PATH_WORK_PATH or into the original string;
;        always a valid null-terminated string
; Clobbers: HL
; ------------------------------------------------------------
path_parse:
    LD   H, D
    LD   L, E                   ; HL = scan pointer

    LD   B, 0                   ; B = char count for device name scan

path_parse_colon_scan:
    LD   A, (HL)
    CP   ':'
    JP   Z, path_parse_colon_found
    OR   A
    JP   Z, path_parse_no_device
    INC  HL
    INC  B
    LD   A, B
    CP   7                      ; max 6-char device name
    JP   NC, path_parse_no_device
    JP   path_parse_colon_scan

path_parse_colon_found:
    ; HL = ':' position; B = device name length; DE = original string start
    PUSH HL                     ; save ':' pointer

    ; Copy device name (B bytes from DE) to PATH_WORK_DEVNAME
    LD   HL, PATH_WORK_DEVNAME
    LD   C, B                   ; C = char count
    LD   A, C
    OR   A
    JP   Z, path_parse_devname_nullterm
path_parse_devname_copy:
    LD   A, (DE)
    LD   (HL), A
    INC  HL
    INC  DE
    DEC  C
    JP   NZ, path_parse_devname_copy
path_parse_devname_nullterm:
    LD   (HL), 0                ; null-terminate device name

    POP  HL                     ; HL = ':' pointer
    INC  HL                     ; HL = char after ':'
    LD   D, H
    LD   E, L                   ; DE = path component (after ':')

    ; Look up device by name
    PUSH DE                     ; save path component
    LD   DE, PATH_WORK_DEVNAME
    CALL sys_dev_lookup         ; DE = name; A = status, HL = device ID (L = ID)
    POP  DE                     ; restore path component
    OR   A
    JP   NZ, path_parse_err
    LD   B, L                   ; B = device ID

    ; If path component is empty (bare "device:"), return pointer to empty string
    LD   A, (DE)
    OR   A
    JP   NZ, path_parse_has_path ; non-empty path after ':'
    LD   HL, PATH_WORK_PATH
    LD   (HL), 0
    LD   D, H
    LD   E, L
    XOR  A
    RET

path_parse_has_path:
    ; B = device ID, DE = path after ':'. If the device is
    ; CUR_DEVICE and the path is relative, prepend CUR_DIR.
    LD   A, (DE)
    CP   '/'
    JP   Z, path_parse_done     ; absolute path — use as-is
    LD   A, (CUR_DEVICE)
    CP   B
    JP   Z, path_parse_need_curdir ; same device — prepend CUR_DIR
    JP   path_parse_done        ; different device — use path as-is (root-relative)

path_parse_no_device:
    ; No ':' found — use CUR_DEVICE; DE = original string
    LD   A, (CUR_DEVICE)
    LD   B, A
    LD   A, (DE)
    OR   A
    JP   Z, path_parse_empty_path

    ; Non-empty path: check if absolute (starts with '/')
    LD   A, (DE)
    CP   '/'
    JP   Z, path_parse_done     ; absolute path — use as-is

    ; Fall through to prepend CUR_DIR

path_parse_need_curdir:
    PUSH BC
    PUSH DE
    ; Bare filename with no slash — prepend CUR_DIR
    POP  DE                     ; DE = bare filename
    POP  BC                     ; B = device ID
    PUSH BC
    PUSH DE                     ; save for append step

    ; Copy CUR_DIR to PATH_WORK_PATH (bounded)
    LD   HL, CUR_DIR            ; source
    LD   DE, PATH_WORK_PATH     ; destination
    LD   C, 55                  ; max chars (56-byte buffer - 1 for null)
path_parse_copy_curdir:
    LD   A, (HL)
    OR   A
    JP   Z, path_parse_curdir_done
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  C
    JP   NZ, path_parse_copy_curdir
    JP   path_parse_overflow    ; CUR_DIR alone filled the buffer
path_parse_curdir_done:

    ; Ensure trailing '/'
    DEC  DE                     ; DE = last character written
    LD   A, (DE)
    INC  DE                     ; DE = null position
    CP   '/'
    JP   Z, path_parse_append_name_setup
    LD   A, C
    OR   A
    JP   Z, path_parse_overflow ; no room for '/'
    LD   A, '/'
    LD   (DE), A
    INC  DE
    DEC  C

path_parse_append_name_setup:
    LD   H, D
    LD   L, E                   ; HL = append position in PATH_WORK_PATH
    POP  DE                     ; DE = bare filename
    LD   A, C                   ; save remaining count
    POP  BC                     ; B = device ID
    LD   C, A                   ; restore remaining count

    ; Append bare filename to PATH_WORK_PATH (bounded)
path_parse_append_name:
    LD   A, (DE)
    OR   A
    JP   Z, path_parse_appended
    LD   A, C
    OR   A
    JP   Z, path_parse_overflow_clean ; no room left
    LD   A, (DE)
    LD   (HL), A
    INC  HL
    INC  DE
    DEC  C
    JP   path_parse_append_name

path_parse_appended:
    LD   (HL), 0                ; null-terminate
    LD   DE, PATH_WORK_PATH
    XOR  A
    RET

path_parse_overflow:
    ; Stack has [DE, BC] from lines 128-129
    POP  DE
    POP  BC
    LD   A, ERR_INVALID_PARAM
    LD   HL, 0
    RET

path_parse_overflow_clean:
    ; Stack already popped at lines 164-165
    LD   A, ERR_INVALID_PARAM
    LD   HL, 0
    RET

path_parse_empty_path:
    ; Empty string with no device — use CUR_DIR as the path
    LD   HL, CUR_DIR            ; source
    LD   DE, PATH_WORK_PATH     ; destination
    CALL strcpy
    LD   DE, PATH_WORK_PATH
    XOR  A
    RET

path_parse_done:
    XOR  A
    RET

path_parse_err:
    LD   A, ERR_NOT_FOUND
    LD   HL, 0
    RET

; ------------------------------------------------------------
; sys_global_openfile
; Resolve a pathname and open the file.  If the pathname is a
; bare device name (e.g. "CF:") return the device ID directly.
; Inputs:
;   DE - pointer to null-terminated pathname string
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - file handle (physical device ID) on success,
;        or raw device ID for bare "device:", or 0 on error
; ------------------------------------------------------------
sys_global_openfile:
    PUSH BC
    PUSH DE
    CALL path_parse             ; A = status, B = device ID, DE = path component
    OR   A
    JP   NZ, sys_global_openfile_err

    LD   A, (DE)
    OR   A
    JP   Z, sys_global_openfile_bare

    ; Non-empty path: open the file
    CALL sys_dev_fopen          ; B=device_id, DE=path; A = status, HL = file handle
    JP   sys_global_openfile_done

sys_global_openfile_bare:
    ; Bare device (empty path): seek to block 0 if block device
    PUSH BC                     ; save device ID (B)
    CALL resolve_device         ; HL = PDT entry (or 0)
    LD   A, H
    OR   L
    JP   Z, sys_global_openfile_bare_done ; device not found, skip seek
    LD   DE, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  DEVCAP_FILESYSTEM
    JP   NZ, sys_global_openfile_bare_done ; filesystem device — DFT slot 4 is not seek
    LD   A, (HL)
    AND  DEVCAP_BLOCK_IN | DEVCAP_BLOCK_OUT
    JP   Z, sys_global_openfile_bare_done ; not a block device, skip seek
    POP  BC
    PUSH BC
    LD   DE, 0                  ; DE = block 0
    LD   A, FNIDX_SEEK
    CALL resolve_and_call       ; seek to beginning
    OR   A
    JP   NZ, sys_global_openfile_seek_err
sys_global_openfile_bare_done:
    POP  BC
    LD   L, B
    LD   H, 0
    XOR  A

sys_global_openfile_done:
    POP  DE
    POP  BC
    RET

sys_global_openfile_seek_err:
    POP  BC                     ; discard saved device ID
    ; A already has error code from resolve_and_call
    LD   HL, 0
    POP  DE
    POP  BC
    RET

sys_global_openfile_err:
    LD   HL, 0
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; sys_global_opendir
; Resolve a pathname and open the directory.  A bare "device:"
; or empty path opens the root directory.
; Inputs:
;   DE - pointer to null-terminated pathname string
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - directory handle (physical device ID), or 0 on error
; ------------------------------------------------------------
sys_global_opendir:
    PUSH BC
    PUSH DE
    CALL path_parse             ; A = status, B = device ID, DE = path component
    OR   A
    JP   NZ, sys_global_opendir_err

    CALL sys_dev_dopen           ; B=device_id, DE=path; A = status, HL = dir handle
    JP   sys_global_opendir_done

sys_global_opendir_err:
    LD   HL, 0

sys_global_opendir_done:
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; sys_path_parse
; Parse a pathname into a device ID and path component string,
; without opening any file or directory.
; Inputs:
;   DE - pointer to null-terminated pathname string
; Outputs:
;   A  - ERR_SUCCESS or ERR_NOT_FOUND
;   HL - resolved device ID (L = ID, H = 0) on success; 0 on error
;   DE - pointer to path component (if ERR_SUCCESS);
;        may point into PATH_WORK_PATH or the original string
; ------------------------------------------------------------
sys_path_parse:
    CALL path_parse
    OR   A
    JP   NZ, sys_path_parse_err
    LD   L, B
    LD   H, 0
    XOR  A                         ; restore A = ERR_SUCCESS
    RET
sys_path_parse_err:
    LD   HL, 0
    RET

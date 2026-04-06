; ============================================================
; Filesystem Open / Create Helpers (8080 Compatible)
; ============================================================

fs_temp_open_cur_inode EQU KERN_TEMP_SPACE + 54  ; current dir inode during path traversal (2 bytes)
fs_temp_open_parent_ino EQU KERN_TEMP_SPACE + 56 ; parent dir inode (2 bytes) for flush
fs_temp_open_slot   EQU KERN_TEMP_SPACE + 80    ; Assigned PDT slot pointer (2 bytes)
fs_temp_open_id     EQU KERN_TEMP_SPACE + 82    ; Assigned physical device ID (1 byte)
fs_temp_open_flags  EQU KERN_TEMP_SPACE + 83    ; Flags to set on the open handle (1 byte)
fs_temp_open_dft    EQU KERN_TEMP_SPACE + 84    ; DFT pointer to set (2 bytes)

; ------------------------------------------------------------
; fs_get_block_dev
; Finds the block device ID for a given filesystem device.
; Inputs:
;   B  - filesystem device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - block device ID on success, 0 on error
; ------------------------------------------------------------
fs_get_block_dev:
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   A, H
    OR   L
    JP   Z, fs_get_block_dev_err

    LD   DE, PHYSDEV_OFF_PARENT
    ADD  HL, DE
    LD   A, (HL)
    LD   H, 0
    LD   L, A
    XOR  A
    POP  DE                     ; restore DE
    RET

fs_get_block_dev_err:
    POP  DE                     ; restore DE
    LD   A, ERR_INVALID_DEVICE
    LD   HL, 0
    RET

; ------------------------------------------------------------
; fs_dopen (slot 5 of dft_fs)
; Opens a directory.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated directory name
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - physical device ID of open handle on success, 0 on error
; ------------------------------------------------------------
fs_dopen:
    PUSH BC                     ; preserve BC (B = device ID)
    PUSH DE                     ; preserve DE (directory name pointer)

    ; Set up directory-specific globals
    LD   A, HND_FLAG_DIR
    LD   (fs_temp_open_flags), A
    LD   HL, dft_dir
    LD   (fs_temp_open_dft), HL

    ; Check if path is empty/root
    LD   A, (DE)
    OR   A
    JP   Z, fs_open_root
    CP   '/'
    JP   NZ, fs_open_common
    ; Next char after '/' ?
    INC  DE
    LD   A, (DE)
    DEC  DE
    OR   A
    JP   Z, fs_open_root
    JP   fs_open_common

fs_open_root:
    ; Provide a fake root directory entry in KERN_TEMP_SPACE
    ; Instead of full fake, just jump to slot setup with root inode = 1
    LD   A, FS_ROOT_INODE & 0xFF
    LD   (fs_temp_open_parent_ino), A  ; parent of root = root
    XOR  A
    LD   (fs_temp_open_parent_ino + 1), A
    LD   A, 1                   ; Inode = 1
    LD   (fs_temp_dir_entry + DIRENT_OFF_INODE), A
    XOR  A
    LD   (fs_temp_dir_entry + DIRENT_OFF_INODE + 1), A

    ; Root acts as size 0 directory
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE + 1), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE + 2), A
    LD   (fs_temp_dir_entry + DIRENT_OFF_SIZE + 3), A

    ; Type = DIR
    LD   A, DIRENT_TYPE_DIR | DIRENT_TYPE_USED
    LD   (fs_temp_dir_entry + DIRENT_OFF_TYPE), A

    ; Common tail requires block dev found and slot allocated
    ; (Duplicating the prep logic is better than spaghetti)
    JP   fs_open_pre_setup

; ------------------------------------------------------------
; fs_fopen (slot 3 of dft_fs)
; Opens a file.
; Inputs:
;   B  - filesystem device ID
;   DE - pointer to null-terminated file name
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - physical device ID of open handle on success, 0 on error
; ------------------------------------------------------------
fs_fopen:
    PUSH BC                     ; preserve BC (B = device ID)
    PUSH DE                     ; preserve DE (file name pointer)

    ; Set up file-specific globals
    XOR  A                      ; No flags for regular file
    LD   (fs_temp_open_flags), A
    LD   HL, dft_file
    LD   (fs_temp_open_dft), HL

fs_open_common:
    ; Strip a leading '/' from the path name (allows "/name" == "name")
    LD   A, (DE)
    CP   '/'
    JP   NZ, fs_open_common_nostrip
    INC  DE
fs_open_common_nostrip:
    ; 1. Get block device
    PUSH DE
    CALL fs_get_block_dev
    POP  DE
    OR   A
    JP   NZ, fs_open_exit
    LD   A, L
    LD   (fs_temp_blk_id), A

    ; 2. Traverse path components and look up the final entry.
    ;    Start at the root directory inode and walk each '/'-separated
    ;    component, following directory inodes, until the last component.
    LD   HL, FS_ROOT_INODE
    LD   A, L
    LD   (fs_temp_open_cur_inode), A
    LD   A, H
    LD   (fs_temp_open_cur_inode + 1), A

fs_open_path_next:
    ; DE = remaining path string; fs_temp_open_cur_inode = inode to search
    PUSH DE                     ; save component start for copy loop
    LD   H, D
    LD   L, E                   ; HL = scan pointer
fs_open_scan_slash:
    LD   A, (HL)
    OR   A
    JP   Z, fs_open_final_comp  ; no slash -> this is the last component
    CP   '/'
    JP   Z, fs_open_mid_comp    ; slash found -> intermediate directory component
    INC  HL
    JP   fs_open_scan_slash

fs_open_mid_comp:
    ; HL = '/' position; [SP] = component start (value of DE at PUSH above).
    ; Copy bytes [component_start .. '/') to fs_temp_name, null-terminate.
    POP  DE                     ; DE = component start
    PUSH HL                     ; save '/' position
    LD   HL, fs_temp_name
    LD   B, 16                  ; max 16 chars per component
fs_open_copy_comp:
    LD   A, (DE)
    CP   '/'
    JP   Z, fs_open_comp_done
    OR   A
    JP   Z, fs_open_comp_done
    LD   (HL), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, fs_open_copy_comp
    ; Name longer than 16 chars: skip rest up to '/'
fs_open_skip_comp:
    LD   A, (DE)
    CP   '/'
    JP   Z, fs_open_comp_done
    OR   A
    JP   Z, fs_open_comp_done
    INC  DE
    JP   fs_open_skip_comp
fs_open_comp_done:
    LD   (HL), 0                ; null-terminate component name
    POP  HL                     ; HL = '/' position
    INC  HL                     ; HL = first char after '/'
    LD   D, H
    LD   E, L                   ; DE = path after '/'
    PUSH DE                     ; save new path across fs_find_dir_entry call
    LD   DE, fs_temp_name       ; DE = component name to look up
    LD   HL, (fs_temp_open_cur_inode)
    CALL fs_find_dir_entry      ; search current dir inode for this component
    POP  DE                     ; restore path after '/'
    OR   A
    JP   NZ, fs_open_exit
    ; Intermediate component must be a directory
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_TYPE)
    AND  DIRENT_TYPE_DIR
    JP   Z, fs_open_not_dir
    ; Descend: set current inode to this directory's inode
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_INODE)
    LD   (fs_temp_open_cur_inode), A
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_INODE + 1)
    LD   (fs_temp_open_cur_inode + 1), A
    JP   fs_open_path_next

fs_open_final_comp:
    ; [SP] = final component pointer (value of DE at PUSH above).
    ; This is the file or directory name to actually open.
    POP  DE                     ; DE = final component
    ; Save parent inode (current dir) for handle initialization
    LD   A, (fs_temp_open_cur_inode)
    LD   (fs_temp_open_parent_ino), A
    LD   A, (fs_temp_open_cur_inode + 1)
    LD   (fs_temp_open_parent_ino + 1), A
    LD   HL, (fs_temp_open_cur_inode)
    CALL fs_find_dir_entry
    OR   A
    JP   NZ, fs_open_exit

fs_open_check_type:
    ; Ensure type matches operation
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_TYPE)
    LD   B, A
    LD   A, (fs_temp_open_flags)
    AND  HND_FLAG_DIR
    JP   Z, fs_open_req_file

fs_open_req_dir:
    LD   A, B
    AND  DIRENT_TYPE_DIR
    JP   Z, fs_open_not_dir     ; Was file, asked for dir
    JP   fs_open_prep_slot

fs_open_req_file:
    LD   A, B
    AND  DIRENT_TYPE_DIR
    JP   NZ, fs_open_not_file   ; Was dir, asked for file
    JP   fs_open_prep_slot

fs_open_not_dir:
fs_open_not_file:
    LD   A, ERR_INVALID_PARAM   ; Trying to open dir as file, etc
    LD   HL, 0
    JP   fs_open_exit

; Jump here from root dir
fs_open_pre_setup:
    ; Roots need the block dev populated
    CALL fs_get_block_dev
    OR   A
    JP   NZ, fs_open_exit
    LD   A, L
    LD   (fs_temp_blk_id), A

fs_open_prep_slot:
    ; 3. Allocate PDT slot
    CALL alloc_ram_pdt_slot
    LD   A, H
    OR   L
    JP   Z, fs_open_no_slots
    LD   (fs_temp_open_slot), HL


    ; 4. Find open physical device ID
    CALL alloc_physdev_id       ; A = free ID, or 0 if none
    JP   Z, fs_open_no_slots
    LD   (fs_temp_open_id), A

    ; 5. Initialize the PDT slot
    LD   HL, (fs_temp_open_slot)

    ; Zero the slot
    PUSH HL
    LD   BC, PHYSDEV_ENTRY_SIZE
    CALL memzero                ; dest=HL
    POP  HL

    ; ID
    LD   A, (fs_temp_open_id)
    LD   BC, PHYSDEV_OFF_ID
    ADD  HL, BC
    LD   (HL), A

    ; Parent = block dev
    LD   HL, (fs_temp_open_slot)
    LD   BC, PHYSDEV_OFF_PARENT
    ADD  HL, BC
    LD   A, (fs_temp_blk_id)
    LD   (HL), A

    ; Caps — mark as closeable handle
    LD   HL, (fs_temp_open_slot)
    LD   BC, PHYSDEV_OFF_CAPS
    ADD  HL, BC
    LD   A, DEVCAP_HANDLE
    LD   (HL), A

    ; DFT
    LD   HL, (fs_temp_open_slot)
    LD   BC, PHYSDEV_OFF_DFT
    ADD  HL, BC
    LD   DE, (fs_temp_open_dft)
    LD   (HL), E
    INC  HL
    LD   (HL), D

    ; User Data (Handle state)
    LD   HL, (fs_temp_open_slot)
    LD   BC, PHYSDEV_OFF_DATA
    ADD  HL, BC

    ; Flags
    LD   A, (fs_temp_open_flags)
    LD   (HL), A
    INC  HL

    ; Root Inode
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_INODE)
    LD   (HL), A
    INC  HL
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_INODE + 1)
    LD   (HL), A
    INC  HL

    ; Size (3 bytes; external interface presents 4 bytes, MSB always 0)
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_SIZE)
    LD   (HL), A
    INC  HL
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_SIZE + 1)
    LD   (HL), A
    INC  HL
    LD   A, (fs_temp_dir_entry + DIRENT_OFF_SIZE + 2)
    LD   (HL), A

    ; Invalidate span cache: set HND_OFF_SPAN_LBA_OFF to 0xFFFF
    ; HL is at offset 5 (after filesize); skip to offset 12 (HND_OFF_SPAN_LBA_OFF)
    INC  HL                     ; offset 6
    INC  HL                     ; offset 7
    INC  HL                     ; offset 8
    INC  HL                     ; offset 9
    INC  HL                     ; offset 10
    INC  HL                     ; offset 11
    INC  HL                     ; offset 12 = HND_OFF_SPAN_LBA_OFF
    LD   (HL), 0xFF
    INC  HL
    LD   (HL), 0xFF             ; SPAN_LBA_OFF = 0xFFFF (invalid)

    ; Parent directory inode (offset 14 = HND_OFF_PARENT_INO)
    INC  HL                     ; offset 14
    LD   A, (fs_temp_open_parent_ino)
    LD   (HL), A
    INC  HL
    LD   A, (fs_temp_open_parent_ino + 1)
    LD   (HL), A

    ; POS (offset 6-7) left as 0 by memzero.
    ; SPAN_FIRST (offset 8-9), SPAN_LAST (offset 10-11) left as 0 by memzero.
    ; SPAN_LBA_OFF (offset 12-13) set to 0xFFFF above to invalidate span cache.

    ; Insert into PHYSDEV_LIST_HEAD
    LD   HL, (fs_temp_open_slot)
    LD   BC, PHYSDEV_OFF_NEXT
    ADD  HL, BC                 ; HL = &slot->next
    LD   DE, (PHYSDEV_LIST_HEAD)
    LD   (HL), E
    INC  HL
    LD   (HL), D

    LD   HL, (fs_temp_open_slot)
    LD   (PHYSDEV_LIST_HEAD), HL


    ; Return SUCCESS and ID in HL
    LD   A, (fs_temp_open_id)
    LD   L, A
    LD   H, 0
    XOR  A
    JP   fs_open_exit

fs_open_no_slots:
    LD   A, ERR_NO_SPACE
    LD   HL, 0

fs_open_exit:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

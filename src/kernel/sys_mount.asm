; ------------------------------------------------------------
; sys_dev_mount
; Mount a filesystem device on a block device.
; Inputs:
;   DE - pointer to MOUNT_PARAMS:
;          byte 0:   physical device ID of block device
;          byte 1+:  null-terminated name for new FS device
; Outputs:
;   A  - status
;   HL - new physical device ID
; ------------------------------------------------------------
sys_dev_mount:
    PUSH BC                     ; preserve BC (B=device, C=fn#)
    PUSH DE                     ; preserve DE (MOUNT_PARAMS pointer)
    ; --- Parse MOUNT_PARAMS: B = blk_dev_id, save name pointer ---
    LD   A, (DE)                ; A = blk_dev_id
    LD   B, A                   ; B = blk_dev_id
    INC  DE                     ; DE = name string pointer
    EX   DE, HL                 ; HL = name_ptr
    LD   (MOUNT_NAME_PTR), HL   ; save for step 9

    ; --- Step 1: Verify block device exists and has block input capability ---
    LD   A, B
    CALL find_physdev_by_id     ; HL = PDT entry or 0; preserves BC
    LD   A, H
    OR   L
    JP   Z, mount_err_invalid
    LD   DE, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  DEVCAP_BLOCK_IN
    JP   Z, mount_err_invalid

    ; --- Step 2: Seek to block 0 of block device ---
    PUSH BC                     ; save B=blk_dev_id across call
    LD   DE, 0
    CALL sys_dev_bseek          ; B=blk_dev_id, DE=0
    POP  BC                     ; restore B=blk_dev_id
    OR   A
    JP   NZ, mount_err_io

    ; --- Step 3: Read block 0 into DISK_BUFFER ---
    PUSH BC
    LD   DE, DISK_BUFFER
    CALL sys_dev_bread          ; B=blk_dev_id, DE=DISK_BUFFER
    POP  BC
    OR   A
    JP   NZ, mount_err_io

    ; --- Step 4: Verify filesystem signature ---
    LD   HL, DISK_BUFFER
    LD   A, (HL)
    CP   FS_SIG_0
    JP   NZ, mount_err_bad_fs
    INC  HL
    LD   A, (HL)
    CP   FS_SIG_1
    JP   NZ, mount_err_bad_fs
    INC  HL
    LD   A, (HL)
    CP   FS_SIG_2
    JP   NZ, mount_err_bad_fs
    INC  HL
    LD   A, (HL)
    CP   FS_SIG_3
    JP   NZ, mount_err_bad_fs

    ; --- Step 5: Find a free RAM PDT slot ---
    CALL alloc_ram_pdt_slot     ; HL = free slot or 0; preserves BC
    LD   A, H
    OR   L
    JP   Z, mount_err_no_space
    LD   (MOUNT_SLOT_PTR), HL   ; save slot pointer

    ; --- Step 6: Find a free physical device ID (>= PHYSDEV_ID_FILE0) ---
    CALL alloc_physdev_id       ; A = free ID, or 0 if none
    JP   Z, mount_err_no_space
    LD   C, A                   ; C = new_dev_id
    ; B = blk_dev_id, C = new_dev_id

    ; --- Step 7: Zero the slot ---
    LD   HL, (MOUNT_SLOT_PTR)
    PUSH BC                     ; save B,C: memzero clobbers BC
    LD   BC, PHYSDEV_ENTRY_SIZE
    CALL memzero
    POP  BC                     ; restore B=blk_dev_id, C=new_dev_id

    ; --- Step 8: Set device ID field ---
    LD   HL, (MOUNT_SLOT_PTR)
    LD   DE, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   (HL), C

    ; --- Step 9: Copy name string into name field ---
    LD   HL, (MOUNT_SLOT_PTR)   ; HL = slot_ptr
    EX   DE, HL                 ; DE = slot_ptr
    LD   HL, PHYSDEV_OFF_NAME
    ADD  HL, DE                 ; HL = slot + PHYSDEV_OFF_NAME (dst)
    EX   DE, HL                 ; DE = dst (slot + PHYSDEV_OFF_NAME), HL discarded
    LD   HL, (MOUNT_NAME_PTR)   ; HL = name_ptr (src)
    CALL strcpy                 ; src=HL -> dst=DE; preserves BC

    ; --- Step 10: Set capabilities ---
    LD   HL, (MOUNT_SLOT_PTR)
    LD   DE, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   (HL), DEVCAP_BLOCK_IN | DEVCAP_BLOCK_OUT | DEVCAP_FILESYSTEM | DEVCAP_SUBDIRS

    ; --- Step 10a: Set DFT pointer ---
    LD   HL, (MOUNT_SLOT_PTR)
    LD   DE, PHYSDEV_OFF_DFT
    ADD  HL, DE
    LD   (HL), dft_fs & 0xFF
    INC  HL
    LD   (HL), dft_fs >> 8

    ; --- Step 11: Set parent = blk_dev_id, child = PHYSDEV_ID_UN ---
    LD   HL, (MOUNT_SLOT_PTR)
    LD   DE, PHYSDEV_OFF_PARENT
    ADD  HL, DE
    LD   (HL), B                ; slot->parent = blk_dev_id
    INC  HL                     ; PHYSDEV_OFF_CHILD = PHYSDEV_OFF_PARENT + 1
    LD   (HL), PHYSDEV_ID_UN    ; slot->child = PHYSDEV_ID_UN

    ; --- Step 12: Update block device's child field ---
    LD   A, B
    CALL find_physdev_by_id     ; HL = block device PDT entry; preserves BC
    LD   A, H
    OR   L
    JP   Z, mount_err_dev_late  ; re-lookup failed (PDT was modified by earlier steps)
    LD   DE, PHYSDEV_OFF_CHILD
    ADD  HL, DE
    LD   (HL), C                ; block_dev->child = new_dev_id

    ; --- Step 13: Prepend new slot to PHYSDEV_LIST_HEAD ---
    LD   HL, (MOUNT_SLOT_PTR)   ; HL = new slot (PHYSDEV_OFF_NEXT = 0)
    EX   DE, HL                 ; DE = new slot base
    LD   HL, (PHYSDEV_LIST_HEAD); HL = old list head
    LD   A, L
    LD   (DE), A                ; new_slot->next low = old head low
    INC  DE
    LD   A, H
    LD   (DE), A                ; new_slot->next high = old head high
    LD   HL, (MOUNT_SLOT_PTR)   ; HL = new slot = new list head
    LD   (PHYSDEV_LIST_HEAD), HL

    ; --- Return: A = ERR_SUCCESS, HL = new device ID ---
    LD   H, 0
    LD   L, C                   ; HL = new device ID (C captured before restoring BC)
    XOR  A
    POP  DE                     ; restore caller's DE
    POP  BC                     ; restore caller's BC
    RET

mount_err_invalid:
mount_err_dev_late:
    LD   A, ERR_INVALID_DEVICE
    JP   mount_err_exit
mount_err_io:
    LD   A, ERR_IO
    JP   mount_err_exit
mount_err_bad_fs:
    LD   A, ERR_BAD_FS
    JP   mount_err_exit
mount_err_no_space:
    LD   A, ERR_NO_SPACE
mount_err_exit:
    LD   HL, 0
    POP  DE                     ; restore caller's DE
    POP  BC                     ; restore caller's BC
    RET

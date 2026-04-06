; ============================================================
; Filesystem Read/Write/Dir Operations (8080 Compatible)
; ============================================================

fs_temp_io_buf   EQU KERN_TEMP_SPACE + 90    ; Pointer to IO buffer (2 bytes)
fs_temp_io_slot  EQU KERN_TEMP_SPACE + 92    ; Pointer to PDT slot (2 bytes)
fs_temp_io_inode EQU KERN_TEMP_SPACE + 94    ; File/Dir Root Inode (2 bytes)
fs_temp_io_pos   EQU KERN_TEMP_SPACE + 96    ; Current block position (2 bytes)
fs_temp_io_lba   EQU KERN_TEMP_SPACE + 98    ; Logical Block Address inside file (2 bytes)
fs_temp_io_pba   EQU KERN_TEMP_SPACE + 100   ; Physical Block Address on disk (2 bytes)
fs_temp_span_count EQU KERN_TEMP_SPACE + 102 ; Remaining span count (1 byte)
fs_temp_orig_lba   EQU KERN_TEMP_SPACE + 103 ; Original LBA before span walk (2 bytes)
fs_temp_span_last  EQU KERN_TEMP_SPACE + 105 ; Last PBA of found span (2 bytes, set by fs_lba_to_pba)


; ------------------------------------------------------------
; fs_get_slot_data
; Looks up a physical device by ID and returns its user data pointer.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - pointer to user data (PHYSDEV_OFF_DATA) on success
; ------------------------------------------------------------
fs_get_slot_data:
    PUSH DE
    PUSH BC
    LD   A, B
    CALL find_physdev_by_id
    LD   A, H
    OR   L
    JP   Z, fs_get_slot_data_err

    ; Save slot pointer
    LD   (fs_temp_io_slot), HL

    ; Calculate offset to PHYSDEV_OFF_DATA
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE

    POP  BC
    POP  DE
    XOR  A
    RET

fs_get_slot_data_err:
    POP  BC
    POP  DE
    LD   A, ERR_INVALID_DEVICE
    RET

; ------------------------------------------------------------
; fs_setup_block_dev
; Reads the parent block device ID from the PDT slot into fs_temp_blk_id.
; Inputs:
;   (fs_temp_io_slot) - pointer to the file/dir PDT slot
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
; ------------------------------------------------------------
fs_setup_block_dev:
    PUSH DE                     ; preserve DE
    PUSH HL                     ; preserve HL
    LD   HL, (fs_temp_io_slot)
    LD   DE, PHYSDEV_OFF_PARENT
    ADD  HL, DE
    LD   A, (HL)
    LD   (fs_temp_blk_id), A

    OR   A
    JP   Z, fs_setup_block_dev_err
    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    XOR  A
    RET

fs_setup_block_dev_err:
    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    LD   A, ERR_INVALID_DEVICE
    RET

; ------------------------------------------------------------
; fs_get_file_state
; Reads HND_OFF_ROOT_INODE and HND_OFF_POS from the PDT slot into temp vars.
; Inputs:
;   (fs_temp_io_slot) - pointer to the file/dir PDT slot
; Outputs:
;   (fs_temp_io_inode) - root inode number
;   (fs_temp_io_pos)   - current block position (2 bytes)
; ------------------------------------------------------------
fs_get_file_state:
    PUSH AF                     ; preserve AF
    PUSH DE                     ; preserve DE
    PUSH HL                     ; preserve HL

    LD   HL, (fs_temp_io_slot)
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE
    INC  HL                     ; Skip Flags (offset 0)

    ; Read Root Inode (offset 1, 2)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    PUSH HL                     ; save HL (points to offset 2)
    LD   HL, fs_temp_io_inode
    LD   (HL), E
    INC  HL
    LD   (HL), D

    ; Skip Size (3 bytes)
    POP  HL                     ; restore HL (points to offset 2)
    INC  HL                     ; offset 3
    INC  HL                     ; offset 4
    INC  HL                     ; offset 5
    INC  HL                     ; offset 6 (Pos)

    ; Read Block Position (2 bytes, offset 6-7)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    LD   HL, fs_temp_io_pos
    LD   (HL), E
    INC  HL
    LD   (HL), D

    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    POP  AF                     ; restore AF
    RET

; ------------------------------------------------------------
; fs_resolve_pba
; Resolves a Logical Block Address to Physical, using the
; handle's span-range cache.  On hit the PBA is computed as
; SPAN_FIRST + (LBA - SPAN_LBA_OFF), verified <= SPAN_LAST.
; On miss the full inode span walk runs and updates the cache.
; Inputs:
;   (fs_temp_io_slot)  - PDT slot pointer (for cache fields)
;   (fs_temp_io_inode) - root inode number
;   (fs_temp_io_lba)   - target logical block address
; Outputs:
;   A  - ERR_SUCCESS or ERR_EOF / ERR_IO
;   (fs_temp_io_pba)   - physical block address on success
; ------------------------------------------------------------
fs_resolve_pba:
    PUSH HL
    PUSH DE
    PUSH BC

    ; Point to SPAN_FIRST in handle
    LD   HL, (fs_temp_io_slot)
    LD   DE, PHYSDEV_OFF_DATA + HND_OFF_SPAN_FIRST
    ADD  HL, DE

    ; Read SPAN_FIRST -> BC
    LD   C, (HL)
    INC  HL
    LD   B, (HL)
    INC  HL

    ; Read SPAN_LAST -> push for later compare
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    PUSH DE                     ; [stack: SPAN_LAST]
    INC  HL

    ; Read SPAN_LBA_OFF -> DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)

    ; offset = LBA - LBA_OFF (borrow → miss)
    LD   HL, (fs_temp_io_lba)
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    JP   C, fs_resolve_hit_miss_pop ; LBA < LBA_OFF → miss

    ; PBA = SPAN_FIRST + offset
    ADD  HL, BC                 ; HL = candidate PBA

    ; Check PBA <= SPAN_LAST
    POP  DE                     ; DE = SPAN_LAST
    LD   A, E
    SUB  L
    LD   A, D
    SBC  A, H
    JP   C, fs_resolve_pba_miss ; LAST < PBA → miss

    ; Cache hit
    LD   (fs_temp_io_pba), HL
    POP  BC
    POP  DE
    POP  HL
    XOR  A                      ; ERR_SUCCESS
    RET

fs_resolve_hit_miss_pop:
    POP  DE                     ; discard SPAN_LAST from stack
fs_resolve_pba_miss:
    POP  BC
    POP  DE
    POP  HL

    ; Save original LBA (fs_lba_to_pba modifies fs_temp_io_lba during span walk)
    PUSH HL
    LD   HL, (fs_temp_io_lba)
    LD   (fs_temp_orig_lba), HL
    POP  HL

    ; Cache miss — do full inode lookup
    CALL fs_lba_to_pba
    OR   A
    RET  NZ                     ; error — don't update cache

    ; Update span-range cache in handle:
    ;   SPAN_FIRST = PBA - remaining_lba
    ;   SPAN_LAST  = fs_temp_span_last (set by fs_lba_to_pba)
    ;   LBA_OFF    = orig_lba - remaining_lba
    PUSH HL
    PUSH DE
    PUSH BC

    ; Compute SPAN_FIRST = PBA - remaining
    LD   HL, (fs_temp_io_pba)
    LD   DE, (fs_temp_io_lba)   ; remaining LBA after span walk
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A                   ; HL = SPAN_FIRST
    LD   B, H
    LD   C, L                   ; BC = SPAN_FIRST (save)

    ; Write all 6 cache bytes sequentially
    LD   HL, (fs_temp_io_slot)
    LD   DE, PHYSDEV_OFF_DATA + HND_OFF_SPAN_FIRST
    ADD  HL, DE
    LD   (HL), C
    INC  HL
    LD   (HL), B                ; SPAN_FIRST written
    INC  HL

    LD   DE, (fs_temp_span_last)
    LD   (HL), E
    INC  HL
    LD   (HL), D                ; SPAN_LAST written
    INC  HL

    ; LBA_OFF = orig_lba - remaining
    LD   DE, (fs_temp_orig_lba)
    LD   BC, (fs_temp_io_lba)   ; remaining
    LD   A, E
    SUB  C
    LD   (HL), A
    INC  HL
    LD   A, D
    SBC  A, B
    LD   (HL), A                ; SPAN_LBA_OFF written

    POP  BC
    POP  DE
    POP  HL
    XOR  A                      ; ERR_SUCCESS
    RET

; ------------------------------------------------------------
; fs_lba_to_pba
; Converts a Logical Block Address (inside file) to a Physical
; Block Address on disk, using the inode spans.
; Inputs:
;   (fs_temp_io_inode) - root inode number
;   (fs_temp_io_lba)   - target logical block address
; Outputs:
;   A  - ERR_SUCCESS or ERR_EOF / ERR_IO
;   (fs_temp_io_pba)   - physical block address on success
; ------------------------------------------------------------
fs_lba_to_pba:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE
    PUSH HL                     ; preserve HL

    ; 1. Read Root Inode into DISK_BUFFER
    LD   HL, (fs_temp_io_inode)
    CALL fs_read_inode
    OR   A
    JP   NZ, fs_lba_to_pba_err

    ; 2. Iterate spans to find the physical block
    ; (fs_temp_io_lba) contains the remaining logical blocks to skip.
    LD   A, (DISK_BUFFER + INODE_OFF_COUNT)
    LD   (fs_temp_span_count), A ; Use temp var instead of B

    LD   DE, DISK_BUFFER + INODE_OFF_SPANS

fs_lba_span_loop:
    LD   A, (fs_temp_span_count)
    OR   A
    JP   Z, fs_lba_eof          ; Ran out of spans before satisfying LBA

    ; Read Span FirstBlock -> HL
    LD   A, (DE)
    LD   L, A
    INC  DE
    LD   A, (DE)
    LD   H, A
    INC  DE

    ; Read Span LastBlock -> A(high):C(low)
    LD   A, (DE)
    LD   C, A
    INC  DE
    LD   A, (DE)
    INC  DE

    ; Span Length = LastBlock - FirstBlock + 1
    PUSH DE                     ; Save pointer to next span
    LD   E, C
    LD   D, A                   ; DE = LastBlock
    LD   A, E
    SUB  L
    LD   E, A
    LD   A, D
    SBC  H
    LD   D, A
    INC  DE                     ; DE = Span Length

    ; If Remaining LBA < Span Length, block is in this span
    LD   HL, (fs_temp_io_lba)
    LD   A, L
    SUB  E
    LD   A, H
    SBC  D
    JP   C, fs_lba_found

    ; Remaining LBA -= Span Length
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  D
    LD   H, A
    LD   (fs_temp_io_lba), HL

    POP  DE                     ; Restore pointer to next span
    LD   A, (fs_temp_span_count)
    DEC  A
    LD   (fs_temp_span_count), A
    JP   fs_lba_span_loop

fs_lba_found:
    ; Physical Block = FirstBlock + Remaining LBA
    ; Re-read FirstBlock from the span (pointer on stack points past it)
    POP  DE                     ; DE = pointer past this span
    DEC  DE
    DEC  DE
    DEC  DE
    DEC  DE                     ; DE = pointer to FirstBlock

    LD   A, (DE)
    LD   L, A
    INC  DE
    LD   A, (DE)
    LD   H, A                   ; HL = FirstBlock
    INC  DE

    ; Read LastBlock and save for span-range cache
    LD   A, (DE)
    LD   (fs_temp_span_last), A
    INC  DE
    LD   A, (DE)
    LD   (fs_temp_span_last + 1), A

    ; Add Remaining LBA
    LD   DE, (fs_temp_io_lba)
    ADD  HL, DE                 ; HL = FirstBlock + Remaining LBA

    LD   (fs_temp_io_pba), HL
    XOR  A
    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

fs_lba_eof:
    LD   A, ERR_EOF
fs_lba_to_pba_err:
    ; A already contains error code
    POP  HL                     ; restore HL
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; fs_advance_block_pos
; Increment the block position by 1 and save back to
; the PDT slot's HND_OFF_POS field.
; Inputs:
;   (fs_temp_io_pos)  - current block position (2 bytes)
;   (fs_temp_io_slot) - pointer to PDT slot
; Outputs:
;   Position updated in both temp vars and PDT slot
; Modifies: A, DE, HL
; ------------------------------------------------------------
fs_advance_block_pos:
    LD   HL, (fs_temp_io_pos)
    INC  HL
    LD   (fs_temp_io_pos), HL
    ; Save to PDT slot
    LD   HL, (fs_temp_io_slot)
    LD   DE, PHYSDEV_OFF_DATA + HND_OFF_POS
    ADD  HL, DE
    LD   A, (fs_temp_io_pos)
    LD   (HL), A
    INC  HL
    LD   A, (fs_temp_io_pos + 1)
    LD   (HL), A
    RET

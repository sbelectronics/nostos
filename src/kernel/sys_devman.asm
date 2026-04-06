; ------------------------------------------------------------
; Device Management Syscall Implementations
; ------------------------------------------------------------

; ------------------------------------------------------------
; sys_dev_log_assign
; Assign a physical device to a logical device slot.
; Inputs:
;   B  - logical device ID (top bit set; 0x80–0xFF)
;   DE - E = physical device ID to assign
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - 0
; ------------------------------------------------------------
sys_dev_log_assign:
    ; Validate before pushing: B must be a logical device ID (top bit set)
    LD   A, B
    AND  0x80
    JP   Z, sys_err_invalid_device
    ; Extract index and validate < LOGDEV_MAX
    LD   A, B
    AND  0x7F
    CP   LOGDEV_MAX
    JP   NC, sys_err_invalid_device
    PUSH BC                     ; preserve BC (B=logical ID, C=fn#)
    PUSH DE                     ; preserve DE (E=physical device ID)
    LD   B, A                   ; B = stripped index (for logdev_entry_addr below)
    ; Find physical device entry for ID in E
    LD   A, E
    CALL find_physdev_by_id     ; returns HL = pointer or 0
    LD   A, H
    OR   L
    JP   Z, sys_dev_log_assign_err
    PUSH HL                     ; save physdev pointer
    ; Compute address of physptr field in logical table entry
    LD   A, B
    CALL logdev_entry_addr      ; HL = base of logical entry
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    POP  DE                     ; DE = physdev pointer
    LD   (HL), E
    INC  HL
    LD   (HL), D
    XOR  A
    LD   H, A
    LD   L, A
    POP  DE                     ; restore caller's DE
    POP  BC                     ; restore caller's BC
    RET

sys_dev_log_assign_err:
    POP  DE                     ; restore caller's DE
    POP  BC                     ; restore caller's BC
    JP   sys_err_invalid_device

; ------------------------------------------------------------
; logdev_id_to_entry
; Validate a logical device ID and return pointer to its entry.
; Inputs:
;   B  - logical device ID (top bit set; 0x80–0xFF)
; Outputs:
;   HL - pointer to logical device entry
; On error: JP sys_err_invalid_device (does not return)
; ------------------------------------------------------------
logdev_id_to_entry:
    LD   A, B
    AND  0x80
    JP   Z, sys_err_invalid_device
    LD   A, B
    AND  0x7F
    CP   LOGDEV_MAX
    JP   NC, sys_err_invalid_device
    JP   logdev_entry_addr          ; A = raw index; tail call; returns HL = entry ptr

; ------------------------------------------------------------
; sys_dev_log_get
; Return a pointer to the logical device table entry for a given device ID.
; Inputs:
;   B  - logical device ID (top bit set; 0x80–0xFF)
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - pointer to logical device entry (8 bytes)
; ------------------------------------------------------------
sys_dev_log_get:
    CALL logdev_id_to_entry         ; HL = &logdev_table[index]; JP err on bad ID
    XOR  A
    RET

; ------------------------------------------------------------
; sys_dev_log_lookup
; Find a logical device by name.
; Inputs:
;   DE - pointer to null-terminated name string
; Outputs:
;   A  - ERR_SUCCESS or ERR_NOT_FOUND
;   HL - logical device ID (top bit set; 0x80–0xFF)
; ------------------------------------------------------------
sys_dev_log_lookup:
    PUSH DE                     ; preserve caller's name ptr across iterations
    LD   B, LOGDEV_MAX
    LD   HL, LOGDEV_TABLE
sys_dev_log_lookup_loop:
    ; Restore DE (caller's name ptr) clobbered by strncmp4 or LD DE below.
    POP  DE
    PUSH DE
    PUSH BC
    PUSH HL
    ; Compare name at LOGDEV_OFF_NAME (case-insensitive)
    LD   A, LOGDEV_OFF_NAME
    ADD  A, L
    LD   L, A
    ; Compare null-terminated name at HL with string at DE
    CALL strcasecmp_hl_de      ; Z set if match; clobbers A, B, HL, DE
    POP  HL
    POP  BC
    JP   Z, sys_dev_log_lookup_found
    LD   DE, LOGDEV_ENTRY_SIZE  ; DE clobbered here, but restored at loop top via POP/PUSH
    ADD  HL, DE
    DEC  B
    JP   NZ, sys_dev_log_lookup_loop
    POP  DE                     ; clean stack
    JP   sys_err_not_found
sys_dev_log_lookup_found:
    ; HL points to start of matched entry
    POP  DE                     ; clean stack
    LD   A, (HL)                ; logical device ID (already has bit 7 set)
    LD   L, A
    LD   H, 0
    XOR  A
    RET

; ------------------------------------------------------------
; sys_dev_log_create
; Allocate a free logical device slot and populate it.
; Inputs:
;   DE - pointer to null-terminated name (up to 4 characters)
; Outputs:
;   A  - ERR_SUCCESS or ERR_NO_SPACE
;   HL - new logical device ID (top bit set; 0x80–0xFF)
; ------------------------------------------------------------
sys_dev_log_create:
    PUSH BC                         ; preserve BC (B=device ID, C=fn#)
    PUSH DE                         ; preserve name ptr (retrieved at found)
    LD   HL, LOGDEV_TABLE
    LD   B, LOGDEV_MAX              ; B = scan counter (clobbers caller's B)
    LD   C, 0                       ; C = slot index counter (clobbers caller's C)
sys_dev_log_create_scan:
    INC  HL                         ; point to name field (LOGDEV_OFF_NAME = 1)
    LD   A, (HL)                    ; A = name[0]; 0 means free slot
    DEC  HL                         ; restore to entry base
    OR   A
    JP   Z, sys_dev_log_create_found
    PUSH DE
    LD   DE, LOGDEV_ENTRY_SIZE
    ADD  HL, DE
    POP  DE
    INC  C
    DEC  B
    JP   NZ, sys_dev_log_create_scan
    POP  DE                         ; clean saved name ptr
    POP  BC                         ; restore caller's BC
    LD   A, ERR_NO_SPACE
    LD   HL, 0
    RET

sys_dev_log_create_found:
    ; HL = entry base, C = slot index, [SP] = name ptr
    LD   A, C
    OR   0x80
    LD   (HL), A                    ; entry[LOGDEV_OFF_ID] = logical device ID (index | 0x80)
    INC  HL                         ; HL = &entry->name
    POP  DE                         ; DE = name ptr
    LD   B, 5                       ; copy up to 5 bytes (4 chars + null terminator)
sys_dev_log_create_copy:
    LD   A, (DE)
    LD   (HL), A
    INC  HL
    INC  DE
    OR   A
    JP   Z, sys_dev_log_create_pad  ; wrote null: zero-fill rest
    DEC  B
    JP   NZ, sys_dev_log_create_copy
    JP   sys_dev_log_create_physptr
sys_dev_log_create_pad:
    ; null already written; fill remaining (B-1) name bytes with 0
    DEC  B
    JP   Z, sys_dev_log_create_physptr
sys_dev_log_create_pad_loop:
    LD   (HL), 0
    INC  HL
    DEC  B
    JP   NZ, sys_dev_log_create_pad_loop
sys_dev_log_create_physptr:
    ; HL = physptr field (LOGDEV_OFF_PHYSPTR = 6); zero it
    LD   (HL), 0
    INC  HL
    LD   (HL), 0
    LD   A, C
    OR   0x80
    LD   L, A                       ; HL = logical device ID (index | 0x80)
    LD   H, 0
    XOR  A
    POP  BC                         ; restore caller's BC
    RET

; ------------------------------------------------------------
; sys_dev_lookup
; Look up a device by name, trying logical first then physical.
; Inputs:
;   DE - pointer to null-terminated name string
; Outputs:
;   A  - ERR_SUCCESS or ERR_NOT_FOUND
;   HL - device ID (top bit set = logical, clear = physical)
; ------------------------------------------------------------
sys_dev_lookup:
    CALL sys_dev_log_lookup     ; try logical first; preserves DE; returns logdev ID if found
    OR   A
    RET  Z                      ; found: HL already has logical device ID (top bit set)
    JP   sys_dev_phys_lookup    ; not found: try physical

; ------------------------------------------------------------
; sys_dev_get_name
; Copy the name of a device into a caller-supplied buffer.
; Inputs:
;   B  - device ID (top bit set = logical, clear = physical)
;   DE - pointer to name buffer (>= 8 bytes)
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - 0
; ------------------------------------------------------------
sys_dev_get_name:
    LD   A, B
    AND  0x80
    JP   NZ, sys_dev_get_name_log
    ; Physical: find PDT entry by ID, copy null-terminated name field
    ; (find_physdev_by_id preserves DE, so no PUSH/POP needed)
    LD   A, B
    CALL find_physdev_by_id     ; HL = entry or 0
    LD   A, H
    OR   L
    JP   Z, sys_err_invalid_device
    LD   BC, PHYSDEV_OFF_NAME
    ADD  HL, BC                 ; HL = &entry->name (null-terminated, up to 6 chars)
    CALL strcpy                 ; strcpy(src=HL, dst=DE)
    XOR  A
    LD   H, A
    LD   L, A
    RET

sys_dev_get_name_log:
    ; (logdev_id_to_entry validates B, strips, calls logdev_entry_addr which preserves DE)
    CALL logdev_id_to_entry     ; HL = &logdev_table[index]; JP err on bad ID
    LD   BC, LOGDEV_OFF_NAME
    ADD  HL, BC                 ; HL = &entry->name (null-terminated, up to 4 chars)
    CALL strcpy                 ; strcpy(src=HL, dst=DE)
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; sys_dev_copy
; Copy a physical device entry into a new RAM PDT slot and link it.
; Inputs:
;   DE - pointer to source physical device entry
; Outputs:
;   A  - ERR_SUCCESS or ERR_NO_SPACE
;   HL - new physical device ID
; ------------------------------------------------------------
sys_dev_copy:
    PUSH DE                     ; Save source pointer (DE)

    ; 1. Find a free RAM PDT slot
    CALL alloc_ram_pdt_slot
    LD   A, H
    OR   L
    JP   Z, sys_dev_copy_err_nospace

    PUSH HL                     ; Save dest slot (HL)
    EX   DE, HL                 ; HL = source, DE = dest

    ; 2. Copy entry
    LD   B, PHYSDEV_ENTRY_SIZE
sys_dev_copy_loop:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, sys_dev_copy_loop

    ; 3. If source ID is 0, dynamically allocate a free ID
    ;    Must happen before linking so a failed slot isn't left in the list.
    POP  HL                     ; Restore dest slot
    PUSH HL                     ; Re-save for linking step
    LD   DE, PHYSDEV_OFF_ID
    ADD  HL, DE                 ; HL = &dest->id
    LD   A, (HL)                ; A = device ID from source
    OR   A
    JP   NZ, sys_dev_copy_link  ; nonzero = caller chose a fixed ID

    PUSH HL                     ; save &dest->id
    CALL alloc_physdev_id       ; A = free ID, or 0 if none
    POP  HL                     ; restore &dest->id
    JP   Z, sys_dev_copy_err_noid
    LD   (HL), A                ; write allocated ID into slot

    ; 4. Link new entry into PHYSDEV_LIST_HEAD
sys_dev_copy_link:
    POP  HL                     ; Restore dest slot
    LD   DE, (PHYSDEV_LIST_HEAD)
    LD   (HL), E                ; dest->next (offset 0) = old head (low)
    INC  HL
    LD   (HL), D                ; dest->next (offset 1) = old head (high)
    DEC  HL                     ; back to dest slot
    LD   (PHYSDEV_LIST_HEAD), HL

    ; Return success: A = ERR_SUCCESS, HL = device ID
    LD   L, A
    LD   H, 0

    POP  DE                     ; Clean up saved source pointer
    XOR  A
    RET

sys_dev_copy_err_noid:
    POP  HL                     ; Clean up saved dest slot
sys_dev_copy_err_nospace:
    POP  DE                     ; Clean up saved source pointer
    LD   A, ERR_NO_SPACE
    LD   HL, 0
    RET

; ------------------------------------------------------------
; sys_dev_phys_lookup
; Find a physical device by name.
; Inputs:
;   DE - pointer to null-terminated name string
; Outputs:
;   A  - ERR_SUCCESS or ERR_NOT_FOUND
;   HL - physical device ID
; ------------------------------------------------------------
sys_dev_phys_lookup:
    PUSH DE                     ; preserve caller's name ptr across iterations
    LD   HL, (PHYSDEV_LIST_HEAD)
sys_dev_phys_lookup_loop:
    LD   A, H
    OR   L
    JP   Z, sys_dev_phys_lookup_fail ; end of list
    PUSH HL                     ; save entry base
    LD   BC, PHYSDEV_OFF_NAME   ; = 3
    ADD  HL, BC                 ; HL = &entry->name
    ; DE = caller's name ptr (preserved by strcasecmp_hl_de via its own pushes)
    CALL strcasecmp_hl_de       ; Z set if names match (case-insensitive); clobbers A, B, HL, DE
    POP  HL                     ; HL = entry base
    JP   Z, sys_dev_phys_lookup_found
    ; No match: follow next pointer at HL + PHYSDEV_OFF_NEXT (= 0)
    LD   C, (HL)
    INC  HL
    LD   B, (HL)
    LD   H, B
    LD   L, C                   ; HL = next entry
    ; Restore DE (caller's name ptr clobbered by strcmp)
    POP  DE
    PUSH DE
    JP   sys_dev_phys_lookup_loop
sys_dev_phys_lookup_found:
    ; HL = entry base.  Return physical device ID from PHYSDEV_OFF_ID (= 2).
    LD   BC, PHYSDEV_OFF_ID
    ADD  HL, BC
    LD   A, (HL)                ; A = physical device ID
    POP  DE                     ; restore DE, clean stack
    LD   L, A
    LD   H, 0
    XOR  A
    RET
sys_dev_phys_lookup_fail:
    POP  DE                     ; clean stack
    JP   sys_err_not_found

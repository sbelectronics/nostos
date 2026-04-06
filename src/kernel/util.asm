; ------------------------------------------------------------
; resolve_device
; Resolve device ID in B to a physical device entry pointer.
; If B has the top bit set, looks up in the logical device table first.
; Inputs:
;   B  - device ID (0x00-0x7F physical, 0x80-0xFF logical)
; Outputs:
;   HL - physical device entry pointer, or 0 if not found
; ------------------------------------------------------------
resolve_device:
    PUSH AF
    PUSH DE
    LD   A, B
    AND  0x80
    JP   NZ, resolve_device_logical
    ; Physical device: search by ID
    LD   A, B
    CALL find_physdev_by_id
    POP  DE
    POP  AF
    RET
resolve_device_logical:
    ; Logical device: index = B & 0x7F
    LD   A, B
    AND  0x7F
    CP   LOGDEV_MAX
    JP   NC, resolve_device_not_found
    CALL logdev_entry_addr      ; HL = logical entry base
    ; Load physical device pointer from LOGDEV_OFF_PHYSPTR
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    EX   DE, HL                 ; HL = physdev pointer
    POP  DE
    POP  AF
    RET
resolve_device_not_found:
    LD   HL, 0
    POP  DE
    POP  AF
    RET

; ------------------------------------------------------------
; resolve_and_call
; Resolve device ID and call a DFT slot function via tail-call.
; Inputs:
;   A  - DFT slot index
;   B  - device ID (0x00-0x7F physical, 0x80-0xFF logical)
;   DE - parameter to pass to device function
; Outputs:
;   A  - status code (from device function)
;   HL - return value (from device function)
; ------------------------------------------------------------
resolve_and_call:
    PUSH DE                     ; save caller's parameter (clobbered by resolve_device)
    PUSH AF                     ; save slot index
    CALL resolve_device         ; HL = physdev entry (DE is now clobbered)
    LD   A, H
    OR   L
    JP   Z, resolve_and_call_nodev

    ; Load physical ID into B for the driver

    PUSH HL
    LD   DE, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   B, (HL)                ; B = physical device ID
    POP  HL                     ; restore HL = physdev entry base

    ; Load DFT pointer from PDT entry at HL + PHYSDEV_OFF_DFT (= 13)
    POP  AF                     ; A = slot index; HL = physdev entry base
    LD   DE, PHYSDEV_OFF_DFT
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = DFT base address (A unchanged)
    
    ; Index into DFT: HL = DFT_base + slot*2
    EX   DE, HL                 ; HL = DFT base, DE = entry base (clobbered)
    LD   E, A
    LD   D, 0
    ADD  HL, DE
    ADD  HL, DE                 ; HL = &DFT[slot]
    
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = fn address (was BC in original)
    PUSH DE
    POP  HL                     ; HL = fn address
    
    POP  DE                     ; restore caller's parameter
    JP   (HL)                   ; tail-call device function; it RET's to our caller

resolve_and_call_nodev:
    POP  AF                     ; discard saved slot
    POP  DE                     ; restore caller's parameter
    JP   sys_err_invalid_device
	
; ------------------------------------------------------------
; alloc_ram_pdt_slot
; Scan the RAM physical device table for a free slot (ID byte = 0).
; The workspace is zeroed at init, so unused slots have ID = 0.
; Inputs:
;   (none)
; Outputs:
;   HL - pointer to free slot, or 0 if none available
; ------------------------------------------------------------
alloc_ram_pdt_slot:
    PUSH AF
    PUSH BC
    PUSH DE
    LD   HL, PHYSDEV_TABLE
    LD   B, PHYSDEV_MAX
alloc_ram_pdt_loop:
    PUSH HL
    LD   DE, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   A, (HL)
    POP  HL
    OR   A
    JP   Z, alloc_ram_pdt_found
    LD   DE, PHYSDEV_ENTRY_SIZE
    ADD  HL, DE
    DEC  B
    JP   NZ, alloc_ram_pdt_loop
    LD   HL, 0
    POP  DE
    POP  BC
    POP  AF
    RET
alloc_ram_pdt_found:
    POP  DE
    POP  BC
    POP  AF
    RET

; ------------------------------------------------------------
; alloc_physdev_id
; Find an unused physical device ID by scanning from PHYSDEV_ID_FILE0.
; Inputs:
;   (none)
; Outputs:
;   A  - free ID (>= PHYSDEV_ID_FILE0), or 0 if none available
;   Zero flag set if no ID available
; Preserves: BC, DE
; ------------------------------------------------------------
alloc_physdev_id:
    PUSH BC
    LD   C, PHYSDEV_ID_FILE0
alloc_physdev_id_loop:
    LD   A, C
    CALL find_physdev_by_id     ; HL = entry or 0
    LD   A, H
    OR   L
    JP   Z, alloc_physdev_id_ok ; HL=0 → ID is free
    INC  C
    LD   A, C
    OR   A                      ; wrapped to 0 = exhausted
    JP   Z, alloc_physdev_id_none
    JP   alloc_physdev_id_loop
alloc_physdev_id_ok:
    LD   A, C                   ; A = free ID
    POP  BC
    OR   A                      ; clear zero flag (ID >= 0x10)
    RET
alloc_physdev_id_none:
    POP  BC
    XOR  A                      ; A = 0, zero flag set
    RET

; ------------------------------------------------------------
; find_physdev_by_id
; Search the physical device linked list for a device with the given ID.
; Inputs:
;   A  - physical device ID to search for
; Outputs:
;   HL - pointer to physical device entry, or 0 if not found
;   A  - ERR_SUCCESS if found
; ------------------------------------------------------------
find_physdev_by_id:
    PUSH DE
    PUSH AF                     ; save target ID
    LD   HL, (PHYSDEV_LIST_HEAD)
find_physdev_loop:
    LD   A, H
    OR   L
    JP   Z, find_physdev_notfound
    ; Compare ID: entry->id is at PHYSDEV_OFF_ID
    PUSH HL
    LD   DE, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   A, (HL)
    POP  HL
    LD   D, A                   ; D = entry ID
    POP  AF                     ; A = target ID
    PUSH AF
    CP   D
    JP   Z, find_physdev_found
    ; Advance to next entry: follow next pointer
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    EX   DE, HL
    JP   find_physdev_loop
find_physdev_found:
    POP  AF
    POP  DE
    XOR  A
    RET
find_physdev_notfound:
    POP  AF
    POP  DE
    LD   HL, 0
    RET

; ------------------------------------------------------------
; logdev_entry_addr
; Return the address of the logical device table entry for index A.
; A must be < LOGDEV_MAX.
; Inputs:
;   A  - logical device index
; Outputs:
;   HL - pointer to logical device table entry
; ------------------------------------------------------------
logdev_entry_addr:
    PUSH AF
    PUSH DE
    LD   H, 0
    LD   L, A
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL                 ; HL = A * 8 (LOGDEV_ENTRY_SIZE)
    LD   DE, LOGDEV_TABLE
    ADD  HL, DE
    POP  DE
    POP  AF
    RET
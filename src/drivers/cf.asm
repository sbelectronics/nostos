; NostOS CompactFlash Block Device Driver
; Uses 8-bit IDE interface. Ports are dynamically loaded from PDT user data.
; LBA addressing, single sector (512 bytes) per operation.
; ============================================================

; ------------------------------------------------------------
; cf_get_port
; Return the port number at a given offset in the device user data.
; Inputs:
;   HL - pointer to physical device user data
;   A  - port offset (e.g. CF_OFF_PORT_DATA)
; Outputs:
;   C  - port number
; ------------------------------------------------------------
cf_get_port:
    PUSH HL
    PUSH DE                     ; preserve DE
    PUSH AF                     ; preserve A (port offset input)
    LD   E, A                   ; E = port offset
    LD   D, 0
    ADD  HL, DE                 ; HL = user_data + offset
    LD   C, (HL)                ; C = port number (output)
    POP  AF                     ; restore A
    POP  DE                     ; restore DE
    POP  HL                     ; restore HL
    RET

; ------------------------------------------------------------
; cf_wait_ready
; Wait until CF is not busy and DRDY is set.
; Uses DE as a 16-bit timeout counter (~65535 polls).
; Inputs:
;   HL - pointer to physical device user data
; Outputs:
;   A  - ERR_SUCCESS if ready, ERR_IO on timeout
; ------------------------------------------------------------
cf_wait_ready:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE (used as timeout counter)
    LD   DE, 0xFFFF             ; timeout counter
    LD   A, CF_OFF_PORT_STATUS
    CALL cf_get_port            ; C = status port; DE preserved (0xFFFF) by cf_get_port
cf_wait_ready_busy:
    CALL tramp_in
    AND  CF_BUSY
    JP   Z, cf_wait_ready_drdy  ; BUSY clear — check DRDY
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, cf_wait_ready_busy
    LD   A, ERR_IO              ; timeout: BUSY never cleared
    JP   cf_wait_ready_done
cf_wait_ready_drdy:
    CALL tramp_in
    AND  CF_DRDY
    JP   NZ, cf_wait_ready_ok   ; DRDY set — device is ready
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, cf_wait_ready_busy ; keep polling
    LD   A, ERR_IO              ; timeout: DRDY never set
    JP   cf_wait_ready_done
cf_wait_ready_ok:
    XOR  A
cf_wait_ready_done:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; cf_wait_drq
; Wait until CF is ready to transfer data (DRQ set).
; Uses DE as a 16-bit timeout counter (~65535 polls).
; Inputs:
;   HL - pointer to physical device user data
; Outputs:
;   A  - ERR_SUCCESS if DRQ set, ERR_IO on timeout
; ------------------------------------------------------------
cf_wait_drq:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE (used as timeout counter)
    LD   DE, 0xFFFF             ; timeout counter
    LD   A, CF_OFF_PORT_STATUS
    CALL cf_get_port            ; C = status port; DE preserved by cf_get_port
cf_wait_drq_loop:
    CALL tramp_in
    AND  CF_DRQ
    JP   NZ, cf_wait_drq_ok    ; DRQ set — ready to transfer
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, cf_wait_drq_loop
    LD   A, ERR_IO              ; timeout: DRQ never set
    JP   cf_wait_drq_done
cf_wait_drq_ok:
    XOR  A
cf_wait_drq_done:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; cf_init
; Initialize the CompactFlash device.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_IO
;   HL - 0
; ------------------------------------------------------------
cf_init:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id     ; HL = physdev entry; preserves BC, DE
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE                 ; HL = user data ptr

    CALL cf_wait_ready
    OR   A
    JP   NZ, cf_init_fail

    ; Enable 8-bit transfer mode via SET FEATURES (0xEF)
    LD   A, CF_OFF_PORT_FEAT
    CALL cf_get_port            ; C = features port
    LD   A, 0x01                ; feature: enable 8-bit transfers
    CALL tramp_out

    LD   A, CF_OFF_PORT_STATUS
    CALL cf_get_port            ; C = command port
    LD   A, 0xEF                ; SET FEATURES command
    CALL tramp_out

    CALL cf_wait_ready
    OR   A
    JP   NZ, cf_init_fail
    LD   H, A                   ; A = 0 = ERR_SUCCESS
    LD   L, A
    JP   cf_init_done
cf_init_fail:
    LD   A, ERR_IO
    LD   HL, 0
cf_init_done:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; cf_readblock
; Read one 512-byte block from CF at the current LBA position.
; Inputs:
;   B  - physical device ID
;   DE - pointer to 512-byte destination buffer
; Outputs:
;   A  - ERR_SUCCESS or ERR_IO
;   HL - 0
; ------------------------------------------------------------
cf_readblock:
    PUSH BC                     ; [1] preserve BC
    PUSH DE                     ; [2] preserve DE (original buffer ptr)
    PUSH DE                     ; [3] save buffer ptr for use after LBA setup
    LD   A, B
    CALL find_physdev_by_id     ; HL = physdev entry; preserves BC, DE
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE                 ; HL = user data ptr (preserved through all calls)

    CALL cf_setup_lba

    LD   A, CF_OFF_PORT_SECCNT
    CALL cf_get_port            ; C = sector count port
    LD   A, 1                   ; read 1 sector
    CALL tramp_out

    LD   A, CF_OFF_PORT_STATUS
    CALL cf_get_port            ; C = command port
    LD   A, CF_CMD_READ
    CALL tramp_out

    CALL cf_wait_drq
    OR   A
    JP   NZ, cf_readblock_drq_err

    POP  DE                     ; [3] restore DE = buffer pointer
    LD   B, 0                   ; iteration count (0 = 256 bytes per pass)
    CALL cf_read256
    CALL cf_read256

    LD   A, CF_OFF_PORT_STATUS
    CALL cf_get_port            ; C = status port
    CALL tramp_in
    AND  CF_ERR
    JP   NZ, cf_readblock_err

    ; Advance LBA by 1
    CALL cf_inc_lba
    XOR  A
    LD   H, A
    LD   L, A
    JP   cf_readblock_done
cf_readblock_drq_err:
    POP  DE                     ; [3] discard saved buffer ptr (stack balance)
cf_readblock_err:
    LD   A, ERR_IO
    LD   HL, 0
cf_readblock_done:
    POP  DE                     ; [2] restore original DE
    POP  BC                     ; [1] restore BC
    RET

; Read 256 bytes from CF data port into (DE), advance DE.
; Inputs:
;   HL - pointer to user data
;   B  - iteration count (0 = 256)
;   DE - destination buffer pointer
; Outputs:
;   DE - advanced by count
;   B  - 0
cf_read256:
    PUSH AF                     ; preserve A
    PUSH BC                     ; preserve C (B=0 restored unchanged)
    LD   A, CF_OFF_PORT_DATA
    CALL cf_get_port            ; C = data port
    PUSH HL
    LD   HL, CF_READ_THUNK
    LD   (HL), 0xDB             ; IN opcode
    INC  HL
    LD   (HL), C                ; port number
    INC  HL
    LD   (HL), 0xC9             ; RET opcode
    POP  HL
cf_read256_loop:
    CALL CF_READ_THUNK          ; A = IN(port)
    LD   (DE), A
    INC  DE
    DEC  B
    JP   NZ, cf_read256_loop
    POP  BC                     ; restore C (and B, which was 0)
    POP  AF                     ; restore A
    RET

; ------------------------------------------------------------
; cf_writeblock
; Write one 512-byte block to CF at the current LBA position.
; Inputs:
;   B  - physical device ID
;   DE - pointer to 512-byte source buffer
; Outputs:
;   A  - ERR_SUCCESS or ERR_IO
;   HL - 0
; ------------------------------------------------------------
cf_writeblock:
    PUSH BC                     ; [1] preserve BC
    PUSH DE                     ; [2] preserve DE (original source ptr)
    PUSH DE                     ; [3] save source ptr for use after LBA setup
    LD   A, B
    CALL find_physdev_by_id     ; HL = physdev entry; preserves BC, DE
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE                 ; HL = user data ptr (preserved through all calls)

    CALL cf_setup_lba

    LD   A, CF_OFF_PORT_SECCNT
    CALL cf_get_port            ; C = sector count port
    LD   A, 1
    CALL tramp_out

    LD   A, CF_OFF_PORT_STATUS
    CALL cf_get_port            ; C = command port
    LD   A, CF_CMD_WRITE
    CALL tramp_out

    CALL cf_wait_drq
    OR   A
    JP   NZ, cf_writeblock_drq_err

    POP  DE                     ; [3] restore DE = source pointer
    LD   B, 0                   ; iteration count (0 = 256 bytes per pass)
    CALL cf_write256
    CALL cf_write256

    CALL cf_wait_ready

    LD   A, CF_OFF_PORT_STATUS
    CALL cf_get_port            ; C = status port
    CALL tramp_in
    AND  CF_ERR
    JP   NZ, cf_writeblock_err

    ; Advance LBA by 1
    CALL cf_inc_lba
    XOR  A
    LD   H, A
    LD   L, A
    JP   cf_writeblock_done
cf_writeblock_drq_err:
    POP  DE                     ; [3] discard saved source ptr (stack balance)
cf_writeblock_err:
    LD   A, ERR_IO
    LD   HL, 0
cf_writeblock_done:
    POP  DE                     ; [2] restore original DE
    POP  BC                     ; [1] restore BC
    RET

; Write 256 bytes from (DE) to CF data port, advance DE.
; Inputs:
;   HL - pointer to user data
;   B  - iteration count (0 = 256)
;   DE - source buffer pointer
; Outputs:
;   DE - advanced by count
;   B  - 0
cf_write256:
    PUSH AF                     ; preserve A
    PUSH BC                     ; preserve C (B=0 restored unchanged)
    LD   A, CF_OFF_PORT_DATA
    CALL cf_get_port            ; C = data port
    PUSH HL
    LD   HL, CF_WRITE_THUNK
    LD   (HL), 0xD3             ; OUT opcode
    INC  HL
    LD   (HL), C                ; port number
    INC  HL
    LD   (HL), 0xC9             ; RET opcode
    POP  HL
cf_write256_loop:
    LD   A, (DE)
    CALL CF_WRITE_THUNK         ; OUT(port) = A
    INC  DE
    DEC  B
    JP   NZ, cf_write256_loop
    POP  BC                     ; restore C (and B, which was 0)
    POP  AF                     ; restore A
    RET

; ------------------------------------------------------------
; cf_seek
; Set the current LBA block position in the device data field.
; Inputs:
;   B  - physical device ID
;   DE - block number (16-bit, LBA 0-65535)
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
cf_seek:
    PUSH BC                     ; preserve BC
    LD   A, B
    CALL find_physdev_by_id     ; HL = physical entry; preserves BC, DE
    PUSH DE                     ; save DE (block number) around ADD HL, DE
    LD   DE, PHYSDEV_OFF_DATA + CF_OFF_LBA
    ADD  HL, DE
    POP  DE                     ; restore DE = block number
    LD   (HL), E                ; store LBA bits 0-7
    INC  HL
    LD   (HL), D                ; store LBA bits 8-15
    INC  HL
    LD   (HL), 0                ; zero LBA bits 16-23
    INC  HL
    LD   (HL), 0                ; zero LBA bits 24-31
    POP  BC                     ; restore BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; cf_bgetpos
; Get the current block position.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - block position
; ------------------------------------------------------------
cf_bgetpos:
    LD   DE, PHYSDEV_OFF_DATA + CF_OFF_LBA
    JP   common_bgetpos

; ------------------------------------------------------------
; cf_setup_lba
; Program the CF LBA registers from PDT user data.
; Inputs:
;   HL - pointer to user data
; Outputs:
;   (none)
; ------------------------------------------------------------
cf_setup_lba:
    PUSH AF                     ; preserve AF
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE (E used as temp LBA byte)

    LD   A, (HL)                ; LBA bits 0-7
    LD   E, A
    LD   A, CF_OFF_PORT_SECNUM
    CALL cf_get_port            ; C = SECNUM port; DE preserved (E=LBA) by cf_get_port
    LD   A, E
    CALL tramp_out

    INC  HL                     ; advance to LBA byte 1
    LD   A, (HL)
    LD   E, A
    DEC  HL                     ; restore HL to user data base
    LD   A, CF_OFF_PORT_CYLLOW
    CALL cf_get_port            ; C = CYLLOW port; DE preserved (E=LBA) by cf_get_port
    LD   A, E
    CALL tramp_out

    LD   A, CF_OFF_PORT_CYLHI
    CALL cf_get_port            ; C = CYLHI port
    XOR  A                      ; LBA bits 16-23 = 0
    CALL tramp_out

    LD   A, CF_OFF_PORT_HEAD
    CALL cf_get_port            ; C = HEAD port
    LD   A, CF_HEAD_LBA         ; LBA mode, device 0
    CALL tramp_out

    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    POP  AF                     ; restore AF
    RET

; ------------------------------------------------------------
; cf_inc_lba
; Increment the 2-byte LBA position in user data.
; CF_OFF_LBA is 0, so HL points directly at LBA low byte.
; Inputs:
;   HL - pointer to user data (= pointer to LBA low byte)
; Outputs:
;   (none)
; Preserves: AF, BC, DE (HL incremented by 1 on low-byte overflow)
; ------------------------------------------------------------
cf_inc_lba:
    INC  (HL)                   ; LBA low byte
    RET  NZ                     ; no carry, done
    INC  HL
    INC  (HL)                   ; LBA high byte (carry)
    RET

; ------------------------------------------------------------
; cf_bgetsize
; Write total device capacity in bytes (4-byte LE) to buffer.
; Reports 4096 blocks = 2MB (0x00200000).
; Inputs:
;   B  - physical device ID (unused)
;   DE - pointer to 4-byte output buffer
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; Preserves: BC
; ------------------------------------------------------------
cf_bgetsize:
    XOR  A
    LD   (DE), A                ; byte 0 = 0x00
    INC  DE
    LD   (DE), A                ; byte 1 = 0x00
    INC  DE
    LD   A, 0x20
    LD   (DE), A                ; byte 2 = 0x20
    INC  DE
    XOR  A
    LD   (DE), A                ; byte 3 = 0x00
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; Device Function Table for CF block device (block DFT, 9 slots)
; ------------------------------------------------------------
dft_cf:
    DEFW cf_init                ; slot 0: Initialize
    DEFW null_getstatus         ; slot 1: GetStatus (reuse null - always ready)
    DEFW cf_readblock           ; slot 2: ReadBlock
    DEFW cf_writeblock          ; slot 3: WriteBlock
    DEFW cf_seek                ; slot 4: Seek
    DEFW cf_bgetpos             ; slot 5: GetPosition
    DEFW cf_bgetsize            ; slot 6: GetLength
    DEFW un_error               ; slot 7: SetSize (not supported)
    DEFW un_error               ; slot 8: Close

; ============================================================
; PDTENTRY_CF ID, NAME, BASE
; Macro: Declare a ROM PDT entry for a CompactFlash block device.
; Arguments:
;   ID   - physical device ID (PHYSDEV_ID_*)
;   NAME - 2-character device name string (e.g. "CF")
;   BASE - I/O base port (8 sequential ports: data, features,
;          sector_count, sector_num, cyl_low, cyl_high, head, status)
; ============================================================
PDTENTRY_CF macro ID, NAME, BASE
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0, 0, 0           ; PHYSDEV_OFF_NAME (7 bytes: 2-char name + 5 nulls)
    DEFB DEVCAP_BLOCK_IN | DEVCAP_BLOCK_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_cf                         ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFS 4, 0                           ; LBA (4 bytes, zeroed at init)
    DEFB BASE + 0                       ; CF_DATA port
    DEFB BASE + 1                       ; CF_FEATURES/CF_ERROR port
    DEFB BASE + 2                       ; CF_SECTOR_COUNT port
    DEFB BASE + 3                       ; CF_SECTOR_NUM port
    DEFB BASE + 4                       ; CF_CYL_LOW port
    DEFB BASE + 5                       ; CF_CYL_HIGH port
    DEFB BASE + 6                       ; CF_HEAD port
    DEFB BASE + 7                       ; CF_STATUS/CF_COMMAND port
    DEFS 5, 0                           ; padding to fill 17-byte user data field
endm


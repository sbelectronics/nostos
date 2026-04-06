; ============================================================
; dup.asm - DUP (Duplicate Output) extension for NostOS
; Registers a character-output device that forwards each
; written character to two existing character devices.
;
; Usage: DUP.EXT name dev1 dev2
;   name - name for the new device (e.g. "BOTH")
;   dev1 - first target device name (e.g. "CON")
;   dev2 - second target device name (e.g. "VFD")
;
; Example: DUP.EXT BOTH CON VFD
;   Creates device "BOTH" that writes to both CON and VFD.
;
; Target device names are resolved to physical IDs at load
; time for zero-overhead dispatch on each character write.
; The resolved IDs are stored in the extension's own data
; section (which persists in memory after SYS_EXIT), so
; dup_writebyte is just two DEV_CWRITE syscalls.
; ============================================================

    INCLUDE "../../src/include/syscall.asm"
    INCLUDE "../../src/include/constants.asm"

    ORG  0

DUP_PHYSDEV_ID      EQU 0x00       ; dynamically allocated by DEV_COPY

; ============================================================
; Entry point
; ============================================================
dup_main:
    ; EXEC_ARGS_PTR points to "name dev1 dev2" (args after program name)
    LD   HL, (EXEC_ARGS_PTR)

    ; --- Arg 1: new device name → PDT name field ---
    CALL dup_skip_spaces
    CALL dup_check_eol
    JP   Z, dup_usage

    LD   DE, dup_pdt_name       ; write directly into PDT template
    LD   B, 6                   ; max 6 chars (7-byte field, 1 null)
    CALL dup_parse_token

    ; Reject empty device name (e.g. leading colon consumed as delimiter)
    LD   A, (dup_pdt_name)
    OR   A
    JP   Z, dup_usage

    ; --- Arg 2: first target device ---
    CALL dup_skip_spaces
    CALL dup_check_eol
    JP   Z, dup_usage

    LD   DE, dup_name_buf
    LD   B, 6
    CALL dup_parse_token
    XOR  A
    LD   (DE), A                ; null-terminate
    LD   (dup_save_hl), HL      ; save parse position across syscall

    LD   DE, dup_name_buf
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    OR   A
    JP   NZ, dup_err_dev1

    CALL dup_resolve_to_phys    ; HL = dev ID → A = physical ID
    LD   (dup_dev1_id), A

    CALL dup_check_char_out     ; verify DEVCAP_CHAR_OUT
    JP   Z, dup_err_caps1

    LD   HL, (dup_save_hl)      ; restore parse position

    ; --- Arg 3: second target device ---
    CALL dup_skip_spaces
    CALL dup_check_eol
    JP   Z, dup_usage

    LD   DE, dup_name_buf
    LD   B, 6
    CALL dup_parse_token
    XOR  A
    LD   (DE), A                ; null-terminate

    LD   DE, dup_name_buf
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    OR   A
    JP   NZ, dup_err_dev2

    CALL dup_resolve_to_phys
    LD   (dup_dev2_id), A

    CALL dup_check_char_out     ; verify DEVCAP_CHAR_OUT
    JP   Z, dup_err_caps2

    ; --- Register device via DEV_COPY ---
    LD   DE, dup_pdt
    LD   C, DEV_COPY
    CALL KERNELADDR
    OR   A
    JP   NZ, dup_err_reg

    ; Print success
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_ok
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Make extension resident
    LD   DE, dup_end
    LD   C, SYS_SET_MEMBOT
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Error / usage paths
; ============================================================
dup_usage:
    LD   DE, msg_usage
    JP   dup_print_exit

dup_err_dev1:
    LD   DE, msg_err_dev1
    JP   dup_print_exit

dup_err_dev2:
    LD   DE, msg_err_dev2
    JP   dup_print_exit

dup_err_caps1:
    LD   DE, msg_err_caps1
    JP   dup_print_exit

dup_err_caps2:
    LD   DE, msg_err_caps2
    JP   dup_print_exit

dup_err_reg:
    LD   DE, msg_err_reg

dup_print_exit:
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Driver functions
; ============================================================

; ------------------------------------------------------------
; dup_init / dup_getstatus
; Return ERR_SUCCESS.
; ------------------------------------------------------------
dup_init:
dup_getstatus:
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; dup_readbyte
; Output-only device — reading is not supported.
; ------------------------------------------------------------
dup_readbyte:
    LD   A, ERR_NOT_SUPPORTED
    LD   HL, 0
    RET

; ------------------------------------------------------------
; dup_writebyte
; Forward character to both target devices.
; Inputs:
;   B  - physical device ID (of DUP device, unused)
;   E  - character to write
; Outputs:
;   A  = ERR_SUCCESS
;   HL = 0
; ------------------------------------------------------------
dup_writebyte:
    PUSH BC
    PUSH DE

    ; Write to device 1
    LD   A, (dup_dev1_id)
    LD   B, A
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    ; Write to device 2 (E preserved by driver convention)
    LD   A, (dup_dev2_id)
    LD   B, A
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; Argument parsing helpers
; ============================================================

; ------------------------------------------------------------
; dup_parse_token
; Copy a token from (HL) to (DE), upcasing letters.
; Stops at space, null, CR, or colon.
; Inputs:
;   HL - source pointer
;   DE - destination buffer
;   B  - max characters to copy
; Outputs:
;   HL - points to the delimiter (space, null, CR) or past it (colon)
;   DE - points past last character written
;   B  - remaining count
; ------------------------------------------------------------
dup_parse_token:
    LD   A, (HL)
    OR   A
    RET  Z                      ; null → stop
    CP   0x0D
    RET  Z                      ; CR → stop
    CP   ' '
    RET  Z                      ; space → stop
    CP   ':'
    JP   Z, dup_pt_skip_delim   ; colon → skip it and stop
    ; Upcase if lowercase
    CP   'a'
    JP   C, dup_pt_store
    CP   'z' + 1
    JP   NC, dup_pt_store
    SUB  0x20
dup_pt_store:
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, dup_parse_token
    ; Max chars reached — skip rest of token
dup_pt_skip:
    LD   A, (HL)
    OR   A
    RET  Z
    CP   0x0D
    RET  Z
    CP   ' '
    RET  Z
    CP   ':'
    JP   Z, dup_pt_skip_delim
    INC  HL
    JP   dup_pt_skip
dup_pt_skip_delim:
    INC  HL                     ; advance past ':'
    RET

; ------------------------------------------------------------
; dup_skip_spaces
; Advance HL past any space characters.
; Inputs:
;   HL - pointer into buffer
; Outputs:
;   HL - pointer to first non-space char
; ------------------------------------------------------------
dup_skip_spaces:
    LD   A, (HL)
    CP   ' '
    RET  NZ
    INC  HL
    JP   dup_skip_spaces

; ------------------------------------------------------------
; dup_check_eol
; Check if (HL) is at end of input (null or CR).
; Outputs:
;   Z flag set if at end of line
; ------------------------------------------------------------
dup_check_eol:
    LD   A, (HL)
    OR   A
    RET  Z                      ; null → Z set
    CP   0x0D                   ; CR → Z set if match
    RET

; ------------------------------------------------------------
; dup_resolve_to_phys
; Resolve a device ID from DEV_LOOKUP to a physical device ID.
; If already physical (bit 7 clear), returns as-is.
; If logical (bit 7 set), navigates the logical device table
; to find the underlying physical device ID.
; Inputs:
;   HL - device ID from DEV_LOOKUP
; Outputs:
;   A  - physical device ID
; Clobbers: HL, DE
; ------------------------------------------------------------
dup_resolve_to_phys:
    LD   A, L
    AND  0x80
    JP   NZ, dup_resolve_logical
    LD   A, L                   ; already physical
    RET
dup_resolve_logical:
    ; Logical device index = L & 0x7F (strip logical bit)
    LD   A, L
    AND  0x7F
    ; Compute LOGDEV_TABLE + index * LOGDEV_ENTRY_SIZE(8) + LOGDEV_OFF_PHYSPTR(6)
    LD   L, A
    LD   H, 0
    ADD  HL, HL                 ; *2
    ADD  HL, HL                 ; *4
    ADD  HL, HL                 ; *8
    LD   DE, LOGDEV_TABLE + LOGDEV_OFF_PHYSPTR
    ADD  HL, DE                 ; HL = &logdev[index].physptr
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = physical device entry pointer
    LD   A, D
    OR   E
    JP   Z, dup_resolve_unassigned ; physptr == 0 → unassigned
    EX   DE, HL                 ; HL = physdev entry
    LD   DE, PHYSDEV_OFF_ID
    ADD  HL, DE                 ; HL = &physdev->id
    LD   A, (HL)                ; A = physical device ID
    RET
dup_resolve_unassigned:
    XOR  A                      ; A = 0 → will fail DEV_PHYS_GET in check
    RET

; ------------------------------------------------------------
; dup_check_char_out
; Verify that a device supports character output.
; Inputs:
;   A  - physical device ID
; Outputs:
;   NZ if device supports char output (ok), Z if not (fail)
; Clobbers: HL, DE, BC
; ------------------------------------------------------------
dup_check_char_out:
    LD   B, A                   ; B = physical device ID
    LD   C, DEV_PHYS_GET        ; → HL = PDT entry pointer
    CALL KERNELADDR
    OR   A
    JP   NZ, dup_check_fail     ; device not found → fail
    LD   DE, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  DEVCAP_CHAR_OUT        ; NZ if bit set (ok), Z if not (fail)
    RET
dup_check_fail:
    XOR  A                      ; set Z flag (fail)
    RET
dup_dev1_id:
    DEFB 0
dup_dev2_id:
    DEFB 0

; Temp storage for parse position across syscalls
dup_save_hl:
    DEFW 0

; Scratch buffer for device name lookup
dup_name_buf:
    DEFS 8, 0

; Messages
msg_usage:
    DEFM "Usage: DUP.EXT name dev1 dev2", 0x0D, 0x0A, 0
msg_ok:
    DEFM "DUP device registered.", 0x0D, 0x0A, 0
msg_err_dev1:
    DEFM "Device 1 not found.", 0x0D, 0x0A, 0
msg_err_dev2:
    DEFM "Device 2 not found.", 0x0D, 0x0A, 0
msg_err_caps1:
    DEFM "Device 1 not char output.", 0x0D, 0x0A, 0
msg_err_caps2:
    DEFM "Device 2 not char output.", 0x0D, 0x0A, 0
msg_err_reg:
    DEFM "Failed to register device.", 0x0D, 0x0A, 0

; ------------------------------------------------------------
; Device Function Table (char DFT, 4 slots)
; ------------------------------------------------------------
dup_dft:
    DEFW dup_init               ; slot 0: Initialize
    DEFW dup_getstatus          ; slot 1: GetStatus
    DEFW dup_readbyte           ; slot 2: ReadByte
    DEFW dup_writebyte          ; slot 3: WriteByte

; ------------------------------------------------------------
; PDT entry template — copied into RAM by DEV_COPY
; ------------------------------------------------------------
dup_pdt:
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB DUP_PHYSDEV_ID                 ; PHYSDEV_OFF_ID (0 = dynamic)
dup_pdt_name:
    DEFS 7, 0                           ; PHYSDEV_OFF_NAME (filled at runtime)
    DEFB DEVCAP_CHAR_OUT                ; PHYSDEV_OFF_CAPS (output only)
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dup_dft                        ; PHYSDEV_OFF_DFT
    DEFS 17, 0                          ; PHYSDEV_OFF_DATA (unused)

dup_end:

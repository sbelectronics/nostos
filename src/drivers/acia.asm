; NostOS ACIA (MC6850) Console Driver
; Polled I/O. Control/status and data ports dynamically mapped from PDT.
; ============================================================

; ------------------------------------------------------------
; acia_init
; Initialize the MC6850 ACIA.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
acia_init:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + ACIA_OFF_PORT_CTRL
    ADD  HL, DE
    LD   C, (HL)                ; C = control port

    LD   A, ACIA_RESET          ; master reset
    CALL tramp_out

    LD   A, ACIA_INIT           ; /64, 8N1, no interrupts
    CALL tramp_out

    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; acia_getstatus
; Check whether a character is waiting in the receive register.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 1 if character waiting, 0 otherwise
; ------------------------------------------------------------
acia_getstatus:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + ACIA_OFF_PORT_CTRL
    ADD  HL, DE
    LD   C, (HL)                ; C = control port

    CALL tramp_in
    AND  ACIA_RDRF              ; isolate RDRF bit
    LD   L, A                   ; L = 1 if char ready, else 0
    LD   H, 0
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    RET

; ------------------------------------------------------------
; acia_readbyte_raw
; Read one character from ACIA without echo (blocking).
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - character read (L = char, H = 0)
; ------------------------------------------------------------
acia_readbyte_raw:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE

    LD   D, (HL)                ; D = control port
    INC  HL
    LD   E, (HL)                ; E = data port

acia_readbyte_raw_wait:
    LD   C, D                   ; C = control port
    CALL tramp_in
    AND  ACIA_RDRF
    JP   Z, acia_readbyte_raw_wait

    LD   C, E                   ; C = data port
    CALL tramp_in
    LD   L, A
    LD   H, 0
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    RET

; ------------------------------------------------------------
; acia_writebyte
; Write one character to ACIA (blocking until TDRE).
; Inputs:
;   B  - physical device ID
;   E  - character to write
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
acia_writebyte:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve D and E
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE                 ; HL = user data ptr

    LD   B, (HL)                ; B = control port (internal use)
    INC  HL
    LD   C, (HL)                ; C = data port (internal use)
    POP  DE                     ; restore DE; E = char to write

acia_writebyte_wait:
    PUSH BC                     ; save ports
    LD   C, B                   ; C = control port
    CALL tramp_in
    POP  BC                     ; restore ports
    AND  ACIA_TDRE
    JP   Z, acia_writebyte_wait

    LD   A, E                   ; A = char to write
    CALL tramp_out              ; C = data port

    POP  BC                     ; restore original B (device ID) and C
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; Device Function Table for ACIA console (char DFT, 4 slots)
; ------------------------------------------------------------
dft_acia:
    DEFW acia_init              ; slot 0: Initialize
    DEFW acia_getstatus         ; slot 1: GetStatus
    DEFW acia_readbyte_raw      ; slot 2: ReadByte (raw, no echo)
    DEFW acia_writebyte         ; slot 3: WriteByte

; ============================================================
; PDTENTRY_ACIA ID, NAME, CTRL_PORT, DATA_PORT
; Macro: Declare a ROM PDT entry for an ACIA character device.
; Arguments:
;   ID        - physical device ID (PHYSDEV_ID_*)
;   NAME      - 4-character device name string (e.g. "ACIA")
;   CTRL_PORT - control/status register port
;   DATA_PORT - data register port
; ============================================================
PDTENTRY_ACIA macro ID, NAME, CTRL_PORT, DATA_PORT
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes: 4-char name + 3 nulls)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_acia                       ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFB CTRL_PORT                      ; ACIA control/status port
    DEFB DATA_PORT                      ; ACIA data port
    DEFS 15, 0                          ; padding to fill 17-byte user data field
endm


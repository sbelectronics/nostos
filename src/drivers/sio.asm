; NostOS SIO/2 (Z80 SIO) Serial Driver
; Polled I/O, dual-channel. Control/status and data ports dynamically
; mapped from PDT. Each channel is a separate physical device instance.
; ============================================================

; ------------------------------------------------------------
; sio_init
; Initialize one SIO/2 channel.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
sio_init:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + SIO_OFF_PORT_CTRL
    ADD  HL, DE
    LD   C, (HL)                ; C = control port
    INC  HL
    INC  HL                     ; skip data port
    LD   D, (HL)                ; D = WR4 value (baud divisor + format)

    ; Channel reset (WR0 command)
    ; Write reset twice: register pointer state is unknown at power-on,
    ; so first write may go to the wrong register. Second is guaranteed
    ; to hit WR0 since reset clears the pointer.
    LD   A, 0x18                ; WR0: channel reset
    CALL tramp_out
    LD   A, 0x18                ; WR0: channel reset (repeat)
    CALL tramp_out

    ; Configure baud rate and format (WR4)
    ; WR4 must be written before WR3/WR5 (before Tx/Rx enable)
    LD   A, 0x04                ; WR0: select register 4
    CALL tramp_out
    LD   A, D                   ; WR4 value from PDT user data
    CALL tramp_out

    ; Disable interrupts (WR1) — polled mode
    LD   A, 0x01                ; WR0: select register 1
    CALL tramp_out
    LD   A, 0x00                ; WR1: no interrupts
    CALL tramp_out

    ; Enable receiver (WR3)
    LD   A, 0x03                ; WR0: select register 3
    CALL tramp_out
    LD   A, 0xC1                ; WR3: Rx 8 bits/char, Rx enable
    CALL tramp_out

    ; Enable transmitter (WR5)
    LD   A, 0x05                ; WR0: select register 5
    CALL tramp_out
    LD   A, 0xEA                ; WR5: DTR, Tx 8 bits/char, Tx enable, RTS
    CALL tramp_out

    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; sio_getstatus
; Check whether a character is waiting in the receive buffer.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 1 if character waiting, 0 otherwise
; ------------------------------------------------------------
sio_getstatus:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + SIO_OFF_PORT_CTRL
    ADD  HL, DE
    LD   C, (HL)                ; C = control port

    CALL tramp_in               ; read RR0
    AND  SIO_RX_READY           ; isolate Rx ready bit
    LD   L, A                   ; L = 1 if char ready, else 0
    LD   H, 0
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    RET

; ------------------------------------------------------------
; sio_readbyte_raw
; Read one character from SIO/2 without echo (blocking).
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - character read (L = char, H = 0)
; ------------------------------------------------------------
sio_readbyte_raw:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE

    LD   D, (HL)                ; D = control port
    INC  HL
    LD   E, (HL)                ; E = data port

sio_readbyte_raw_wait:
    LD   C, D                   ; C = control port
    CALL tramp_in               ; read RR0
    AND  SIO_RX_READY
    JP   Z, sio_readbyte_raw_wait

    LD   C, E                   ; C = data port
    CALL tramp_in               ; read received byte
    LD   L, A
    LD   H, 0
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    RET

; ------------------------------------------------------------
; sio_writebyte
; Write one character to SIO/2 (blocking until Tx buffer empty).
; Inputs:
;   B  - physical device ID
;   E  - character to write
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
sio_writebyte:
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

sio_writebyte_wait:
    PUSH BC                     ; save ports
    LD   C, B                   ; C = control port
    CALL tramp_in               ; read RR0
    POP  BC                     ; restore ports
    AND  SIO_TX_EMPTY
    JP   Z, sio_writebyte_wait

    LD   A, E                   ; A = char to write
    CALL tramp_out              ; C = data port

    POP  BC                     ; restore original B (device ID) and C
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; Device Function Table for SIO/2 (char DFT, 4 slots)
; ------------------------------------------------------------
dft_sio:
    DEFW sio_init               ; slot 0: Initialize
    DEFW sio_getstatus          ; slot 1: GetStatus
    DEFW sio_readbyte_raw       ; slot 2: ReadByte (raw, no echo)
    DEFW sio_writebyte          ; slot 3: WriteByte

; ============================================================
; PDTENTRY_SIO ID, NAME, CTRL_PORT, DATA_PORT, WR4_VAL
; Macro: Declare a ROM PDT entry for an SIO/2 channel.
; Arguments:
;   ID        - physical device ID (PHYSDEV_ID_*)
;   NAME      - 4-character device name string (e.g. "SIOA")
;   CTRL_PORT - control/status register port for this channel
;   DATA_PORT - data register port for this channel
;   WR4_VAL   - WR4 register value (clock divisor + format, e.g. SIO_8N1_DIV16)
; ============================================================
PDTENTRY_SIO macro ID, NAME, CTRL_PORT, DATA_PORT, WR4_VAL
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes: 4-char name + 3 nulls)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_sio                        ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFB CTRL_PORT                      ; SIO control/status port
    DEFB DATA_PORT                      ; SIO data port
    DEFB WR4_VAL                        ; WR4: clock divisor + format
    DEFS 14, 0                          ; padding to fill 17-byte user data field
endm

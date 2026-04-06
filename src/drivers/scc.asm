; NostOS SCC (Z85C30) Serial Driver
; Polled I/O, dual-channel. Control/status and data ports dynamically
; mapped from PDT. Each channel is a separate physical device instance.
; Unlike SIO, the SCC has a built-in baud rate generator (BRG) configured
; via WR11-WR14. BRG time constant is stored in PDT user data.
;
; PDT user data layout:
;   byte 0: control/status port
;   byte 1: data port
;   byte 2: WR4 value (clock divisor + format)
;   byte 3: BRG time constant low (WR12)
;   byte 4: BRG time constant high (WR13)
; ============================================================

; ------------------------------------------------------------
; scc_init
; Initialize one SCC channel.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
scc_init:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + SCC_OFF_PORT_CTRL
    ADD  HL, DE
    LD   C, (HL)                ; C = control port
    INC  HL
    INC  HL                     ; skip data port
    LD   D, (HL)                ; D = WR4 value
    INC  HL
    LD   E, (HL)                ; E = BRG TC low (WR12)
    INC  HL
    LD   A, (HL)
    PUSH AF                     ; save BRG TC high (WR13) on stack

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

    ; Configure receiver bit width (WR3) — do NOT enable yet
    ; Rx/Tx must stay disabled until BRG clock is running,
    ; or the channel locks up with no clock source.
    LD   A, 0x03                ; WR0: select register 3
    CALL tramp_out
    LD   A, 0xC0                ; WR3: Rx 8 bits/char, Rx NOT enabled
    CALL tramp_out

    ; Configure transmitter bit width (WR5) — do NOT enable yet
    LD   A, 0x05                ; WR0: select register 5
    CALL tramp_out
    LD   A, 0xE2                ; WR5: DTR, Tx 8 bits/char, RTS, Tx NOT enabled
    CALL tramp_out

    ; Set clock source to BRG (WR11)
    LD   A, 0x0B                ; WR0: select register 11
    CALL tramp_out
    LD   A, SCC_WR11_BRG        ; Rx clock = BRG, Tx clock = BRG
    CALL tramp_out

    ; Set BRG time constant low byte (WR12)
    LD   A, 0x0C                ; WR0: select register 12
    CALL tramp_out
    LD   A, E                   ; WR12: TC low from PDT
    CALL tramp_out

    ; Set BRG time constant high byte (WR13)
    LD   A, 0x0D                ; WR0: select register 13
    CALL tramp_out
    POP  AF                     ; restore WR13 value
    CALL tramp_out

    ; Enable BRG with RTxC source (WR14)
    ; Set source first (disabled), then enable
    LD   A, 0x0E                ; WR0: select register 14
    CALL tramp_out
    LD   A, SCC_WR14_BRG_SRC    ; BRG source = RTxC, disabled
    CALL tramp_out
    LD   A, 0x0E                ; WR0: select register 14
    CALL tramp_out
    LD   A, SCC_WR14_BRG_ENA    ; BRG source = RTxC, enabled
    CALL tramp_out

    ; BRG is now running — safe to enable Rx and Tx

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

    ; Disable external/status interrupts (WR15)
    LD   A, 0x0F                ; WR0: select register 15
    CALL tramp_out
    LD   A, 0x00                ; WR15: no ext/status interrupts
    CALL tramp_out

    ; Reset ext/status interrupts (WR0 command: twice per Zilog manual)
    LD   A, 0x10                ; WR0: reset ext/status interrupts
    CALL tramp_out
    LD   A, 0x10                ; WR0: reset ext/status interrupts (repeat)
    CALL tramp_out

    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; scc_getstatus
; Check whether a character is waiting in the receive buffer.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 1 if character waiting, 0 otherwise
; ------------------------------------------------------------
scc_getstatus:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + SCC_OFF_PORT_CTRL
    ADD  HL, DE
    LD   C, (HL)                ; C = control port

    CALL tramp_in               ; read RR0
    AND  SCC_RX_READY           ; isolate Rx ready bit
    LD   L, A                   ; L = 1 if char ready, else 0
    LD   H, 0
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    RET

; ------------------------------------------------------------
; scc_readbyte_raw
; Read one character from SCC without echo (blocking).
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - character read (L = char, H = 0)
; ------------------------------------------------------------
scc_readbyte_raw:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE

    LD   D, (HL)                ; D = control port
    INC  HL
    LD   E, (HL)                ; E = data port

scc_readbyte_raw_wait:
    LD   C, D                   ; C = control port
    CALL tramp_in               ; read RR0
    AND  SCC_RX_READY
    JP   Z, scc_readbyte_raw_wait

    LD   C, E                   ; C = data port
    CALL tramp_in               ; read received byte
    LD   L, A
    LD   H, 0
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    RET

; ------------------------------------------------------------
; scc_writebyte
; Write one character to SCC (blocking until Tx buffer empty).
; Inputs:
;   B  - physical device ID
;   E  - character to write
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
scc_writebyte:
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

scc_writebyte_wait:
    PUSH BC                     ; save ports
    LD   C, B                   ; C = control port
    CALL tramp_in               ; read RR0
    POP  BC                     ; restore ports
    AND  SCC_TX_EMPTY
    JP   Z, scc_writebyte_wait

    LD   A, E                   ; A = char to write
    CALL tramp_out              ; C = data port

    POP  BC                     ; restore original B (device ID) and C
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; Device Function Table for SCC (char DFT, 4 slots)
; ------------------------------------------------------------
dft_scc:
    DEFW scc_init               ; slot 0: Initialize
    DEFW scc_getstatus          ; slot 1: GetStatus
    DEFW scc_readbyte_raw       ; slot 2: ReadByte (raw, no echo)
    DEFW scc_writebyte          ; slot 3: WriteByte

; ============================================================
; PDTENTRY_SCC ID, NAME, CTRL_PORT, DATA_PORT, WR4_VAL, BRG_TC_LO, BRG_TC_HI
; Macro: Declare a ROM PDT entry for an SCC channel.
; Arguments:
;   ID         - physical device ID (PHYSDEV_ID_*)
;   NAME       - 4-character device name string (e.g. "SCCA")
;   CTRL_PORT  - control/status register port for this channel
;   DATA_PORT  - data register port for this channel
;   WR4_VAL    - WR4 register value (clock divisor + format, e.g. SCC_8N1_DIV16)
;   BRG_TC_LO  - BRG time constant low byte (WR12)
;   BRG_TC_HI  - BRG time constant high byte (WR13)
; ============================================================
PDTENTRY_SCC macro ID, NAME, CTRL_PORT, DATA_PORT, WR4_VAL, BRG_TC_LO, BRG_TC_HI
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes: 4-char name + 3 nulls)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_scc                        ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFB CTRL_PORT                      ; control/status port
    DEFB DATA_PORT                      ; data port
    DEFB WR4_VAL                        ; WR4: clock divisor + format
    DEFB BRG_TC_LO                      ; WR12: BRG time constant low
    DEFB BRG_TC_HI                      ; WR13: BRG time constant high
    DEFS 12, 0                          ; padding to fill 17-byte user data field
endm

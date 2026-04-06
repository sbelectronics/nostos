; NostOS Z180 ASCI Serial Driver
; Polled I/O, dual-channel. Each channel is a separate physical device.
; PDT user data byte 0 = channel number (0 or 1).
; All port addresses are hardcoded from Z180 internal I/O base and
; computed at runtime as base_port + channel.
;
; This driver uses Z80 instructions (IN A,(C) / OUT (C),A) since the Z180
; is a Z80 superset.  These access Z180 internal I/O registers directly
; without needing the tramp_in/tramp_out thunks.
; B is set to 0 before all I/O (RomWBW convention).
; ============================================================

; ------------------------------------------------------------
; z180_get_channel
; Helper: load channel number from PDT user data.
; Inputs:
;   B  - physical device ID
; Outputs:
;   D  - channel number (0 or 1)
;   B  - 0 (ready for Z180 I/O)
; Clobbers: A, HL, E
; ------------------------------------------------------------
z180_get_channel:
    LD   A, B
    CALL find_physdev_by_id     ; HL = PDT entry
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   D, (HL)                ; D = channel (0 or 1)
    LD   B, 0                   ; B = 0 for Z180 internal I/O
    RET

; ------------------------------------------------------------
; z180_init
; Initialize one Z180 ASCI channel.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
z180_init:
    PUSH BC
    PUSH DE
    CALL z180_get_channel       ; D = channel, B = 0

    ; One-time setup: I/O remap + clock config (ch0 only).
    ; IMPORTANT: Channel 0 must be initialized before channel 1.
    ; The ASCI register accesses below use remapped ports (Z180_IO_BASE),
    ; which are only valid after the ICR write that ch0 performs here.
    LD   A, D
    AND  1                      ; channel 1?
    JP   NZ, z180_init_asci     ; skip — already done by ch0 init

    ; Remap Z180 internal I/O from 0x00-0x3F to Z180_IO_BASE (0xC0).
    ; ICR is always at port 0x3F regardless of current mapping.
    ; Must happen before any other Z180 register access at the new base.
    LD   C, Z180_ICR            ; port 0x3F
    LD   A, Z180_IO_BASE        ; 0xC0
    OUT  (C), A

    ; Enable full-speed clock.
    ; At reset, Z8S180 CCR bit 7 = 0 → PHI = XTAL/2 = 9.216 MHz.
    ; Set bit 7 → PHI = XTAL = 18.432 MHz (needed for 115200 baud).
    ; Per RomWBW: CMR must be written before CCR.
    LD   C, Z180_CMR            ; port 0xDE (clock multiplier)
    XOR  A                      ; A = 0 (no multiplier)
    OUT  (C), A                 ; write CMR first (required before CCR)
    LD   C, Z180_CCR            ; port 0x1F (clock divide)
    LD   A, 0x80                ; bit 7 = 1: PHI = XTAL (full speed)
    OUT  (C), A                 ; write CCR — PHI now = XTAL

z180_init_asci:
    ; Write CNTLA: 8N1, Rx+Tx enable
    LD   A, D
    ADD  A, Z180_CNTLA0         ; CNTLA port = 0x00 + channel
    LD   C, A
    LD   A, Z180_CNTLA_8N1      ; 0x64
    OUT  (C), A

    ; Write CNTLB: baud rate
    LD   A, D
    ADD  A, Z180_CNTLB0         ; CNTLB port = 0x02 + channel
    LD   C, A
    LD   A, Z180_BAUD_115200    ; 0x00
    OUT  (C), A

    ; Write STAT: clear all flags, no interrupts
    LD   A, D
    ADD  A, Z180_STAT0           ; STAT port = 0x04 + channel
    LD   C, A
    XOR  A
    OUT  (C), A

    ; Write ASEXT: disable CTS0/DCD0 flow control (ch0 only).
    ; Ch1 has no CTS/DCD hardware — skip or risk clobbering CKA1.
    LD   A, D
    AND  1                      ; channel 1?
    JP   NZ, z180_init_done
    LD   A, D
    ADD  A, Z180_ASEXT0          ; ASEXT port = 0x12 + channel
    LD   C, A
    LD   A, Z180_ASEXT_INIT      ; 0x60: DCD0 disable + CTS0 disable
    OUT  (C), A

z180_init_done:
    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; z180_getstatus
; Check whether a character is waiting in the receive buffer.
; Also clears any line errors (PE/FE/OVRN) via CNTLA EFR,
; or the receiver will stall (per Z180 datasheet / RomWBW).
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 1 if character waiting, 0 otherwise
; ------------------------------------------------------------
z180_getstatus:
    PUSH BC
    PUSH DE
    CALL z180_get_channel       ; D = channel, B = 0

    ; Read STAT
    LD   A, D
    ADD  A, Z180_STAT0
    LD   C, A
    IN   A, (C)
    LD   E, A                   ; E = saved STAT value

    ; Check for errors (PE=bit4, FE=bit5, OVRN=bit6)
    AND  0x70
    JP   Z, z180_gs_noerr
    ; Clear errors: read CNTLA, clear EFR (bit 3), write back
    LD   A, D
    ADD  A, Z180_CNTLA0         ; CNTLA port = 0x00 + channel
    LD   C, A
    IN   A, (C)
    AND  0xF7                   ; clear bit 3 (EFR=0 resets errors)
    OUT  (C), A
z180_gs_noerr:
    LD   A, E                   ; restore STAT
    AND  Z180_RDRF              ; bit 7: data ready?
    JP   Z, z180_gs_empty
    LD   L, 1
    JP   z180_gs_done
z180_gs_empty:
    LD   L, 0
z180_gs_done:
    LD   H, 0
    POP  DE
    POP  BC
    XOR  A
    RET

; ------------------------------------------------------------
; z180_readbyte_raw
; Read one character from Z180 ASCI without echo (blocking).
; Clears line errors in the wait loop to prevent receiver stall.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - character read (L = char, H = 0)
; ------------------------------------------------------------
z180_readbyte_raw:
    PUSH BC
    PUSH DE
    CALL z180_get_channel       ; D = channel, B = 0

z180_rb_wait:
    ; Read STAT
    LD   A, D
    ADD  A, Z180_STAT0
    LD   C, A
    IN   A, (C)
    LD   E, A                   ; E = saved STAT

    ; Clear errors if present
    AND  0x70                   ; PE | FE | OVRN
    JP   Z, z180_rb_noerr
    LD   A, D
    ADD  A, Z180_CNTLA0         ; CNTLA port = 0x00 + channel
    LD   C, A
    IN   A, (C)
    AND  0xF7                   ; clear EFR
    OUT  (C), A
z180_rb_noerr:
    LD   A, E                   ; restore STAT
    AND  Z180_RDRF
    JP   Z, z180_rb_wait

    ; Read character from RDR
    LD   A, D
    ADD  A, Z180_RDR0
    LD   C, A
    IN   A, (C)
    LD   L, A
    LD   H, 0
    POP  DE
    POP  BC
    XOR  A
    RET

; ------------------------------------------------------------
; z180_writebyte
; Write one character to Z180 ASCI (blocking until TDRE set).
; Inputs:
;   B  - physical device ID
;   E  - character to write
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
z180_writebyte:
    PUSH BC
    PUSH DE                     ; save E = char to write
    LD   A, B
    CALL find_physdev_by_id     ; HL = PDT entry
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   A, (HL)                ; A = channel
    LD   L, A                   ; L = channel (survives POP DE)
    POP  DE                     ; restore E = char to write
    LD   B, 0                   ; B = 0 for Z180 I/O

z180_wb_wait:
    LD   A, L                   ; A = channel
    ADD  A, Z180_STAT0
    LD   C, A                   ; C = STAT port
    IN   A, (C)
    AND  Z180_TDRE              ; bit 1: Tx empty?
    JP   Z, z180_wb_wait

    LD   A, L                   ; A = channel
    ADD  A, Z180_TDR0
    LD   C, A                   ; C = TDR port
    LD   A, E                   ; A = char to write
    OUT  (C), A

    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; Device Function Table for Z180 ASCI (char DFT, 4 slots)
; ------------------------------------------------------------
dft_z180:
    DEFW z180_init              ; slot 0: Initialize
    DEFW z180_getstatus         ; slot 1: GetStatus
    DEFW z180_readbyte_raw      ; slot 2: ReadByte (raw, no echo)
    DEFW z180_writebyte         ; slot 3: WriteByte

; ============================================================
; PDTENTRY_Z180 ID, NAME, CHANNEL
; Macro: Declare a ROM PDT entry for a Z180 ASCI channel.
; Arguments:
;   ID      - physical device ID (PHYSDEV_ID_Z180A or Z180B)
;   NAME    - 4-character device name string (e.g. "ASC0")
;   CHANNEL - channel number: 0 for ASCI0, 1 for ASCI1
; ============================================================
PDTENTRY_Z180 macro ID, NAME, CHANNEL
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes: 4-char name + 3 nulls)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_z180                       ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFB CHANNEL                        ; channel number (0 or 1)
    DEFS 16, 0                          ; padding
endm

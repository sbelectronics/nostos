; ============================================================
; NostOS Interrupt-Driven Z180 ASCI Serial Driver
;
; Channels 0 and 1 of one Z180 chip; Rx via vectored interrupt +
; ring buffer; Tx polled.  Limit: ONE Z180 chip system-wide.
;
; Mutually exclusive with the other interrupt UART drivers — they
; use IM 1 / RST 38, this one uses IM 2 / vectored, and the CPU
; can only be in one IM mode at a time.  See kernel.asm.
;
; --- Z80-family-only instructions used ---
; This driver is NOT 8080-compatible and never was: the Z180 is a
; Z80 superset, so its drivers (polled z180.asm and this one) can
; freely use Z80-specific I/O.  All other NostOS code stays 8080-
; clean; the Z180 family is the one exception, independent of any
; interrupt-driver waiver.
;
;   DI / EI / RETI         in the ISR and read path
;   IM 2 / LD I, A         in platform_init
;   IN A,(C) / OUT (C),A   throughout — per-channel ASCI register
;                          addressing computes the port at runtime
;                          (C = base + channel_offset), which needs
;                          register-indirect I/O.
;
; --- Vectored vs RST 38 dispatch ---
; The Z180 ASCI uses internal vectored interrupts.  Each channel
; has its own ISR (z180_int_isr_a / z180_int_isr_b) reached via a
; vector table whose base is set by the I register and IL.  No
; scan loop in the ISR; the hardware picks the right entry point.
;
; --- Why this driver looks different from sio_int / scc_int ---
; Because IN A,(C) / OUT (C),A is available, ASCI port addresses
; can be computed at runtime as base + channel_offset.  That means
; init/getstatus/readbyte/writebyte can all be ONE function each
; that branches on the channel index from PDT user data — no need
; to split into per-channel function pairs the way sio_int and
; scc_int do.  Only the ISRs are split, because the hardware
; vector dispatch sends each channel to a different entry point
; (z180_int_isr_a / z180_int_isr_b).
;
; --- Receiver-stall quirk ---
; If a line error (parity/framing/overrun) occurs, the bit latches
; in STAT and the receiver STALLS until the Error Flag Reset (EFR)
; bit is cleared in CNTLA.  This is non-obvious and has bitten a
; lot of Z180 drivers.  The ISR clears errors before reading RDR,
; so by the time a byte reaches the ring buffer, any latch has
; already been cleared.  z180_int_readbyte_raw only touches the
; software ring and never the hardware, so it doesn't need to
; replicate the error-clear logic.
; ============================================================

; PDT user data layout (within PHYSDEV_OFF_DATA):
;   +0  channel number (0 or 1)
; (No port info — Z180 ASCI ports are computed from the channel
;  number plus a fixed base, just like polled z180.asm.)
Z180_INT_PDT_OFF_CHAN EQU 0

; ------------------------------------------------------------
; z180_int_get_channel
; Helper: load channel number from PDT user data.
; Inputs:
;   B  - physical device ID
; Outputs:
;   D  - channel number (0 or 1)
;   B  - 0 (ready for Z180 I/O)
; Clobbers: A, HL, E
; ------------------------------------------------------------
z180_int_get_channel:
    LD   A, B
    CALL find_physdev_by_id     ; HL = PDT entry
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   D, (HL)                ; D = channel (0 or 1)
    LD   B, 0                   ; B = 0 for Z180 internal I/O
    RET

; ------------------------------------------------------------
; z180_int_init
; Initialise one Z180 ASCI channel.  Channel 0's init also does
; the chip-wide I/O remap (ICR) and CPU clock config (CMR/CCR);
; channel 1's init skips those steps.  IMPORTANT: ASC0 must be
; initialised before ASC1 because the ASCI register accesses below
; use remapped ports that are only valid after the ICR write.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
z180_int_init:
    DI                          ; register state must be stable
    PUSH BC
    PUSH DE
    CALL z180_int_get_channel   ; D = channel, B = 0

    LD   A, D
    OR   A
    JP   NZ, z180_int_init_zero_b
    XOR  A
    LD   (RINGBUF_HEAD_A), A
    LD   (RINGBUF_TAIL_A), A
    LD   (RINGBUF_COUNT_A), A
    JP   z180_int_init_zero_done
z180_int_init_zero_b:
    XOR  A
    LD   (RINGBUF_HEAD_B), A
    LD   (RINGBUF_TAIL_B), A
    LD   (RINGBUF_COUNT_B), A
z180_int_init_zero_done:

    LD   A, D
    AND  1                      ; channel 1 skips the chip-wide setup
    JP   NZ, z180_int_init_asci

    ; Remap internal I/O from 0x00-0x3F to Z180_IO_BASE (0xC0).
    ; ICR itself is at port 0x3F regardless of remap state.  After
    ; this write, all the ASCI register constants below resolve to
    ; the new base; before this write they wouldn't.
    LD   C, Z180_ICR
    LD   A, Z180_IO_BASE
    OUT  (C), A

    ; Switch from reset-default half-speed clock to full speed.
    ; The Z8S180 boots with PHI = XTAL/2; bit 7 of CCR drops the
    ; divider so PHI = XTAL.  Per Zilog, CMR must be written before
    ; CCR — the multiplier register has to be valid first.
    LD   C, Z180_CMR
    XOR  A
    OUT  (C), A
    LD   C, Z180_CCR
    LD   A, 0x80
    OUT  (C), A

z180_int_init_asci:
    ; CNTLA = 8N1, Rx+Tx enable, RTS0 asserted (channel 0 only on RTS).
    LD   A, D
    ADD  A, Z180_CNTLA0
    LD   C, A
    LD   A, Z180_CNTLA_8N1
    OUT  (C), A

    ; CNTLB = baud rate select (115200 by default).
    LD   A, D
    ADD  A, Z180_CNTLB0
    LD   C, A
    LD   A, Z180_BAUD_115200
    OUT  (C), A

    ; STAT = clear flags + enable Rx interrupt.
    LD   A, D
    ADD  A, Z180_STAT0
    LD   C, A
    LD   A, Z180_STAT_RIE
    OUT  (C), A

    ; ASEXT (channel 0 only): disable CTS0/DCD0 hardware flow control.
    ; Without this, an unconnected DCD0 holds the transmitter off.
    ; Channel 1 has no equivalent register on most Z180 packages.
    LD   A, D
    AND  1
    JP   NZ, z180_int_init_done
    LD   A, D
    ADD  A, Z180_ASEXT0
    LD   C, A
    LD   A, Z180_ASEXT_INIT
    OUT  (C), A

z180_int_init_done:
    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; z180_int_getstatus
; Return whether a character is waiting in this channel's ring buffer.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 1 if character waiting, 0 otherwise
; ------------------------------------------------------------
z180_int_getstatus:
    PUSH BC
    PUSH DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + Z180_INT_PDT_OFF_CHAN
    ADD  HL, DE
    LD   A, (HL)                ; A = channel index
    OR   A
    JP   NZ, z180_int_getstatus_b
    LD   A, (RINGBUF_COUNT_A)
    JP   z180_int_getstatus_done
z180_int_getstatus_b:
    LD   A, (RINGBUF_COUNT_B)
z180_int_getstatus_done:
    LD   H, 0
    LD   L, 0
    OR   A
    JP   Z, z180_int_getstatus_ret
    INC  L
z180_int_getstatus_ret:
    POP  DE
    POP  BC
    XOR  A
    RET

; ------------------------------------------------------------
; z180_int_readbyte_raw
; Read one character from this channel's ring buffer (blocking).
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - character read (L = char, H = 0)
; ------------------------------------------------------------
z180_int_readbyte_raw:
    PUSH BC                     ; preserve B (device ID)
    PUSH DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + Z180_INT_PDT_OFF_CHAN
    ADD  HL, DE
    LD   A, (HL)                ; A = channel index
    OR   A
    JP   NZ, z180_int_read_b

; -------- channel 0 --------
z180_int_read_a_wait:
    LD   A, (RINGBUF_COUNT_A)
    OR   A
    JP   Z, z180_int_read_a_wait

    DI
    LD   A, (RINGBUF_TAIL_A)
    LD   E, A
    LD   D, 0
    LD   HL, RINGBUF_A
    ADD  HL, DE
    LD   E, (HL)                ; E = byte read

    INC  A
    AND  RINGBUF_MASK
    LD   (RINGBUF_TAIL_A), A

    LD   A, (RINGBUF_COUNT_A)
    DEC  A
    LD   (RINGBUF_COUNT_A), A

    CP   RINGBUF_LOW_WATER
    JP   NC, z180_int_read_a_norts

    ; Below low-water: drop RTS0 to let the sender resume.
    ; Z180_CNTLA_8N1 has RTS0 bit clear, so the same constant we
    ; init'd with also serves as the "RTS asserted" value.
    LD   B, 0
    LD   C, Z180_CNTLA0
    LD   A, Z180_CNTLA_8N1
    OUT  (C), A
z180_int_read_a_norts:
    EI
    LD   L, E                   ; return char in L
    LD   H, 0
    POP  DE
    POP  BC
    XOR  A
    RET

; -------- channel 1 --------
z180_int_read_b:
z180_int_read_b_wait:
    LD   A, (RINGBUF_COUNT_B)
    OR   A
    JP   Z, z180_int_read_b_wait

    DI
    LD   A, (RINGBUF_TAIL_B)
    LD   E, A
    LD   D, 0
    LD   HL, RINGBUF_B
    ADD  HL, DE
    LD   E, (HL)

    INC  A
    AND  RINGBUF_MASK
    LD   (RINGBUF_TAIL_B), A

    LD   A, (RINGBUF_COUNT_B)
    DEC  A
    LD   (RINGBUF_COUNT_B), A

    ; Channel 1 has no RTS pin on most Z180 packages — no throttle release.

    EI
    LD   L, E
    LD   H, 0
    POP  DE
    POP  BC
    XOR  A
    RET

; ------------------------------------------------------------
; z180_int_writebyte
; Polled Tx, identical pattern to polled z180_writebyte.
; Inputs:
;   B  - physical device ID
;   E  - character to write
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
z180_int_writebyte:
    PUSH BC
    PUSH DE                     ; preserve E across the PDT lookup
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   A, (HL)
    LD   L, A                   ; stash channel in L (survives POP DE)
    POP  DE                     ; restore E
    LD   B, 0                   ; B = 0 for Z180 internal I/O

z180_int_writebyte_wait:
    LD   A, L
    ADD  A, Z180_STAT0
    LD   C, A
    IN   A, (C)
    AND  Z180_TDRE
    JP   Z, z180_int_writebyte_wait

    LD   A, L
    ADD  A, Z180_TDR0
    LD   C, A
    LD   A, E
    OUT  (C), A

    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; z180_int_isr_a
; ASCI channel 0 ISR.  Hardware-dispatched via the Z180 vector
; table at Z180_INTVEC_TABLE + Z180_VEC_OFF_ASCI0.
; ============================================================
z180_int_isr_a:
    PUSH AF
    PUSH HL
    PUSH DE
    PUSH BC

    LD   B, 0
    LD   C, Z180_STAT0
    IN   A, (C)
    LD   E, A                   ; save STAT — we need it intact below

    ; Clear any latched line errors before reading RDR.  Bits 4-6
    ; of STAT (PE/FE/OVRN) latch on error and the receiver stalls
    ; until they're cleared via the EFR strobe in CNTLA — see the
    ; receiver-stall note in the file header.
    AND  0x70
    JP   Z, z180_int_isr_a_noerr
    LD   C, Z180_CNTLA0
    IN   A, (C)
    AND  0xF7                   ; clear bit 3 (EFR) — clears the latches
    OUT  (C), A
z180_int_isr_a_noerr:
    LD   A, E                   ; restore STAT
    AND  Z180_RDRF
    JP   Z, z180_int_isr_a_done ; no byte ready (spurious / already drained)

    LD   C, Z180_RDR0
    IN   A, (C)                 ; reading RDR clears RDRF
    LD   E, A

    LD   A, (RINGBUF_COUNT_A)
    CP   RINGBUF_SIZE
    JP   Z, z180_int_isr_a_done ; buffer full -> drop

    ; Append at HEAD, advance HEAD (modulo RINGBUF_SIZE), bump COUNT.
    LD   A, (RINGBUF_HEAD_A)
    LD   L, A
    LD   H, 0
    PUSH HL
    LD   HL, RINGBUF_A
    POP  BC                     ; BC = head index
    ADD  HL, BC
    LD   (HL), E

    LD   A, C
    INC  A
    AND  RINGBUF_MASK
    LD   (RINGBUF_HEAD_A), A

    LD   A, (RINGBUF_COUNT_A)
    INC  A
    LD   (RINGBUF_COUNT_A), A
    CP   RINGBUF_HIGH_WATER
    JP   C, z180_int_isr_a_done

    ; At/above high-water: assert RTS0 to throttle the sender.
    LD   B, 0
    LD   C, Z180_CNTLA0
    LD   A, Z180_CNTLA0_RTS_HIGH
    OUT  (C), A

z180_int_isr_a_done:
    POP  BC
    POP  DE
    POP  HL
    POP  AF
    EI
    RETI

; ============================================================
; z180_int_isr_b
; ASCI channel 1 ISR.  Mirror of channel 0 except: no RTS throttle
; (channel 1 has no RTS pin on most Z180 packages, so a full ring
; buffer just drops bytes).
; ============================================================
z180_int_isr_b:
    PUSH AF
    PUSH HL
    PUSH DE
    PUSH BC

    LD   B, 0
    LD   C, Z180_STAT1
    IN   A, (C)
    LD   E, A

    AND  0x70                   ; PE | FE | OVRN — clear via EFR if any
    JP   Z, z180_int_isr_b_noerr
    LD   C, Z180_CNTLA1
    IN   A, (C)
    AND  0xF7
    OUT  (C), A
z180_int_isr_b_noerr:
    LD   A, E
    AND  Z180_RDRF
    JP   Z, z180_int_isr_b_done

    LD   C, Z180_RDR1
    IN   A, (C)
    LD   E, A

    LD   A, (RINGBUF_COUNT_B)
    CP   RINGBUF_SIZE
    JP   Z, z180_int_isr_b_done

    LD   A, (RINGBUF_HEAD_B)
    LD   L, A
    LD   H, 0
    PUSH HL
    LD   HL, RINGBUF_B
    POP  BC
    ADD  HL, BC
    LD   (HL), E

    LD   A, C
    INC  A
    AND  RINGBUF_MASK
    LD   (RINGBUF_HEAD_B), A

    LD   A, (RINGBUF_COUNT_B)
    INC  A
    LD   (RINGBUF_COUNT_B), A
    ; No throttle: channel 1 has no RTS.

z180_int_isr_b_done:
    POP  BC
    POP  DE
    POP  HL
    POP  AF
    EI
    RETI

; ============================================================
; z180_int_isr_spurious
; Default handler for the 7 internal interrupt sources we don't
; enable (INT1/2, PRT0/1, DMA0/1, CSI/O).  Their vector slots
; need to point somewhere safe in case a peripheral asserts an
; interrupt despite its enable bit being off — better to bounce
; out cleanly than jump into garbage RAM.
; ============================================================
z180_int_isr_spurious:
    EI
    RETI

; ------------------------------------------------------------
; Device Function Table — one shared by both ASCI channels.
; (Unlike sio_int/scc_int, this driver branches on the channel
; index inside each function rather than splitting per-channel.)
; ------------------------------------------------------------
dft_z180_int:
    DEFW z180_int_init          ; slot 0: Initialize
    DEFW z180_int_getstatus     ; slot 1: GetStatus
    DEFW z180_int_readbyte_raw  ; slot 2: ReadByte (raw, no echo)
    DEFW z180_int_writebyte     ; slot 3: WriteByte

; ============================================================
; PDTENTRY_Z180_INT ID, NAME, CHANNEL  (CHANNEL = 0 or 1)
; ============================================================
PDTENTRY_Z180_INT macro ID, NAME, CHANNEL
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_z180_int                   ; PHYSDEV_OFF_DFT
    DEFB CHANNEL                        ; +0 channel number (0 or 1)
    DEFS 16, 0                          ; padding to fill 17-byte user data
endm

; ============================================================
; NostOS Interrupt-Driven SIO/2 Serial Driver
;
; Channels A and B of one SIO/2 chip; Rx via interrupt + ring
; buffer; Tx polled.  Limit: ONE such chip system-wide.  The
; polled sio.asm may also be present in the same build for
; additional polled SIO chips.
;
; Mutually exclusive with the other interrupt UART drivers (they
; all claim IM 1 / RST 38, except z180_int which claims IM 2).
; See kernel.asm for the variant chain.
;
; Z80-only instructions used: DI / EI / RETI in the ISR and read
; path.  IM 1 / EI for global enable lives in platform_init.
;
; --- Hardcoded ports ---
; SIO_CTRL_A / SIO_DATA_A / SIO_CTRL_B / SIO_DATA_B appear as
; immediate operands on every IN/OUT in this file.  The ISR cannot
; use tramp_in/tramp_out (the shared workspace thunk would race
; with main code), and 8080 IN n / OUT n encodes the port as an
; immediate, so the ISR can only reach compile-time-fixed ports.
; Once the ISR is locked, nothing else in the driver looks ports
; up from PDT either; the macros take no port arguments.
;
; --- Per-channel function pairs ---
; The two channels' code is symmetric but uses different port
; constants, so each DFT slot has a per-channel implementation:
; init_a/init_b, getstatus_a/getstatus_b, etc.  Two DFTs
; (dft_sio_int_a / dft_sio_int_b) bind the right pair, and
; PDTENTRY_SIO_INT_A / PDTENTRY_SIO_INT_B point each PDT entry
; at its DFT.  No runtime channel branching.
;
; --- Port map selection ---
; Standard RC2014 vs Scott's-board SIO wiring is selected by the
; SIO_USE_SB build flag, which switches the SIO_CTRL_* / SIO_DATA_*
; constants in constants.asm.  Both polled and interrupt-driven
; SIO drivers consume the same constants, so the flag affects both.
; ============================================================

; PDT user data layout (within PHYSDEV_OFF_DATA):
;   +0  WR4 value (1 byte)
;   (no channel index — the DFT selects which channel's functions
;    run, so the channel is encoded by which DFT the PDT points at)
SIO_INT_PDT_OFF_WR4  EQU 0

; ============================================================
; Channel A entry points
; ============================================================

; ------------------------------------------------------------
; sio_int_init_a
; Initialise SIO/2 channel A.  Reads WR4 from PDT user data.
; Interrupts stay disabled on exit; the chip-wide IM 1 / EI is
; deferred to platform_init so both channels are fully programmed
; (and their bookkeeping zeroed) before any ISR can fire.
;
; SIO register programming uses a two-step pattern: write the
; register number to WR0, then write the data to the same control
; port.  This is the standard Z80 SIO interface — see Zilog UM008.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
sio_int_init_a:
    DI                          ; SIO WR pointer state must be stable
    PUSH BC                     ; preserve B (device ID)
    PUSH DE

    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + SIO_INT_PDT_OFF_WR4
    ADD  HL, DE
    LD   D, (HL)                ; D = WR4 value (clock + format)

    XOR  A
    LD   (RINGBUF_HEAD_A), A
    LD   (RINGBUF_TAIL_A), A
    LD   (RINGBUF_COUNT_A), A

    ; Channel reset.  Written twice because WR0's pointer field is
    ; unknown at power-on; the first write may select the wrong
    ; register, the second is guaranteed to land on WR0 because
    ; the first reset cleared the pointer.
    LD   A, 0x18
    OUT  (SIO_CTRL_A), A
    LD   A, 0x18
    OUT  (SIO_CTRL_A), A

    ; WR4: clock divisor + character format.  Must come before
    ; WR3/WR5 (Rx/Tx enable) per the SIO datasheet's setup order.
    LD   A, 0x04
    OUT  (SIO_CTRL_A), A
    LD   A, D
    OUT  (SIO_CTRL_A), A

    ; WR1 = 0x18: "interrupt on all Rx characters" mode.
    LD   A, 0x01
    OUT  (SIO_CTRL_A), A
    LD   A, 0x18
    OUT  (SIO_CTRL_A), A

    ; WR3 = 0xE1: Rx 8-bit, auto-enables, Rx enable.
    LD   A, 0x03
    OUT  (SIO_CTRL_A), A
    LD   A, 0xE1
    OUT  (SIO_CTRL_A), A

    ; WR5 = SIO_RTS_LOW: DTR, Tx 8-bit, Tx enable, RTS asserted.
    LD   A, 0x05
    OUT  (SIO_CTRL_A), A
    LD   A, SIO_RTS_LOW
    OUT  (SIO_CTRL_A), A

    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; sio_int_getstatus_a
; Return whether a character is waiting in channel A's ring buffer.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 1 if character waiting, 0 otherwise
; ------------------------------------------------------------
sio_int_getstatus_a:
    LD   A, (RINGBUF_COUNT_A)
    LD   H, 0
    LD   L, 0
    OR   A
    JP   Z, sio_int_getstatus_a_ret
    INC  L
sio_int_getstatus_a_ret:
    XOR  A
    RET

; ------------------------------------------------------------
; sio_int_readbyte_raw_a
; Read one character from channel A's ring buffer (blocking).
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - character read (L = char, H = 0)
; ------------------------------------------------------------
sio_int_readbyte_raw_a:
    PUSH BC                     ; preserve B (device ID)
    PUSH DE
sio_int_read_a_wait:
    LD   A, (RINGBUF_COUNT_A)
    OR   A
    JP   Z, sio_int_read_a_wait

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
    JP   NC, sio_int_read_a_norts

    ; Below low-water: drop RTS to let the sender resume.
    LD   A, 0x05
    OUT  (SIO_CTRL_A), A
    LD   A, SIO_RTS_LOW
    OUT  (SIO_CTRL_A), A
sio_int_read_a_norts:
    EI
    LD   L, E                   ; return char in L
    LD   H, 0
    POP  DE
    POP  BC
    XOR  A
    RET

; ------------------------------------------------------------
; sio_int_writebyte_a
; Write one character to channel A (polled, blocks until Tx empty).
; Inputs:
;   B  - physical device ID
;   E  - character to write
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
sio_int_writebyte_a:
sio_int_writebyte_a_wait:
    IN   A, (SIO_CTRL_A)        ; A = RR0
    AND  SIO_TX_EMPTY
    JP   Z, sio_int_writebyte_a_wait
    LD   A, E
    OUT  (SIO_DATA_A), A
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; Channel B entry points
; ============================================================

; ------------------------------------------------------------
; sio_int_init_b
; Initialise SIO/2 channel B.  Same shape as sio_int_init_a, plus
; the WR2 vector-base write (which physically lives on channel B
; on the SIO/2 even though it's a chip-wide setting).
; ------------------------------------------------------------
sio_int_init_b:
    DI
    PUSH BC
    PUSH DE

    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + SIO_INT_PDT_OFF_WR4
    ADD  HL, DE
    LD   D, (HL)                ; D = WR4 value

    XOR  A
    LD   (RINGBUF_HEAD_B), A
    LD   (RINGBUF_TAIL_B), A
    LD   (RINGBUF_COUNT_B), A

    LD   A, 0x18                ; channel reset (twice; see init_a)
    OUT  (SIO_CTRL_B), A
    LD   A, 0x18
    OUT  (SIO_CTRL_B), A

    LD   A, 0x04                ; WR4 = clock + format
    OUT  (SIO_CTRL_B), A
    LD   A, D
    OUT  (SIO_CTRL_B), A

    LD   A, 0x01                ; WR1 = Rx int on all chars
    OUT  (SIO_CTRL_B), A
    LD   A, 0x18
    OUT  (SIO_CTRL_B), A

    ; WR2 = interrupt vector base.  Unused under IM 1 (the CPU
    ; never reads the SIO's vector byte) but the SIO datasheet
    ; calls for it during init regardless, and the Searle BASIC
    ; reference programs it.  Written here for completeness.
    LD   A, 0x02
    OUT  (SIO_CTRL_B), A
    LD   A, 0xE0
    OUT  (SIO_CTRL_B), A

    LD   A, 0x03                ; WR3 = Rx 8-bit, auto-enables, Rx enable
    OUT  (SIO_CTRL_B), A
    LD   A, 0xE1
    OUT  (SIO_CTRL_B), A

    LD   A, 0x05                ; WR5 = DTR, Tx 8-bit, Tx enable, RTS low
    OUT  (SIO_CTRL_B), A
    LD   A, SIO_RTS_LOW
    OUT  (SIO_CTRL_B), A

    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; sio_int_getstatus_b
; Return whether a character is waiting in channel B's ring buffer.
; ------------------------------------------------------------
sio_int_getstatus_b:
    LD   A, (RINGBUF_COUNT_B)
    LD   H, 0
    LD   L, 0
    OR   A
    JP   Z, sio_int_getstatus_b_ret
    INC  L
sio_int_getstatus_b_ret:
    XOR  A
    RET

; ------------------------------------------------------------
; sio_int_readbyte_raw_b
; Read one character from channel B's ring buffer (blocking).
; ------------------------------------------------------------
sio_int_readbyte_raw_b:
    PUSH BC
    PUSH DE
sio_int_read_b_wait:
    LD   A, (RINGBUF_COUNT_B)
    OR   A
    JP   Z, sio_int_read_b_wait

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

    CP   RINGBUF_LOW_WATER
    JP   NC, sio_int_read_b_norts

    LD   A, 0x05
    OUT  (SIO_CTRL_B), A
    LD   A, SIO_RTS_LOW
    OUT  (SIO_CTRL_B), A
sio_int_read_b_norts:
    EI
    LD   L, E
    LD   H, 0
    POP  DE
    POP  BC
    XOR  A
    RET

; ------------------------------------------------------------
; sio_int_writebyte_b
; Write one character to channel B (polled).
; ------------------------------------------------------------
sio_int_writebyte_b:
sio_int_writebyte_b_wait:
    IN   A, (SIO_CTRL_B)
    AND  SIO_TX_EMPTY
    JP   Z, sio_int_writebyte_b_wait
    LD   A, E
    OUT  (SIO_DATA_B), A
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; sio_int_isr
; RST 38 / IM 1 entry.  Drains any pending Rx byte from each
; channel into its ring buffer, asserting RTS-high on high-water
; approach.  Reached directly via RST7_RAM_VEC (installed by
; platform_init); does NOT dispatch through the DFT.
;
; The two channel paths are inlined as straight-line code rather
; than a loop because (a) there are only two channels and (b)
; direct IN/OUT requires immediate ports — the same reason the
; rest of the driver hardcodes per-channel functions.
; ============================================================
sio_int_isr:
    PUSH AF
    PUSH HL
    PUSH DE
    PUSH BC

; --- Channel A ---
    XOR  A
    OUT  (SIO_CTRL_A), A        ; WR0 = 0 (select RR0 for next read)
    IN   A, (SIO_CTRL_A)        ; A = RR0 status
    AND  SIO_RX_READY
    JP   Z, sio_int_isr_chk_b

    IN   A, (SIO_DATA_A)
    LD   E, A
    LD   A, (RINGBUF_COUNT_A)
    CP   RINGBUF_SIZE
    JP   Z, sio_int_isr_chk_b   ; buffer full -> drop

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
    JP   C, sio_int_isr_chk_b

    ; At/above high-water: WR5 RTS-high to throttle the sender.
    LD   A, 0x05
    OUT  (SIO_CTRL_A), A
    LD   A, SIO_RTS_HIGH
    OUT  (SIO_CTRL_A), A

; --- Channel B (mirror of channel A) ---
sio_int_isr_chk_b:
    XOR  A
    OUT  (SIO_CTRL_B), A
    IN   A, (SIO_CTRL_B)
    AND  SIO_RX_READY
    JP   Z, sio_int_isr_done

    IN   A, (SIO_DATA_B)
    LD   E, A
    LD   A, (RINGBUF_COUNT_B)
    CP   RINGBUF_SIZE
    JP   Z, sio_int_isr_done    ; buffer full -> drop

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
    CP   RINGBUF_HIGH_WATER
    JP   C, sio_int_isr_done

    LD   A, 0x05
    OUT  (SIO_CTRL_B), A
    LD   A, SIO_RTS_HIGH
    OUT  (SIO_CTRL_B), A

sio_int_isr_done:
    POP  BC
    POP  DE
    POP  HL
    POP  AF
    EI
    RETI

; ------------------------------------------------------------
; Device Function Tables — one per channel.
; ------------------------------------------------------------
dft_sio_int_a:
    DEFW sio_int_init_a         ; slot 0: Initialize
    DEFW sio_int_getstatus_a    ; slot 1: GetStatus
    DEFW sio_int_readbyte_raw_a ; slot 2: ReadByte (raw, no echo)
    DEFW sio_int_writebyte_a    ; slot 3: WriteByte

dft_sio_int_b:
    DEFW sio_int_init_b
    DEFW sio_int_getstatus_b
    DEFW sio_int_readbyte_raw_b
    DEFW sio_int_writebyte_b

; ============================================================
; PDTENTRY_SIO_INT_A ID, NAME, WR4_VAL  -> binds dft_sio_int_a
; PDTENTRY_SIO_INT_B ID, NAME, WR4_VAL  -> binds dft_sio_int_b
;
; No port arguments: see the "Hardcoded ports" note in the file
; header.  PDT user data carries only the WR4 value, which is the
; one parameter that varies between hosts (baud rate / format).
; ============================================================
PDTENTRY_SIO_INT_A macro ID, NAME, WR4_VAL
    DEFW 0                              ; PHYSDEV_OFF_NEXT
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_sio_int_a                  ; PHYSDEV_OFF_DFT (channel A)
    DEFB WR4_VAL                        ; +0 WR4 value
    DEFS 16, 0                          ; padding to fill 17-byte user data
endm

PDTENTRY_SIO_INT_B macro ID, NAME, WR4_VAL
    DEFW 0                              ; PHYSDEV_OFF_NEXT
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_sio_int_b                  ; PHYSDEV_OFF_DFT (channel B)
    DEFB WR4_VAL                        ; +0 WR4 value
    DEFS 16, 0                          ; padding to fill 17-byte user data
endm

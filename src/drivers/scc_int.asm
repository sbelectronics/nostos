; ============================================================
; NostOS Interrupt-Driven SCC (Z85C30) Serial Driver
;
; Channels A and B of one SCC chip; Rx via interrupt + ring
; buffer; Tx polled.  Limit: ONE such chip system-wide.  The
; polled scc.asm may also be present for additional polled SCCs.
;
; Mutually exclusive with the other interrupt UART drivers; see
; kernel.asm for the variant chain.
;
; Z80-only instructions used: DI / EI / RETI in the ISR and read
; path.  IM 1 / EI for global enable lives in platform_init.
;
; --- Hardcoded ports ---
; SCC_CTRL_A / SCC_DATA_A / SCC_CTRL_B / SCC_DATA_B are immediate
; operands on every IN/OUT in this file.  See the same note in
; sio_int.asm for the rationale (ISR can't use tramp_*, 8080 I/O
; opcodes encode the port in the instruction).  PDTENTRY_SCC_INT_A
; and PDTENTRY_SCC_INT_B take no port arguments as a result.
;
; Per-channel function pairs (init_a/init_b, etc.) and per-channel
; DFTs (dft_scc_int_a / dft_scc_int_b) follow the same pattern as
; sio_int.asm.
;
; Only Scott's-board SCC wiring is supported today.  A standard
; RC2014 SCC port map could be added with a SCC_USE_SB-style flag
; modeled on SIO_USE_SB in constants.asm.
;
; --- SCC vs SIO programming differences ---
; The SCC has features the SIO doesn't, and a few of them affect
; how this driver programs the chip:
;
;   * WR1 = 0x10 to enable Rx-int-on-all-chars.  Different bit
;     encoding from the SIO's WR1 = 0x18; the bit at position 4 on
;     the SCC is the "Rx int mode" select that the SIO doesn't have.
;
;   * WR9 is a chip-wide register (no per-channel copy).  It holds
;     the master interrupt enable (MIE) plus a hardware-reset bit.
;     Channel A's init issues WR9 = 0xC0 (full HW reset) at the
;     very start, programs all the per-channel registers, then
;     issues WR9 = 0x09 (MIE | NV) at the end.  The WR9 reset MUST
;     come before per-channel programming or it would clobber it.
;     The WR9 enable MUST come after, for the same reason.
;     Channel B's init does not touch WR9.
;
;   * BRG (Baud Rate Generator) configuration: WR11/12/13/14.
;     The SCC has its own BRG; the SIO relies on an external clock.
;     PDT user data carries the BRG time-constant bytes.
; ============================================================

; PDT user data layout (within PHYSDEV_OFF_DATA):
;   +0  WR4 value      (1 byte)
;   +1  BRG TC low     (1 byte, WR12)
;   +2  BRG TC high    (1 byte, WR13)
;   (no channel index — the DFT selects which channel's functions
;    run, so the channel is encoded by which DFT the PDT points at)
SCC_INT_PDT_OFF_WR4    EQU 0
SCC_INT_PDT_OFF_BRG_LO EQU 1
SCC_INT_PDT_OFF_BRG_HI EQU 2

; ============================================================
; Channel A entry points
; ============================================================

; ------------------------------------------------------------
; scc_int_init_a
; Initialise SCC channel A.  Also handles the chip-wide WR9
; programming (HW reset at the start, MIE at the end) — see the
; SCC programming notes in the file header.  Reads WR4 and BRG
; time constants from PDT user data.
;
; SCC register programming uses a two-step pattern: write the
; register number to WR0, then write the data to the same control
; port.  See Zilog UM010902 for the full register reference.
; ------------------------------------------------------------
scc_int_init_a:
    DI                          ; SCC WR pointer state must be stable
    PUSH BC
    PUSH DE

    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   D, (HL)                ; D = WR4 value
    INC  HL
    LD   E, (HL)                ; E = BRG TC low
    INC  HL
    LD   B, (HL)                ; B = BRG TC high.  We're clobbering
                                ; B (device ID) here; the original
                                ; is on the stack and POP BC restores.

    XOR  A
    LD   (RINGBUF_HEAD_A), A
    LD   (RINGBUF_TAIL_A), A
    LD   (RINGBUF_COUNT_A), A

    ; Chip-wide hardware reset.  Must come first; resets ALL channels
    ; and clears any in-progress programming.  Datasheet says the SCC
    ; needs ~4 PCLK cycles to settle afterward — at 7.3728 MHz that's
    ; under 1 µs, comfortably less than the next OUT's instruction time.
    LD   A, 0x09
    OUT  (SCC_CTRL_A), A
    LD   A, SCC_WR9_HW_RESET
    OUT  (SCC_CTRL_A), A

    LD   A, 0x18                ; WR0 channel reset (twice; see sio_int)
    OUT  (SCC_CTRL_A), A
    LD   A, 0x18
    OUT  (SCC_CTRL_A), A

    LD   A, 0x04                ; WR4 = clock + format
    OUT  (SCC_CTRL_A), A
    LD   A, D
    OUT  (SCC_CTRL_A), A

    ; WR3/WR5 with Rx and Tx DISABLED for now: the BRG isn't running
    ; yet, so enabling Rx/Tx would deadlock the channel waiting for
    ; clock edges that never come.  We'll enable them after WR14 below.
    LD   A, 0x03                ; WR3 = Rx 8-bit, Rx disabled
    OUT  (SCC_CTRL_A), A
    LD   A, 0xC0
    OUT  (SCC_CTRL_A), A

    LD   A, 0x05                ; WR5 = DTR, Tx 8-bit, RTS, Tx disabled
    OUT  (SCC_CTRL_A), A
    LD   A, 0xE2
    OUT  (SCC_CTRL_A), A

    LD   A, 0x0B                ; WR11 = clock source for Rx and Tx = BRG
    OUT  (SCC_CTRL_A), A
    LD   A, SCC_WR11_BRG
    OUT  (SCC_CTRL_A), A

    LD   A, 0x0C                ; WR12 = BRG time constant low
    OUT  (SCC_CTRL_A), A
    LD   A, E
    OUT  (SCC_CTRL_A), A

    LD   A, 0x0D                ; WR13 = BRG time constant high
    OUT  (SCC_CTRL_A), A
    LD   A, B
    OUT  (SCC_CTRL_A), A

    ; WR14 BRG enable is two writes: source select (BRG_SRC) THEN
    ; enable (BRG_ENA).  Per Zilog this is the documented sequence
    ; — writing BRG_ENA without first selecting the source first
    ; can leave the BRG in an undefined state on some SCC revisions.
    LD   A, 0x0E
    OUT  (SCC_CTRL_A), A
    LD   A, SCC_WR14_BRG_SRC
    OUT  (SCC_CTRL_A), A
    LD   A, 0x0E
    OUT  (SCC_CTRL_A), A
    LD   A, SCC_WR14_BRG_ENA
    OUT  (SCC_CTRL_A), A

    ; BRG is now running — safe to enable Rx and Tx.
    LD   A, 0x03                ; WR3 = Rx 8-bit, Rx ENABLE
    OUT  (SCC_CTRL_A), A
    LD   A, 0xC1
    OUT  (SCC_CTRL_A), A

    LD   A, 0x05                ; WR5 = DTR, Tx 8-bit, Tx ENABLE, RTS low
    OUT  (SCC_CTRL_A), A
    LD   A, SCC_RTS_LOW
    OUT  (SCC_CTRL_A), A

    LD   A, 0x0F                ; WR15 = no ext/status interrupts
    OUT  (SCC_CTRL_A), A
    LD   A, 0x00
    OUT  (SCC_CTRL_A), A

    LD   A, 0x10                ; WR0 cmd: reset ext/status (twice per Zilog)
    OUT  (SCC_CTRL_A), A
    LD   A, 0x10
    OUT  (SCC_CTRL_A), A

    LD   A, 0x01                ; WR1 = Rx int on all chars, no Tx int
    OUT  (SCC_CTRL_A), A
    LD   A, SCC_WR1_RX_INT_ALL
    OUT  (SCC_CTRL_A), A

    ; Chip-wide MIE (master interrupt enable).  Must come AFTER
    ; per-channel programming because the earlier WR9 = HW_RESET
    ; would have clobbered everything written before it.
    LD   A, 0x09
    OUT  (SCC_CTRL_A), A
    LD   A, SCC_WR9_MIE_NV
    OUT  (SCC_CTRL_A), A

    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; scc_int_getstatus_a
; Return whether a character is waiting in channel A's ring buffer.
; ------------------------------------------------------------
scc_int_getstatus_a:
    LD   A, (RINGBUF_COUNT_A)
    LD   H, 0
    LD   L, 0
    OR   A
    JP   Z, scc_int_getstatus_a_ret
    INC  L
scc_int_getstatus_a_ret:
    XOR  A
    RET

; ------------------------------------------------------------
; scc_int_readbyte_raw_a
; Read one character from channel A's ring buffer (blocking).
; ------------------------------------------------------------
scc_int_readbyte_raw_a:
    PUSH BC
    PUSH DE
scc_int_read_a_wait:
    LD   A, (RINGBUF_COUNT_A)
    OR   A
    JP   Z, scc_int_read_a_wait

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
    JP   NC, scc_int_read_a_norts

    ; Below low-water: drop RTS to let the sender resume.
    LD   A, 0x05
    OUT  (SCC_CTRL_A), A
    LD   A, SCC_RTS_LOW
    OUT  (SCC_CTRL_A), A
scc_int_read_a_norts:
    EI
    LD   L, E                   ; return char in L
    LD   H, 0
    POP  DE
    POP  BC
    XOR  A
    RET

; ------------------------------------------------------------
; scc_int_writebyte_a
; Write one character to channel A (polled).
; ------------------------------------------------------------
scc_int_writebyte_a:
scc_int_writebyte_a_wait:
    IN   A, (SCC_CTRL_A)        ; A = RR0
    AND  SCC_TX_EMPTY
    JP   Z, scc_int_writebyte_a_wait
    LD   A, E
    OUT  (SCC_DATA_A), A
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; Channel B entry points
; ============================================================

; ------------------------------------------------------------
; scc_int_init_b
; Initialise SCC channel B.  Identical to channel A's setup
; sequence but on the channel B port and skipping WR9 (chip-wide,
; already programmed by scc_int_init_a).
; ------------------------------------------------------------
scc_int_init_b:
    DI
    PUSH BC
    PUSH DE

    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   D, (HL)                ; D = WR4
    INC  HL
    LD   E, (HL)                ; E = BRG TC low
    INC  HL
    LD   B, (HL)                ; B = BRG TC high (clobbers device ID;
                                ;     restored by POP BC at the end)

    XOR  A
    LD   (RINGBUF_HEAD_B), A
    LD   (RINGBUF_TAIL_B), A
    LD   (RINGBUF_COUNT_B), A

    LD   A, 0x18                ; channel reset (twice)
    OUT  (SCC_CTRL_B), A
    LD   A, 0x18
    OUT  (SCC_CTRL_B), A

    LD   A, 0x04                ; WR4 = clock + format
    OUT  (SCC_CTRL_B), A
    LD   A, D
    OUT  (SCC_CTRL_B), A

    LD   A, 0x03                ; WR3 = Rx 8-bit, Rx disabled (no clock yet)
    OUT  (SCC_CTRL_B), A
    LD   A, 0xC0
    OUT  (SCC_CTRL_B), A

    LD   A, 0x05                ; WR5 = DTR, Tx 8-bit, RTS, Tx disabled
    OUT  (SCC_CTRL_B), A
    LD   A, 0xE2
    OUT  (SCC_CTRL_B), A

    LD   A, 0x0B                ; WR11 = clock source = BRG
    OUT  (SCC_CTRL_B), A
    LD   A, SCC_WR11_BRG
    OUT  (SCC_CTRL_B), A

    LD   A, 0x0C                ; WR12 = BRG TC low
    OUT  (SCC_CTRL_B), A
    LD   A, E
    OUT  (SCC_CTRL_B), A

    LD   A, 0x0D                ; WR13 = BRG TC high
    OUT  (SCC_CTRL_B), A
    LD   A, B
    OUT  (SCC_CTRL_B), A

    LD   A, 0x0E                ; WR14 select source...
    OUT  (SCC_CTRL_B), A
    LD   A, SCC_WR14_BRG_SRC
    OUT  (SCC_CTRL_B), A
    LD   A, 0x0E                ; ...then enable
    OUT  (SCC_CTRL_B), A
    LD   A, SCC_WR14_BRG_ENA
    OUT  (SCC_CTRL_B), A

    LD   A, 0x03                ; WR3 = Rx 8-bit, Rx ENABLE
    OUT  (SCC_CTRL_B), A
    LD   A, 0xC1
    OUT  (SCC_CTRL_B), A

    LD   A, 0x05                ; WR5 = DTR, Tx 8-bit, Tx ENABLE, RTS low
    OUT  (SCC_CTRL_B), A
    LD   A, SCC_RTS_LOW
    OUT  (SCC_CTRL_B), A

    LD   A, 0x0F                ; WR15 = no ext/status interrupts
    OUT  (SCC_CTRL_B), A
    LD   A, 0x00
    OUT  (SCC_CTRL_B), A

    LD   A, 0x10                ; WR0 cmd: reset ext/status (twice)
    OUT  (SCC_CTRL_B), A
    LD   A, 0x10
    OUT  (SCC_CTRL_B), A

    LD   A, 0x01                ; WR1 = Rx int on all chars
    OUT  (SCC_CTRL_B), A
    LD   A, SCC_WR1_RX_INT_ALL
    OUT  (SCC_CTRL_B), A

    ; (No WR9 here — it's chip-wide; channel A programmed it.)

    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; scc_int_getstatus_b
; ------------------------------------------------------------
scc_int_getstatus_b:
    LD   A, (RINGBUF_COUNT_B)
    LD   H, 0
    LD   L, 0
    OR   A
    JP   Z, scc_int_getstatus_b_ret
    INC  L
scc_int_getstatus_b_ret:
    XOR  A
    RET

; ------------------------------------------------------------
; scc_int_readbyte_raw_b
; ------------------------------------------------------------
scc_int_readbyte_raw_b:
    PUSH BC
    PUSH DE
scc_int_read_b_wait:
    LD   A, (RINGBUF_COUNT_B)
    OR   A
    JP   Z, scc_int_read_b_wait

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
    JP   NC, scc_int_read_b_norts

    LD   A, 0x05
    OUT  (SCC_CTRL_B), A
    LD   A, SCC_RTS_LOW
    OUT  (SCC_CTRL_B), A
scc_int_read_b_norts:
    EI
    LD   L, E
    LD   H, 0
    POP  DE
    POP  BC
    XOR  A
    RET

; ------------------------------------------------------------
; scc_int_writebyte_b
; ------------------------------------------------------------
scc_int_writebyte_b:
scc_int_writebyte_b_wait:
    IN   A, (SCC_CTRL_B)
    AND  SCC_TX_EMPTY
    JP   Z, scc_int_writebyte_b_wait
    LD   A, E
    OUT  (SCC_DATA_B), A
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; scc_int_isr
; RST 38 / IM 1 entry.  Drains any pending Rx byte from each
; channel into its ring buffer, asserting RTS-high on high-water
; approach.  Reached directly via RST7_RAM_VEC.
; ============================================================
scc_int_isr:
    PUSH AF
    PUSH HL
    PUSH DE
    PUSH BC

; --- Channel A ---
    XOR  A
    OUT  (SCC_CTRL_A), A        ; WR0 = 0 (select RR0 for next read)
    IN   A, (SCC_CTRL_A)        ; A = RR0 status
    AND  SCC_RX_READY
    JP   Z, scc_int_isr_chk_b

    IN   A, (SCC_DATA_A)
    LD   E, A
    LD   A, (RINGBUF_COUNT_A)
    CP   RINGBUF_SIZE
    JP   Z, scc_int_isr_chk_b   ; buffer full -> drop

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
    JP   C, scc_int_isr_chk_b

    ; At/above high-water: WR5 RTS-high to throttle the sender.
    LD   A, 0x05
    OUT  (SCC_CTRL_A), A
    LD   A, SCC_RTS_HIGH
    OUT  (SCC_CTRL_A), A

; --- Channel B (mirror of channel A) ---
scc_int_isr_chk_b:
    XOR  A
    OUT  (SCC_CTRL_B), A
    IN   A, (SCC_CTRL_B)
    AND  SCC_RX_READY
    JP   Z, scc_int_isr_done

    IN   A, (SCC_DATA_B)
    LD   E, A
    LD   A, (RINGBUF_COUNT_B)
    CP   RINGBUF_SIZE
    JP   Z, scc_int_isr_done

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
    JP   C, scc_int_isr_done

    LD   A, 0x05
    OUT  (SCC_CTRL_B), A
    LD   A, SCC_RTS_HIGH
    OUT  (SCC_CTRL_B), A

scc_int_isr_done:
    POP  BC
    POP  DE
    POP  HL
    POP  AF
    EI
    RETI

; ------------------------------------------------------------
; Device Function Tables — one per channel.
; ------------------------------------------------------------
dft_scc_int_a:
    DEFW scc_int_init_a         ; slot 0: Initialize
    DEFW scc_int_getstatus_a    ; slot 1: GetStatus
    DEFW scc_int_readbyte_raw_a ; slot 2: ReadByte (raw, no echo)
    DEFW scc_int_writebyte_a    ; slot 3: WriteByte

dft_scc_int_b:
    DEFW scc_int_init_b
    DEFW scc_int_getstatus_b
    DEFW scc_int_readbyte_raw_b
    DEFW scc_int_writebyte_b

; ============================================================
; PDTENTRY_SCC_INT_A ID, NAME, WR4_VAL, BRG_TC_LO, BRG_TC_HI
; PDTENTRY_SCC_INT_B ID, NAME, WR4_VAL, BRG_TC_LO, BRG_TC_HI
;
; No port arguments: see the "Hardcoded ports" note in the file
; header.  PDT user data carries WR4 (clock + format) and the
; BRG time constant (low/high), which set the baud rate.
; ============================================================
PDTENTRY_SCC_INT_A macro ID, NAME, WR4_VAL, BRG_TC_LO, BRG_TC_HI
    DEFW 0                              ; PHYSDEV_OFF_NEXT
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_scc_int_a                  ; PHYSDEV_OFF_DFT (channel A)
    DEFB WR4_VAL                        ; +0 WR4
    DEFB BRG_TC_LO                      ; +1 BRG TC low
    DEFB BRG_TC_HI                      ; +2 BRG TC high
    DEFS 14, 0                          ; padding to fill 17-byte user data
endm

PDTENTRY_SCC_INT_B macro ID, NAME, WR4_VAL, BRG_TC_LO, BRG_TC_HI
    DEFW 0                              ; PHYSDEV_OFF_NEXT
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_scc_int_b                  ; PHYSDEV_OFF_DFT (channel B)
    DEFB WR4_VAL                        ; +0 WR4
    DEFB BRG_TC_LO                      ; +1 BRG TC low
    DEFB BRG_TC_HI                      ; +2 BRG TC high
    DEFS 14, 0                          ; padding to fill 17-byte user data
endm

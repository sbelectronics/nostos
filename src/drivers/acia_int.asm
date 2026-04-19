; ============================================================
; NostOS Interrupt-Driven ACIA (MC6850) Serial Driver
;
; Single channel, Rx via interrupt + ring buffer.  Tx is polled.
; Limit: ONE such chip system-wide.  The polled acia.asm may also
; be present in the same build for additional polled ACIAs.
;
; Mutually exclusive with the other interrupt UART drivers; they
; all claim the IM 1 / RST 38 path (z180_int uses IM 2, also
; mutually exclusive).  See kernel.asm for the variant chain.
;
; The 6850 has only one channel, so this driver uses RINGBUF_A
; only; RINGBUF_B is allocated by WITH_RINGBUF but never touched.
;
; Z80-only instructions used: DI / EI / RETI in the ISR and read
; path.  IM 1 / EI for global enable lives in platform_init.
;
; --- Hardcoded ports ---
; ACIA_CONTROL and ACIA_DATA appear as immediate operands on every
; IN/OUT in this file.  The ISR cannot use tramp_in/tramp_out (the
; shared workspace thunk would race with main code), and 8080
; IN n / OUT n encodes the port as an immediate, so the ISR can
; only reach compile-time-fixed ports.  Once the ISR is locked,
; nothing else in the driver has any reason to look up the ports
; from PDT user data, so PDTENTRY_ACIA_INT takes no port arguments.
; ============================================================

; ------------------------------------------------------------
; acia_int_init
; Initialise the MC6850 ACIA for interrupt-driven receive.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
acia_int_init:
    DI                          ; protect register state from ISR
    PUSH BC                     ; preserve B (device ID)

    ; Zero ring-buffer bookkeeping before enabling the chip's Rx
    ; interrupt, so the ISR can never observe stale HEAD/TAIL/COUNT.
    XOR  A
    LD   (RINGBUF_HEAD_A), A
    LD   (RINGBUF_TAIL_A), A
    LD   (RINGBUF_COUNT_A), A

    LD   A, ACIA_RESET          ; master reset
    OUT  (ACIA_CONTROL), A
    LD   A, ACIA_INIT_INT_RTS_LOW   ; /64, 8N1, RTS low, Rx int enabled
    OUT  (ACIA_CONTROL), A

    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; acia_int_getstatus
; Return whether a character is waiting in the ring buffer.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 1 if character waiting, 0 otherwise
; ------------------------------------------------------------
acia_int_getstatus:
    LD   A, (RINGBUF_COUNT_A)
    LD   H, 0
    LD   L, 0
    OR   A
    JP   Z, acia_int_getstatus_ret
    INC  L
acia_int_getstatus_ret:
    XOR  A
    RET

; ------------------------------------------------------------
; acia_int_readbyte_raw
; Read one character from the ring buffer (blocking).
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - character read (L = char, H = 0)
; ------------------------------------------------------------
acia_int_readbyte_raw:
    PUSH BC                     ; preserve B (device ID)
    PUSH DE

acia_int_read_wait:
    LD   A, (RINGBUF_COUNT_A)
    OR   A
    JP   Z, acia_int_read_wait

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
    JP   NC, acia_int_read_norts

    ; Below low-water: drop RTS to let the sender resume.  The 6850
    ; has no separate RTS register — we rewrite the whole control
    ; register, which keeps Rx int enabled (bit 7 = 1) and switches
    ; bits 6:5 from "RTS high" to "RTS low".
    LD   A, ACIA_INIT_INT_RTS_LOW
    OUT  (ACIA_CONTROL), A
acia_int_read_norts:
    EI
    LD   L, E                   ; return char in L
    LD   H, 0
    POP  DE
    POP  BC
    XOR  A
    RET

; ------------------------------------------------------------
; acia_int_writebyte
; Write one character (polled, identical to acia_writebyte).
; Inputs:
;   B  - physical device ID
;   E  - character to write
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
acia_int_writebyte:
acia_int_writebyte_wait:
    IN   A, (ACIA_CONTROL)      ; A = status
    AND  ACIA_TDRE
    JP   Z, acia_int_writebyte_wait
    LD   A, E
    OUT  (ACIA_DATA), A
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; acia_int_isr
; RST 38 / IM 1 entry.  Drains one Rx byte into the ring buffer
; if RDRF is set, asserting RTS-high on high-water approach.
; ============================================================
acia_int_isr:
    PUSH AF
    PUSH HL
    PUSH DE
    PUSH BC

    ; First check that the IRQ came from us (bit 7 of status).
    ; Important for shared-IRQ setups: if some other device on the
    ; same /INT line fired, we must NOT drain ACIA_DATA — we'd steal
    ; whatever happens to be sitting in RDRF from the real consumer.
    IN   A, (ACIA_CONTROL)      ; A = status
    AND  ACIA_IRQ
    JP   Z, acia_int_isr_done   ; not us — spurious or shared IRQ

    ; Re-read status to recover the bits the previous AND destroyed.
    ; (We could save the original to a register instead, but a 6850
    ;  status read is one IN; the cost is a wash.)
    IN   A, (ACIA_CONTROL)
    AND  ACIA_RDRF
    JP   Z, acia_int_isr_done   ; IRQ but no Rx data — ignore

    IN   A, (ACIA_DATA)         ; reading data clears RDRF and IRQ
    LD   E, A
    LD   A, (RINGBUF_COUNT_A)
    CP   RINGBUF_SIZE
    JP   Z, acia_int_isr_done   ; buffer full -> drop

    ; Append byte at HEAD, advance HEAD, bump COUNT.
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
    JP   C, acia_int_isr_done

    ; At/above high-water: assert RTS to throttle the sender.
    LD   A, ACIA_INIT_INT_RTS_HIGH
    OUT  (ACIA_CONTROL), A

acia_int_isr_done:
    POP  BC
    POP  DE
    POP  HL
    POP  AF
    EI
    RETI

; ------------------------------------------------------------
; Device Function Table for interrupt-driven ACIA (4 char slots)
; ------------------------------------------------------------
dft_acia_int:
    DEFW acia_int_init          ; slot 0: Initialize
    DEFW acia_int_getstatus     ; slot 1: GetStatus
    DEFW acia_int_readbyte_raw  ; slot 2: ReadByte (raw, no echo)
    DEFW acia_int_writebyte     ; slot 3: WriteByte

; ============================================================
; PDTENTRY_ACIA_INT ID, NAME
; Macro: declare a ROM PDT entry for the interrupt-driven ACIA.
; Unlike PDTENTRY_ACIA, this macro takes no port arguments — the
; driver hardcodes ACIA_CONTROL/ACIA_DATA throughout because the
; ISR cannot use tramp_in/tramp_out (it would race the workspace
; thunk with main code) and direct IN/OUT requires immediate ports.
; Only one ACIA chip at the canonical ports is supported under
; the interrupt-driven driver.
; ============================================================
PDTENTRY_ACIA_INT macro ID, NAME
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_acia_int                   ; PHYSDEV_OFF_DFT
    DEFS 17, 0                          ; user data: unused (driver uses
                                        ; direct IN/OUT against fixed ports)
endm

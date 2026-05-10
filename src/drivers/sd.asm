; ============================================================
; NostOS SD card SPI block device driver.
;
; Two transports, IFDEF-selected (mutually exclusive):
;   SD_USE_CSIO    — Z180 CSI/O hardware SPI (SC131-class boards)
;   SD_USE_BITBANG — software SPI on a single 8-bit latch (SC611)
;
; Each transport implements: sd_send_byte, sd_recv_byte,
; sd_cs_assert, sd_cs_deassert, sd_set_speed_init / _fast (no-op
; on bit-bang), sd_init_transport, sd_setup_io (no-op on CSI/O,
; patches I/O thunks on bit-bang from PDT user data).
;
; Card type (SDSC / SDHC / SDXC) is detected from CMD58's CCS bit
; and stored in PDT byte SD_OFF_TYPE.  sd_setup_address translates
; LBA → byte address (×512) for SDSC; SDHC/SDXC use blocks as-is.
; ============================================================

    IFNDEF SD_USE_CSIO
        IFNDEF SD_USE_BITBANG
            ERROR "sd.asm requires -DSD_USE_CSIO or -DSD_USE_BITBANG"
        ENDIF
    ENDIF
    IFDEF SD_USE_CSIO
        IFDEF SD_USE_BITBANG
            ERROR "sd.asm: SD_USE_CSIO and SD_USE_BITBANG are mutually exclusive"
        ENDIF
    ENDIF

; ============================================================
; Transport: Z180 CSI/O (SC131)
;
; Z180-specific (8080 rule waived for the Z180 family).  Internal-
; I/O writes use `LD B, 0; OUT (C), A`; plain `OUT (n), A` mirrors
; A onto A8-A15 and misses the internal decoder for non-zero A.
;
; CSI/O is half-duplex (TE and RE mutually exclusive) and shifts
; LSB-first.  SD is MSB-first, so every byte is bit-mirrored at
; the wire boundary by sd_mirror.
; ============================================================
    IFDEF SD_USE_CSIO

; sd_csio_wait_idle
; Spin until both TE and RE are clear in CNTR.  Required before
; touching TRDR or changing CNTR baud bits, otherwise the in-flight
; bit gets corrupted.
; Clobbers: A, B, C
sd_csio_wait_idle:
    LD   B, 0
    LD   C, Z180_CNTR
sd_csio_wait_idle_loop:
    IN   A, (C)
    AND  Z180_CNTR_TE | Z180_CNTR_RE
    JP   NZ, sd_csio_wait_idle_loop
    RET

; sd_mirror
; Bit-reverse the byte in A.  Software shift (~50 cycles/byte); a
; 256-byte LUT would be ~10× faster but isn't worth the ROM at
; typical app-load sizes (16-32 blocks).
; Inputs:  A = byte
; Outputs: A = bit-reversed byte
; Clobbers: B, C, F (preserves DE, HL)
sd_mirror:
    PUSH BC
    LD   B, 8
    LD   C, 0
sd_mirror_loop:
    ADD  A, A           ; A high bit → carry
    PUSH AF             ; save shifted A
    LD   A, C
    RRA                 ; carry → bit 7 of result; bit 0 → carry (discarded)
    LD   C, A
    POP  AF
    DEC  B
    JP   NZ, sd_mirror_loop
    LD   A, C
    POP  BC
    RET

; sd_send_byte
; Clock one byte MSB-first via CSI/O TE.  MISO sample discarded.
; Inputs:  A = byte to send
; Clobbers: A, B, C, F (preserves DE, HL)
sd_send_byte:
    CALL sd_mirror              ; A = LSB-first wire form
    PUSH AF                     ; save mirrored byte across wait
    CALL sd_csio_wait_idle
    POP  AF
    LD   B, 0
    LD   C, Z180_TRDR
    OUT  (C), A                 ; load TRDR
    LD   C, Z180_CNTR
    IN   A, (C)
    OR   Z180_CNTR_TE
    OUT  (C), A                 ; arm TE → start transmit
    JP   sd_csio_wait_idle      ; tail-call: wait for TE to self-clear

; sd_recv_byte
; Clock 8 dummy bits via CSI/O RE and capture MISO into TRDR.
; The chip leaves stale TRDR contents on MOSI during RE, but SD
; ignores MOSI in response/data slots so we don't pre-load 0xFF.
; Outputs: A = byte received, MSB-first
; Clobbers: A, B, C, F (preserves DE, HL)
sd_recv_byte:
    CALL sd_csio_wait_idle
    LD   B, 0
    LD   C, Z180_CNTR
    IN   A, (C)
    OR   Z180_CNTR_RE
    OUT  (C), A                 ; arm RE → start receive
    CALL sd_csio_wait_idle
    LD   C, Z180_TRDR
    IN   A, (C)
    JP   sd_mirror              ; tail-call: A = MSB-first byte

; sd_cs_assert / sd_cs_deassert
; Drive SD /CS via the SC131's 74HCT259 latch at port SD_SC131_CS_PORT
; (D2 = SD /CS, D3 always high to match RomWBW's pattern).  Other
; latch outputs are unused on SC131; a full-byte write is safe.
sd_cs_assert:
    PUSH AF
    LD   A, SD_SC131_CS_LOW
    OUT  (SD_SC131_CS_PORT), A
    POP  AF
    RET

sd_cs_deassert:
    PUSH AF
    LD   A, SD_SC131_CS_HIGH
    OUT  (SD_SC131_CS_PORT), A
    POP  AF
    RET

; sd_set_speed_init / sd_set_speed_fast
; Switch CSI/O baud divisor.  Init clock must be ≤ 400 kHz per SD
; spec; CNTR=$06 → PHI/1280 ≈ 14.4 kHz at 18.432 MHz.  Fast clock
; is the chip's max: CNTR=$00 → PHI/20 ≈ 921 kHz.  Match RomWBW.
; Clobbers: A, B, C
sd_set_speed_init:
    LD   A, SD_CNTR_INIT
    JP   sd_set_speed_common
sd_set_speed_fast:
    LD   A, SD_CNTR_FAST
sd_set_speed_common:
    PUSH AF
    CALL sd_csio_wait_idle
    POP  AF
    LD   B, 0
    LD   C, Z180_CNTR
    OUT  (C), A
    RET

; sd_init_transport
; One-shot CSI/O bring-up: deassert CS and select init speed.
sd_init_transport:
    CALL sd_cs_deassert
    JP   sd_set_speed_init

; sd_setup_io
; Per-operation I/O setup.  No-op for CSI/O — port addresses are
; fixed at the chip's internal-I/O base.
; Inputs:  HL = pointer to PDT user data (unused)
sd_setup_io:
    RET

    ENDIF   ; SD_USE_CSIO

; ============================================================
; Transport: SC611 bit-bang
;
; 8080-clean.  All four SD lines share one I/O port (output) plus
; the same port for input (MISO on bit 7).  The port is jumper-
; selected on SC611, stored at PDT user data offset SD_OFF_PORT,
; and patched into self-modifying IN/OUT thunks at the start of
; each operation.
; ============================================================
    IFDEF SD_USE_BITBANG

; sd_bb_setup_thunks
; Patch SD_BB_IN_THUNK and SD_BB_OUT_THUNK with the runtime port.
; Aliases the unused-by-this-build CF I/O thunks (CF and bit-bang
; SD never coexist on a real board).
; Inputs:  HL = pointer to PDT user data
; Clobbers: A
sd_bb_setup_thunks:
    PUSH HL
    PUSH DE
    LD   DE, SD_OFF_PORT
    ADD  HL, DE
    LD   A, (HL)                ; A = port number
    LD   HL, SD_BB_IN_THUNK
    LD   (HL), 0xDB             ; IN n, A
    INC  HL
    LD   (HL), A
    INC  HL
    LD   (HL), 0xC9             ; RET
    LD   HL, SD_BB_OUT_THUNK
    LD   (HL), 0xD3             ; OUT n, A
    INC  HL
    LD   (HL), A
    INC  HL
    LD   (HL), 0xC9             ; RET
    POP  DE
    POP  HL
    RET

; sd_setup_io
; Per-operation I/O setup: bit-bang patches its IN/OUT thunks.
; Inputs:  HL = pointer to PDT user data
sd_setup_io:
    JP   sd_bb_setup_thunks

; sd_bb_xchg_byte
; Exchange one byte: MSB-first send while sampling MISO.  Caller
; must have CS asserted.  SPI mode 0: SCLK idles low, sample MISO
; on the rising edge.
; Inputs:  A = byte to send (MSB-first)
; Outputs: A = byte received (MSB-first)
; Clobbers: B, C, F (preserves DE, HL)
sd_bb_xchg_byte:
    PUSH DE
    LD   E, A                   ; E = outgoing byte
    LD   D, 0                   ; D = incoming byte accumulator
    LD   B, 8
sd_bb_xchg_loop:
    LD   A, E
    AND  0x80
    JP   Z, sd_bb_xchg_zero
    ; outbit = 1: drive MOSI=1, SCLK low → high
    LD   A, SD_BB_CS_LOW_CLK_LO | SD_BB_BIT_MOSI
    CALL SD_BB_OUT_THUNK
    LD   A, SD_BB_CS_LOW_CLK_HI | SD_BB_BIT_MOSI
    CALL SD_BB_OUT_THUNK
    JP   sd_bb_xchg_sample
sd_bb_xchg_zero:
    ; outbit = 0: drive MOSI=0, SCLK low → high
    LD   A, SD_BB_CS_LOW_CLK_LO
    CALL SD_BB_OUT_THUNK
    LD   A, SD_BB_CS_LOW_CLK_HI
    CALL SD_BB_OUT_THUNK
sd_bb_xchg_sample:
    CALL SD_BB_IN_THUNK         ; A = port byte; MISO on bit 7
    RLA                         ; MISO bit → carry
    LD   A, D
    RLA                         ; shift carry into D bit 0
    LD   D, A
    LD   A, E
    ADD  A, A                   ; shift E left, MSB lost (already used)
    LD   E, A
    DEC  B
    JP   NZ, sd_bb_xchg_loop
    LD   A, D
    POP  DE
    RET

; sd_send_byte
; Clock byte out, discard MISO sample.
; Inputs:  A = byte to send
; Clobbers: A, B, C, F (preserves DE, HL)
sd_send_byte:
    JP   sd_bb_xchg_byte

; sd_recv_byte
; Clock 0xFF out (MOSI idle high), capture MISO.
; Outputs: A = byte received
; Clobbers: A, B, C, F (preserves DE, HL)
sd_recv_byte:
    LD   A, 0xFF
    JP   sd_bb_xchg_byte

; sd_cs_assert / sd_cs_deassert
; Drive /CS via the same latch port (D3 = /CS, active low).
; MOSI bit kept high in the idle state for SPI hygiene.
sd_cs_assert:
    PUSH AF
    LD   A, SD_BB_CS_LOW_CLK_LO | SD_BB_BIT_MOSI
    CALL SD_BB_OUT_THUNK
    POP  AF
    RET

sd_cs_deassert:
    PUSH AF
    LD   A, SD_BB_IDLE
    CALL SD_BB_OUT_THUNK
    POP  AF
    RET

; sd_set_speed_init / sd_set_speed_fast
; No-op on bit-bang — software clock rate is whatever the loop
; happens to run at.  At ~14 MHz Z80 it lands well below the
; 400 kHz init ceiling, so init works without any throttling.
sd_set_speed_init:
sd_set_speed_fast:
    RET

; sd_init_transport
; Bit-bang has no chip-side state to reset; just deassert CS.
sd_init_transport:
    JP   sd_cs_deassert

    ENDIF   ; SD_USE_BITBANG

; ============================================================
; Common SD logic
; ============================================================

; sd_get_userdata
; Resolve a physical device ID to its user-data pointer.
; Inputs:  B = physical device ID
; Outputs: HL = pointer to user data
; Clobbers: A, DE
sd_get_userdata:
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE
    RET

; sd_dummy_clocks
; Clock B 0xFF bytes with CS in whatever state the caller chose.
; Used to give the card 80+ initial clocks (CS high) and to flush
; the 8 trailing clocks the spec requires after each transaction.
; Inputs:  B = byte count
; Clobbers: A, B, C, F
sd_dummy_clocks:
    LD   A, 0xFF
    PUSH BC
    CALL sd_send_byte
    POP  BC
    DEC  B
    JP   NZ, sd_dummy_clocks
    RET

; sd_send_cmd_buf
; Clock the 6-byte command frame at SD_CMD_BUF and poll for the R1
; response.  Polls up to 8 byte times (NCR per the spec).
; Outputs: A = R1 byte, or 0xFF on timeout
; Clobbers: A, B, C, D, E, H, L
sd_send_cmd_buf:
    LD   HL, SD_CMD_BUF
    LD   B, 6
sd_send_cmd_buf_send:
    LD   A, (HL)
    PUSH BC
    PUSH HL
    CALL sd_send_byte
    POP  HL
    POP  BC
    INC  HL
    DEC  B
    JP   NZ, sd_send_cmd_buf_send
    LD   B, 16                  ; up to 16 bytes for R1 (NCR + slack)
sd_send_cmd_buf_wait:
    PUSH BC
    CALL sd_recv_byte
    POP  BC
    LD   C, A                   ; preserve full byte
    AND  0x80
    JP   Z, sd_send_cmd_buf_done
    DEC  B
    JP   NZ, sd_send_cmd_buf_wait
    LD   A, 0xFF                ; timeout
    RET
sd_send_cmd_buf_done:
    LD   A, C                   ; full R1 (top bit was zero)
    RET

; sd_build_cmd_simple
; Build a fixed-arg command into SD_CMD_BUF.
; Inputs:
;   A      - command byte (e.g. SD_CMD0)
;   DE     - arg[31:24]:arg[23:16]   (D high, E low)
;   HL     - arg[15:8]:arg[7:0]      (H high, L low)
;   C      - CRC byte
sd_build_cmd_simple:
    PUSH HL
    LD   HL, SD_CMD_BUF
    LD   (HL), A                ; cmd
    INC  HL
    LD   (HL), D                ; arg[31:24]
    INC  HL
    LD   (HL), E                ; arg[23:16]
    INC  HL
    EX   DE, HL                 ; DE = SD_CMD_BUF+3
    POP  HL                     ; HL = original arg low word
    LD   A, H
    LD   (DE), A                ; arg[15:8]
    INC  DE
    LD   A, L
    LD   (DE), A                ; arg[7:0]
    INC  DE
    LD   A, C
    LD   (DE), A                ; CRC
    RET

; sd_wait_token
; Poll for the 0xFE start-of-block data token.  Up to ~64K byte
; times of patience (cards are slow on first read after init).
; Outputs: A = 0 on success, ERR_IO on timeout
; Clobbers: A, B, C, D, E
sd_wait_token:
    LD   DE, 0xFFFF             ; coarse loop count
sd_wait_token_loop:
    PUSH DE
    CALL sd_recv_byte
    POP  DE
    CP   SD_TOKEN_DATA
    JP   Z, sd_wait_token_ok
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, sd_wait_token_loop
    LD   A, ERR_IO
    RET
sd_wait_token_ok:
    XOR  A
    RET

; sd_xfer_block
; Read 512 bytes from the SD card into (DE).  Caller has already
; sent CMD17 and consumed the 0xFE token.  Two CRC bytes are read
; and discarded after the data.
; Inputs:  DE = destination buffer pointer (advanced by 512)
; Clobbers: A, B, C, F (preserves HL)
sd_xfer_block:
    LD   B, 0                   ; 0 = 256 iterations per pass
    CALL sd_xfer_256
    CALL sd_xfer_256
    ; Discard 2 CRC bytes.
    CALL sd_recv_byte
    JP   sd_recv_byte           ; tail-call

; sd_xfer_256
; Inputs:  DE = destination, B = 0 (= 256)
sd_xfer_256:
    PUSH HL
sd_xfer_256_loop:
    PUSH BC
    CALL sd_recv_byte
    POP  BC
    LD   (DE), A
    INC  DE
    DEC  B
    JP   NZ, sd_xfer_256_loop
    POP  HL
    RET

; sd_xmit_block
; Write 512 bytes from (DE) to the SD card.  Caller has already
; sent CMD24 and the 0xFE token.  Two dummy CRC bytes are appended.
; Inputs:  DE = source buffer pointer (advanced by 512)
; Clobbers: A, B, C, F (preserves HL)
sd_xmit_block:
    LD   B, 0
    CALL sd_xmit_256
    CALL sd_xmit_256
    ; Two dummy CRC bytes (card ignores them in SPI mode).
    LD   A, 0xFF
    CALL sd_send_byte
    LD   A, 0xFF
    JP   sd_send_byte           ; tail-call

sd_xmit_256:
    PUSH HL
sd_xmit_256_loop:
    LD   A, (DE)
    PUSH BC
    PUSH DE
    CALL sd_send_byte
    POP  DE
    POP  BC
    INC  DE
    DEC  B
    JP   NZ, sd_xmit_256_loop
    POP  HL
    RET

; sd_setup_address
; Build the 4-byte address argument in DE:HL for an SD command,
; converting LBA → byte address for SDSC cards (×512).
;
; The wire format is big-endian, but sd_build_cmd_simple wants its
; arg in registers as DE = high word, HL = low word with the most-
; significant byte in D and the least in L:
;     D = arg[31:24], E = arg[23:16], H = arg[15:8], L = arg[7:0]
; Inputs:
;   HL = pointer to PDT user data (LBA at offset 0, type at +4)
; Outputs:
;   DE, HL = command argument as above
; Clobbers: A, B, C, F
sd_setup_address:
    ; Read card type FIRST, while HL is still the user-data pointer.
    PUSH HL
    LD   DE, SD_OFF_TYPE
    ADD  HL, DE
    LD   A, (HL)                ; A = card type
    LD   C, A                   ; stash for later branch
    POP  HL                     ; HL back to user-data base

    ; Load LBA bytes 0..3 into temp registers.  After this block:
    ;   E = LBA byte 0, D = LBA byte 1, B = LBA byte 2, A = LBA byte 3
    LD   A, (HL)
    LD   E, A
    INC  HL
    LD   A, (HL)
    LD   D, A
    INC  HL
    LD   A, (HL)
    LD   B, A
    INC  HL
    LD   A, (HL)

    ; Re-arrange so D is most-significant and L is least-significant.
    LD   L, E                   ; L = LBA byte 0 (LSB)
    LD   H, D                   ; H = LBA byte 1
    LD   E, B                   ; E = LBA byte 2
    LD   D, A                   ; D = LBA byte 3 (MSB)

    ; SDHC/SDXC use block addressing → done.
    LD   A, C
    CP   SD_TYPE_SDHC
    RET  Z

    ; SDSC: byte addressing, multiply by 512 (left-shift by 9).
    ; First an 8-bit byte rotate (×256): D=E, E=H, H=L, L=0.
    LD   D, E
    LD   E, H
    LD   H, L
    LD   L, 0
    ; Then one more bit through carry to complete ×512.
    LD   A, L
    ADD  A, A
    LD   L, A
    LD   A, H
    ADC  A, A
    LD   H, A
    LD   A, E
    ADC  A, A
    LD   E, A
    LD   A, D
    ADC  A, A
    LD   D, A
    RET

; sd_inc_lba
; Advance the 32-bit LBA at user-data offset 0 by one block.
; Inputs:  HL = pointer to user data
; Clobbers: A, F (preserves BC, DE; HL advances by 0..3 bytes)
sd_inc_lba:
    INC  (HL)
    RET  NZ
    INC  HL
    INC  (HL)
    RET  NZ
    INC  HL
    INC  (HL)
    RET  NZ
    INC  HL
    INC  (HL)
    RET

; ============================================================
; Hardware-debug diagnostics — gated on SD_DEBUG (off by default).
; sd_diag_fail emits "SD<phase> <hex(R1)>\r\n" then jumps to
; sd_init_fail.  Phase letters: '0' CMD0, 'V' ACMD41-V1, 'H'
; ACMD41-V2, '5' CMD58, 'C'/'D'/'B' sd_writeblock CMD24/data-resp/
; busy-poll.  In non-debug builds sd_diag_fail just jumps to fail
; and sd_diag_print is a RET.
; ============================================================
    IFDEF SD_DEBUG

sd_diag_putc:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL syscall_entry
    POP  HL
    POP  DE
    POP  BC
    POP  AF
    RET

sd_diag_puthex:
    PUSH AF
    RLCA
    RLCA
    RLCA
    RLCA
    AND  0x0F
    CALL sd_diag_putnib
    POP  AF
    AND  0x0F
sd_diag_putnib:
    CP   10
    JP   C, sd_diag_putnib_dec
    ADD  A, 'A' - 10 - '0'
sd_diag_putnib_dec:
    ADD  A, '0'
    JP   sd_diag_putc

sd_diag_print:
    LD   C, A                   ; C = phase letter
    LD   A, 'S'
    CALL sd_diag_putc
    LD   A, 'D'
    CALL sd_diag_putc
    LD   A, C
    CALL sd_diag_putc
    LD   A, ' '
    CALL sd_diag_putc
    LD   A, B
    CALL sd_diag_puthex
    LD   A, 0x0D
    CALL sd_diag_putc
    LD   A, 0x0A
    JP   sd_diag_putc

sd_diag_fail:
    CALL sd_diag_print
    JP   sd_init_fail

    ELSE   ; ! SD_DEBUG

sd_diag_print:
    RET
sd_diag_fail:
    JP   sd_init_fail

    ENDIF

; sd_xact_begin / sd_xact_end
; Wrap each SD command in a CS-low/CS-high transaction, with one
; dummy 0xFF byte (8 clocks) on each side.  RomWBW does this
; between every command during init; many cards need the CS
; bounce + idle clocks to clock out the response state machine
; before they will accept the next command.
; Clobbers: A, B, C, F (preserves DE, HL); end preserves AF too.
sd_xact_begin:
    CALL sd_cs_assert
    LD   A, 0xFF
    JP   sd_send_byte           ; tail-call

sd_xact_end:
    PUSH AF                     ; preserve caller's R1 in A
    LD   A, 0xFF
    CALL sd_send_byte
    CALL sd_cs_deassert
    POP  AF
    RET

; sd_check_init
; If the card type is already known, return success.  Otherwise
; (re-)run sd_init.  Lets read/write recover from boot-time init
; failures — the card may have been inserted after boot, or it
; may have needed more wake-up time than was available before
; devices_init ran.
; Inputs:  B  = physical device ID
; Outputs: A  = 0 if card is ready, ERR_IO otherwise
; Clobbers: A, C, D, E, H, L  (preserves B)
sd_check_init:
    PUSH BC
    CALL sd_get_userdata
    LD   DE, SD_OFF_TYPE
    ADD  HL, DE
    LD   A, (HL)
    OR   A
    JP   NZ, sd_check_init_ok   ; type already set: ready
    CALL sd_init                ; try again
    CALL sd_get_userdata
    LD   DE, SD_OFF_TYPE
    ADD  HL, DE
    LD   A, (HL)
    OR   A
    JP   Z, sd_check_init_fail
sd_check_init_ok:
    POP  BC
    XOR  A                      ; A = 0 = ready (NOT the type byte)
    RET
sd_check_init_fail:
    POP  BC
    LD   A, ERR_IO
    RET

; ============================================================
; sd_init
; Bring the SD card from power-up to ready: 80 dummy clocks, CMD0,
; CMD8, ACMD41 loop, CMD58.  On success, store SD_TYPE_SDSC or
; SD_TYPE_SDHC at user-data offset SD_OFF_TYPE.  On any failure
; (no card, timeout, unknown response), leave SD_TYPE_NONE so
; subsequent reads/writes fail cleanly with ERR_IO.
;
; Inputs:  B  = physical device ID
; Outputs: A  = ERR_SUCCESS or ERR_IO
;          HL = 0
; ============================================================
sd_init:
    PUSH BC
    PUSH DE
    LD   A, B
    LD   (SD_DEV_ID), A         ; stash device ID — B gets clobbered by
                                ; every Z180 OUT (C),A in the transport
    CALL sd_get_userdata        ; HL = user data ptr
    ; Reset card type; success path overwrites with SDSC/SDHC at the
    ; end.  Do NOT touch the LBA: on a re-init from sd_check_init
    ; the caller may have already seeked.
    PUSH HL
    LD   DE, SD_OFF_TYPE
    ADD  HL, DE
    LD   (HL), SD_TYPE_NONE
    POP  HL

    CALL sd_setup_io            ; bit-bang: patch I/O thunks
    CALL sd_init_transport      ; CS deasserted, slow speed

    ; 80 dummy clocks with CS deasserted (spec: ≥74 to wake card).
    LD   B, 10
    CALL sd_dummy_clocks

    ; --- CMD0 — GO_IDLE_STATE ---
    ; Each retry is its own CS-bounced transaction, per RomWBW.
    ; Cards can be flaky on the very first command after power-up;
    ; up to 8 attempts before giving up.
    LD   B, 8
sd_init_cmd0_retry:
    PUSH BC                     ; save loop counter
    CALL sd_xact_begin
    LD   A, SD_CMD0
    LD   DE, 0
    LD   HL, 0
    LD   C, SD_CRC_CMD0
    CALL sd_build_cmd_simple
    CALL sd_send_cmd_buf        ; A = R1
    PUSH AF                     ; save R1 — xact_end clobbers BC
    CALL sd_xact_end
    POP  AF
    POP  BC                     ; restore loop counter
    CP   SD_R1_IDLE
    JP   Z, sd_init_cmd8
    DEC  B
    JP   NZ, sd_init_cmd0_retry
    LD   B, A                   ; B = last R1 for diag
    LD   A, '0'
    JP   sd_diag_fail

sd_init_cmd8:
    ; CMD8 — SEND_IF_COND, arg = 0x000001AA (3.3V + 0xAA pattern).
    ; V2 cards reply R1=0x01 + 4 R7 bytes.  V1 cards reply with
    ; ILLEGAL_CMD bit set in R1 and no R7 trailer.
    CALL sd_xact_begin
    LD   A, SD_CMD8
    LD   DE, 0
    LD   HL, 0x01AA
    LD   C, SD_CRC_CMD8
    CALL sd_build_cmd_simple
    CALL sd_send_cmd_buf        ; A = R1
    AND  SD_R1_ILLEGAL_CMD       ; flag-only test; A clobbered (we don't need R1 again)
    JP   NZ, sd_init_cmd8_v1

    ; V2 path: drain the 4 R7 trailer bytes before deasserting CS.
    CALL sd_recv_byte
    CALL sd_recv_byte
    CALL sd_recv_byte
    CALL sd_recv_byte
    CALL sd_xact_end
    JP   sd_init_acmd41_v2

sd_init_cmd8_v1:
    CALL sd_xact_end
    JP   sd_init_acmd41_v1

sd_init_acmd41_v1:
    ; ACMD41 with arg=0 for V1 cards.  CMD55 then ACMD41, each in
    ; its own CS transaction, retried up to 200 times (~1 second
    ; at slow speed).
    LD   B, 200
sd_init_acmd41_v1_loop:
    PUSH BC
    LD   DE, 0
    LD   HL, 0
    CALL sd_send_acmd41
    POP  BC
    LD   C, A                   ; C = R1
    OR   A
    JP   Z, sd_init_v1_done
    DEC  B
    JP   NZ, sd_init_acmd41_v1_loop
    LD   B, C
    LD   A, 'V'
    JP   sd_diag_fail

sd_init_v1_done:
    ; V1 cards are SDSC by definition; skip CMD58.
    JP   sd_init_set_sdsc

sd_init_acmd41_v2:
    ; ACMD41 with arg=0x40000000 (HCS bit) for V2 cards.
    LD   B, 200
sd_init_acmd41_v2_loop:
    PUSH BC
    LD   DE, 0x4000             ; arg[31:24]=0x40 (HCS)
    LD   HL, 0
    CALL sd_send_acmd41
    POP  BC
    LD   C, A                   ; C = R1
    OR   A
    JP   Z, sd_init_v2_done
    DEC  B
    JP   NZ, sd_init_acmd41_v2_loop
    LD   B, C
    LD   A, 'H'
    JP   sd_diag_fail

sd_init_v2_done:
    ; CMD58 — READ_OCR.  R3 = R1 + 4-byte OCR.  Bit 30 of OCR
    ; (= bit 6 of OCR[31:24]) is the CCS flag: SDHC/SDXC if set,
    ; SDSC otherwise.
    CALL sd_xact_begin
    LD   A, SD_CMD58
    LD   DE, 0
    LD   HL, 0
    LD   C, 0xFF
    CALL sd_build_cmd_simple
    CALL sd_send_cmd_buf        ; A = R1
    OR   A
    JP   NZ, sd_init_cmd58_fail
    CALL sd_recv_byte           ; OCR[31:24] (CCS bit)
    LD   D, A                   ; preserve
    CALL sd_recv_byte           ; OCR[23:16]
    CALL sd_recv_byte           ; OCR[15:8]
    CALL sd_recv_byte           ; OCR[7:0]
    CALL sd_xact_end
    LD   A, D
    AND  0x40                   ; CCS bit
    JP   Z, sd_init_set_sdsc

    ; SDHC / SDXC (block-addressed).
    LD   A, (SD_DEV_ID)
    LD   B, A
    CALL sd_get_userdata
    LD   DE, SD_OFF_TYPE
    ADD  HL, DE
    LD   (HL), SD_TYPE_SDHC
    JP   sd_init_done

sd_init_cmd58_fail:
    PUSH AF                     ; save R1 — xact_end clobbers BC
    CALL sd_xact_end
    POP  AF
    LD   B, A                   ; B = R1 for diag
    LD   A, '5'
    JP   sd_diag_fail

sd_init_set_sdsc:
    LD   A, (SD_DEV_ID)
    LD   B, A
    CALL sd_get_userdata
    LD   DE, SD_OFF_TYPE
    ADD  HL, DE
    LD   (HL), SD_TYPE_SDSC

sd_init_done:
    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

sd_init_fail:
    CALL sd_cs_deassert         ; defensive — usually already deasserted
    LD   B, 1
    CALL sd_dummy_clocks
    POP  DE
    POP  BC
    LD   A, ERR_IO
    LD   HL, 0
    RET

; sd_send_acmd41
; Send CMD55 + ACMD41 as two separate CS-bounced transactions.
; Inputs:
;   DE, HL = ACMD41 argument (D=arg[31:24], L=arg[7:0])
; Outputs:
;   A = R1 from ACMD41
sd_send_acmd41:
    PUSH DE
    PUSH HL
    CALL sd_xact_begin
    LD   A, SD_CMD55
    LD   DE, 0
    LD   HL, 0
    LD   C, 0xFF
    CALL sd_build_cmd_simple
    CALL sd_send_cmd_buf        ; A = CMD55 R1 (we don't check it)
    CALL sd_xact_end
    POP  HL
    POP  DE
    CALL sd_xact_begin
    LD   A, SD_ACMD41
    LD   C, 0xFF
    CALL sd_build_cmd_simple
    CALL sd_send_cmd_buf        ; A = ACMD41 R1
    PUSH AF                     ; save R1 — xact_end clobbers BC
    CALL sd_xact_end
    POP  AF
    RET

; ============================================================
; sd_readblock
; Read one 512-byte block from the SD card at the current LBA.
; Inputs:  B  = physical device ID
;          DE = pointer to 512-byte destination buffer
; Outputs: A  = ERR_SUCCESS or ERR_IO
;          HL = 0
;
; Stack discipline: PUSH BC, PUSH DE on entry; matched by every
; exit path.  HL is freely clobbered by sd_send_cmd_buf and
; sd_setup_address — we re-fetch via sd_get_userdata when needed.
; ============================================================
sd_readblock:
    PUSH BC
    PUSH DE
    LD   A, B
    LD   (SD_DEV_ID), A         ; stash device ID for use after CSI/O ops
    CALL sd_check_init          ; auto-init if SD_TYPE still NONE
    OR   A
    JP   NZ, sd_readblock_no_card
    CALL sd_get_userdata        ; HL = user data ptr (re-fetch after init)

    CALL sd_setup_io            ; bit-bang patches I/O thunks; CSI/O no-op
    CALL sd_set_speed_fast      ; HL preserved by both transports
    CALL sd_setup_address       ; HL,DE → address arg
    LD   A, SD_CMD17
    LD   C, 0xFF
    CALL sd_build_cmd_simple

    CALL sd_cs_assert
    LD   B, 1
    CALL sd_dummy_clocks
    CALL sd_send_cmd_buf
    OR   A
    JP   NZ, sd_readblock_err

    CALL sd_wait_token
    OR   A
    JP   NZ, sd_readblock_err

    ; Recover destination buffer ptr (saved by outer PUSH DE).
    POP  DE                     ; DE = caller's buffer ptr
    PUSH DE                     ; restore for end-of-routine POP
    CALL sd_xfer_block          ; reads 512 + 2 CRC discard

    CALL sd_cs_deassert
    LD   B, 1
    CALL sd_dummy_clocks
    CALL sd_set_speed_init
    LD   A, (SD_DEV_ID)
    LD   B, A
    CALL sd_get_userdata
    CALL sd_inc_lba
    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

sd_readblock_err:
    CALL sd_cs_deassert
    LD   B, 1
    CALL sd_dummy_clocks
    CALL sd_set_speed_init
    POP  DE
    POP  BC
    LD   A, ERR_IO
    LD   HL, 0
    RET

sd_readblock_no_card:
    POP  DE
    POP  BC
    LD   A, ERR_IO
    LD   HL, 0
    RET

; ============================================================
; sd_writeblock
; Write one 512-byte block to the SD card at the current LBA.
; Inputs:  B  = physical device ID
;          DE = pointer to 512-byte source buffer
; Outputs: A  = ERR_SUCCESS or ERR_IO
;          HL = 0
; ============================================================
sd_writeblock:
    PUSH BC
    PUSH DE
    LD   A, B
    LD   (SD_DEV_ID), A         ; stash device ID for use after CSI/O ops
    CALL sd_check_init
    OR   A
    JP   NZ, sd_writeblock_no_card
    CALL sd_get_userdata

    CALL sd_setup_io
    CALL sd_set_speed_fast
    CALL sd_setup_address
    LD   A, SD_CMD24
    LD   C, 0xFF
    CALL sd_build_cmd_simple

    CALL sd_cs_assert
    LD   B, 1
    CALL sd_dummy_clocks
    CALL sd_send_cmd_buf        ; A = R1
    OR   A
    JP   Z, sd_writeblock_cmd24_ok
    LD   B, A                   ; B = R1 for diag
    LD   A, 'C'                 ; CMD24 phase
    CALL sd_diag_print
    JP   sd_writeblock_err
sd_writeblock_cmd24_ok:

    ; One dummy byte separator (Nwr), then the data token.
    LD   A, 0xFF
    CALL sd_send_byte
    LD   A, SD_TOKEN_DATA
    CALL sd_send_byte

    POP  DE                     ; DE = caller's source buffer
    PUSH DE                     ; restore for end-of-routine POP
    CALL sd_xmit_block

    ; Data response: low 5 bits = status; 0x05 = accepted.
    CALL sd_recv_byte           ; A = response byte
    LD   B, A                   ; B = full response (kept for diag)
    AND  SD_RESP_MASK
    CP   SD_RESP_ACCEPTED
    JP   Z, sd_writeblock_resp_ok
    LD   A, 'D'                 ; data response phase
    CALL sd_diag_print
    JP   sd_writeblock_err
sd_writeblock_resp_ok:

    ; Wait for not-busy: card drives MISO low while programming.
    ; ~64K poll cycles ≈ 0.5 s at fast speed; comfortably above
    ; the 250 ms typical write latency.
    LD   DE, 0xFFFF
sd_writeblock_busy_loop:
    PUSH DE
    CALL sd_recv_byte
    POP  DE
    CP   0xFF
    JP   Z, sd_writeblock_busy_done
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, sd_writeblock_busy_loop
    LD   B, 0                   ; busy timeout — show 0 for "never went 0xFF"
    LD   A, 'B'
    CALL sd_diag_print
    JP   sd_writeblock_err

sd_writeblock_busy_done:
    CALL sd_cs_deassert
    LD   B, 1
    CALL sd_dummy_clocks
    CALL sd_set_speed_init
    LD   A, (SD_DEV_ID)
    LD   B, A
    CALL sd_get_userdata
    CALL sd_inc_lba
    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

sd_writeblock_err:
    CALL sd_cs_deassert
    LD   B, 1
    CALL sd_dummy_clocks
    CALL sd_set_speed_init
    POP  DE
    POP  BC
    LD   A, ERR_IO
    LD   HL, 0
    RET

sd_writeblock_no_card:
    POP  DE
    POP  BC
    LD   A, ERR_IO
    LD   HL, 0
    RET

; ============================================================
; sd_seek
; Set the current 16-bit LBA in user data.  Higher 2 bytes zeroed.
; Inputs:  B  = physical device ID
;          DE = block number (16-bit)
; Outputs: A  = ERR_SUCCESS
;          HL = 0
; ============================================================
sd_seek:
    PUSH BC
    LD   A, B
    CALL find_physdev_by_id
    PUSH DE
    LD   DE, PHYSDEV_OFF_DATA + SD_OFF_LBA
    ADD  HL, DE
    POP  DE
    LD   (HL), E
    INC  HL
    LD   (HL), D
    INC  HL
    LD   (HL), 0
    INC  HL
    LD   (HL), 0
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; sd_bgetpos
; Standard helper — same shape as cf_bgetpos.
; ============================================================
sd_bgetpos:
    LD   DE, PHYSDEV_OFF_DATA + SD_OFF_LBA
    JP   common_bgetpos

; ============================================================
; sd_bgetsize
; Report a fixed nominal capacity (32 MB, 65536 blocks).  Apps
; that need exact capacity should read the CSD register directly.
; ============================================================
sd_bgetsize:
    XOR  A
    LD   (DE), A                ; LE byte 0 (LSB) = 0x00
    INC  DE
    LD   (DE), A                ; byte 1 = 0x00
    INC  DE
    LD   (DE), A                ; byte 2 = 0x00
    INC  DE
    LD   A, SD_REPORTED_SIZE_HI ; byte 3 (MSB) = 0x02 → 0x02000000 = 32 MB
    LD   (DE), A
    LD   H, 0
    LD   L, 0
    RET

; ============================================================
; Device Function Table for SD block device (block DFT, 9 slots)
; ============================================================
dft_sd:
    DEFW sd_init                ; slot 0: Initialize
    DEFW null_getstatus         ; slot 1: GetStatus (always ready)
    DEFW sd_readblock           ; slot 2: ReadBlock
    DEFW sd_writeblock          ; slot 3: WriteBlock
    DEFW sd_seek                ; slot 4: Seek
    DEFW sd_bgetpos             ; slot 5: GetPosition
    DEFW sd_bgetsize            ; slot 6: GetLength
    DEFW un_error               ; slot 7: SetSize
    DEFW un_error               ; slot 8: Close

; ============================================================
; PDTENTRY_SD ID, NAME [, PORT]
; Build a ROM PDT entry for the SD card.  In CSI/O mode the PORT
; argument is unused; in bit-bang mode it sets the SC611 latch port.
;
; User data layout (17 bytes):
;   bytes 0-3  current LBA (zero-initialised once by the ROM
;              template; sd_init does NOT touch the LBA so a
;              caller-issued sd_seek survives a re-init)
;   byte  4    card type (cleared to SD_TYPE_NONE by sd_init,
;              then set to SDSC/SDHC if init succeeds)
;   byte  5    bit-bang port number (CSI/O builds: dead byte)
;   bytes 6-16 padding
; ============================================================
    IFDEF SD_USE_CSIO
PDTENTRY_SD macro ID, NAME
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0, 0, 0           ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_BLOCK_IN | DEVCAP_BLOCK_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_sd                         ; PHYSDEV_OFF_DFT
    DEFS 4, 0                           ; LBA (4 bytes)
    DEFB SD_TYPE_NONE                   ; card type
    DEFS 12, 0                          ; padding (1 dead port byte + 11)
endm
    ENDIF

    IFDEF SD_USE_BITBANG
PDTENTRY_SD macro ID, NAME, PORT
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0, 0, 0           ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_BLOCK_IN | DEVCAP_BLOCK_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_sd                         ; PHYSDEV_OFF_DFT
    DEFS 4, 0                           ; LBA (4 bytes)
    DEFB SD_TYPE_NONE                   ; card type
    DEFB PORT                           ; bit-bang port
    DEFS 11, 0                          ; padding
endm
    ENDIF

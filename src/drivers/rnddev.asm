; NostOS Random Character Device Driver
; Returns pseudo-random bytes via a 16-bit Galois LFSR.
; ============================================================

; ------------------------------------------------------------
; rnd_init
; Seed the LFSR with a nonzero value.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; Preserves: BC, DE
; ------------------------------------------------------------
rnd_init:
    LD   A, 0xAC
    LD   (RND_SEED), A
    LD   A, 0xE1
    LD   (RND_SEED + 1), A
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; rnd_readbyte
; Return a pseudo-random byte via 16-bit Galois LFSR.
; Polynomial: x^16 + x^14 + x^13 + x^11 + 1 (taps = 0xB400)
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_SUCCESS
;   L  - random byte
;   H  - 0
; Preserves: BC, DE
; ------------------------------------------------------------
rnd_readbyte:
    PUSH BC
    LD   HL, (RND_SEED)
    LD   B, 8                   ; shift 8 bits for one output byte
rnd_readbyte_loop:
    LD   A, L
    AND  1                      ; test low bit; clears carry
    LD   A, H
    RRA                         ; shift high byte right (0 from top)
    LD   H, A
    LD   A, L
    RRA                         ; shift low byte right (H bit0 from top)
    LD   L, A
    JP   Z, rnd_readbyte_next   ; bit 0 was 0, skip XOR
    LD   A, H
    XOR  0xB4                   ; high byte of taps 0xB400
    LD   H, A
rnd_readbyte_next:
    DEC  B
    JP   NZ, rnd_readbyte_loop
    LD   (RND_SEED), HL         ; save LFSR state
    LD   H, 0                   ; L = random byte (already correct)
    POP  BC
    XOR  A                      ; ERR_SUCCESS
    RET

; ------------------------------------------------------------
; Device Function Table for RND device (char DFT, 4 slots)
; ------------------------------------------------------------
dft_rnd:
    DEFW rnd_init               ; slot 0: Initialize
    DEFW null_getstatus         ; slot 1: GetStatus (always ready)
    DEFW rnd_readbyte           ; slot 2: ReadByte
    DEFW null_writebyte         ; slot 3: WriteByte (discard)

; ============================================================
; PDTENTRY_RND ID, NAME
; Macro: Declare a ROM PDT entry for the random device.
; Arguments:
;   ID   - physical device ID
;   NAME - 3-character device name string
; ============================================================
PDTENTRY_RND macro ID, NAME
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0, 0              ; PHYSDEV_OFF_NAME (7 bytes: 3-char name + 4 nulls)
    DEFB DEVCAP_CHAR_IN                 ; PHYSDEV_OFF_CAPS (read-only)
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_rnd                        ; PHYSDEV_OFF_DFT
    DEFS 17, 0                          ; user data (17 bytes, unused)
endm

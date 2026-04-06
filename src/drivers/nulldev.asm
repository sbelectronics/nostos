; NostOS Null Device Driver
; The null device discards all output and returns no input.
; ============================================================

; ------------------------------------------------------------
; null_init / null_getstatus / null_writebyte
; Return ERR_SUCCESS with HL = 0.
; ------------------------------------------------------------
null_init:
null_getstatus:
null_writebyte:
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; null_readbyte
; Return ERR_EOF — there is never any data to read.
; ------------------------------------------------------------
null_readbyte:
    LD   A, ERR_EOF
    LD   HL, 0
    RET

; ------------------------------------------------------------
; Device Function Table for NUL device (char DFT, 4 slots)
; ------------------------------------------------------------
dft_nul:
    DEFW null_init              ; slot 0: Initialize
    DEFW null_getstatus         ; slot 1: GetStatus
    DEFW null_readbyte          ; slot 2: ReadByte
    DEFW null_writebyte         ; slot 3: WriteByte

; ============================================================
; PDTENTRY_NUL ID, NAME
; Macro: Declare a ROM PDT entry for a null device.
; Arguments:
;   ID   - physical device ID (PHYSDEV_ID_*)
;   NAME - 3-character device name string (e.g. "NUL")
; ============================================================
PDTENTRY_NUL macro ID, NAME
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0, 0              ; PHYSDEV_OFF_NAME (7 bytes: 3-char name + 4 nulls)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_nul                        ; PHYSDEV_OFF_DFT
    DEFS 17, 0                          ; user data (17 bytes, unused)
endm

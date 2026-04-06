; NostOS Unassigned Device Driver
; The unassigned device returns an error for all operations.
; ============================================================

; ------------------------------------------------------------
; un_init
; Initialize the unassigned device: no-op, returns success.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
un_init:
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; un_error
; Return ERR_NOT_SUPPORTED for any attempt to use the device.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_NOT_SUPPORTED
;   HL - 0
; ------------------------------------------------------------
un_error:
    LD  A, ERR_NOT_SUPPORTED
    LD  HL, 0
    RET

; ------------------------------------------------------------
; Device Function Table for UN device (char DFT, 4 slots)
; ------------------------------------------------------------
dft_un:
    DEFW un_init                ; slot 0: Initialize
    DEFW un_error               ; slot 1: GetStatus
    DEFW un_error               ; slot 2: ReadByte
    DEFW un_error               ; slot 3: WriteByte

; ============================================================
; PDTENTRY_UN ID, NAME
; Macro: Declare a ROM PDT entry for an unassigned device.
; Arguments:
;   ID   - physical device ID (PHYSDEV_ID_*)
;   NAME - 2-character device name string (e.g. "UN")
; ============================================================
PDTENTRY_UN macro ID, NAME
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0, 0, 0           ; PHYSDEV_OFF_NAME (7 bytes: 2-char name + 5 nulls)
    DEFB 0                              ; PHYSDEV_OFF_CAPS (none)
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_un                         ; PHYSDEV_OFF_DFT
    DEFS 17, 0                          ; user data (17 bytes, unused)
endm

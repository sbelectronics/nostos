; ------------------------------------------------------------
; Common error return helpers
; ------------------------------------------------------------

; ------------------------------------------------------------
; sys_err_invalid_device
; Return ERR_INVALID_DEVICE to the syscall caller.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_INVALID_DEVICE
;   HL - 0
; ------------------------------------------------------------
sys_err_invalid_device:
    LD   A, ERR_INVALID_DEVICE
    LD   HL, 0
    RET

; ------------------------------------------------------------
; sys_err_not_found
; Return ERR_NOT_FOUND to the syscall caller.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_NOT_FOUND
;   HL - 0
; ------------------------------------------------------------
sys_err_not_found:
    LD   A, ERR_NOT_FOUND
    LD   HL, 0
    RET

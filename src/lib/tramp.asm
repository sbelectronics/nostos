; ------------------------------------------------------------
; 8080-compatible Dynamic I/O Trampolines
; Shared by kernel and user-space extensions.
; Requires constants.asm for TRAMP_IN_THUNK / TRAMP_OUT_THUNK.
; ------------------------------------------------------------

; ------------------------------------------------------------
; tramp_in
; Read a byte from a dynamically-specified port using a
; pre-populated workspace thunk.
; Inputs:
;   C  - port number to read from
; Outputs:
;   A  - value read from port
; ------------------------------------------------------------
tramp_in:
    PUSH HL
    LD   HL, TRAMP_IN_THUNK + 1
    LD   (HL), C                ; Write port number
    CALL TRAMP_IN_THUNK
    POP  HL
    RET

; ------------------------------------------------------------
; tramp_out
; Write a byte to a dynamically-specified port using a
; pre-populated workspace thunk.
; Inputs:
;   C  - port number to write to
;   A  - value to write
; Outputs:
;   (none)
; ------------------------------------------------------------
tramp_out:
    PUSH HL
    PUSH AF
    LD   HL, TRAMP_OUT_THUNK + 1  ; Address of port byte in thunk
    LD   (HL), C                ; Write port number
    POP  AF
    CALL TRAMP_OUT_THUNK
    POP  HL
    RET

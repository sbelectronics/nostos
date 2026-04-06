; ============================================================
; helloext.asm - Hello device kernel extension for NostOS
; Registers a character device "HELO" that repeats a message
; endlessly on read.  Write is a no-op (like NUL).
; ============================================================

    INCLUDE "../../src/include/syscall.asm"
    INCLUDE "../../src/include/constants.asm"

    ORG  0

HELO_PHYSDEV_ID     EQU 0x00    ; 0 = dynamically allocated by DEV_COPY

; ============================================================
; Entry point
; ============================================================
helloext_main:
    ; Register device: DEV_COPY clones our PDT template into
    ; a RAM slot, links it into the device list, and returns
    ; the physical device ID.
    LD   DE, helo_pdt
    LD   C, DEV_COPY
    CALL KERNELADDR
    OR   A
    JP   NZ, helloext_err

    ; Print success
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_ok
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Make extension resident
    LD   DE, helloext_end
    LD   C, SYS_SET_MEMBOT
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

helloext_err:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_err
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Driver functions
; ============================================================

; ------------------------------------------------------------
; helo_init / helo_writebyte / helo_getstatus
; No-ops — return ERR_SUCCESS.
; ------------------------------------------------------------
helo_init:
helo_getstatus:
helo_writebyte:
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; helo_readbyte
; Returns the next character of msg_hello, cycling endlessly.
; Outputs:
;   A  = ERR_SUCCESS
;   HL = character (L = byte, H = 0)
; ------------------------------------------------------------
helo_readbyte:
    LD   HL, (helo_pos)         ; HL = pointer into msg_hello
    LD   A, (HL)                ; A = current character
    OR   A                      ; null terminator?
    JP   NZ, helo_readbyte_ok
    ; Wrap around to start of message
    LD   HL, msg_hello
    LD   A, (HL)
helo_readbyte_ok:
    INC  HL
    LD   (helo_pos), HL         ; save next position
    LD   L, A                   ; L = character
    LD   H, 0
    XOR  A                      ; A = ERR_SUCCESS
    RET

; ============================================================
; Data
; ============================================================

msg_hello:
    DEFM "Hello from extension!", 0x0D, 0x0A, 0x1A, 0

helo_pos:
    DEFW msg_hello              ; current read position

msg_ok:
    DEFM "HELO device registered.", 0x0D, 0x0A, 0
msg_err:
    DEFM "Failed to register device.", 0x0D, 0x0A, 0

; ------------------------------------------------------------
; Device Function Table (char DFT, 4 slots)
; ------------------------------------------------------------
helo_dft:
    DEFW helo_init              ; slot 0: Initialize
    DEFW helo_getstatus         ; slot 1: GetStatus
    DEFW helo_readbyte          ; slot 2: ReadByte
    DEFW helo_writebyte         ; slot 3: WriteByte

; ------------------------------------------------------------
; PDT entry template — copied into RAM by DEV_COPY
; ------------------------------------------------------------
helo_pdt:
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB HELO_PHYSDEV_ID                ; PHYSDEV_OFF_ID
    DEFM "HELO", 0, 0, 0               ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW helo_dft                       ; PHYSDEV_OFF_DFT
    DEFS 17, 0                          ; PHYSDEV_OFF_DATA (unused)

helloext_end:

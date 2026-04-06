; ============================================================
; speech.asm - SP0256A-AL2 speech synthesis extension for NostOS
; Registers a character device "SP0" that writes allophones
; to the SP0256A-AL2 chip via a configurable I/O port.
;
; WriteByte: polls the port until it reads 0 (chip ready),
;            then writes the allophone value to the same port.
; ReadByte:  reads and returns the current value from the port.
; ============================================================

    INCLUDE "../../src/include/syscall.asm"
    INCLUDE "../../src/include/constants.asm"

    ORG  0

SP0_PHYSDEV_ID      EQU 0x00    ; 0 = dynamically allocated by DEV_COPY
SP0_DEFAULT_PORT    EQU 0x20    ; default I/O port for SP0256A-AL2

; PDT user data offset for the port number
SP0_OFF_PORT        EQU 0       ; port number (1 byte) within PHYSDEV_OFF_DATA

; ============================================================
; Entry point
; ============================================================
speech_main:
    ; Register device: DEV_COPY clones our PDT template into
    ; a RAM slot, links it into the device list.
    LD   DE, sp0_pdt
    LD   C, DEV_COPY
    CALL KERNELADDR
    OR   A
    JP   NZ, speech_err

    ; Print success
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_ok
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Make extension resident
    LD   DE, speech_end
    LD   C, SYS_SET_MEMBOT
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

speech_err:
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
; sp0_init / sp0_getstatus
; No-ops — return ERR_SUCCESS.
; ------------------------------------------------------------
sp0_init:
sp0_getstatus:
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; sp0_get_port
; Helper: look up this device's PDT entry and load the port
; number from user data.
; Inputs:
;   B  - physical device ID
; Outputs:
;   C  - port number
; ------------------------------------------------------------
sp0_get_port:
    PUSH DE
    LD   C, DEV_PHYS_GET
    CALL KERNELADDR             ; HL = PDT entry pointer
    LD   DE, PHYSDEV_OFF_DATA + SP0_OFF_PORT
    ADD  HL, DE
    LD   C, (HL)                ; C = port number
    POP  DE
    RET

; ------------------------------------------------------------
; sp0_readbyte
; Read the current value from the SP0256A-AL2 port.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  = ERR_SUCCESS
;   HL = value read (L = byte, H = 0)
; ------------------------------------------------------------
sp0_readbyte:
    PUSH BC
    CALL sp0_get_port           ; C = port
    CALL tramp_in               ; A = value from port
    LD   L, A
    LD   H, 0
    POP  BC
    XOR  A                      ; A = ERR_SUCCESS
    RET

; ------------------------------------------------------------
; sp0_writebyte
; Write an allophone to the SP0256A-AL2 chip.
; Polls the port until it reads 1 (chip ready), then writes
; the allophone byte.
; Inputs:
;   B  - physical device ID
;   E  - allophone byte to write
; Outputs:
;   A  = ERR_SUCCESS
;   HL = 0
; ------------------------------------------------------------
sp0_writebyte:
    PUSH BC
    CALL sp0_get_port           ; C = port

    ; Poll: read port until it returns 0 (chip ready)
sp0_poll:
    CALL tramp_in               ; A = value read from port
    OR   A
    JP   Z, sp0_poll

    ; Chip is ready — write the allophone
    LD   A, E                   ; A = allophone byte
    CALL tramp_out              ; write A to port

    POP  BC
    XOR  A                      ; A = ERR_SUCCESS
    LD   H, A
    LD   L, A
    RET

; ============================================================
; Data
; ============================================================

msg_ok:
    DEFM "SP0 device registered.", 0x0D, 0x0A, 0
msg_err:
    DEFM "Failed to register device.", 0x0D, 0x0A, 0

; ------------------------------------------------------------
; Device Function Table (char DFT, 4 slots)
; ------------------------------------------------------------
sp0_dft:
    DEFW sp0_init               ; slot 0: Initialize
    DEFW sp0_getstatus          ; slot 1: GetStatus
    DEFW sp0_readbyte           ; slot 2: ReadByte
    DEFW sp0_writebyte          ; slot 3: WriteByte

; ------------------------------------------------------------
; PDT entry template — copied into RAM by DEV_COPY
; ------------------------------------------------------------
sp0_pdt:
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB SP0_PHYSDEV_ID                 ; PHYSDEV_OFF_ID
    DEFM "SP0", 0, 0, 0, 0             ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW sp0_dft                        ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFB SP0_DEFAULT_PORT               ; SP0_OFF_PORT: I/O port number
    DEFS 16, 0                          ; padding

; ============================================================
; Shared library includes
; ============================================================
    INCLUDE "../../src/lib/tramp.asm"

speech_end:

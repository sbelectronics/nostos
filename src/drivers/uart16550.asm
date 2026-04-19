; NostOS 16550 UART Console Driver
; Polled I/O. Base port dynamically mapped from PDT.
; ============================================================

; ------------------------------------------------------------
; uart16550_init
; Initialize the 16550 UART for 115200 8N1 polled operation.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
uart16550_init:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + UART16550_OFF_BASE
    ADD  HL, DE
    LD   D, (HL)                ; D = base port

    LD   A, D
    ADD  A, UART16550_REG_LCR
    LD   C, A                   ; C = LCR port
    LD   A, UART16550_LCR_DLAB  ; set DLAB to access baud rate registers
    CALL tramp_out

    LD   C, D                   ; C = DLL port (base+0, DLAB=1)
    LD   A, UART16550_DIV_LOW
    CALL tramp_out

    LD   A, D
    ADD  A, UART16550_REG_IER
    LD   C, A                   ; C = DLM port (base+1, DLAB=1)
    LD   A, UART16550_DIV_HIGH
    CALL tramp_out

    LD   A, D
    ADD  A, UART16550_REG_LCR
    LD   C, A                   ; C = LCR port
    LD   A, UART16550_LCR_8N1   ; clear DLAB, configure 8N1
    CALL tramp_out

    LD   A, D
    ADD  A, UART16550_REG_FCR
    LD   C, A                   ; C = FCR port
    LD   A, UART16550_FCR_INIT  ; enable and reset FIFOs
    CALL tramp_out

    LD   A, D
    ADD  A, UART16550_REG_IER
    LD   C, A                   ; C = IER port
    XOR  A                      ; disable all interrupts
    CALL tramp_out

    LD   A, D
    ADD  A, UART16550_REG_MCR
    LD   C, A                   ; C = MCR port
    LD   A, UART16550_MCR_INIT  ; assert DTR and RTS
    CALL tramp_out

    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; uart16550_getstatus
; Check whether a character is waiting in the receive FIFO.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 1 if character waiting, 0 otherwise
; ------------------------------------------------------------
uart16550_getstatus:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + UART16550_OFF_BASE
    ADD  HL, DE
    LD   A, (HL)                ; A = base port
    ADD  A, UART16550_REG_LSR
    LD   C, A                   ; C = LSR port

    CALL tramp_in               ; A = LSR value
    AND  UART16550_LSR_DR       ; isolate data-ready bit
    LD   L, A                   ; L = 1 if char ready, else 0
    LD   H, 0
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    RET

; ------------------------------------------------------------
; uart16550_readbyte_raw
; Read one character from the 16550 without echo (blocking).
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS
;   HL - character read (L = char, H = 0)
; ------------------------------------------------------------
uart16550_readbyte_raw:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + UART16550_OFF_BASE
    ADD  HL, DE
    LD   D, (HL)                ; D = base port (RBR)

    LD   A, D
    ADD  A, UART16550_REG_LSR
    LD   E, A                   ; E = LSR port

uart16550_readbyte_raw_wait:
    LD   C, E                   ; C = LSR port
    CALL tramp_in               ; A = LSR value
    AND  UART16550_LSR_DR
    JP   Z, uart16550_readbyte_raw_wait

    LD   C, D                   ; C = base port (RBR)
    CALL tramp_in               ; A = received byte
    LD   L, A
    LD   H, 0
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    XOR  A
    RET

; ------------------------------------------------------------
; uart16550_writebyte
; Write one character to the 16550 (blocking until THRE).
; Inputs:
;   B  - physical device ID
;   E  - character to write
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
uart16550_writebyte:
    PUSH BC                     ; preserve B (device ID) and C
    PUSH DE                     ; preserve E (char to write); D is repurposed below
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + UART16550_OFF_BASE
    ADD  HL, DE
    LD   B, (HL)                ; B = base port (THR)
    POP  DE                     ; restore DE; E = char to write
    LD   A, B
    ADD  A, UART16550_REG_LSR
    LD   D, A                   ; D = LSR port

uart16550_writebyte_wait:
    LD   C, D                   ; C = LSR port
    CALL tramp_in               ; A = LSR value
    AND  UART16550_LSR_THRE
    JP   Z, uart16550_writebyte_wait

    LD   A, E                   ; A = char to write
    LD   C, B                   ; C = THR port (base + 0)
    CALL tramp_out

    POP  BC                     ; restore original B (device ID) and C
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; Device Function Table for 16550 console (char DFT, 4 slots)
; ------------------------------------------------------------
dft_uart16550:
    DEFW uart16550_init         ; slot 0: Initialize
    DEFW uart16550_getstatus    ; slot 1: GetStatus
    DEFW uart16550_readbyte_raw ; slot 2: ReadByte (raw, no echo)
    DEFW uart16550_writebyte    ; slot 3: WriteByte

; ============================================================
; PDTENTRY_16550 ID, NAME, BASE_PORT
; Macro: Declare a ROM PDT entry for a 16550 character device.
; Arguments:
;   ID        - physical device ID (PHYSDEV_ID_*)
;   NAME      - 4-character device name string (e.g. "U550")
;   BASE_PORT - base I/O port of the 16550 (RBR/THR at base+0)
; ============================================================
PDTENTRY_16550 macro ID, NAME, BASE_PORT
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0                  ; PHYSDEV_OFF_NAME (7 bytes: 4-char name + 3 nulls)
    DEFB DEVCAP_CHAR_IN | DEVCAP_CHAR_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_uart16550                  ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFB BASE_PORT                      ; base I/O port
    DEFS 16, 0                          ; padding to fill 17-byte user data field
endm

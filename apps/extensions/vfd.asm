; ============================================================
; vfd.asm - VFD (Vacuum Fluorescent Display) extension for NostOS
; Registers a character-output-only device "VFD" that drives a
; 4-line x 40-column HD44780-based VFD via two controllers.
;
; Hardware: Two HD44780 controllers, each driving 2 lines.
;   Controller 0 (lines 1-2): command port = base+0, data port = base+1
;   Controller 1 (lines 3-4): command port = base+2, data port = base+3
;
; Text is written to line 4. When a line wraps or LF is received,
; all lines scroll up and line 4 is cleared.
;
; Based on RomWBW vfd.asm by Wayne Warthen.
; ============================================================

    INCLUDE "../../src/include/syscall.asm"
    INCLUDE "../../src/include/constants.asm"

    ORG  0

VFD_PHYSDEV_ID      EQU 0x00       ; 0 = dynamically allocated by DEV_COPY
VFD_DEFAULT_PORT    EQU 0x00       ; default base I/O port
VFD_LINE_LEN        EQU 40         ; characters per line
VFD_NUM_LINES       EQU 4          ; number of display lines

; Port offsets from base
VFD_C0              EQU 0          ; controller 0 command
VFD_D0              EQU 1          ; controller 0 data
VFD_C1              EQU 2          ; controller 1 command
VFD_D1              EQU 3          ; controller 1 data

; HD44780 commands
VFD_CMD_FUNCSET     EQU 0x38       ; function set: 8-bit, 2-line
VFD_CMD_CLEAR       EQU 0x01       ; clear display
VFD_CMD_DISON_NOCUR EQU 0x0C       ; display on, cursor off
VFD_CMD_DISON_CUR   EQU 0x0F       ; display on, cursor on, blink
VFD_CMD_LINE1       EQU 0x80       ; DDRAM address: line 1 start
VFD_CMD_LINE2       EQU 0xC0       ; DDRAM address: line 2 start
VFD_CMD_CURLEFT     EQU 0x10       ; shift cursor left

; ============================================================
; Entry point
; ============================================================
vfd_main:
    ; Initialize the display hardware
    CALL vfd_hw_init

    ; Register device via DEV_COPY
    LD   DE, vfd_pdt
    LD   C, DEV_COPY
    CALL KERNELADDR
    OR   A
    JP   NZ, vfd_err

    ; Print success
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_ok
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Make extension resident
    LD   DE, vfd_end
    LD   C, SYS_SET_MEMBOT
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

vfd_err:
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_err
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Hardware initialization
; ============================================================
vfd_hw_init:
    PUSH AF
    PUSH BC

    ; Initialize controller 0 (lines 1-2)
    LD   C, VFD_DEFAULT_PORT + VFD_C0
    LD   A, VFD_CMD_FUNCSET
    CALL vfd_out
    LD   A, VFD_CMD_CLEAR
    CALL vfd_out
    CALL vfd_delay                  ; Clear needs ~1.52ms to execute
    LD   A, VFD_CMD_DISON_NOCUR
    CALL vfd_out

    ; Initialize controller 1 (lines 3-4)
    LD   C, VFD_DEFAULT_PORT + VFD_C1
    LD   A, VFD_CMD_FUNCSET
    CALL vfd_out
    LD   A, VFD_CMD_CLEAR
    CALL vfd_out
    CALL vfd_delay                  ; Clear needs ~1.52ms to execute
    LD   A, VFD_CMD_DISON_CUR
    CALL vfd_out

    ; Clear the line buffer
    CALL vfd_clear_buf

    ; Position cursor to start of line 4
    CALL vfd_sol

    POP  BC
    POP  AF
    RET

; ============================================================
; Driver functions
; ============================================================

; ------------------------------------------------------------
; vfd_init / vfd_getstatus
; Return ERR_SUCCESS.
; ------------------------------------------------------------
vfd_init:
vfd_getstatus:
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; vfd_readbyte
; Output-only device — reading is not supported.
; ------------------------------------------------------------
vfd_readbyte:
    LD   A, ERR_NOT_SUPPORTED
    LD   HL, 0
    RET

; ------------------------------------------------------------
; vfd_writebyte
; Write a character to the VFD display.
; Inputs:
;   E  - character to write
; Outputs:
;   A  = ERR_SUCCESS
;   HL = 0
; ------------------------------------------------------------
vfd_writebyte:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   A, E
    CP   0x08                       ; backspace?
    JP   Z, vfd_bspc
    CP   0x0A                       ; line feed?
    JP   Z, vfd_newline
    CP   0x0D                       ; carriage return?
    JP   Z, vfd_cr

    ; Printable character — write to VFD and buffer
    LD   C, VFD_DEFAULT_PORT + VFD_D1
    LD   A, E
    CALL vfd_out                  ; send char to controller 1

    LD   HL, (vfd_ptr)             ; store in line buffer
    LD   (HL), E
    INC  HL
    LD   (vfd_ptr), HL

    LD   A, (vfd_col)              ; advance column
    INC  A
    LD   (vfd_col), A

    CP   VFD_LINE_LEN              ; wrapped past end of line?
    JP   NZ, vfd_putc_out

    ; Line full — scroll and reposition
vfd_newline:
    CALL vfd_scroll
    CALL vfd_redraw
    CALL vfd_sol
    JP   vfd_putc_out

vfd_bspc:
    LD   A, (vfd_col)
    OR   A
    JP   Z, vfd_putc_out           ; at column 0, ignore

    DEC  A                          ; move column back
    LD   (vfd_col), A

    LD   HL, (vfd_ptr)             ; move pointer back
    DEC  HL
    LD   (vfd_ptr), HL

    ; Shift VFD cursor left
    LD   C, VFD_DEFAULT_PORT + VFD_C1
    LD   A, VFD_CMD_CURLEFT
    CALL vfd_out
    JP   vfd_putc_out

vfd_cr:
    CALL vfd_sol
    JP   vfd_putc_out

vfd_putc_out:
    POP  HL
    POP  DE
    POP  BC
    XOR  A                          ; A = ERR_SUCCESS
    LD   H, A
    LD   L, A
    RET

; ============================================================
; Display helpers
; ============================================================

; ------------------------------------------------------------
; vfd_scroll
; Scroll the 4-line buffer up by one line. Line 4 is cleared.
; ------------------------------------------------------------
vfd_scroll:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL

    ; Copy line 2 → line 1
    LD   HL, vfd_line2
    LD   DE, vfd_line1
    LD   B, VFD_LINE_LEN
    CALL vfd_memcpy

    ; Copy line 3 → line 2
    LD   HL, vfd_line3
    LD   DE, vfd_line2
    LD   B, VFD_LINE_LEN
    CALL vfd_memcpy

    ; Copy line 4 → line 3
    LD   HL, vfd_line4
    LD   DE, vfd_line3
    LD   B, VFD_LINE_LEN
    CALL vfd_memcpy

    ; Clear line 4
    LD   HL, vfd_line4
    LD   B, VFD_LINE_LEN
    LD   A, ' '
    CALL vfd_memset

    POP  HL
    POP  DE
    POP  BC
    POP  AF
    RET

; ------------------------------------------------------------
; vfd_sol
; Set pointer and column to start of line 4. Position VFD
; cursor to start of controller 1, line 2 (DDRAM 0xC0).
; ------------------------------------------------------------
vfd_sol:
    PUSH AF
    PUSH BC
    LD   HL, vfd_line4
    LD   (vfd_ptr), HL
    XOR  A
    LD   (vfd_col), A
    ; Position cursor on controller 1
    LD   C, VFD_DEFAULT_PORT + VFD_C1
    LD   A, VFD_CMD_LINE2
    CALL vfd_out
    POP  BC
    POP  AF
    RET

; ------------------------------------------------------------
; vfd_redraw
; Redraw all 4 lines on the VFD from the buffer.
; ------------------------------------------------------------
vfd_redraw:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL

    ; Line 1: controller 0, DDRAM line 1
    LD   C, VFD_DEFAULT_PORT + VFD_C0
    LD   A, VFD_CMD_LINE1
    CALL vfd_out
    LD   HL, vfd_line1
    LD   C, VFD_DEFAULT_PORT + VFD_D0
    LD   B, VFD_LINE_LEN
    CALL vfd_send_line

    ; Line 2: controller 0, DDRAM line 2
    LD   C, VFD_DEFAULT_PORT + VFD_C0
    LD   A, VFD_CMD_LINE2
    CALL vfd_out
    LD   HL, vfd_line2
    LD   C, VFD_DEFAULT_PORT + VFD_D0
    LD   B, VFD_LINE_LEN
    CALL vfd_send_line

    ; Line 3: controller 1, DDRAM line 1
    LD   C, VFD_DEFAULT_PORT + VFD_C1
    LD   A, VFD_CMD_LINE1
    CALL vfd_out
    LD   HL, vfd_line3
    LD   C, VFD_DEFAULT_PORT + VFD_D1
    LD   B, VFD_LINE_LEN
    CALL vfd_send_line

    ; Line 4: controller 1, DDRAM line 2
    LD   C, VFD_DEFAULT_PORT + VFD_C1
    LD   A, VFD_CMD_LINE2
    CALL vfd_out
    LD   HL, vfd_line4
    LD   C, VFD_DEFAULT_PORT + VFD_D1
    LD   B, VFD_LINE_LEN
    CALL vfd_send_line

    POP  HL
    POP  DE
    POP  BC
    POP  AF
    RET

; ------------------------------------------------------------
; vfd_send_line
; Send B bytes from (HL) to port C.
; ------------------------------------------------------------
vfd_send_line:
    LD   A, (HL)
    CALL vfd_out
    INC  HL
    DEC  B
    JP   NZ, vfd_send_line
    RET

; ------------------------------------------------------------
; vfd_memcpy
; Copy B bytes from (HL) to (DE). 8080-compatible.
; ------------------------------------------------------------
vfd_memcpy:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, vfd_memcpy
    RET

; ------------------------------------------------------------
; vfd_memset
; Fill B bytes at (HL) with value in A. 8080-compatible.
; ------------------------------------------------------------
vfd_memset:
    LD   (HL), A
    INC  HL
    DEC  B
    JP   NZ, vfd_memset
    RET

; ------------------------------------------------------------
; vfd_out
; Write to HD44780 and wait for command execution.
; With VFD_LCD_COMPAT, adds a ~37μs delay after each write
; for LCD compatibility. Without it, just calls tramp_out.
; Inputs:
;   C  - port number
;   A  - value to write
; ------------------------------------------------------------
vfd_out:
IFNDEF VFD_LCD_COMPAT
    JP tramp_out        ; no delay -- jump to tramp_out and let it return
ELSE
    CALL tramp_out

    ; Fall through to vfd_short_delay

; ------------------------------------------------------------
; vfd_short_delay
; Delay ≥ 37μs for standard HD44780 command execution time.
; 48 * ~14 cycles = ~672 cycles.
; At 7.3728 MHz ≈ 91μs, at 18.432 MHz ≈ 36μs.
; ------------------------------------------------------------
vfd_short_delay:
    PUSH BC
    LD   B, 48
vfd_short_delay_loop:
    DEC  B
    JP   NZ, vfd_short_delay_loop
    POP  BC
ENDIF
    RET

; ------------------------------------------------------------
; vfd_delay
; Delay ≥ 2ms for HD44780 Clear/Home commands (need 1.52ms).
; Nested loop: 10 * 256 * ~14 cycles = ~35,840 cycles.
; At 7.3728 MHz ≈ 4.9ms, at 18.432 MHz ≈ 1.9ms.
; ------------------------------------------------------------
vfd_delay:
    PUSH BC
    LD   C, 10                     ; outer loop count
vfd_delay_outer:
    LD   B, 0                      ; inner: 256 iterations
vfd_delay_inner:
    DEC  B
    JP   NZ, vfd_delay_inner
    DEC  C
    JP   NZ, vfd_delay_outer
    POP  BC
    RET

; ------------------------------------------------------------
; vfd_clear_buf
; Fill the entire 4-line buffer with spaces.
; ------------------------------------------------------------
vfd_clear_buf:
    PUSH AF
    PUSH BC
    PUSH HL
    LD   HL, vfd_line1
    LD   B, VFD_LINE_LEN * VFD_NUM_LINES
    LD   A, ' '
    CALL vfd_memset
    POP  HL
    POP  BC
    POP  AF
    RET

; ============================================================
; Data
; ============================================================

msg_ok:
    DEFM "VFD device registered.", 0x0D, 0x0A, 0
msg_err:
    DEFM "Failed to register device.", 0x0D, 0x0A, 0

; Display state
vfd_ptr:
    DEFW vfd_line4                  ; current write pointer
vfd_col:
    DEFB 0                          ; current column (0-39)

; Line buffer (4 x 40 = 160 bytes)
vfd_line1:
    DEFS VFD_LINE_LEN, ' '
vfd_line2:
    DEFS VFD_LINE_LEN, ' '
vfd_line3:
    DEFS VFD_LINE_LEN, ' '
vfd_line4:
    DEFS VFD_LINE_LEN, ' '

; ------------------------------------------------------------
; Device Function Table (char DFT, 4 slots)
; ------------------------------------------------------------
vfd_dft:
    DEFW vfd_init                   ; slot 0: Initialize
    DEFW vfd_getstatus              ; slot 1: GetStatus
    DEFW vfd_readbyte               ; slot 2: ReadByte
    DEFW vfd_writebyte              ; slot 3: WriteByte

; ------------------------------------------------------------
; PDT entry template — copied into RAM by DEV_COPY
; ------------------------------------------------------------
vfd_pdt:
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB VFD_PHYSDEV_ID                 ; PHYSDEV_OFF_ID
    DEFM "VFD", 0, 0, 0, 0             ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_OUT                ; PHYSDEV_OFF_CAPS (output only)
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW vfd_dft                        ; PHYSDEV_OFF_DFT
    DEFS 17, 0                          ; PHYSDEV_OFF_DATA (unused)

; ============================================================
; Shared library includes
; ============================================================
    INCLUDE "../../src/lib/tramp.asm"

vfd_end:

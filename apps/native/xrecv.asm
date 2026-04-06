; ============================================================
; xrecv.asm - XMODEM Receive: receive a file via XMODEM protocol
; ============================================================
; Usage: XRECV <filename>
;
; Receives a file over the SERI/SERO serial port using the
; XMODEM (checksum) protocol. The filename may include a
; device prefix and/or subdirectory path.
;
; At startup, SERI and SERO are resolved to physical device
; IDs so that subsequent character I/O avoids the logical
; device table lookup on every call.
;
; Algorithm:
;   1. Parse and upcase filename
;   2. Resolve SERI/SERO to physical device IDs
;   3. Create output file
;   4. Send NAK to initiate transfer
;   5. Receive XMODEM blocks (SOH + blk# + ~blk# + 128 data + cksum)
;   6. Accumulate in 512-byte buffer; BWRITE when full
;   7. On EOT: flush, BSETSIZE, close, report
;
; Direct Port I/O (bypass kernel for receive path):
;   At 115200 baud with a 1-byte FIFO (ACIA MC6850), each byte
;   arrives every ~87us. A kernel syscall (KERNELADDR → dispatch →
;   linked-list device lookup → DFT call → driver) takes ~500+
;   T-states (~70us at 7.3728 MHz), leaving almost no margin for
;   the polling loop. Two back-to-back syscalls (status check +
;   data read) guarantee overrun.
;
;   Instead, we read the UART ctrl and data port numbers from the
;   PDT entry at startup, then poll/read directly via the kernel's
;   TRAMP_IN_THUNK (a 3-byte `IN A,(port); RET` thunk in workspace
;   RAM at 0x43E7). This reduces each poll to ~38 T-states (~5us),
;   giving ~16 polls per byte period — plenty of margin.
;
;   This works across all four NostOS UART drivers. At startup,
;   the physical device ID selects the port mapping:
;     ACIA, SIO/2, SCC:
;       ctrl/data port read from PDT user data +0/+1
;       RX ready = status bit 0
;     Z180 ASCI:
;       PDT user data +0 = channel (0 or 1)
;       ctrl = Z180_STAT0 + channel, data = Z180_RDR0 + channel
;       RX ready = status bit 7
;
;   Only the receive path uses direct I/O. ACK/NAK sends and file
;   writes go through KERNELADDR as normal — they happen between
;   blocks, so syscall overhead doesn't matter there.
;
; Quiet mode:
;   When SERO and CONO resolve to the same physical device (i.e.
;   the console IS the serial port, as in a typical BBS or terminal
;   setup), printing progress dots during the transfer would inject
;   bytes into the XMODEM data stream. The quiet flag suppresses
;   all mid-transfer console output in this case.
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point - jump over header
    JP   xm_main

    ; Header pad: 13 bytes (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; XMODEM protocol constants
; ============================================================
XM_SOH          EQU 0x01       ; Start of Header
XM_EOT          EQU 0x04       ; End of Transmission
XM_ACK          EQU 0x06       ; Acknowledge
XM_NAK          EQU 0x15       ; Negative Acknowledge
XM_CAN          EQU 0x18       ; Cancel

XM_MAX_RETRIES  EQU 10         ; max NAK retries before abort
XM_DATA_SIZE    EQU 128        ; bytes per XMODEM block
XM_TIMEOUT_OUT  EQU 4          ; outer timeout loop count (SOH wait)
XM_BYTE_TIMEOUT EQU 1          ; per-byte timeout outer loops
; Inner timeout loop = 65536 iterations (16-bit wrap)
; ~4 * 65536 * ~40us/iter ≈ ~10 seconds per NAK retry
; ~1 * 65536 * ~40us/iter ≈ ~2.6 seconds per byte timeout

; ============================================================
; Entry point
; ============================================================
xm_main:
    ; --- Parse filename from command line ---
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, xm_usage

    ; Save filename pointer
    LD   (xm_fname), HL

    ; Upcase filename in-place
xm_upcase:
    LD   A, (HL)
    OR   A
    JP   Z, xm_upcase_done
    CP   ' '
    JP   Z, xm_upcase_done
    CP   'a'
    JP   C, xm_upcase_store
    CP   'z' + 1
    JP   NC, xm_upcase_store
    AND  0x5F                   ; make uppercase
xm_upcase_store:
    LD   (HL), A
    INC  HL
    JP   xm_upcase
xm_upcase_done:
    LD   (HL), 0                ; null-terminate

    ; --- Print header ---
    LD   DE, xm_msg_header
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Resolve SERI logical device to physical ID ---
    ; Get logdev entry, follow physptr, read phys ID and caps
    LD   B, LOGDEV_ID_SERI
    LD   C, DEV_LOG_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, xm_error_noseri
    ; HL = pointer to logdev entry; read physptr
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = PDT entry pointer
    ; Check physptr is not NULL
    LD   A, D
    OR   E
    JP   Z, xm_error_noseri
    ; Read physical device ID
    LD   HL, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   A, (HL)
    LD   (xm_seri_id), A

    ; Set up direct port I/O parameters based on device type.
    ; ACIA/SIO/SCC: ctrl and data port numbers stored in PDT user data
    ;   at +0 and +1; RX ready = status bit 0.
    ; Z180 ASCI: PDT user data byte 0 = channel number (0 or 1);
    ;   status port = Z180_STAT0 + channel, data port = Z180_RDR0 + channel;
    ;   RX ready = status bit 7.
    CP   PHYSDEV_ID_Z180A
    JP   Z, xm_seri_z180
    CP   PHYSDEV_ID_Z180B
    JP   Z, xm_seri_z180

    ; ACIA / SIO / SCC path
    LD   HL, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   A, (HL)
    LD   (xm_seri_ctrl), A
    INC  HL
    LD   A, (HL)
    LD   (xm_seri_data), A
    LD   A, 0x01                ; RX ready = bit 0
    LD   (xm_seri_rxmask), A
    JP   xm_seri_ports_done

xm_seri_z180:
    ; Z180 ASCI: read channel number from PDT user data byte 0
    LD   HL, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   A, (HL)                ; A = channel (0 or 1)
    LD   C, A                   ; C = channel
    ADD  A, Z180_STAT0
    LD   (xm_seri_ctrl), A     ; status port = STAT0 + channel
    LD   A, C
    ADD  A, Z180_RDR0
    LD   (xm_seri_data), A     ; data port = RDR0 + channel
    LD   A, Z180_RDRF           ; RX ready = bit 7 (0x80)
    LD   (xm_seri_rxmask), A

xm_seri_ports_done:
    ; Verify device has DEVCAP_CHAR_IN
    LD   HL, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  DEVCAP_CHAR_IN
    JP   Z, xm_error_noseri

    ; --- Resolve SERO logical device to physical ID ---
    LD   B, LOGDEV_ID_SERO
    LD   C, DEV_LOG_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, xm_error_nosero
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = PDT entry pointer
    LD   A, D
    OR   E
    JP   Z, xm_error_nosero
    ; Read physical device ID
    LD   HL, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   A, (HL)
    LD   (xm_sero_id), A
    ; Verify device has DEVCAP_CHAR_OUT
    LD   HL, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  DEVCAP_CHAR_OUT
    JP   Z, xm_error_nosero

    ; --- Detect quiet mode: if SERO == CONO, suppress mid-transfer output ---
    ; Resolve CONO to physical ID for comparison
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_LOG_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, xm_quiet_off          ; can't resolve CONO, assume not quiet
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                    ; DE = CONO PDT entry pointer
    LD   A, D
    OR   E
    JP   Z, xm_quiet_off
    LD   HL, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   A, (HL)                    ; A = CONO physical ID
    LD   D, A
    LD   A, (xm_sero_id)
    CP   D
    JP   NZ, xm_quiet_off
    LD   A, 1
    LD   (xm_quiet), A
    JP   xm_quiet_done
xm_quiet_off:
    XOR  A
    LD   (xm_quiet), A
xm_quiet_done:

    ; --- Create output file ---
    LD   DE, (xm_fname)
    LD   C, SYS_PATH_PARSE
    CALL KERNELADDR
    OR   A
    JP   NZ, xm_error
    ; L = device ID, DE = path component
    LD   B, L
    LD   C, DEV_FCREATE
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, xm_error
    ; L = file handle (device ID)
    LD   A, L
    LD   (xm_handle), A

    ; --- Initialize state ---
    LD   A, 1
    LD   (xm_expected_blk), A
    LD   HL, 0
    LD   (xm_bufpos), HL
    LD   (xm_total), HL
    XOR  A
    LD   (xm_total + 2), A

    ; --- Print waiting message ---
    LD   DE, xm_msg_waiting
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Send initial NAK to start transfer ---
    LD   A, XM_MAX_RETRIES
    LD   (xm_retries), A

xm_send_nak_wait:
    CALL xm_send_nak

; ------------------------------------------------------------
; Wait for SOH or EOT with timeout
; Uses direct port I/O via trampoline for speed.
; ------------------------------------------------------------
xm_wait_soh:
    ; Z180 ASCI: clear any pending errors (PE/FE/OVRN) before polling.
    ; If OVRN occurs and isn't cleared, the Z180 receiver stalls permanently.
    ; On non-Z180, rxmask != 0x80 so this is skipped.
    LD   A, (xm_seri_rxmask)
    CP   Z180_RDRF              ; 0x80 = Z180?
    JP   NZ, xm_wait_soh_poll
    ; Read STAT register
    LD   A, (xm_seri_ctrl)
    LD   (TRAMP_IN_THUNK + 1), A
    CALL TRAMP_IN_THUNK         ; A = STAT
    AND  0x70                   ; PE | FE | OVRN
    JP   Z, xm_wait_soh_poll   ; no errors
    ; Clear errors: CNTLA port = STAT port - 4 (STAT is CNTLA + 4)
    LD   A, (xm_seri_ctrl)
    SUB  Z180_STAT0 - Z180_CNTLA0  ; A = CNTLA port
    LD   (TRAMP_IN_THUNK + 1), A
    LD   (TRAMP_OUT_THUNK + 1), A
    CALL TRAMP_IN_THUNK         ; A = CNTLA value
    AND  0xF7                   ; clear EFR (bit 3)
    CALL TRAMP_OUT_THUNK        ; write back → clears error flags

xm_wait_soh_poll:
    ; Set up trampoline for status port polling
    LD   A, (xm_seri_ctrl)
    LD   (TRAMP_IN_THUNK + 1), A
    LD   A, XM_TIMEOUT_OUT
    LD   (xm_tmr_outer), A
    LD   A, (xm_seri_rxmask)
    LD   E, A                   ; E = RX ready mask for polling loop
xm_wait_outer:
    LD   HL, 0                  ; inner counter: 0 = 65536 iterations
xm_wait_inner:
    CALL TRAMP_IN_THUNK         ; A = status register
    AND  E                      ; test RX ready bit (bit 0 or bit 7)
    JP   NZ, xm_char_ready
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, xm_wait_inner
    ; Inner loop expired
    LD   A, (xm_tmr_outer)
    DEC  A
    LD   (xm_tmr_outer), A
    JP   NZ, xm_wait_outer

    ; Full timeout - retry NAK
    LD   A, (xm_retries)
    DEC  A
    LD   (xm_retries), A
    JP   Z, xm_timeout
    JP   xm_send_nak_wait

; ------------------------------------------------------------
; Character available - read and dispatch
; ------------------------------------------------------------
xm_char_ready:
    ; Read the byte via trampoline (data port)
    LD   A, (xm_seri_data)
    LD   (TRAMP_IN_THUNK + 1), A
    CALL TRAMP_IN_THUNK         ; A = received byte

    CP   XM_SOH
    JP   Z, xm_recv_block
    CP   XM_EOT
    JP   Z, xm_eot
    CP   XM_CAN
    JP   Z, xm_cancelled
    ; Ignore other bytes
    JP   xm_wait_soh

; ------------------------------------------------------------
; Receive one XMODEM block
; ------------------------------------------------------------
xm_recv_block:
    ; Read block number
    CALL xm_recv_byte
    JP   C, xm_block_nak        ; timeout → NAK
    LD   A, L
    LD   (xm_recv_blk), A

    ; Read complement of block number
    CALL xm_recv_byte
    JP   C, xm_block_nak
    LD   A, L
    LD   (xm_recv_cpl), A

    ; Read 128 data bytes into xm_buf at current bufpos
    ; Accumulate checksum as we go
    XOR  A
    LD   (xm_checksum), A

    ; Calculate destination: xm_buf + bufpos
    LD   HL, (xm_bufpos)
    LD   DE, xm_buf
    ADD  HL, DE                 ; HL = dest pointer

    LD   B, XM_DATA_SIZE        ; 128 bytes to read
xm_recv_data:
    PUSH BC
    PUSH HL
    CALL xm_recv_byte           ; L = data byte, carry = timeout
    LD   A, L                   ; (doesn't affect carry)
    POP  HL                     ; (doesn't affect carry)
    POP  BC                     ; (doesn't affect carry)
    JP   C, xm_block_nak        ; timeout → NAK
    LD   (HL), A                ; store in buffer
    INC  HL
    ; Accumulate checksum
    LD   D, A
    LD   A, (xm_checksum)
    ADD  A, D
    LD   (xm_checksum), A
    DEC  B
    JP   NZ, xm_recv_data

    ; Read checksum byte from sender
    CALL xm_recv_byte
    JP   C, xm_block_nak
    LD   A, L
    LD   (xm_recv_cksum), A

    ; --- Verify complement ---
    LD   A, (xm_recv_blk)
    LD   D, A
    LD   A, (xm_recv_cpl)
    ADD  A, D
    CP   0xFF
    JP   NZ, xm_block_nak

    ; --- Verify block number ---
    LD   A, (xm_expected_blk)
    LD   D, A
    LD   A, (xm_recv_blk)
    CP   D
    JP   Z, xm_blk_ok
    ; Check for duplicate (previous block resent)
    DEC  D                      ; D = expected - 1
    CP   D
    JP   Z, xm_block_dup
    ; Unexpected block number - NAK
    JP   xm_block_nak

xm_blk_ok:
    ; --- Verify checksum ---
    LD   A, (xm_checksum)
    LD   D, A
    LD   A, (xm_recv_cksum)
    CP   D
    JP   NZ, xm_block_nak

    ; --- Block accepted ---
    ; Advance bufpos by 128
    LD   HL, (xm_bufpos)
    LD   DE, XM_DATA_SIZE
    ADD  HL, DE
    LD   (xm_bufpos), HL

    ; Check if buffer full (512 bytes = H==2, L==0)
    LD   A, H
    CP   2
    JP   NZ, xm_no_flush

    ; Flush full 512-byte block to file
    CALL xm_flush_block
    LD   HL, 0
    LD   (xm_bufpos), HL

xm_no_flush:
    ; Update total byte count (24-bit; 4th byte stays 0 for DEV_BSETSIZE)
    LD   HL, (xm_total)
    LD   DE, XM_DATA_SIZE
    ADD  HL, DE
    LD   (xm_total), HL
    JP   NC, xm_no_carry
    LD   A, (xm_total + 2)
    INC  A
    LD   (xm_total + 2), A
xm_no_carry:

    ; Advance expected block number (wraps at 256)
    LD   A, (xm_expected_blk)
    INC  A
    LD   (xm_expected_blk), A

    ; Reset retry counter
    LD   A, XM_MAX_RETRIES
    LD   (xm_retries), A

    ; Print dot for progress (unless quiet mode)
    LD   A, (xm_quiet)
    OR   A
    JP   NZ, xm_skip_dot
    LD   E, '.'
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
xm_skip_dot:

    ; ACK and wait for next block
    CALL xm_send_ack
    JP   xm_wait_soh

; ------------------------------------------------------------
; Duplicate block - ACK but don't store
; ------------------------------------------------------------
xm_block_dup:
    CALL xm_send_ack
    JP   xm_wait_soh

; ------------------------------------------------------------
; Block error - NAK
; ------------------------------------------------------------
xm_block_nak:
    LD   A, (xm_retries)
    DEC  A
    LD   (xm_retries), A
    JP   Z, xm_too_many_errors
    CALL xm_send_nak
    JP   xm_wait_soh

; ------------------------------------------------------------
; EOT received - transfer complete
; ------------------------------------------------------------
xm_eot:
    ; ACK the EOT
    CALL xm_send_ack

    ; Flush any remaining data in buffer
    LD   HL, (xm_bufpos)
    LD   A, H
    OR   L
    JP   Z, xm_eot_no_flush

    ; Zero-fill remainder of 512-byte block
    LD   DE, xm_buf
    ADD  HL, DE                 ; HL = fill start address
    ; Calculate bytes remaining: 512 - bufpos (16-bit subtraction)
    PUSH HL                     ; save fill pointer
    LD   HL, (xm_bufpos)
    LD   B, H
    LD   C, L
    LD   HL, 512
    LD   A, L
    SUB  C
    LD   C, A
    LD   A, H
    SBC  A, B
    LD   B, A                   ; BC = 512 - bufpos
    POP  HL                     ; restore fill pointer
xm_zero_fill:
    LD   (HL), 0
    INC  HL
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, xm_zero_fill

    ; Write the final block
    CALL xm_flush_block

xm_eot_no_flush:
    ; Set file size to total bytes received
    LD   A, (xm_handle)
    LD   B, A
    LD   DE, xm_total
    LD   C, DEV_BSETSIZE
    CALL KERNELADDR
    OR   A
    JP   NZ, xm_error_setsize

    ; Close the file
    LD   A, (xm_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    OR   A
    JP   NZ, xm_error_finalize

    ; Print success message
    LD   DE, xm_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xm_msg_done
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Print byte count (24-bit)
    LD   HL, (xm_total)
    LD   A, (xm_total + 2)
    LD   E, A
    CALL xm_print_dec24

    LD   DE, xm_msg_bytes
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Helper functions
; ============================================================

; ------------------------------------------------------------
; xm_recv_byte
; Read one byte from serial input with timeout.
; Bypasses kernel — polls UART status port directly via
; trampoline for speed (~80 T-states/poll vs ~500+ via syscall).
; Works with all four NostOS UART types (ACIA, SIO, SCC, Z180).
; Uses xm_seri_rxmask for the RX ready bit (bit 0 or bit 7).
; Outputs:
;   L     - byte read (valid only if carry clear)
;   A     - same as L (valid only if carry clear)
;   Carry - clear on success, set on timeout
; ------------------------------------------------------------
xm_recv_byte:
    PUSH DE
    ; Set up trampoline for status port
    LD   A, (xm_seri_ctrl)
    LD   (TRAMP_IN_THUNK + 1), A
    LD   A, (xm_seri_rxmask)
    LD   E, A                   ; E = RX ready mask
    LD   D, XM_BYTE_TIMEOUT     ; outer loop count
xm_rb_outer:
    LD   HL, 0                  ; inner: 65536 iterations
xm_rb_inner:
    CALL TRAMP_IN_THUNK         ; A = status register
    AND  E                      ; test RX ready bit (bit 0 or bit 7)
    JP   NZ, xm_rb_ready
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, xm_rb_inner
    DEC  D
    JP   NZ, xm_rb_outer
    ; Timeout - no byte arrived
    POP  DE
    SCF                         ; carry = timeout
    RET
xm_rb_ready:
    ; Switch trampoline to data port and read
    LD   A, (xm_seri_data)
    LD   (TRAMP_IN_THUNK + 1), A
    CALL TRAMP_IN_THUNK         ; A = received byte
    LD   L, A
    LD   H, 0
    POP  DE
    OR   A                      ; clear carry = success
    RET

; ------------------------------------------------------------
; xm_send_ack
; Send ACK byte to serial output.
; ------------------------------------------------------------
xm_send_ack:
    LD   A, (xm_sero_id)
    LD   B, A
    LD   E, XM_ACK
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    RET

; ------------------------------------------------------------
; xm_send_nak
; Send NAK byte to serial output.
; ------------------------------------------------------------
xm_send_nak:
    LD   A, (xm_sero_id)
    LD   B, A
    LD   E, XM_NAK
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    RET

; ------------------------------------------------------------
; xm_flush_block
; Write a full 512-byte block to the output file.
; On I/O error: sends CAN, closes file, prints error, and
; exits — does not return to caller.
; ------------------------------------------------------------
xm_flush_block:
    LD   A, (xm_handle)
    LD   B, A
    LD   DE, xm_buf
    LD   C, DEV_BWRITE
    CALL KERNELADDR
    OR   A
    RET  Z                      ; success — return to caller
    ; I/O error — abort transfer
    PUSH AF                     ; save error code
    ; Send CAN to abort sender
    LD   A, (xm_sero_id)
    LD   B, A
    LD   E, XM_CAN
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    ; Close file
    LD   A, (xm_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    ; Print error
    LD   DE, xm_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xm_msg_ioerr
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  AF
    LD   L, A
    LD   H, 0
    LD   E, 0
    CALL xm_print_dec24
    LD   DE, xm_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Error handlers
; ============================================================
xm_timeout:
    ; Close file and report timeout
    LD   A, (xm_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, xm_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xm_msg_timeout
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xm_cancelled:
    ; Sender cancelled
    LD   A, (xm_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, xm_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xm_msg_cancel
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xm_too_many_errors:
    ; Too many retries
    ; Send CAN to abort sender
    LD   A, (xm_sero_id)
    LD   B, A
    LD   E, XM_CAN
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    ; Close file
    LD   A, (xm_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, xm_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xm_msg_toomany
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xm_error:
    PUSH AF
    LD   DE, xm_msg_error
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  AF
    LD   L, A
    LD   H, 0
    LD   E, 0
    CALL xm_print_dec24
    LD   DE, xm_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xm_error_setsize:
    ; BSETSIZE failed — close file first, then report
    PUSH AF
    LD   A, (xm_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    POP  AF
    ; Fall through to xm_error_finalize

xm_error_finalize:
    ; Finalization failed (BSETSIZE or CLOSE) — report error code and exit
    PUSH AF
    LD   DE, xm_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xm_msg_finerr
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  AF
    LD   L, A
    LD   H, 0
    LD   E, 0
    CALL xm_print_dec24
    LD   DE, xm_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xm_error_noseri:
    LD   DE, xm_msg_noseri
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xm_error_nosero:
    LD   DE, xm_msg_nosero
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xm_usage:
    LD   DE, xm_msg_usage
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; xm_print_dec24 - Print E:HL as unsigned 24-bit decimal
; Inputs:
;   E  - high byte (bits 16-23)
;   HL - low 16 bits (bits 0-15)
; ============================================================
xm_print_dec24:
    PUSH HL
    PUSH DE
    PUSH BC
    LD   C, E                   ; C:HL = 24-bit value
    LD   B, 0                   ; B = digit count on stack
xm_pd_divloop:
    PUSH BC                     ; save digit count
    LD   D, 0                   ; D = remainder
    LD   B, 24                  ; 24 bit iterations
xm_pd_div10:
    ADD  HL, HL                 ; shift C:HL left by 1
    LD   A, C
    RLA
    LD   C, A
    LD   A, D                   ; shift carry into remainder
    RLA
    SUB  10                     ; remainder >= 10?
    JP   C, xm_pd_skip
    LD   D, A                   ; yes: keep subtracted value
    INC  L                      ; set bit 0 of quotient
    JP   xm_pd_cont
xm_pd_skip:
    ADD  A, 10                  ; no: restore remainder
    LD   D, A
xm_pd_cont:
    DEC  B
    JP   NZ, xm_pd_div10
    POP  BC                     ; restore digit count
    LD   A, D                   ; remainder = digit
    ADD  A, '0'
    PUSH AF                     ; push digit char
    INC  B                      ; digit count++
    LD   A, H                   ; check if quotient is zero
    OR   L
    OR   C
    JP   NZ, xm_pd_divloop
xm_pd_print:
    POP  AF
    PUSH BC
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    DEC  B
    JP   NZ, xm_pd_print
    POP  BC
    POP  DE
    POP  HL
    RET

; ============================================================
; Variables
; ============================================================
xm_fname:       DEFW 0          ; pointer to filename in input buffer
xm_handle:      DEFB 0          ; file handle (device ID)
xm_seri_id:     DEFB 0          ; resolved physical device ID for SERI
xm_seri_ctrl:   DEFB 0          ; SERI UART status/control port number
xm_seri_data:   DEFB 0          ; SERI UART data port number
xm_seri_rxmask: DEFB 0          ; RX ready bit mask (0x01=ACIA/SIO/SCC, 0x80=Z180)
xm_sero_id:     DEFB 0          ; resolved physical device ID for SERO
xm_quiet:       DEFB 0          ; 1 = quiet mode (SERO == CONO, suppress dots)
xm_expected_blk: DEFB 0         ; expected XMODEM block number (1-255, wraps)
xm_retries:     DEFB 0          ; remaining retries
xm_tmr_outer:   DEFB 0          ; timeout outer loop counter
xm_recv_blk:    DEFB 0          ; received block number
xm_recv_cpl:    DEFB 0          ; received complement
xm_recv_cksum:  DEFB 0          ; received checksum
xm_checksum:    DEFB 0          ; computed checksum accumulator
xm_bufpos:      DEFW 0          ; current position in write buffer (0-511)
xm_total:       DEFS 4, 0       ; total bytes received (4 bytes, for DEV_BSETSIZE)

; ============================================================
; String data
; ============================================================
xm_msg_header:  DEFM "XRECV: XMODEM Receive", 0x0D, 0x0A, 0
xm_msg_waiting: DEFM "Waiting for sender...", 0x0D, 0x0A, 0
xm_msg_done:    DEFM "Transfer complete: ", 0
xm_msg_bytes:   DEFM " bytes received.", 0x0D, 0x0A, 0
xm_msg_timeout: DEFM "Error: transfer timed out.", 0x0D, 0x0A, 0
xm_msg_cancel:  DEFM "Error: transfer cancelled by sender.", 0x0D, 0x0A, 0
xm_msg_toomany: DEFM "Error: too many retries.", 0x0D, 0x0A, 0
xm_msg_ioerr:   DEFM "Error: disk write failed, code ", 0
xm_msg_finerr:  DEFM "Error: file finalize failed, code ", 0
xm_msg_error:   DEFM "Error: ", 0
xm_msg_noseri:  DEFM "Error: SERI not assigned to a serial device.", 0x0D, 0x0A
                DEFM "Use AS SERI <device> first.", 0x0D, 0x0A, 0
xm_msg_nosero:  DEFM "Error: SERO not assigned to a serial device.", 0x0D, 0x0A
                DEFM "Use AS SERO <device> first.", 0x0D, 0x0A, 0
xm_msg_usage:   DEFM "Usage: XRECV <filename>", 0x0D, 0x0A, 0
xm_msg_crlf:    DEFM 0x0D, 0x0A, 0

; ============================================================
; I/O buffer (512 bytes) - must be last
; ============================================================
xm_buf:         DEFS 512, 0

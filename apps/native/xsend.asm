; ============================================================
; xsend.asm - XMODEM Send: send a file via XMODEM protocol
; ============================================================
; Usage: XSEND <filename>
;
; Sends a file over the SERI/SERO serial port using the
; XMODEM protocol (auto-detects checksum or CRC mode based
; on receiver's initial byte). The filename may include a
; device prefix and/or subdirectory path.
;
; Algorithm:
;   1. Parse and upcase filename
;   2. Resolve SERI to physical ID (direct port I/O for ACK/NAK)
;   3. Resolve SERO to physical ID (kernel DEV_CWRITE for sends)
;   4. Open input file (SYS_GLOBAL_OPENFILE)
;   5. Get file size (DEV_BGETSIZE), compute XMODEM block count
;   6. Wait for initial NAK from receiver
;   7. Read 512-byte disk blocks; send as 4x 128-byte XMODEM blocks
;   8. Pad last block with 0x1A (CP/M EOF)
;   9. Send EOT, wait for ACK, close, report
;
; Direct port I/O is used only for receiving ACK/NAK (timeout
; required). All sends use kernel DEV_CWRITE — send performance
; is not critical since the receiver controls pacing.
;
; Quiet mode:
;   When SERO and CONO resolve to the same physical device,
;   progress dots are suppressed to avoid injecting bytes into
;   the serial stream.
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point - jump over header
    JP   xs_main

    ; Header pad: 13 bytes (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; XMODEM protocol constants
; ============================================================
XS_SOH          EQU 0x01       ; Start of Header
XS_EOT          EQU 0x04       ; End of Transmission
XS_ACK          EQU 0x06       ; Acknowledge
XS_NAK          EQU 0x15       ; Negative Acknowledge
XS_CAN          EQU 0x18       ; Cancel
XS_CRC_INIT     EQU 0x43       ; 'C' — CRC mode request from receiver

XS_MAX_RETRIES  EQU 10         ; max retries per block before abort
XS_INIT_RETRIES EQU 60         ; retries waiting for receiver (~5 min)
XS_DATA_SIZE    EQU 128        ; bytes per XMODEM block
XS_TIMEOUT_OUT  EQU 10         ; outer timeout loop count (~5 sec)
; Inner timeout loop = 65536 iterations (16-bit wrap)

; ============================================================
; Entry point
; ============================================================
xs_main:
    ; --- Parse filename from command line ---
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, xs_usage

    ; Save filename pointer
    LD   (xs_fname), HL

    ; Upcase filename in-place
xs_upcase:
    LD   A, (HL)
    OR   A
    JP   Z, xs_upcase_done
    CP   ' '
    JP   Z, xs_upcase_done
    CP   'a'
    JP   C, xs_upcase_store
    CP   'z' + 1
    JP   NC, xs_upcase_store
    AND  0x5F                   ; make uppercase
xs_upcase_store:
    LD   (HL), A
    INC  HL
    JP   xs_upcase
xs_upcase_done:
    LD   (HL), 0                ; null-terminate

    ; --- Print header ---
    LD   DE, xs_msg_header
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; --- Resolve SERI logical device to physical ID ---
    ; Needed for direct port I/O when receiving ACK/NAK with timeout
    LD   B, LOGDEV_ID_SERI
    LD   C, DEV_LOG_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, xs_error_noseri
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = PDT entry pointer
    LD   A, D
    OR   E
    JP   Z, xs_error_noseri
    ; Read physical device ID
    LD   HL, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   A, (HL)
    LD   (xs_seri_id), A

    ; Set up direct port I/O parameters based on device type
    CP   PHYSDEV_ID_Z180A
    JP   Z, xs_seri_z180
    CP   PHYSDEV_ID_Z180B
    JP   Z, xs_seri_z180

    ; ACIA / SIO / SCC path
    LD   HL, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   A, (HL)
    LD   (xs_seri_ctrl), A
    INC  HL
    LD   A, (HL)
    LD   (xs_seri_data), A
    LD   A, 0x01                ; RX ready = bit 0
    LD   (xs_seri_rxmask), A
    JP   xs_seri_done

xs_seri_z180:
    ; Z180 ASCI: channel number in PDT user data byte 0
    LD   HL, PHYSDEV_OFF_DATA
    ADD  HL, DE
    LD   A, (HL)                ; A = channel (0 or 1)
    LD   C, A
    ADD  A, Z180_STAT0
    LD   (xs_seri_ctrl), A
    LD   A, C
    ADD  A, Z180_RDR0
    LD   (xs_seri_data), A
    LD   A, Z180_RDRF           ; RX ready = bit 7 (0x80)
    LD   (xs_seri_rxmask), A

xs_seri_done:
    ; Verify DEVCAP_CHAR_IN
    LD   HL, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  DEVCAP_CHAR_IN
    JP   Z, xs_error_noseri

    ; --- Resolve SERO logical device to physical ID ---
    LD   B, LOGDEV_ID_SERO
    LD   C, DEV_LOG_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, xs_error_nosero
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    LD   A, D
    OR   E
    JP   Z, xs_error_nosero
    LD   HL, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   A, (HL)
    LD   (xs_sero_id), A
    ; Verify DEVCAP_CHAR_OUT
    LD   HL, PHYSDEV_OFF_CAPS
    ADD  HL, DE
    LD   A, (HL)
    AND  DEVCAP_CHAR_OUT
    JP   Z, xs_error_nosero

    ; --- Detect quiet mode: if SERO == CONO, suppress progress dots ---
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_LOG_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, xs_quiet_off
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    LD   A, D
    OR   E
    JP   Z, xs_quiet_off
    LD   HL, PHYSDEV_OFF_ID
    ADD  HL, DE
    LD   A, (HL)
    LD   D, A
    LD   A, (xs_sero_id)
    CP   D
    JP   NZ, xs_quiet_off
    LD   A, 1
    LD   (xs_quiet), A
    JP   xs_quiet_done
xs_quiet_off:
    XOR  A
    LD   (xs_quiet), A
xs_quiet_done:

    ; --- Open input file ---
    LD   DE, (xs_fname)
    LD   C, SYS_GLOBAL_OPENFILE
    CALL KERNELADDR
    OR   A
    JP   NZ, xs_error
    LD   A, L
    LD   (xs_handle), A

    ; --- Get file size ---
    LD   B, L
    LD   DE, xs_filesize
    LD   C, DEV_BGETSIZE
    CALL KERNELADDR
    OR   A
    JP   NZ, xs_error_close

    ; --- Compute XMODEM block count = ceil(filesize / 128) ---
    ; DEV_BGETSIZE writes 4 bytes LE; only the low 3 are used here
    ; (max file size is 16MB). Result is 16 bits.
    ; ceil(n/128) = (n + 127) >> 7
    LD   HL, (xs_filesize)      ; HL = filesize[0:1]
    LD   A, (xs_filesize + 2)
    LD   C, A                   ; C:HL = filesize (24 bits)
    LD   A, L
    ADD  A, 127
    LD   L, A
    LD   A, H
    ADC  A, 0
    LD   H, A
    LD   A, C
    ADC  A, 0
    LD   C, A                   ; C:HL = filesize + 127
    ; Shift right 7: result_lo = (H << 1) | (L >> 7), result_hi = (C << 1) | (H >> 7)
    LD   A, L
    RLA                         ; carry = L bit 7
    LD   A, H
    RLA                         ; A = (H << 1) | (L >> 7), carry = H bit 7
    LD   L, A
    LD   A, C
    RLA                         ; A = (C << 1) | (H >> 7)
    LD   H, A                  ; HL = ceil(filesize / 128)
    LD   (xs_total_blks), HL

    ; Reject empty files
    LD   A, H
    OR   L
    JP   Z, xs_error_empty

    ; --- Print waiting message (unless quiet) ---
    LD   A, (xs_quiet)
    OR   A
    JP   NZ, xs_init_state
    LD   DE, xs_msg_waiting
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
xs_init_state:

    ; --- Initialize state ---
    LD   A, 1
    LD   (xs_blk_num), A
    XOR  A
    LD   (xs_sub_blk), A
    LD   A, XS_INIT_RETRIES
    LD   (xs_retries), A

; ============================================================
; Wait for initial NAK from receiver
; ============================================================
xs_wait_nak:
    CALL xs_recv_byte
    JP   C, xs_wait_nak_timeout
    CP   XS_NAK
    JP   Z, xs_start_checksum
    CP   XS_CRC_INIT
    JP   Z, xs_start_crc
    CP   XS_CAN
    JP   Z, xs_cancelled
    ; Ignore other bytes
    JP   xs_wait_nak

xs_start_crc:
    LD   A, 1
    LD   (xs_crc_mode), A
    JP   xs_drain_rx

xs_start_checksum:
    XOR  A
    LD   (xs_crc_mode), A
    JP   xs_drain_rx

; ------------------------------------------------------------
; xs_drain_rx
; Drain any stale bytes from the SERI receive buffer before
; starting the transfer.  The receiver may have sent multiple
; 'C' or NAK bytes while the user was starting xsend; if these
; remain buffered, xs_wait_ack would read them instead of the
; real ACK, causing spurious retries and sender/receiver desync.
; Uses a short timeout (~0.67 sec) per poll.
; ------------------------------------------------------------
xs_drain_rx:
    LD   A, (xs_seri_ctrl)
    LD   (TRAMP_IN_THUNK + 1), A
    LD   A, (xs_seri_rxmask)
    LD   E, A
xs_drain_poll:
    LD   HL, 0                  ; inner: 65536 iterations (~0.67 sec)
xs_drain_inner:
    CALL TRAMP_IN_THUNK
    AND  E
    JP   NZ, xs_drain_consume
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, xs_drain_inner
    ; Timeout — buffer is empty, proceed to send
    JP   xs_start_send

xs_drain_consume:
    ; Read and discard the byte, then restart poll
    LD   A, (xs_seri_data)
    LD   (TRAMP_IN_THUNK + 1), A
    CALL TRAMP_IN_THUNK
    LD   A, (xs_seri_ctrl)
    LD   (TRAMP_IN_THUNK + 1), A
    JP   xs_drain_poll

xs_wait_nak_timeout:
    LD   A, (xs_retries)
    DEC  A
    LD   (xs_retries), A
    JP   Z, xs_timeout
    JP   xs_wait_nak

; ============================================================
; Main send loop
; ============================================================
xs_start_send:
    LD   A, XS_MAX_RETRIES
    LD   (xs_retries), A

xs_send_loop:
    ; All blocks sent?
    LD   HL, (xs_total_blks)
    LD   A, H
    OR   L
    JP   Z, xs_send_eot

    ; Read next 512-byte disk block when sub_blk == 0
    LD   A, (xs_sub_blk)
    OR   A
    JP   NZ, xs_send_block

    LD   A, (xs_handle)
    LD   B, A
    LD   DE, xs_buf
    LD   C, DEV_BREAD
    CALL KERNELADDR
    OR   A
    JP   NZ, xs_error_read

; ------------------------------------------------------------
; Send one XMODEM block (also retry entry point)
; ------------------------------------------------------------
xs_send_block:
    ; Compute data pointer: xs_buf + sub_blk * 128
    LD   A, (xs_sub_blk)
    OR   A                      ; clear carry
    RRA                         ; A = sub_blk >> 1, carry = bit 0
    LD   H, A
    LD   A, 0
    RRA                         ; A = (sub_blk & 1) << 7
    LD   L, A
    LD   DE, xs_buf
    ADD  HL, DE                 ; HL = pointer to 128-byte block
    LD   (xs_data_ptr), HL

    ; Pad last XMODEM block with 0x1A if file doesn't end on 128-byte boundary
    LD   DE, (xs_total_blks)
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, xs_send_frame      ; not last block, skip padding

    ; Last block: check if padding needed
    LD   A, (xs_filesize)
    AND  0x7F                   ; filesize mod 128
    JP   Z, xs_send_frame       ; exact multiple, no padding

    ; Pad from offset A to 128 with 0x1A
    LD   HL, (xs_data_ptr)
    LD   E, A
    LD   D, 0
    ADD  HL, DE                 ; HL = start of padding
    LD   C, A
    LD   A, XS_DATA_SIZE
    SUB  C
    LD   B, A                   ; B = bytes to pad
xs_pad_loop:
    LD   (HL), 0x1A
    INC  HL
    DEC  B
    JP   NZ, xs_pad_loop

xs_send_frame:
    ; --- SOH ---
    LD   E, XS_SOH
    CALL xs_send_byte

    ; --- Block number ---
    LD   A, (xs_blk_num)
    LD   E, A
    CALL xs_send_byte

    ; --- Complement ---
    LD   A, (xs_blk_num)
    CPL
    LD   E, A
    CALL xs_send_byte

    ; --- 128 data bytes + compute checksum/CRC ---
    XOR  A
    LD   (xs_checksum), A
    LD   (xs_crc_val), A
    LD   (xs_crc_val + 1), A    ; CRC = 0x0000
    LD   HL, (xs_data_ptr)
    LD   B, XS_DATA_SIZE
xs_send_data:
    LD   A, (HL)
    LD   D, A                   ; save for checksum/CRC
    LD   E, A
    PUSH BC
    PUSH HL
    CALL xs_send_byte
    POP  HL
    POP  BC
    ; Update checksum
    LD   A, (xs_checksum)
    ADD  A, D
    LD   (xs_checksum), A
    ; Update CRC if in CRC mode
    LD   A, (xs_crc_mode)
    OR   A
    JP   Z, xs_send_data_next
    PUSH BC
    PUSH HL
    LD   HL, (xs_crc_val)
    LD   A, D
    CALL xs_crc_update
    LD   (xs_crc_val), HL
    POP  HL
    POP  BC
xs_send_data_next:
    INC  HL
    DEC  B
    JP   NZ, xs_send_data

    ; --- Send checksum or CRC ---
    LD   A, (xs_crc_mode)
    OR   A
    JP   NZ, xs_send_crc
    ; Checksum mode: send 1 byte
    LD   A, (xs_checksum)
    LD   E, A
    CALL xs_send_byte
    JP   xs_wait_ack
xs_send_crc:
    ; CRC mode: send 2 bytes, high first
    LD   A, (xs_crc_val + 1)   ; CRC high byte
    LD   E, A
    CALL xs_send_byte
    LD   A, (xs_crc_val)       ; CRC low byte
    LD   E, A
    CALL xs_send_byte

    ; --- Wait for ACK/NAK ---
xs_wait_ack:
    CALL xs_recv_byte
    JP   C, xs_ack_retry
    CP   XS_ACK
    JP   Z, xs_block_acked
    CP   XS_CAN
    JP   Z, xs_cancelled
    ; NAK or unexpected byte — retry
    JP   xs_ack_retry

xs_block_acked:
    ; Advance block number (wraps at 256)
    LD   A, (xs_blk_num)
    INC  A
    LD   (xs_blk_num), A

    ; Advance sub-block within 512-byte buffer (wraps 4 → 0)
    LD   A, (xs_sub_blk)
    INC  A
    AND  0x03
    LD   (xs_sub_blk), A

    ; Decrement remaining blocks
    LD   HL, (xs_total_blks)
    DEC  HL
    LD   (xs_total_blks), HL

    ; Reset retries
    LD   A, XS_MAX_RETRIES
    LD   (xs_retries), A

    ; Progress dot (unless quiet mode)
    LD   A, (xs_quiet)
    OR   A
    JP   NZ, xs_send_loop
    LD   E, '.'
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    JP   xs_send_loop

xs_ack_retry:
    LD   A, (xs_retries)
    DEC  A
    LD   (xs_retries), A
    JP   Z, xs_too_many_errors
    JP   xs_send_block          ; resend same block (no disk re-read)

; ============================================================
; EOT - all data sent
; ============================================================
xs_send_eot:
    LD   E, XS_EOT
    CALL xs_send_byte

    ; Wait for ACK
    CALL xs_recv_byte
    JP   C, xs_eot_retry
    CP   XS_ACK
    JP   Z, xs_done
    ; Not ACK — retry
xs_eot_retry:
    LD   A, (xs_retries)
    DEC  A
    LD   (xs_retries), A
    JP   Z, xs_timeout
    JP   xs_send_eot

; ============================================================
; Transfer complete
; ============================================================
xs_done:
    ; Close file
    LD   A, (xs_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR

    ; Print success
    LD   DE, xs_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xs_msg_done
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Print file size (24-bit decimal)
    LD   HL, (xs_filesize)
    LD   A, (xs_filesize + 2)
    LD   E, A
    CALL xs_print_dec24

    LD   DE, xs_msg_bytes
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Helper functions
; ============================================================

; ------------------------------------------------------------
; xs_recv_byte
; Read one byte from serial input with timeout.
; Uses direct port I/O via trampoline (same as xrecv).
; Outputs:
;   A     - byte read (valid only if carry clear)
;   Carry - clear on success, set on timeout
; ------------------------------------------------------------
xs_recv_byte:
    PUSH DE
    PUSH HL

    ; Z180 ASCI: clear any pending errors before polling
    LD   A, (xs_seri_rxmask)
    CP   Z180_RDRF              ; 0x80 = Z180?
    JP   NZ, xs_rb_poll
    LD   A, (xs_seri_ctrl)
    LD   (TRAMP_IN_THUNK + 1), A
    CALL TRAMP_IN_THUNK         ; A = STAT
    AND  0x70                   ; PE | FE | OVRN
    JP   Z, xs_rb_poll
    ; Clear errors: CNTLA port = STAT port - 4 (STAT is CNTLA + 4)
    LD   A, (xs_seri_ctrl)
    SUB  Z180_STAT0 - Z180_CNTLA0
    LD   (TRAMP_IN_THUNK + 1), A
    LD   (TRAMP_OUT_THUNK + 1), A
    CALL TRAMP_IN_THUNK         ; A = CNTLA value
    AND  0xF7                   ; clear EFR (bit 3)
    CALL TRAMP_OUT_THUNK

xs_rb_poll:
    ; Set up trampoline for status port
    LD   A, (xs_seri_ctrl)
    LD   (TRAMP_IN_THUNK + 1), A
    LD   A, XS_TIMEOUT_OUT
    LD   D, A                   ; D = outer loop count
    LD   A, (xs_seri_rxmask)
    LD   E, A                   ; E = RX ready mask
xs_rb_outer:
    LD   HL, 0                  ; inner: 65536 iterations
xs_rb_inner:
    CALL TRAMP_IN_THUNK         ; A = status register
    AND  E
    JP   NZ, xs_rb_ready
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, xs_rb_inner
    DEC  D
    JP   NZ, xs_rb_outer
    ; Timeout
    POP  HL
    POP  DE
    SCF                         ; carry = timeout
    RET
xs_rb_ready:
    ; Read data byte
    LD   A, (xs_seri_data)
    LD   (TRAMP_IN_THUNK + 1), A
    CALL TRAMP_IN_THUNK         ; A = received byte
    POP  HL
    POP  DE
    OR   A                      ; clear carry = success, A preserved
    RET

; ------------------------------------------------------------
; xs_send_byte
; Send one byte to serial output via kernel.
; Inputs:
;   E - byte to send
; ------------------------------------------------------------
xs_send_byte:
    LD   A, (xs_sero_id)
    LD   B, A
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    RET

; ------------------------------------------------------------
; xs_crc_update
; Update CRC-16/CCITT (polynomial 0x1021) with one byte.
; Inputs:
;   A  - data byte
;   HL - current CRC value
; Outputs:
;   HL - updated CRC value
; Preserves: DE
; ------------------------------------------------------------
xs_crc_update:
    XOR  H              ; A = byte ^ CRC_hi
    LD   H, A
    LD   B, 8
xs_crc_bit:
    ADD  HL, HL         ; CRC <<= 1, carry = old bit 15
    JP   NC, xs_crc_skip
    LD   A, H
    XOR  0x10           ; high byte of 0x1021
    LD   H, A
    LD   A, L
    XOR  0x21           ; low byte of 0x1021
    LD   L, A
xs_crc_skip:
    DEC  B
    JP   NZ, xs_crc_bit
    RET

; ------------------------------------------------------------
; xs_print_dec24 - Print E:HL as unsigned 24-bit decimal
; Inputs:
;   E  - high byte (bits 16-23)
;   HL - low 16 bits (bits 0-15)
; ------------------------------------------------------------
xs_print_dec24:
    PUSH HL
    PUSH DE
    PUSH BC
    LD   C, E                   ; C:HL = 24-bit value
    LD   B, 0                   ; B = digit count on stack
xs_pd_divloop:
    PUSH BC                     ; save digit count
    LD   D, 0                   ; D = remainder
    LD   B, 24                  ; 24 bit iterations
xs_pd_div10:
    ADD  HL, HL                 ; shift C:HL left by 1
    LD   A, C
    RLA
    LD   C, A
    LD   A, D                   ; shift carry into remainder
    RLA
    SUB  10                     ; remainder >= 10?
    JP   C, xs_pd_skip
    LD   D, A                   ; yes: keep subtracted value
    INC  L                      ; set bit 0 of quotient
    JP   xs_pd_cont
xs_pd_skip:
    ADD  A, 10                  ; no: restore remainder
    LD   D, A
xs_pd_cont:
    DEC  B
    JP   NZ, xs_pd_div10
    POP  BC                     ; restore digit count
    LD   A, D                   ; remainder = digit
    ADD  A, '0'
    PUSH AF                     ; push digit char
    INC  B                      ; digit count++
    LD   A, H                   ; check if quotient is zero
    OR   L
    OR   C
    JP   NZ, xs_pd_divloop
xs_pd_print:
    POP  AF
    PUSH BC
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    DEC  B
    JP   NZ, xs_pd_print
    POP  BC
    POP  DE
    POP  HL
    RET

; ============================================================
; Error handlers
; ============================================================
xs_timeout:
    LD   A, (xs_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, xs_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xs_msg_timeout
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xs_cancelled:
    LD   A, (xs_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, xs_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xs_msg_cancel
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xs_too_many_errors:
    ; Send CAN to abort receiver
    LD   E, XS_CAN
    CALL xs_send_byte
    ; Close file
    LD   A, (xs_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, xs_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xs_msg_toomany
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xs_error_read:
    ; Disk read error during transfer — send CAN and abort
    PUSH AF                     ; save error code
    LD   E, XS_CAN
    CALL xs_send_byte
    LD   A, (xs_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, xs_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   DE, xs_msg_ioerr
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  AF
    LD   L, A
    LD   H, 0
    LD   E, 0
    CALL xs_print_dec24
    LD   DE, xs_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xs_error_close:
    ; Error after file was opened — close first
    PUSH AF
    LD   A, (xs_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    POP  AF
    ; Fall through to xs_error

xs_error:
    PUSH AF
    LD   DE, xs_msg_error
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  AF
    LD   L, A
    LD   H, 0
    LD   E, 0
    CALL xs_print_dec24
    LD   DE, xs_msg_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xs_error_empty:
    LD   A, (xs_handle)
    LD   B, A
    LD   C, DEV_CLOSE
    CALL KERNELADDR
    LD   DE, xs_msg_empty
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xs_error_noseri:
    LD   DE, xs_msg_noseri
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xs_error_nosero:
    LD   DE, xs_msg_nosero
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

xs_usage:
    LD   DE, xs_msg_usage
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Variables
; ============================================================
xs_fname:       DEFW 0          ; pointer to filename in input buffer
xs_handle:      DEFB 0          ; file handle (device ID)
xs_seri_id:     DEFB 0          ; SERI physical device ID
xs_seri_ctrl:   DEFB 0          ; SERI UART status/control port
xs_seri_data:   DEFB 0          ; SERI UART data port
xs_seri_rxmask: DEFB 0          ; RX ready bit mask (0x01 or 0x80)
xs_sero_id:     DEFB 0          ; SERO physical device ID
xs_quiet:       DEFB 0          ; 1 = quiet mode
xs_blk_num:     DEFB 0          ; current XMODEM block number (1-255, wraps)
xs_sub_blk:     DEFB 0          ; sub-block within 512-byte buffer (0-3)
xs_retries:     DEFB 0          ; remaining retries
xs_checksum:    DEFB 0          ; computed checksum accumulator
xs_crc_mode:    DEFB 0          ; 0 = checksum mode, 1 = CRC mode
xs_crc_val:     DEFW 0          ; CRC-16 accumulator (LE: low, high)
xs_total_blks:  DEFW 0          ; remaining XMODEM blocks to send
xs_data_ptr:    DEFW 0          ; pointer to current 128-byte block in buffer
xs_filesize:    DEFS 4, 0       ; file size from DEV_BGETSIZE (4 bytes LE)

; ============================================================
; String data
; ============================================================
xs_msg_header:  DEFM "XSEND: XMODEM Send", 0x0D, 0x0A, 0
xs_msg_waiting: DEFM "Waiting for receiver...", 0x0D, 0x0A, 0
xs_msg_done:    DEFM "Transfer complete: ", 0
xs_msg_bytes:   DEFM " bytes sent.", 0x0D, 0x0A, 0
xs_msg_timeout: DEFM "Error: transfer timed out.", 0x0D, 0x0A, 0
xs_msg_cancel:  DEFM "Error: transfer cancelled by receiver.", 0x0D, 0x0A, 0
xs_msg_toomany: DEFM "Error: too many retries.", 0x0D, 0x0A, 0
xs_msg_ioerr:   DEFM "Error: disk read failed, code ", 0
xs_msg_empty:   DEFM "Error: file is empty.", 0x0D, 0x0A, 0
xs_msg_error:   DEFM "Error: ", 0
xs_msg_noseri:  DEFM "Error: SERI not assigned to a serial device.", 0x0D, 0x0A
                DEFM "Use AS SERI <device> first.", 0x0D, 0x0A, 0
xs_msg_nosero:  DEFM "Error: SERO not assigned to a serial device.", 0x0D, 0x0A
                DEFM "Use AS SERO <device> first.", 0x0D, 0x0A, 0
xs_msg_usage:   DEFM "Usage: XSEND <filename>", 0x0D, 0x0A, 0
xs_msg_crlf:    DEFM 0x0D, 0x0A, 0

; ============================================================
; I/O buffer (512 bytes) - must be last
; ============================================================
xs_buf:         DEFS 512, 0

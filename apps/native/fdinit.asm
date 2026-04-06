; ============================================================
; fdinit.asm - Floppy Disk Low-Level Format for NostOS
; ============================================================
; Usage: FDINIT <device:>
;   device - FDC physical device name (e.g., FD or FD:)
;
; Reads geometry from PDT user data, confirms with user,
; then low-level formats all tracks on the floppy disk.
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    JP   fdf_main
    DEFS 13, 0

; Local constants
FDF_CMD_FORMAT  EQU 0x4D       ; Format Track (MF=1, MFM mode)
FDF_FILL_BYTE   EQU 0xE5       ; Sector fill byte

; ============================================================
; fdf_main - entry point
; ============================================================
fdf_main:
    ; --- Parse device name from command line ---
    LD   HL, (EXEC_ARGS_PTR)
    LD   DE, fdf_dev_name
    LD   B, 8                   ; safety limit
fdf_copy_dev:
    LD   A, (HL)
    OR   A
    JP   Z, fdf_copy_done
    CP   ' '
    JP   Z, fdf_copy_done
    CP   ':'
    JP   Z, fdf_had_colon
    LD   (DE), A
    INC  DE
    INC  HL
    DEC  B
    JP   NZ, fdf_copy_dev
    JP   fdf_err_usage
fdf_had_colon:
    INC  HL
fdf_copy_done:
    LD   A, 0
    LD   (DE), A                ; null-terminate

    ; Verify we got a name
    LD   A, (fdf_dev_name)
    OR   A
    JP   Z, fdf_err_usage

    ; --- Lookup device ---
    LD   DE, fdf_dev_name
    LD   B, 0
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, fdf_err_dev
    LD   A, L
    AND  0x80
    JP   NZ, fdf_err_dev        ; logical device, need physical
    LD   A, L
    LD   (fdf_dev_id), A

    ; --- Get PDT entry ---
    LD   B, A
    LD   C, DEV_PHYS_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, fdf_err_dev

    ; HL = PDT entry pointer
    ; Read FDC geometry from user data
    LD   DE, PHYSDEV_OFF_DATA + FDC_OFF_DRIVE
    ADD  HL, DE
    LD   A, (HL)                ; drive
    LD   (fdf_drive), A
    INC  HL
    LD   A, (HL)                ; SPT
    LD   (fdf_spt), A
    INC  HL
    LD   A, (HL)                ; heads
    LD   (fdf_heads), A
    INC  HL
    LD   A, (HL)                ; secsize code
    LD   (fdf_secsize), A
    INC  HL
    LD   A, (HL)                ; cylinders
    LD   (fdf_cylinders), A
    INC  HL
    INC  HL                     ; skip read/write GPL
    LD   A, (HL)                ; datarate
    LD   (fdf_datarate), A

    ; Determine format GPL based on SPT
    LD   A, (fdf_spt)
    CP   18
    JP   Z, fdf_gpl_hd
    LD   A, 0x50                ; DD format gap (9 SPT)
    JP   fdf_gpl_set
fdf_gpl_hd:
    LD   A, 0x54                ; HD format gap (18 SPT)
fdf_gpl_set:
    LD   (fdf_format_gpl), A

    ; --- Display geometry and confirm ---
    LD   DE, msg_header
    CALL fdf_puts
    LD   DE, fdf_dev_name
    CALL fdf_puts
    LD   DE, msg_space
    CALL fdf_puts
    LD   A, (fdf_cylinders)
    CALL fdf_print_a_dec
    LD   DE, msg_cyl
    CALL fdf_puts
    LD   A, (fdf_heads)
    CALL fdf_print_a_dec
    LD   DE, msg_heads
    CALL fdf_puts
    LD   A, (fdf_spt)
    CALL fdf_print_a_dec
    LD   DE, msg_spt
    CALL fdf_puts
    LD   DE, msg_confirm
    CALL fdf_puts

    ; Wait for keypress
    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    LD   A, L
    CP   'Y'
    JP   Z, fdf_confirmed
    CP   'y'
    JP   Z, fdf_confirmed
    LD   DE, msg_cancelled
    CALL fdf_puts
    JP   fdf_exit

fdf_confirmed:
    LD   DE, msg_crlf
    CALL fdf_puts

    ; --- Reset and initialize FDC ---
    ; Assert /RESET (clear bit 2 of DOR)
    XOR  A
    OUT  (FDC_PORT_DOR), A
    ; Brief reset pulse delay
    LD   B, 0
fdf_reset_delay:
    DEC  B
    JP   NZ, fdf_reset_delay

    ; Release reset with motor on
    CALL fdf_motor_on

    ; Post-reset settle (~2.4ms)
    LD   A, 5
fdf_settle_outer:
    LD   B, 0
fdf_settle_inner:
    DEC  B
    JP   NZ, fdf_settle_inner
    DEC  A
    JP   NZ, fdf_settle_outer

    ; Drain pending interrupts from reset
fdf_drain_ints:
    CALL fdf_sense_int
    JP   C, fdf_drain_done      ; timeout = no more
    AND  0xC0
    CP   0xC0                   ; IC=11 = no interrupt pending
    JP   NZ, fdf_drain_ints     ; real interrupt consumed, check more
fdf_drain_done:

    ; Drain any pending data bytes
    LD   B, 0
fdf_drain_data:
    IN   A, (FDC_PORT_MSR)
    AND  FDC_MSR_RQM | FDC_MSR_DIO
    CP   FDC_MSR_RQM | FDC_MSR_DIO
    JP   NZ, fdf_drain_data_done
    IN   A, (FDC_PORT_DATA)
    DEC  B
    JP   NZ, fdf_drain_data
fdf_drain_data_done:

    ; Set data rate
    LD   A, (fdf_datarate)
    OUT  (FDC_PORT_DCR), A

    ; Send SPECIFY
    LD   A, FDC_CMD_SPECIFY
    CALL fdf_send_byte
    JP   C, fdf_err_io
    LD   A, FDC_SPECIFY_BYTE1
    CALL fdf_send_byte
    JP   C, fdf_err_io
    LD   A, FDC_SPECIFY_BYTE2
    CALL fdf_send_byte
    JP   C, fdf_err_io

    ; Double recalibrate (per kernel convention for 80-track drives)
    CALL fdf_recalibrate
    JP   C, fdf_err_io
    CALL fdf_recalibrate
    JP   C, fdf_err_io

    ; --- Format all tracks ---
    LD   A, 0
    LD   (fdf_cur_cyl), A

fdf_cyl_loop:
    LD   A, (fdf_cur_cyl)
    LD   B, A
    LD   A, (fdf_cylinders)
    CP   B
    JP   Z, fdf_format_done

    ; Print "CC.0 " progress
    LD   A, (fdf_cur_cyl)
    CALL fdf_print_a_dec
    LD   B, LOGDEV_ID_CONO
    LD   E, '.'
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    LD   E, '0'
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    LD   E, ' '
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    ; Seek to cylinder, head 0
    XOR  A
    LD   (fdf_cur_head), A
    LD   A, (fdf_cur_cyl)
    CALL fdf_seek
    JP   C, fdf_err_io

    ; Format head 0
    LD   A, 0
    CALL fdf_format_track
    JP   C, fdf_err_io_detail

    ; Format head 1 (if 2-headed)
    LD   A, (fdf_heads)
    CP   2
    JP   C, fdf_cyl_next

    ; Print "CC.1 "
    LD   A, (fdf_cur_cyl)
    CALL fdf_print_a_dec
    LD   B, LOGDEV_ID_CONO
    LD   E, '.'
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    LD   E, '1'
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    LD   E, ' '
    LD   C, DEV_CWRITE
    CALL KERNELADDR

    ; Seek with head 1 before formatting head 1
    LD   A, 1
    LD   (fdf_cur_head), A
    LD   A, (fdf_cur_cyl)
    CALL fdf_seek
    JP   C, fdf_err_io

    LD   A, 1
    CALL fdf_format_track
    JP   C, fdf_err_io_detail

fdf_cyl_next:

    LD   A, (fdf_cur_cyl)
    INC  A
    LD   (fdf_cur_cyl), A
    JP   fdf_cyl_loop

fdf_format_done:
    ; Recalibrate to cylinder 0 so kernel driver state is valid
    CALL fdf_recalibrate
    LD   DE, msg_crlf
    CALL fdf_puts
    LD   DE, msg_done
    CALL fdf_puts
    JP   fdf_exit

; ============================================================
; Error handlers
; ============================================================
fdf_err_usage:
    LD   DE, msg_usage
    JP   fdf_err_print
fdf_err_dev:
    LD   DE, msg_bad_dev
    JP   fdf_err_print
fdf_err_io:
    LD   DE, msg_io_err
    JP   fdf_err_print
fdf_err_io_detail:
    LD   DE, msg_err_at
    CALL fdf_puts
    LD   A, (fdf_cur_cyl)
    CALL fdf_print_a_dec
    LD   DE, msg_err_head
    CALL fdf_puts
    LD   A, (fdf_cur_head)
    CALL fdf_print_a_dec
    LD   DE, msg_err_step
    CALL fdf_puts
    LD   A, (fdf_err_step)
    CALL fdf_print_a_dec
    LD   DE, msg_err_msr
    CALL fdf_puts
    LD   A, (fdf_err_msr)
    CALL fdf_print_a_hex
    LD   DE, msg_err_st
    CALL fdf_puts
    LD   A, (fdf_result_st0)
    CALL fdf_print_a_hex
    LD   B, LOGDEV_ID_CONO
    LD   E, ' '
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    LD   A, (fdf_result_st1)
    CALL fdf_print_a_hex
    LD   DE, msg_crlf
    CALL fdf_puts
fdf_err_print:
    CALL fdf_puts
fdf_exit:
    ; Re-initialize FDC via kernel (resets controller, re-sends
    ; SPECIFY/data rate, recalibrates, syncs all PDT state)
    LD   A, (fdf_dev_id)
    OR   A
    JP   Z, fdf_exit_done         ; no device opened, skip re-init
    LD   B, A
    LD   C, DEV_INIT
    CALL KERNELADDR
fdf_exit_done:
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; FDC low-level routines
; ============================================================

; ------------------------------------------------------------
; fdf_send_byte
; Send byte in A to FDC data register.
; Waits for RQM=1, DIO=0 (CPU->FDC direction).
; Inputs:  A = byte to send
; Outputs: Carry set on timeout
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdf_send_byte:
    PUSH BC
    PUSH DE
    LD   D, A                   ; save data byte
    LD   BC, 0                  ; timeout (65536)
fdf_sb_wait:
    IN   A, (FDC_PORT_MSR)
    LD   E, A                   ; save last MSR
    AND  0xC0                   ; isolate RQM + DIO
    CP   0x80                   ; RQM=1, DIO=0?
    JP   Z, fdf_sb_send
    CP   0xC0                   ; RQM=1, DIO=1? (result phase)
    JP   Z, fdf_sb_result       ; bail immediately
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, fdf_sb_wait
fdf_sb_result:
    LD   A, E
    LD   (fdf_err_msr), A       ; save MSR at point of failure
    POP  DE
    POP  BC
    SCF
    RET
fdf_sb_send:
    LD   A, D
    OUT  (FDC_PORT_DATA), A
    POP  DE
    POP  BC
    OR   A                      ; clear carry
    RET

; ------------------------------------------------------------
; fdf_read_byte
; Read byte from FDC data register.
; Waits for RQM=1, DIO=1 (FDC->CPU direction).
; Inputs:  (none)
; Outputs: A = data byte, Carry set on timeout
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdf_read_byte:
    PUSH BC
    PUSH DE
    LD   BC, 0                  ; timeout
fdf_rb_wait:
    IN   A, (FDC_PORT_MSR)
    LD   E, A                   ; save last MSR
    AND  0xC0
    CP   0xC0                   ; RQM=1, DIO=1?
    JP   Z, fdf_rb_read
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, fdf_rb_wait
    LD   A, E
    LD   (fdf_err_msr), A       ; save MSR at timeout
    POP  DE
    POP  BC
    SCF
    RET
fdf_rb_read:
    IN   A, (FDC_PORT_DATA)
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; fdf_sense_int
; Send Sense Interrupt Status command.
; Outputs: A = ST0, carry on timeout
; Preserves: DE, HL
; ------------------------------------------------------------
fdf_sense_int:
    PUSH BC
    LD   A, FDC_CMD_SENSE_INT
    CALL fdf_send_byte
    JP   C, fdf_si_err
    CALL fdf_read_byte          ; A = ST0
    JP   C, fdf_si_err
    LD   B, A                   ; save ST0
    CALL fdf_read_byte          ; A = PCN (discard)
    JP   C, fdf_si_err
    LD   A, B                   ; restore ST0
    POP  BC
    OR   A                      ; clear carry
    RET
fdf_si_err:
    POP  BC
    SCF
    RET

; ------------------------------------------------------------
; fdf_wait_seek
; Poll Sense Interrupt until seek completes (IC != 11).
; Outputs: Carry set on timeout
; Preserves: BC, HL
; ------------------------------------------------------------
fdf_wait_seek:
    PUSH DE
    ; Brief settle delay (~28us)
    LD   A, 15
fdf_ws_settle:
    DEC  A
    JP   NZ, fdf_ws_settle
    LD   DE, 0xFFFF             ; timeout
fdf_ws_poll:
    CALL fdf_sense_int          ; A = ST0
    JP   C, fdf_ws_retry
    CP   0xC0                   ; IC=11? (no interrupt)
    JP   C, fdf_ws_done         ; A < 0xC0: real interrupt
fdf_ws_retry:
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, fdf_ws_poll
    POP  DE
    SCF
    RET
fdf_ws_done:
    POP  DE
    OR   A                      ; clear carry
    RET

; ------------------------------------------------------------
; fdf_seek
; Seek to cylinder in A, head in fdf_cur_head.
; Inputs:  A = target cylinder
; Outputs: Carry set on error
; Preserves: BC, HL
; ------------------------------------------------------------
fdf_seek:
    PUSH DE
    LD   D, A                   ; save cylinder
    LD   A, FDC_CMD_SEEK
    CALL fdf_send_byte
    JP   C, fdf_seek_err
    LD   A, (fdf_cur_head)
    ADD  A, A
    ADD  A, A                   ; head << 2
    LD   E, A
    LD   A, (fdf_drive)
    OR   E                      ; (head << 2) | drive
    CALL fdf_send_byte
    JP   C, fdf_seek_err
    LD   A, D                   ; cylinder
    CALL fdf_send_byte
    JP   C, fdf_seek_err
    CALL fdf_wait_seek
    JP   C, fdf_seek_err
    POP  DE
    OR   A
    RET
fdf_seek_err:
    POP  DE
    SCF
    RET

; ------------------------------------------------------------
; fdf_recalibrate
; Recalibrate: seek to track 0.
; Outputs: Carry set on error
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdf_recalibrate:
    LD   A, FDC_CMD_RECAL
    CALL fdf_send_byte
    RET  C
    LD   A, (fdf_drive)
    CALL fdf_send_byte
    RET  C
    JP   fdf_wait_seek          ; tail call

; ------------------------------------------------------------
; fdf_format_track
; Format one track (current cylinder, specified head).
; Inputs:  A = head number (0 or 1)
; Outputs: Carry set on error (ST0/ST1 saved)
; Preserves: HL
; ------------------------------------------------------------
fdf_format_track:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   (fdf_cur_head), A

    ; Clear result bytes (0xFF = "not populated")
    LD   A, 0xFF
    LD   (fdf_result_st0), A
    LD   (fdf_result_st1), A
    LD   (fdf_err_msr), A
    XOR  A
    LD   (fdf_err_step), A

    ; --- Command phase: 6 bytes ---
    ; Byte 0: FORMAT TRACK command
    LD   A, FDF_CMD_FORMAT
    CALL fdf_send_byte
    JP   C, fdf_ft_err

    ; Byte 1: (head << 2) | drive
    LD   A, 1
    LD   (fdf_err_step), A
    LD   A, (fdf_cur_head)
    ADD  A, A
    ADD  A, A                   ; head << 2
    LD   B, A
    LD   A, (fdf_drive)
    OR   B
    CALL fdf_send_byte
    JP   C, fdf_ft_err

    ; Byte 2: N (sector size code)
    LD   A, 2
    LD   (fdf_err_step), A
    LD   A, (fdf_secsize)
    CALL fdf_send_byte
    JP   C, fdf_ft_err

    ; Byte 3: SC (sectors per track)
    LD   A, 3
    LD   (fdf_err_step), A
    LD   A, (fdf_spt)
    CALL fdf_send_byte
    JP   C, fdf_ft_err

    ; Byte 4: GPL (format gap length)
    LD   A, 4
    LD   (fdf_err_step), A
    LD   A, (fdf_format_gpl)
    CALL fdf_send_byte
    JP   C, fdf_ft_err

    ; Byte 5: D (fill byte)
    LD   A, 5
    LD   (fdf_err_step), A
    LD   A, FDF_FILL_BYTE
    CALL fdf_send_byte
    JP   C, fdf_ft_err

    ; --- Execution phase: tight inline poll-and-send ---
    ; Preload constants into registers for speed:
    ;   D = cylinder, E = head, H = sector size code
    ;   B = sectors remaining, C = current sector (1-based)
    ; Each byte must be provided within 16us at 500kbit/s MFM.
    ; Using ADD A,A bit-shift to check RQM/DIO quickly.
    LD   A, (fdf_cur_cyl)
    LD   D, A
    LD   A, (fdf_cur_head)
    LD   E, A
    LD   A, (fdf_secsize)
    LD   H, A
    LD   A, (fdf_spt)
    LD   B, A
    LD   C, 1                   ; sector 1

fdf_ft_id_loop:
    ; --- Send cylinder (D) ---
fdf_ft_poll_c:
    IN   A, (FDC_PORT_MSR)
    ADD  A, A                   ; bit7 (RQM) -> carry
    JP   NC, fdf_ft_poll_c
    ADD  A, A                   ; bit6 (DIO) -> carry
    JP   C, fdf_ft_exec_err     ; DIO=1: result phase
    LD   A, D
    OUT  (FDC_PORT_DATA), A

    ; --- Send head (E) ---
fdf_ft_poll_h:
    IN   A, (FDC_PORT_MSR)
    ADD  A, A
    JP   NC, fdf_ft_poll_h
    ADD  A, A
    JP   C, fdf_ft_exec_err
    LD   A, E
    OUT  (FDC_PORT_DATA), A

    ; --- Send sector number (C) ---
fdf_ft_poll_r:
    IN   A, (FDC_PORT_MSR)
    ADD  A, A
    JP   NC, fdf_ft_poll_r
    ADD  A, A
    JP   C, fdf_ft_exec_err
    LD   A, C
    OUT  (FDC_PORT_DATA), A

    ; --- Send sector size (H) ---
fdf_ft_poll_n:
    IN   A, (FDC_PORT_MSR)
    ADD  A, A
    JP   NC, fdf_ft_poll_n
    ADD  A, A
    JP   C, fdf_ft_exec_err
    LD   A, H
    OUT  (FDC_PORT_DATA), A

    INC  C                      ; next sector
    DEC  B
    JP   NZ, fdf_ft_id_loop

    ; --- Result phase: read 7 bytes ---
    CALL fdf_ft_read_result
    JP   C, fdf_ft_err

    ; Check ST0: IC bits must be 00 (normal completion)
    LD   A, (fdf_result_st0)
    AND  0xC0
    JP   NZ, fdf_ft_err         ; IC != 00: error

    POP  HL
    POP  DE
    POP  BC
    OR   A                      ; clear carry
    RET

; Execution phase error: FDC entered result phase early
; Save sector info for diagnostics, then read result bytes
fdf_ft_exec_err:
    ; Save which sector we were on: step = (spt - B) * 4 + 6
    LD   A, (fdf_spt)
    SUB  B                      ; A = sectors completed
    ADD  A, A
    ADD  A, A                   ; A = sectors * 4
    ADD  A, 6
    LD   (fdf_err_step), A
    ; Capture MSR
    IN   A, (FDC_PORT_MSR)
    LD   (fdf_err_msr), A
    ; Try to read result bytes
    AND  0xC0
    CP   0xC0                   ; still in result phase?
    JP   NZ, fdf_ft_err
    CALL fdf_ft_read_result
    JP   fdf_ft_err

; Read 7 result bytes from FDC into fdf_result_st0/st1
fdf_ft_read_result:
    CALL fdf_read_byte          ; ST0
    RET  C
    LD   (fdf_result_st0), A
    CALL fdf_read_byte          ; ST1
    RET  C
    LD   (fdf_result_st1), A
    CALL fdf_read_byte          ; ST2 (discard)
    RET  C
    CALL fdf_read_byte          ; C
    RET  C
    CALL fdf_read_byte          ; H
    RET  C
    CALL fdf_read_byte          ; R
    RET  C
    CALL fdf_read_byte          ; N
    RET

fdf_ft_err:
    POP  HL
    POP  DE
    POP  BC
    SCF
    RET

; ------------------------------------------------------------
; fdf_motor_on
; Enable motor for configured drive, with ~500ms spin-up.
; Only supports drives 0 and 1 (DOR values are hardcoded).
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdf_motor_on:
    PUSH AF
    PUSH BC
    LD   A, (fdf_drive)
    OR   A
    JP   NZ, fdf_mo_d1
    ; Drive 0: motor0 (bit 4) + reset + dmagate + drive 0
    LD   A, FDC_DOR_RESET | FDC_DOR_DMAGATE | 0x10
    JP   fdf_mo_out
fdf_mo_d1:
    ; Drive 1: motor1 (bit 5) + reset + dmagate + drive 1
    LD   A, FDC_DOR_RESET | FDC_DOR_DMAGATE | 0x21
fdf_mo_out:
    OUT  (FDC_PORT_DOR), A
    ; Spin-up delay ~500ms at 7.3728 MHz
    ; Inner: 256 * 14T = 3584T
    ; Mid:   256 * 3584 = 917,504T ≈ 124ms
    ; Outer: 4 * 124ms ≈ 500ms
    LD   A, 4
fdf_mo_dly_o:
    LD   B, 0
fdf_mo_dly_m:
    LD   C, 0
fdf_mo_dly_i:
    DEC  C
    JP   NZ, fdf_mo_dly_i
    DEC  B
    JP   NZ, fdf_mo_dly_m
    DEC  A
    JP   NZ, fdf_mo_dly_o
    POP  BC
    POP  AF
    RET

; ------------------------------------------------------------
; fdf_motor_off
; Turn motor off, keep FDC active.
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdf_motor_off:
    PUSH AF
    LD   A, (fdf_drive)
    OR   FDC_DOR_RESET | FDC_DOR_DMAGATE
    OUT  (FDC_PORT_DOR), A      ; motor bits cleared
    POP  AF
    RET

; ============================================================
; Utility routines
; ============================================================

; ------------------------------------------------------------
; fdf_puts
; Print null-terminated string at DE to console.
; Preserves: HL
; ------------------------------------------------------------
fdf_puts:
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    RET

; ------------------------------------------------------------
; fdf_print_a_dec
; Print A (0-255) as unsigned decimal.
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdf_print_a_dec:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   H, 0
    LD   L, A                   ; HL = value
    LD   DE, fdf_dec_buf + 3
    LD   A, 0
    LD   (DE), A                ; null terminator
fdf_pad_loop:
    DEC  DE
    PUSH DE
    LD   BC, 0                  ; quotient
fdf_d10_loop:
    LD   A, H
    OR   A
    JP   NZ, fdf_d10_sub
    LD   A, L
    CP   10
    JP   C, fdf_d10_done
fdf_d10_sub:
    LD   A, L
    SUB  10
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    INC  BC
    JP   fdf_d10_loop
fdf_d10_done:
    LD   A, L                   ; A = remainder
    LD   H, B
    LD   L, C                   ; HL = quotient
    POP  DE
    ADD  A, '0'
    LD   (DE), A
    LD   A, H
    OR   L
    JP   NZ, fdf_pad_loop
    CALL fdf_puts
    POP  HL
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; fdf_print_a_hex
; Print A as 2 hex digits.
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdf_print_a_hex:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   B, A                   ; save value
    ; High nibble
    RRCA
    RRCA
    RRCA
    RRCA
    AND  0x0F
    CALL fdf_nibble_to_ascii
    LD   E, A
    PUSH BC
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    ; Low nibble
    LD   A, B
    AND  0x0F
    CALL fdf_nibble_to_ascii
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  DE
    POP  BC
    RET

fdf_nibble_to_ascii:
    ADD  A, '0'
    CP   '9' + 1
    RET  C
    ADD  A, 'A' - ('9' + 1)
    RET

; ============================================================
; Variables
; ============================================================
fdf_dev_id:     DEFB 0
fdf_drive:      DEFB 0
fdf_spt:        DEFB 0
fdf_heads:      DEFB 0
fdf_secsize:    DEFB 0
fdf_cylinders:  DEFB 0
fdf_datarate:   DEFB 0
fdf_format_gpl: DEFB 0
fdf_cur_cyl:    DEFB 0
fdf_cur_head:   DEFB 0
fdf_result_st0: DEFB 0
fdf_result_st1: DEFB 0
fdf_err_step:   DEFB 0
fdf_err_msr:    DEFB 0
fdf_dev_name:   DEFS 8, 0
fdf_dec_buf:    DEFS 4, 0

; ============================================================
; Messages
; ============================================================
msg_header:     DEFM "FDINIT: ", 0
msg_space:      DEFM " ", 0
msg_cyl:        DEFM " cyl, ", 0
msg_heads:      DEFM " heads, ", 0
msg_spt:        DEFM " spt", 0x0D, 0x0A, 0
msg_confirm:    DEFM "Format disk? (Y/N) ", 0
msg_cancelled:  DEFM 0x0D, 0x0A, "Cancelled.", 0x0D, 0x0A, 0
msg_done:       DEFM "Format complete.", 0x0D, 0x0A, 0
msg_usage:      DEFM "Usage: FDINIT <device:>", 0x0D, 0x0A, 0
msg_bad_dev:    DEFM "Error: unknown device.", 0x0D, 0x0A, 0
msg_io_err:     DEFM "Error: I/O error.", 0x0D, 0x0A, 0
msg_err_at:     DEFM 0x0D, 0x0A, "Error at cyl ", 0
msg_err_head:   DEFM " head ", 0
msg_err_step:   DEFM " step ", 0
msg_err_msr:    DEFM " MSR=", 0
msg_err_st:     DEFM " ST=", 0
msg_crlf:       DEFM 0x0D, 0x0A, 0

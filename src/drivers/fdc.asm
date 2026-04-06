; NostOS WD37C65 Floppy Disk Controller Driver
; Polled I/O, single sector (512 bytes) per operation.
; Ports are hardcoded; disk geometry is stored in PDT user data.
;
; PDT user data layout:
;   bytes 0-1:  current LBA position (2 bytes, little-endian)
;   byte 2:    drive number (0-3)
;   byte 3:    sectors per track
;   byte 4:    number of heads (1 or 2)
;   byte 5:    sector size code (2 = 512 bytes)
;   byte 6:    total cylinders
;   byte 7:    gap length (GPL)
;   byte 8:    data rate (DCR value: 0=500kbps, 1=300kbps, 2=250kbps)
;   byte 9:    current cylinder (runtime state)
;   byte 10:   motor state (runtime: 0=off, nonzero=on)
;   byte 11:   target cylinder (per-I/O scratch)
;   byte 12:   target head (per-I/O scratch)
;   byte 13:   target sector (per-I/O scratch, 1-based)
; ============================================================


; ------------------------------------------------------------
; fdc_send_byte
; Send one command/parameter byte to the FDC data register.
; Waits for RQM=1 and DIO=0 (CPU->FDC direction) with timeout.
; Inputs:
;   A  - byte to send
; Outputs:
;   Carry flag set on timeout
; Preserves: A, BC, DE, HL (flags clobbered)
; ------------------------------------------------------------
fdc_send_byte:
    PUSH AF                     ; save byte to send
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE
    LD   DE, 0xFFFF             ; timeout counter
    ; Brief delay for MSR settling (~16us at 7.3MHz).
    ; The WD37C65 takes up to 12us to update MSR after a byte exchange.
    LD   A, 15                  ; 15 * 14T = 210T ≈ 28us
fdc_send_settle:
    DEC  A
    JP   NZ, fdc_send_settle
fdc_send_byte_wait:
    IN   A, (FDC_PORT_MSR)
    AND  FDC_MSR_RQM | FDC_MSR_DIO ; check RQM=1 and DIO=0
    CP   FDC_MSR_RQM            ; RQM set, DIO clear?
    JP   Z, fdc_send_byte_go
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, fdc_send_byte_wait
    ; Timeout
    POP  DE
    POP  BC
    POP  AF
    SCF                         ; carry = error
    RET
fdc_send_byte_go:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    POP  AF                     ; restore byte to send
    OUT  (FDC_PORT_DATA), A
    OR   A                      ; clear carry (POP AF restored caller's flags)
    RET

; ------------------------------------------------------------
; fdc_read_byte
; Read one result byte from the FDC data register.
; Waits for RQM=1 and DIO=1 (FDC->CPU direction) with timeout.
; Inputs:
;   (none)
; Outputs:
;   A  - byte read
;   Carry flag set on timeout
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdc_read_byte:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE
    LD   DE, 0xFFFF             ; timeout counter
    ; Brief delay for MSR settling (~16us at 7.3MHz).
    LD   A, 15                  ; 15 * 14T = 210T ≈ 28us
fdc_read_settle:
    DEC  A
    JP   NZ, fdc_read_settle
fdc_read_byte_wait:
    IN   A, (FDC_PORT_MSR)
    AND  FDC_MSR_RQM | FDC_MSR_DIO ; check both RQM and DIO
    CP   FDC_MSR_RQM | FDC_MSR_DIO ; RQM=1 and DIO=1?
    JP   Z, fdc_read_byte_go
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, fdc_read_byte_wait
    ; Timeout
    POP  DE
    POP  BC
    XOR  A                      ; A = 0
    SCF                         ; carry = error
    RET
fdc_read_byte_go:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    IN   A, (FDC_PORT_DATA)
    ; carry clear from CP match above
    RET

; ------------------------------------------------------------
; fdc_sense_int
; Send Sense Interrupt Status command and read 2-byte result.
; Inputs:
;   (none)
; Outputs:
;   A  - ST0
;   B  - current cylinder
;   Carry set on timeout
; Preserves: DE, HL
; ------------------------------------------------------------
fdc_sense_int:
    LD   A, FDC_CMD_SENSE_INT
    CALL fdc_send_byte
    RET  C                      ; timeout sending command
    CALL fdc_read_byte          ; A = ST0
    RET  C                      ; timeout reading ST0
    PUSH AF                     ; save ST0
    CALL fdc_read_byte          ; A = current cylinder
    JP   C, fdc_sense_int_err
    LD   B, A                   ; B = cylinder
    POP  AF                     ; A = ST0
    OR   A                      ; clear carry
    RET
fdc_sense_int_err:
    POP  AF                     ; balance stack (saved ST0)
    SCF                         ; carry = error
    RET

; ------------------------------------------------------------
; fdc_read_result
; Read 7-byte result phase after a Read Data or Write Data command.
; Inputs:
;   (none)
; Outputs:
;   A  - ST0 (interrupt code in bits 7:6)
;   B  - ST1 (EN bit in bit 7)
;   Carry set if any read timed out
; Preserves: DE, HL
; ------------------------------------------------------------
fdc_read_result:
    CALL fdc_read_byte          ; ST0
    JP   C, fdc_read_result_err
    PUSH AF                     ; save ST0
    CALL fdc_read_byte          ; ST1
    JP   C, fdc_read_result_err2
    LD   B, A                   ; B = ST1
    LD   C, 5                   ; 5 remaining result bytes (ST2, C, H, R, N)
fdc_read_result_discard:
    CALL fdc_read_byte
    JP   C, fdc_read_result_err2
    DEC  C
    JP   NZ, fdc_read_result_discard
    POP  AF                     ; restore ST0
    OR   A                      ; clear carry
    RET
fdc_read_result_err2:
    POP  AF                     ; balance stack (saved ST0)
fdc_read_result_err:
    SCF                         ; carry = timeout error
    RET

; ------------------------------------------------------------
; fdc_check_result
; Read 7-byte result phase and evaluate ST0/ST1.
; With EOT=R (single sector), the FDC terminates with IC=01
; and ST1 EN=1, which is normal — not an error.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_SUCCESS or ERR_IO
; Preserves: DE, HL
; ------------------------------------------------------------
fdc_check_result:
    CALL fdc_read_result        ; A = ST0, B = ST1, carry on timeout
    JP   C, fdc_check_rtout     ; read_result timed out
    LD   C, A                   ; C = raw ST0 (save for debug)
    AND  0xC0                   ; isolate IC bits (7:6)
    RET  Z                      ; IC=00: normal termination, A=0=ERR_SUCCESS
    CP   0x40                   ; IC=01: abnormal termination?
    JP   NZ, fdc_check_errd     ; IC=10 or 11: real error
    ; IC=01: check ST1 EN bit (End of Cylinder = normal for single-sector)
    LD   A, B                   ; A = ST1
    AND  0xB7                   ; EN (0x80) + error bits DE|OR|ND|NW|MA (0x37)
    CP   0x80                   ; exactly EN, no error bits?
    JP   NZ, fdc_check_errd     ; missing EN or real error bits set
    XOR  A                      ; EN set, no errors: success
    RET                         ; A = ERR_SUCCESS
fdc_check_rtout:
fdc_check_errd:
fdc_check_fail:
    LD   A, ERR_IO
    RET

; ------------------------------------------------------------
; fdc_div16by8
; Unsigned 16-bit by 8-bit division.
; Inputs:
;   HL - dividend (16-bit)
;   C  - divisor (8-bit, must be nonzero)
; Outputs:
;   HL - quotient
;   A  - remainder
; Preserves: DE
; ------------------------------------------------------------
fdc_div16by8:
    PUSH BC
    XOR  A                      ; clear remainder
    LD   B, 16                  ; 16 bits to process
fdc_div16by8_loop:
    ADD  HL, HL                 ; shift dividend left, MSB into carry
    RLA                         ; shift carry into remainder
    CP   C                      ; remainder >= divisor?
    JP   C, fdc_div16by8_skip   ; carry set = remainder < divisor, skip
    SUB  C                      ; remainder -= divisor
    INC  L                      ; set quotient bit
fdc_div16by8_skip:
    DEC  B
    JP   NZ, fdc_div16by8_loop
    POP  BC
    RET

; ------------------------------------------------------------
; fdc_lba_to_chs
; Convert the current LBA position (from PDT) to CHS.
; sector = (LBA % SPT) + 1
; head   = (LBA / SPT) % heads
; cyl    = (LBA / SPT) / heads
; Inputs:
;   HL - pointer to user data (destroyed)
; Outputs:
;   D  - cylinder
;   E  - head
;   A  - sector (1-based)
; Clobbers: BC, HL
; ------------------------------------------------------------
fdc_lba_to_chs:
    ; Read LBA
    LD   E, (HL)                ; LBA low
    INC  HL
    LD   D, (HL)                ; LBA high
    INC  HL
    INC  HL                     ; skip drive (offset 2), now at offset 3
    LD   B, (HL)                ; B = SPT
    INC  HL
    LD   A, (HL)                ; A = heads
    ; Now: DE = LBA, B = SPT, A = heads

    PUSH AF                     ; save heads

    ; Division 1: LBA / SPT
    LD   H, D
    LD   L, E                   ; HL = LBA
    LD   C, B                   ; C = SPT (divisor)
    CALL fdc_div16by8           ; HL = LBA/SPT, A = LBA%SPT
    INC  A                      ; A = sector (1-based)
    LD   D, A                   ; D = sector (save)

    ; Division 2: (LBA/SPT) / heads
    POP  AF                     ; A = heads
    LD   C, A                   ; C = heads (divisor)
    CALL fdc_div16by8           ; HL = cylinder, A = head

    ; Results: L = cylinder, A = head, D = sector
    LD   E, A                   ; E = head
    LD   A, D                   ; A = sector
    LD   D, L                   ; D = cylinder
    ; D = cylinder, E = head, A = sector (1-based)
    RET

; ------------------------------------------------------------
; fdc_motor_on
; Enable motor for the drive specified in PDT user data.
; If motor is already on, returns immediately.
; Includes ~500ms spin-up delay for first activation.
; Inputs:
;   HL - pointer to user data
; Outputs:
;   (none)
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdc_motor_on:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL

    ; Check if motor is already on
    PUSH HL
    LD   DE, FDC_OFF_MOTOR
    ADD  HL, DE
    LD   A, (HL)
    POP  HL
    OR   A
    JP   NZ, fdc_motor_on_done  ; already on

    ; Get drive number
    PUSH HL
    LD   DE, FDC_OFF_DRIVE
    ADD  HL, DE
    LD   C, (HL)                ; C = drive number (0-3)
    POP  HL

    ; Compute DOR value: motor_bit | DMA gate | /RESET | drive select
    ; Motor enable bit = 1 << (drive + 4)
    LD   A, C                   ; A = drive number
    OR   A
    JP   Z, fdc_motor_drv0      ; drive 0: motor bit is 0x10
    LD   B, A                   ; B = shift count
    LD   A, 0x10
fdc_motor_shift:
    ADD  A, A                   ; shift left
    DEC  B
    JP   NZ, fdc_motor_shift
    JP   fdc_motor_set_dor
fdc_motor_drv0:
    LD   A, 0x10
fdc_motor_set_dor:
    OR   FDC_DOR_DMAGATE | FDC_DOR_RESET
    OR   C                      ; drive select bits
    OUT  (FDC_PORT_DOR), A

    ; Spin-up delay (~500ms at 7.3728 MHz)
    ; Inner loop: DEC DE / LD A,D / OR E / JP NZ = 24 T-states
    ; 65536 * 24 = 1,572,864 T ≈ 213ms.  3 iterations ≈ 639ms.
    LD   A, 3
fdc_spinup_outer:
    PUSH AF
    LD   DE, 0                  ; 65536 iterations
fdc_spinup_inner:
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, fdc_spinup_inner
    POP  AF
    DEC  A
    JP   NZ, fdc_spinup_outer

    ; Mark motor as on
    PUSH HL
    LD   DE, FDC_OFF_MOTOR
    ADD  HL, DE
    LD   (HL), 1
    POP  HL

fdc_motor_on_done:
    POP  HL
    POP  DE
    POP  BC
    POP  AF
    RET

; ------------------------------------------------------------
; fdc_poll_sense_int
; Settle delay then poll Sense Interrupt until a real interrupt
; is received (IC != 11).  Used after recalibrate and seek.
; Inputs:
;   (none)
; Outputs:
;   A  - ST0 (on success)
;   Carry set on timeout
; Preserves: HL
; ------------------------------------------------------------
fdc_poll_sense_int:
    PUSH DE
    LD   A, 15                  ; 15 * 14T = 210T ≈ 28us settle
fdc_poll_si_settle:
    DEC  A
    JP   NZ, fdc_poll_si_settle
    LD   DE, 0xFFFF             ; timeout counter
fdc_poll_si_wait:
    CALL fdc_sense_int          ; A=ST0, B=cyl; preserves DE, HL
    JP   C, fdc_poll_si_retry
    CP   0xC0                   ; IC=11? (no interrupt pending)
    JP   C, fdc_poll_si_done    ; A < 0xC0: real interrupt
fdc_poll_si_retry:
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, fdc_poll_si_wait
    POP  DE
    SCF                         ; carry = timeout
    RET
fdc_poll_si_done:
    POP  DE
    OR   A                      ; clear carry = success
    RET

; ------------------------------------------------------------
; fdc_recalibrate
; Send Recalibrate command to move head to track 0.
; Updates current cylinder in PDT to 0.
; Inputs:
;   HL - pointer to user data
; Outputs:
;   Carry set on error (timeout)
; Preserves: BC, DE, HL
; ------------------------------------------------------------
fdc_recalibrate:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Get drive number
    LD   DE, FDC_OFF_DRIVE
    ADD  HL, DE
    LD   C, (HL)                ; C = drive number

    LD   A, FDC_CMD_RECAL
    CALL fdc_send_byte
    JP   C, fdc_recal_err
    LD   A, C                   ; drive number
    CALL fdc_send_byte
    JP   C, fdc_recal_err

    CALL fdc_poll_sense_int
    JP   C, fdc_recal_err

    ; Set current cylinder to 0 in PDT
    POP  HL                     ; restore user data ptr
    PUSH HL                     ; re-save
    LD   DE, FDC_OFF_CUR_CYL
    ADD  HL, DE
    LD   (HL), 0

    POP  HL
    POP  DE
    POP  BC
    OR   A                      ; clear carry = success
    RET

fdc_recal_err:
    POP  HL
    POP  DE
    POP  BC
    SCF                         ; carry = error
    RET

; ------------------------------------------------------------
; fdc_do_seek
; Seek to a specific cylinder. Updates current cylinder in PDT.
; Inputs:
;   A  - target cylinder
;   HL - pointer to user data
; Outputs:
;   Carry set on error (timeout)
; Preserves: DE, HL
; ------------------------------------------------------------
fdc_do_seek:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   D, A                   ; D = target cylinder

    ; Get drive number and target head from user data
    PUSH HL
    PUSH DE                     ; save D=target cyl
    LD   DE, FDC_OFF_DRIVE
    ADD  HL, DE
    LD   C, (HL)                ; C = drive number
    LD   DE, FDC_OFF_TGT_HEAD - FDC_OFF_DRIVE
    ADD  HL, DE
    LD   B, (HL)                ; B = target head
    POP  DE                     ; restore D=target cyl
    POP  HL                     ; HL = user data ptr

    ; Send seek command: command, (head<<2)|drive, cylinder
    LD   A, FDC_CMD_SEEK
    CALL fdc_send_byte
    JP   C, fdc_do_seek_err
    LD   A, B                   ; target head
    ADD  A, A                   ; head << 1
    ADD  A, A                   ; head << 2
    OR   C                      ; | drive
    CALL fdc_send_byte
    JP   C, fdc_do_seek_err
    LD   A, D                   ; target cylinder
    CALL fdc_send_byte
    JP   C, fdc_do_seek_err

    PUSH DE                     ; save D=target cylinder
    CALL fdc_poll_sense_int
    POP  DE                     ; restore D=target cylinder
    JP   C, fdc_do_seek_err

    ; Update current cylinder in PDT
    POP  HL                     ; restore user data ptr
    PUSH HL                     ; re-save
    PUSH DE
    LD   A, D                   ; target cylinder
    LD   DE, FDC_OFF_CUR_CYL
    ADD  HL, DE
    LD   (HL), A
    POP  DE

    POP  HL
    POP  DE
    POP  BC
    OR   A                      ; clear carry = success
    RET

fdc_do_seek_err:
    POP  HL
    POP  DE
    POP  BC
    SCF                         ; carry = error
    RET

; ------------------------------------------------------------
; fdc_send_rw_cmd
; Send the 9-byte Read Data or Write Data command sequence.
; CHS must already be stored in PDT user data at FDC_OFF_TGT_CYL/HEAD/SECTOR.
; Inputs:
;   A  - command byte (FDC_CMD_READ or FDC_CMD_WRITE)
;   HL - pointer to user data
; Outputs:
;   Carry flag set on timeout
; Preserves: DE, HL
; ------------------------------------------------------------
fdc_send_rw_cmd:
    PUSH DE
    PUSH HL

    ; Byte 0: command
    CALL fdc_send_byte
    JP   C, fdc_send_rw_cmd_err

    ; Byte 1: (head << 2) | drive
    PUSH HL
    LD   DE, FDC_OFF_TGT_HEAD
    ADD  HL, DE
    LD   A, (HL)                ; target head
    POP  HL
    ADD  A, A                   ; head << 1
    ADD  A, A                   ; head << 2
    PUSH HL
    LD   DE, FDC_OFF_DRIVE
    ADD  HL, DE
    OR   (HL)                   ; OR in drive number
    POP  HL
    CALL fdc_send_byte
    JP   C, fdc_send_rw_cmd_err

    ; Bytes 2-7: table-driven from PDT offsets
    ; (cylinder, head, sector, secsize, EOT=sector, GPL)
    LD   DE, fdc_rw_param_offsets
    LD   B, 6
fdc_send_rw_params:
    PUSH BC
    PUSH DE
    LD   A, (DE)                ; get PDT offset from table
    PUSH HL                     ; save user data ptr
    LD   E, A
    LD   D, 0
    ADD  HL, DE
    LD   A, (HL)                ; read value from user data
    POP  HL                     ; restore user data ptr
    CALL fdc_send_byte
    POP  DE
    POP  BC
    JP   C, fdc_send_rw_cmd_err
    INC  DE
    DEC  B
    JP   NZ, fdc_send_rw_params

    ; Byte 8: DTL = 0xFF (ignored when sector size code != 0)
    LD   A, 0xFF
    CALL fdc_send_byte
    JP   C, fdc_send_rw_cmd_err

    POP  HL
    POP  DE
    ; carry clear
    RET

fdc_send_rw_cmd_err:
    POP  HL
    POP  DE
    SCF                         ; carry = error
    RET

fdc_rw_param_offsets:
    DEFB FDC_OFF_TGT_CYL        ; byte 2: cylinder
    DEFB FDC_OFF_TGT_HEAD       ; byte 3: head
    DEFB FDC_OFF_TGT_SECTOR     ; byte 4: sector (1-based)
    DEFB FDC_OFF_SECSIZE         ; byte 5: sector size code
    DEFB FDC_OFF_TGT_SECTOR     ; byte 6: EOT = sector
    DEFB FDC_OFF_GPL             ; byte 7: GPL

; ------------------------------------------------------------
; fdc_read_data_256
; Transfer 256 bytes from FDC data port into buffer.
; Called twice for a 512-byte sector.  Tight poll loop
; matches RomWBW approach: no PUSH/POP per byte.
; Uses HL as nested timeout (only while waiting for first
; byte or when FDC stalls; resets each byte).
; Inputs:
;   B  - iteration count (0 = 256)
;   DE - destination buffer pointer
; Outputs:
;   DE - advanced past transferred bytes
;   B  - 0 on success
;   Carry flag set on timeout
; Clobbers: A, C, HL
; ------------------------------------------------------------
fdc_read_data_256:
fdc_rd256_next:
    LD   H, 0                 ; outer timeout (256 outer loops)
fdc_rd256_outer:
    LD   L, 0                 ; inner timeout (256 inner polls)
fdc_rd256_poll:
    IN   A, (FDC_PORT_MSR)   ; 11T
    AND  0xF0                 ; 7T  mask off drive-busy bits (D0-D3)
    CP   0xF0                 ; 7T  RQM|DIO|EXM|CB
    JP   Z, fdc_rd256_xfer   ; 10T
    DEC  L                    ; 4T
    JP   NZ, fdc_rd256_poll   ; 10T  (42T per inner poll)
    DEC  H
    JP   NZ, fdc_rd256_outer
    SCF                        ; carry = timeout error
    RET
fdc_rd256_xfer:
    IN   A, (FDC_PORT_DATA)  ; 11T
    LD   (DE), A             ; 7T
    INC  DE                  ; 6T
    DEC  B                   ; 4T
    JP   NZ, fdc_rd256_next  ; 10T  (38T xfer, then 7+7=14T to first poll)
    ; B=0: done, carry clear
    RET

; ------------------------------------------------------------
; fdc_write_data_256
; Transfer 256 bytes from buffer to FDC data port.
; Called twice for a 512-byte sector.  Tight poll loop.
; Inputs:
;   B  - iteration count (0 = 256)
;   DE - source buffer pointer
; Outputs:
;   DE - advanced past transferred bytes
;   B  - 0 on success
;   Carry flag set on timeout
; Clobbers: A, C, HL
; ------------------------------------------------------------
fdc_write_data_256:
fdc_wr256_next:
    LD   H, 0                 ; outer timeout
fdc_wr256_outer:
    LD   L, 0                 ; inner timeout
fdc_wr256_poll:
    IN   A, (FDC_PORT_MSR)
    AND  0xF0                 ; mask off drive-busy bits (D0-D3)
    CP   0xB0                 ; RQM|EXM|CB (DIO=0 for write)
    JP   Z, fdc_wr256_xfer
    DEC  L
    JP   NZ, fdc_wr256_poll
    DEC  H
    JP   NZ, fdc_wr256_outer
    SCF                        ; carry = timeout error
    RET
fdc_wr256_xfer:
    LD   A, (DE)
    OUT  (FDC_PORT_DATA), A
    INC  DE
    DEC  B
    JP   NZ, fdc_wr256_next
    ; carry clear
    RET

; ------------------------------------------------------------
; fdc_prepare_rw
; Common setup for read/write: look up PDT, motor on, LBA->CHS,
; seek if needed, send command.
; Inputs:
;   B  - physical device ID
;   A  - command byte (FDC_CMD_READ or FDC_CMD_WRITE)
; Outputs:
;   HL - user data pointer
;   Carry flag set on error
; Clobbers: BC, DE (callers must save/restore themselves)
; ------------------------------------------------------------
fdc_prepare_rw:
    PUSH AF                     ; save command byte
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE                 ; HL = user data ptr

    CALL fdc_motor_on

    ; Drain any pending bytes from the FDC (per RomWBW FOP_CLR1).
    ; If a previous operation timed out or left the FDC in an
    ; unexpected state, there may be result bytes waiting.
    PUSH BC
    LD   B, 0                   ; up to 256 bytes to drain
fdc_drain_loop:
    IN   A, (FDC_PORT_MSR)
    AND  FDC_MSR_RQM | FDC_MSR_DIO ; RQM=1 and DIO=1?
    CP   FDC_MSR_RQM | FDC_MSR_DIO
    JP   NZ, fdc_drain_done     ; no pending data, proceed
    IN   A, (FDC_PORT_DATA)     ; read and discard pending byte
    DEC  B
    JP   NZ, fdc_drain_loop
fdc_drain_done:
    POP  BC

    ; LBA to CHS
    PUSH HL                     ; save user data ptr
    CALL fdc_lba_to_chs         ; D=cyl, E=head, A=sector (destroys HL)
    ; Store CHS into PDT user data (per-device scratch, no collision with FS temps)
    POP  HL                     ; HL = user data ptr
    PUSH DE                     ; save D=cyl, E=head
    PUSH HL
    LD   DE, FDC_OFF_TGT_CYL
    ADD  HL, DE
    POP  DE                     ; DE = user data ptr (was HL)
    ; now HL = user data + FDC_OFF_TGT_CYL
    POP  BC                     ; B=cyl (was D), C=head (was E)
    LD   (HL), B                ; target cylinder
    INC  HL
    LD   (HL), C                ; target head
    INC  HL
    LD   (HL), A                ; target sector
    LD   H, D
    LD   L, E                   ; HL = user data ptr

    ; Seek to target position (cylinder and head)
    PUSH HL
    LD   DE, FDC_OFF_TGT_CYL
    ADD  HL, DE
    LD   A, (HL)                ; target cylinder
    POP  HL
    CALL fdc_do_seek            ; A = target cyl, HL = user data ptr
    JP   C, fdc_prepare_rw_err  ; seek failed

    ; Send read/write command
    POP  AF                     ; restore command byte
    CALL fdc_send_rw_cmd        ; send 9-byte command; carry on error
    RET                         ; carry propagates to caller

fdc_prepare_rw_err:
    POP  AF                     ; balance stack (saved command byte)
    SCF                         ; carry = error
    RET

; ------------------------------------------------------------
; fdc_init
; Initialize the FDC: reset controller, specify, motor on,
; set data rate, recalibrate.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS, or ERR_IO if controller unresponsive
;   HL - 0
; Preserves: BC, DE
; ------------------------------------------------------------
fdc_init:
    PUSH BC
    PUSH DE
    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA
    ADD  HL, DE                 ; HL = user data ptr

    ; Reset FDC: assert /RESET via DOR (clear bit 2)
    XOR  A
    OUT  (FDC_PORT_DOR), A      ; all bits zero = reset asserted
    ; Clear runtime state invalidated by hardware reset
    PUSH HL
    LD   DE, FDC_OFF_MOTOR
    ADD  HL, DE
    LD   (HL), 0                ; motor is physically off after reset
    POP  HL
    ; Brief delay for reset pulse
    LD   B, 0
fdc_init_reset_delay:
    DEC  B
    JP   NZ, fdc_init_reset_delay

    ; Release reset: set /RESET + DMA gate + drive select
    PUSH HL
    LD   DE, FDC_OFF_DRIVE
    ADD  HL, DE
    LD   C, (HL)                ; C = drive number
    POP  HL
    LD   A, FDC_DOR_DMAGATE | FDC_DOR_RESET
    OR   C                      ; drive select
    OUT  (FDC_PORT_DOR), A

    ; Post-reset settling delay (~2.4ms at 7.3728 MHz).
    ; The FDC needs time to initialize after reset release before
    ; it can accept commands.  RomWBW uses a similar delay here.
    ; 256 * 14T = 3584T ≈ 486us; 5 loops ≈ 2.4ms.
    LD   A, 5
fdc_init_post_reset:
    LD   B, 0
fdc_init_post_reset_inner:
    DEC  B
    JP   NZ, fdc_init_post_reset_inner
    DEC  A
    JP   NZ, fdc_init_post_reset

    ; Clear all pending interrupts from reset.
    ; Loop until sense_int returns IC=11 (no more interrupts)
    ; or times out.  Per RomWBW: do not assume exactly 4.
fdc_init_clear_ints:
    CALL fdc_sense_int
    JP   C, fdc_init_ints_done  ; timeout: FDC not ready or no more
    AND  0xC0
    CP   0xC0                   ; IC=11 (invalid = no interrupt pending)?
    JP   NZ, fdc_init_clear_ints ; real interrupt consumed, check for more
fdc_init_ints_done:

    ; Set data rate via DCR
    PUSH HL
    PUSH DE
    LD   DE, FDC_OFF_DATARATE
    ADD  HL, DE
    LD   A, (HL)
    POP  DE
    POP  HL
    OUT  (FDC_PORT_DCR), A

    ; Send Specify command (step rate, head load/unload times, non-DMA)
    LD   A, FDC_CMD_SPECIFY
    CALL fdc_send_byte
    JP   C, fdc_init_fail
    LD   A, FDC_SPECIFY_BYTE1
    CALL fdc_send_byte
    JP   C, fdc_init_fail
    LD   A, FDC_SPECIFY_BYTE2
    CALL fdc_send_byte
    JP   C, fdc_init_fail

    ; Motor on (includes spin-up delay)
    CALL fdc_motor_on
    ; Recalibrate (seek to track 0).
    ; Double recalibrate: the WD37C65 RECALIBRATE steps at most 77 tracks.
    ; On 80-track drives, a second attempt ensures track 0 is reached.
    CALL fdc_recalibrate
    JP   C, fdc_init_fail
    CALL fdc_recalibrate
    JP   C, fdc_init_fail
    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

fdc_init_fail:
    POP  DE
    POP  BC
    LD   A, ERR_IO
    LD   HL, 0
    RET

; ------------------------------------------------------------
; fdc_readblock
; Read one 512-byte block from floppy at the current LBA position.
; Inputs:
;   B  - physical device ID
;   DE - pointer to 512-byte destination buffer
; Outputs:
;   A  - ERR_SUCCESS or ERR_IO
;   HL - 0
; Preserves: BC, DE
; ------------------------------------------------------------
fdc_readblock:
    PUSH BC                     ; [1] preserve BC
    PUSH DE                     ; [2] preserve DE (original buffer ptr)
    PUSH DE                     ; [3] save buffer ptr for data phase

    LD   A, FDC_CMD_READ
    CALL fdc_prepare_rw         ; HL = user data ptr, command sent
    JP   C, fdc_readblock_prep_err ; command phase failed

    ; Swap user data ptr onto stack, get buffer ptr for data phase
    EX   (SP), HL               ; [3] now = user data ptr; HL = buffer ptr
    EX   DE, HL                 ; DE = buffer ptr
    LD   B, 0                   ; 256 iterations
    CALL fdc_read_data_256
    JP   C, fdc_readblock_data_err ; timeout during transfer
    CALL fdc_read_data_256
    JP   C, fdc_readblock_data_err ; timeout during transfer

    ; Result phase (handles EOT=R termination with ST1 EN as success)
    CALL fdc_check_result       ; A = ERR_SUCCESS or ERR_IO
    OR   A
    JP   NZ, fdc_readblock_fail

    ; Advance LBA by 1
    POP  HL                     ; [3] HL = user data ptr
    CALL fdc_inc_lba
    XOR  A
    LD   H, A
    LD   L, A
    JP   fdc_readblock_done
fdc_readblock_prep_err:
    POP  DE                     ; [3] discard saved buffer ptr
    JP   fdc_readblock_err
fdc_readblock_data_err:
    ; FDC is in result phase — read and discard result bytes
    CALL fdc_check_result
fdc_readblock_fail:
    POP  HL                     ; [3] discard user data ptr
fdc_readblock_err:
    LD   A, ERR_IO
    LD   HL, 0
fdc_readblock_done:
    POP  DE                     ; [2] restore original DE
    POP  BC                     ; [1] restore BC
    RET

; ------------------------------------------------------------
; fdc_writeblock
; Write one 512-byte block to floppy at the current LBA position.
; Inputs:
;   B  - physical device ID
;   DE - pointer to 512-byte source buffer
; Outputs:
;   A  - ERR_SUCCESS or ERR_IO
;   HL - 0
; Preserves: BC, DE
; ------------------------------------------------------------
fdc_writeblock:
    PUSH BC                     ; [1] preserve BC
    PUSH DE                     ; [2] preserve DE (original source ptr)
    PUSH DE                     ; [3] save source ptr for data phase

    LD   A, FDC_CMD_WRITE
    CALL fdc_prepare_rw         ; HL = user data ptr, command sent
    JP   C, fdc_writeblock_prep_err ; command phase failed

    ; Swap user data ptr onto stack, get source ptr for data phase
    EX   (SP), HL               ; [3] now = user data ptr; HL = source ptr
    EX   DE, HL                 ; DE = source ptr
    LD   B, 0                   ; 256 iterations
    CALL fdc_write_data_256
    JP   C, fdc_writeblock_fail ; timeout during transfer
    CALL fdc_write_data_256
    JP   C, fdc_writeblock_fail ; timeout during transfer

    ; Result phase (handles EOT=R termination with ST1 EN as success)
    CALL fdc_check_result       ; A = ERR_SUCCESS or ERR_IO
    OR   A
    JP   NZ, fdc_writeblock_fail

    ; Advance LBA by 1
    POP  HL                     ; [3] HL = user data ptr
    CALL fdc_inc_lba
    XOR  A
    LD   H, A
    LD   L, A
    JP   fdc_writeblock_done
fdc_writeblock_prep_err:
    POP  DE                     ; [3] discard saved source ptr
    JP   fdc_writeblock_err
fdc_writeblock_fail:
    POP  HL                     ; [3] discard user data ptr
fdc_writeblock_err:
    LD   A, ERR_IO
    LD   HL, 0
fdc_writeblock_done:
    POP  DE                     ; [2] restore original DE
    POP  BC                     ; [1] restore BC
    RET

; ------------------------------------------------------------
; fdc_seek_lba
; Set the current LBA block position in the PDT user data.
; Inputs:
;   B  - physical device ID
;   DE - block number (16-bit LBA)
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; Preserves: BC, DE
; ------------------------------------------------------------
fdc_seek_lba:
    PUSH BC
    LD   A, B
    CALL find_physdev_by_id
    PUSH DE
    LD   DE, PHYSDEV_OFF_DATA + FDC_OFF_LBA
    ADD  HL, DE
    POP  DE
    LD   (HL), E                ; LBA low
    INC  HL
    LD   (HL), D                ; LBA high
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; fdc_inc_lba
; Increment the 2-byte LBA position in user data.
; FDC_OFF_LBA is 0, so HL points directly at LBA low byte.
; Inputs:
;   HL - pointer to user data (= pointer to LBA low byte)
; Outputs:
;   (none)
; Preserves: AF, BC, DE (HL incremented by 1 on low-byte overflow)
; ------------------------------------------------------------
fdc_inc_lba:
    INC  (HL)                   ; LBA low byte
    RET  NZ                     ; no carry, done
    INC  HL
    INC  (HL)                   ; LBA high byte (carry)
    RET

; ------------------------------------------------------------
; fdc_bgetpos
; Get the current block position.
; Inputs:
;   B  - physical device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - block position
; Preserves: BC, DE
; ------------------------------------------------------------
fdc_bgetpos:
    LD   DE, PHYSDEV_OFF_DATA + FDC_OFF_LBA
    JP   common_bgetpos

; ------------------------------------------------------------
; fdc_bgetsize
; Write total device capacity in bytes (4-byte LE) to buffer.
; size = cylinders * heads * SPT * 512
; Inputs:
;   B  - physical device ID
;   DE - pointer to 4-byte output buffer
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; Preserves: BC
; ------------------------------------------------------------
fdc_bgetsize:
    PUSH BC                     ; preserve caller's BC
    PUSH DE                     ; save output buffer pointer

    LD   A, B
    CALL find_physdev_by_id
    LD   DE, PHYSDEV_OFF_DATA + FDC_OFF_SPT
    ADD  HL, DE                 ; HL -> SPT in user data
    LD   C, (HL)                ; C = SPT
    INC  HL
    LD   B, (HL)                ; B = heads
    INC  HL                     ; skip SECSIZE
    INC  HL
    LD   A, (HL)                ; A = cylinders

    ; Multiply cylinders * SPT -> HL (8x8 -> 16-bit)
    LD   HL, 0
    LD   D, 0
    LD   E, C                   ; DE = SPT (16-bit)
    PUSH BC                     ; save B = heads
    LD   B, 8                   ; 8 bits in multiplier
fdc_bgs_mul:
    ADD  HL, HL                 ; shift result left
    ADD  A, A                   ; shift cylinders MSB into carry
    JP   NC, fdc_bgs_mul_skip
    ADD  HL, DE                 ; add SPT
fdc_bgs_mul_skip:
    DEC  B
    JP   NZ, fdc_bgs_mul
    ; HL = cylinders * SPT

    POP  BC                     ; B = heads
    DEC  B
    JP   Z, fdc_bgs_heads_done
    ADD  HL, HL                 ; *2 for 2 heads
fdc_bgs_heads_done:
    ; HL = total_blocks (cylinders * heads * SPT)
    ; *512 = shift left 9 = *2 then store as [carry:H:L:0x00]
    ADD  HL, HL                 ; total_blocks * 2, carry = bit 16
    LD   A, 0                   ; preserve carry (LD doesn't affect flags)
    ADC  A, A                   ; A = carry bit = byte 3

    LD   B, A                   ; save byte 3
    POP  DE                     ; DE = output buffer
    XOR  A
    LD   (DE), A                ; byte 0 = 0x00
    INC  DE
    LD   (DE), L                ; byte 1
    INC  DE
    LD   (DE), H                ; byte 2
    INC  DE
    LD   (DE), B                ; byte 3

    POP  BC                     ; restore caller's BC
    XOR  A                      ; A = ERR_SUCCESS
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; Device Function Table for FDC (block DFT, 9 slots)
; ------------------------------------------------------------
dft_fdc:
    DEFW fdc_init               ; slot 0: Initialize
    DEFW null_getstatus         ; slot 1: GetStatus (always ready)
    DEFW fdc_readblock          ; slot 2: ReadBlock
    DEFW fdc_writeblock         ; slot 3: WriteBlock
    DEFW fdc_seek_lba           ; slot 4: Seek
    DEFW fdc_bgetpos            ; slot 5: GetPosition
    DEFW fdc_bgetsize           ; slot 6: GetLength
    DEFW un_error               ; slot 7: SetSize
    DEFW un_error               ; slot 8: Close

; ============================================================
; PDTENTRY_FDC ID, NAME, DRIVE, SPT, HEADS, SECSIZE, CYLS, GPL, DATARATE
; Macro: Declare a ROM PDT entry for a WD37C65 floppy disk drive.
; Arguments:
;   ID       - physical device ID (PHYSDEV_ID_FDC)
;   NAME     - 2-character device name string (e.g. "FD")
;   DRIVE    - drive number (0-3)
;   SPT      - sectors per track (e.g. 18 for 1.44MB HD)
;   HEADS    - number of heads (1 or 2)
;   SECSIZE  - sector size code (2 = 512 bytes)
;   CYLS     - total cylinders (e.g. 80)
;   GPL      - gap length for read/write (e.g. 0x1B)
;   DATARATE - DCR data rate value (0=500k, 1=300k, 2=250k)
; ============================================================
PDTENTRY_FDC macro ID, NAME, DRIVE, SPT, HEADS, SECSIZE, CYLS, GPL, DATARATE
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0, 0, 0           ; PHYSDEV_OFF_NAME (7 bytes: 2-char name + 5 nulls)
    DEFB DEVCAP_BLOCK_IN | DEVCAP_BLOCK_OUT ; PHYSDEV_OFF_CAPS
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_fdc                        ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFW 0                              ; FDC_OFF_LBA: current LBA (2 bytes, zeroed)
    DEFB DRIVE                          ; FDC_OFF_DRIVE: drive number
    DEFB SPT                            ; FDC_OFF_SPT: sectors per track
    DEFB HEADS                          ; FDC_OFF_HEADS: number of heads
    DEFB SECSIZE                        ; FDC_OFF_SECSIZE: sector size code
    DEFB CYLS                           ; FDC_OFF_CYLINDERS: total cylinders
    DEFB GPL                            ; FDC_OFF_GPL: gap length
    DEFB DATARATE                       ; FDC_OFF_DATARATE: DCR data rate
    DEFB 0                              ; FDC_OFF_CUR_CYL: current cylinder (runtime)
    DEFB 0                              ; FDC_OFF_MOTOR: motor state (runtime)
    DEFB 0                              ; FDC_OFF_TGT_CYL: target cyl (I/O scratch)
    DEFB 0                              ; FDC_OFF_TGT_HEAD: target head (I/O scratch)
    DEFB 0                              ; FDC_OFF_TGT_SECTOR: target sector (I/O scratch)
    DEFS 3, 0                           ; padding to fill 17-byte user data field
endm

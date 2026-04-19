; ============================================================
; bubble.asm - Intel 7220 Bubble Memory block device driver
; ============================================================
; Converts the sample/bblbas.asm bubble memory routines into a
; NostOS block device driver. 128KB capacity = 256 blocks of
; 512 bytes. Each NostOS block = 8 bubble pages of 64 bytes.
;
; Hardware: 7220 controller, ports 0x10 (data FIFO), 0x11 (cmd/status)
; Cannot be tested in emulator — hardware only.
;
; 7220 register values and command sequences referenced from
; SBC-85 bubble memory routines by Craig Andrews, 2020.
;
; PDT user data:
;   +0  CUR_BLOCK (2 bytes, LE): current block position
;
; Temporary variables (KERN_TEMP_SPACE + 74..77)
; Shares offsets with ramdisk/tinyramdisk; safe because these
; are per-call temporaries and driver calls are never concurrent.
; Must NOT overlap fs_dir temps (64-73) or fs_open temps (80-85).
bbl_temp_slot       EQU KERN_TEMP_SPACE + 74   ; PDT slot pointer (2 bytes)
bbl_temp_bar_lo     EQU KERN_TEMP_SPACE + 76   ; BAR low byte (1 byte)
bbl_temp_bar_hi     EQU KERN_TEMP_SPACE + 77   ; BAR high byte (1 byte)

; ============================================================
; 7220 Hardware Constants
; ============================================================

BBL_DAT             EQU 0x10       ; bubble data FIFO port
BBL_CS              EQU 0x11       ; bubble command/status port

; 7220 register addresses (written to BBL_CS to select register)
BBL_RLA             EQU 0x0B       ; block length register LSB address
; Registers auto-increment: RLA, RHA, ERA, ARLA, ARHA

; Default register values
BBL_RLV             EQU 0x01       ; default 1 page block length (for init)
BBL_RHV             EQU 0x10       ; BLR MSB: 64-byte pages, 255 pages max
BBL_EV              EQU 0x40       ; enable: no parity, no IRQ, no DMA, ECC on
BBL_RHVI            EQU 0x10       ; BLR MSB during init

; Status register bit masks
BBL_SR_BUSY         EQU 0x80       ; busy flag
BBL_SR_OPC          EQU 0x40       ; opcode complete
BBL_SR_FIFO         EQU 0x01       ; FIFO available

; NostOS block = 8 bubble pages (8 * 64 = 512 bytes)
BBL_PAGES_PER_BLOCK EQU 8

; Bubble PDT user-data offsets
BBL_OFF_CUR_BLOCK   EQU 0          ; 2 bytes: current block position (LE)

; ============================================================
; Device Function Table
; ============================================================
dft_bubble:
    DEFW bbl_init           ; slot 0: Initialize (hardware init with double-retry)
    DEFW null_init          ; slot 1: GetStatus
    DEFW bbl_bread          ; slot 2: ReadBlock
    DEFW bbl_bwrite         ; slot 3: WriteBlock
    DEFW bbl_bseek          ; slot 4: Seek
    DEFW bbl_bgetpos        ; slot 5: GetPosition
    DEFW bbl_bgetsize       ; slot 6: GetLength
    DEFW un_error           ; slot 7: SetSize (not supported)
    DEFW un_error           ; slot 8: Close (not supported)

; ============================================================
; PDTENTRY_BUBBLE ID, NAME
; Macro: Declare a ROM PDT entry for bubble memory.
; ============================================================
PDTENTRY_BUBBLE macro ID, NAME
    DEFW 0                              ; PHYSDEV_OFF_NEXT
    DEFB ID                             ; PHYSDEV_OFF_ID
    DEFM NAME, 0, 0, 0, 0              ; PHYSDEV_OFF_NAME (7 bytes: 3-char name + 4 nulls)
    DEFB DEVCAP_BLOCK_IN | DEVCAP_BLOCK_OUT ; PHYSDEV_OFF_CAPS (read-write)
    DEFB 0                              ; PHYSDEV_OFF_PARENT
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW dft_bubble                     ; PHYSDEV_OFF_DFT
    ; User data (17 bytes):
    DEFW 0                              ; BBL_OFF_CUR_BLOCK
    DEFS 15, 0                          ; padding
endm

; ============================================================
; bbl_get_slot
; Find PDT slot for device B and save slot pointer.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   (bbl_temp_slot) = slot pointer
; Clobbers: HL, BC
; ============================================================
bbl_get_slot:
    LD   A, B
    CALL find_physdev_by_id
    LD   A, H
    OR   L
    JP   Z, bbl_get_slot_err
    LD   (bbl_temp_slot), HL
    XOR  A
    RET
bbl_get_slot_err:
    LD   A, ERR_INVALID_DEVICE
    RET

; ============================================================
; bbl_init
; Initialize the 7220 bubble memory controller.
; Does double-retry (init often fails first time).
; Inputs:
;   B  - device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_IO
;   HL - 0
; ============================================================
bbl_init:
    CALL bbl_hw_init
    CP   BBL_SR_OPC             ; 0x40 = success
    JP   Z, bbl_init_ok
    CP   0x42                   ; 0x42 = success with parity
    JP   Z, bbl_init_ok
    ; First try failed — retry once
    CALL bbl_hw_init
    CP   BBL_SR_OPC
    JP   Z, bbl_init_ok
    CP   0x42
    JP   Z, bbl_init_ok
    ; Both attempts failed
    LD   A, ERR_IO
    LD   HL, 0
    RET
bbl_init_ok:
    XOR  A                      ; ERR_SUCCESS
    LD   HL, 0
    RET

; ============================================================
; bbl_hw_init
; Low-level 7220 initialization sequence.
; Outputs:
;   A  - 7220 status (0x40 = success, 0x42 = parity, 0xE* = error)
; Clobbers: DE
; ============================================================
bbl_hw_init:
    PUSH DE
    ; Load parametric register defaults for init
    LD   A, BBL_RLA             ; set register pointer to BLR LSB
    OUT  (BBL_CS), A
    LD   A, BBL_RLV             ; block length LSB = 1 page
    OUT  (BBL_DAT), A
    LD   A, BBL_RHVI            ; block length MSB (init value)
    OUT  (BBL_DAT), A
    LD   A, BBL_EV              ; enable register
    OUT  (BBL_DAT), A
    LD   A, 0                   ; address LSB = 0
    OUT  (BBL_DAT), A
    LD   A, 0                   ; address MSB = 0
    OUT  (BBL_DAT), A

    ; Abort any commands being processed.
    ; If abort doesn't return clean 0x40, skip to done — caller (bbl_init)
    ; will retry the entire bbl_hw_init sequence.
    CALL bbl_abort
    CP   BBL_SR_OPC
    JP   NZ, bbl_hw_init_done

    ; Reload parametric registers after abort
    LD   A, BBL_RLA
    OUT  (BBL_CS), A
    LD   A, BBL_RLV
    OUT  (BBL_DAT), A
    LD   A, BBL_RHVI
    OUT  (BBL_DAT), A
    LD   A, BBL_EV
    OUT  (BBL_DAT), A
    LD   A, 0
    OUT  (BBL_DAT), A
    LD   A, 0
    OUT  (BBL_DAT), A

    ; Send Initialize Bubble command
    LD   DE, 0xFFFF             ; timeout counter
    LD   A, 0x11                ; initialize bubble command
    OUT  (BBL_CS), A

    ; 7220 busy-wait pattern: RLCA puts status bit 7 (BUSY) into carry.
    ; Carry SET = controller is busy (accepted command) → proceed to poll.
    ; Carry CLEAR = not yet busy → keep waiting for acknowledgement.
bbl_hw_init_busy:
    IN   A, (BBL_CS)            ; get status
    RLCA                        ; bit 7 (BUSY) → carry
    JP   C, bbl_hw_init_poll    ; BUSY=1: command accepted, poll for completion
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, bbl_hw_init_busy
    LD   A, 0xE5               ; timeout error
    JP   bbl_hw_init_done

bbl_hw_init_poll:
    IN   A, (BBL_CS)
    CP   BBL_SR_OPC             ; opcode complete?
    JP   Z, bbl_hw_init_done
    AND  0x30                   ; check timing error bits
    CP   0x30
    JP   Z, bbl_hw_init_tmerr  ; timing error — bail
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, bbl_hw_init_poll
    LD   A, 0xE6               ; timeout error
    JP   bbl_hw_init_done

bbl_hw_init_tmerr:
    IN   A, (BBL_CS)           ; read final status

bbl_hw_init_done:
    POP  DE
    RET

; ============================================================
; bbl_abort
; Send abort command to the 7220 (called twice internally).
; Outputs:
;   A  - 7220 status
; Clobbers: DE
; ============================================================
bbl_abort:
    CALL bbl_abort1
    CALL bbl_abort1
    RET

bbl_abort1:
    PUSH DE
    LD   DE, 0xFFFF
    LD   A, 0x19                ; abort command
    OUT  (BBL_CS), A
bbl_abort1_busy:
    IN   A, (BBL_CS)
    RLCA                        ; bit 7 (BUSY) → carry
    JP   C, bbl_abort1_poll     ; BUSY=1: command accepted, poll for completion
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, bbl_abort1_busy
    LD   A, 0xE1               ; timeout
    JP   bbl_abort1_done
bbl_abort1_poll:
    IN   A, (BBL_CS)
    CP   BBL_SR_OPC
    JP   Z, bbl_abort1_done
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, bbl_abort1_poll
    LD   A, 0xE2               ; timeout
bbl_abort1_done:
    POP  DE
    RET

; ============================================================
; bbl_fifo_reset
; Send FIFO reset command to the 7220.
; Outputs:
;   A  - 7220 status
; Clobbers: DE
; ============================================================
bbl_fifo_reset:
    PUSH DE
    LD   DE, 0xFFFF
    LD   A, 0x1D                ; FIFO reset command
    OUT  (BBL_CS), A
bbl_ffr_busy:
    IN   A, (BBL_CS)
    RLCA                        ; bit 7 (BUSY) → carry
    JP   C, bbl_ffr_poll        ; BUSY=1: command accepted, poll for completion
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, bbl_ffr_busy
    LD   A, 0xE3               ; timeout
    JP   bbl_ffr_done
bbl_ffr_poll:
    IN   A, (BBL_CS)
    CP   BBL_SR_OPC
    JP   Z, bbl_ffr_done
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, bbl_ffr_poll
    LD   A, 0xE4               ; timeout
bbl_ffr_done:
    POP  DE
    RET

; ============================================================
; bbl_load_params
; Load the 7220 parametric registers for a block I/O operation.
; Uses bbl_temp_bar_lo/hi for the bubble address.
; Block length is always BBL_PAGES_PER_BLOCK (8 pages = 512 bytes).
; Clobbers: A
; ============================================================
bbl_load_params:
    LD   A, BBL_RLA             ; set register pointer
    OUT  (BBL_CS), A
    LD   A, BBL_PAGES_PER_BLOCK ; block length LSB = 8 pages
    OUT  (BBL_DAT), A
    LD   A, BBL_RHV             ; block length MSB (64-byte pages)
    OUT  (BBL_DAT), A
    LD   A, BBL_EV              ; enable register
    OUT  (BBL_DAT), A
    LD   A, (bbl_temp_bar_lo)   ; address LSB
    OUT  (BBL_DAT), A
    LD   A, (bbl_temp_bar_hi)   ; address MSB
    OUT  (BBL_DAT), A
    IN   A, (BBL_CS)            ; read status before return
    RET

; ============================================================
; bbl_block_to_bar
; Convert NostOS block number to bubble BAR address.
; Block N → BAR = N * 8 (8 pages per block).
; Inputs:
;   (bbl_temp_slot) = PDT slot pointer
; Outputs:
;   (bbl_temp_bar_lo), (bbl_temp_bar_hi) set
;   A  - ERR_SUCCESS or ERR_EOF
; Clobbers: BC, DE, HL
; ============================================================
bbl_block_to_bar:
    LD   HL, (bbl_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + BBL_OFF_CUR_BLOCK
    ADD  HL, BC
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = cur_block

    ; Check bounds: cur_block must be < 256 (128KB / 512 = 256 blocks).
    ; D must be 0; if so, E (a byte) is always < 256.
    LD   A, D
    OR   A
    JP   NZ, bbl_block_eof     ; block >= 256, out of range

    ; BAR = cur_block * 8 = E << 3
    ; BAR high = E >> 5, BAR low = (E << 3) & 0xFF
    LD   A, E
    RRCA
    RRCA
    RRCA
    RRCA
    RRCA                        ; rotate right 5 = shift right 5
    AND  0x07                   ; isolate top 3 bits of original E
    LD   (bbl_temp_bar_hi), A

    LD   A, E
    RLCA
    RLCA
    RLCA                        ; rotate left 3 = shift left 3
    AND  0xF8                   ; isolate low 5 bits of original E, shifted up
    LD   (bbl_temp_bar_lo), A

    XOR  A                      ; ERR_SUCCESS
    RET

bbl_block_eof:
    LD   A, ERR_EOF
    RET

; ============================================================
; bbl_inc_curblock
; Increment the 16-bit cur_block in the PDT slot.
; Inputs:
;   (bbl_temp_slot) = PDT slot pointer
; Clobbers: A, BC, HL
; ============================================================
bbl_inc_curblock:
    LD   HL, (bbl_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + BBL_OFF_CUR_BLOCK
    ADD  HL, BC
    LD   A, (HL)
    INC  A
    LD   (HL), A
    JP   NZ, bbl_inc_done
    INC  HL
    LD   A, (HL)
    INC  A
    LD   (HL), A
bbl_inc_done:
    RET

; ============================================================
; bbl_bgetpos
; Get the current block position.
; Inputs:
;   B  - device ID
; Outputs:
;   A  - ERR_SUCCESS or ERR_INVALID_DEVICE
;   HL - block position
; ============================================================
bbl_bgetpos:
    LD   DE, PHYSDEV_OFF_DATA + BBL_OFF_CUR_BLOCK
    JP   common_bgetpos

; ============================================================
; bbl_bseek
; Set current block position.
; Inputs:
;   B  - device ID
;   DE - block number
; Outputs:
;   A  - ERR_SUCCESS or error
;   HL - 0
; ============================================================
bbl_bseek:
    PUSH DE
    CALL bbl_get_slot
    POP  DE
    OR   A
    JP   NZ, bbl_exit
    LD   HL, (bbl_temp_slot)
    LD   BC, PHYSDEV_OFF_DATA + BBL_OFF_CUR_BLOCK
    ADD  HL, BC
    LD   A, E
    LD   (HL), A
    INC  HL
    LD   A, D
    LD   (HL), A
    XOR  A
bbl_exit:
    LD   HL, 0
    RET

; ============================================================
; bbl_bread
; Read one 512-byte block from bubble memory into a buffer.
; Inputs:
;   B  - device ID
;   DE - 512-byte destination buffer
; Outputs:
;   A  - ERR_SUCCESS / ERR_EOF / ERR_IO / ERR_INVALID_DEVICE
;   HL - 0
; ============================================================
bbl_bread:
    PUSH DE                     ; save dest buffer

    CALL bbl_get_slot
    OR   A
    JP   NZ, bbl_err_pop

    CALL bbl_block_to_bar
    OR   A
    JP   NZ, bbl_eof_pop

    ; Perform the bubble read
    SAFE_DI                     ; disable interrupts (timing critical)

    CALL bbl_abort
    CALL bbl_fifo_reset
    XOR  BBL_SR_OPC             ; FIFO reset must return exactly 0x40;
    JP   NZ, bbl_bread_err      ; 0x42 (parity) only applies to data commands, not here

    CALL bbl_load_params

    ; Issue read command and transfer 512 bytes
    POP  DE                     ; DE = dest buffer
    PUSH DE                     ; re-push for cleanup
    LD   HL, 512                ; byte count
    CALL bbl_hw_get             ; read data from bubble to (DE), HL bytes

    ; Wait for not-busy
    LD   HL, 0xFFFF
bbl_bread_wait:
    IN   A, (BBL_CS)
    RLCA
    JP   NC, bbl_bread_chk      ; not busy
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, bbl_bread_wait

bbl_bread_chk:
    IN   A, (BBL_CS)            ; final status
    SAFE_EI

    ; Check status: 0x40 or 0x42 = success
    CP   BBL_SR_OPC
    JP   Z, bbl_bread_ok
    CP   0x42
    JP   Z, bbl_bread_ok

    ; Error
    POP  DE
    LD   A, ERR_IO
    LD   HL, 0
    RET

bbl_bread_err:
    SAFE_EI
    POP  DE
    LD   A, ERR_IO
    LD   HL, 0
    RET

bbl_bread_ok:
    POP  DE
    CALL bbl_inc_curblock
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; bbl_bwrite
; Write a 512-byte block from buffer to bubble memory.
; Inputs:
;   B  - device ID
;   DE - 512-byte source buffer
; Outputs:
;   A  - ERR_SUCCESS / ERR_EOF / ERR_IO / ERR_INVALID_DEVICE
;   HL - 0
; ============================================================
bbl_bwrite:
    PUSH DE                     ; save source buffer

    CALL bbl_get_slot
    OR   A
    JP   NZ, bbl_err_pop

    CALL bbl_block_to_bar
    OR   A
    JP   NZ, bbl_eof_pop

    ; Perform the bubble write
    SAFE_DI

    CALL bbl_abort
    CALL bbl_fifo_reset
    XOR  BBL_SR_OPC             ; FIFO reset must return exactly 0x40;
    JP   NZ, bbl_bwrite_err     ; 0x42 (parity) only applies to data commands, not here

    CALL bbl_load_params

    ; Issue write command and transfer 512 bytes
    POP  DE                     ; DE = source buffer
    PUSH DE                     ; re-push for cleanup
    LD   HL, 512
    CALL bbl_hw_put             ; write data from (DE) to bubble, HL bytes

    ; Wait for not-busy
    LD   HL, 0xFFFF
bbl_bwrite_wait:
    IN   A, (BBL_CS)
    RLCA
    JP   NC, bbl_bwrite_chk
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, bbl_bwrite_wait

bbl_bwrite_chk:
    IN   A, (BBL_CS)            ; final status
    SAFE_EI

    CP   BBL_SR_OPC
    JP   Z, bbl_bwrite_ok
    CP   0x42
    JP   Z, bbl_bwrite_ok

    POP  DE
    LD   A, ERR_IO
    LD   HL, 0
    RET

bbl_bwrite_err:
    SAFE_EI
    POP  DE
    LD   A, ERR_IO
    LD   HL, 0
    RET

bbl_bwrite_ok:
    POP  DE
    CALL bbl_inc_curblock
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ============================================================
; Shared error exits
; ============================================================
bbl_eof_pop:
    POP  DE
    LD   A, ERR_EOF
    LD   HL, 0
    RET

bbl_err_pop:
    POP  DE
    LD   HL, 0
    RET                         ; A = error code from bbl_get_slot

; ============================================================
; bbl_bgetsize
; Return total device size in bytes (4-byte LE) to buffer at DE.
; 128KB = 0x00020000
; Inputs:
;   B  - device ID
;   DE - pointer to 4-byte output buffer
; Outputs:
;   A  - ERR_SUCCESS or error
;   HL - 0
; ============================================================
bbl_bgetsize:
    ; Write 128KB = 0x00020000 as 4-byte little-endian
    XOR  A
    LD   (DE), A                ; byte 0: 0x00
    INC  DE
    LD   (DE), A                ; byte 1: 0x00
    INC  DE
    LD   A, 0x02
    LD   (DE), A                ; byte 2: 0x02
    INC  DE
    XOR  A
    LD   (DE), A                ; byte 3: 0x00

    ; A already 0 = ERR_SUCCESS
    LD   H, A
    LD   L, A
    RET

; ============================================================
; bbl_hw_get
; Read data from bubble FIFO into RAM.
; Must be called after bbl_load_params and with interrupts disabled.
; Inputs:
;   DE - destination RAM address
;   HL - number of bytes to read (must be multiple of 64)
; Outputs:
;   A  - 7220 status on error, undefined on success
; Clobbers: BC, DE, HL
; ============================================================
bbl_hw_get:
    PUSH DE
    PUSH BC
    LD   BC, 0xFFFF             ; timeout counter
    LD   A, 0x12                ; read bubble data command
    OUT  (BBL_CS), A

    ; Wait for busy (indicates command accepted)
bbl_get_waitbusy:
    DEC  BC
    LD   A, B
    OR   C
    LD   A, 0xEA               ; preload error
    JP   Z, bbl_get_done
    IN   A, (BBL_CS)
    RLCA                        ; busy bit into carry
    JP   NC, bbl_get_waitbusy   ; wait until busy

    ; Transfer loop: read bytes from FIFO
bbl_get_poll:
    IN   A, (BBL_CS)
    RRCA                        ; FIFO available into carry
    JP   C, bbl_get_byte        ; data available

    IN   A, (BBL_CS)
    RLCA                        ; busy bit
    LD   A, 0xEB
    JP   NC, bbl_get_done       ; not busy = error

    DEC  BC
    LD   A, B
    OR   C
    LD   A, 0xEC
    JP   Z, bbl_get_done        ; timeout
    JP   bbl_get_poll

bbl_get_byte:
    LD   BC, 0xFFFF             ; reset timeout
    IN   A, (BBL_DAT)           ; read byte from bubble FIFO
    LD   (DE), A                ; store to destination
    INC  DE

    DEC  HL                     ; decrement byte counter
    LD   A, H
    OR   L
    JP   NZ, bbl_get_poll       ; more bytes to read

    ; All bytes read — no partial page flush needed since we always
    ; read exact multiples of 64 bytes (512 = 8 * 64).

bbl_get_done:
    POP  BC
    POP  DE
    RET

; ============================================================
; bbl_hw_put
; Write data from RAM into bubble FIFO.
; Must be called after bbl_load_params and with interrupts disabled.
; Inputs:
;   DE - source RAM address
;   HL - number of bytes to write (must be multiple of 64)
; Outputs:
;   A  - 7220 status on error, undefined on success
; Clobbers: BC, DE, HL
; ============================================================
bbl_hw_put:
    PUSH DE
    PUSH BC
    LD   BC, 0xFFFF             ; timeout counter
    LD   A, 0x13                ; write bubble data command
    OUT  (BBL_CS), A

    ; Wait for busy (indicates command accepted)
bbl_put_waitbusy:
    DEC  BC
    LD   A, B
    OR   C
    LD   A, 0xEA
    JP   Z, bbl_put_done
    IN   A, (BBL_CS)
    RLCA
    JP   NC, bbl_put_waitbusy

    ; Transfer loop: write bytes to FIFO
bbl_put_poll:
    IN   A, (BBL_CS)
    RRCA                        ; FIFO ready into carry
    JP   C, bbl_put_byte        ; room in FIFO

    IN   A, (BBL_CS)
    RLCA
    LD   A, 0xEB
    JP   NC, bbl_put_done       ; not busy = error

    DEC  BC
    LD   A, B
    OR   C
    LD   A, 0xEC
    JP   Z, bbl_put_done        ; timeout
    JP   bbl_put_poll

bbl_put_byte:
    LD   BC, 0xFFFF             ; reset timeout
    LD   A, (DE)                ; load byte from source
    OUT  (BBL_DAT), A           ; send to bubble FIFO
    INC  DE

    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, bbl_put_poll

    ; All bytes written — no partial page padding needed since we always
    ; write exact multiples of 64 bytes (512 = 8 * 64).

bbl_put_done:
    IN   A, (BBL_CS)            ; read final status
    POP  BC
    POP  DE
    RET

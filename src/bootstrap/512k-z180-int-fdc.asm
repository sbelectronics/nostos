; Bootstrap for interrupt-driven Z180 ASCI + WD37C65 FDC.
; Channels 0 and 1 are interrupt-driven via the Z180 internal
; vectored interrupt mechanism (IM 2).  FDC is the block device.
; At most one interrupt-driven UART per system (mutually exclusive
; with UART_SIO_INT_*, UART_ACIA_INT_*, UART_SCC_INT_*).

; ============================================================
; Include Device Drivers (assembled as part of kernel image)
; ============================================================
    INCLUDE "src/drivers/undev.asm"
    INCLUDE "src/drivers/nulldev.asm"
    INCLUDE "src/drivers/rnddev.asm"
;    INCLUDE "src/drivers/acia.asm"
    INCLUDE "src/drivers/fdc.asm"
    INCLUDE "src/drivers/ramdisk.asm"
    INCLUDE "src/drivers/z180_int.asm"
    INCLUDE "src/drivers/fs.asm"

; ============================================================
; Physical device table entries (ROM)
; ============================================================

physdev_fdc:
    PDTENTRY_FDC PHYSDEV_ID_FDC, "FD", 0, 18, 2, 2, 80, 0x1B, 0x00

physdev_nul:
    PDTENTRY_NUL PHYSDEV_ID_NUL, "NUL"

physdev_rnd:
    PDTENTRY_RND PHYSDEV_ID_RND, "RND"

physdev_un:
    PDTENTRY_UN PHYSDEV_ID_UN, "UN"

physdev_romdisk:
    PDTENTRY_ROMDISK PHYSDEV_ID_ROMD, "ROMD", 2, 31

physdev_ramdisk:
    PDTENTRY_RAMDISK PHYSDEV_ID_RAMD, "RAMD", 35, 63

physdev_z180a:
    PDTENTRY_Z180_INT PHYSDEV_ID_Z180A, "ASC0", 0
physdev_z180b:
    PDTENTRY_Z180_INT PHYSDEV_ID_Z180B, "ASC1", 1

; Table of ROM PDT pointers for devices_init.
; IMPORTANT: ASC0 must initialize before ASC1 because channel 0's
; init performs the I/O remap and clock setup that the ASCI
; register accesses depend on.
devices_rom_table:
    DEFW physdev_fdc
    DEFW physdev_nul
    DEFW physdev_rnd
    DEFW physdev_un
    DEFW physdev_romdisk
    DEFW physdev_ramdisk
    DEFW physdev_z180a
    DEFW physdev_z180b
devices_rom_table_end:

; ROM template for the six well-known logical device entries.
logdev_init_table:
    DEFB LOGDEV_ID_NUL
    DEFM "NUL", 0, 0
    DEFB PHYSDEV_ID_NUL, 0

    DEFB LOGDEV_ID_CONI
    DEFM "CONI", 0
    DEFB PHYSDEV_ID_Z180A, 0

    DEFB LOGDEV_ID_CONO
    DEFM "CONO", 0
    DEFB PHYSDEV_ID_Z180A, 0

    DEFB LOGDEV_ID_SERI
    DEFM "SERI", 0
    DEFB PHYSDEV_ID_UN, 0

    DEFB LOGDEV_ID_SERO
    DEFM "SERO", 0
    DEFB PHYSDEV_ID_UN, 0

    DEFB LOGDEV_ID_PRN
    DEFM "PRN", 0, 0
    DEFB PHYSDEV_ID_UN, 0
logdev_init_table_end:

; ROM automount table.
automount_table:
    DEFB PHYSDEV_ID_ROMD
    DEFM "A", 0, 0, 0, 0
    DEFB 1

    DEFB PHYSDEV_ID_FDC
    DEFM "C", 0, 0, 0, 0
    DEFB 0

    DEFB 0                      ; end sentinel

; ============================================================
; platform_init: set up vectored interrupt dispatch on the Z180.
;
; By the time this runs, both ASCI channels have been programmed
; (RIE set in STAT) and the ring-buffer bookkeeping is zeroed.
; What's left is the chip-wide interrupt plumbing:
;
;   1. Populate the Z180 internal interrupt vector table.  All
;      9 internal source slots get an entry — 7 spurious handlers
;      for sources we don't enable, plus the two real ASCI handlers.
;   2. Point the I register at the table's high byte.
;   3. Write the table's low byte to the IL register (port 0xF3).
;      Only bits 7:5 of IL are settable; bits 4:0 are forced to
;      zero by hardware, which is why Z180_INTVEC_TABLE has to be
;      32-byte aligned (the rest is filled in by the source ID
;      during the interrupt acknowledge cycle).
;   4. Switch the CPU to IM 2 and EI.
; ============================================================
platform_init:
    ; --- Vector table: spurious handler for the seven sources we
    ;     don't use (INT1, INT2, PRT0/1, DMA0/1, CSI/O) ---
    LD   HL, Z180_INTVEC_TABLE + Z180_VEC_OFF_INT1
    LD   (HL), z180_int_isr_spurious & 0xFF
    INC  HL
    LD   (HL), z180_int_isr_spurious >> 8
    LD   HL, Z180_INTVEC_TABLE + Z180_VEC_OFF_INT2
    LD   (HL), z180_int_isr_spurious & 0xFF
    INC  HL
    LD   (HL), z180_int_isr_spurious >> 8
    LD   HL, Z180_INTVEC_TABLE + Z180_VEC_OFF_PRT0
    LD   (HL), z180_int_isr_spurious & 0xFF
    INC  HL
    LD   (HL), z180_int_isr_spurious >> 8
    LD   HL, Z180_INTVEC_TABLE + Z180_VEC_OFF_PRT1
    LD   (HL), z180_int_isr_spurious & 0xFF
    INC  HL
    LD   (HL), z180_int_isr_spurious >> 8
    LD   HL, Z180_INTVEC_TABLE + Z180_VEC_OFF_DMA0
    LD   (HL), z180_int_isr_spurious & 0xFF
    INC  HL
    LD   (HL), z180_int_isr_spurious >> 8
    LD   HL, Z180_INTVEC_TABLE + Z180_VEC_OFF_DMA1
    LD   (HL), z180_int_isr_spurious & 0xFF
    INC  HL
    LD   (HL), z180_int_isr_spurious >> 8
    LD   HL, Z180_INTVEC_TABLE + Z180_VEC_OFF_CSIO
    LD   (HL), z180_int_isr_spurious & 0xFF
    INC  HL
    LD   (HL), z180_int_isr_spurious >> 8

    ; --- Vector table: the two real ASCI handlers ---
    LD   HL, Z180_INTVEC_TABLE + Z180_VEC_OFF_ASCI0
    LD   (HL), z180_int_isr_a & 0xFF
    INC  HL
    LD   (HL), z180_int_isr_a >> 8
    LD   HL, Z180_INTVEC_TABLE + Z180_VEC_OFF_ASCI1
    LD   (HL), z180_int_isr_b & 0xFF
    INC  HL
    LD   (HL), z180_int_isr_b >> 8

    ; --- I register = table base high byte ---
    LD   A, Z180_INTVEC_TABLE >> 8
    LD   I, A

    ; --- IL register = table base low byte ---
    ; (Z180_INTVEC_TABLE is 32-byte aligned so the low byte already
    ;  has bits 4:0 = 0; we can write it directly.)
    LD   B, 0
    LD   C, Z180_IL
    LD   A, Z180_INTVEC_TABLE & 0xFF
    OUT  (C), A

    IM   2
    EI
    RET

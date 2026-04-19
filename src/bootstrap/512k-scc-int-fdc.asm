; Bootstrap for interrupt-driven SCC + WD37C65 FDC.
; Channels A and B are interrupt-driven via the RST 38 / IM 1 vector.
; FDC is the block device.
; At most one interrupt-driven UART per system (mutually exclusive
; with UART_SIO_INT_*, UART_ACIA_INT_*).

; ============================================================
; Include Device Drivers (assembled as part of kernel image)
; ============================================================
    INCLUDE "src/drivers/undev.asm"
    INCLUDE "src/drivers/nulldev.asm"
    INCLUDE "src/drivers/rnddev.asm"
;    INCLUDE "src/drivers/acia.asm"
    INCLUDE "src/drivers/fdc.asm"
    INCLUDE "src/drivers/ramdisk.asm"
    INCLUDE "src/drivers/scc_int.asm"
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

physdev_scca:
    PDTENTRY_SCC_INT_A PHYSDEV_ID_SCCA, "SCCA", SCC_8N1_DIV16, SCC_TC_115200 & 0xFF, SCC_TC_115200 >> 8
physdev_sccb:
    PDTENTRY_SCC_INT_B PHYSDEV_ID_SCCB, "SCCB", SCC_8N1_DIV16, SCC_TC_115200 & 0xFF, SCC_TC_115200 >> 8

; Table of ROM PDT pointers for devices_init.
; IMPORTANT: SCCA must initialize BEFORE SCCB because SCCA's init
; programs WR9 (which is chip-wide).
devices_rom_table:
    DEFW physdev_fdc
    DEFW physdev_nul
    DEFW physdev_rnd
    DEFW physdev_un
    DEFW physdev_romdisk
    DEFW physdev_ramdisk
    DEFW physdev_scca
    DEFW physdev_sccb
devices_rom_table_end:

; ROM template for the six well-known logical device entries.
logdev_init_table:
    DEFB LOGDEV_ID_NUL
    DEFM "NUL", 0, 0
    DEFB PHYSDEV_ID_NUL, 0

    DEFB LOGDEV_ID_CONI
    DEFM "CONI", 0
    DEFB PHYSDEV_ID_SCCA, 0

    DEFB LOGDEV_ID_CONO
    DEFM "CONO", 0
    DEFB PHYSDEV_ID_SCCA, 0

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
; platform_init: install scc_int_isr into the RST 7 RAM vector
; and enable IM 1 interrupts.  By the time this runs, scc_int_init_a
; has issued the chip-wide WR9 MIE and both channels are programmed,
; so it is safe to let the ISR fire.
; ============================================================
platform_init:
    LD   HL, RST7_RAM_VEC + 1
    LD   (HL), scc_int_isr & 0xFF
    INC  HL
    LD   (HL), scc_int_isr >> 8
    IM   1
    EI
    RET

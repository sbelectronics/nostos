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
; platform_init: install the Z180 vectored interrupt table and EI.
; (See Z180_INT_INSTALL_VECTORS in src/drivers/z180_int.asm.)
; ============================================================
platform_init:
    Z180_INT_INSTALL_VECTORS
    RET

; --- Build-flag assertions (see mapper_config.asm for sentinel contract) ---
    IFNDEF MAPPER_74HCT670_CHOSEN
        ERROR "512k-z180-int-fdc bootstrap requires the default 74HCT670 mapper (no -DMAPPER_NONE or -DMAPPER_Z180_MMU)"
    ENDIF

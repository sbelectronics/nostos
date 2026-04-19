; Like 512K-SIO-INT but with the WD37C65 floppy controller as the
; block device instead of CompactFlash.  RC2014 standard SIO port map.

; ============================================================
; Include Device Drivers (assembled as part of kernel image)
; ============================================================
    INCLUDE "src/drivers/undev.asm"
    INCLUDE "src/drivers/nulldev.asm"
    INCLUDE "src/drivers/rnddev.asm"
;    INCLUDE "src/drivers/acia.asm"
    INCLUDE "src/drivers/fdc.asm"
    INCLUDE "src/drivers/ramdisk.asm"
    INCLUDE "src/drivers/sio_int.asm"
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

physdev_sioa:
    PDTENTRY_SIO_INT_A PHYSDEV_ID_SIOA, "SIOA", SIO_8N1_DIV64
physdev_siob:
    PDTENTRY_SIO_INT_B PHYSDEV_ID_SIOB, "SIOB", SIO_8N1_DIV64

; Table of ROM PDT pointers for devices_init.
devices_rom_table:
    DEFW physdev_fdc
    DEFW physdev_nul
    DEFW physdev_rnd
    DEFW physdev_un
    DEFW physdev_romdisk
    DEFW physdev_ramdisk
    DEFW physdev_sioa
    DEFW physdev_siob
devices_rom_table_end:

; ROM template for the six well-known logical device entries.
logdev_init_table:
    DEFB LOGDEV_ID_NUL
    DEFM "NUL", 0, 0
    DEFB PHYSDEV_ID_NUL, 0

    DEFB LOGDEV_ID_CONI
    DEFM "CONI", 0
    DEFB PHYSDEV_ID_SIOA, 0

    DEFB LOGDEV_ID_CONO
    DEFM "CONO", 0
    DEFB PHYSDEV_ID_SIOA, 0

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

automount_table:
    DEFB PHYSDEV_ID_ROMD
    DEFM "A", 0, 0, 0, 0
    DEFB 1

    DEFB PHYSDEV_ID_FDC
    DEFM "C", 0, 0, 0, 0
    DEFB 0

    DEFB 0                      ; end sentinel

; ============================================================
; platform_init: install sio_int_isr into RST 7 and enable IM 1.
; See 512k-sio-int-cf.asm for the full rationale; this is the
; FDC variant.
; ============================================================
platform_init:
    LD   HL, RST7_RAM_VEC + 1
    LD   (HL), sio_int_isr & 0xFF
    INC  HL
    LD   (HL), sio_int_isr >> 8
    IM   1
    EI
    RET

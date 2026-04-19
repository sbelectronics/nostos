; Like 512K-ACIA but with the interrupt-driven ACIA driver.
; Channel A is interrupt-driven via the RST 38 / IM 1 vector.
; At most one interrupt-driven UART per system (mutually exclusive
; with UART_SIO_INT_*).

; ============================================================
; Include Device Drivers (assembled as part of kernel image)
; ============================================================
    INCLUDE "src/drivers/undev.asm"
    INCLUDE "src/drivers/nulldev.asm"
    INCLUDE "src/drivers/rnddev.asm"
    INCLUDE "src/drivers/acia_int.asm"
    INCLUDE "src/drivers/cf.asm"
    INCLUDE "src/drivers/ramdisk.asm"
    INCLUDE "src/drivers/fs.asm"

; ============================================================
; Physical device table entries (ROM)
; ============================================================

physdev_cf:
    PDTENTRY_CF PHYSDEV_ID_CF, "CF", CF_BASE

physdev_acia:
    PDTENTRY_ACIA_INT PHYSDEV_ID_ACIA, "ACIA"

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

; Table of ROM PDT pointers for devices_init.
devices_rom_table:
    DEFW physdev_cf
    DEFW physdev_acia
    DEFW physdev_nul
    DEFW physdev_rnd
    DEFW physdev_un
    DEFW physdev_romdisk
    DEFW physdev_ramdisk
devices_rom_table_end:

; ROM template for the six well-known logical device entries.
logdev_init_table:
    DEFB LOGDEV_ID_NUL
    DEFM "NUL", 0, 0
    DEFB PHYSDEV_ID_NUL, 0

    DEFB LOGDEV_ID_CONI
    DEFM "CONI", 0
    DEFB PHYSDEV_ID_ACIA, 0

    DEFB LOGDEV_ID_CONO
    DEFM "CONO", 0
    DEFB PHYSDEV_ID_ACIA, 0

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

    DEFB PHYSDEV_ID_CF
    DEFM "C", 0, 0, 0, 0
    DEFB 0

    DEFB 0                      ; end sentinel

; ============================================================
; platform_init: install acia_int_isr into the RST 7 RAM vector
; and enable IM 1 interrupts.  Called once by kernel_init after
; all device inits — by this point the ACIA is programmed and the
; ring buffer is zeroed, so it is safe to let the ISR fire.
; ============================================================
platform_init:
    ; Patch only the target field of the JP thunk; workspace_init
    ; already wrote the 0xC3 JP opcode at +0.
    LD   HL, RST7_RAM_VEC + 1
    LD   (HL), acia_int_isr & 0xFF
    INC  HL
    LD   (HL), acia_int_isr >> 8
    IM   1
    EI
    RET

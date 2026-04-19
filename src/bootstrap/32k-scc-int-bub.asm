; 32K ROM variant for interrupt-driven SCC + Bubble Memory.
;
; Like 32k-scc-bub but uses the interrupt-driven scc_int driver
; instead of polled scc.asm.  Channels A and B are interrupt-driven
; via the RST 38 / IM 1 vector.  Mutually exclusive with all other
; interrupt-driven UART variants.
;
; Matches Scott's "Basic Bubble" computer:
;   * 32KB ROM
;   * 32KB RAM
;   * SCC (interrupt-driven)
;   * Bubble Memory
;
; This configuration does not have CompactFlash or floppy.

; ============================================================
; Include Device Drivers (assembled as part of kernel image)
; ============================================================
    INCLUDE "src/drivers/undev.asm"
    INCLUDE "src/drivers/nulldev.asm"
    INCLUDE "src/drivers/rnddev.asm"
    INCLUDE "src/drivers/scc_int.asm"
    INCLUDE "src/drivers/tinyramdisk.asm"
    INCLUDE "src/drivers/bubble.asm"
    INCLUDE "src/drivers/fs.asm"

; ============================================================
; Physical device table entries (ROM)
; ============================================================

physdev_nul:
    PDTENTRY_NUL PHYSDEV_ID_NUL, "NUL"

physdev_rnd:
    PDTENTRY_RND PHYSDEV_ID_RND, "RND"

physdev_un:
    PDTENTRY_UN PHYSDEV_ID_UN, "UN"

physdev_romdisk:
    PDTENTRY_TINYROMDISK PHYSDEV_ID_ROMD, "ROMD", 0x4000, 0x4000

physdev_bubble:
    PDTENTRY_BUBBLE PHYSDEV_ID_BBL, "BBL"

physdev_scca:
    PDTENTRY_SCC_INT_A PHYSDEV_ID_SCCA, "SCCA", SCC_8N1_DIV16, SCC_TC_115200 & 0xFF, SCC_TC_115200 >> 8
physdev_sccb:
    PDTENTRY_SCC_INT_B PHYSDEV_ID_SCCB, "SCCB", SCC_8N1_DIV16, SCC_TC_115200 & 0xFF, SCC_TC_115200 >> 8

; Table of ROM PDT pointers for devices_init.
; IMPORTANT: SCCA must initialize BEFORE SCCB because SCCA's init
; programs WR9 (which is chip-wide).
devices_rom_table:
    DEFW physdev_nul
    DEFW physdev_rnd
    DEFW physdev_un
    DEFW physdev_romdisk
    DEFW physdev_bubble
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

    DEFB PHYSDEV_ID_BBL
    DEFM "B", 0, 0, 0, 0
    DEFB 0

    DEFB 0                      ; end sentinel

; ============================================================
; platform_init: install scc_int_isr into RST 7 and enable IM 1.
; See 512k-scc-int-fdc.asm for the rationale; this is the 32K
; bubble-memory variant for Scott's Basic Bubble board.
; ============================================================
platform_init:
    LD   HL, RST7_RAM_VEC + 1
    LD   (HL), scc_int_isr & 0xFF
    INC  HL
    LD   (HL), scc_int_isr >> 8
    IM   1
    EI
    RET

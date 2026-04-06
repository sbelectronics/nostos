; 32K ROM variant for SCC + Bubble Memory (no memory mapper, uses tinyramdisk)
;
; This configuration matches Scott's "Basic Bubble" computer which has
;   * 32KB ROM
;   * 32KB RAM
;   * SCC
;   * Bubble Memory
;
; This configuration does not have compactflash or floppy

; ============================================================
; Include Device Drivers (assembled as part of kernel image)
; ============================================================
    INCLUDE "src/drivers/undev.asm"
    INCLUDE "src/drivers/nulldev.asm"
    INCLUDE "src/drivers/rnddev.asm"
    INCLUDE "src/drivers/scc.asm"
    INCLUDE "src/drivers/tinyramdisk.asm"
    INCLUDE "src/drivers/bubble.asm"
    INCLUDE "src/drivers/fs.asm"

; ============================================================
; Physical device table entries (ROM)
; All ROM PDT entries are declared here using driver macros.
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
    PDTENTRY_SCC PHYSDEV_ID_SCCA, "SCCA", SCC_CTRL_A, SCC_DATA_A, SCC_8N1_DIV16, SCC_TC_115200 & 0xFF, SCC_TC_115200 >> 8
physdev_sccb:
    PDTENTRY_SCC PHYSDEV_ID_SCCB, "SCCB", SCC_CTRL_B, SCC_DATA_B, SCC_8N1_DIV16, SCC_TC_115200 & 0xFF, SCC_TC_115200 >> 8

; Table of ROM PDT pointers for devices_init.
; Add a new entry here to register an additional ROM device.
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
; Each entry is LOGDEV_ENTRY_SIZE (8) bytes: ID (1), Name (5), PhysID (1), pad (1).
; logdev_table_init copies ID+name to RAM then calls DEV_LOG_ASSIGN with PhysID.
logdev_init_table:
    DEFB LOGDEV_ID_NUL          ; ID
    DEFM "NUL", 0, 0            ; Name: 3 chars + 2 nulls = 5 bytes
    DEFB PHYSDEV_ID_NUL, 0      ; PhysID, pad

    DEFB LOGDEV_ID_CONI         ; ID
    DEFM "CONI", 0              ; Name: 4 chars + null = 5 bytes
    DEFB PHYSDEV_ID_SCCA, 0     ; PhysID, pad

    DEFB LOGDEV_ID_CONO         ; ID
    DEFM "CONO", 0              ; Name: 4 chars + null = 5 bytes
    DEFB PHYSDEV_ID_SCCA, 0     ; PhysID, pad

    DEFB LOGDEV_ID_SERI         ; ID
    DEFM "SERI", 0              ; Name: 4 chars + null = 5 bytes
    DEFB PHYSDEV_ID_UN, 0       ; PhysID, pad

    DEFB LOGDEV_ID_SERO         ; ID
    DEFM "SERO", 0              ; Name: 4 chars + null = 5 bytes
    DEFB PHYSDEV_ID_UN, 0       ; PhysID, pad

    DEFB LOGDEV_ID_PRN          ; ID
    DEFM "PRN", 0, 0            ; Name: 3 chars + 2 nulls = 5 bytes
    DEFB PHYSDEV_ID_UN, 0       ; PhysID, pad
logdev_init_table_end:

; ROM automount table: 7 bytes per entry.
;   byte 0:   physdev_id (0 = end sentinel)
;   bytes 1-5: null-terminated name for new FS device (5 bytes)
;   byte 6:   autosel flag (nonzero = set CUR_DEVICE to new device)
; Add entries here to mount additional devices at boot.
automount_table:
    DEFB PHYSDEV_ID_ROMD        ; block device to mount
    DEFM "A", 0, 0, 0, 0        ; name for new FS device (5 bytes)
    DEFB 1                      ; autosel: set CUR_DEVICE to this device

    DEFB PHYSDEV_ID_BBL         ; block device to mount
    DEFM "B", 0, 0, 0, 0        ; name for new FS device (5 bytes)
    DEFB 0                      ; autosel: do not switch to this device

    DEFB 0                      ; end sentinel

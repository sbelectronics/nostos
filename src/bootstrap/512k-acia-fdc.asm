; Bootstrap for ACIA + WD37C65 FDC configuration.
; Uses ACIA for serial console, FDC for disk instead of CompactFlash.

; ============================================================
; Include Device Drivers (assembled as part of kernel image)
; ============================================================
    INCLUDE "src/drivers/undev.asm"
    INCLUDE "src/drivers/nulldev.asm"
    INCLUDE "src/drivers/rnddev.asm"
    INCLUDE "src/drivers/acia.asm"
    INCLUDE "src/drivers/fdc.asm"
    INCLUDE "src/drivers/ramdisk.asm"
    INCLUDE "src/drivers/fs.asm"

; ============================================================
; Physical device table entries (ROM)
; All ROM PDT entries are declared here using driver macros.
; ============================================================

physdev_fdc:
    PDTENTRY_FDC PHYSDEV_ID_FDC, "FD", 0, 18, 2, 2, 80, 0x1B, 0x00

physdev_acia:
    PDTENTRY_ACIA PHYSDEV_ID_ACIA, "ACIA", ACIA_CONTROL, ACIA_DATA

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
; Add a new entry here to register an additional ROM device.
devices_rom_table:
    DEFW physdev_acia
    DEFW physdev_fdc
    DEFW physdev_nul
    DEFW physdev_rnd
    DEFW physdev_un
    DEFW physdev_romdisk
    DEFW physdev_ramdisk
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
    DEFB PHYSDEV_ID_ACIA, 0     ; PhysID, pad

    DEFB LOGDEV_ID_CONO         ; ID
    DEFM "CONO", 0              ; Name: 4 chars + null = 5 bytes
    DEFB PHYSDEV_ID_ACIA, 0     ; PhysID, pad

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

    DEFB PHYSDEV_ID_FDC         ; block device to mount
    DEFM "C", 0, 0, 0, 0        ; name for new FS device (5 bytes)
    DEFB 0                      ; autosel: not the default device

    DEFB 0                      ; end sentinel

; ============================================================
; platform_init: bootstrap-supplied final init step.
; Called once by kernel_init after all device inits complete.
; This board has no interrupt-driven peripherals, so nothing to do.
; ============================================================
platform_init:
    RET

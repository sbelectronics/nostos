; ============================================================
; Include Device Drivers (assembled as part of kernel image)
; ============================================================
    INCLUDE "src/drivers/undev.asm"
    INCLUDE "src/drivers/nulldev.asm"
    INCLUDE "src/drivers/rnddev.asm"
    INCLUDE "src/drivers/cf.asm"
    INCLUDE "src/drivers/ramdisk.asm"
    INCLUDE "src/drivers/z180.asm"
    INCLUDE "src/drivers/fs.asm"

; ============================================================
; Physical device table entries (ROM)
; All ROM PDT entries are declared here using driver macros.
; ============================================================

physdev_cf:
    PDTENTRY_CF PHYSDEV_ID_CF, "CF", CF_BASE

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
    PDTENTRY_Z180 PHYSDEV_ID_Z180A, "ASC0", 0
physdev_z180b:
    PDTENTRY_Z180 PHYSDEV_ID_Z180B, "ASC1", 1

; Table of ROM PDT pointers for devices_init.
; Add a new entry here to register an additional ROM device.
devices_rom_table:
    DEFW physdev_cf
    DEFW physdev_nul
    DEFW physdev_rnd
    DEFW physdev_un
    DEFW physdev_romdisk
    DEFW physdev_ramdisk
    DEFW physdev_z180a
    DEFW physdev_z180b
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
    DEFB PHYSDEV_ID_Z180A, 0    ; PhysID, pad

    DEFB LOGDEV_ID_CONO         ; ID
    DEFM "CONO", 0              ; Name: 4 chars + null = 5 bytes
    DEFB PHYSDEV_ID_Z180A, 0    ; PhysID, pad

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

    DEFB PHYSDEV_ID_CF          ; block device to mount
    DEFM "C", 0, 0, 0, 0        ; name for new FS device (5 bytes)
    DEFB 0                      ; autosel: not the default device

    DEFB 0                      ; end sentinel

; ============================================================
; mapper_none.asm - no-mapper configuration (32K builds)
; ============================================================
; For boards with no banking hardware: 32K of ROM at 0x0000-0x7FFF
; and 32K of RAM at 0x8000-0xFFFF, accessed directly.
;
; MAPPER_INIT is empty — nothing to program at boot.
;
; MAPPER_REMAP_BANK / MAPPER_RESTORE_BANK are also empty for
; symmetry, but should never expand: the 32K bootstraps include
; tinyramdisk.asm (which doesn't bank), not ramdisk.asm.
;
; This file is included by mapper_config.asm when MAPPER_NONE is
; defined (typically alongside ROM_32K).
; ============================================================

MAPPER_NONE_CHOSEN  EQU 1       ; sentinel: bootstraps assert via IFNDEF

; High byte of the logical address where a (hypothetical) ramdisk
; paging window would appear.  Unused in 32K builds because
; ramdisk.asm is not included.  Defined as 0 to make accidental
; references obviously wrong rather than producing a plausible-looking
; bug if someone does include ramdisk.asm by mistake.
MAPPER_RD_WIN_HIGH  EQU 0

; ------------------------------------------------------------
; MAPPER_INIT - no-op for 32K boards (no banking hardware).
; ------------------------------------------------------------
MAPPER_INIT macro
endm

; ------------------------------------------------------------
; MAPPER_REMAP_BANK page_var - no-op (ramdisk not used in 32K).
; ------------------------------------------------------------
MAPPER_REMAP_BANK macro page_var
endm

; ------------------------------------------------------------
; MAPPER_RESTORE_BANK - no-op (ramdisk not used in 32K).
; ------------------------------------------------------------
MAPPER_RESTORE_BANK macro
endm

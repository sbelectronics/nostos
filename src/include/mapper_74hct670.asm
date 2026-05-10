; ============================================================
; mapper_74hct670.asm - external 4-window 16KB memory mapper
; ============================================================
; Zeta-style banking via four window-port writes (one per 16KB
; window) and one enable port:
;
;   Port 0x78 -> window 0 (0x0000-0x3FFF)
;   Port 0x79 -> window 1 (0x4000-0x7FFF)
;   Port 0x7A -> window 2 (0x8000-0xBFFF)   <-- ramdisk paging window
;   Port 0x7B -> window 3 (0xC000-0xFFFF)
;   Port 0x7C -> banking enable (write 1 to enable)
;
; Page numbers 0-31 = ROM, 32-63 = RAM (each 16KB).
;
; The ramdisk driver remaps WIN2 to a non-default page during
; block I/O, then restores the default.  No other window is
; touched at runtime.
;
; This file is included by mapper_config.asm when neither
; MAPPER_Z180_MMU nor MAPPER_NONE is defined (i.e. the default).
; ============================================================

MAPPER_74HCT670_CHOSEN  EQU 1   ; sentinel: bootstraps assert via IFNDEF

MAPPER_WIN0_PORT    EQU 0x78    ; set window 0 page
MAPPER_WIN1_PORT    EQU 0x79    ; set window 1 page
MAPPER_WIN2_PORT    EQU 0x7A    ; set window 2 page
MAPPER_WIN3_PORT    EQU 0x7B    ; set window 3 page
MAPPER_ENABLE_PORT  EQU 0x7C    ; write 1 to enable banking

; Page numbers written to the window ports at boot.  The ramdisk
; driver may temporarily replace MAPPER_WIN2_RAM during block I/O
; but always restores it.
MAPPER_WIN0_ROM     EQU 0       ; ROM page 0 -> window 0 (kernel + executive)
MAPPER_WIN1_RAM     EQU 32      ; RAM page 0 -> window 1 (0x4000-0x7FFF)
MAPPER_WIN2_RAM     EQU 33      ; RAM page 1 -> window 2 (0x8000-0xBFFF)
MAPPER_WIN3_RAM     EQU 34      ; RAM page 2 -> window 3 (0xC000-0xFFFF)

; High byte of the logical address where the ramdisk paging window
; appears.  WIN2 starts at 0x8000.  Used by rd_win2_addr.
MAPPER_RD_WIN_HIGH  EQU 0x80

; ------------------------------------------------------------
; MAPPER_INIT
; Boot-time initialisation: program all 4 windows and enable banking.
; Called from kernel_init before the stack is touched.  Safe to
; execute from window 0 (ROM) regardless of windows 1-3 reset state.
; Clobbers: A
; ------------------------------------------------------------
MAPPER_INIT macro
    LD   A, MAPPER_WIN0_ROM
    OUT  (MAPPER_WIN0_PORT), A
    LD   A, MAPPER_WIN1_RAM
    OUT  (MAPPER_WIN1_PORT), A
    LD   A, MAPPER_WIN2_RAM
    OUT  (MAPPER_WIN2_PORT), A
    LD   A, MAPPER_WIN3_RAM
    OUT  (MAPPER_WIN3_PORT), A
    LD   A, 1
    OUT  (MAPPER_ENABLE_PORT), A
endm

; ------------------------------------------------------------
; MAPPER_REMAP_BANK page_var
; Remap the paging window to the 16KB page held in the workspace
; variable named by `page_var` (1 byte).  Must be paired with a
; MAPPER_RESTORE_BANK before the critical section ends.  Caller
; must have DI'd already.
; Clobbers: A
; ------------------------------------------------------------
MAPPER_REMAP_BANK macro page_var
    LD   A, (page_var)
    OUT  (MAPPER_WIN2_PORT), A
endm

; ------------------------------------------------------------
; MAPPER_RESTORE_BANK
; Restore the paging window to its default page.  Called at the
; end of the critical section, before EI.
; Clobbers: A
; ------------------------------------------------------------
MAPPER_RESTORE_BANK macro
    LD   A, MAPPER_WIN2_RAM
    OUT  (MAPPER_WIN2_PORT), A
endm

; ============================================================
; mapper_config.asm - dispatch to the per-mapper include file
; ============================================================
; Three mapper backends are supported.  The build system selects
; one via a -D flag on the command line:
;
;   (default)              -> mapper_74hct670.asm
;                              External 4-window 16K mapper
;                              (Zeta-style, ports 0x78-0x7C)
;
;   -DMAPPER_NONE          -> mapper_none.asm
;                              No banking hardware (32K builds)
;
;   -DMAPPER_Z180_MMU      -> mapper_z180_mmu.asm
;                              Z180 internal MMU
;
; Each backend provides:
;   - sentinel MAPPER_<name>_CHOSEN (defined; bootstraps assert via IFNDEF)
;   - constant MAPPER_RD_WIN_HIGH (high byte of paging window)
;   - macro    MAPPER_INIT
;   - macro    MAPPER_REMAP_BANK page_var
;   - macro    MAPPER_RESTORE_BANK
;
; The kernel and ramdisk driver only use these macros — no IFDEF
; arms appear outside this file or its included backends.  Each
; bootstrap asserts at the bottom that the chosen backend matches
; what it expects, so a UART/mapper mismatch fails at assembly time
; rather than producing a broken ROM.
;
; The flag MUST come from the command line, not from a bootstrap
; file: bootstraps are included late (from kernel.asm), well after
; the kernel code that uses MAPPER_INIT has been processed.
; ============================================================

        IFDEF MAPPER_Z180_MMU
            INCLUDE "src/include/mapper_z180_mmu.asm"
        ELSE
            IFDEF MAPPER_NONE
                INCLUDE "src/include/mapper_none.asm"
            ELSE
                INCLUDE "src/include/mapper_74hct670.asm"
            ENDIF
        ENDIF

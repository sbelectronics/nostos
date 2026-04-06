; ============================================================
; Zeta-style 16KB Memory Mapper (EtchedPixels RC2014 emulator)
; ============================================================
; The emulator implements Zeta-style banking with four 16KB windows.
; Each window has its own port (0x78-0x7B); writing a page number to
; the port selects which physical 16KB page backs that window.
;
;   Port 0x78 -> window 0 (0x0000-0x3FFF)
;   Port 0x79 -> window 1 (0x4000-0x7FFF)
;   Port 0x7A -> window 2 (0x8000-0xBFFF)
;   Port 0x7B -> window 3 (0xC000-0xFFFF)
;
;   Page numbers 0-31  = ROM pages  (read-only; 0 = first 16KB of ROM image)
;   Page numbers 32-63 = RAM pages  (read-write)
;
; Banking is enabled by writing 1 to port 0x7C.  In the emulator,
; it is pre-enabled when the -b flag is used.

MAPPER_WIN0_PORT    EQU 0x78    ; set window 0 page
MAPPER_WIN1_PORT    EQU 0x79    ; set window 1 page
MAPPER_WIN2_PORT    EQU 0x7A    ; set window 2 page
MAPPER_WIN3_PORT    EQU 0x7B    ; set window 3 page
MAPPER_ENABLE_PORT  EQU 0x7C    ; write 1 to enable banking

; Page numbers written to the window ports. This is the canonical configuration
; for executing the kernel, executive, and user programs. The ramdisk driver
; may modify these pages, but will always restore them afterward.

MAPPER_WIN0_ROM     EQU 0       ; ROM page 0 -> window 0 (vectors + kernel + executive)
MAPPER_WIN1_RAM     EQU 32      ; RAM page 0 -> window 1 (0x4000-0x7FFF)
MAPPER_WIN2_RAM     EQU 33      ; RAM page 1 -> window 2 (0x8000-0xBFFF)
MAPPER_WIN3_RAM     EQU 34      ; RAM page 2 -> window 3 (0xC000-0xFFFF)

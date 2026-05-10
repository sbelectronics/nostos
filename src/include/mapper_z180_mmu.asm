; ============================================================
; mapper_z180_mmu.asm - Z180 internal MMU
; ============================================================
; Replaces the external 74HCT670 mapper with the Z180's built-in
; MMU.  Memory layout (CBAR = 0xC4):
;
;   Logical                       Physical
;   0x0000 - 0x3FFF  Common 0     0x00000 - 0x03FFF  ROM (identity)
;   0x4000 - 0xBFFF  Bank Area    0x80000 - 0x87FFF  user RAM (default;
;                                                    pages 32-33)
;   0xC000 - 0xFFFF  Common 1     0x88000 - 0x8BFFF  kernel RAM (page 34)
;
; Bank Area is the paging window: ramdisk reads switch BBR to map
; the desired 16KB page in, then restore.  Common 0 (ROM) and
; Common 1 (workspace, ring buffers, kernel stack, DISK_BUFFER)
; stay stable across the swap.
;
; Translation: PA[19:12] = (LA[15:12] + offset) & 0xFF; PA[11:0] = LA[11:0],
; where offset is BBR for the Bank Area or CBR for Common 1 (Common 0
; is always identity, no offset register).
;
; --- All internal-I/O writes use OUT (C), A with B = 0 ---
; The Z180 internal I/O decoder responds only when address bus
; A15-A8 == 0; that's the whole reason Zilog added IN0/OUT0,
; which force the upper byte to zero.  Plain OUT (n), A mirrors
; the accumulator onto A15-A8, so writing (say) A=0xC4 to an MMU
; port silently misses the internal block and bleeds onto the
; external bus.  z88dk's z80asm doesn't assemble OUT0, so we use
; OUT (C), A with B preloaded to 0 to get equivalent bus activity
; (matches the RomWBW / NostOS z180.asm / z180_int.asm convention).
; ============================================================

MAPPER_Z180_MMU_CHOSEN EQU 1    ; sentinel: bootstraps assert via IFNDEF

Z180_ICR_BOOT       EQU 0x3F        ; ICR is at 0x3F before remap

Z180_RCR_REMAPPED   EQU 0xC0 + 0x36 ; refresh control
Z180_TCR_REMAPPED   EQU 0xC0 + 0x10 ; timer control
Z180_ITC_REMAPPED   EQU 0xC0 + 0x34 ; interrupt/TRAP control
Z180_DCNTL_REMAPPED EQU 0xC0 + 0x32 ; DMA/wait control
Z180_CBR_REMAPPED   EQU 0xC0 + 0x38 ; MMU common base
Z180_BBR_REMAPPED   EQU 0xC0 + 0x39 ; MMU bank base
Z180_CBAR_REMAPPED  EQU 0xC0 + 0x3A ; MMU common/bank area

; CBAR: high nibble = CA (Common 1 boundary, 4K units), low nibble
; = BA (Bank boundary).  0xC4 -> Common 0 = 16K, Bank = 32K, Common 1 = 16K.
Z180_CBAR_VALUE     EQU 0xC4
Z180_BBR_USER       EQU 0x7C        ; Bank   -> physical 0x80000 (RAM page 32)
Z180_CBR_KERN       EQU 0x7C        ; Common 1 -> physical 0x88000 (RAM page 34)

; High byte of the logical address where the ramdisk paging window
; appears.  Bank starts at logical 0x4000.  Used by rd_win2_addr.
MAPPER_RD_WIN_HIGH  EQU 0x40

; ------------------------------------------------------------
; MAPPER_INIT
; Boot-time MMU + I/O setup.  Runs before SP is valid -- no stack
; usage.
;
; Order: ICR remap, then quiescence, then MMU.  CBAR is written
; before BBR/CBR so that while we still have BBR=CBR=0 in effect
; everything stays identity-mapped, and the PC (in low ROM)
; keeps fetching the same physical bytes through the layout change.
; Clobbers: A, B, C
; ------------------------------------------------------------
MAPPER_INIT macro
    LD   B, 0                       ; B=0 forces A15-A8=0 on every OUT (C), A

    LD   C, Z180_ICR_BOOT
    LD   A, Z180_IO_BASE
    OUT  (C), A                     ; remap internal I/O to 0xC0-0xFF

    XOR  A
    LD   C, Z180_RCR_REMAPPED
    OUT  (C), A                     ; refresh off (SRAM)
    LD   C, Z180_TCR_REMAPPED
    OUT  (C), A                     ; PRT timers off
    LD   C, Z180_ITC_REMAPPED
    OUT  (C), A                     ; mask all internal IRQs
    LD   C, Z180_DCNTL_REMAPPED
    LD   A, 0xF0
    OUT  (C), A                     ; max wait states (safe everywhere)

    LD   C, Z180_CBAR_REMAPPED
    LD   A, Z180_CBAR_VALUE
    OUT  (C), A
    LD   C, Z180_BBR_REMAPPED
    LD   A, Z180_BBR_USER
    OUT  (C), A
    LD   C, Z180_CBR_REMAPPED
    LD   A, Z180_CBR_KERN
    OUT  (C), A
endm

; ------------------------------------------------------------
; MAPPER_REMAP_BANK page_var
; Remap the Bank Area to the 16KB ramdisk page held in `page_var`
; (1 byte; 16KB-page units, matching the external-mapper convention:
; page 0 = physical 0x00000, page 32 = physical 0x80000, etc.).
;
; BBR for page N is 4*(N-1):
;   logical 0x4000 must map to physical N*16K
;   PA[19:12] at LA=0x4000 is (0x4 + BBR), so BBR = 4N - 4 = 4*(N-1)
;
; Caller must have DI'd already.  Common 0 (ROM, where this runs)
; and Common 1 (kernel RAM) are unaffected.
; Clobbers: A, B, C
; ------------------------------------------------------------
MAPPER_REMAP_BANK macro page_var
    LD   A, (page_var)
    ADD  A, A
    ADD  A, A
    SUB  4
    LD   B, 0
    LD   C, Z180_BBR_REMAPPED
    OUT  (C), A
endm

; ------------------------------------------------------------
; MAPPER_RESTORE_BANK
; Restore the Bank Area to its default (user RAM at physical
; 0x80000).  Called at the end of the critical section, before EI.
; Clobbers: A, B, C
; ------------------------------------------------------------
MAPPER_RESTORE_BANK macro
    LD   B, 0
    LD   C, Z180_BBR_REMAPPED
    LD   A, Z180_BBR_USER
    OUT  (C), A
endm

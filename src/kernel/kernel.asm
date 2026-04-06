; NostOS Kernel
; Part of the single 16KB ROM image (assembled via src/nostos.asm).
;
; Runtime memory layout:
;   0x0000-0x003F     RST vectors (ROM); KERNELADDR (0x0010) = syscall entry
;   0x0040-0x3FFF     Kernel + executive code (ROM, 16K; 0x7FFF for 32K)
;   USER_PROGRAM_BASE User programs and extensions (RAM)
;   WORKSPACE_BASE    Kernel workspace in high RAM (see constants.asm)
;   KERNEL_STACK      Stack, grows down from just below workspace
;
; All workspace addresses and dimensions are defined in
; src/include/constants.asm.  See specification/KERNEL.md for full
; documentation of the workspace layout.
;
; Boot sequence:
;   1. CPU resets to 0x0000 (ROM mirrored to all windows by 74HCT670)
;   2. RST 0 vector jumps to kernel_init
;   3. kernel_init configures mapper, sets up stack, workspace, devices,
;      then jumps to exec_main
; ============================================================

; ============================================================
; kernel_init
; Entry point after CPU reset.  Configures the memory mapper,
; initialises all kernel data structures, and launches the
; executive.
; ============================================================
kernel_init:
    IFNDEF ROM_32K
    ; Window 0 stays ROM (we're executing from it right now).
    ; Switch windows 1-3 to RAM before touching the stack or workspace.
    ; These OUT instructions need no stack, so they are safe to execute
    ; from window 0 (ROM) with windows 1-3 still in their reset state.
    LD   A, MAPPER_WIN0_ROM
    OUT  (MAPPER_WIN0_PORT), A  ; window 0 (0x0000-0x3FFF) = ROM page 0 (already is, but be explicit)
    LD   A, MAPPER_WIN1_RAM
    OUT  (MAPPER_WIN1_PORT), A  ; window 1 (0x4000-0x7FFF) = RAM page 32
    LD   A, MAPPER_WIN2_RAM
    OUT  (MAPPER_WIN2_PORT), A  ; window 2 (0x8000-0xBFFF) = RAM page 33
    LD   A, MAPPER_WIN3_RAM
    OUT  (MAPPER_WIN3_PORT), A  ; window 3 (0xC000-0xFFFF) = RAM page 34
    LD   A, 1
    OUT  (MAPPER_ENABLE_PORT), A ; For Zeta-2 hardware, enable the mapper.
    ENDIF

    LD   SP, KERNEL_STACK       ; set up kernel/executive stack (window 3 is now RAM)

    CALL workspace_init         ; zero workspace, install vectors, init tables
    CALL devices_init           ; initialise ROM device drivers
    CALL logdev_table_init      ; assign logical devices from ROM table
    CALL automount_init         ; mount filesystems from ROM automount table

    JP   exec_main              ; start the executive (never returns here)

; ============================================================
; workspace_init
; Zeroes the entire workspace, initialises logical and physical
; device tables, I/O trampolines, and sets default CWD.
; Called once at boot from kernel_init; no register constraints.
; Inputs:
;   (none)
; Outputs:
;   (none - all registers clobbered; init-only)
; ============================================================
workspace_init:
    ; Zero the entire workspace
    LD   HL, WORKSPACE_BASE
    LD   BC, WORKSPACE_END - WORKSPACE_BASE
    CALL memzero

    ; RST 2 vector (JP syscall_entry at 0x0010) is in ROM — no install needed.

    ; Physical device list head: points to 0, since PDT starts empty.
    LD   HL, 0
    LD   (PHYSDEV_LIST_HEAD), HL

    ; Default current device: CONO (logical device identifier with top bit set)
    LD   A, LOGDEV_ID_CONO
    LD   (CUR_DEVICE), A

    ; Default current directory: "/"
    LD   HL, CUR_DIR
    LD   (HL), '/'
    INC  HL
    LD   (HL), 0                ; null terminator

    ; Initialize dynamic memory top and bottom
    LD   HL, KERNEL_STACK - 1
    LD   (DYNAMIC_MEMTOP), HL
    LD   HL, USER_PROGRAM_BASE
    LD   (DYNAMIC_MEMBOT), HL

    ; Initialize dynamic I/O trampolines
    ; IN thunk: 0xDB, 0x00, 0xC9 (IN A, (00) / RET)
    LD   HL, TRAMP_IN_THUNK
    LD   (HL), 0xDB
    INC  HL
    LD   (HL), 0x00
    INC  HL
    LD   (HL), 0xC9
    
    ; OUT thunk: 0xD3, 0x00, 0xC9 (OUT (00), A / RET)
    LD   HL, TRAMP_OUT_THUNK
    LD   (HL), 0xD3
    INC  HL
    LD   (HL), 0x00
    INC  HL
    LD   (HL), 0xC9

    RET

; ============================================================
; logdev_table_init
; Copies each ROM logical device entry (ID + name) into the
; workspace RAM logical device table, then calls DEV_LOG_ASSIGN
; to bind the physical device ID stored in the ROM entry's
; PhysID byte. Called once from kernel_init after devices_init.
; Inputs:
;   (none)
; Outputs:
;   (none - all registers clobbered; init-only)
; ============================================================
logdev_table_init:
    LD   HL, logdev_init_table
    LD   B, (logdev_init_table_end - logdev_init_table) / LOGDEV_ENTRY_SIZE
logdev_table_init_loop:
    PUSH BC                     ; save entry count

    ; Read logical device ID and compute RAM entry address
    LD   C, (HL)                ; C = logical device ID (LOGDEV_OFF_ID, e.g. 0x80 for NUL)
    LD   A, C
    AND  0x7F                   ; strip top bit to get raw slot index for logdev_entry_addr
    PUSH HL                     ; save ROM entry base
    CALL logdev_entry_addr      ; HL = &LOGDEV_TABLE[index]; preserves A, DE
    LD   D, H
    LD   E, L                   ; DE = RAM entry dest
    POP  HL                     ; HL = ROM entry base

    ; Copy 6 bytes (ID + name) from ROM to RAM
    LD   B, 6
logdev_table_init_copy:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  B
    JP   NZ, logdev_table_init_copy
    ; HL = ROM entry PhysID byte; DE = RAM entry PhysPtr_low

    ; Zero RAM PhysPtr (DEV_LOG_ASSIGN will fill it with the RAM PDT pointer)
    XOR  A
    LD   (DE), A
    INC  DE
    LD   (DE), A

    ; Read physdev ID from ROM, advance past PhysID + pad bytes
    LD   E, (HL)                ; E = physdev ID (ROM PhysID byte)
    INC  HL
    INC  HL                     ; skip PhysID + pad → HL = next ROM entry
    PUSH HL                     ; save next ROM entry

    ; Call DEV_LOG_ASSIGN: B = logical device ID, E = physdev ID
    LD   A, C
    OR   0x80
    LD   B, A                   ; B = logical device ID (index | 0x80)
    LD   C, DEV_LOG_ASSIGN
    CALL syscall_entry

    POP  HL                     ; HL = next ROM entry
    POP  BC                     ; restore entry count
    DEC  B
    JP   NZ, logdev_table_init_loop
    RET

; ============================================================
; devices_init
; Copy each ROM device entry into a RAM PDT slot and run its
; initializer. Iterates devices_rom_table; adding a new ROM
; device only requires appending its PDT pointer to that table.
; Logical device assignments are performed by logdev_table_init,
; which is called after this function.
; Called once at boot from kernel_init; no register constraints.
; Inputs:
;   (none)
; Outputs:
;   (none - all registers clobbered; init-only)
; ============================================================
devices_init:
    LD   HL, devices_rom_table
    LD   B, (devices_rom_table_end - devices_rom_table) / 2
devices_init_loop:
    PUSH BC
    LD   E, (HL)                ; DE = ROM PDT pointer (little-endian)
    INC  HL
    LD   D, (HL)
    INC  HL                     ; HL now at next table entry
    PUSH HL                     ; save next-entry pointer
    LD   C, DEV_COPY            ; copy ROM PDT to RAM slot
    CALL syscall_entry          ; returns HL = new physical device ID
    LD   B, L                   ; B = physical device ID
    LD   C, DEV_INIT
    CALL syscall_entry
    POP  HL                     ; HL = next-entry pointer
    POP  BC
    DEC  B
    JP   NZ, devices_init_loop
    RET

; ============================================================
; automount_init
; Mount filesystems listed in automount_table.
; Each entry is 7 bytes: physdev_id (1), name (5), autosel (1).
;   physdev_id: physical block device ID; 0 = end sentinel
;   name:       5-byte null-terminated name for the new FS device
;   autosel:    if nonzero, set CUR_DEVICE to the new device ID
; On mount failure, prints a warning to CON.
; Called once from kernel_init after logdev_table_init.
; Inputs:
;   (none)
; Outputs:
;   (none - all registers clobbered; init-only)
; ============================================================
automount_init:
    LD   HL, automount_table
automount_init_loop:
    LD   A, (HL)                ; byte 0: block dev ID (0 = end sentinel)
    OR   A
    JP   Z, automount_init_done
    PUSH HL                     ; save table ptr across syscall
    LD   D, H
    LD   E, L                   ; DE = MOUNT_PARAMS (blkdev_id + name)
    LD   C, DEV_MOUNT
    CALL syscall_entry          ; A = status, HL = new dev ID
    LD   B, L                   ; B = new physical dev ID (save before POP)
    POP  HL                     ; restore table ptr
    OR   A
    JP   NZ, automount_init_warn
    ; Check byte 6 (autosel flag): HL+6
    PUSH HL
    LD   DE, 6
    ADD  HL, DE
    LD   A, (HL)                ; byte 6: autosel flag
    POP  HL
    OR   A
    JP   Z, automount_init_next
    LD   A, B                   ; A = new physical dev ID
    LD   (CUR_DEVICE), A
    JP   automount_init_next
automount_init_warn:
    PUSH HL                     ; save table ptr across warning syscall
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_automount_warn
    LD   C, DEV_CWRITE_STR
    CALL syscall_entry
    POP  HL                     ; restore table ptr
automount_init_next:
    LD   DE, 7
    ADD  HL, DE                 ; advance to next 7-byte entry
    JP   automount_init_loop
automount_init_done:
    RET

msg_automount_warn:
    DEFM "Warning: automount failed.", 0x0D, 0x0A, 0

; ============================================================
; unexpected_rst
; Handler for uncaught RST instructions (RST 3–7).
; Prints a warning to CONO and returns to the caller.
; Inputs:
;   (none)
; Outputs:
;   (none — all registers preserved)
; ============================================================
unexpected_rst:
    PUSH AF
    PUSH BC
    PUSH DE
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   DE, msg_unexpected_rst
    CALL sys_dev_cwrite_str
    POP  HL
    POP  DE
    POP  BC
    POP  AF
    RET

msg_unexpected_rst:
    DEFM "Unexpected RST", 0x0D, 0x0A, 0

; ============================================================
; Utilities
; ============================================================
    INCLUDE "src/lib/string.asm"
    INCLUDE "src/lib/tramp.asm"
    INCLUDE "kernel/util.asm"

; ============================================================
; System calls
; ============================================================
    INCLUDE "kernel/sys_entry.asm"
    INCLUDE "kernel/sys_misc.asm"
    INCLUDE "kernel/sys_devman.asm"
    INCLUDE "kernel/sys_mount.asm"
    INCLUDE "kernel/sys_dev.asm"
    INCLUDE "kernel/sys_path.asm"
    INCLUDE "kernel/sys_err.asm"

; ============================================================
; Include Debug Support
; ============================================================
    INCLUDE "src/debug/printhex.asm"

; ============================================================
; Board-specific bootstrap: PDT entries, device tables, automount
; Pass -DUART_SIO, -DUART_SIO_SB, -DUART_Z180, or -DUART_SCC to select UART.
; Pass -DBLKDEV_FDC to select ACIA+FDC (floppy) instead of ACIA+CF.
; Default (no flag) is ACIA (MC6850) with CompactFlash.
; ============================================================
    IFDEF UART_Z180
    INCLUDE "src/bootstrap/512k-z180.asm"
    ELSE
    IFDEF UART_SCC
    IFDEF ROM_32K
    INCLUDE "src/bootstrap/32k-scc-bub.asm"
    ELSE
    INCLUDE "src/bootstrap/512k-scc.asm"
    ENDIF
    ELSE
    IFDEF UART_SIO
    INCLUDE "src/bootstrap/512k-sio.asm"
    ELSE
    IFDEF UART_SIO_SB
    INCLUDE "src/bootstrap/512k-sio-sb.asm"
    ELSE
    IFDEF BLKDEV_FDC
    INCLUDE "src/bootstrap/512k-acia-fdc.asm"
    ELSE
    IFDEF ROM_32K
    INCLUDE "src/bootstrap/32k-acia.asm"
    ELSE
    INCLUDE "src/bootstrap/512k-acia.asm"
    ENDIF
    ENDIF
    ENDIF
    ENDIF
    ENDIF
    ENDIF

; ============================================================
; Kernel size constant (used by SYS_INFO)
; ============================================================
kernel_end:
kernel_size EQU kernel_end - KERNEL_BASE

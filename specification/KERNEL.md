# NostOS Kernel

The kernel is rommable — it runs directly from ROM and uses only a small workspace area in RAM.

The kernel's primary responsibility is device management: it maintains the physical and logical device tables, and dispatches system calls from user programs and the executive to the appropriate device drivers.

## Memory Mapping

NostOS uses a Zeta-style 16 KB page mapper to divide the 64 KB address space into four windows. Each window is mapped to a physical page via an I/O port write.

| Port | Window | Address Range | Runtime Mapping |
|------|--------|---------------|-----------------|
| 0x78 | 0 | 0x0000–0x3FFF | ROM page 0 |
| 0x79 | 1 | 0x4000–0x7FFF | RAM page 32 |
| 0x7A | 2 | 0x8000–0xBFFF | RAM page 33 |
| 0x7B | 3 | 0xC000–0xFFFF | RAM page 34 |

Page numbers 0–31 are ROM (read-only) and 32–63 are RAM (read-write). Banking is enabled by writing 1 to port 0x7C.

At power-on reset, the 74HCT670 register file mirrors the ROM page into all windows, so the CPU begins executing ROM code at address 0x0000. Window 0 remains mapped to ROM permanently; the kernel reconfigures windows 1–3 to RAM during boot. The ramdisk driver may temporarily remap windows to access additional RAM pages, but always restores the canonical configuration afterward.

## Boot Sequence

1. The CPU resets to address 0x0000. The 74HCT670 mirrors ROM page 0 into all windows, so execution begins at the RST 0 vector which jumps to `kernel_init` (0x0040).
2. `kernel_init` configures the memory mapper (window 0 = ROM, windows 1–3 = RAM), sets the stack pointer to `KERNEL_STACK` (0xF7F0), calls `workspace_init` (clears and populates the workspace), then calls `devices_init` (registers built-in devices and sets up logical device assignments).
3. The kernel jumps to `exec_main`, handing control to the executive.

## Stack Conventions

| Rule | Description |
|------|-------------|
| Default location | Below workspace (`KERNEL_STACK`, 0xF7F0) |
| User override | User programs may relocate the stack during execution |
| Restoration | When SYS_EXIT is called, the stack is restored to the default before re-entering the executive |

## Workspace

The kernel maintains a 1,920-byte workspace in high RAM at `WORKSPACE_BASE` (0xF800). This area holds device tables, I/O buffers, and executive state. All workspace addresses are defined relative to `WORKSPACE_BASE` so the workspace can be relocated by changing a single constant. The workspace is at a fixed address regardless of ROM size (16K or 32K), so apps compiled once work on all builds.

| Address | Size | Label | Contents |
|---------|------|-------|----------|
| 0xF800 | 64 bytes | — | Unused (previously RAM interrupt vectors) |
| 0xF840 | 128 bytes | `LOGDEV_TABLE` | Logical device table (16 entries × 8 bytes) |
| 0xF8C0 | 512 bytes | `PHYSDEV_TABLE` | Physical device table (16 entries × 32 bytes) |
| 0xFAC0 | 256 bytes | `INPUT_BUFFER` | Input buffer for reading strings from devices |
| 0xFBC0 | 1 byte | `CUR_DEVICE` | Current logical device ID |
| 0xFBC1 | 32 bytes | `CUR_DIR` | Current directory path (null-terminated) |
| 0xFBE1 | 2 bytes | `PHYSDEV_LIST_HEAD` | Pointer to head of physical device linked list |
| 0xFBE3 | 2 bytes | `EXEC_CMD_TABLE_HEAD` | Pointer to head of executive command table |
| 0xFBE5 | 2 bytes | `EXEC_ARGS_PTR` | Pointer to command-line arguments |
| 0xFBE7 | 4 bytes | `TRAMP_IN_THUNK` | Dynamic IN trampoline (IN A,(port) / RET) |
| 0xFBEB | 4 bytes | `TRAMP_OUT_THUNK` | Dynamic OUT trampoline (OUT (port),A / RET) |
| 0xFBEF | 1 byte | `PLAY_AUTORUN` | Autoplay flag (0 = not yet tried, 1 = done) |
| 0xFBF0 | 3 bytes | `CF_READ_THUNK` | CF per-read IN thunk |
| 0xFBF4 | 3 bytes | `CF_WRITE_THUNK` | CF per-write OUT thunk |
| 0xFBF7 | 2 bytes | `DYNAMIC_MEMTOP` | Runtime-adjustable memory top (initialized to KERNEL_STACK − 1) |
| 0xFBF9 | 2 bytes | `DYNAMIC_MEMBOT` | Runtime-adjustable memory bottom (initialized to USER_PROGRAM_BASE) |
| 0xFBFB | 1 byte | `PLAY_HANDLE` | PLAY command file handle (0 = inactive) |
| 0xFBFC | 2 bytes | `PLAY_BLOCK` | PLAY command current block number |
| 0xFBFE | 2 bytes | `PLAY_OFFSET` | PLAY command byte offset within block (0–511) |
| 0xFC00 | 512 bytes | `DISK_BUFFER` | Disk transfer buffer (inodes, directory blocks, etc.) |
| 0xFE00 | 64 bytes | `PATH_WORK_BASE` | Path resolver workspace |
| 0xFE40 | 52 bytes | `FS_SPAN_CACHE` | Filesystem span cache |
| 0xFE74 | 8 bytes | `SYS_EXEC_STATE` | SYS_EXEC persistent state (safe across driver calls) |
| 0xFE7C | 2 bytes | `RND_SEED` | Random number generator LFSR state |
| 0xFE7E | 130 bytes | — | Unused |
| 0xFF00 | 128 bytes | `KERN_TEMP_SPACE` | Kernel temporary space |

The RST vectors (including the syscall entry point at 0x0010) reside in ROM at address 0x0000. The syscall entry point (`KERNELADDR`) corresponds to the RST 2 vector. User programs and the executive invoke system calls via `CALL 0x0010`.

### Runtime Memory Layout

```
0xFFFF  ┌─────────────────────────┐
        │  Kernel workspace       │  0xF800–0xFF7F
0xF800  ├─────────────────────────┤  WORKSPACE_BASE
        │  Stack (grows down)     │  KERNEL_STACK = 0xF7F0
0xF7F0  ├  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  ┤
0xF7EF  │  DYNAMIC_MEMTOP         │  (initialized to KERNEL_STACK − 1)
        │                         │
0xF000  │  EXEC_RAM_START         │  Executive scratch space (used only
        │                         │    while no user program is loaded)
        │  [free — user programs] │
        │                         │
MEMBOT  │  DYNAMIC_MEMBOT         │  (grows upward as extensions load)
        ├─────────────────────────┤
        │  Extension N            │
        │  ...                    │
        │  Extension 1            │
0x4000  ├─────────────────────────┤  USER_PROGRAM_BASE (16K ROM)
        │  Kernel + Executive ROM │  0x0040–0x3FFF
        │  (single 16 KB image)   │
0x0040  ├─────────────────────────┤
        │  RST Vectors            │  0x0000–0x003F
0x0000  └─────────────────────────┘  KERNEL_BASE (ROM, window 0)
```

- **ROM** occupies window 0 (0x0000–0x3FFF): RST vectors, kernel, and executive (assembled as a single 16 KB image).
- **RAM** occupies windows 1–3 (0x4000–0xFFFF): user programs, extensions, executive scratch, stack, and workspace.
- **Workspace** is in high RAM at 0xF800–0xFF7F, at a fixed address for all builds (16K and 32K ROM).
- **Stack** grows downward from `KERNEL_STACK` (0xF7F0), just below the workspace.
- **Extensions** load at `DYNAMIC_MEMBOT` and grow upward. After an extension is loaded, `DYNAMIC_MEMBOT` advances past the extension code.
- **User programs** load at the current value of `DYNAMIC_MEMBOT` and may use memory up to `DYNAMIC_MEMTOP`.
- **EXEC_RAM_START** (0xF000) is scratch space used by executive commands. This area is overwritten when a user program loads and is only valid while the executive is running commands.
- **SYS_MEMTOP** (syscall 5) returns `DYNAMIC_MEMTOP`. User programs can read `DYNAMIC_MEMBOT` directly from the workspace to determine their load base.
- **USER_PROGRAM_BASE** is build-dependent: 0x4000 for 16K ROM builds, 0x8000 for 32K ROM builds.

### Path resolver workspace (PATH_WORK, 0xFE00, 64 bytes)

Used exclusively by SYS_GLOBAL_OPENFILE and SYS_GLOBAL_OPENDIR during pathname resolution. Contents are not preserved across syscall boundaries.

| Offset | Size | Label | Description |
|--------|------|-------|-------------|
| 0x00 | 8 bytes | `PATH_WORK_DEVNAME` | Extracted device name, null-terminated (max 6 chars + null + 1 pad) |
| 0x08 | 56 bytes | `PATH_WORK_PATH` | Assembled path string passed to DEV_FOPEN/DEV_DOPEN |

### Filesystem span cache (FS_SPAN_CACHE, 0xFE40, 52 bytes)

The workspace span cache holds up to 13 (FirstBlock, LastBlock) span entries copied from a directory inode. It is used by directory traversal and removal code (`fs_dir.asm`, `fs_remove.asm`) that operates without an open file handle. This is separate from the per-handle span cache stored in PDT user data (see [Filesystem](FILESYS.md)), which is used for open file/directory I/O.

When a directory inode is loaded into `DISK_BUFFER`, the routine `fs_cache_inode_spans` copies up to 13 span entries (52 bytes) into this cache. The directory scanner then walks through data blocks using the cached spans without needing the inode in the disk buffer, freeing the disk buffer for reading directory data blocks.

Each cached span entry is 4 bytes: 2-byte FirstBlock followed by 2-byte LastBlock (same format as the inode span table).

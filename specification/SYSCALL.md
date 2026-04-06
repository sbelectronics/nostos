# NostOS System Call Reference

System calls are used by user programs and the executive to interact with the kernel and, indirectly, with devices.

## Calling Convention

System calls are made via `CALL KERNELADDR` (0x0010, the RST 2 vector).

| Register | Direction | Purpose |
|----------|-----------|---------|
| B | Input | Device identifier (for device operations; unused otherwise) |
| C | Input | Function number (see reference table below) |
| DE | Input | Parameter value (meaning varies per syscall) |
| A | Output | Status code: 0 = success, non-zero = error (see error codes) |
| HL | Output | Return value (meaning varies per syscall) |

Some system calls use DE as a pointer to a larger argument, or return an address in HL. These cases are documented per-syscall below.

## Syscall Reference

### System

| # | Name | DE | HL return | Notes |
|---|------|----|-----------|-------|
| 0 | SYS_EXIT | — | Does not return | Exit user program, return to executive |
| 1 | SYS_INFO | Pointer to 64-byte buffer | — | Fill buffer with system info (see SYS_INFO format) |
| 2 | SYS_GET_CWD | Pointer to 33-byte buffer | — | Get current device (1 byte) + directory path (32 bytes) |
| 3 | SYS_SET_CWD | Pointer to pathname string | — | Change current device and directory; uses pathname resolution (see algorithm below) |
| 4 | SYS_GET_CMDLINE | — | Address of input buffer | Get pointer to command-line input buffer |
| 5 | SYS_MEMTOP | — | Top of user memory | Returns DYNAMIC_MEMTOP (last usable address for user programs) |

### Device Management

| # | Name | B | DE | HL return | Notes |
|---|------|---|----|-----------|-------|
| 6 | DEV_LOG_ASSIGN | Logical device ID | Physical device ID (in E) | — | Assign logical device to physical device |
| 7 | DEV_LOG_GET | Logical device ID | — | Pointer to logical device entry | |
| 8 | DEV_LOG_LOOKUP | — | Pointer to name string | Logical device ID | Lookup logical device by name |
| 9 | DEV_PHYS_LOOKUP | — | Pointer to name string | Physical device ID | Lookup physical device by name |
| 31 | DEV_PHYS_GET | Physical device ID (in B) | — | Pointer to PDT entry | |
| 35 | DEV_LOG_CREATE | — | Pointer to name (up to 4 chars, null-terminated) | Logical device ID | Create a new logical device entry |
| 36 | DEV_LOOKUP | — | Pointer to name string | Device ID | Tries logical lookup first, then physical. Bit 7 of result indicates logical (set) vs physical (clear). |
| 37 | DEV_GET_NAME | Device ID (in B) | Pointer to name buffer (≥ 8 bytes) | — | Get device name by ID |
| 38 | DEV_COPY | — | Pointer to PDT entry | — | Copy a physical device entry into the RAM PDT area |

### Character I/O

| # | Name | B | DE | HL return | Notes |
|---|------|---|----|-----------|-------|
| 10 | DEV_INIT | Device ID | — | — | Initialize device |
| 11 | DEV_SHUTDOWN | Device ID | — | — | **Stub** — returns ERR_NOT_SUPPORTED |
| 12 | DEV_STAT | Device ID | — | 1 if char waiting, else 0 | Check if character is available |
| 13 | DEV_CREAD_RAW | Device ID | — | Character in L | Read one byte without echo |
| 14 | DEV_CREAD | Device ID | — | Character in L | Read one byte with echo |
| 15 | DEV_CWRITE | Device ID | Character in E | — | Write one byte |
| 16 | DEV_CWRITE_STR | Device ID | Pointer to null-terminated string | — | Write string |
| 17 | DEV_CREAD_STR | Device ID | Pointer to 256-byte buffer | Number of characters read | Read line until CR/LF |

### Block I/O

| # | Name | B | DE | HL return | Notes |
|---|------|---|----|-----------|-------|
| 18 | DEV_BREAD | Device ID | Pointer to 512-byte buffer | — | Read one block; advances position by 1 |
| 19 | DEV_BWRITE | Device ID | Pointer to 512-byte buffer | — | Write one block; advances position by 1. Expands file if past EOF. |
| 20 | DEV_BSEEK | Device ID | Block number | — | Seek to block number (relative to start of file) |
| 21 | DEV_BSETSIZE | Device ID | Pointer to 4-byte size (low 3 bytes used) | — | Set file size in bytes. Does not allocate or deallocate blocks. |
| 32 | DEV_BGETPOS | Device ID | — | Block number (relative to start of file) | Get current block position |
| 33 | DEV_BGETSIZE | Device ID | Pointer to 4-byte buffer | — | Get file size in bytes |

### Filesystem Operations

| # | Name | B | DE | HL return | Notes |
|---|------|---|----|-----------|-------|
| 22 | DEV_FOPEN | Filesystem device ID | Pointer to pathname string | File device ID (physical) | Open file; returns handle for block I/O. Path may include directories (e.g. "DIR/FILE"). |
| 23 | DEV_CLOSE | Device ID | — | — | Close handle. If DEVCAP_HANDLE is set, calls DFT Close and frees PDT entry. Otherwise no-op. |
| 24 | DEV_FCREATE | Filesystem device ID | Pointer to pathname string | File device ID (physical) | Create file. Path may include directories (e.g. "DIR/FILE"). |
| 25 | DEV_FREMOVE | Filesystem device ID | Pointer to pathname string | — | Remove file. Path may include directories. |
| 26 | DEV_FRENAME | Filesystem device ID | Pointer to {src_ptr, dst_ptr} | — | Rename file (DE points to two 16-bit pointers) |
| 27 | DEV_DCREATE | Filesystem device ID | Pointer to pathname string | — | Create directory. Path may include parent directories (e.g. "A/B/C" creates "C" inside "A/B"). |
| 28 | DEV_DOPEN | Filesystem device ID | Pointer to pathname string (empty string or "/" for root) | Dir device ID (physical) | Open directory; returns handle for entry enumeration |
| 29 | DIR_FIRST | — | — | — | **Stub** — use DEV_BSEEK(0) + DEV_BREAD instead |
| 30 | DIR_NEXT | — | — | — | **Stub** — use DEV_BREAD instead |
| 42 | DEV_FREE | Filesystem device ID | — | Free block count | Get number of free blocks on filesystem |

### Pathname Resolution

| # | Name | DE | HL return | Notes |
|---|------|----|-----------|-------|
| 34 | DEV_MOUNT | Pointer to MOUNT_PARAMS | Physical device ID of new FS device | Mount filesystem on a block device |
| 39 | SYS_GLOBAL_OPENFILE | Pointer to pathname string | File device ID (physical) | Full path resolution; see pathname parsing below |
| 40 | SYS_GLOBAL_OPENDIR | Pointer to pathname string | Dir device ID (physical) | Full path resolution; opens root dir for bare device names |
| 41 | SYS_EXEC | B=file handle, DE=load address | Does not return on success | Read relocatable executable from open file handle, apply relocation fixups, close handle, jump to entry point (load_addr + 2) |
| 43 | SYS_PATH_PARSE | Pointer to pathname string | Device ID (L = ID, H = 0) | Parse pathname into device ID (HL) and path component (DE); does not open anything |
| 44 | SYS_SET_MEMBOT | New DYNAMIC_MEMBOT value | 0 | Set bottom of user memory; used by extensions to make themselves resident |

**Note on SYS_PATH_PARSE:**

Errors: `ERR_NOT_FOUND` if the device name is not recognised; `ERR_INVALID_PARAM` if the path overflows the internal scratch buffer (path too long). On error, HL = 0 and DE is undefined.

The path component returned in DE may point into an internal scratch buffer. This buffer is overwritten by any subsequent syscall that performs path resolution (e.g. SYS_GLOBAL_OPENFILE, SYS_GLOBAL_OPENDIR, DEV_FCREATE, DEV_FREMOVE). Callers must consume or copy the path before making further syscalls.

## Data Structures

### Pathnames

Pathnames follow the format `[DEVID:][/][directory/]filename`. The leading slash before a directory name is optional. Examples:

| Pathname | Meaning |
|----------|---------|
| `foo` | File `foo` in current device and directory |
| `foo.bar` | File `foo.bar` in current device and directory |
| `a:foo` | File `foo` in root directory of device A |
| `a:somedir/foo` | File `foo` in directory `somedir` on device A |
| `a:/somedir/foo` | Same as above (leading slash is optional) |

Resolution rules:

- If DEVID is present, it may be a logical or physical device name. DEV_LOOKUP resolves it.
- If DEVID is absent, the current device (`CUR_DEVICE`) and current directory (`CUR_DIR`) are used.
- If DEVID is present but no path follows, the root directory of that device is used.
- If DEVID is present with a directory component (with or without leading `/`), the path is always absolute from the device root. The current working directory is not used.
- Pathnames are case-insensitive and are converted to uppercase when stored.

### MOUNT_PARAMS

Passed in DE to DEV_MOUNT. Variable-length structure.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 byte | Physical device ID of the underlying block device |
| 1 | N bytes | Null-terminated name string for the new filesystem physical device |

DEV_MOUNT validates the filesystem signature on the block device, allocates a new RAM PDT entry for the filesystem device, sets the PDT Parent field to the block device ID, and sets the block device's PDT Child field to the new filesystem device ID. On success, HL contains the physical device ID of the newly created filesystem device.

### DEV_FCREATE / DEV_DCREATE

DE points to a null-terminated filename or directory name string. The kernel sets the Type field automatically (bit 7 = used, bit 6 = directory for DEV_DCREATE). Attributes default to 0.

### SYS_INFO Buffer Format

The SYS_INFO syscall fills a 64-byte buffer pointed to by DE with the following fields:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 byte | Major version |
| 1 | 1 byte | Minor version |
| 2 | 1 byte | Patch version |
| 3 | 2 bytes | Build year |
| 5 | 1 byte | Build month |
| 6 | 1 byte | Build day |
| 7 | 2 bytes | Kernel size (bytes) |
| 9 | 55 bytes | Reserved |

## Error Codes

| Code | Name | Description |
|------|------|-------------|
| 0 | ERR_SUCCESS | Success (no error) |
| 1 | ERR_NOT_FOUND | File, directory, or device not found |
| 2 | ERR_EXISTS | File or directory already exists |
| 3 | ERR_NOT_SUPPORTED | Operation not supported by this device |
| 4 | ERR_INVALID_PARAM | Invalid parameter |
| 5 | ERR_INVALID_DEVICE | Invalid or unknown device identifier |
| 6 | ERR_NO_SPACE | Device or filesystem is full |
| 7 | ERR_IO | Hardware or device I/O error |
| 8 | ERR_NOT_OPEN | Device or file is not open |
| 9 | ERR_TOO_MANY_OPEN | No free slots in physical device table |
| 10 | ERR_READ_ONLY | Device or file is read-only |
| 11 | ERR_NOT_DIR | Expected a directory but found a file |
| 12 | ERR_NOT_FILE | Expected a file but found a directory |
| 13 | ERR_DIR_NOT_EMPTY | Directory is not empty and cannot be removed |
| 14 | ERR_BAD_FS | Filesystem signature not recognized or structure corrupt |
| 15 | ERR_EOF | End of file (DEV_BREAD) or no more directory entries |

## Pathname Resolution Algorithm

SYS_GLOBAL_OPENFILE and SYS_GLOBAL_OPENDIR implement the full pathname parsing rules above. The algorithm is:

1. Scan for `:`. If found, the text before it is a device name; call DEV_LOOKUP to resolve it. If not found, use the device ID stored in `CUR_DEVICE`.
2. The remainder of the string (after `:`, or the whole string if no `:`) is the path component.
3. If the path component is empty (bare `device:` with nothing after the colon, or an empty input with no device):
   - **SYS_GLOBAL_OPENFILE**: return the resolved device ID directly (DEVCAP_HANDLE is clear; DEV_CLOSE is a no-op).
   - **SYS_GLOBAL_OPENDIR**: open the root directory of the resolved device via DEV_DOPEN with an empty path string.
4. If the path component is non-empty and starts with `/` → use it as-is (absolute path from device root).
5. If the path component is non-empty and does not start with `/`:
   - Device was explicit and differs from `CUR_DEVICE` → treat as root-relative (use as-is).
   - Device was explicit and matches `CUR_DEVICE`, or no device prefix → prepend `CUR_DIR` and a `/` separator to form the full path, using the path resolver workspace buffer.
6. The assembled (device-id, path-string) pair is passed to DEV_FOPEN or DEV_DOPEN.

Path assembly in step 5 uses the `PATH_WORK` scratch buffer (see workspace layout in [Kernel](KERNEL.md)).

Errors:
- ERR_NOT_FOUND if the device name is not found by DEV_LOOKUP, or the file/directory is not found on the device.
- Any error propagated from DEV_FOPEN or DEV_DOPEN.

## Bootstrapping

The kernel and executive are assembled as a single 16 KB ROM image and reside in window 0 (0x0000–0x3FFF). The 8080/Z80 processor begins execution at address 0x0000, which is the RST 0 vector in ROM. This vector jumps to `kernel_init`, which configures the memory mapper so that windows 1–3 (0x4000–0xFFFF) are RAM, initializes the workspace at 0xF800, and starts the executive via `exec_main`.

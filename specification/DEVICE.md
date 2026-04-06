# NostOS Device Model

Devices are central to NostOS, and the primary purpose of the kernel is to serve as a device manager.

At the bottom level are **physical devices** — hardware such as serial interfaces and CompactFlash adapters, as well as pseudo-devices created at runtime for open files and directories.

Above the physical layer is the **logical device layer**, which provides a level of indirection allowing physical devices to be reassigned at runtime. For example, the console logical device can be pointed at different serial drivers without changing any other code.

## Device Types

| Type | Description |
|------|-------------|
| Character | Read and write one byte at a time |
| Screen | Character device with additional screen capabilities (cursor, attributes) |
| Block | Read and write 512-byte blocks of data |
| Filesystem | Block device with additional filesystem capabilities for reading and writing files |

## Device Identifiers

A device identifier is an 8-bit integer. Bit 7 distinguishes logical from physical devices:

| Bit 7 | Range | Type |
|-------|-------|------|
| 0 | 0x00–0x7F | Physical device |
| 1 | 0x80–0xFF | Logical device |

## Logical Device Table

The logical device table maps logical device identifiers to physical devices via short ASCII names.

### Logical device entry layout (8 bytes)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 byte | Logical device ID |
| 1 | 5 bytes | Short ASCII name (up to 4 characters + null terminator) |
| 6 | 2 bytes | Physical device pointer (16-bit pointer to PDT entry; 0 = unassigned) |

### Well-known logical devices

| ID | Name | Description |
|----|------|-------------|
| 0x80 | NUL | Null device |
| 0x81 | CONI | Console input device |
| 0x82 | CONO | Console output device |
| 0x83 | SERI | Serial input device |
| 0x84 | SERO | Serial output device |
| 0x85 | PRN | Printer device |
| 0x86–0xFF | A–Z | Filesystem devices (one letter each; not all can be used simultaneously due to table size limits) |

Console and serial devices are split into separate input and output logical devices so they can be independently redirected. For example, CONI can read from the ACIA while CONO writes to a different serial port.

## Physical Device Table

The physical device table (PDT) is a linked list of 32-byte entries. New devices are added at the front of the list. The list may span ROM and RAM — recently-added entries (open files, mounted filesystems) reside in the RAM PDT area, with the linked list eventually reaching static entries in ROM.

### PDT entry layout (32 bytes)

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 2 bytes | Next pointer | Pointer to next PDT entry (0 = end of list) |
| 2 | 1 byte | Physical device ID | Unique identifier for this device |
| 3 | 7 bytes | Short ASCII name | Up to 6 characters + null terminator |
| 10 | 1 byte | Capabilities | Bitmapped device capabilities (see below) |
| 11 | 1 byte | Parent device ID | Physical ID of parent device (e.g., filesystem for a file handle) |
| 12 | 1 byte | Child device ID | Physical ID of child device (e.g., mounted FS on a block device) |
| 13 | 2 bytes | DFT pointer | Pointer to the device function table |
| 15 | 17 bytes | User data | Device-specific data; pads entry to 32 bytes |

## Device Capabilities

The capabilities byte is a bitmapped field describing what operations a device supports.

| Bit | Name | Description |
|-----|------|-------------|
| 0 | CHAR_IN | Character input |
| 1 | CHAR_OUT | Character output |
| 2 | BLOCK_IN | Block input |
| 3 | BLOCK_OUT | Block output |
| 4 | FILESYSTEM | Filesystem operations |
| 5 | SUBDIRS | Filesystem supports subdirectories |
| 6 | SCREEN | Screen operations (cursor, attributes) |
| 7 | HANDLE | Closeable handle — set on PDT entries allocated by DEV_FOPEN or DEV_DOPEN. DEV_CLOSE checks this bit: if set, it calls the DFT Close slot and frees the PDT entry; if clear, it returns ERR_SUCCESS without doing anything. Permanent devices (ACIA, CF, NUL, etc.) never have this bit set. |

## Device Function Table

The device function table (DFT) is a table of function pointers used to access a device's operations. Each PDT entry contains a 16-bit pointer to its DFT. The DFT varies in size depending on the device type.

A common set of functions is shared across similar device types. Every device implements at least Initialize and GetStatus.

### Character DFT (4 slots)

| Slot | Function |
|------|----------|
| 0 | Initialize |
| 1 | GetStatus |
| 2 | ReadByte |
| 3 | WriteByte |

### Screen DFT (8 slots)

Screen devices extend the character DFT with display-specific operations.

| Slot | Function |
|------|----------|
| 0 | Initialize |
| 1 | GetStatus |
| 2 | ReadByte |
| 3 | WriteByte |
| 4 | ClearScreen |
| 5 | SetCursorPosition |
| 6 | GetCursorPosition |
| 7 | SetAttribute |

### Block DFT (9 slots)

| Slot | Function | Description |
|------|----------|-------------|
| 0 | Initialize | |
| 1 | GetStatus | |
| 2 | ReadBlock | Read one 512-byte block |
| 3 | WriteBlock | Write one 512-byte block |
| 4 | Seek | Set block position |
| 5 | GetPosition | Get current block position |
| 6 | GetLength | Get size |
| 7 | SetSize | Set file size |
| 8 | Close | Close a file or directory handle. No-op for non-closeable devices (e.g., CompactFlash, ramdisk). |

### Filesystem DFT (12 slots)

| Slot | Function | Description |
|------|----------|-------------|
| 0 | Initialize | |
| 1 | GetStatus | |
| 2 | CreateFile | Create a new file |
| 3 | OpenFile | Open a file; returns a pseudo-device ID for a block-device handle |
| 4 | CreateDirectory | Create a new directory |
| 5 | OpenDirectory | Open a directory; returns a pseudo-device ID for a directory handle |
| 6 | Rename | Rename a file or directory |
| 7 | Remove | Remove a file or directory |
| 8 | SetAttributes | Set file attributes (reserved) |
| 9 | GetAttributes | Get file attributes (reserved) |
| 10 | (reserved) | |
| 11 | FreeCount | Return the number of free blocks on the filesystem |

The OpenFile and OpenDirectory functions return pseudo-device identifiers that correspond to block-device entries in the PDT. These handles can then be used with DEV_BREAD, DEV_BWRITE, DEV_BSEEK, and DEV_CLOSE.

## Well-Known Physical Device IDs

Physical device IDs 0x01–0x0F are reserved for ROM-resident devices. IDs 0x10–0x7F are dynamically allocated at runtime for open file/directory handles, mounted filesystems, and extension devices.

| ID | Name | Caps | Type | Description |
|----|------|------|------|-------------|
| 0x01 | NUL | CI/CO | Character | Null device — discards output, returns EOF on input |
| 0x02 | ACIA | CI/CO | Character | 6850 ACIA UART serial |
| 0x03 | CF | BI/BO | Block | CompactFlash card |
| 0x05 | ROMD | BI | Block | ROM disk |
| 0x06 | RAMD | BI/BO | Block | RAM disk |
| 0x07 | SIOA | CI/CO | Character | SIO/2 channel A |
| 0x08 | SIOB | CI/CO | Character | SIO/2 channel B |
| 0x09 | ASC0 | CI/CO | Character | Z180 ASCI channel 0 |
| 0x0A | ASC1 | CI/CO | Character | Z180 ASCI channel 1 |
| 0x0B | SCCA | CI/CO | Character | SCC channel A  |
| 0x0C | SCCB | CI/CO | Character | SCC channel B  |
| 0x0D | FD | BI/BO | Block | WD37C65 floppy disk controller  |
| 0x0E | RND | CI | Character | Random number generator |
| 0x0F | BBL | BI/BO | Block | Intel 7220 bubble memory (32K SCC build only) |
| 0x10+ | (varies) | (varies) | (varies) | Dynamically allocated — file/dir handles, mounted filesystems, and extension devices |
| 0xFF | UN | — | Sentinel | Unassigned device — marks end of physical device chain |

**Caps key:** CI = char input, CO = char output, BI = block input, BO = block output, FS = filesystem, HND = handle (closeable).

Not all physical devices are present in every build. Each ROM variant includes only the serial driver for its target hardware (ACIA, SIO, Z180 ASCI, or SCC), plus the appropriate storage devices.

## Well-Known Logical Device IDs

Logical devices provide a level of indirection so applications can use generic names (e.g., CONO) without knowing the underlying hardware. The default physical device mappings below are for the ACIA build; other builds substitute the appropriate serial driver (e.g., SIOA, ASC0, SCCA).

| ID | Name | Default Physical | Description |
|----|------|-----------------|-------------|
| 0x80 | NUL | NUL (0x01) | Null device |
| 0x81 | CONI | ACIA (0x02) | Console input |
| 0x82 | CONO | ACIA (0x02) | Console output |
| 0x83 | SERI | UN (0xFF) | Serial input (unassigned by default) |
| 0x84 | SERO | UN (0xFF) | Serial output (unassigned by default) |
| 0x85 | PRN | UN (0xFF) | Printer (unassigned by default) |

Filesystem mount points (A:, C:, etc.) are also logical devices, created dynamically at boot by the automount table. These use IDs starting at 0x86.

Logical devices can be reassigned at runtime using the AS (assign) command or the DEV_LOG_ASSIGN syscall.

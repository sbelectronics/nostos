# NostOS Filesystem

NostOS supports a simple filesystem stored on a block device. It supports a root directory and nested subdirectories. Block size is 512 bytes. Filenames and directory names may be up to 16 characters in length. The current working directory path is limited to 31 characters.

A directory is represented as a file whose data blocks contain 32-byte directory entries.

## Filesystem Layout

| Block(s) | Contents |
|----------|----------|
| 0 | Filesystem header |
| 1 | Root directory inode |
| 2+ | Free space bitmap (1 or more contiguous blocks) |
| After bitmap | Root directory data blocks, file inodes, file data blocks |

### Filesystem Header (Block 0)

The header occupies block 0 (512 bytes). Only the first 13 bytes are defined; the remainder is reserved and should be written as zero.

| Offset | Size | Field |
|--------|------|-------|
| 0x00 | 4 bytes | Signature: `0x53 0x43 0x4F 0x54` (ASCII "SCOT") |
| 0x04 | 2 bytes | Number of blocks in the filesystem |
| 0x06 | 2 bytes | Root directory inode block (must be 1) |
| 0x08 | 2 bytes | Free space bitmap start block (must be 2) |
| 0x0A | 1 byte | Sectors per track (floppy only; 0 for block devices) |
| 0x0B | 1 byte | Tracks (floppy only; 0 for block devices) |
| 0x0C | 1 byte | Heads (floppy only; 0 for block devices) |
| 0x0D | 499 bytes | Reserved (set to 0) |

## Spans

A span is a contiguous sequence of blocks, described by a (FirstBlock, LastBlock) pair. Both values are inclusive — a span of (5, 7) covers blocks 5, 6, and 7 (3 blocks).

## Inodes

An inode occupies exactly one 512-byte block and describes which blocks belong to a file. It holds a list of spans and an optional link to a continuation inode.

For the initial version of the filesystem, only a single inode is supported per file (no continuation inodes). This limits a file to 126 spans. If a file becomes too fragmented to fit in 126 spans, an error is returned and the filesystem must be defragmented.

### Inode byte layout (512 bytes)

| Offset | Size | Field |
|--------|------|-------|
| 0x00 | 1 byte | Span count (0–126) |
| 0x01 | 1 byte | Reserved |
| 0x02 | 2 bytes | Next inode block number (0 = none) |
| 0x04 | 4 bytes | Reserved |
| 0x08 | 4 bytes | Span 0 |
| 0x0C | 4 bytes | Span 1 |
| ... | ... | ... |
| 0x1FC | 4 bytes | Span 125 |

The header is 8 bytes, followed by up to 126 span entries of 4 bytes each (8 + 126 × 4 = 512).

### Span entry format (4 bytes)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 2 bytes | FirstBlock (inclusive) |
| 2 | 2 bytes | LastBlock (inclusive) |

## Directory Entries

Each directory entry is exactly 32 bytes. A directory's data blocks contain a packed array of these entries (16 entries per 512-byte block).

### Directory entry byte layout (32 bytes)

| Offset | Size | Field |
|--------|------|-------|
| 0x00 | 1 byte | Type (bit 7 = used, bit 6 = directory, bits 5–0 reserved) |
| 0x01 | 17 bytes | Name (null-terminated, max 16 chars + null) |
| 0x12 | 4 bytes | Size (file size in bytes; 0 for directories) |
| 0x16 | 4 bytes | Modification date/time (set to 0; no RTC in prototype) |
| 0x1A | 1 byte | Attributes (reserved; set to 0) |
| 0x1B | 1 byte | Owner (reserved; set to 0) |
| 0x1C | 2 bytes | Inode block number |
| 0x1E | 2 bytes | Unused (set to 0) |

### Type field

| Bit | Meaning |
|-----|---------|
| 7 | 1 = entry is in use, 0 = entry is free/deleted |
| 6 | 1 = directory, 0 = file |
| 5–0 | Reserved for future use |

## Free Space Bitmap

The free space bitmap is stored as raw data blocks (not through an inode). It begins at block 2 and continues for as many contiguous blocks as are needed: `ceil(num_blocks / 4096)` blocks, since each 512-byte block holds 4096 bits.

Each bit represents one filesystem block:
- **1** = block is free
- **0** = block is in use

Bit ordering is LSB-first:

| Block N | Byte | Bit |
|---------|------|-----|
| Block 0 | byte 0, bit 0 | `0x01` |
| Block 7 | byte 0, bit 7 | `0x80` |
| Block 8 | byte 1, bit 0 | `0x01` |
| Block N | byte `N / 8` | bit `N mod 8` |

The bitmask for block N can be computed by indexing into a lookup table: `{0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80}` using `N mod 8`.

When searching for a free block, the allocator uses a first-fit strategy — the first free block encountered is used.

## Known Limitations

### Directories do not shrink

When files or subdirectories are added to a directory, new data blocks are allocated to hold the additional directory entries (16 entries per 512-byte block). When entries are later deleted, the type byte is cleared (marking the slot as free), but the directory data blocks themselves are never deallocated. This means a directory that once held many entries will retain its expanded block allocation even after most entries are removed.

This is standard behavior for simple filesystems (FAT works the same way). The unused slots will be reused by future file creation in the same directory, so the space is not permanently lost — it is simply reserved for directory use.

This can be observed with the FREE command: creating many files in a directory and then deleting all of them will show a free block count lower than the original by the number of directory blocks that were allocated during expansion.

## Working with Files

DEV_FOPEN and DEV_DOPEN return pseudo-device identifiers in the physical device table. The number of simultaneously open files is limited by the number of available PDT entries (total entries minus those used for permanent devices).

### Open file/directory handle layout

When DEV_FOPEN or DEV_DOPEN allocates a pseudo-device PDT entry, the 17-byte user data area (`PHYSDEV_OFF_DATA`, offset 15 in the PDT entry) holds all per-handle state. The handle uses 16 of the 17 available bytes.

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | 1 byte | Flags | bit 0 = writable, bit 7 = is-directory |
| 1 | 2 bytes | Root inode block | First inode block; needed for seek-to-start |
| 3 | 3 bytes | File size (bytes) | Copied from directory entry; 0 for directories |
| 6 | 2 bytes | Current block position | Block index; updated by DEV_BREAD/BWRITE/BSEEK |
| 8 | 2 bytes | Cached span first PBA | First physical block address of the cached span |
| 10 | 2 bytes | Cached span last PBA | Last physical block address of the cached span |
| 12 | 2 bytes | Cached span LBA offset | Logical block at which cached span starts (0xFFFF = invalid) |
| 14 | 2 bytes | Parent directory inode | Inode of the parent directory; used for size flush on write |

The per-handle span cache fields (offsets 8–13) allow the driver to translate a logical block position to a physical block address without re-reading the inode. When a read/write crosses out of the cached span, the driver walks the inode span table to locate the new span and updates the cache. This cache is separate from the workspace-level directory span cache (`FS_SPAN_CACHE`, see [Kernel](KERNEL.md)), which is used by directory traversal operations that don't have an open file handle.

### Directory enumeration

For directory handles (bit 7 set in Flags), the block position field stores a **directory entry index** (not a block number).

- **DEV_BSEEK** with DE=0 resets the entry index to the start.
- **DEV_BREAD** reads one 32-byte directory entry into the first 32 bytes of the caller's 512-byte buffer and advances the entry index by one.
- **DEV_BREAD** returns ERR_EOF when no more entries remain.

This replaces the DIR_FIRST/DIR_NEXT syscalls, which exist as stubs but are not implemented.

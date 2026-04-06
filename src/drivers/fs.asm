; ============================================================
; fs.asm - Filesystem Driver
; Implements an 8080-compatible block-backed filesystem driver
; ============================================================

; ============================================================
; Working Space (in KERN_TEMP_SPACE)
; ============================================================
; KERN_TEMP_SPACE is at 0x0780. We allocate variables here.
fs_temp_blk_id      EQU KERN_TEMP_SPACE + 0     ; physical device ID of underlying block device (1 byte)
fs_temp_inode       EQU KERN_TEMP_SPACE + 1     ; current inode block being processed (2 bytes)
fs_temp_name        EQU KERN_TEMP_SPACE + 3     ; null-terminated name buffer (17 bytes)
fs_temp_dir_entry   EQU KERN_TEMP_SPACE + 20    ; temporary holding for directory entry (32 bytes)
fs_temp_pdt_slot    EQU KERN_TEMP_SPACE + 52    ; pointer to free PDT slot (2 bytes)
; Available up to 0x07FF (128 bytes total).

; ============================================================
; Filesystem Constants
; ============================================================
FS_BLOCK_SIZE       EQU 512
FS_ROOT_INODE       EQU 1
FS_BITMAP_START     EQU 2       ; bitmap data starts at this block (no inode)

; Inode offsets
INODE_OFF_COUNT     EQU 0       ; Span count (1 byte)
INODE_OFF_NEXT      EQU 2       ; Next inode block (2 bytes)
INODE_OFF_SPANS     EQU 8       ; Start of spans array

; Directory entry structure: see constants.asm (DIRENT_OFF_*, DIRENT_TYPE_*)

; Open Handle (PDT User Data) Offsets (17 bytes max, 16 used)
HND_OFF_FLAGS       EQU 0       ; bit0=writable, bit7=is-dir (1 byte)
HND_OFF_ROOT_INODE  EQU 1       ; Root inode block (2 bytes)
HND_OFF_FILESIZE    EQU 3       ; File size in bytes (3 bytes)
HND_OFF_POS         EQU 6       ; Current block position (2 bytes)
HND_OFF_SPAN_FIRST  EQU 8       ; First PBA of cached span (2 bytes)
HND_OFF_SPAN_LAST   EQU 10      ; Last PBA of cached span (2 bytes)
HND_OFF_SPAN_LBA_OFF EQU 12    ; LBA at which cached span starts (2 bytes, 0xFFFF=invalid)
HND_OFF_PARENT_INO  EQU 14      ; Parent directory inode (2 bytes)

HND_FLAG_DIR        EQU 0x80
HND_FLAG_WRITE      EQU 0x01

; ============================================================
; Filesystem Base (dft_fs) Functions
; ============================================================

; ------------------------------------------------------------
; fs_init
; Initialize the filesystem device.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_SUCCESS
;   HL - 0
; ------------------------------------------------------------
fs_init:
fs_getstatus:
    XOR  A                      ; A = ERR_SUCCESS (0)
    LD   H, A
    LD   L, A                   ; HL = 0
    RET

; ------------------------------------------------------------
; fs_not_supported
; Standard stub for unimplemented filesystem operations.
; Inputs:
;   (none)
; Outputs:
;   A  - ERR_NOT_SUPPORTED
;   HL - 0
; ------------------------------------------------------------
fs_not_supported:
    LD   A, ERR_NOT_SUPPORTED
    LD   HL, 0
    RET

; ============================================================
; Device Function Tables
; ============================================================

; DFT for the base filesystem mounted device
dft_fs:
    DEFW fs_init                ; slot 0: Initialize
    DEFW fs_getstatus           ; slot 1: GetStatus
    DEFW fs_fcreate             ; slot 2: CreateFile
    DEFW fs_fopen               ; slot 3: OpenFile
    DEFW fs_dcreate             ; slot 4: CreateDir
    DEFW fs_dopen               ; slot 5: OpenDir
    DEFW fs_rename              ; slot 6: Rename
    DEFW fs_remove              ; slot 7: Remove
    DEFW fs_not_supported       ; slot 8: SetAttributes
    DEFW fs_not_supported       ; slot 9: GetAttributes
    DEFW fs_not_supported       ; slot 10: (reserved)
    DEFW fs_free_count          ; slot 11: FreeCount

; DFT for an open file (block semantics)
dft_file:
    DEFW fs_init                ; slot 0: Initialize
    DEFW fs_getstatus           ; slot 1: GetStatus
    DEFW fs_file_bread          ; slot 2: ReadBlock
    DEFW fs_file_bwrite         ; slot 3: WriteBlock
    DEFW fs_file_seek           ; slot 4: Seek
    DEFW fs_file_bgetpos        ; slot 5: GetPosition
    DEFW fs_file_bgetsize       ; slot 6: GetLength
    DEFW fs_file_bsetsize       ; slot 7: SetSize
    DEFW fs_close               ; slot 8: Close

; DFT for an open directory (directory semantics)
dft_dir:
    DEFW fs_init                ; slot 0: Initialize
    DEFW fs_getstatus           ; slot 1: GetStatus
    DEFW fs_dir_bread           ; slot 2: ReadBlock
    DEFW fs_not_supported       ; slot 3: WriteBlock
    DEFW fs_file_seek           ; slot 4: Seek (shared with file)
    DEFW fs_file_bgetpos        ; slot 5: GetPosition (shared with file)
    DEFW fs_not_supported       ; slot 6: GetLength
    DEFW fs_not_supported       ; slot 7: SetSize
    DEFW fs_close               ; slot 8: Close

    INCLUDE "src/drivers/fs_alloc.asm"
    INCLUDE "src/drivers/fs_dir.asm"
    INCLUDE "src/drivers/fs_open.asm"
    INCLUDE "src/drivers/fs_io.asm"
    INCLUDE "src/drivers/fs_io_dir.asm"
    INCLUDE "src/drivers/fs_io_file.asm"
    INCLUDE "src/drivers/fs_io_write.asm"
    INCLUDE "src/drivers/fs_create.asm"
    INCLUDE "src/drivers/fs_remove.asm"
    INCLUDE "src/drivers/fs_rename.asm"

; ------------------------------------------------------------
; fs_read_block
; Read a single 512-byte block from the underlying block device.
; Inputs:
;   DE - pointer to 512-byte destination buffer
;   HL - block number (0-65535)
;   (fs_temp_blk_id must contain the underlying physical device ID)
; Outputs:
;   A  - ERR_SUCCESS or error code
; ------------------------------------------------------------
fs_read_block:
    PUSH HL                     ; preserve HL (block number)
    ; 1. Seek to the block
    PUSH BC                     ; preserve BC
    PUSH DE                     ; save buffer pointer
    EX   DE, HL                 ; DE = block number, HL = buffer ptr (ignored)
    LD   A, (fs_temp_blk_id)
    LD   B, A
    LD   C, DEV_BSEEK
    CALL syscall_entry          ; DE=block, B=dev, C=syscall
    POP  DE                     ; restore buffer pointer
    OR   A
    JP   NZ, fs_read_block_err

    ; 2. Read the block
    PUSH DE
    LD   A, (fs_temp_blk_id)
    LD   B, A
    LD   C, DEV_BREAD           ; DE=buffer, B=dev, C=syscall
    CALL syscall_entry
    POP  DE

fs_read_block_err:
    POP  BC                     ; restore BC
    POP  HL                     ; restore HL (block number)
    RET

; ------------------------------------------------------------
; fs_write_block
; Write a single 512-byte block to the underlying block device.
; Inputs:
;   DE - pointer to 512-byte source buffer
;   HL - block number (0-65535)
;   (fs_temp_blk_id must contain the underlying physical device ID)
; Outputs:
;   A  - ERR_SUCCESS or error code
; ------------------------------------------------------------
fs_write_block:
    PUSH HL                     ; preserve HL (block number)
    ; 1. Seek to the block
    PUSH BC                     ; preserve BC
    PUSH DE                     ; save buffer pointer
    EX   DE, HL                 ; DE = block number, HL = buffer ptr (ignored)
    LD   A, (fs_temp_blk_id)
    LD   B, A
    LD   C, DEV_BSEEK
    CALL syscall_entry
    POP  DE                     ; restore buffer pointer
    OR   A
    JP   NZ, fs_write_block_err

    ; 2. Write the block
    PUSH DE
    LD   A, (fs_temp_blk_id)
    LD   B, A
    LD   C, DEV_BWRITE          ; DE=buffer, B=dev
    CALL syscall_entry
    POP  DE

fs_write_block_err:
    POP  BC                     ; restore BC
    POP  HL                     ; restore HL (block number)
    RET


; ------------------------------------------------------------
; fs_read_inode
; Read an inode from disk into DISK_BUFFER.
; Inputs:
;   HL - inode block number
;   (fs_temp_blk_id must contain block device ID)
; Outputs:
;   A  - ERR_SUCCESS or error code
;   (DISK_BUFFER contains inode data on success)
; ------------------------------------------------------------
fs_read_inode:
    ; Store current inode number for tracking
    LD   A, L
    LD   (fs_temp_inode), A
    LD   A, H
    LD   (fs_temp_inode + 1), A

    LD   DE, DISK_BUFFER
    JP   fs_read_block


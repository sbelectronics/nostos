; ============================================================
; Filesystem Allocation Helpers (8080 Compatible)
; ============================================================

fs_temp_alloc_blk   EQU KERN_TEMP_SPACE + 60    ; Temp variable for bitmap block number (2 bytes)
fs_temp_alloc_ptr   EQU KERN_TEMP_SPACE + 62    ; Temp variable for buffer pointer (2 bytes)

; ------------------------------------------------------------
; fs_alloc_block
; Scans the free space bitmap for the first available block,
; marks it as used, writes the bitmap back to disk, and returns it.
; Inputs:
;   (fs_temp_blk_id) - physical device ID of block device
; Outputs:
;   A  - ERR_SUCCESS and HL = new block number
;        OR ERR_NO_SPACE / ERR_IO
;   HL - new block number on success, 0 on error
; ------------------------------------------------------------
fs_alloc_block:
    PUSH BC                     ; preserve BC
    PUSH DE                     ; preserve DE

    ; Read bitmap data block (always at FS_BITMAP_START)
    LD   HL, FS_BITMAP_START
    LD   (fs_temp_alloc_blk), HL
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    JP   NZ, fs_alloc_block_exit

    ; Scan DISK_BUFFER for a free bit (indicated by 1)
    LD   HL, DISK_BUFFER
    LD   BC, 0                  ; BC = block index (byte_idx * 8 + bit_idx)

fs_alloc_scan_bytes:
    LD   A, (HL)
    OR   A
    JP   NZ, fs_alloc_found_byte

    ; Next byte
    INC  HL
    ; Add 8 to BC
    LD   A, C
    ADD  A, 8
    LD   C, A
    LD   A, B
    ADC  A, 0
    LD   B, A

    ; Check if we exceeded 512 bytes (4096 blocks)
    ; HL starts at DISK_BUFFER (0x0400) and should not reach DISK_BUFFER+FS_BLOCK_SIZE (0x0600)
    LD   A, H
    CP   (DISK_BUFFER + FS_BLOCK_SIZE) >> 8
    JP   C, fs_alloc_scan_bytes

    ; No free blocks found in this sector
    LD   A, ERR_NO_SPACE
    LD   HL, 0
    JP   fs_alloc_block_exit

fs_alloc_found_byte:
    ; We found a byte with a free bit at (HL).
    ; Save the byte pointer.
    LD   D, H
    LD   E, L
    LD   HL, fs_temp_alloc_ptr
    LD   (HL), E
    INC  HL
    LD   (HL), D

    ; Find the specific bit (0-7).
    EX   DE, HL                 ; HL = byte pointer
    LD   D, 0                   ; D = bit index
    LD   A, (HL)                ; A = the byte
fs_alloc_find_bit:
    RRA                         ; Shift bit 0 into Carry
    JP   C, fs_alloc_got_bit
    INC  D
    ; BC++
    INC  BC
    JP   fs_alloc_find_bit

fs_alloc_got_bit:
    ; We found a free bit at bit D. D is 0..7.
    ; BC contains the absolute block number. Push it to use BC for mask.
    PUSH BC

    ; Mark it as used (clear the bit) in the byte at (HL).
    ; Mask = ~(1 << D)
    LD   C, 1
fs_alloc_shift_loop:
    LD   A, D
    OR   A
    JP   Z, fs_alloc_shift_done
    ; Shift C left by 1
    LD   A, C
    ADD  A
    LD   C, A
    DEC  D
    JP   fs_alloc_shift_loop

fs_alloc_shift_done:
    LD   A, C                   ; A = 1 << D
    CMA                         ; A = ~(1 << D)
    LD   E, A                   ; E = mask

    ; Read byte pointer
    LD   HL, fs_temp_alloc_ptr
    LD   C, (HL)
    INC  HL
    LD   B, (HL)
    LD   H, B
    LD   L, C                   ; HL = byte pointer

    ; Apply mask
    LD   A, (HL)
    AND  E
    LD   (HL), A                ; Byte is updated

    ; Write the bitmap block back to disk
    LD   HL, fs_temp_alloc_blk
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    EX   DE, HL                 ; HL = bitmap block number
    LD   DE, DISK_BUFFER
    CALL fs_write_block
    OR   A
    JP   NZ, fs_alloc_write_err

    ; Restore newly allocated block number into HL
    POP  BC
    LD   H, B
    LD   L, C

    ; Ensure block is not 0, 1, or 2 (header, root inode, bitmap data).
    LD   A, H
    OR   A
    JP   NZ, fs_alloc_success
    LD   A, L
    CP   3
    JP   NC, fs_alloc_success

    ; We tried to allocate block 0, 1, or 2. This is bad.
    LD   A, ERR_IO
    LD   HL, 0
    JP   fs_alloc_block_exit

fs_alloc_write_err:
    ; fs_write_block failed; A = error code
    POP  BC                     ; discard saved block number
    LD   HL, 0
    JP   fs_alloc_block_exit

fs_alloc_success:
    XOR  A
    ; HL = block number (set above from POP BC → LD H,B / LD L,C)

fs_alloc_block_exit:
    POP  DE                     ; restore DE
    POP  BC                     ; restore BC
    RET

; ------------------------------------------------------------
; fs_free_count (dft_fs slot 11)
; Return the number of free blocks on the filesystem.
; Inputs:
;   B  - filesystem device ID
; Outputs:
;   A  - ERR_SUCCESS or error code
;   HL - free block count on success, 0 on error
; ------------------------------------------------------------
fs_free_count:
    PUSH BC
    PUSH DE

    ; 1. Get underlying block device
    CALL fs_get_block_dev
    OR   A
    JP   NZ, fs_free_count_err
    LD   A, L
    LD   (fs_temp_blk_id), A

    ; 2. Read bitmap data block into DISK_BUFFER
    LD   HL, FS_BITMAP_START
    LD   DE, DISK_BUFFER
    CALL fs_read_block
    OR   A
    JP   NZ, fs_free_count_err

    ; 3. Count set bits (bit=1 means free block) in all 512 bytes
    LD   HL, DISK_BUFFER        ; HL = byte pointer
    LD   BC, 0                  ; BC = running free count

fs_free_count_byte:
    LD   A, H
    CP   (DISK_BUFFER + FS_BLOCK_SIZE) >> 8
    JP   NC, fs_free_count_done

    LD   A, (HL)                ; load next bitmap byte
    INC  HL
    LD   D, 8                   ; D = bits remaining in this byte

fs_free_count_bits:
    RRA                         ; shift bit 0 into carry
    JP   NC, fs_free_count_zero
    INC  BC                     ; bit was 1: free block
fs_free_count_zero:
    DEC  D
    JP   NZ, fs_free_count_bits
    JP   fs_free_count_byte

fs_free_count_done:
    LD   H, B
    LD   L, C                   ; HL = free block count
    XOR  A
    POP  DE
    POP  BC
    RET

fs_free_count_err:
    LD   HL, 0
    POP  DE
    POP  BC
    RET

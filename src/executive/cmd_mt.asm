; ============================================================
; cmd_mt.asm - MOUNT command handler
; ============================================================
; MT / MOUNT <blkdev> <newname>
;   blkdev  - physical block device name (e.g. CF)
;   newname - name to give the new filesystem device (e.g. FS)
;
; Looks up <blkdev> by name, then calls DEV_MOUNT with a
; MOUNT_PARAMS buffer built in KERN_TEMP_SPACE:
;   byte 0:  physical device ID of block device
;   byte 1+: null-terminated name string for new FS device
;
; Register / stack protocol:
;   After token 1 is parsed, DE = blkname ptr (upcase'd in INPUT_BUFFER).
;   physname ptr is saved on the stack while DEV_PHYS_LOOKUP runs.
;   EX (SP), HL swaps physname ptr <-> blk_dev_id on the stack.
; ============================================================
cmd_mt:
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, cmd_mt_usage            ; no args

    ; --- Token 1: blkdev name ---
    LD   D, H
    LD   E, L                       ; DE = blkdev name start
    CALL exec_upcase_delimit        ; upcase+null-terminate; HL = next; DE preserved
    CALL exec_strip_colon           ; strip trailing ':' if present
    CALL exec_skip_spaces           ; HL = newname start or null

    LD   A, (HL)
    OR   A
    JP   Z, cmd_mt_usage            ; missing newname

    ; --- Token 2: new FS device name ---
    PUSH HL                         ; [SP] = newname ptr
    ; DE = blkdev name; look it up as a physical device
    LD   B, 0
    LD   C, DEV_PHYS_LOOKUP
    CALL KERNELADDR                 ; A = status, HL = physical device ID
    CP   ERR_SUCCESS
    JP   NZ, cmd_mt_bad_blkdev_pop

    ; Swap: save blk_dev_id on stack, retrieve newname ptr into HL.
    EX   (SP), HL                   ; HL = newname ptr; [SP] = blk_dev_id (in HL from lookup)

    ; Upcase and null-terminate the newname in place.
    LD   D, H
    LD   E, L                       ; DE = newname start
    CALL exec_upcase_delimit        ; HL = past token; newname null-terminated in buffer
    CALL exec_strip_colon           ; strip trailing ':' if present

    ; --- Build MOUNT_PARAMS in KERN_TEMP_SPACE ---
    ; KERN_TEMP_SPACE[0] = blk_dev_id (pop from stack into A)
    ; DE = newname start (preserved by exec_upcase_delimit and exec_strip_colon)
    POP  HL                         ; HL = blk_dev_id (returned in HL by DEV_PHYS_LOOKUP)
    LD   A, L                       ; A = blk_dev_id (low byte)
    LD   (KERN_TEMP_SPACE), A

    ; Copy newname from input buffer into KERN_TEMP_SPACE+1
    ; DE still points to the newname start (upcased, colon-stripped)
    LD   H, D
    LD   L, E                       ; HL = newname start
    LD   DE, KERN_TEMP_SPACE + 1
cmd_mt_copy_name:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    OR   A
    JP   NZ, cmd_mt_copy_name      ; copy including null terminator

    ; --- Call DEV_MOUNT ---
    LD   B, 0                       ; B unused by DEV_MOUNT
    LD   DE, KERN_TEMP_SPACE        ; DE = MOUNT_PARAMS
    LD   C, DEV_MOUNT
    CALL KERNELADDR                 ; A = status, HL = new device ID
    CP   ERR_SUCCESS
    JP   NZ, cmd_mt_error

    LD   DE, msg_mt_ok
    CALL exec_puts
    RET

cmd_mt_bad_blkdev_pop:
    POP  HL                         ; discard newname ptr (clean stack)
    LD   DE, msg_mt_bad_blkdev
    CALL exec_puts
    RET

cmd_mt_error:
    CALL exec_print_error
    RET

cmd_mt_usage:
    LD   DE, msg_mt_usage
    CALL exec_puts
    RET

msg_mt_ok:
    DEFM "Mounted.", 0x0D, 0x0A, 0
msg_mt_usage:
    DEFM "Usage: MT <blkdev> <newname>", 0x0D, 0x0A, 0
msg_mt_bad_blkdev:
    DEFM "Unknown block device.", 0x0D, 0x0A, 0

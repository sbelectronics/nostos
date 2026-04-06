; ============================================================
; cmd_lp.asm - LP command handler
; ============================================================
; LP: list physical devices
cmd_lp:
    LD   HL, (PHYSDEV_LIST_HEAD)
cmd_lp_loop:
    LD   A, H
    OR   L
    JP   Z, cmd_lp_exit         ; end of list if HL=0

    PUSH HL                     ; save node pointer

    ; Print PhysID
    INC  HL
    INC  HL                     ; offset 2
    LD   A, (HL)
    CALL exec_print_dec8
    CALL exec_print_space

    ; Print PhysName
    INC  HL                     ; offset 3
    CALL exec_print_devname

    ; Check for parent device (offset 11 = PHYSDEV_OFF_PARENT)
    POP  HL                     ; restore node pointer
    PUSH HL                     ; save it again for next iteration
    LD   DE, PHYSDEV_OFF_PARENT
    ADD  HL, DE
    LD   A, (HL)
    OR   A
    JP   Z, cmd_lp_no_parent    ; parent == 0: no parent (ROM devices)
    CP   PHYSDEV_ID_UN
    JP   Z, cmd_lp_no_parent    ; parent == 0xFF: unassigned
    ; Has a parent -- look up its PDT entry
    LD   B, A
    LD   C, DEV_PHYS_GET
    CALL KERNELADDR
    CP   ERR_SUCCESS
    JP   NZ, cmd_lp_no_parent
    ; HL = parent PDT entry pointer
    LD   DE, PHYSDEV_OFF_NAME
    ADD  HL, DE                 ; HL = parent name
    ; Print " on NAME:"
    PUSH HL
    LD   DE, cmd_lp_on_str
    CALL exec_puts
    POP  HL
    CALL exec_print_devname
cmd_lp_no_parent:
    CALL exec_crlf

    POP  HL                     ; restore node pointer
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    EX   DE, HL                 ; move to next
    JP   cmd_lp_loop

cmd_lp_exit:
    RET

cmd_lp_on_str:  DEFM " on ", 0

; ============================================================
; cmd_ll.asm - LL command handler
; ============================================================
; LL: list logical devices
cmd_ll:
    LD   B, 0
cmd_ll_loop:
    PUSH BC                     ; save loop counter B
    ; HL = LOGDEV_TABLE + B * 8
    LD   HL, LOGDEV_TABLE
    LD   A, B
    ADD  A, A                   ; A = B * 2
    ADD  A, A                   ; A = B * 4
    ADD  A, A                   ; A = B * 8
    LD   E, A
    LD   D, 0
    ADD  HL, DE
    PUSH HL                     ; save entry base for use if physptr is non-zero

    ; Check physptr == 0? If so, unused
    LD   DE, LOGDEV_OFF_PHYSPTR
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    LD   A, D
    OR   E
    JP   Z, cmd_ll_next_skip    ; skip if physptr is 0

    POP  HL                     ; restore entry base

    ; Print LogID (B | 0x80); B still valid (not clobbered since PUSH BC)
    LD   A, B
    OR   0x80
    CALL exec_print_dec8
    CALL exec_print_space

    ; Print LogName
    INC  HL                     ; move to name
    CALL exec_print_devname

    ; Print " -> "
    LD   DE, msg_arrow
    CALL exec_puts

    ; Recover PhysPtr (LOGDEV_OFF_PHYSPTR = 6; name starts at offset 1, so +5 to reach offset 6)
    INC  HL
    INC  HL
    INC  HL
    INC  HL
    INC  HL
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    EX   DE, HL                 ; HL = PhysPtr

    ; Print PhysID
    INC  HL
    INC  HL                     ; move to ID
    LD   A, (HL)
    CALL exec_print_dec8
    CALL exec_print_space

    ; Print PhysName
    INC  HL                     ; move to name
    CALL exec_print_devname
    CALL exec_crlf
    JP   cmd_ll_next            ; taken path: entry base already popped above

cmd_ll_next_skip:
    POP  HL                     ; discard saved entry base (skip path only)
cmd_ll_next:
    POP  BC                     ; restore loop counter B
    INC  B
    LD   A, B
    CP   LOGDEV_MAX
    JP   NZ, cmd_ll_loop
    RET

msg_arrow:
    DEFM " -> ", 0

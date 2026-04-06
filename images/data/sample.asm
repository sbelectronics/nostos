    org 0
    push hl
    push bc
    ld de, msg
    ld b, 0x82
    ld c, 16
    call 0x0010
    pop bc
    pop hl
    ld c, 0
    call 0x0010
msg:
    defm "Hello from Zealasm!"
    defb 0x0D
    defb 0x0A
    defb 0

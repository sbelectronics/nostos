; ============================================================
; helloworld.asm - Hello World application for NostOS
; Relocatable application — assembled with ORG 0 and processed
; by mkreloc.py into the NostOS relocatable format.
; ============================================================

    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header to main
    JP   helloworld_main

    ; Header pad: 13 bytes of zeros (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; helloworld_main - entry point (at 0x0810)
; ============================================================
helloworld_main:
    LD   B, LOGDEV_ID_CONO       ; B = logical console device
    LD   DE, msg_hello          ; DE = pointer to string
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Data
; ============================================================
msg_hello:
    DEFM "Hello, World!", 0x0D, 0x0A, 0

; NostOS executive standalone test
;
; The executive should not invoke any of the kernel's private symbols. By assembling the
; executive by itself, we can verify this is true.

    org 0x0000

    INCLUDE "src/include/constants.asm"
    INCLUDE "src/include/mapper_config.asm"
    INCLUDE "src/include/syscall.asm"

    INCLUDE "src/executive/executive.asm"

; NostOS main assembly files
;
; Includes Interrupt Vectors, Kernel, and Executive.

    org 0x0000

    INCLUDE "build/build_info.asm"
    INCLUDE "src/include/constants.asm"
    INCLUDE "src/include/mapper_config.asm"
    INCLUDE "src/include/syscall.asm"
    
    INCLUDE "src/vectors/vectors.asm"
    INCLUDE "src/kernel/kernel.asm"

    INCLUDE "src/executive/executive.asm"

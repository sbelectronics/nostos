; ------------------------------------------------------------
; memzero
; Zero BC bytes of memory starting at HL.
; Inputs:
;   HL - start address
;   BC - number of bytes to zero
; Outputs:
;   HL - address one past the last zeroed byte
;   BC - 0
; ------------------------------------------------------------
memzero:
    PUSH AF                     ; preserve AF (A used as temp)
    LD   A, B
    OR   C
    JP   Z, memzero_done
memzero_loop:
    XOR  A
    LD   (HL), A
    INC  HL
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, memzero_loop
memzero_done:
    POP  AF                     ; restore AF
    RET

; ------------------------------------------------------------
; strcpy
; Copy a null-terminated string from HL to DE.
; Inputs:
;   HL - source address
;   DE - destination address
; Outputs:
;   HL - address one past the source null terminator
;   DE - address one past the destination null terminator
; ------------------------------------------------------------
strcpy:
    PUSH AF                     ; preserve AF (A used as temp)
strcpy_loop:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    OR   A
    JP   NZ, strcpy_loop
    POP  AF                     ; restore AF
    RET

; ------------------------------------------------------------
; memcpy
; Copy BC bytes from HL to DE.
; Inputs:
;   HL - source address
;   DE - destination address
;   BC - byte count (0 = no-op)
; Outputs:
;   HL - one past last source byte
;   DE - one past last destination byte
;   BC - 0
; ------------------------------------------------------------
memcpy:
    PUSH AF
    LD   A, B
    OR   C
    JP   Z, memcpy_done
memcpy_loop:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, memcpy_loop
memcpy_done:
    POP  AF
    RET

; ------------------------------------------------------------
; strcasecmp_hl_de
; Compare null-terminated strings at HL and DE, case-insensitively.
; Inputs:
;   HL - pointer to first string
;   DE - pointer to second string
; Outputs:
;   Z   - set if strings are equal (case-insensitively), clear if not
;   A   - clobbered
;   B   - clobbered
;   HL  - advanced (clobbered)
;   DE  - advanced (clobbered)
; ------------------------------------------------------------
strcasecmp_hl_de:
    ; Load and upcase char from DE into B
    LD   A, (DE)
    CP   'a'
    JP   C, strcasecmp_hl_de_s1
    CP   'z' + 1
    JP   NC, strcasecmp_hl_de_s1
    SUB  0x20
strcasecmp_hl_de_s1:
    LD   B, A                   ; B = upcased char from DE
    ; Load and upcase char from HL into A
    LD   A, (HL)
    CP   'a'
    JP   C, strcasecmp_hl_de_cmp
    CP   'z' + 1
    JP   NC, strcasecmp_hl_de_cmp
    SUB  0x20
strcasecmp_hl_de_cmp:
    CP   B
    RET  NZ                     ; mismatch
    OR   A                      ; Z set if both upcased chars are null
    RET  Z                      ; both null: strings are equal
    INC  HL
    INC  DE
    JP   strcasecmp_hl_de

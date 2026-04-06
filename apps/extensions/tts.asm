; ============================================================
; tts.asm - Text-to-Speech extension for NostOS
; Registers a character device "TTS" that converts ASCII text
; to SP0256A-AL2 phonemes using NRL rule-based synthesis.
;
; WriteByte: accumulates characters into a word buffer. On
;   space, punctuation, or CR, translates the word and outputs
;   phonemes to the parent device.
; ReadByte:  returns ERR_NOT_SUPPORTED (output-only device).
;
; Based on NRL text-to-speech rules (Retrospeak by Jason Lane,
; ported by Scott Baker).
; ============================================================

    INCLUDE "../../src/include/syscall.asm"
    INCLUDE "../../src/include/constants.asm"

    ORG  0

TTS_PHYSDEV_ID      EQU 0x00    ; 0 = dynamically allocated by DEV_COPY
TTS_MAX_WLEN        EQU 32      ; max word length

; ============================================================
; Entry point
; ============================================================
tts_main:
    ; Look up SP0 device by name
    LD   DE, tts_sp0_name
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    OR   A
    JP   NZ, tts_no_sp0

    ; L = device ID from DEV_LOOKUP
    ; Store it as parent in the PDT template before DEV_COPY
    LD   A, L
    LD   (tts_pdt_parent), A

    ; Register device
    LD   DE, tts_pdt
    LD   C, DEV_COPY
    CALL KERNELADDR
    OR   A
    JP   NZ, tts_err

    ; Print success
    LD   B, LOGDEV_ID_CONO
    LD   DE, tts_msg_ok
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Make extension resident
    LD   DE, tts_end
    LD   C, SYS_SET_MEMBOT
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

tts_no_sp0:
    LD   B, LOGDEV_ID_CONO
    LD   DE, tts_msg_no_sp0
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

tts_err:
    LD   B, LOGDEV_ID_CONO
    LD   DE, tts_msg_err
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Driver functions
; ============================================================

; ------------------------------------------------------------
; tts_init / tts_getstatus
; No-ops — return ERR_SUCCESS.
; ------------------------------------------------------------
tts_init:
    ; Reset word buffer position
    XOR  A
    LD   (tts_wpos), A
tts_getstatus:
    XOR  A
    LD   H, A
    LD   L, A
    RET

; ------------------------------------------------------------
; tts_readbyte
; Not supported — output-only device.
; ------------------------------------------------------------
tts_readbyte:
    LD   A, ERR_NOT_SUPPORTED
    LD   HL, 0
    RET

; ------------------------------------------------------------
; tts_writebyte
; Accumulate character into word buffer. On word boundary
; (space, CR, LF, punctuation), translate and speak the word.
; Inputs:
;   B  - physical device ID
;   E  - character to write
; Outputs:
;   A  = ERR_SUCCESS
;   HL = 0
; ------------------------------------------------------------
tts_writebyte:
    PUSH BC
    PUSH DE

    ; Save our device ID for later (need it to find parent)
    LD   A, B
    LD   (tts_devid), A

    LD   A, E

    ; Check for word boundary characters
    CP   ' '
    JP   Z, tts_wb_boundary
    CP   0x0D                   ; CR
    JP   Z, tts_wb_boundary
    CP   0x0A                   ; LF
    JP   Z, tts_wb_boundary

    ; Check for punctuation that also triggers word boundary
    ; but should itself be translated (.,!?,--)
    CP   ','
    JP   Z, tts_wb_punct
    CP   '.'
    JP   Z, tts_wb_punct
    CP   '!'
    JP   Z, tts_wb_punct
    CP   '?'
    JP   Z, tts_wb_punct

    ; Regular character — convert lowercase to uppercase
    CP   'a'
    JP   C, tts_wb_store
    CP   'z' + 1
    JP   NC, tts_wb_store
    SUB  'a' - 'A'

tts_wb_store:
    ; A = character to store (already uppercased if needed)
    LD   D, A                   ; D = char to store
    LD   A, (tts_wpos)
    CP   TTS_MAX_WLEN
    JP   NC, tts_wb_done        ; buffer full, drop char

    ; Compute address: wordbuf + 1 + wpos
    LD   C, A
    LD   B, 0
    LD   HL, tts_wordbuf + 1
    ADD  HL, BC
    LD   (HL), D                ; store character

    ; Increment position
    LD   A, C
    INC  A
    LD   (tts_wpos), A

tts_wb_done:
    POP  DE
    POP  BC
    XOR  A
    LD   H, A
    LD   L, A
    RET

tts_wb_punct:
    ; Punctuation: flush current word first, then translate
    ; the punctuation character as its own word
    PUSH AF                     ; save punctuation char
    CALL tts_flush_word

    ; Now translate the punctuation as a single-char word
    POP  AF
    LD   HL, tts_wordbuf + 1
    LD   (HL), A
    LD   A, 1
    LD   (tts_wpos), A
    CALL tts_flush_word

    JP   tts_wb_done

tts_wb_boundary:
    ; Space/CR/LF: flush accumulated word, then send a pause
    CALL tts_flush_word

    LD   HL, tts_wordbuf + 1
    LD   (HL), ' '
    LD   A, 1
    LD   (tts_wpos), A
    CALL tts_flush_word
    JP   tts_wb_done

; ------------------------------------------------------------
; tts_flush_word
; Translate the current word buffer and output phonemes to
; the parent device. Resets the word buffer.
; ------------------------------------------------------------
tts_flush_word:
    LD   A, (tts_wpos)
    OR   A
    RET  Z                      ; nothing to flush

    ; Add space sentinels: wordbuf[0] = ' ', wordbuf[wpos+1] = ' ', wordbuf[wpos+2] = 0
    LD   HL, tts_wordbuf
    LD   (HL), ' '              ; leading space sentinel

    LD   C, A                   ; C = wpos (word length)
    LD   B, 0
    LD   HL, tts_wordbuf + 1
    ADD  HL, BC                 ; HL = &wordbuf[wpos+1]
    LD   (HL), ' '              ; trailing space sentinel
    INC  HL
    LD   (HL), 0                ; null terminator

    ; Save word length and start index
    LD   A, C
    LD   (tts_wlen), A
    LD   A, 1
    LD   (tts_widx), A          ; start at index 1

tts_flush_loop:
    ; C code: for (index=1; index<=wLen; )
    ; Continue while widx <= wlen
    LD   A, (tts_wlen)
    LD   C, A
    LD   A, (tts_widx)
    LD   B, A                   ; B = widx
    LD   A, C
    CP   B                      ; wlen - widx: carry if wlen < widx
    JP   C, tts_flush_done      ; widx > wlen, done
    ; If Z (widx == wlen), still process this character

    ; Get character at wordbuf[widx]
    LD   A, (tts_widx)
    LD   C, A
    LD   B, 0
    LD   HL, tts_wordbuf
    ADD  HL, BC
    LD   A, (HL)                ; A = character

    ; Look up in rulemap: need char as index (0-127)
    AND  0x7F
    LD   C, A
    LD   B, 0
    LD   HL, tts_rulemap
    ADD  HL, BC
    ADD  HL, BC                 ; HL = &rulemap[char] (2 bytes per entry)
    LD   C, (HL)
    INC  HL
    LD   B, (HL)                ; BC = rule pointer

    ; Check for no rules (0x0000)
    LD   A, B
    OR   C
    JP   Z, tts_flush_skip      ; no rules, skip char

    ; BC = pointer to first rule for this character
    CALL tts_find_rule          ; returns HL = matching rule, or 0

    LD   A, H
    OR   L
    JP   Z, tts_flush_skip      ; no matching rule found

    ; HL = pointer to matching rule
    ; Output phonemes from rule
    PUSH HL
    CALL tts_emit_phonemes
    POP  HL

    ; Advance widx by length of match string
    ; Rule layout: left(2), match(2), right(2), outlen(1), output(N)
    INC  HL
    INC  HL                     ; skip left ptr
    LD   C, (HL)
    INC  HL
    LD   B, (HL)                ; BC = match string pointer
    CALL tts_strlen             ; A = length of string at BC
    LD   C, A
    LD   A, (tts_widx)
    ADD  A, C
    LD   (tts_widx), A
    JP   tts_flush_loop

tts_flush_skip:
    LD   A, (tts_widx)
    INC  A
    LD   (tts_widx), A
    JP   tts_flush_loop

tts_flush_done:
    XOR  A
    LD   (tts_wpos), A
    RET

; ------------------------------------------------------------
; tts_emit_phonemes
; Output phonemes from a matched rule to the parent device.
; Inputs:
;   HL - pointer to rule entry
; Rule layout: left(2), match(2), right(2), outlen(1), output(N)
; ------------------------------------------------------------
tts_emit_phonemes:
    PUSH BC
    PUSH DE

    ; Skip to outlen: offset 6 from start of rule
    LD   DE, 6
    ADD  HL, DE
    LD   B, (HL)                ; B = output count
    INC  HL                     ; HL = first phoneme byte

    LD   A, B
    OR   A
    JP   Z, tts_emit_done      ; no phonemes

    ; Look up parent device ID
    PUSH HL
    PUSH BC
    LD   A, (tts_devid)
    LD   B, A
    LD   C, DEV_PHYS_GET
    CALL KERNELADDR             ; HL = PDT entry pointer
    LD   DE, PHYSDEV_OFF_PARENT
    ADD  HL, DE
    LD   A, (HL)                ; A = parent device ID
    LD   (tts_parent), A
    POP  BC
    POP  HL

tts_emit_loop:
    LD   E, (HL)                ; E = phoneme byte
    PUSH HL
    PUSH BC
    LD   A, (tts_parent)
    LD   B, A                   ; B = parent device ID
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    POP  HL
    INC  HL
    DEC  B
    JP   NZ, tts_emit_loop

tts_emit_done:
    POP  DE
    POP  BC
    RET

; ------------------------------------------------------------
; tts_find_rule
; Search rules starting at BC for one matching wordbuf at widx.
; Uses memory variables to avoid complex stack management.
; Inputs:
;   BC - pointer to first rule to try
; Outputs:
;   HL - pointer to matching rule, or 0 if not found
; ------------------------------------------------------------
tts_find_rule:
    PUSH DE

tts_fr_loop:
    ; Check for NOMORE sentinel: first word == 0x0003
    LD   H, B
    LD   L, C                   ; HL = current rule
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = left pointer
    LD   A, D
    OR   A
    JP   NZ, tts_fr_not_end
    LD   A, E
    CP   3
    JP   Z, tts_fr_notfound
tts_fr_not_end:
    ; Save current rule pointer in memory
    LD   A, B
    LD   (tts_fr_rule), A
    LD   A, C
    LD   (tts_fr_rule + 1), A

    ; Step 1: Check match string against wordbuf[widx]
    ; Rule: left(2), match(2), right(2), outlen(1), output(N)
    LD   H, B
    LD   L, C
    INC  HL
    INC  HL                     ; skip left(2)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)                ; DE = match string pointer

    ; Compare match string against wordbuf[widx]
    LD   A, (tts_widx)
    LD   C, A
    LD   B, 0
    LD   HL, tts_wordbuf
    ADD  HL, BC                 ; HL = &wordbuf[widx]

    ; Inline string compare: DE = pattern, HL = word
tts_fr_match_cmp:
    LD   A, (DE)
    OR   A
    JP   Z, tts_fr_match_ok
    CP   (HL)
    JP   NZ, tts_fr_nomatch
    INC  DE
    INC  HL
    JP   tts_fr_match_cmp

tts_fr_match_ok:
    ; HL = pointer into wordbuf after the match (right context start)
    ; Save it for right context check
    LD   A, H
    LD   (tts_fr_rctx), A
    LD   A, L
    LD   (tts_fr_rctx + 1), A

    ; Step 2: Check right context
    ; Get right ptr from rule: rule_start + 4
    LD   A, (tts_fr_rule)
    LD   B, A
    LD   A, (tts_fr_rule + 1)
    LD   C, A                   ; BC = rule start
    LD   H, B
    LD   L, C
    LD   DE, 4
    ADD  HL, DE                 ; HL = &rule.right
    LD   C, (HL)
    INC  HL
    LD   B, (HL)                ; BC = right context pattern ptr

    ; Check if ANYTHING (0x0001)
    LD   A, B
    OR   A
    JP   NZ, tts_fr_check_right
    LD   A, C
    CP   1
    JP   Z, tts_fr_right_ok

tts_fr_check_right:
    ; BC = right pattern, HL = right context in wordbuf
    LD   A, (tts_fr_rctx)
    LD   H, A
    LD   A, (tts_fr_rctx + 1)
    LD   L, A                   ; HL = right context word ptr
    CALL tts_lr_match           ; A = 1 if match, 0 if not
    OR   A
    JP   Z, tts_fr_nomatch

tts_fr_right_ok:
    ; Step 3: Check left context
    ; Get left ptr from rule: rule_start + 0
    LD   A, (tts_fr_rule)
    LD   B, A
    LD   A, (tts_fr_rule + 1)
    LD   C, A                   ; BC = rule start
    LD   H, B
    LD   L, C
    LD   C, (HL)
    INC  HL
    LD   B, (HL)                ; BC = left context pattern ptr

    ; Check if ANYTHING (0x0001)
    LD   A, B
    OR   A
    JP   NZ, tts_fr_check_left
    LD   A, C
    CP   1
    JP   Z, tts_fr_found

tts_fr_check_left:
    ; Reverse left context into tts_leftbuf
    ; wordbuf[widx-1] down to wordbuf[0]
    LD   A, (tts_widx)
    DEC  A                      ; start from widx-1
    LD   HL, tts_leftbuf
tts_fr_rev_left_ctx:
    CP   0xFF                   ; underflow check
    JP   Z, tts_fr_rev_left_ctx_done
    PUSH HL
    LD   C, A
    LD   B, 0
    LD   HL, tts_wordbuf
    ADD  HL, BC
    LD   D, (HL)                ; D = wordbuf[i]
    POP  HL
    LD   (HL), D
    INC  HL
    DEC  A
    JP   tts_fr_rev_left_ctx
tts_fr_rev_left_ctx_done:
    LD   (HL), 0                ; null terminate

    ; Reverse left pattern into tts_leftpat
    ; BC = left pattern pointer (still set from above)
    ; Reload it since we clobbered BC
    LD   A, (tts_fr_rule)
    LD   B, A
    LD   A, (tts_fr_rule + 1)
    LD   C, A
    LD   H, B
    LD   L, C
    LD   C, (HL)
    INC  HL
    LD   B, (HL)                ; BC = left pattern ptr again

    PUSH BC
    CALL tts_strlen             ; A = strlen(BC)
    POP  DE                     ; DE = left pattern
    LD   C, A                   ; C = length
    LD   B, 0
    LD   HL, tts_leftpat
    ; Start from DE + length - 1
    PUSH HL
    LD   H, D
    LD   L, E
    ADD  HL, BC
    DEC  HL                     ; HL = &pattern[len-1]
    EX   DE, HL                 ; DE = &pattern[len-1]
    POP  HL                     ; HL = tts_leftpat
    LD   A, C                   ; A = length
    OR   A
    JP   Z, tts_fr_rev_left_pat_done
tts_fr_rev_left_pat:
    LD   B, A                   ; save counter
    LD   A, (DE)
    LD   (HL), A
    INC  HL
    DEC  DE
    LD   A, B
    DEC  A
    JP   NZ, tts_fr_rev_left_pat
tts_fr_rev_left_pat_done:
    LD   (HL), 0                ; null terminate

    ; Match: pattern=tts_leftpat, context=tts_leftbuf
    LD   BC, tts_leftpat
    LD   HL, tts_leftbuf
    CALL tts_lr_match           ; A = 1 if match
    OR   A
    JP   Z, tts_fr_nomatch

tts_fr_found:
    ; Return rule pointer in HL
    LD   A, (tts_fr_rule)
    LD   H, A
    LD   A, (tts_fr_rule + 1)
    LD   L, A
    POP  DE
    RET

tts_fr_nomatch:
    ; Advance to next rule
    ; Rule layout: left(2), match(2), right(2), outlen(1), output(outlen)
    ; Total = 7 + outlen
    LD   A, (tts_fr_rule)
    LD   B, A
    LD   A, (tts_fr_rule + 1)
    LD   C, A                   ; BC = current rule
    LD   H, B
    LD   L, C
    LD   DE, 6
    ADD  HL, DE                 ; HL = &outlen
    LD   A, (HL)                ; A = outlen
    INC  HL                     ; skip outlen byte
    LD   E, A
    LD   D, 0
    ADD  HL, DE                 ; HL = start of next rule
    LD   B, H
    LD   C, L
    JP   tts_fr_loop

tts_fr_notfound:
    POP  DE
    LD   HL, 0
    RET

; ------------------------------------------------------------
; tts_lr_match
; Match a context pattern against a context string.
; Patterns can contain: A-Z, ' ', space (literal match),
; # (one+ vowels), : (zero+ consonants), ^ (one consonant),
; . (voiced consonant), + (E/I/Y), % (suffix pattern)
; Inputs:
;   BC - pattern string (null-terminated)
;   HL - context string (null-terminated)
; Outputs:
;   A  - 1 if match, 0 if no match
; ------------------------------------------------------------
tts_lr_match:
    PUSH DE

tts_lr_loop:
    LD   A, (BC)
    OR   A
    JP   Z, tts_lr_matched      ; end of pattern = match

    ; Check pattern character type
    CP   '#'
    JP   Z, tts_lr_vowels
    CP   ':'
    JP   Z, tts_lr_consonants0
    CP   '^'
    JP   Z, tts_lr_one_consonant
    CP   '.'
    JP   Z, tts_lr_voiced
    CP   '+'
    JP   Z, tts_lr_eiy
    CP   '%'
    JP   Z, tts_lr_suffix

    ; Literal match (A-Z, space, apostrophe, etc.)
    CP   (HL)
    JP   NZ, tts_lr_fail
    INC  BC
    INC  HL
    JP   tts_lr_loop

tts_lr_vowels:
    ; # = one or more vowels (AEIOU)
    LD   A, (HL)
    CALL tts_is_vowel
    JP   NZ, tts_lr_fail        ; first must be vowel (Z = is vowel)
    INC  HL
tts_lr_vowels_more:
    LD   A, (HL)
    CALL tts_is_vowel
    JP   NZ, tts_lr_vowels_end  ; not vowel, stop
    INC  HL
    JP   tts_lr_vowels_more
tts_lr_vowels_end:
    INC  BC
    JP   tts_lr_loop

tts_lr_consonants0:
    ; : = zero or more consonants
    LD   A, (HL)
    CALL tts_is_consonant
    JP   NZ, tts_lr_cons0_end   ; not consonant (NZ = not consonant)
    INC  HL
    JP   tts_lr_consonants0
tts_lr_cons0_end:
    INC  BC
    JP   tts_lr_loop

tts_lr_one_consonant:
    ; ^ = one consonant
    LD   A, (HL)
    CALL tts_is_consonant
    JP   NZ, tts_lr_fail        ; not consonant (NZ = not consonant)
    INC  HL
    INC  BC
    JP   tts_lr_loop

tts_lr_voiced:
    ; . = B,D,V,G,J,L,M,N,R,W,Z
    LD   A, (HL)
    PUSH HL
    LD   HL, tts_voiced_chars
    CALL tts_char_in_set
    POP  HL
    JP   Z, tts_lr_fail
    INC  HL
    INC  BC
    JP   tts_lr_loop

tts_lr_eiy:
    ; + = E, I, or Y
    LD   A, (HL)
    CP   'E'
    JP   Z, tts_lr_eiy_ok
    CP   'I'
    JP   Z, tts_lr_eiy_ok
    CP   'Y'
    JP   Z, tts_lr_eiy_ok
    JP   tts_lr_fail
tts_lr_eiy_ok:
    INC  HL
    INC  BC
    JP   tts_lr_loop

tts_lr_suffix:
    ; % = ING, ERY, ER, ES, ED, or E (in that priority order)
    ; Try ING
    LD   A, (HL)
    CP   'I'
    JP   NZ, tts_lr_suf_try_e_pfx
    PUSH HL
    INC  HL
    LD   A, (HL)
    CP   'N'
    JP   NZ, tts_lr_suf_pop_try_e
    INC  HL
    LD   A, (HL)
    CP   'G'
    JP   NZ, tts_lr_suf_pop_try_e
    ; ING matched — advance past ING
    POP  DE                     ; discard saved HL
    INC  HL                     ; past G
    INC  BC
    JP   tts_lr_loop

tts_lr_suf_pop_try_e:
    POP  HL
tts_lr_suf_try_e_pfx:
    ; Try ERY, ER, ES, ED, E
    LD   A, (HL)
    CP   'E'
    JP   NZ, tts_lr_fail

    ; Check what follows E
    PUSH HL
    INC  HL
    LD   A, (HL)
    CP   'R'
    JP   Z, tts_lr_suf_er
    CP   'S'
    JP   Z, tts_lr_suf_es
    CP   'D'
    JP   Z, tts_lr_suf_ed
    ; Just E — advance past E
    POP  HL
    INC  HL
    INC  BC
    JP   tts_lr_loop

tts_lr_suf_er:
    ; Check ERY
    INC  HL
    LD   A, (HL)
    CP   'Y'
    JP   NZ, tts_lr_suf_er_only
    ; ERY matched — advance past ERY
    POP  DE                     ; discard saved HL
    INC  HL                     ; past Y
    INC  BC
    JP   tts_lr_loop
tts_lr_suf_er_only:
    ; ER matched — HL is past R
    POP  DE                     ; discard saved HL
    INC  BC
    JP   tts_lr_loop

tts_lr_suf_es:
    ; ES matched — HL is past S
    POP  DE
    INC  HL
    INC  BC
    JP   tts_lr_loop

tts_lr_suf_ed:
    ; ED matched — HL is past D
    POP  DE
    INC  HL
    INC  BC
    JP   tts_lr_loop

tts_lr_matched:
    POP  DE
    LD   A, 1
    RET

tts_lr_fail:
    POP  DE
    XOR  A
    RET

; ------------------------------------------------------------
; Helper: tts_is_vowel
; Check if A is a vowel (A,E,I,O,U)
; Outputs: Z if vowel, NZ if not
; ------------------------------------------------------------
tts_is_vowel:
    CP   'A'
    RET  Z
    CP   'E'
    RET  Z
    CP   'I'
    RET  Z
    CP   'O'
    RET  Z
    CP   'U'
    RET                         ; Z if A==U (vowel), NZ otherwise

; ------------------------------------------------------------
; Helper: tts_is_consonant
; Check if A is a consonant (uppercase letter, not vowel)
; Outputs: Z if consonant, NZ if not
; ------------------------------------------------------------
tts_is_consonant:
    CP   'A'
    JP   C, tts_is_cons_no      ; < 'A'
    CP   'Z' + 1
    JP   NC, tts_is_cons_no     ; > 'Z'
    ; It's uppercase — check if vowel
    CALL tts_is_vowel
    JP   NZ, tts_is_cons_yes    ; NOT a vowel = IS a consonant
    ; It's a vowel, not a consonant
tts_is_cons_no:
    LD   A, 1
    OR   A                      ; set NZ (not consonant)
    RET
tts_is_cons_yes:
    XOR  A                      ; set Z (is consonant)
    RET

; ------------------------------------------------------------
; Helper: tts_char_in_set
; Check if A is in null-terminated character set at HL
; Outputs: NZ if found, Z if not
; ------------------------------------------------------------
tts_char_in_set:
    LD   D, A                   ; save char
tts_cis_loop:
    LD   A, (HL)
    OR   A
    JP   Z, tts_cis_notfound
    CP   D
    JP   Z, tts_cis_found
    INC  HL
    JP   tts_cis_loop
tts_cis_found:
    LD   A, 1
    OR   A                      ; NZ
    RET
tts_cis_notfound:
    XOR  A                      ; Z
    RET

; ------------------------------------------------------------
; Helper: tts_strlen
; Get length of null-terminated string at BC.
; Outputs: A = length
; ------------------------------------------------------------
tts_strlen:
    PUSH HL
    LD   H, B
    LD   L, C
    LD   A, 0
tts_strlen_loop:
    LD   D, A                   ; save count
    LD   A, (HL)
    OR   A
    JP   Z, tts_strlen_done
    LD   A, D
    INC  A
    INC  HL
    JP   tts_strlen_loop
tts_strlen_done:
    LD   A, D                   ; A = count
    POP  HL
    RET

; ============================================================
; Data
; ============================================================

tts_voiced_chars:
    DEFM "BDVGJLMNRWZ", 0

tts_sp0_name:
    DEFM "SP0", 0
tts_msg_ok:
    DEFM "TTS device registered.", 0x0D, 0x0A, 0
tts_msg_no_sp0:
    DEFM "SP0 device not found.", 0x0D, 0x0A, 0
tts_msg_err:
    DEFM "Failed to register device.", 0x0D, 0x0A, 0

; Working variables
tts_devid:
    DEFB 0                      ; our physical device ID
tts_parent:
    DEFB 0                      ; parent device ID (cached)
tts_wpos:
    DEFB 0                      ; current position in word buffer
tts_wlen:
    DEFB 0                      ; word length for current translation
tts_widx:
    DEFB 0                      ; current index in word during translation

; find_rule working variables (avoids stack juggling)
tts_fr_rule:
    DEFW 0                      ; current rule pointer
tts_fr_rctx:
    DEFW 0                      ; right context word pointer

; Buffers
tts_wordbuf:
    DEFS TTS_MAX_WLEN + 3, 0   ; word buffer with space sentinels
tts_leftbuf:
    DEFS TTS_MAX_WLEN + 3, 0   ; reversed left context
tts_leftpat:
    DEFS TTS_MAX_WLEN + 3, 0   ; reversed left pattern

; ------------------------------------------------------------
; Device Function Table (char DFT, 4 slots)
; ------------------------------------------------------------
tts_dft:
    DEFW tts_init               ; slot 0: Initialize
    DEFW tts_getstatus          ; slot 1: GetStatus
    DEFW tts_readbyte           ; slot 2: ReadByte
    DEFW tts_writebyte          ; slot 3: WriteByte

; ------------------------------------------------------------
; PDT entry template — copied into RAM by DEV_COPY
; ------------------------------------------------------------
tts_pdt:
    DEFW 0                              ; PHYSDEV_OFF_NEXT (filled by DEV_COPY)
    DEFB TTS_PHYSDEV_ID                 ; PHYSDEV_OFF_ID
    DEFM "TTS", 0, 0, 0, 0             ; PHYSDEV_OFF_NAME (7 bytes)
    DEFB DEVCAP_CHAR_OUT                ; PHYSDEV_OFF_CAPS
tts_pdt_parent:
    DEFB 0                              ; PHYSDEV_OFF_PARENT (filled at startup)
    DEFB 0                              ; PHYSDEV_OFF_CHILD
    DEFW tts_dft                        ; PHYSDEV_OFF_DFT
    DEFS 17, 0                          ; PHYSDEV_OFF_DATA (unused)

; ============================================================
; Rule tables (auto-generated)
; ============================================================
    INCLUDE "tts_rules.asm"

tts_end:

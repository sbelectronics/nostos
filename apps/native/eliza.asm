; ============================================================
; eliza.asm - ELIZA chatbot for NostOS
; ============================================================
; An implementation of Weizenbaum's ELIZA with the DOCTOR
; script. Keyword matching, pronoun reflection, and cycling
; responses.
;
; Type natural language sentences. ELIZA responds as a
; Rogerian therapist. Type QUIT or BYE to exit.
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    JP   el_main
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================
EL_MAX_INPUT    EQU 78
EL_SUBST        EQU 0x01    ; marker for tail substitution in responses

    INCLUDE "ansi.asm"

; ============================================================
; el_main - Entry point
; ============================================================
el_main:
    LD   DE, el_intro1
    CALL el_println
    LD   DE, el_intro2
    CALL el_println

el_loop:
    ; Prompt
    LD   E, '>'
    CALL ansi_putchar
    LD   E, ' '
    CALL ansi_putchar

    ; Read input
    CALL el_read_line

    ; Empty input?
    LD   A, (el_input)
    OR   A
    JP   Z, el_loop

    ; Convert to uppercase for matching
    CALL el_to_upper

    ; Check for exit keywords
    LD   DE, el_s_quit
    CALL el_find_in_input
    JP   Z, el_goodbye
    LD   DE, el_s_bye
    CALL el_find_in_input
    JP   Z, el_goodbye
    LD   DE, el_s_goodbye
    CALL el_find_in_input
    JP   Z, el_goodbye

    ; Search keyword table for best match
    CALL el_match_keywords   ; Z = found, HL = response group
    JP   Z, el_respond

    ; No keyword matched — fallback
    LD   HL, el_rg_none
    CALL el_get_response     ; DE = response string
    CALL el_println
    JP   el_loop

el_respond:
    ; HL = response group, el_tail = text after keyword
    PUSH HL
    CALL el_reflect          ; el_tail → el_reflected
    POP  HL
    CALL el_get_response     ; DE = response template
    CALL el_print_response   ; print template, substituting 0x01
    JP   el_loop

el_goodbye:
    LD   DE, el_goodbye_str
    CALL el_println
    LD   C, SYS_EXIT
    JP   KERNELADDR

; ============================================================
; el_read_line - Read a line into el_input with echo
; ============================================================
el_read_line:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   HL, el_input
    LD   B, 0                ; char count
el_rl_read:
    PUSH BC
    PUSH HL
    LD   B, LOGDEV_ID_CONI
    LD   C, DEV_CREAD_RAW
    CALL KERNELADDR
    LD   A, L
    POP  HL
    POP  BC
    ; Enter?
    CP   0x0D
    JP   Z, el_rl_done
    ; Backspace?
    CP   0x08
    JP   Z, el_rl_bs
    CP   0x7F
    JP   Z, el_rl_bs
    ; Buffer full?
    LD   C, A
    LD   A, B
    CP   EL_MAX_INPUT
    JP   NC, el_rl_read
    ; Store and echo
    LD   (HL), C
    INC  HL
    INC  B
    LD   E, C
    CALL ansi_putchar
    JP   el_rl_read
el_rl_bs:
    LD   A, B
    OR   A
    JP   Z, el_rl_read
    DEC  HL
    DEC  B
    LD   E, 0x08
    CALL ansi_putchar
    LD   E, ' '
    CALL ansi_putchar
    LD   E, 0x08
    CALL ansi_putchar
    JP   el_rl_read
el_rl_done:
    LD   (HL), 0
    CALL el_newline
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; el_to_upper - Convert el_input to uppercase in place
; ============================================================
el_to_upper:
    PUSH HL
    LD   HL, el_input
el_tu_loop:
    LD   A, (HL)
    OR   A
    JP   Z, el_tu_done
    CP   'a'
    JP   C, el_tu_next
    CP   'z' + 1
    JP   NC, el_tu_next
    SUB  0x20
    LD   (HL), A
el_tu_next:
    INC  HL
    JP   el_tu_loop
el_tu_done:
    POP  HL
    RET

; ============================================================
; el_find_in_input - Find keyword DE in el_input (word-boundary)
; Returns: Z if found, HL = position in el_input after keyword
;          NZ if not found
; Preserves: DE
; ============================================================
el_find_in_input:
    PUSH BC
    LD   HL, el_input
    ; First position = word boundary (start of string)
    JP   el_fi_try
el_fi_advance:
    ; Scan to next word boundary
    LD   A, (HL)
    OR   A
    JP   Z, el_fi_nf
    INC  HL
    CP   ' '
    JP   NZ, el_fi_advance
    ; HL is at char after space = word boundary
    LD   A, (HL)
    OR   A
    JP   Z, el_fi_nf
el_fi_try:
    PUSH HL
    PUSH DE
el_fi_cmp:
    LD   A, (DE)
    OR   A
    JP   Z, el_fi_match     ; end of keyword = full match
    CP   (HL)
    JP   NZ, el_fi_nomatch
    INC  HL
    INC  DE
    JP   el_fi_cmp
el_fi_match:
    ; Check word boundary after keyword: next char must be space, null, or punctuation
    LD   A, (HL)
    OR   A
    JP   Z, el_fi_ok        ; end of input
    CP   ' '
    JP   Z, el_fi_ok
    CP   '.'
    JP   Z, el_fi_ok
    CP   ','
    JP   Z, el_fi_ok
    CP   '!'
    JP   Z, el_fi_ok
    CP   '?'
    JP   Z, el_fi_ok
    CP   ';'
    JP   Z, el_fi_ok
    CP   ':'
    JP   Z, el_fi_ok
    ; Not a word boundary — reject (e.g., "AM" inside "NAME")
    JP   el_fi_nomatch_pop
el_fi_ok:
    POP  DE
    POP  BC                  ; discard saved HL
    POP  BC                  ; restore caller's BC
    XOR  A                   ; Z = found
    RET
el_fi_nomatch_pop:
el_fi_nomatch:
    POP  DE
    POP  HL
    JP   el_fi_advance
el_fi_nf:
    POP  BC
    LD   A, 1
    OR   A                   ; NZ = not found
    RET

; ============================================================
; el_match_keywords - Search keyword table for first match
; Returns: Z if found, HL = response group pointer
;          el_tail filled with text after keyword
;          NZ if no match
; ============================================================
el_match_keywords:
    PUSH BC
    PUSH DE
    LD   HL, el_kw_table
el_mk_loop:
    ; Read keyword string pointer
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    LD   A, D
    OR   E
    JP   Z, el_mk_none      ; end of table
    ; Save table position (pointing at response group ptr)
    LD   (el_mk_tpos), HL
    ; Try to find keyword DE in input
    CALL el_find_in_input
    JP   Z, el_mk_found
    ; Not found — skip response group pointer
    LD   HL, (el_mk_tpos)
    INC  HL
    INC  HL
    JP   el_mk_loop
el_mk_found:
    ; HL = position after keyword in el_input
    CALL el_extract_tail
    ; Load response group pointer
    LD   HL, (el_mk_tpos)
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    LD   H, D
    LD   L, E                ; HL = response group
    POP  DE
    POP  BC
    XOR  A                   ; Z = found
    RET
el_mk_none:
    POP  DE
    POP  BC
    LD   A, 1
    OR   A                   ; NZ
    RET

; ============================================================
; el_extract_tail - Copy text after keyword into el_tail
; Input: HL = position in el_input after keyword
; ============================================================
el_extract_tail:
    PUSH DE
    PUSH HL
    ; Skip leading spaces
el_et_skip:
    LD   A, (HL)
    CP   ' '
    JP   NZ, el_et_copy
    INC  HL
    JP   el_et_skip
el_et_copy:
    LD   DE, el_tail
el_et_loop:
    LD   A, (HL)
    LD   (DE), A
    OR   A
    JP   Z, el_et_done
    INC  HL
    INC  DE
    JP   el_et_loop
el_et_done:
    POP  HL
    POP  DE
    RET

; ============================================================
; el_reflect - Pronoun-reflect el_tail into el_reflected
; ============================================================
el_reflect:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   HL, el_tail
    LD   DE, el_reflected
el_rf_loop:
    LD   A, (HL)
    OR   A
    JP   Z, el_rf_done
    CP   ' '
    JP   Z, el_rf_space
    ; Start of word — save position and find end
    LD   (el_rf_wstart), HL
el_rf_wend:
    LD   A, (HL)
    OR   A
    JP   Z, el_rf_got_word
    CP   ' '
    JP   Z, el_rf_got_word
    INC  HL
    JP   el_rf_wend
el_rf_got_word:
    LD   (el_rf_wend_ptr), HL
    ; Try reflection lookup
    CALL el_lookup_refl      ; Z if found, BC = replacement
    JP   Z, el_rf_replace
    ; Not found — copy original word
    LD   HL, (el_rf_wstart)
el_rf_orig:
    LD   A, (HL)
    OR   A
    JP   Z, el_rf_next
    CP   ' '
    JP   Z, el_rf_next
    CALL el_rf_put
    JP   Z, el_rf_done
    INC  HL
    JP   el_rf_orig
el_rf_replace:
    ; Copy replacement string from BC
    LD   H, B
    LD   L, C
el_rf_repl:
    LD   A, (HL)
    OR   A
    JP   Z, el_rf_next
    CALL el_rf_put
    JP   Z, el_rf_done
    INC  HL
    JP   el_rf_repl
el_rf_next:
    LD   HL, (el_rf_wend_ptr)
    JP   el_rf_loop
el_rf_space:
    CALL el_rf_put
    JP   Z, el_rf_done
    INC  HL
    JP   el_rf_loop
    ; Copy (HL) to (DE) and advance DE, unless buffer is full.
    ; Returns Z if buffer is full (output truncated), NZ if ok.
el_rf_put:
    PUSH HL
    LD   HL, el_reflected + EL_MAX_INPUT
    LD   A, E
    CP   L
    JP   NZ, el_rf_put_ok
    LD   A, D
    CP   H
    JP   NZ, el_rf_put_ok
    ; Buffer full — null-terminate and signal done
    XOR  A
    LD   (DE), A
    POP  HL
    XOR  A                      ; Z = full
    RET
el_rf_put_ok:
    POP  HL
    LD   A, (HL)
    LD   (DE), A
    INC  DE
    OR   0xFF                   ; NZ = ok
    RET
el_rf_done:
    XOR  A
    LD   (DE), A             ; null-terminate
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; el_lookup_refl - Look up word in reflection table
; Uses el_rf_wstart, el_rf_wend_ptr
; Returns: Z if found, BC = replacement string pointer
;          NZ if not found
; ============================================================
el_lookup_refl:
    PUSH DE
    PUSH HL
    LD   HL, el_refl_table
el_lr_loop:
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    INC  HL
    LD   A, D
    OR   E
    JP   Z, el_lr_nf         ; end of table
    LD   (el_lr_tpos), HL    ; save (points to to-string ptr)
    ; Compare word with from-string at DE
    PUSH DE
    LD   HL, (el_rf_wstart)
el_lr_cmp:
    LD   A, (DE)
    OR   A
    JP   Z, el_lr_end_from
    CP   (HL)
    JP   NZ, el_lr_no
    INC  HL
    INC  DE
    JP   el_lr_cmp
el_lr_end_from:
    ; From-string ended — check word also ended
    LD   A, (HL)
    OR   A
    JP   Z, el_lr_yes
    CP   ' '
    JP   Z, el_lr_yes
    ; Word continues past from-string — not a match
el_lr_no:
    POP  DE
    LD   HL, (el_lr_tpos)
    INC  HL
    INC  HL                   ; skip to-string pointer
    JP   el_lr_loop
el_lr_yes:
    POP  DE                   ; discard saved from-ptr
    LD   HL, (el_lr_tpos)
    LD   C, (HL)
    INC  HL
    LD   B, (HL)              ; BC = to-string pointer
    POP  HL
    POP  DE
    XOR  A                    ; Z = found
    RET
el_lr_nf:
    POP  HL
    POP  DE
    LD   A, 1
    OR   A                    ; NZ
    RET

; ============================================================
; el_get_response - Get next cycling response from group at HL
; Returns: DE = response string pointer
; ============================================================
el_get_response:
    PUSH BC
    PUSH HL
    ; (HL+0) = current index, (HL+1) = count, (HL+2..) = pointers
    LD   A, (HL)              ; current index
    LD   B, A                 ; B = index to use
    INC  HL
    LD   C, (HL)              ; C = count
    DEC  HL
    ; Advance index for next call
    LD   A, B
    INC  A
    CP   C
    JP   C, el_gr_store
    XOR  A                    ; wrap to 0
el_gr_store:
    LD   (HL), A              ; store next index
    ; Compute pointer address: HL + 2 + B*2
    INC  HL
    INC  HL
    LD   A, B
    ADD  A, A                 ; *2
    LD   C, A
    LD   B, 0
    ADD  HL, BC
    LD   E, (HL)
    INC  HL
    LD   D, (HL)              ; DE = response string
    POP  HL
    POP  BC
    RET

; ============================================================
; el_print_response - Print response, substituting 0x01 with el_reflected
; Input: DE = response template
; ============================================================
el_print_response:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   H, D
    LD   L, E
el_pr_loop:
    LD   A, (HL)
    OR   A
    JP   Z, el_pr_done
    CP   EL_SUBST
    JP   Z, el_pr_sub
    LD   E, A
    CALL ansi_putchar
    INC  HL
    JP   el_pr_loop
el_pr_sub:
    PUSH HL
    LD   DE, el_reflected
    CALL ansi_puts
    POP  HL
    INC  HL
    JP   el_pr_loop
el_pr_done:
    CALL el_newline
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; el_println - Print string at DE followed by newline
; ============================================================
el_println:
    CALL ansi_puts
    ; fall through
el_newline:
    PUSH DE
    LD   E, 0x0D
    CALL ansi_putchar
    LD   E, 0x0A
    CALL ansi_putchar
    POP  DE
    RET

; ============================================================
; Intro and exit strings
; ============================================================
el_intro1:
    DEFB "HOW DO YOU DO. PLEASE TELL ME YOUR PROBLEM.", 0
el_intro2:
    DEFB 0
el_goodbye_str:
    DEFB "GOODBYE. THANK YOU FOR TALKING TO ME.", 0
el_s_quit:
    DEFB "QUIT", 0
el_s_bye:
    DEFB "BYE", 0
el_s_goodbye:
    DEFB "GOODBYE", 0

; ============================================================
; Keyword table — searched in order (highest priority first)
; Each entry: DEFW keyword_string, DEFW response_group
; Terminated by DEFW 0
; ============================================================
el_kw_table:
    DEFW el_k_whydontyou, el_rg_whydontyou
    DEFW el_k_whycanti,   el_rg_whycanti
    DEFW el_k_doyouremem, el_rg_doyouremem
    DEFW el_k_iremember,  el_rg_iremember
    DEFW el_k_canyou,     el_rg_canyou
    DEFW el_k_cani,       el_rg_cani
    DEFW el_k_youare,     el_rg_youare
    DEFW el_k_youre,      el_rg_youare
    DEFW el_k_areyou,     el_rg_areyou
    DEFW el_k_ami,        el_rg_ami
    DEFW el_k_sorry,      el_rg_sorry
    DEFW el_k_idont,      el_rg_idont
    DEFW el_k_ifeel,      el_rg_ifeel
    DEFW el_k_ithink,     el_rg_ithink
    DEFW el_k_icant,      el_rg_icant
    DEFW el_k_iam,        el_rg_iam
    DEFW el_k_im,         el_rg_iam
    DEFW el_k_iwant,      el_rg_iwant
    DEFW el_k_ineed,      el_rg_ineed
    DEFW el_k_because,    el_rg_because
    DEFW el_k_if,         el_rg_if
    DEFW el_k_perhaps,    el_rg_perhaps
    DEFW el_k_maybe,      el_rg_perhaps
    DEFW el_k_dream,      el_rg_dream
    DEFW el_k_hello,      el_rg_greet
    DEFW el_k_hi,         el_rg_greet
    DEFW el_k_computer,   el_rg_computer
    DEFW el_k_always,     el_rg_always
    DEFW el_k_everyone,   el_rg_everyone
    DEFW el_k_everybody,  el_rg_everyone
    DEFW el_k_nobody,     el_rg_everyone
    DEFW el_k_mother,     el_rg_family
    DEFW el_k_father,     el_rg_family
    DEFW el_k_sister,     el_rg_family
    DEFW el_k_brother,    el_rg_family
    DEFW el_k_family,     el_rg_family
    DEFW el_k_my,         el_rg_my
    DEFW el_k_your,       el_rg_your
    DEFW el_k_yes,        el_rg_yes
    DEFW el_k_no,         el_rg_no
    DEFW el_k_what,       el_rg_question
    DEFW el_k_how,        el_rg_question
    DEFW el_k_who,        el_rg_question
    DEFW el_k_where,      el_rg_question
    DEFW el_k_when,       el_rg_question
    DEFW el_k_why,        el_rg_question
    DEFW el_k_alike,      el_rg_alike
    DEFW el_k_like,       el_rg_alike
    DEFW el_k_you,        el_rg_you
    DEFW 0, 0

; ============================================================
; Keyword strings
; ============================================================
el_k_whydontyou: DEFB "WHY DON'T YOU", 0
el_k_whycanti:   DEFB "WHY CAN'T I", 0
el_k_doyouremem: DEFB "DO YOU REMEMBER", 0
el_k_iremember:  DEFB "I REMEMBER", 0
el_k_canyou:     DEFB "CAN YOU", 0
el_k_cani:       DEFB "CAN I", 0
el_k_youare:     DEFB "YOU ARE", 0
el_k_youre:      DEFB "YOU'RE", 0
el_k_areyou:     DEFB "ARE YOU", 0
el_k_ami:        DEFB "AM I", 0
el_k_sorry:      DEFB "SORRY", 0
el_k_idont:      DEFB "I DON'T", 0
el_k_ifeel:      DEFB "I FEEL", 0
el_k_ithink:     DEFB "I THINK", 0
el_k_icant:      DEFB "I CAN'T", 0
el_k_iam:        DEFB "I AM", 0
el_k_im:         DEFB "I'M", 0
el_k_iwant:      DEFB "I WANT", 0
el_k_ineed:      DEFB "I NEED", 0
el_k_because:    DEFB "BECAUSE", 0
el_k_if:         DEFB "IF", 0
el_k_perhaps:    DEFB "PERHAPS", 0
el_k_maybe:      DEFB "MAYBE", 0
el_k_dream:      DEFB "DREAM", 0
el_k_hello:      DEFB "HELLO", 0
el_k_hi:         DEFB "HI", 0
el_k_computer:   DEFB "COMPUTER", 0
el_k_always:     DEFB "ALWAYS", 0
el_k_everyone:   DEFB "EVERYONE", 0
el_k_everybody:  DEFB "EVERYBODY", 0
el_k_nobody:     DEFB "NOBODY", 0
el_k_mother:     DEFB "MOTHER", 0
el_k_father:     DEFB "FATHER", 0
el_k_sister:     DEFB "SISTER", 0
el_k_brother:    DEFB "BROTHER", 0
el_k_family:     DEFB "FAMILY", 0
el_k_my:         DEFB "MY", 0
el_k_your:       DEFB "YOUR", 0
el_k_yes:        DEFB "YES", 0
el_k_no:         DEFB "NO", 0
el_k_what:       DEFB "WHAT", 0
el_k_how:        DEFB "HOW", 0
el_k_who:        DEFB "WHO", 0
el_k_where:      DEFB "WHERE", 0
el_k_when:       DEFB "WHEN", 0
el_k_why:        DEFB "WHY", 0
el_k_alike:      DEFB "ALIKE", 0
el_k_like:       DEFB "LIKE", 0
el_k_you:        DEFB "YOU", 0

; ============================================================
; Response groups
; Format: DEFB current_index, count, DEFW ptr0, ptr1, ...
; ============================================================

el_rg_whydontyou:
    DEFB 0, 3
    DEFW el_r_wdyu0, el_r_wdyu1, el_r_wdyu2
el_rg_whycanti:
    DEFB 0, 2
    DEFW el_r_wci0, el_r_wci1
el_rg_doyouremem:
    DEFB 0, 2
    DEFW el_r_dyr0, el_r_dyr1
el_rg_iremember:
    DEFB 0, 2
    DEFW el_r_ir0, el_r_ir1
el_rg_canyou:
    DEFB 0, 2
    DEFW el_r_cy0, el_r_cy1
el_rg_cani:
    DEFB 0, 2
    DEFW el_r_ci0, el_r_ci1
el_rg_youare:
    DEFB 0, 2
    DEFW el_r_ya0, el_r_ya1
el_rg_areyou:
    DEFB 0, 2
    DEFW el_r_ay0, el_r_ay1
el_rg_ami:
    DEFB 0, 2
    DEFW el_r_ami0, el_r_ami1
el_rg_sorry:
    DEFB 0, 2
    DEFW el_r_sry0, el_r_sry1
el_rg_idont:
    DEFB 0, 2
    DEFW el_r_idt0, el_r_idt1
el_rg_ifeel:
    DEFB 0, 2
    DEFW el_r_if0, el_r_if1
el_rg_ithink:
    DEFB 0, 2
    DEFW el_r_it0, el_r_it1
el_rg_icant:
    DEFB 0, 2
    DEFW el_r_ic0, el_r_ic1
el_rg_iam:
    DEFB 0, 3
    DEFW el_r_iam0, el_r_iam1, el_r_iam2
el_rg_iwant:
    DEFB 0, 2
    DEFW el_r_iw0, el_r_iw1
el_rg_ineed:
    DEFB 0, 2
    DEFW el_r_in0, el_r_in1
el_rg_because:
    DEFB 0, 3
    DEFW el_r_bc0, el_r_bc1, el_r_bc2
el_rg_if:
    DEFB 0, 2
    DEFW el_r_iff0, el_r_iff1
el_rg_perhaps:
    DEFB 0, 2
    DEFW el_r_ph0, el_r_ph1
el_rg_dream:
    DEFB 0, 2
    DEFW el_r_dr0, el_r_dr1
el_rg_greet:
    DEFB 0, 2
    DEFW el_r_gr0, el_r_gr1
el_rg_computer:
    DEFB 0, 2
    DEFW el_r_cp0, el_r_cp1
el_rg_always:
    DEFB 0, 2
    DEFW el_r_al0, el_r_al1
el_rg_everyone:
    DEFB 0, 2
    DEFW el_r_ev0, el_r_ev1
el_rg_family:
    DEFB 0, 2
    DEFW el_r_fm0, el_r_fm1
el_rg_my:
    DEFB 0, 3
    DEFW el_r_my0, el_r_my1, el_r_my2
el_rg_your:
    DEFB 0, 2
    DEFW el_r_yr0, el_r_yr1
el_rg_yes:
    DEFB 0, 3
    DEFW el_r_y0, el_r_y1, el_r_y2
el_rg_no:
    DEFB 0, 3
    DEFW el_r_n0, el_r_n1, el_r_n2
el_rg_question:
    DEFB 0, 3
    DEFW el_r_q0, el_r_q1, el_r_q2
el_rg_alike:
    DEFB 0, 2
    DEFW el_r_lk0, el_r_lk1
el_rg_you:
    DEFB 0, 3
    DEFW el_r_u0, el_r_u1, el_r_u2

; Fallback (no keyword matched)
el_rg_none:
    DEFB 0, 8
    DEFW el_r_no0, el_r_no1, el_r_no2, el_r_no3
    DEFW el_r_no4, el_r_no5, el_r_no6, el_r_no7

; ============================================================
; Response strings (0x01 = substitute reflected tail)
; ============================================================

; WHY DON'T YOU
el_r_wdyu0: DEFB "DO YOU BELIEVE I DON'T ", EL_SUBST, "?", 0
el_r_wdyu1: DEFB "PERHAPS I WILL ", EL_SUBST, " IN GOOD TIME.", 0
el_r_wdyu2: DEFB "SHOULD YOU ", EL_SUBST, " YOURSELF?", 0

; WHY CAN'T I
el_r_wci0:  DEFB "DO YOU THINK YOU SHOULD BE ABLE TO ", EL_SUBST, "?", 0
el_r_wci1:  DEFB "DO YOU WANT TO BE ABLE TO ", EL_SUBST, "?", 0

; DO YOU REMEMBER
el_r_dyr0:  DEFB "DID YOU THINK I WOULD FORGET ", EL_SUBST, "?", 0
el_r_dyr1:  DEFB "WHY DO YOU THINK I SHOULD RECALL ", EL_SUBST, " NOW?", 0

; I REMEMBER
el_r_ir0:   DEFB "DO YOU OFTEN THINK OF ", EL_SUBST, "?", 0
el_r_ir1:   DEFB "DOES THINKING OF ", EL_SUBST, " BRING ANYTHING ELSE TO MIND?", 0

; CAN YOU
el_r_cy0:   DEFB "YOU BELIEVE I CAN ", EL_SUBST, "?", 0
el_r_cy1:   DEFB "WHAT MAKES YOU THINK I CAN'T ", EL_SUBST, "?", 0

; CAN I
el_r_ci0:   DEFB "WHETHER OR NOT YOU CAN ", EL_SUBST, " DEPENDS ON YOU MORE THAN ON ME.", 0
el_r_ci1:   DEFB "DO YOU WANT TO BE ABLE TO ", EL_SUBST, "?", 0

; YOU ARE / YOU'RE
el_r_ya0:   DEFB "WHAT MAKES YOU THINK I AM ", EL_SUBST, "?", 0
el_r_ya1:   DEFB "DOES IT PLEASE YOU TO BELIEVE I AM ", EL_SUBST, "?", 0

; ARE YOU
el_r_ay0:   DEFB "WHY ARE YOU INTERESTED IN WHETHER I AM ", EL_SUBST, " OR NOT?", 0
el_r_ay1:   DEFB "WOULD YOU PREFER IF I WEREN'T ", EL_SUBST, "?", 0

; AM I
el_r_ami0:  DEFB "DO YOU BELIEVE YOU ARE ", EL_SUBST, "?", 0
el_r_ami1:  DEFB "WOULD YOU WANT TO BE ", EL_SUBST, "?", 0

; SORRY
el_r_sry0:  DEFB "PLEASE DON'T APOLOGIZE.", 0
el_r_sry1:  DEFB "APOLOGIES ARE NOT NECESSARY.", 0

; I DON'T
el_r_idt0:  DEFB "DON'T YOU REALLY ", EL_SUBST, "?", 0
el_r_idt1:  DEFB "WHY DON'T YOU ", EL_SUBST, "?", 0

; I FEEL
el_r_if0:   DEFB "DO YOU OFTEN FEEL ", EL_SUBST, "?", 0
el_r_if1:   DEFB "TELL ME MORE ABOUT SUCH FEELINGS.", 0

; I THINK
el_r_it0:   DEFB "DO YOU REALLY THINK SO?", 0
el_r_it1:   DEFB "BUT YOU ARE NOT SURE YOU ", EL_SUBST, "?", 0

; I CAN'T
el_r_ic0:   DEFB "HOW DO YOU KNOW YOU CAN'T ", EL_SUBST, "?", 0
el_r_ic1:   DEFB "HAVE YOU TRIED?", 0

; I AM / I'M
el_r_iam0:  DEFB "DID YOU COME TO ME BECAUSE YOU ARE ", EL_SUBST, "?", 0
el_r_iam1:  DEFB "HOW LONG HAVE YOU BEEN ", EL_SUBST, "?", 0
el_r_iam2:  DEFB "HOW DOES BEING ", EL_SUBST, " MAKE YOU FEEL?", 0

; I WANT
el_r_iw0:   DEFB "WHAT WOULD IT MEAN IF YOU GOT ", EL_SUBST, "?", 0
el_r_iw1:   DEFB "WHY DO YOU WANT ", EL_SUBST, "?", 0

; I NEED
el_r_in0:   DEFB "WHY DO YOU NEED ", EL_SUBST, "?", 0
el_r_in1:   DEFB "WOULD IT REALLY HELP YOU TO GET ", EL_SUBST, "?", 0

; BECAUSE
el_r_bc0:   DEFB "IS THAT THE REAL REASON?", 0
el_r_bc1:   DEFB "WHAT OTHER REASONS COME TO MIND?", 0
el_r_bc2:   DEFB "DOES THAT REASON SEEM TO EXPLAIN ANYTHING ELSE?", 0

; IF
el_r_iff0:  DEFB "DO YOU THINK IT'S LIKELY THAT ", EL_SUBST, "?", 0
el_r_iff1:  DEFB "DO YOU WISH THAT ", EL_SUBST, "?", 0

; PERHAPS / MAYBE
el_r_ph0:   DEFB "YOU DON'T SEEM QUITE CERTAIN.", 0
el_r_ph1:   DEFB "WHY THE UNCERTAIN TONE?", 0

; DREAM
el_r_dr0:   DEFB "WHAT DOES THAT DREAM SUGGEST TO YOU?", 0
el_r_dr1:   DEFB "DO YOU DREAM OFTEN?", 0

; HELLO / HI
el_r_gr0:   DEFB "HOW DO YOU DO. PLEASE STATE YOUR PROBLEM.", 0
el_r_gr1:   DEFB "HI. WHAT SEEMS TO BE YOUR PROBLEM?", 0

; COMPUTER
el_r_cp0:   DEFB "DO COMPUTERS WORRY YOU?", 0
el_r_cp1:   DEFB "WHAT DO YOU THINK ABOUT MACHINES?", 0

; ALWAYS
el_r_al0:   DEFB "CAN YOU THINK OF A SPECIFIC EXAMPLE?", 0
el_r_al1:   DEFB "WHEN?", 0

; EVERYONE / EVERYBODY / NOBODY
el_r_ev0:   DEFB "CAN YOU THINK OF ANYONE IN PARTICULAR?", 0
el_r_ev1:   DEFB "WHO, FOR EXAMPLE?", 0

; MOTHER / FATHER / SISTER / BROTHER / FAMILY
el_r_fm0:   DEFB "TELL ME MORE ABOUT YOUR FAMILY.", 0
el_r_fm1:   DEFB "WHO ELSE IN YOUR FAMILY ", EL_SUBST, "?", 0

; MY
el_r_my0:   DEFB "YOUR ", EL_SUBST, "?", 0
el_r_my1:   DEFB "WHY DO YOU SAY YOUR ", EL_SUBST, "?", 0
el_r_my2:   DEFB "DOES THAT HAVE ANYTHING TO DO WITH THE FACT THAT YOUR ", EL_SUBST, "?", 0

; YOUR
el_r_yr0:   DEFB "WHY ARE YOU CONCERNED OVER MY ", EL_SUBST, "?", 0
el_r_yr1:   DEFB "WHAT ABOUT YOUR OWN ", EL_SUBST, "?", 0

; YES
el_r_y0:    DEFB "YOU SEEM QUITE POSITIVE.", 0
el_r_y1:    DEFB "ARE YOU SURE?", 0
el_r_y2:    DEFB "I SEE.", 0

; NO
el_r_n0:    DEFB "ARE YOU SAYING NO JUST TO BE NEGATIVE?", 0
el_r_n1:    DEFB "WHY NOT?", 0
el_r_n2:    DEFB "YOU ARE BEING A BIT NEGATIVE.", 0

; WHAT / HOW / WHO / WHERE / WHEN / WHY
el_r_q0:    DEFB "WHY DO YOU ASK?", 0
el_r_q1:    DEFB "DOES THAT QUESTION INTEREST YOU?", 0
el_r_q2:    DEFB "WHAT IS IT YOU REALLY WANT TO KNOW?", 0

; ALIKE / LIKE
el_r_lk0:   DEFB "IN WHAT WAY?", 0
el_r_lk1:   DEFB "WHAT RESEMBLANCE DO YOU SEE?", 0

; YOU (catch-all)
el_r_u0:    DEFB "WE WERE DISCUSSING YOU -- NOT ME.", 0
el_r_u1:    DEFB "OH, I ", EL_SUBST, "?", 0
el_r_u2:    DEFB "YOU'RE NOT REALLY TALKING ABOUT ME -- ARE YOU?", 0

; Fallback (no keyword matched)
el_r_no0:   DEFB "PLEASE GO ON.", 0
el_r_no1:   DEFB "TELL ME MORE ABOUT THAT.", 0
el_r_no2:   DEFB "CAN YOU ELABORATE ON THAT?", 0
el_r_no3:   DEFB "THAT IS INTERESTING. PLEASE CONTINUE.", 0
el_r_no4:   DEFB "I SEE. AND WHAT DOES THAT TELL YOU?", 0
el_r_no5:   DEFB "VERY INTERESTING.", 0
el_r_no6:   DEFB "I'M NOT SURE I UNDERSTAND YOU FULLY.", 0
el_r_no7:   DEFB "WHAT DOES THAT SUGGEST TO YOU?", 0

; ============================================================
; Reflection table: DEFW from_ptr, DEFW to_ptr; ends with DEFW 0
; Order: longer strings first to avoid partial matches
; (though word-boundary check should prevent issues)
; ============================================================
el_refl_table:
    DEFW el_rf_f_myself,   el_rf_t_yourself
    DEFW el_rf_f_yourself, el_rf_t_myself
    DEFW el_rf_f_im,       el_rf_t_youre
    DEFW el_rf_f_youre,    el_rf_t_im
    DEFW el_rf_f_ive,      el_rf_t_youve
    DEFW el_rf_f_youve,    el_rf_t_ive
    DEFW el_rf_f_my,       el_rf_t_your
    DEFW el_rf_f_your,     el_rf_t_my
    DEFW el_rf_f_me,       el_rf_t_you
    DEFW el_rf_f_am,       el_rf_t_are
    DEFW el_rf_f_are,      el_rf_t_am
    DEFW el_rf_f_was,      el_rf_t_were
    DEFW el_rf_f_were,     el_rf_t_was
    DEFW el_rf_f_you,      el_rf_t_i
    DEFW el_rf_f_i,        el_rf_t_you
    DEFW 0

el_rf_f_i:        DEFB "I", 0
el_rf_f_im:       DEFB "I'M", 0
el_rf_f_ive:      DEFB "I'VE", 0
el_rf_f_me:       DEFB "ME", 0
el_rf_f_my:       DEFB "MY", 0
el_rf_f_myself:   DEFB "MYSELF", 0
el_rf_f_am:       DEFB "AM", 0
el_rf_f_was:      DEFB "WAS", 0
el_rf_f_you:      DEFB "YOU", 0
el_rf_f_youre:    DEFB "YOU'RE", 0
el_rf_f_youve:    DEFB "YOU'VE", 0
el_rf_f_your:     DEFB "YOUR", 0
el_rf_f_yourself: DEFB "YOURSELF", 0
el_rf_f_are:      DEFB "ARE", 0
el_rf_f_were:     DEFB "WERE", 0

el_rf_t_you:      DEFB "YOU", 0
el_rf_t_youre:    DEFB "YOU'RE", 0
el_rf_t_youve:    DEFB "YOU'VE", 0
el_rf_t_your:     DEFB "YOUR", 0
el_rf_t_yourself: DEFB "YOURSELF", 0
el_rf_t_i:        DEFB "I", 0
el_rf_t_im:       DEFB "I'M", 0
el_rf_t_ive:      DEFB "I'VE", 0
el_rf_t_my:       DEFB "MY", 0
el_rf_t_myself:   DEFB "MYSELF", 0
el_rf_t_are:      DEFB "ARE", 0
el_rf_t_am:       DEFB "AM", 0
el_rf_t_were:     DEFB "WERE", 0
el_rf_t_was:      DEFB "WAS", 0

; ============================================================
; Variables
; ============================================================
el_input:        DEFS EL_MAX_INPUT + 1, 0
el_tail:         DEFS EL_MAX_INPUT + 1, 0
el_reflected:    DEFS EL_MAX_INPUT + 1, 0
el_mk_tpos:      DEFS 2, 0       ; keyword table scan position
el_lr_tpos:      DEFS 2, 0       ; reflection table scan position
el_rf_wstart:    DEFS 2, 0       ; reflection word start pointer
el_rf_wend_ptr:  DEFS 2, 0       ; reflection word end pointer

; ============================================================
; startrek.asm - Super Star Trek for NostOS
; Classic 1970s Star Trek game ported to 8080-compatible Z80
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    JP   st_main
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================
ST_EMPTY        EQU 0
ST_STAR         EQU 1
ST_KLINGON      EQU 2
ST_BASE         EQU 3
ST_ENTERPRISE   EQU 4

ST_INIT_ENERGY  EQU 3000
ST_INIT_TORPS   EQU 10
ST_MAX_KLINGONS EQU 3       ; max per quadrant

; Damage system indices (0-7)
ST_DMG_WARP     EQU 0
ST_DMG_SRS      EQU 1
ST_DMG_LRS      EQU 2
ST_DMG_PHASER   EQU 3
ST_DMG_TORP     EQU 4
ST_DMG_DMGCTL   EQU 5
ST_DMG_SHIELD   EQU 6
ST_DMG_COMP     EQU 7

; ============================================================
; Main entry point
; ============================================================
st_main:
    CALL st_init
    CALL st_intro
    CALL st_enter_quad
    CALL st_cmd_srs

st_main_loop:
    ; Check win/lose
    CALL st_check_end
    LD   A, (st_gameover)
    OR   A
    JP   NZ, st_exit

    ; Prompt for command
    LD   DE, st_msg_prompt
    CALL st_puts
    CALL st_getline
    LD   HL, st_inbuf
    LD   A, (HL)
    ; Uppercase
    CP   'a'
    JP   C, st_dispatch
    CP   'z'+1
    JP   NC, st_dispatch
    SUB  0x20
st_dispatch:
    CP   'N'
    JP   Z, st_do_nav
    CP   'S'
    JP   Z, st_do_srs
    CP   'L'
    JP   Z, st_do_lrs
    CP   'P'
    JP   Z, st_do_pha
    CP   'T'
    JP   Z, st_do_tor
    CP   'H'
    JP   Z, st_do_she
    CP   'D'
    JP   Z, st_do_dam
    CP   'C'
    JP   Z, st_do_com
    CP   'Q'
    JP   Z, st_do_quit
    CP   '?'
    JP   Z, st_do_help
    ; Unknown command
    LD   DE, st_msg_badcmd
    CALL st_puts
    JP   st_main_loop

st_do_nav:
    CALL st_cmd_nav
    JP   st_main_loop
st_do_srs:
    CALL st_cmd_srs
    JP   st_main_loop
st_do_lrs:
    CALL st_cmd_lrs
    JP   st_main_loop
st_do_pha:
    CALL st_cmd_pha
    JP   st_main_loop
st_do_tor:
    CALL st_cmd_tor
    JP   st_main_loop
st_do_she:
    CALL st_cmd_she
    JP   st_main_loop
st_do_dam:
    CALL st_cmd_dam
    JP   st_main_loop
st_do_com:
    CALL st_cmd_com
    JP   st_main_loop
st_do_quit:
    LD   DE, st_msg_resign
    CALL st_puts
    JP   st_exit
st_do_help:
    LD   DE, st_msg_help
    CALL st_puts
    JP   st_main_loop

st_exit:
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; st_intro - Print title and mission briefing
; ============================================================
st_intro:
    LD   DE, st_msg_title
    CALL st_puts
    ; Print mission
    LD   DE, st_msg_mission1
    CALL st_puts
    LD   A, (st_total_k)
    CALL st_print_a
    LD   DE, st_msg_mission2
    CALL st_puts
    LD   A, (st_timelimit)
    CALL st_print_a
    LD   DE, st_msg_mission3
    CALL st_puts
    LD   A, (st_total_b)
    CALL st_print_a
    LD   DE, st_msg_mission4
    CALL st_puts
    RET

; ============================================================
; st_init - Initialize game state and generate galaxy
; ============================================================
st_init:
    ; Seed RNG from workspace byte (semi-random)
    LD   A, (INPUT_BUFFER)
    OR   A
    JP   NZ, st_init_seed
    LD   A, 0x37
st_init_seed:
    LD   L, A
    LD   H, 0xAC
    LD   (st_rng), HL

    ; Zero game state
    XOR  A
    LD   (st_total_k), A
    LD   (st_total_b), A
    LD   (st_gameover), A
    LD   (st_docked), A

    ; Set starting values
    LD   HL, ST_INIT_ENERGY
    LD   (st_energy), HL
    LD   HL, 0
    LD   (st_shields), HL
    LD   A, ST_INIT_TORPS
    LD   (st_torps), A

    ; Starting stardate: 2000 + rand(0-15)*8 (2000-2120)
    CALL st_rand
    AND  0x0F
    LD   L, A
    LD   H, 0
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL           ; HL = rand(0-15) * 8 = 0-120
    LD   DE, 2000
    ADD  HL, DE           ; HL = 2000-2120
    LD   (st_stardate), HL
    LD   (st_startdate), HL

    ; Time limit: 40 + rand(0-15) = 40-55 stardates
    CALL st_rand
    AND  0x0F
    ADD  A, 40
    LD   (st_timelimit), A

    ; Zero damage
    LD   HL, st_damage
    LD   B, 8
st_init_dmg:
    LD   (HL), 0
    INC  HL
    DEC  B
    JP   NZ, st_init_dmg

    ; Zero known galaxy
    LD   HL, st_known
    LD   B, 64
st_init_known:
    LD   (HL), 0
    INC  HL
    DEC  B
    JP   NZ, st_init_known

    ; Generate galaxy - loop through 64 quadrants using index
    LD   C, 0            ; C = quadrant index 0-63
st_gen_loop:
    PUSH BC

    ; Klingons: rand threshold
    CALL st_rand
    CP   250             ; >250: 3 klingons (~2%)
    JP   NC, st_gen_k3
    CP   240             ; >240: 2 klingons (~4%)
    JP   NC, st_gen_k2
    CP   200             ; >200: 1 klingon (~16%)
    JP   NC, st_gen_k1
    XOR  A               ; 0 klingons
    JP   st_gen_k_done
st_gen_k3:
    LD   A, 3
    JP   st_gen_k_done
st_gen_k2:
    LD   A, 2
    JP   st_gen_k_done
st_gen_k1:
    LD   A, 1
st_gen_k_done:
    POP  BC
    PUSH BC
    PUSH AF              ; save klingon count
    ; Store in galaxy klingon array
    LD   B, 0
    LD   HL, st_gal_k
    ADD  HL, BC
    LD   (HL), A
    ; Add to total
    LD   B, A
    LD   A, (st_total_k)
    ADD  A, B
    LD   (st_total_k), A
    POP  AF              ; restore klingon count

    ; Starbases: ~4% chance
    CALL st_rand
    CP   245
    JP   NC, st_gen_b1
    XOR  A
    JP   st_gen_b_done
st_gen_b1:
    LD   A, 1
st_gen_b_done:
    POP  BC
    PUSH BC
    LD   B, 0
    LD   HL, st_gal_b
    ADD  HL, BC
    LD   (HL), A
    LD   B, A
    LD   A, (st_total_b)
    ADD  A, B
    LD   (st_total_b), A

    ; Stars: 1-8
    CALL st_rand
    AND  0x07
    INC  A               ; 1-8
    POP  BC
    PUSH BC
    LD   B, 0
    LD   HL, st_gal_s
    ADD  HL, BC
    LD   (HL), A

    POP  BC
    INC  C
    LD   A, C
    CP   64
    JP   NZ, st_gen_loop

    ; Ensure at least 1 starbase
    LD   A, (st_total_b)
    OR   A
    JP   NZ, st_gen_base_ok
    ; Place one in a random quadrant
    CALL st_rand
    AND  0x3F            ; 0-63
    LD   C, A
    LD   B, 0
    LD   HL, st_gal_b
    ADD  HL, BC
    LD   (HL), 1
    LD   A, 1
    LD   (st_total_b), A
st_gen_base_ok:

    ; Ensure at least 1 klingon
    LD   A, (st_total_k)
    OR   A
    JP   NZ, st_gen_k_ok
    CALL st_rand
    AND  0x3F
    LD   C, A
    LD   B, 0
    LD   HL, st_gal_k
    ADD  HL, BC
    LD   A, (HL)
    INC  A
    LD   (HL), A
    LD   A, 1
    LD   (st_total_k), A
st_gen_k_ok:

    ; Place enterprise in random quadrant and sector
    CALL st_rand
    AND  0x07
    LD   (st_quad_r), A
    CALL st_rand
    AND  0x07
    LD   (st_quad_c), A
    CALL st_rand
    AND  0x07
    LD   (st_sect_r), A
    CALL st_rand
    AND  0x07
    LD   (st_sect_c), A

    RET

; ============================================================
; st_enter_quad - Set up sector map for current quadrant
; ============================================================
st_enter_quad:
    ; Clear sector map
    LD   HL, st_sector
    LD   B, 64
st_eq_clear:
    LD   (HL), ST_EMPTY
    INC  HL
    DEC  B
    JP   NZ, st_eq_clear

    ; Clear klingon data (prevents phantom attacks from previous quadrant)
    LD   HL, st_kdata
    LD   B, ST_MAX_KLINGONS * 4
st_eq_clear_k:
    LD   (HL), 0
    INC  HL
    DEC  B
    JP   NZ, st_eq_clear_k

    ; Get quadrant index
    LD   A, (st_quad_r)
    ADD  A, A
    ADD  A, A
    ADD  A, A
    LD   B, A
    LD   A, (st_quad_c)
    ADD  A, B             ; A = quad_r*8 + quad_c
    LD   (st_qi), A       ; save quadrant index

    ; Read klingon, base, star counts
    LD   C, A
    LD   B, 0
    LD   HL, st_gal_k
    ADD  HL, BC
    LD   A, (HL)
    LD   (st_cur_k), A
    LD   HL, st_gal_b
    ADD  HL, BC
    LD   A, (HL)
    LD   (st_cur_b), A
    LD   HL, st_gal_s
    ADD  HL, BC
    LD   A, (HL)
    LD   (st_cur_s), A

    ; Mark quadrant as known
    LD   HL, st_known
    ADD  HL, BC
    LD   (HL), 1

    ; Place enterprise
    LD   A, (st_sect_r)
    LD   B, A
    LD   A, (st_sect_c)
    LD   C, A
    CALL st_sect_addr      ; HL = sector map address
    LD   (HL), ST_ENTERPRISE

    ; Place klingons
    LD   A, (st_cur_k)
    OR   A
    JP   Z, st_eq_place_b
    LD   B, A              ; B = count
    LD   C, 0              ; C = index
st_eq_pk_loop:
    PUSH BC
    CALL st_find_empty     ; B=row, C=col
    CALL st_sect_addr      ; HL = sector addr for (B,C)
    LD   (HL), ST_KLINGON
    ; Save klingon data
    LD   D, B              ; D = row
    LD   E, C              ; E = col
    POP  BC                ; B=remaining, C=index
    PUSH BC
    ; Offset into kdata: index * 4
    LD   A, C
    ADD  A, A
    ADD  A, A
    LD   L, A
    LD   H, 0
    PUSH DE
    LD   DE, st_kdata
    ADD  HL, DE
    POP  DE                ; D=row, E=col
    LD   (HL), D           ; row
    INC  HL
    LD   (HL), E           ; col
    INC  HL
    ; Energy: 100 + (rand >> 1) = 100-227
    PUSH HL
    CALL st_rand
    POP  HL
    PUSH HL
    LD   E, A
    LD   D, 0
    LD   A, E
    AND  A                 ; clear carry
    RRA                    ; A = rand/2 (0-127)
    ADD  A, 100            ; 100-227
    LD   E, A
    LD   D, 0              ; DE = energy
    POP  HL
    LD   (HL), E           ; energy low
    INC  HL
    LD   (HL), D           ; energy high
    POP  BC
    INC  C
    DEC  B
    JP   NZ, st_eq_pk_loop

    ; Place starbases
st_eq_place_b:
    LD   A, (st_cur_b)
    OR   A
    JP   Z, st_eq_place_s
    LD   B, A
st_eq_pb_loop:
    PUSH BC
    CALL st_find_empty
    CALL st_sect_addr
    LD   (HL), ST_BASE
    POP  BC
    DEC  B
    JP   NZ, st_eq_pb_loop

    ; Place stars
st_eq_place_s:
    LD   A, (st_cur_s)
    OR   A
    JP   Z, st_eq_done
    LD   B, A
st_eq_ps_loop:
    PUSH BC
    CALL st_find_empty
    CALL st_sect_addr
    LD   (HL), ST_STAR
    POP  BC
    DEC  B
    JP   NZ, st_eq_ps_loop

st_eq_done:
    ; Check docking
    CALL st_check_dock

    ; Print quadrant name and alert
    LD   DE, st_msg_entering
    CALL st_puts
    LD   A, (st_quad_r)
    LD   B, A
    LD   A, (st_quad_c)
    LD   C, A
    CALL st_print_qname
    CALL st_newline
    LD   A, (st_cur_k)
    OR   A
    RET  Z
    LD   DE, st_msg_redalert
    CALL st_puts
    LD   A, (st_cur_k)
    CALL st_print_a
    LD   DE, st_msg_kdetected
    CALL st_puts
    RET

; ============================================================
; st_find_empty - Find a random empty sector
; Outputs: B=row, C=col
; ============================================================
st_find_empty:
    CALL st_rand
    AND  0x07
    LD   B, A              ; random row
    CALL st_rand
    AND  0x07
    LD   C, A              ; random col
    CALL st_sect_addr
    LD   A, (HL)
    OR   A                 ; ST_EMPTY = 0
    RET  Z                 ; found empty
    JP   st_find_empty     ; try again

; ============================================================
; st_sect_addr - Get sector map address
; Inputs: B=row, C=col
; Outputs: HL = address in st_sector
; Preserves: BC, DE
; ============================================================
st_sect_addr:
    LD   A, B
    ADD  A, A
    ADD  A, A
    ADD  A, A
    ADD  A, C              ; A = row*8 + col
    LD   L, A
    LD   H, 0
    PUSH DE
    LD   DE, st_sector
    ADD  HL, DE
    POP  DE
    RET

; ============================================================
; st_cmd_srs - Short Range Scan
; ============================================================
st_cmd_srs:
    ; Check if SRS damaged
    LD   A, (st_damage + ST_DMG_SRS)
    OR   A
    JP   Z, st_srs_ok
    LD   DE, st_msg_srs_dmg
    CALL st_puts
    RET
st_srs_ok:
    LD   DE, st_msg_srs_hdr
    CALL st_puts

    ; Print sector grid
    LD   D, 0              ; D = row counter
st_srs_row:
    ; Print row number
    LD   A, D
    INC  A
    ADD  A, '0'
    LD   E, A
    CALL st_putchar
    LD   E, ' '
    CALL st_putchar

    LD   B, 0              ; B = col counter
st_srs_col:
    ; Get sector content
    LD   A, D              ; row
    ADD  A, A
    ADD  A, A
    ADD  A, A
    ADD  A, B              ; index = row*8 + col
    LD   L, A
    LD   H, 0
    PUSH DE
    LD   DE, st_sector
    ADD  HL, DE
    POP  DE
    LD   A, (HL)
    ; Look up display char
    LD   L, A
    LD   H, 0
    PUSH DE
    LD   DE, st_cell_chars
    ADD  HL, DE
    POP  DE
    LD   A, (HL)
    LD   E, A
    CALL st_putchar
    LD   E, ' '
    CALL st_putchar

    INC  B
    LD   A, B
    CP   8
    JP   NZ, st_srs_col

    CALL st_newline
    INC  D
    LD   A, D
    CP   8
    JP   NZ, st_srs_row

    ; Print status below map
    CALL st_print_status
    RET

; ============================================================
; st_print_status - Print ship status
; ============================================================
st_print_status:
    LD   DE, st_msg_sd
    CALL st_puts
    LD   HL, (st_stardate)
    CALL st_print_hl
    LD   DE, st_msg_cond
    CALL st_puts
    ; Determine condition
    LD   A, (st_docked)
    OR   A
    JP   NZ, st_stat_dock
    LD   A, (st_cur_k)
    OR   A
    JP   NZ, st_stat_red
    LD   HL, (st_energy)
    LD   DE, 300
    CALL st_cmp_hl_de
    JP   C, st_stat_yel
    LD   DE, st_msg_green
    JP   st_stat_cond
st_stat_dock:
    LD   DE, st_msg_docked
    JP   st_stat_cond
st_stat_red:
    LD   DE, st_msg_red
    JP   st_stat_cond
st_stat_yel:
    LD   DE, st_msg_yellow
st_stat_cond:
    CALL st_puts

    LD   DE, st_msg_quad
    CALL st_puts
    LD   A, (st_quad_r)
    INC  A
    CALL st_print_a
    LD   E, ','
    CALL st_putchar
    LD   A, (st_quad_c)
    INC  A
    CALL st_print_a

    LD   DE, st_msg_sect
    CALL st_puts
    LD   A, (st_sect_r)
    INC  A
    CALL st_print_a
    LD   E, ','
    CALL st_putchar
    LD   A, (st_sect_c)
    INC  A
    CALL st_print_a
    CALL st_newline

    LD   DE, st_msg_energy
    CALL st_puts
    LD   HL, (st_energy)
    CALL st_print_hl
    LD   DE, st_msg_shld
    CALL st_puts
    LD   HL, (st_shields)
    CALL st_print_hl
    CALL st_newline

    LD   DE, st_msg_torps
    CALL st_puts
    LD   A, (st_torps)
    CALL st_print_a
    LD   DE, st_msg_krem
    CALL st_puts
    LD   A, (st_total_k)
    CALL st_print_a
    CALL st_newline
    RET

; ============================================================
; st_cmd_lrs - Long Range Scan
; ============================================================
st_cmd_lrs:
    LD   A, (st_damage + ST_DMG_LRS)
    OR   A
    JP   Z, st_lrs_ok
    LD   DE, st_msg_lrs_dmg
    CALL st_puts
    RET
st_lrs_ok:
    LD   DE, st_msg_lrs_hdr
    CALL st_puts
    ; Scan 3x3 around current quadrant
    LD   A, (st_quad_r)
    DEC  A
    LD   D, A              ; D = start row (may be -1)
    LD   E, 3              ; E = row counter
st_lrs_row:
    LD   A, (st_quad_c)
    DEC  A
    LD   B, A              ; B = col (may be -1)
    LD   C, 3              ; C = col counter

    LD   A, E              ; save row counter
    PUSH AF
    PUSH DE
st_lrs_col:
    PUSH BC
    ; Check bounds
    LD   A, D
    CP   0xFF              ; -1?
    JP   Z, st_lrs_oob
    CP   8
    JP   NC, st_lrs_oob
    LD   A, B
    CP   0xFF
    JP   Z, st_lrs_oob
    CP   8
    JP   NC, st_lrs_oob

    ; Valid quadrant: print KBS
    PUSH DE                ; save D (row index) across cell printing
    ; Mark as known
    LD   A, D
    ADD  A, A
    ADD  A, A
    ADD  A, A
    ADD  A, B              ; A = index
    LD   L, A
    LD   H, 0
    PUSH HL
    LD   DE, st_known
    ADD  HL, DE
    LD   (HL), 1
    POP  HL

    ; Get K
    PUSH HL
    LD   DE, st_gal_k
    ADD  HL, DE
    LD   A, (HL)
    ADD  A, '0'
    LD   E, A
    CALL st_putchar
    POP  HL

    ; Get B
    PUSH HL
    LD   DE, st_gal_b
    ADD  HL, DE
    LD   A, (HL)
    ADD  A, '0'
    LD   E, A
    CALL st_putchar
    POP  HL

    ; Get S
    LD   DE, st_gal_s
    ADD  HL, DE
    LD   A, (HL)
    ADD  A, '0'
    LD   E, A
    CALL st_putchar

    LD   E, ' '
    CALL st_putchar
    POP  DE                ; restore D (row index)
    JP   st_lrs_next_col

st_lrs_oob:
    LD   DE, st_msg_oob
    CALL st_puts

st_lrs_next_col:
    POP  BC
    INC  B                 ; next col
    DEC  C
    JP   NZ, st_lrs_col

    CALL st_newline
    POP  DE
    POP  AF
    LD   E, A              ; restore row counter
    INC  D                 ; next row
    DEC  E
    JP   NZ, st_lrs_row
    RET

; ============================================================
; st_cmd_nav - Navigation
; ============================================================
st_cmd_nav:
    ; Check warp engines
    LD   A, (st_damage + ST_DMG_WARP)
    OR   A
    JP   Z, st_nav_eng_ok
    LD   DE, st_msg_warp_dmg
    CALL st_puts
    RET
st_nav_eng_ok:
    ; Get course 1-8
    LD   DE, st_msg_course
    CALL st_puts
    CALL st_getline
    LD   HL, st_inbuf
    CALL st_parse_num
    JP   C, st_nav_bad
    LD   A, E
    OR   A
    JP   Z, st_nav_bad
    CP   9
    JP   NC, st_nav_bad
    DEC  A                 ; 0-based
    LD   (st_tmp1), A      ; course index

    ; Get warp 1-8
    LD   DE, st_msg_warp
    CALL st_puts
    CALL st_getline
    LD   HL, st_inbuf
    CALL st_parse_num
    JP   C, st_nav_bad
    LD   A, E
    OR   A
    JP   Z, st_nav_bad
    CP   9
    JP   NC, st_nav_bad
    LD   (st_tmp2), A      ; warp factor

    ; Energy cost = warp * 10
    LD   B, A
    LD   C, 10
    CALL st_mul_b_c        ; HL = warp * 10
    ; Check we have enough energy (DE >= HL)
    PUSH HL                ; save cost
    LD   DE, (st_energy)
    LD   A, D
    CP   H
    JP   C, st_nav_nrg     ; energy < cost (high byte)
    JP   NZ, st_nav_nrg_ok ; energy > cost (high byte)
    LD   A, E
    CP   L
    JP   C, st_nav_nrg     ; energy < cost (low byte)
st_nav_nrg_ok:
    ; Subtract cost from energy
    LD   HL, (st_energy)
    POP  DE                ; DE = cost
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    LD   (st_energy), HL
    JP   st_nav_move

st_nav_nrg:
    POP  HL
    LD   DE, st_msg_no_nrg
    CALL st_puts
    RET
st_nav_bad:
    LD   DE, st_msg_badinp
    CALL st_puts
    RET

st_nav_move:
    ; Remove enterprise from sector map
    LD   A, (st_sect_r)
    LD   B, A
    LD   A, (st_sect_c)
    LD   C, A
    CALL st_sect_addr
    LD   (HL), ST_EMPTY

    ; Get direction vectors
    LD   A, (st_tmp1)      ; course index 0-7
    LD   L, A
    LD   H, 0
    PUSH HL
    LD   DE, st_dir_r
    ADD  HL, DE
    LD   A, (HL)
    LD   (st_nav_dr), A
    POP  HL
    LD   DE, st_dir_c
    ADD  HL, DE
    LD   A, (HL)
    LD   (st_nav_dc), A

    ; Compute new absolute position and move
    ; abs = quad*8 + sect + dir * warp
    ; Row:
    LD   A, (st_quad_r)
    ADD  A, A
    ADD  A, A
    ADD  A, A
    LD   B, A
    LD   A, (st_sect_r)
    ADD  A, B              ; A = abs_r

    LD   B, A              ; B = abs_r
    LD   A, (st_tmp2)      ; warp
    LD   C, A
    LD   A, (st_nav_dr)    ; dir: FF, 00, or 01
    OR   A
    JP   Z, st_nav_r_same
    JP   M, st_nav_r_neg
    ; Positive: abs_r + warp
    LD   A, B
    ADD  A, C
    CP   64
    JP   C, st_nav_r_ok
    LD   A, 63             ; clamp
    JP   st_nav_r_ok
st_nav_r_neg:
    LD   A, B
    SUB  C
    JP   NC, st_nav_r_ok
    XOR  A                 ; clamp to 0
    JP   st_nav_r_ok
st_nav_r_same:
    LD   A, B
st_nav_r_ok:
    ; Decompose: quad = A/8, sect = A%8
    LD   B, A
    AND  0x07
    LD   (st_sect_r), A
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    LD   (st_new_qr), A

    ; Column (same logic):
    LD   A, (st_quad_c)
    ADD  A, A
    ADD  A, A
    ADD  A, A
    LD   B, A
    LD   A, (st_sect_c)
    ADD  A, B              ; A = abs_c

    LD   B, A
    LD   A, (st_tmp2)
    LD   C, A
    LD   A, (st_nav_dc)
    OR   A
    JP   Z, st_nav_c_same
    JP   M, st_nav_c_neg
    LD   A, B
    ADD  A, C
    CP   64
    JP   C, st_nav_c_ok
    LD   A, 63
    JP   st_nav_c_ok
st_nav_c_neg:
    LD   A, B
    SUB  C
    JP   NC, st_nav_c_ok
    XOR  A
    JP   st_nav_c_ok
st_nav_c_same:
    LD   A, B
st_nav_c_ok:
    LD   B, A
    AND  0x07
    LD   (st_sect_c), A
    LD   A, B
    RRCA
    RRCA
    RRCA
    AND  0x07
    LD   (st_new_qc), A

    ; Advance stardate
    LD   HL, (st_stardate)
    INC  HL
    LD   (st_stardate), HL

    ; Did we change quadrant?
    LD   A, (st_new_qr)
    LD   B, A
    LD   A, (st_quad_r)
    CP   B
    JP   NZ, st_nav_newquad
    LD   A, (st_new_qc)
    LD   B, A
    LD   A, (st_quad_c)
    CP   B
    JP   NZ, st_nav_newquad

    ; Same quadrant: place enterprise and check for collisions
    LD   A, (st_sect_r)
    LD   B, A
    LD   A, (st_sect_c)
    LD   C, A
    CALL st_sect_addr
    LD   A, (HL)
    OR   A
    JP   Z, st_nav_place
    ; Sector occupied! Find nearby empty
    CALL st_find_empty
    LD   A, B
    LD   (st_sect_r), A
    LD   A, C
    LD   (st_sect_c), A
    CALL st_sect_addr
st_nav_place:
    LD   (HL), ST_ENTERPRISE
    CALL st_check_dock
    CALL st_do_repair
    ; Klingons attack
    LD   A, (st_cur_k)
    OR   A
    CALL NZ, st_klingon_attack
    CALL st_cmd_srs
    RET

st_nav_newquad:
    ; Update quadrant
    LD   A, (st_new_qr)
    LD   (st_quad_r), A
    LD   A, (st_new_qc)
    LD   (st_quad_c), A
    CALL st_do_repair
    CALL st_enter_quad
    CALL st_cmd_srs
    RET

; ============================================================
; st_cmd_pha - Phasers
; ============================================================
st_cmd_pha:
    LD   A, (st_damage + ST_DMG_PHASER)
    OR   A
    JP   Z, st_pha_ok
    LD   DE, st_msg_pha_dmg
    CALL st_puts
    RET
st_pha_ok:
    LD   A, (st_cur_k)
    OR   A
    JP   NZ, st_pha_have_k
    LD   DE, st_msg_no_k
    CALL st_puts
    RET
st_pha_have_k:
    ; Ask energy
    LD   DE, st_msg_pha_nrg
    CALL st_puts
    CALL st_getline
    LD   HL, st_inbuf
    CALL st_parse_num
    JP   C, st_nav_bad
    ; DE = energy to fire
    LD   A, D
    OR   E
    RET  Z                 ; 0 = cancel
    ; Check energy available
    LD   HL, (st_energy)
    CALL st_cmp_hl_de
    JP   C, st_pha_no_nrg  ; not enough energy
    ; Subtract from energy
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    LD   (st_energy), HL
    ; DE = total energy fired
    ; Per klingon: DE / cur_k
    LD   A, (st_cur_k)
    LD   C, A
    CALL st_div_de_c       ; DE = energy per klingon

    ; Store energy-per-klingon in temp var
    LD   (st_pha_epk), DE

    ; Loop through all klingon slots (some may be dead)
    LD   B, ST_MAX_KLINGONS
    LD   C, 0              ; C = klingon index
st_pha_loop:
    PUSH BC

    ; Check if this klingon is alive (energy > 0)
    LD   A, C
    ADD  A, A
    ADD  A, A              ; A = index * 4
    LD   L, A
    LD   H, 0
    LD   DE, st_kdata
    ADD  HL, DE
    INC  HL
    INC  HL
    LD   A, (HL)
    INC  HL
    OR   (HL)
    JP   Z, st_pha_skip    ; dead klingon (energy == 0)

    ; Compute distance (Chebyshev: max of |dr|, |dc|, minimum 1)
    POP  BC
    PUSH BC
    LD   A, C
    ADD  A, A
    ADD  A, A
    LD   L, A
    LD   H, 0
    LD   DE, st_kdata
    ADD  HL, DE
    LD   D, (HL)           ; D = k_row
    INC  HL
    LD   E, (HL)           ; E = k_col
    LD   A, (st_sect_r)
    SUB  D
    JP   NC, st_pha_dr_pos
    CPL
    INC  A
st_pha_dr_pos:
    LD   D, A              ; D = |dr|
    LD   A, (st_sect_c)
    SUB  E
    JP   NC, st_pha_dc_pos
    CPL
    INC  A
st_pha_dc_pos:
    CP   D
    JP   NC, st_pha_dist_ok
    LD   A, D              ; A = max(|dr|, |dc|)
st_pha_dist_ok:
    OR   A
    JP   NZ, st_pha_dist_nz
    INC  A                 ; minimum distance 1
st_pha_dist_nz:
    ; Compute hit = (epk / distance) * rand >> 7
    LD   C, A              ; C = distance
    LD   DE, (st_pha_epk)
    CALL st_div_de_c       ; DE = epk / distance
    CALL st_rand
    LD   C, A              ; C = rand byte
    LD   B, E              ; B = low byte of (epk/dist)
    CALL st_mul_b_c        ; HL = B * C
    ; HL >> 7 = (H << 1) | (L >> 7)
    LD   A, L
    RLCA
    AND  0x01
    LD   L, A
    LD   A, H
    ADD  A, A
    OR   L                 ; A = hit amount
    LD   (st_pha_hit), A

    ; Load klingon energy
    POP  BC
    PUSH BC
    LD   A, C
    ADD  A, A
    ADD  A, A
    LD   L, A
    LD   H, 0
    LD   DE, st_kdata
    ADD  HL, DE
    INC  HL
    INC  HL                ; HL = &kdata[i].energy_lo
    LD   E, (HL)
    INC  HL
    LD   D, (HL)           ; DE = klingon energy
    ; Subtract hit
    LD   A, (st_pha_hit)
    LD   C, A
    LD   A, E
    SUB  C
    LD   E, A
    LD   A, D
    SBC  A, 0
    LD   D, A
    JP   NC, st_pha_alive
    ; Klingon destroyed
    LD   D, 0
    LD   E, 0
st_pha_alive:
    ; Store new energy
    LD   (HL), D           ; high byte
    DEC  HL
    LD   (HL), E           ; low byte
    ; Check if destroyed
    LD   A, D
    OR   E
    JP   NZ, st_pha_k_lives

    ; Klingon destroyed — remove from sector map and update counts
    LD   DE, st_msg_k_dead
    CALL st_puts
    POP  BC
    PUSH BC
    LD   A, C
    ADD  A, A
    ADD  A, A
    LD   L, A
    LD   H, 0
    LD   DE, st_kdata
    ADD  HL, DE
    LD   B, (HL)           ; row
    INC  HL
    LD   C, (HL)           ; col
    CALL st_sect_addr
    LD   (HL), ST_EMPTY
    LD   A, (st_cur_k)
    DEC  A
    LD   (st_cur_k), A
    LD   A, (st_total_k)
    DEC  A
    LD   (st_total_k), A
    LD   A, (st_qi)
    LD   L, A
    LD   H, 0
    LD   DE, st_gal_k
    ADD  HL, DE
    DEC  (HL)
    JP   st_pha_skip

st_pha_k_lives:
    LD   DE, st_msg_k_hit
    CALL st_puts

st_pha_skip:
    POP  BC
    INC  C
    LD   A, (st_cur_k)
    OR   A
    JP   Z, st_pha_done    ; all destroyed during loop
    DEC  B
    JP   NZ, st_pha_loop
    JP   st_pha_done

st_pha_no_nrg:
    LD   DE, st_msg_no_nrg
    CALL st_puts
    RET

st_pha_done:
    ; Surviving klingons attack
    LD   A, (st_cur_k)
    OR   A
    CALL NZ, st_klingon_attack
    RET

; ============================================================
; st_cmd_tor - Photon Torpedoes
; ============================================================
st_cmd_tor:
    LD   A, (st_damage + ST_DMG_TORP)
    OR   A
    JP   Z, st_tor_ok
    LD   DE, st_msg_tor_dmg
    CALL st_puts
    RET
st_tor_ok:
    LD   A, (st_torps)
    OR   A
    JP   NZ, st_tor_have
    LD   DE, st_msg_no_tor
    CALL st_puts
    RET
st_tor_have:
    ; Get course
    LD   DE, st_msg_tor_crs
    CALL st_puts
    CALL st_getline
    LD   HL, st_inbuf
    CALL st_parse_num
    JP   C, st_nav_bad
    LD   A, E
    OR   A
    JP   Z, st_nav_bad
    CP   9
    JP   NC, st_nav_bad
    DEC  A                 ; 0-based course

    ; Spend torpedo
    PUSH AF
    LD   A, (st_torps)
    DEC  A
    LD   (st_torps), A
    POP  AF

    ; Get direction vector
    LD   L, A
    LD   H, 0
    PUSH HL
    LD   DE, st_dir_r
    ADD  HL, DE
    LD   A, (HL)
    LD   (st_nav_dr), A
    POP  HL
    LD   DE, st_dir_c
    ADD  HL, DE
    LD   A, (HL)
    LD   (st_nav_dc), A

    ; Start at enterprise position
    LD   A, (st_sect_r)
    LD   B, A
    LD   A, (st_sect_c)
    LD   C, A

    LD   DE, st_msg_track
    CALL st_puts

st_tor_step:
    ; Move one sector
    LD   A, (st_nav_dr)
    ADD  A, B
    LD   B, A              ; new row
    LD   A, (st_nav_dc)
    ADD  A, C
    LD   C, A              ; new col
    ; Check bounds
    LD   A, B
    CP   0xFF
    JP   Z, st_tor_miss
    CP   8
    JP   NC, st_tor_miss
    LD   A, C
    CP   0xFF
    JP   Z, st_tor_miss
    CP   8
    JP   NC, st_tor_miss

    ; Print track position
    LD   A, B
    INC  A
    PUSH BC
    CALL st_print_a
    LD   E, ','
    CALL st_putchar
    POP  BC
    LD   A, C
    INC  A
    PUSH BC
    CALL st_print_a
    LD   DE, st_msg_dots
    CALL st_puts
    POP  BC

    ; Check what's at this sector
    PUSH BC
    CALL st_sect_addr
    LD   A, (HL)
    POP  BC

    CP   ST_KLINGON
    JP   Z, st_tor_hit_k
    CP   ST_STAR
    JP   Z, st_tor_hit_star
    CP   ST_BASE
    JP   Z, st_tor_hit_base
    ; Empty, continue
    JP   st_tor_step

st_tor_miss:
    LD   DE, st_msg_tor_miss
    CALL st_puts
    JP   st_tor_after

st_tor_hit_k:
    LD   DE, st_msg_tor_k
    CALL st_puts
    ; Remove klingon from sector
    PUSH BC
    CALL st_sect_addr
    LD   (HL), ST_EMPTY
    POP  BC
    ; Find which klingon and zero its energy
    CALL st_kill_klingon_at
    ; Update counts
    LD   A, (st_cur_k)
    DEC  A
    LD   (st_cur_k), A
    LD   A, (st_total_k)
    DEC  A
    LD   (st_total_k), A
    LD   A, (st_qi)
    LD   L, A
    LD   H, 0
    LD   DE, st_gal_k
    ADD  HL, DE
    DEC  (HL)
    JP   st_tor_after

st_tor_hit_star:
    LD   DE, st_msg_tor_star
    CALL st_puts
    JP   st_tor_after

st_tor_hit_base:
    LD   DE, st_msg_tor_base
    CALL st_puts
    ; Remove base
    PUSH BC
    CALL st_sect_addr
    LD   (HL), ST_EMPTY
    POP  BC
    LD   A, (st_cur_b)
    DEC  A
    LD   (st_cur_b), A
    LD   A, (st_total_b)
    DEC  A
    LD   (st_total_b), A
    LD   A, (st_qi)
    LD   L, A
    LD   H, 0
    LD   DE, st_gal_b
    ADD  HL, DE
    DEC  (HL)

st_tor_after:
    ; Surviving klingons attack
    LD   A, (st_cur_k)
    OR   A
    CALL NZ, st_klingon_attack
    RET

; ============================================================
; st_kill_klingon_at - Zero energy for klingon at B=row, C=col
; ============================================================
st_kill_klingon_at:
    LD   D, 0              ; D = index
st_kka_loop:
    LD   A, D
    CP   ST_MAX_KLINGONS
    RET  NC                ; not found (shouldn't happen)
    ADD  A, A
    ADD  A, A
    LD   L, A
    LD   H, 0
    PUSH DE
    LD   DE, st_kdata
    ADD  HL, DE
    POP  DE
    LD   A, (HL)           ; row
    CP   B
    JP   NZ, st_kka_next
    INC  HL
    LD   A, (HL)           ; col
    CP   C
    JP   NZ, st_kka_next
    ; Found! Zero energy
    INC  HL
    LD   (HL), 0
    INC  HL
    LD   (HL), 0
    RET
st_kka_next:
    INC  D
    JP   st_kka_loop

; ============================================================
; st_cmd_she - Shields
; ============================================================
st_cmd_she:
    LD   A, (st_damage + ST_DMG_SHIELD)
    OR   A
    JP   Z, st_she_ok
    LD   DE, st_msg_she_dmg
    CALL st_puts
    RET
st_she_ok:
    LD   DE, st_msg_she_ask
    CALL st_puts
    CALL st_getline
    LD   HL, st_inbuf
    CALL st_parse_num
    JP   C, st_nav_bad
    ; DE = desired shield level
    ; Total available = energy + shields
    LD   HL, (st_energy)
    PUSH DE
    LD   DE, (st_shields)
    ADD  HL, DE            ; HL = total
    POP  DE                ; DE = desired shields
    ; Check DE <= HL
    CALL st_cmp_hl_de
    JP   C, st_she_toomuch
    ; New energy = total - desired shields
    ; HL = total already
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    LD   (st_energy), HL
    LD   (st_shields), DE
    LD   DE, st_msg_she_set
    CALL st_puts
    RET
st_she_toomuch:
    LD   DE, st_msg_she_max
    CALL st_puts
    RET

; ============================================================
; st_cmd_dam - Damage Control Report
; ============================================================
st_cmd_dam:
    LD   DE, st_msg_dam_hdr
    CALL st_puts
    LD   B, 0              ; index
st_dam_loop:
    ; Print system name
    LD   A, B
    PUSH BC
    ; Get name pointer from table
    ADD  A, A              ; * 2 for pointer table
    LD   L, A
    LD   H, 0
    LD   DE, st_sys_names
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)           ; DE = name string pointer
    CALL st_puts
    ; Print damage value
    POP  BC
    PUSH BC
    LD   A, B
    LD   L, A
    LD   H, 0
    LD   DE, st_damage
    ADD  HL, DE
    LD   A, (HL)
    CALL st_print_a
    CALL st_newline
    POP  BC
    INC  B
    LD   A, B
    CP   8
    JP   NZ, st_dam_loop
    RET

; ============================================================
; st_cmd_com - Computer
; ============================================================
st_cmd_com:
    LD   A, (st_damage + ST_DMG_COMP)
    OR   A
    JP   Z, st_com_ok
    LD   DE, st_msg_com_dmg
    CALL st_puts
    RET
st_com_ok:
    LD   DE, st_msg_com_menu
    CALL st_puts
    CALL st_getline
    LD   HL, st_inbuf
    LD   A, (HL)
    CP   '1'
    JP   Z, st_com_map
    CP   '2'
    JP   Z, st_com_status
    RET

st_com_map:
    ; Galaxy map
    LD   DE, st_msg_galmap
    CALL st_puts
    LD   D, 0              ; row
st_com_map_row:
    LD   B, 0              ; col
st_com_map_col:
    ; Compute index
    LD   A, D
    ADD  A, A
    ADD  A, A
    ADD  A, A
    ADD  A, B
    LD   L, A
    LD   H, 0
    ; Check if known
    PUSH DE
    PUSH BC
    PUSH HL
    LD   DE, st_known
    ADD  HL, DE
    LD   A, (HL)
    POP  HL
    OR   A
    JP   Z, st_com_unknown

    ; Known: print KBS
    PUSH HL
    LD   DE, st_gal_k
    ADD  HL, DE
    LD   A, (HL)
    ADD  A, '0'
    LD   E, A
    CALL st_putchar
    POP  HL
    PUSH HL
    LD   DE, st_gal_b
    ADD  HL, DE
    LD   A, (HL)
    ADD  A, '0'
    LD   E, A
    CALL st_putchar
    POP  HL
    LD   DE, st_gal_s
    ADD  HL, DE
    LD   A, (HL)
    ADD  A, '0'
    LD   E, A
    CALL st_putchar
    JP   st_com_map_sp

st_com_unknown:
    LD   DE, st_msg_unk
    CALL st_puts
st_com_map_sp:
    LD   E, ' '
    CALL st_putchar
    POP  BC
    POP  DE
    INC  B
    LD   A, B
    CP   8
    JP   NZ, st_com_map_col
    CALL st_newline
    INC  D
    LD   A, D
    CP   8
    JP   NZ, st_com_map_row
    RET

st_com_status:
    LD   DE, st_msg_remain
    CALL st_puts
    LD   A, (st_total_k)
    CALL st_print_a
    LD   DE, st_msg_kremain
    CALL st_puts
    LD   A, (st_total_b)
    CALL st_print_a
    LD   DE, st_msg_bremain
    CALL st_puts
    ; Time remaining
    LD   A, (st_timelimit)
    LD   C, A
    LD   HL, (st_stardate)
    LD   DE, (st_startdate)
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A              ; HL = elapsed
    LD   A, C
    SUB  L                 ; remaining (assume < 256)
    CALL st_print_a
    LD   DE, st_msg_tremain
    CALL st_puts
    RET

; ============================================================
; st_klingon_attack - All klingons fire at enterprise
; ============================================================
st_klingon_attack:
    LD   C, 0              ; index
st_ka_loop:
    LD   A, C
    CP   ST_MAX_KLINGONS
    RET  NC
    PUSH BC
    ; Get klingon data
    LD   A, C
    ADD  A, A
    ADD  A, A
    LD   L, A
    LD   H, 0
    LD   DE, st_kdata
    ADD  HL, DE
    LD   D, (HL)           ; row
    INC  HL
    LD   E, (HL)           ; col
    INC  HL
    PUSH DE                ; save row,col
    LD   E, (HL)
    INC  HL
    LD   D, (HL)           ; DE = energy
    LD   A, D
    OR   E
    JP   Z, st_ka_skip     ; dead

    ; Compute distance
    POP  HL                ; H=row, L=col (from PUSH DE: H=D=row, L=E=col)
    PUSH HL                ; re-save
    LD   A, (st_sect_r)
    SUB  H                 ; A = enterprise_r - klingon_r
    JP   NC, st_ka_dr_pos
    CPL
    INC  A
st_ka_dr_pos:
    LD   B, A              ; B = |dr|
    LD   A, (st_sect_c)
    SUB  L                 ; enterprise_c - klingon_c
    JP   NC, st_ka_dc_pos
    CPL
    INC  A
st_ka_dc_pos:
    CP   B
    JP   NC, st_ka_maxd
    LD   A, B
st_ka_maxd:
    OR   A
    JP   NZ, st_ka_dist
    INC  A
st_ka_dist:
    LD   C, A              ; C = distance

    ; hit = klingon_energy / distance / 2 + rand(0-31)
    ; DE = klingon energy, C = distance
    CALL st_div_de_c       ; DE = energy / distance
    ; Halve DE (16-bit right shift by 1)
    LD   A, D
    AND  A                 ; clear carry
    RRA
    LD   D, A              ; D >>= 1, carry = old D bit 0
    LD   A, E
    RRA
    LD   E, A              ; E >>= 1, D's old bit 0 into E bit 7
    ; Add random
    PUSH DE
    CALL st_rand
    AND  0x1F              ; 0-31
    POP  DE
    ADD  A, E
    LD   E, A
    JP   NC, st_ka_noc
    INC  D
st_ka_noc:
    ; DE = hit amount
    ; Apply to shields first
    LD   HL, (st_shields)
    CALL st_cmp_hl_de
    JP   C, st_ka_hull     ; shields < hit
    ; Shields absorb all
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    LD   (st_shields), HL
    LD   DE, st_msg_shabs
    CALL st_puts
    POP  HL                ; discard saved row,col
    POP  BC
    INC  C
    JP   st_ka_loop

st_ka_hull:
    ; Shields don't cover it all
    ; Remaining damage = hit - shields
    PUSH DE
    LD   HL, (st_shields)
    POP  DE
    LD   A, E
    SUB  L
    LD   E, A
    LD   A, D
    SBC  A, H
    LD   D, A              ; DE = remaining damage
    LD   HL, 0
    LD   (st_shields), HL
    ; Subtract from energy
    LD   HL, (st_energy)
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    JP   NC, st_ka_alive
    LD   HL, 0
st_ka_alive:
    LD   (st_energy), HL
    ; Random system damage
    PUSH HL
    CALL st_rand
    AND  0x07
    LD   L, A
    LD   H, 0
    LD   DE, st_damage
    ADD  HL, DE
    LD   A, (HL)
    ADD  A, 5              ; add 5 damage
    JP   NC, st_ka_dmg_ok
    LD   A, 0xFF           ; clamp at 255
st_ka_dmg_ok:
    LD   (HL), A
    POP  HL

    LD   DE, st_msg_hit
    CALL st_puts

    POP  HL                ; discard saved row,col
    POP  BC
    INC  C
    JP   st_ka_loop

st_ka_skip:
    POP  HL                ; discard saved row,col (or balance stack if not pushed)
    POP  BC
    INC  C
    JP   st_ka_loop

; ============================================================
; st_check_dock - Check if adjacent to starbase
; ============================================================
st_check_dock:
    LD   A, 0
    LD   (st_docked), A
    LD   A, (st_cur_b)
    OR   A
    RET  Z                 ; no bases in quadrant

    ; Check 8 neighbors + current position
    LD   A, (st_sect_r)
    DEC  A
    LD   D, A              ; start row
    LD   E, 3              ; 3 rows
st_dock_r:
    LD   A, D
    CP   0xFF
    JP   Z, st_dock_nr
    CP   8
    JP   NC, st_dock_nr
    LD   A, (st_sect_c)
    DEC  A
    LD   B, A              ; start col
    LD   C, 3
st_dock_c:
    LD   A, B
    CP   0xFF
    JP   Z, st_dock_nc
    CP   8
    JP   NC, st_dock_nc
    ; Check sector (D,B)
    PUSH DE
    PUSH BC
    LD   A, D
    ADD  A, A
    ADD  A, A
    ADD  A, A
    ADD  A, B
    LD   L, A
    LD   H, 0
    LD   DE, st_sector
    ADD  HL, DE
    LD   A, (HL)
    POP  BC
    POP  DE
    CP   ST_BASE
    JP   Z, st_dock_yes
st_dock_nc:
    INC  B
    DEC  C
    JP   NZ, st_dock_c
st_dock_nr:
    INC  D
    DEC  E
    JP   NZ, st_dock_r
    RET                    ; not docked

st_dock_yes:
    LD   A, 1
    LD   (st_docked), A
    ; Restore energy, torpedoes, repair
    LD   HL, ST_INIT_ENERGY
    LD   (st_energy), HL
    LD   HL, 0
    LD   (st_shields), HL
    LD   A, ST_INIT_TORPS
    LD   (st_torps), A
    ; Repair all damage
    LD   HL, st_damage
    LD   B, 8
st_dock_rep:
    LD   (HL), 0
    INC  HL
    DEC  B
    JP   NZ, st_dock_rep
    RET

; ============================================================
; st_do_repair - Repair damage slightly during warp
; ============================================================
st_do_repair:
    LD   HL, st_damage
    LD   B, 8
st_rep_loop:
    LD   A, (HL)
    OR   A
    JP   Z, st_rep_skip
    DEC  A                 ; repair 1 point
    LD   (HL), A
st_rep_skip:
    INC  HL
    DEC  B
    JP   NZ, st_rep_loop
    RET

; ============================================================
; st_check_end - Check win/lose conditions
; ============================================================
st_check_end:
    ; Win: all klingons destroyed
    LD   A, (st_total_k)
    OR   A
    JP   Z, st_win

    ; Lose: energy + shields <= 0
    LD   HL, (st_energy)
    LD   DE, (st_shields)
    ADD  HL, DE
    LD   A, H
    OR   L
    JP   Z, st_lose_nrg

    ; Lose: time up
    LD   HL, (st_stardate)
    LD   DE, (st_startdate)
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A              ; HL = elapsed time
    ; Compare HL >= timelimit (8-bit, so H must be 0 for in-range)
    LD   A, H
    OR   A
    JP   NZ, st_lose_time  ; elapsed > 255, definitely expired
    LD   A, (st_timelimit)
    CP   L                 ; carry if timelimit < elapsed
    JP   C, st_lose_time
    JP   Z, st_lose_time   ; timelimit == elapsed also expired
    RET

st_win:
    LD   DE, st_msg_win
    CALL st_puts
    LD   A, 1
    LD   (st_gameover), A
    RET
st_lose_nrg:
    LD   DE, st_msg_lose_nrg
    CALL st_puts
    LD   A, 1
    LD   (st_gameover), A
    RET
st_lose_time:
    LD   DE, st_msg_lose_time
    CALL st_puts
    LD   A, 1
    LD   (st_gameover), A
    RET

; ============================================================
; st_print_qname - Print quadrant name
; Inputs: B=row (0-7), C=col (0-7)
; ============================================================
st_print_qname:
    ; Name index = row * 2 + (col / 4)
    LD   A, B
    ADD  A, A              ; row * 2
    LD   B, A
    LD   A, C
    RRCA
    RRCA
    AND  0x01              ; col / 4 (0 or 1)
    ADD  A, B              ; index 0-15
    ; Get name pointer
    ADD  A, A              ; * 2
    LD   L, A
    LD   H, 0
    LD   DE, st_qnames
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    CALL st_puts
    ; Print suffix: col % 4 -> " I", " II", " III", " IV"
    LD   A, C
    AND  0x03
    ADD  A, A
    LD   L, A
    LD   H, 0
    LD   DE, st_qsuffix
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    CALL st_puts
    RET

; ============================================================
; I/O Utilities
; ============================================================

; st_puts - Print null-terminated string at DE
st_puts:
    PUSH BC
    PUSH DE
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  DE
    POP  BC
    RET

; st_putchar - Print character in E
st_putchar:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  DE
    POP  BC
    RET

; st_newline - Print CR/LF
st_newline:
    PUSH DE
    LD   DE, st_crlf
    CALL st_puts
    POP  DE
    RET

; st_getline - Read a line into st_inbuf
; Echoes CRLF after reading (piped input doesn't echo Enter)
st_getline:
    PUSH BC
    LD   B, LOGDEV_ID_CONI
    LD   DE, st_inbuf
    LD   C, DEV_CREAD_STR
    CALL KERNELADDR
    ; Echo newline
    LD   E, 0x0D
    CALL st_putchar
    LD   E, 0x0A
    CALL st_putchar
    POP  BC
    RET

; st_print_a - Print A as decimal (0-255)
st_print_a:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   L, A
    LD   H, 0
    CALL st_print_hl
    POP  HL
    POP  DE
    POP  BC
    RET

; st_print_hl - Print HL as unsigned decimal, no leading zeros
st_print_hl:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   B, 0              ; suppress flag
    LD   DE, 10000
    CALL st_phl_digit
    LD   DE, 1000
    CALL st_phl_digit
    LD   DE, 100
    CALL st_phl_digit
    LD   D, 0
    LD   E, 10
    CALL st_phl_digit
    ; Ones: always print
    LD   A, L
    ADD  A, '0'
    LD   E, A
    CALL st_putchar
    POP  HL
    POP  DE
    POP  BC
    RET

; Helper: subtract DE from HL repeatedly, print digit
st_phl_digit:
    LD   C, '0'
st_phld_loop:
    LD   A, L
    SUB  E
    PUSH AF
    LD   A, H
    SBC  A, D
    JP   C, st_phld_done
    LD   H, A
    POP  AF
    LD   L, A
    INC  C
    JP   st_phld_loop
st_phld_done:
    POP  AF                ; discard
    LD   A, C
    CP   '0'
    JP   NZ, st_phld_print
    LD   A, B
    OR   A
    RET  Z                 ; suppress leading zero
st_phld_print:
    LD   B, 1
    LD   E, C
    JP   st_putchar

; st_parse_num - Parse decimal number from (HL)
; Output: DE = number, carry set on error
; HL advanced past digits
st_parse_num:
    ; Skip spaces
st_pn_skip:
    LD   A, (HL)
    CP   ' '
    JP   NZ, st_pn_start
    INC  HL
    JP   st_pn_skip
st_pn_start:
    LD   DE, 0
    LD   B, 0              ; digit count
st_pn_loop:
    LD   A, (HL)
    SUB  '0'
    JP   C, st_pn_end
    CP   10
    JP   NC, st_pn_end
    ; DE = DE * 10 + A
    PUSH AF
    PUSH HL
    ; DE * 10: DE*8 + DE*2
    LD   H, D
    LD   L, E
    ADD  HL, HL            ; *2
    PUSH HL                ; save *2
    ADD  HL, HL            ; *4
    ADD  HL, HL            ; *8
    POP  DE                ; DE = *2
    ADD  HL, DE            ; HL = *10
    LD   D, H
    LD   E, L
    POP  HL
    POP  AF
    ADD  A, E
    LD   E, A
    JP   NC, st_pn_noc
    INC  D
st_pn_noc:
    INC  B
    INC  HL
    JP   st_pn_loop
st_pn_end:
    LD   A, B
    OR   A
    JP   Z, st_pn_err      ; no digits
    AND  A                 ; clear carry
    RET
st_pn_err:
    SCF
    RET

; ============================================================
; Math Utilities
; ============================================================

; st_rand - 16-bit Galois LFSR PRNG
; Output: A = random byte
; Preserves: HL, BC, DE
st_rand:
    PUSH HL
    LD   HL, (st_rng)
    AND  A                 ; clear carry
    LD   A, H
    RRA
    LD   H, A
    LD   A, L
    RRA
    LD   L, A
    JP   NC, st_rand_done
    LD   A, H
    XOR  0xB4
    LD   H, A
st_rand_done:
    LD   (st_rng), HL
    LD   A, H
    POP  HL
    RET

; st_mul_b_c - Multiply B * C, result in HL
; Destroys: A
st_mul_b_c:
    LD   HL, 0
    LD   A, B
    OR   A
    RET  Z
    LD   D, 0
    LD   E, C
st_mul_loop:
    ADD  HL, DE
    DEC  A
    JP   NZ, st_mul_loop
    RET

; st_div_de_c - Divide DE by C, quotient in DE
; Destroys: A, B, HL
st_div_de_c:
    LD   A, C
    OR   A
    RET  Z                 ; div by zero: return DE unchanged
    LD   HL, 0             ; remainder
    LD   B, 16
st_div_loop:
    ; Shift DE left, MSB into HL
    LD   A, E
    ADD  A, A
    LD   E, A
    LD   A, D
    ADC  A, A
    LD   D, A
    LD   A, L
    ADC  A, A
    LD   L, A
    LD   A, H
    ADC  A, A
    LD   H, A
    ; Compare HL with C
    LD   A, H
    OR   A
    JP   NZ, st_div_sub    ; H > 0 so HL >= C
    LD   A, L
    CP   C
    JP   C, st_div_nosub
st_div_sub:
    LD   A, L
    SUB  C
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    INC  E                 ; set quotient bit
st_div_nosub:
    DEC  B
    JP   NZ, st_div_loop
    RET

; st_cmp_hl_de - Compare HL with DE (unsigned)
; Carry set if HL < DE
st_cmp_hl_de:
    LD   A, H
    CP   D
    RET  NZ                ; if H != D, carry tells us
    LD   A, L
    CP   E
    RET

; ============================================================
; Data - Strings
; ============================================================
st_crlf:
    DEFM 0x0D, 0x0A, 0

st_msg_title:
    DEFM 0x0D, 0x0A
    DEFM "*** SUPER STAR TREK ***", 0x0D, 0x0A
    DEFM 0x0D, 0x0A, 0

st_msg_mission1:
    DEFM "Your mission: destroy ", 0
st_msg_mission2:
    DEFM " Klingons in ", 0
st_msg_mission3:
    DEFM " stardates.", 0x0D, 0x0A
    DEFM "There are ", 0
st_msg_mission4:
    DEFM " starbases.", 0x0D, 0x0A, 0x0D, 0x0A, 0

st_msg_help:
    DEFM "Commands:", 0x0D, 0x0A
    DEFM "  N - Navigate    S - Short scan", 0x0D, 0x0A
    DEFM "  L - Long scan   P - Phasers", 0x0D, 0x0A
    DEFM "  T - Torpedoes   H - Shields", 0x0D, 0x0A
    DEFM "  D - Damage      C - Computer", 0x0D, 0x0A
    DEFM "  Q - Quit        ? - Help", 0x0D, 0x0A, 0

st_msg_prompt:
    DEFM "Command? ", 0
st_msg_badcmd:
    DEFM "Unknown command. ? for help.", 0x0D, 0x0A, 0
st_msg_badinp:
    DEFM "Invalid input.", 0x0D, 0x0A, 0

st_msg_srs_hdr:
    DEFM "  1 2 3 4 5 6 7 8", 0x0D, 0x0A, 0
st_msg_srs_dmg:
    DEFM "Short range sensors damaged.", 0x0D, 0x0A, 0
st_msg_lrs_hdr:
    DEFM "Long range scan:", 0x0D, 0x0A, 0
st_msg_lrs_dmg:
    DEFM "Long range sensors damaged.", 0x0D, 0x0A, 0
st_msg_oob:
    DEFM "*** ", 0

st_msg_sd:
    DEFM "Stardate: ", 0
st_msg_cond:
    DEFM "  Condition: ", 0
st_msg_green:
    DEFM "GREEN", 0x0D, 0x0A, 0
st_msg_red:
    DEFM "RED", 0x0D, 0x0A, 0
st_msg_yellow:
    DEFM "YELLOW", 0x0D, 0x0A, 0
st_msg_docked:
    DEFM "DOCKED", 0x0D, 0x0A, 0
st_msg_quad:
    DEFM "Quadrant: ", 0
st_msg_sect:
    DEFM "  Sector: ", 0
st_msg_energy:
    DEFM "Energy: ", 0
st_msg_shld:
    DEFM "  Shields: ", 0
st_msg_torps:
    DEFM "Torpedoes: ", 0
st_msg_krem:
    DEFM "  Klingons: ", 0

st_msg_course:
    DEFM "Course (1-8)? ", 0
st_msg_warp:
    DEFM "Warp (1-8)? ", 0
st_msg_no_nrg:
    DEFM "Not enough energy.", 0x0D, 0x0A, 0
st_msg_warp_dmg:
    DEFM "Warp engines damaged.", 0x0D, 0x0A, 0

st_msg_entering:
    DEFM "Entering ", 0
st_msg_redalert:
    DEFM "RED ALERT: ", 0
st_msg_kdetected:
    DEFM " Klingon(s) detected!", 0x0D, 0x0A, 0

st_msg_pha_dmg:
    DEFM "Phasers damaged.", 0x0D, 0x0A, 0
st_msg_pha_nrg:
    DEFM "Energy to fire? ", 0
st_msg_no_k:
    DEFM "No Klingons in this quadrant.", 0x0D, 0x0A, 0
st_msg_k_dead:
    DEFM "*** Klingon destroyed! ***", 0x0D, 0x0A, 0
st_msg_k_hit:
    DEFM "Klingon hit.", 0x0D, 0x0A, 0

st_msg_tor_dmg:
    DEFM "Torpedo tubes damaged.", 0x0D, 0x0A, 0
st_msg_no_tor:
    DEFM "No torpedoes remaining.", 0x0D, 0x0A, 0
st_msg_tor_crs:
    DEFM "Torpedo course (1-8)? ", 0
st_msg_track:
    DEFM "Torpedo track: ", 0
st_msg_dots:
    DEFM " ", 0
st_msg_tor_miss:
    DEFM "Torpedo missed.", 0x0D, 0x0A, 0
st_msg_tor_k:
    DEFM "*** Klingon destroyed by torpedo! ***", 0x0D, 0x0A, 0
st_msg_tor_star:
    DEFM "Star absorbed torpedo.", 0x0D, 0x0A, 0
st_msg_tor_base:
    DEFM "*** Starbase destroyed! ***", 0x0D, 0x0A, 0

st_msg_she_dmg:
    DEFM "Shield control damaged.", 0x0D, 0x0A, 0
st_msg_she_ask:
    DEFM "Shield energy level? ", 0
st_msg_she_set:
    DEFM "Shields set.", 0x0D, 0x0A, 0
st_msg_she_max:
    DEFM "Not enough energy.", 0x0D, 0x0A, 0

st_msg_dam_hdr:
    DEFM "Damage Report:", 0x0D, 0x0A, 0
st_msg_com_dmg:
    DEFM "Computer damaged.", 0x0D, 0x0A, 0
st_msg_com_menu:
    DEFM "1=Galaxy map, 2=Status? ", 0
st_msg_galmap:
    DEFM "Galaxy Map:", 0x0D, 0x0A, 0
st_msg_unk:
    DEFM "...", 0
st_msg_remain:
    DEFM "Remaining: ", 0
st_msg_kremain:
    DEFM " Klingons, ", 0
st_msg_bremain:
    DEFM " Starbases, ", 0
st_msg_tremain:
    DEFM " Stardates", 0x0D, 0x0A, 0

st_msg_shabs:
    DEFM "Shields absorbed hit.", 0x0D, 0x0A, 0
st_msg_hit:
    DEFM "*** Ship hit! ***", 0x0D, 0x0A, 0

st_msg_resign:
    DEFM "Resigned.", 0x0D, 0x0A, 0
st_msg_win:
    DEFM 0x0D, 0x0A
    DEFM "*** CONGRATULATIONS ***", 0x0D, 0x0A
    DEFM "All Klingons destroyed! The galaxy is safe.", 0x0D, 0x0A, 0
st_msg_lose_nrg:
    DEFM 0x0D, 0x0A
    DEFM "*** THE ENTERPRISE HAS BEEN DESTROYED ***", 0x0D, 0x0A, 0
st_msg_lose_time:
    DEFM 0x0D, 0x0A
    DEFM "*** TIME HAS EXPIRED ***", 0x0D, 0x0A
    DEFM "The Klingons have conquered the galaxy.", 0x0D, 0x0A, 0

; Cell display characters (indexed by ST_EMPTY..ST_ENTERPRISE)
st_cell_chars:
    DEFM ".*KBE"

; Direction tables: course 1=E, 2=NE, 3=N, 4=NW, 5=W, 6=SW, 7=S, 8=SE
; Index 0-7 (course - 1)
st_dir_r:
    DEFB  0, 0xFF, 0xFF, 0xFF,  0,  1,  1,  1
st_dir_c:
    DEFB  1,  1,  0, 0xFF, 0xFF, 0xFF,  0,  1

; System names for damage report
st_sys_names:
    DEFW st_sn0, st_sn1, st_sn2, st_sn3
    DEFW st_sn4, st_sn5, st_sn6, st_sn7
st_sn0: DEFM "  Warp Engines:   ", 0
st_sn1: DEFM "  S.R. Sensors:   ", 0
st_sn2: DEFM "  L.R. Sensors:   ", 0
st_sn3: DEFM "  Phaser Control: ", 0
st_sn4: DEFM "  Torpedo Tubes:  ", 0
st_sn5: DEFM "  Damage Control: ", 0
st_sn6: DEFM "  Shield Control: ", 0
st_sn7: DEFM "  Library Comp:   ", 0

; Quadrant names (16 regions)
st_qnames:
    DEFW st_qn0,  st_qn1,  st_qn2,  st_qn3
    DEFW st_qn4,  st_qn5,  st_qn6,  st_qn7
    DEFW st_qn8,  st_qn9,  st_qn10, st_qn11
    DEFW st_qn12, st_qn13, st_qn14, st_qn15
st_qn0:  DEFM "Antares", 0
st_qn1:  DEFM "Sirius", 0
st_qn2:  DEFM "Rigel", 0
st_qn3:  DEFM "Deneb", 0
st_qn4:  DEFM "Procyon", 0
st_qn5:  DEFM "Capella", 0
st_qn6:  DEFM "Vega", 0
st_qn7:  DEFM "Altair", 0
st_qn8:  DEFM "Sagittar", 0
st_qn9:  DEFM "Pollux", 0
st_qn10: DEFM "Canopus", 0
st_qn11: DEFM "Aldebaran", 0
st_qn12: DEFM "Regulus", 0
st_qn13: DEFM "Arcturus", 0
st_qn14: DEFM "Fomalhaut", 0
st_qn15: DEFM "Spica", 0

; Quadrant suffixes
st_qsuffix:
    DEFW st_qs0, st_qs1, st_qs2, st_qs3
st_qs0: DEFM " I", 0
st_qs1: DEFM " II", 0
st_qs2: DEFM " III", 0
st_qs3: DEFM " IV", 0

; ============================================================
; Variables (BSS)
; ============================================================
st_rng:        DEFW 0
st_gameover:   DEFB 0
st_docked:     DEFB 0

; Ship state
st_energy:     DEFW 0
st_shields:    DEFW 0
st_torps:      DEFB 0
st_quad_r:     DEFB 0
st_quad_c:     DEFB 0
st_sect_r:     DEFB 0
st_sect_c:     DEFB 0
st_stardate:   DEFW 0
st_startdate:  DEFW 0
st_timelimit:  DEFB 0

; Galaxy totals
st_total_k:    DEFB 0
st_total_b:    DEFB 0

; Current quadrant info
st_qi:         DEFB 0      ; quadrant index
st_cur_k:      DEFB 0      ; klingons in current quad
st_cur_b:      DEFB 0      ; bases in current quad
st_cur_s:      DEFB 0      ; stars in current quad

; Galaxy arrays (64 bytes each)
st_gal_k:     DEFS 64, 0
st_gal_b:     DEFS 64, 0
st_gal_s:     DEFS 64, 0
st_known:     DEFS 64, 0

; Sector map (8x8)
st_sector:    DEFS 64, 0

; Klingon data: 3 entries * 4 bytes (row, col, energy_lo, energy_hi)
st_kdata:     DEFS 12, 0

; Damage array (8 systems)
st_damage:    DEFS 8, 0

; Temp variables
st_tmp1:       DEFB 0
st_tmp2:       DEFB 0
st_nav_dr:     DEFB 0
st_nav_dc:     DEFB 0
st_new_qr:     DEFB 0
st_new_qc:     DEFB 0
st_pha_epk:    DEFW 0
st_pha_hit:    DEFB 0

; Input buffer
st_inbuf:     DEFS 80, 0

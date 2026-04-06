; ============================================================
; pacman.asm - Pac-Man game for NostOS
; ============================================================
; Navigate the maze, eat all dots, avoid ghosts.
; Power pellets (o) make ghosts vulnerable for a short time.
;
; Controls:
;   W/w - up       A/a - left
;   S/s - down     D/d - right
;   Q/q - quit
;
; 19x21 maze, 4 ghosts, 4 power pellets.
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    JP   pac_main
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================
PAC_ROWS        EQU 19
PAC_COLS        EQU 21
PAC_MAZE_SIZE   EQU PAC_ROWS * PAC_COLS    ; 399

; Display: maze row 0 at terminal row 2
PAC_DISP_ROW    EQU 2

; Characters
PAC_WALL        EQU '#'
PAC_DOT         EQU '.'
PAC_PELLET      EQU 'o'
PAC_EMPTY       EQU ' '
PAC_CH_PAC      EQU 'C'
PAC_CH_GHOST    EQU 'M'
PAC_CH_FRIGHT   EQU '~'

; Directions
DIR_UP          EQU 0
DIR_RIGHT       EQU 1
DIR_DOWN        EQU 2
DIR_LEFT        EQU 3
DIR_NONE        EQU 0xFF

; Starting positions
PAC_START_ROW   EQU 15
PAC_START_COL   EQU 10
NUM_GHOSTS      EQU 4

; Scoring
SCORE_DOT       EQU 10
SCORE_PELLET    EQU 50
SCORE_GHOST_LO  EQU 200 & 0xFF     ; 200 = 0x00C8
SCORE_GHOST_HI  EQU 200 >> 8

; Timers
FRIGHT_DURATION EQU 30

; Lives
INITIAL_LIVES   EQU 3

; ============================================================
; Include shared ANSI routines
; ============================================================
    INCLUDE "ansi.asm"

; ============================================================
; pac_main - Entry point
; ============================================================
pac_main:
    LD   HL, 0xCAFE
    LD   (pac_rng), HL

    CALL pac_init_game

    CALL ansi_cls
    CALL ansi_hide_cursor

    ; Draw HUD line (row 1)
    CALL pac_draw_hud

    ; Draw full maze
    CALL pac_draw_maze

    ; Draw entities on top
    CALL pac_draw_entities

    ; --------------------------------------------------------
    ; Main game loop
    ; --------------------------------------------------------
pac_loop:
    ; --- Input ---
    CALL pac_handle_input
    LD   A, (pac_quit)
    OR   A
    JP   NZ, pac_exit

    LD   A, (pac_game_over)
    OR   A
    JP   NZ, pac_wait_key

    ; --- Erase moving entities ---
    CALL pac_erase_entities

    ; --- Move pacman ---
    CALL pac_move_pacman

    ; --- Move ghosts (every other frame) ---
    LD   A, (pac_frame)
    AND  1
    CALL Z, pac_move_ghosts

    ; --- Increment frame ---
    LD   A, (pac_frame)
    INC  A
    LD   (pac_frame), A

    ; --- Decrement fright timer ---
    LD   A, (pac_fright)
    OR   A
    JP   Z, pac_no_fright_dec
    DEC  A
    LD   (pac_fright), A
pac_no_fright_dec:

    ; --- Draw entities ---
    CALL pac_draw_entities

    ; --- Check collisions ---
    CALL pac_check_collision

    ; --- Check win ---
    LD   HL, (pac_dots)
    LD   A, H
    OR   L
    JP   NZ, pac_no_win
    LD   A, 1
    LD   (pac_game_over), A
    LD   B, PAC_ROWS + PAC_DISP_ROW
    LD   C, 1
    CALL ansi_goto
    LD   DE, pac_win_str
    CALL ansi_puts
pac_no_win:

    ; --- Update HUD ---
    CALL pac_draw_hud

    ; --- Delay ---
    CALL pac_delay

    JP   pac_loop

; --------------------------------------------------------
pac_wait_key:
    CALL ansi_check_key
    JP   Z, pac_wait_key
    CP   'Q'
    JP   Z, pac_exit
    CP   'q'
    JP   Z, pac_exit
    JP   pac_wait_key

pac_exit:
    CALL ansi_show_cursor
    LD   B, PAC_ROWS + PAC_DISP_ROW + 1
    LD   C, 1
    CALL ansi_goto
    LD   C, SYS_EXIT
    JP   KERNELADDR

; ============================================================
; pac_init_game - Initialize all game state
; ============================================================
pac_init_game:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Copy maze template to working maze
    LD   HL, pac_maze_tmpl
    LD   DE, pac_maze
    LD   BC, PAC_MAZE_SIZE
pac_ig_copy:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, pac_ig_copy

    ; Count dots and pellets
    LD   HL, pac_maze
    LD   BC, PAC_MAZE_SIZE
    LD   DE, 0               ; DE = dot count
pac_ig_count:
    LD   A, (HL)
    CP   PAC_DOT
    JP   Z, pac_ig_inc
    CP   PAC_PELLET
    JP   Z, pac_ig_inc
    JP   pac_ig_next
pac_ig_inc:
    INC  DE
pac_ig_next:
    INC  HL
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, pac_ig_count
    LD   (pac_dots), DE

    ; Pacman position
    LD   A, PAC_START_ROW
    LD   (pac_row), A
    LD   A, PAC_START_COL
    LD   (pac_col), A
    LD   A, DIR_NONE
    LD   (pac_dir), A
    LD   (pac_next_dir), A

    ; Ghost positions
    CALL pac_reset_ghosts

    ; Score = 0
    LD   HL, 0
    LD   (pac_score), HL

    ; Lives
    LD   A, INITIAL_LIVES
    LD   (pac_lives), A

    ; Flags
    XOR  A
    LD   (pac_quit), A
    LD   (pac_game_over), A
    LD   (pac_fright), A
    LD   (pac_frame), A

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_reset_ghosts - Reset ghost positions to start
; ============================================================
pac_reset_ghosts:
    LD   A, (pac_ghost_start)
    LD   (pac_ghost_row), A
    LD   A, (pac_ghost_start + 1)
    LD   (pac_ghost_col), A
    LD   A, (pac_ghost_start + 2)
    LD   (pac_ghost_row + 1), A
    LD   A, (pac_ghost_start + 3)
    LD   (pac_ghost_col + 1), A
    LD   A, (pac_ghost_start + 4)
    LD   (pac_ghost_row + 2), A
    LD   A, (pac_ghost_start + 5)
    LD   (pac_ghost_col + 2), A
    LD   A, (pac_ghost_start + 6)
    LD   (pac_ghost_row + 3), A
    LD   A, (pac_ghost_start + 7)
    LD   (pac_ghost_col + 3), A
    ; Directions
    LD   A, DIR_UP
    LD   (pac_ghost_dir), A
    LD   (pac_ghost_dir + 1), A
    LD   A, DIR_DOWN
    LD   (pac_ghost_dir + 2), A
    LD   (pac_ghost_dir + 3), A
    RET

; ============================================================
; pac_handle_input - Read keypresses, set direction
; ============================================================
pac_handle_input:
    CALL ansi_check_key
    RET  Z                   ; no key

    CP   'Q'
    JP   Z, pac_hi_quit
    CP   'q'
    JP   Z, pac_hi_quit
    CP   'W'
    JP   Z, pac_hi_up
    CP   'w'
    JP   Z, pac_hi_up
    CP   'D'
    JP   Z, pac_hi_right
    CP   'd'
    JP   Z, pac_hi_right
    CP   'S'
    JP   Z, pac_hi_down
    CP   's'
    JP   Z, pac_hi_down
    CP   'A'
    JP   Z, pac_hi_left
    CP   'a'
    JP   Z, pac_hi_left
    RET

pac_hi_quit:
    LD   A, 1
    LD   (pac_quit), A
    RET
pac_hi_up:
    LD   A, DIR_UP
    LD   (pac_next_dir), A
    RET
pac_hi_right:
    LD   A, DIR_RIGHT
    LD   (pac_next_dir), A
    RET
pac_hi_down:
    LD   A, DIR_DOWN
    LD   (pac_next_dir), A
    RET
pac_hi_left:
    LD   A, DIR_LEFT
    LD   (pac_next_dir), A
    RET

; ============================================================
; pac_move_pacman - Move pacman in current direction
; ============================================================
pac_move_pacman:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Try next_dir first (buffered input)
    LD   A, (pac_next_dir)
    CP   DIR_NONE
    JP   Z, pac_mp_try_cur
    LD   B, A
    CALL pac_try_dir         ; A=0 if can move in dir B
    OR   A
    JP   NZ, pac_mp_try_cur
    ; Next dir is valid — adopt it
    LD   A, B
    LD   (pac_dir), A
    JP   pac_mp_do_move

pac_mp_try_cur:
    LD   A, (pac_dir)
    CP   DIR_NONE
    JP   Z, pac_mp_done
    LD   B, A
    CALL pac_try_dir
    OR   A
    JP   NZ, pac_mp_done     ; blocked

pac_mp_do_move:
    ; Move pacman in direction B
    LD   A, (pac_row)
    LD   C, A
    LD   A, (pac_col)
    LD   D, A
    CALL pac_apply_dir       ; C=new_row, D=new_col
    LD   A, C
    LD   (pac_row), A
    LD   A, D
    LD   (pac_col), A

    ; Check what's at the new position
    LD   B, C
    LD   C, D
    CALL pac_maze_addr       ; HL = maze cell address
    LD   A, (HL)

    CP   PAC_DOT
    JP   Z, pac_mp_eat_dot
    CP   PAC_PELLET
    JP   Z, pac_mp_eat_pellet
    JP   pac_mp_done

pac_mp_eat_dot:
    LD   (HL), PAC_EMPTY
    LD   HL, (pac_score)
    LD   DE, SCORE_DOT
    ADD  HL, DE
    LD   (pac_score), HL
    LD   HL, (pac_dots)
    DEC  HL
    LD   (pac_dots), HL
    JP   pac_mp_done

pac_mp_eat_pellet:
    LD   (HL), PAC_EMPTY
    LD   HL, (pac_score)
    LD   DE, SCORE_PELLET
    ADD  HL, DE
    LD   (pac_score), HL
    LD   HL, (pac_dots)
    DEC  HL
    LD   (pac_dots), HL
    LD   A, FRIGHT_DURATION
    LD   (pac_fright), A

pac_mp_done:
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_try_dir - Test if direction B is passable from pacman pos
; Returns: A=0 if can move, A=1 if blocked
; ============================================================
pac_try_dir:
    PUSH BC
    PUSH DE
    LD   A, (pac_row)
    LD   C, A
    LD   A, (pac_col)
    LD   D, A
    CALL pac_apply_dir       ; C=new row, D=new col
    ; Check bounds
    LD   A, C
    CP   PAC_ROWS
    JP   NC, pac_td_blocked
    LD   A, D
    CP   PAC_COLS
    JP   NC, pac_td_blocked
    ; Check maze cell
    LD   B, C
    LD   C, D
    CALL pac_maze_addr
    LD   A, (HL)
    CP   PAC_WALL
    JP   Z, pac_td_blocked
    XOR  A                   ; A=0, can move
    POP  DE
    POP  BC
    RET
pac_td_blocked:
    LD   A, 1
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_apply_dir - Apply direction B to position (C=row, D=col)
; Modifies C and D in place
; ============================================================
pac_apply_dir:
    LD   A, B
    CP   DIR_UP
    JP   Z, pac_ad_up
    CP   DIR_RIGHT
    JP   Z, pac_ad_right
    CP   DIR_DOWN
    JP   Z, pac_ad_down
    ; DIR_LEFT
    DEC  D
    RET
pac_ad_up:
    DEC  C
    RET
pac_ad_right:
    INC  D
    RET
pac_ad_down:
    INC  C
    RET

; ============================================================
; pac_move_ghosts - Move all 4 ghosts
; ============================================================
pac_move_ghosts:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   A, 0               ; ghost index
pac_mg_loop:
    LD   (pac_cur_ghost), A
    CALL pac_move_one_ghost
    LD   A, (pac_cur_ghost)
    INC  A
    CP   NUM_GHOSTS
    JP   C, pac_mg_loop

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_move_one_ghost - Move ghost at index (pac_cur_ghost)
; Uses temp variables to avoid register juggling
; ============================================================
pac_move_one_ghost:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Load ghost index
    LD   A, (pac_cur_ghost)
    LD   E, A
    LD   D, 0

    ; Load position into temp vars
    LD   HL, pac_ghost_row
    ADD  HL, DE
    LD   A, (HL)
    LD   (pac_mog_row), A   ; current row
    LD   HL, pac_ghost_col
    ADD  HL, DE
    LD   A, (HL)
    LD   (pac_mog_col), A   ; current col
    LD   HL, pac_ghost_dir
    ADD  HL, DE
    LD   A, (HL)
    LD   (pac_temp_dir), A  ; current direction

    ; Choose direction via AI
    LD   A, (pac_mog_row)
    LD   B, A
    LD   A, (pac_mog_col)
    LD   C, A
    CALL pac_ghost_ai       ; returns A = chosen direction

    ; Apply direction to get new position
    LD   B, A               ; B = direction
    LD   (pac_temp_dir), A  ; save new direction
    LD   A, (pac_mog_row)
    LD   C, A               ; C = row
    LD   A, (pac_mog_col)
    LD   D, A               ; D = col
    CALL pac_apply_dir      ; C = new row, D = new col

    ; Save new position to temp vars (D is needed for indexing)
    LD   A, C
    LD   (pac_mog_row), A
    LD   A, D
    LD   (pac_mog_col), A

    ; Store new position and direction using ghost index
    LD   A, (pac_cur_ghost)
    LD   E, A
    LD   D, 0
    LD   HL, pac_ghost_row
    ADD  HL, DE
    LD   A, (pac_mog_row)
    LD   (HL), A
    LD   HL, pac_ghost_col
    ADD  HL, DE
    LD   A, (pac_mog_col)
    LD   (HL), A
    LD   HL, pac_ghost_dir
    ADD  HL, DE
    LD   A, (pac_temp_dir)
    LD   (HL), A

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_ghost_ai - Choose direction for ghost
; Inputs: B=ghost row, C=ghost col, pac_temp_dir=current dir
; Output: A=chosen direction
; Preserves: HL (BC, DE clobbered)
; ============================================================
pac_ghost_ai:
    PUSH HL

    ; Save ghost position for use during direction testing
    LD   A, B
    LD   (pac_ai_grow), A
    LD   A, C
    LD   (pac_ai_gcol), A

    ; Compute reverse of current direction (disallowed unless dead end)
    LD   A, (pac_temp_dir)
    XOR  2                   ; UP↔DOWN, RIGHT↔LEFT
    LD   (pac_reverse_dir), A

    ; Initialize best tracking
    LD   A, 0xFF
    LD   (pac_best_dist), A
    LD   A, DIR_NONE
    LD   (pac_best_dir), A
    XOR  A
    LD   (pac_valid_count), A

    ; Try each direction 0-3
    LD   A, 0
pac_ai_loop:
    LD   (pac_ai_try), A

    ; Skip reverse direction
    LD   A, (pac_reverse_dir)
    LD   D, A
    LD   A, (pac_ai_try)
    CP   D
    JP   Z, pac_ai_next

    ; Calculate target cell: apply direction to ghost position
    LD   A, (pac_ai_grow)
    LD   C, A                ; C = row
    LD   A, (pac_ai_gcol)
    LD   D, A                ; D = col
    LD   A, (pac_ai_try)
    LD   B, A                ; B = direction
    CALL pac_apply_dir       ; C = new row, D = new col

    ; Check bounds
    LD   A, C
    CP   PAC_ROWS
    JP   NC, pac_ai_next
    LD   A, D
    CP   PAC_COLS
    JP   NC, pac_ai_next

    ; Check wall: get maze cell at (C, D) — note maze_addr wants B=row, C=col
    LD   A, C                ; save new row
    LD   (pac_ai_nrow), A
    LD   A, D                ; save new col
    LD   (pac_ai_ncol), A
    LD   B, C                ; B = row for maze_addr
    LD   C, D                ; C = col for maze_addr
    CALL pac_maze_addr
    LD   A, (HL)
    CP   PAC_WALL
    JP   Z, pac_ai_next

    ; This direction is valid
    LD   A, (pac_valid_count)
    INC  A
    LD   (pac_valid_count), A

    ; Store this valid direction in the valid list (for frightened random pick)
    DEC  A                   ; index 0-based
    LD   E, A
    LD   D, 0
    LD   HL, pac_valid_dirs
    ADD  HL, DE
    LD   A, (pac_ai_try)
    LD   (HL), A

    ; Calculate Manhattan distance to pacman: |nrow - pac_row| + |ncol - pac_col|
    LD   A, (pac_row)
    LD   B, A
    LD   A, (pac_ai_nrow)
    SUB  B
    JP   P, pac_ai_abs1
    CPL
    INC  A
pac_ai_abs1:
    LD   E, A                ; E = |row diff|
    LD   A, (pac_col)
    LD   B, A
    LD   A, (pac_ai_ncol)
    SUB  B
    JP   P, pac_ai_abs2
    CPL
    INC  A
pac_ai_abs2:
    ADD  A, E                ; A = Manhattan distance

    ; Compare with best
    LD   E, A
    LD   A, (pac_best_dist)
    CP   E
    JP   C, pac_ai_next      ; best < new, skip
    JP   Z, pac_ai_next      ; equal, skip
    ; New best
    LD   A, E
    LD   (pac_best_dist), A
    LD   A, (pac_ai_try)
    LD   (pac_best_dir), A

pac_ai_next:
    LD   A, (pac_ai_try)
    INC  A
    CP   4
    JP   C, pac_ai_loop

    ; If no valid direction found, allow reverse
    LD   A, (pac_valid_count)
    OR   A
    JP   NZ, pac_ai_pick
    LD   A, (pac_reverse_dir)
    POP  HL
    RET

pac_ai_pick:
    ; If frightened, always pick random
    LD   A, (pac_fright)
    OR   A
    JP   NZ, pac_ai_rand

    ; Ghost personality: compare random byte against per-ghost threshold
    ; If random < threshold, pick randomly; otherwise chase
    LD   A, (pac_cur_ghost)
    LD   E, A
    LD   D, 0
    LD   HL, pac_ghost_rnd_thresh
    ADD  HL, DE
    LD   B, (HL)             ; B = randomness threshold
    CALL pac_random
    CP   B
    JP   NC, pac_ai_use_best ; random >= threshold, chase

    ; Pick random valid direction
pac_ai_rand:
    CALL pac_random
    LD   B, A
    LD   A, (pac_valid_count)
    LD   C, A                ; C = count of valid dirs
    LD   A, B                ; A = random byte
    ; A mod C: repeated subtraction
pac_ai_mod:
    CP   C
    JP   C, pac_ai_mod_done
    SUB  C
    JP   pac_ai_mod
pac_ai_mod_done:
    ; A = index into pac_valid_dirs
    LD   E, A
    LD   D, 0
    LD   HL, pac_valid_dirs
    ADD  HL, DE
    LD   A, (HL)
    POP  HL
    RET

pac_ai_use_best:
    LD   A, (pac_best_dir)
    CP   DIR_NONE
    JP   NZ, pac_ai_ret
    ; Fallback: keep current direction
    LD   A, (pac_temp_dir)
pac_ai_ret:
    POP  HL
    RET

; ============================================================
; pac_check_collision - Check pacman vs all ghosts
; ============================================================
pac_check_collision:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   A, (pac_row)
    LD   B, A
    LD   A, (pac_col)
    LD   C, A

    LD   E, 0               ; ghost index
pac_cc_loop:
    LD   D, 0
    LD   HL, pac_ghost_row
    ADD  HL, DE
    LD   A, (HL)
    CP   B
    JP   NZ, pac_cc_next    ; row mismatch
    LD   HL, pac_ghost_col
    ADD  HL, DE
    LD   A, (HL)
    CP   C
    JP   NZ, pac_cc_next    ; col mismatch

    ; Collision! Check if frightened
    LD   A, (pac_fright)
    OR   A
    JP   Z, pac_cc_die

    ; Ghost is frightened — eat it, score += 200
    PUSH DE
    LD   HL, (pac_score)
    LD   D, SCORE_GHOST_HI
    LD   E, SCORE_GHOST_LO
    ADD  HL, DE
    LD   (pac_score), HL
    POP  DE

    ; Reset this ghost to start position
    LD   D, 0
    LD   HL, pac_ghost_start
    ADD  HL, DE
    ADD  HL, DE              ; *2 (each start entry is row,col pair)
    LD   A, (HL)             ; start row
    PUSH HL
    PUSH DE
    LD   D, 0
    LD   HL, pac_ghost_row
    ADD  HL, DE
    LD   (HL), A
    POP  DE
    POP  HL
    INC  HL
    LD   A, (HL)             ; start col
    PUSH DE
    LD   D, 0
    LD   HL, pac_ghost_col
    ADD  HL, DE
    LD   (HL), A
    POP  DE
    JP   pac_cc_next

pac_cc_die:
    ; Pacman dies
    LD   A, (pac_lives)
    DEC  A
    LD   (pac_lives), A
    JP   Z, pac_cc_gameover

    ; Reset positions, continue
    CALL pac_reset_positions
    CALL pac_draw_maze
    CALL pac_draw_entities
    CALL pac_draw_hud
    CALL pac_long_delay
    JP   pac_cc_done

pac_cc_gameover:
    LD   A, 1
    LD   (pac_game_over), A
    LD   B, PAC_ROWS + PAC_DISP_ROW
    LD   C, 1
    CALL ansi_goto
    LD   DE, pac_gameover_str
    CALL ansi_puts
    JP   pac_cc_done

pac_cc_next:
    INC  E
    LD   A, E
    CP   NUM_GHOSTS
    JP   C, pac_cc_loop

pac_cc_done:
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_reset_positions - Reset pacman and ghosts to start
; ============================================================
pac_reset_positions:
    LD   A, PAC_START_ROW
    LD   (pac_row), A
    LD   A, PAC_START_COL
    LD   (pac_col), A
    LD   A, DIR_NONE
    LD   (pac_dir), A
    LD   (pac_next_dir), A
    XOR  A
    LD   (pac_fright), A
    CALL pac_reset_ghosts
    RET

; ============================================================
; pac_maze_addr - Get address of maze cell (B=row, C=col)
; Returns: HL = address in pac_maze
; ============================================================
pac_maze_addr:
    PUSH DE
    ; HL = row * 21 + col
    LD   H, 0
    LD   L, B                ; HL = row
    LD   D, H
    LD   E, L                ; DE = row
    ADD  HL, HL              ; *2
    ADD  HL, HL              ; *4
    ADD  HL, DE              ; *5
    ADD  HL, HL              ; *10
    ADD  HL, HL              ; *20
    ADD  HL, DE              ; *21
    LD   D, 0
    LD   E, C
    ADD  HL, DE              ; + col
    LD   DE, pac_maze
    ADD  HL, DE              ; + base
    POP  DE
    RET

; ============================================================
; pac_draw_maze - Draw entire maze
; ============================================================
pac_draw_maze:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   HL, pac_maze
    LD   B, 0                ; row
pac_dm_row:
    PUSH BC
    PUSH HL
    LD   A, B
    ADD  A, PAC_DISP_ROW
    LD   B, A
    LD   C, 1
    CALL ansi_goto
    POP  HL
    POP  BC

    LD   C, 0                ; col
pac_dm_col:
    LD   A, (HL)
    LD   E, A
    PUSH BC
    PUSH HL
    CALL ansi_putchar
    POP  HL
    POP  BC
    INC  HL
    INC  C
    LD   A, C
    CP   PAC_COLS
    JP   C, pac_dm_col

    INC  B
    LD   A, B
    CP   PAC_ROWS
    JP   C, pac_dm_row

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_draw_cell - Redraw maze cell at (B=row, C=col)
; ============================================================
pac_draw_cell:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   A, B
    ADD  A, PAC_DISP_ROW
    PUSH BC
    LD   B, A
    INC  C                   ; terminal cols are 1-based
    CALL ansi_goto
    POP  BC
    CALL pac_maze_addr
    LD   A, (HL)
    LD   E, A
    CALL ansi_putchar
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_draw_entities - Draw pacman and ghosts
; ============================================================
pac_draw_entities:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Draw pacman
    LD   A, (pac_row)
    ADD  A, PAC_DISP_ROW
    LD   B, A
    LD   A, (pac_col)
    INC  A                   ; 1-based
    LD   C, A
    CALL ansi_goto
    LD   E, PAC_CH_PAC
    CALL ansi_putchar

    ; Draw ghosts
    LD   A, 0
pac_de_loop:
    LD   (pac_temp), A
    LD   E, A
    LD   D, 0
    LD   HL, pac_ghost_row
    ADD  HL, DE
    LD   A, (HL)
    ADD  A, PAC_DISP_ROW
    LD   B, A
    LD   HL, pac_ghost_col
    ADD  HL, DE
    LD   A, (HL)
    INC  A
    LD   C, A
    CALL ansi_goto
    LD   A, (pac_fright)
    OR   A
    JP   Z, pac_de_normal
    LD   E, PAC_CH_FRIGHT
    JP   pac_de_draw
pac_de_normal:
    LD   E, PAC_CH_GHOST
pac_de_draw:
    CALL ansi_putchar
    LD   A, (pac_temp)
    INC  A
    CP   NUM_GHOSTS
    JP   C, pac_de_loop

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_erase_entities - Redraw maze cells under entities
; ============================================================
pac_erase_entities:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Erase pacman
    LD   A, (pac_row)
    LD   B, A
    LD   A, (pac_col)
    LD   C, A
    CALL pac_draw_cell

    ; Erase ghosts
    LD   A, 0
pac_ee_loop:
    LD   (pac_temp), A
    LD   E, A
    LD   D, 0
    LD   HL, pac_ghost_row
    ADD  HL, DE
    LD   B, (HL)
    LD   HL, pac_ghost_col
    ADD  HL, DE
    LD   C, (HL)
    CALL pac_draw_cell
    LD   A, (pac_temp)
    INC  A
    CP   NUM_GHOSTS
    JP   C, pac_ee_loop

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_draw_hud - Draw score and lives on row 1
; ============================================================
pac_draw_hud:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   B, 1
    LD   C, 1
    CALL ansi_goto
    LD   DE, pac_score_str
    CALL ansi_puts
    LD   HL, (pac_score)
    CALL pac_print_u16

    LD   DE, pac_lives_str
    CALL ansi_puts
    LD   A, (pac_lives)
    LD   B, A
    OR   A
    JP   Z, pac_dh_nolives
pac_dh_lloop:
    LD   E, PAC_CH_PAC
    CALL ansi_putchar
    LD   E, ' '
    CALL ansi_putchar
    DEC  B
    JP   NZ, pac_dh_lloop
pac_dh_nolives:
    ; Clear rest of line
    LD   DE, pac_eol_str
    CALL ansi_puts

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; pac_print_u16 - Print 16-bit number in HL
; ============================================================
pac_print_u16:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   C, 0               ; leading zero suppression
    LD   DE, 10000
    CALL pac_pu_digit
    LD   DE, 1000
    CALL pac_pu_digit
    LD   DE, 100
    CALL pac_pu_digit
    LD   DE, 10
    CALL pac_pu_digit
    LD   A, L
    ADD  A, '0'
    LD   E, A
    CALL ansi_putchar
    POP  HL
    POP  DE
    POP  BC
    RET

pac_pu_digit:
    LD   B, 0
pac_pu_div:
    LD   A, L
    SUB  E
    LD   A, H
    SBC  A, D
    JP   C, pac_pu_done
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    INC  B
    JP   pac_pu_div
pac_pu_done:
    LD   A, B
    OR   C
    JP   Z, pac_pu_skip
    LD   C, 1
    LD   A, B
    ADD  A, '0'
    LD   E, A
    CALL ansi_putchar
pac_pu_skip:
    RET

; ============================================================
; pac_random - Galois LFSR PRNG
; Returns: A = random byte
; ============================================================
pac_random:
    PUSH HL
    PUSH DE
    LD   HL, (pac_rng)
    LD   A, H
    OR   A
    RRA
    LD   D, A
    LD   A, L
    RRA
    LD   E, A
    JP   NC, pac_rng_noxor
    LD   A, D
    XOR  0xB4
    LD   D, A
pac_rng_noxor:
    LD   H, D
    LD   L, E
    LD   (pac_rng), HL
    LD   A, L
    POP  DE
    POP  HL
    RET

; ============================================================
; pac_delay - Frame delay
; ============================================================
pac_delay:
    PUSH BC
    PUSH HL
    LD   B, 3
pac_delay_outer:
    LD   HL, 5000
pac_delay_inner:
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, pac_delay_inner
    DEC  B
    JP   NZ, pac_delay_outer
    POP  HL
    POP  BC
    RET

; ============================================================
; pac_long_delay - Longer delay (after death)
; ============================================================
pac_long_delay:
    PUSH BC
    LD   B, 5
pac_ld_loop:
    CALL pac_delay
    DEC  B
    JP   NZ, pac_ld_loop
    POP  BC
    RET

; ============================================================
; Strings
; ============================================================
pac_score_str:
    DEFB "Score:", 0
pac_lives_str:
    DEFB "  Lives:", 0
pac_eol_str:
    DEFB 0x1B, "[K", 0
pac_win_str:
    DEFB "YOU WIN! Press Q to quit.", 0x1B, "[K", 0
pac_gameover_str:
    DEFB "GAME OVER! Press Q to quit.", 0x1B, "[K", 0

; ============================================================
; Ghost starting positions (row, col pairs)
; ============================================================
pac_ghost_start:
    DEFB 1, 1               ; ghost 0: top-left
    DEFB 1, 19              ; ghost 1: top-right
    DEFB 17, 1              ; ghost 2: bottom-left
    DEFB 17, 19             ; ghost 3: bottom-right

; Ghost personality: randomness threshold (0=always chase, 255=always random)
pac_ghost_rnd_thresh:
    DEFB 0                   ; ghost 0: always chases (Blinky)
    DEFB 128                 ; ghost 1: 50% random (Pinky)
    DEFB 192                 ; ghost 2: 75% random (Inky)
    DEFB 64                  ; ghost 3: 25% random (Clyde)

; ============================================================
; Maze template (19 rows x 21 cols, stored as ASCII)
; ============================================================
pac_maze_tmpl:
    DEFM "#####################"
    DEFM "#.........#.........#"
    DEFM "#.###.###.#.###.###.#"
    DEFM "#o.................o#"
    DEFM "#.###.#.#####.#.###.#"
    DEFM "#.....#...#...#.....#"
    DEFM "#.###.###.#.###.###.#"
    DEFM "#.........#.........#"
    DEFM "#.###.#.#####.#.###.#"
    DEFM "#.....#...#...#.....#"
    DEFM "#####.###...###.#####"
    DEFM "#.....#...#...#.....#"
    DEFM "#.###.#.#####.#.###.#"
    DEFM "#.........#.........#"
    DEFM "#.###.###.#.###.###.#"
    DEFM "#o.................o#"
    DEFM "#.###.###.#.###.###.#"
    DEFM "#.........#.........#"
    DEFM "#####################"

; ============================================================
; Variables
; ============================================================
pac_maze:        DEFS PAC_MAZE_SIZE, 0
pac_row:         DEFS 1, 0
pac_col:         DEFS 1, 0
pac_dir:         DEFS 1, 0
pac_next_dir:    DEFS 1, 0
pac_ghost_row:   DEFS NUM_GHOSTS, 0
pac_ghost_col:   DEFS NUM_GHOSTS, 0
pac_ghost_dir:   DEFS NUM_GHOSTS, 0
pac_score:       DEFS 2, 0
pac_dots:        DEFS 2, 0
pac_lives:       DEFS 1, 0
pac_fright:      DEFS 1, 0
pac_frame:       DEFS 1, 0
pac_quit:        DEFS 1, 0
pac_game_over:   DEFS 1, 0
pac_rng:         DEFS 2, 0
pac_cur_ghost:   DEFS 1, 0
pac_temp_dir:    DEFS 1, 0
pac_temp:        DEFS 2, 0
pac_best_dist:   DEFS 1, 0
pac_best_dir:    DEFS 1, 0
pac_valid_count: DEFS 1, 0
pac_valid_dirs:  DEFS 4, 0       ; up to 4 valid directions
pac_reverse_dir: DEFS 1, 0
pac_ai_try:      DEFS 1, 0
pac_ai_grow:     DEFS 1, 0       ; ghost row for AI calculation
pac_ai_gcol:     DEFS 1, 0       ; ghost col for AI calculation
pac_ai_nrow:     DEFS 1, 0       ; new row after direction applied
pac_ai_ncol:     DEFS 1, 0       ; new col after direction applied
pac_mog_row:     DEFS 1, 0       ; move_one_ghost temp row
pac_mog_col:     DEFS 1, 0       ; move_one_ghost temp col

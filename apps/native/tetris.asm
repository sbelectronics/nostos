; ============================================================
; tetris.asm - Tetris for NostOS
; ============================================================
; Classic falling-block puzzle game.
;
; Controls:
;   A/a - move left     D/d - move right
;   S/s - soft drop     W/w - rotate
;   Space - hard drop   Q/q - quit
;
; 10x20 playfield, 7 tetrominoes, line clearing, levels 1-10.
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    JP   tet_main
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================
TET_ROWS        EQU 20
TET_COLS        EQU 10
TET_BOARD_SIZE  EQU TET_ROWS * TET_COLS    ; 200

; Display: border top at terminal row 2, playfield at row 3
TET_BOARD_TOP   EQU 3       ; terminal row of first board row
TET_BOARD_LEFT  EQU 2       ; terminal col of first board col

; Characters
TET_EMPTY       EQU ' '
TET_BLOCK       EQU '#'

; Piece types
NUM_PIECES      EQU 7

; Spawn position
SPAWN_ROW       EQU 0
SPAWN_COL       EQU 3

; Line clear scoring
SCORE_1_LO      EQU 100 & 0xFF
SCORE_1_HI      EQU 100 >> 8
SCORE_2_LO      EQU 300 & 0xFF
SCORE_2_HI      EQU 300 >> 8
SCORE_3_LO      EQU 500 & 0xFF
SCORE_3_HI      EQU 500 >> 8
SCORE_4_LO      EQU 800 & 0xFF
SCORE_4_HI      EQU 800 >> 8

; Lines per level
LINES_PER_LEVEL EQU 10

; ============================================================
; Include shared ANSI routines
; ============================================================
    INCLUDE "ansi.asm"

; ============================================================
; tet_main - Entry point
; ============================================================
tet_main:
    LD   HL, 0xBEEF
    LD   (tet_rng), HL

    CALL tet_init_game
    CALL ansi_cls
    CALL ansi_hide_cursor
    CALL tet_draw_border
    CALL tet_draw_board
    CALL tet_draw_hud
    CALL tet_spawn_piece

    LD   A, (tet_game_over)
    OR   A
    JP   NZ, tet_show_gameover

; --------------------------------------------------------
; Main game loop
; --------------------------------------------------------
tet_loop:
    ; Draw current piece
    CALL tet_draw_piece

    ; Delay (piece visible during delay)
    CALL tet_delay

    ; Erase current piece
    CALL tet_erase_piece

    ; Input
    CALL tet_handle_input
    LD   A, (tet_quit)
    OR   A
    JP   NZ, tet_exit

    LD   A, (tet_game_over)
    OR   A
    JP   NZ, tet_show_gameover

    ; Gravity
    LD   A, (tet_gravity_cnt)
    INC  A
    LD   (tet_gravity_cnt), A

    ; Get speed threshold for current level
    LD   HL, tet_speed_table
    LD   A, (tet_level)
    DEC  A                   ; 0-based index
    CP   10
    JP   C, tet_grav_ok
    LD   A, 9                ; cap at level 10
tet_grav_ok:
    LD   E, A
    LD   D, 0
    ADD  HL, DE
    LD   B, (HL)             ; B = speed threshold
    LD   A, (tet_gravity_cnt)
    CP   B
    JP   C, tet_no_drop

    ; Time to drop
    XOR  A
    LD   (tet_gravity_cnt), A
    CALL tet_try_down
    OR   A
    JP   Z, tet_no_drop      ; moved down OK

    ; Can't move down — lock piece
    CALL tet_lock_piece
    CALL tet_clear_lines
    CALL tet_draw_board
    CALL tet_draw_hud
    CALL tet_spawn_piece
    LD   A, (tet_game_over)
    OR   A
    JP   NZ, tet_show_gameover

tet_no_drop:
    JP   tet_loop

; --------------------------------------------------------
tet_show_gameover:
    CALL tet_draw_board
    LD   B, TET_ROWS + TET_BOARD_TOP + 1
    LD   C, 1
    CALL ansi_goto
    LD   DE, tet_gameover_str
    CALL ansi_puts

tet_wait_key:
    CALL ansi_check_key
    JP   Z, tet_wait_key
    CP   'Q'
    JP   Z, tet_exit
    CP   'q'
    JP   Z, tet_exit
    JP   tet_wait_key

tet_exit:
    CALL ansi_show_cursor
    LD   B, TET_ROWS + TET_BOARD_TOP + 2
    LD   C, 1
    CALL ansi_goto
    LD   C, SYS_EXIT
    JP   KERNELADDR

; ============================================================
; tet_init_game - Initialize all game state
; ============================================================
tet_init_game:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Clear board
    LD   HL, tet_board
    LD   BC, TET_BOARD_SIZE
tet_ig_clr:
    LD   (HL), TET_EMPTY
    INC  HL
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, tet_ig_clr

    ; Init state
    LD   HL, 0
    LD   (tet_score), HL
    LD   (tet_lines), HL
    LD   A, 1
    LD   (tet_level), A
    XOR  A
    LD   (tet_quit), A
    LD   (tet_game_over), A
    LD   (tet_gravity_cnt), A

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_spawn_piece - Spawn a new random piece at top
; ============================================================
tet_spawn_piece:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Pick random piece type (0-6)
    CALL tet_random
    ; A mod 7: repeated subtraction
    LD   B, 7
tet_sp_mod:
    CP   B
    JP   C, tet_sp_mod_done
    SUB  B
    JP   tet_sp_mod
tet_sp_mod_done:
    LD   (tet_piece), A

    ; Reset position and rotation
    LD   A, SPAWN_ROW
    LD   (tet_row), A
    LD   A, SPAWN_COL
    LD   (tet_col), A
    XOR  A
    LD   (tet_rot), A
    LD   (tet_gravity_cnt), A

    ; Check if spawn position is valid
    LD   A, (tet_row)
    LD   B, A
    LD   A, (tet_col)
    LD   C, A
    LD   A, (tet_rot)
    LD   D, A
    CALL tet_check_collision  ; A=0 if OK
    OR   A
    JP   Z, tet_sp_ok

    ; Game over
    LD   A, 1
    LD   (tet_game_over), A

tet_sp_ok:
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_handle_input - Read key and act
; ============================================================
tet_handle_input:
    CALL ansi_check_key
    RET  Z

    CP   'Q'
    JP   Z, tet_hi_quit
    CP   'q'
    JP   Z, tet_hi_quit
    CP   'A'
    JP   Z, tet_hi_left
    CP   'a'
    JP   Z, tet_hi_left
    CP   'D'
    JP   Z, tet_hi_right
    CP   'd'
    JP   Z, tet_hi_right
    CP   'S'
    JP   Z, tet_hi_down
    CP   's'
    JP   Z, tet_hi_down
    CP   'W'
    JP   Z, tet_hi_rotate
    CP   'w'
    JP   Z, tet_hi_rotate
    CP   ' '
    JP   Z, tet_hi_drop
    RET

tet_hi_quit:
    LD   A, 1
    LD   (tet_quit), A
    RET

tet_hi_left:
    LD   A, (tet_row)
    LD   B, A
    LD   A, (tet_col)
    DEC  A
    LD   C, A
    LD   A, (tet_rot)
    LD   D, A
    CALL tet_check_collision
    OR   A
    RET  NZ
    LD   A, (tet_col)
    DEC  A
    LD   (tet_col), A
    RET

tet_hi_right:
    LD   A, (tet_row)
    LD   B, A
    LD   A, (tet_col)
    INC  A
    LD   C, A
    LD   A, (tet_rot)
    LD   D, A
    CALL tet_check_collision
    OR   A
    RET  NZ
    LD   A, (tet_col)
    INC  A
    LD   (tet_col), A
    RET

tet_hi_down:
    CALL tet_try_down
    OR   A
    RET  Z                   ; moved OK
    ; Can't move down — lock
    CALL tet_lock_piece
    CALL tet_clear_lines
    CALL tet_draw_board
    CALL tet_draw_hud
    CALL tet_spawn_piece
    RET

tet_hi_rotate:
    LD   A, (tet_row)
    LD   B, A
    LD   A, (tet_col)
    LD   C, A
    LD   A, (tet_rot)
    INC  A
    AND  3                   ; wrap 0-3
    LD   D, A
    CALL tet_check_collision
    OR   A
    RET  NZ
    LD   A, (tet_rot)
    INC  A
    AND  3
    LD   (tet_rot), A
    RET

tet_hi_drop:
    ; Hard drop: move down until blocked
tet_hd_loop:
    CALL tet_try_down
    OR   A
    JP   Z, tet_hd_loop
    ; Lock
    CALL tet_lock_piece
    CALL tet_clear_lines
    CALL tet_draw_board
    CALL tet_draw_hud
    CALL tet_spawn_piece
    RET

; ============================================================
; tet_try_down - Try to move piece down by one row
; Returns: A=0 if moved, A=1 if blocked
; ============================================================
tet_try_down:
    PUSH BC
    PUSH DE
    LD   A, (tet_row)
    INC  A
    LD   B, A
    LD   A, (tet_col)
    LD   C, A
    LD   A, (tet_rot)
    LD   D, A
    CALL tet_check_collision
    OR   A
    JP   NZ, tet_td_blocked
    LD   A, (tet_row)
    INC  A
    LD   (tet_row), A
    XOR  A
    POP  DE
    POP  BC
    RET
tet_td_blocked:
    LD   A, 1
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_check_collision - Check if piece at (B=row, C=col, D=rot) collides
; Returns: A=0 if OK, A=1 if collision
; ============================================================
tet_check_collision:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Save position for block calculation
    LD   A, B
    LD   (tet_cc_row), A
    LD   A, C
    LD   (tet_cc_col), A
    LD   A, D
    LD   (tet_cc_rot), A

    ; Get shape pointer for piece type + rotation D
    LD   A, (tet_piece)
    LD   (tet_cc_piece), A
    CALL tet_get_shape_ptr_ex  ; HL = shape data

    LD   B, 4               ; 4 blocks
tet_cc_loop:
    ; Get block offsets
    LD   A, (HL)             ; row offset
    LD   D, A
    INC  HL
    LD   A, (HL)             ; col offset
    LD   E, A
    INC  HL
    PUSH HL
    PUSH BC

    ; Compute absolute position
    LD   A, (tet_cc_row)
    ADD  A, D                ; abs_row
    LD   B, A
    LD   A, (tet_cc_col)
    ADD  A, E                ; abs_col
    LD   C, A

    ; Check bounds: row >= TET_ROWS?
    LD   A, B
    CP   TET_ROWS
    JP   NC, tet_cc_hit      ; unsigned: catches < 0 and >= ROWS

    ; Check bounds: col < 0 or col >= TET_COLS?
    LD   A, C
    CP   TET_COLS
    JP   NC, tet_cc_hit

    ; Check board cell
    CALL tet_board_addr       ; HL = board[B][C]
    LD   A, (HL)
    CP   TET_EMPTY
    JP   NZ, tet_cc_hit

    POP  BC
    POP  HL
    DEC  B
    JP   NZ, tet_cc_loop

    ; No collision
    XOR  A
    POP  HL
    POP  DE
    POP  BC
    RET

tet_cc_hit:
    POP  BC
    POP  HL
    LD   A, 1
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_get_shape_ptr - Get pointer to current piece's shape data
; Returns: HL = pointer to 8 bytes (4 row,col pairs)
; ============================================================
tet_get_shape_ptr:
    PUSH DE
    ; offset = piece * 32 + rot * 8
    LD   A, (tet_piece)
    LD   H, 0
    LD   L, A
    ADD  HL, HL              ; *2
    ADD  HL, HL              ; *4
    ADD  HL, HL              ; *8
    ADD  HL, HL              ; *16
    ADD  HL, HL              ; *32
    LD   A, (tet_rot)
    ADD  A, A                ; *2
    ADD  A, A                ; *4
    ADD  A, A                ; *8
    LD   E, A
    LD   D, 0
    ADD  HL, DE
    LD   DE, tet_shapes
    ADD  HL, DE
    POP  DE
    RET

; ============================================================
; tet_get_shape_ptr_ex - Get shape ptr for tet_cc_piece + tet_cc_rot
; Returns: HL = pointer to 8 bytes
; ============================================================
tet_get_shape_ptr_ex:
    PUSH DE
    LD   A, (tet_cc_piece)
    LD   H, 0
    LD   L, A
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL              ; *32
    LD   A, (tet_cc_rot)
    ADD  A, A
    ADD  A, A
    ADD  A, A                ; *8
    LD   E, A
    LD   D, 0
    ADD  HL, DE
    LD   DE, tet_shapes
    ADD  HL, DE
    POP  DE
    RET

; ============================================================
; tet_board_addr - Get address of board cell (B=row, C=col)
; Returns: HL = address in tet_board
; ============================================================
tet_board_addr:
    PUSH DE
    ; HL = row * 10 + col = row * 8 + row * 2 + col
    LD   H, 0
    LD   L, B                ; HL = row
    LD   D, H
    LD   E, L                ; DE = row
    ADD  HL, HL              ; *2
    ADD  HL, HL              ; *4
    ADD  HL, HL              ; *8
    ADD  HL, DE              ; *9
    ADD  HL, DE              ; *10
    LD   D, 0
    LD   E, C
    ADD  HL, DE              ; + col
    LD   DE, tet_board
    ADD  HL, DE              ; + base
    POP  DE
    RET

; ============================================================
; tet_lock_piece - Write current piece into board
; ============================================================
tet_lock_piece:
    PUSH BC
    PUSH DE
    PUSH HL

    CALL tet_get_shape_ptr   ; HL = shape data
    LD   D, 4                ; 4 blocks
tet_lp_loop:
    LD   A, (HL)             ; row offset
    LD   B, A
    INC  HL
    LD   A, (HL)             ; col offset
    LD   C, A
    INC  HL
    PUSH HL
    PUSH DE
    ; Absolute position
    LD   A, (tet_row)
    ADD  A, B
    LD   B, A
    LD   A, (tet_col)
    ADD  A, C
    LD   C, A
    CALL tet_board_addr
    LD   (HL), TET_BLOCK
    POP  DE
    POP  HL
    DEC  D
    JP   NZ, tet_lp_loop

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_clear_lines - Check and clear completed lines
; ============================================================
tet_clear_lines:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   D, 0               ; D = lines cleared this call
    LD   B, TET_ROWS - 1    ; start from bottom row
tet_cl_row:
    ; Check if row B is full
    LD   C, 0               ; col
    LD   A, B
    LD   (tet_cl_cur_row), A
tet_cl_check:
    CALL tet_board_addr
    LD   A, (HL)
    CP   TET_EMPTY
    JP   Z, tet_cl_not_full
    INC  C
    LD   A, C
    CP   TET_COLS
    LD   A, (tet_cl_cur_row)
    LD   B, A
    JP   C, tet_cl_check

    ; Row is full — shift everything above down
    INC  D                   ; count cleared line
    PUSH DE
    LD   A, (tet_cl_cur_row)
    LD   E, A                ; E = row to shift into
tet_cl_shift:
    LD   A, E
    OR   A
    JP   Z, tet_cl_blank_top ; reached top row

    ; Copy row E-1 into row E
    LD   C, 0
tet_cl_copy:
    ; Source: (E-1, C)
    LD   A, E
    DEC  A
    LD   B, A
    CALL tet_board_addr
    LD   A, (HL)
    PUSH AF
    ; Dest: (E, C)
    LD   A, E
    LD   B, A
    CALL tet_board_addr
    POP  AF
    LD   (HL), A
    INC  C
    LD   A, C
    CP   TET_COLS
    JP   C, tet_cl_copy

    DEC  E
    JP   tet_cl_shift

tet_cl_blank_top:
    ; Clear top row
    LD   B, 0
    LD   C, 0
tet_cl_blank:
    CALL tet_board_addr
    LD   (HL), TET_EMPTY
    INC  C
    LD   A, C
    CP   TET_COLS
    JP   C, tet_cl_blank

    POP  DE
    ; Re-check same row (it now has new content from above)
    LD   A, (tet_cl_cur_row)
    LD   B, A
    JP   tet_cl_row

tet_cl_not_full:
    ; Move to row above
    LD   A, (tet_cl_cur_row)
    LD   B, A
    DEC  B
    LD   A, B
    CP   0xFF               ; wrapped past 0?
    JP   NZ, tet_cl_row_save
    JP   tet_cl_done
tet_cl_row_save:
    LD   (tet_cl_cur_row), A
    JP   tet_cl_row

tet_cl_done:
    ; D = number of lines cleared
    LD   A, D
    OR   A
    JP   Z, tet_cl_exit

    ; Update lines count
    LD   A, D
    LD   E, A                ; save lines cleared
    LD   HL, (tet_lines)
    LD   D, 0
    ADD  HL, DE
    LD   (tet_lines), HL

    ; Update level: level = lines / LINES_PER_LEVEL + 1, capped at 10
    ; Skip if already at max level (avoids 8-bit overflow at 256+ lines)
    LD   A, (tet_level)
    CP   10
    JP   NC, tet_cl_skip_level
    LD   A, L                ; low byte of lines
    LD   B, 0
tet_cl_div:
    CP   LINES_PER_LEVEL
    JP   C, tet_cl_div_done
    SUB  LINES_PER_LEVEL
    INC  B
    JP   tet_cl_div
tet_cl_div_done:
    INC  B                   ; level = quotient + 1
    LD   A, B
    CP   10
    JP   C, tet_cl_set_level
    LD   A, 10               ; cap at 10
tet_cl_set_level:
    LD   (tet_level), A
tet_cl_skip_level:

    ; Add score based on lines cleared (E still has count)
    LD   A, E
    CP   1
    JP   Z, tet_cl_s1
    CP   2
    JP   Z, tet_cl_s2
    CP   3
    JP   Z, tet_cl_s3
    ; 4 lines (tetris)
    LD   D, SCORE_4_HI
    LD   E, SCORE_4_LO
    JP   tet_cl_add_score
tet_cl_s1:
    LD   D, SCORE_1_HI
    LD   E, SCORE_1_LO
    JP   tet_cl_add_score
tet_cl_s2:
    LD   D, SCORE_2_HI
    LD   E, SCORE_2_LO
    JP   tet_cl_add_score
tet_cl_s3:
    LD   D, SCORE_3_HI
    LD   E, SCORE_3_LO
tet_cl_add_score:
    LD   HL, (tet_score)
    ADD  HL, DE
    LD   (tet_score), HL

tet_cl_exit:
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_draw_piece - Draw the current piece on screen
; ============================================================
tet_draw_piece:
    PUSH BC
    PUSH DE
    PUSH HL

    CALL tet_get_shape_ptr   ; HL = shape data
    LD   D, 4               ; 4 blocks
tet_dp_loop:
    LD   A, (HL)             ; row offset
    LD   B, A
    INC  HL
    LD   A, (HL)             ; col offset
    LD   C, A
    INC  HL
    PUSH HL
    PUSH DE
    ; Absolute screen position
    LD   A, (tet_row)
    ADD  A, B
    ADD  A, TET_BOARD_TOP
    LD   B, A                ; terminal row
    LD   A, (tet_col)
    ADD  A, C
    ADD  A, TET_BOARD_LEFT
    LD   C, A                ; terminal col
    CALL ansi_goto
    LD   E, TET_BLOCK
    CALL ansi_putchar
    POP  DE
    POP  HL
    DEC  D
    JP   NZ, tet_dp_loop

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_erase_piece - Erase current piece by redrawing board cells
; ============================================================
tet_erase_piece:
    PUSH BC
    PUSH DE
    PUSH HL

    CALL tet_get_shape_ptr   ; HL = shape data
    LD   D, 4
tet_ep_loop:
    LD   A, (HL)             ; row offset
    LD   B, A
    INC  HL
    LD   A, (HL)             ; col offset
    LD   C, A
    INC  HL
    PUSH HL
    PUSH DE
    ; Absolute board position
    LD   A, (tet_row)
    ADD  A, B
    LD   B, A                ; board row
    LD   A, (tet_col)
    ADD  A, C
    LD   C, A                ; board col
    ; Get board cell content
    CALL tet_board_addr
    LD   E, (HL)             ; board cell (should be empty or locked)
    ; Screen position
    LD   A, B
    ADD  A, TET_BOARD_TOP
    LD   B, A
    LD   A, C
    ADD  A, TET_BOARD_LEFT
    LD   C, A
    CALL ansi_goto
    CALL ansi_putchar
    POP  DE
    POP  HL
    DEC  D
    JP   NZ, tet_ep_loop

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_draw_board - Redraw entire playfield from board array
; ============================================================
tet_draw_board:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   HL, tet_board
    LD   B, 0                ; board row
tet_db_row:
    ; Position cursor at start of row
    PUSH BC
    PUSH HL
    LD   A, B
    ADD  A, TET_BOARD_TOP
    LD   B, A
    LD   C, TET_BOARD_LEFT
    CALL ansi_goto
    POP  HL
    POP  BC

    LD   C, 0                ; board col
tet_db_col:
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
    CP   TET_COLS
    JP   C, tet_db_col

    INC  B
    LD   A, B
    CP   TET_ROWS
    JP   C, tet_db_row

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_draw_border - Draw playfield border
; ============================================================
tet_draw_border:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Top border: row 2
    LD   B, TET_BOARD_TOP - 1
    LD   C, 1
    CALL ansi_goto
    LD   E, '+'
    CALL ansi_putchar
    LD   B, TET_COLS
tet_dbo_top:
    LD   E, '-'
    CALL ansi_putchar
    DEC  B
    JP   NZ, tet_dbo_top
    LD   E, '+'
    CALL ansi_putchar

    ; Side borders for each row
    LD   B, 0
tet_dbo_sides:
    PUSH BC
    LD   A, B
    ADD  A, TET_BOARD_TOP
    LD   B, A
    LD   C, 1
    CALL ansi_goto
    LD   E, '|'
    CALL ansi_putchar
    POP  BC
    PUSH BC
    LD   A, B
    ADD  A, TET_BOARD_TOP
    LD   B, A
    LD   C, TET_BOARD_LEFT + TET_COLS
    CALL ansi_goto
    LD   E, '|'
    CALL ansi_putchar
    POP  BC
    INC  B
    LD   A, B
    CP   TET_ROWS
    JP   C, tet_dbo_sides

    ; Bottom border
    LD   B, TET_ROWS + TET_BOARD_TOP
    LD   C, 1
    CALL ansi_goto
    LD   E, '+'
    CALL ansi_putchar
    LD   B, TET_COLS
tet_dbo_bot:
    LD   E, '-'
    CALL ansi_putchar
    DEC  B
    JP   NZ, tet_dbo_bot
    LD   E, '+'
    CALL ansi_putchar

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_draw_hud - Draw score, level, lines on row 1
; ============================================================
tet_draw_hud:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   B, 1
    LD   C, 1
    CALL ansi_goto
    LD   DE, tet_score_str
    CALL ansi_puts
    LD   HL, (tet_score)
    CALL tet_print_u16
    LD   DE, tet_level_str
    CALL ansi_puts
    LD   A, (tet_level)
    LD   L, A
    LD   H, 0
    CALL tet_print_u16
    LD   DE, tet_lines_str
    CALL ansi_puts
    LD   HL, (tet_lines)
    CALL tet_print_u16
    LD   DE, tet_eol_str
    CALL ansi_puts

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; tet_print_u16 - Print 16-bit number in HL
; ============================================================
tet_print_u16:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   C, 0               ; leading zero suppression
    LD   DE, 10000
    CALL tet_pu_digit
    LD   DE, 1000
    CALL tet_pu_digit
    LD   DE, 100
    CALL tet_pu_digit
    LD   DE, 10
    CALL tet_pu_digit
    LD   A, L
    ADD  A, '0'
    LD   E, A
    CALL ansi_putchar
    POP  HL
    POP  DE
    POP  BC
    RET

tet_pu_digit:
    LD   B, 0
tet_pu_div:
    LD   A, L
    SUB  E
    LD   A, H
    SBC  A, D
    JP   C, tet_pu_done
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    INC  B
    JP   tet_pu_div
tet_pu_done:
    LD   A, B
    OR   C
    JP   Z, tet_pu_skip
    LD   C, 1
    LD   A, B
    ADD  A, '0'
    LD   E, A
    CALL ansi_putchar
tet_pu_skip:
    RET

; ============================================================
; tet_random - Galois LFSR PRNG
; Returns: A = random byte
; ============================================================
tet_random:
    PUSH HL
    PUSH DE
    LD   HL, (tet_rng)
    LD   A, H
    OR   A
    RRA
    LD   D, A
    LD   A, L
    RRA
    LD   E, A
    JP   NC, tet_rng_noxor
    LD   A, D
    XOR  0xB4
    LD   D, A
tet_rng_noxor:
    LD   H, D
    LD   L, E
    LD   (tet_rng), HL
    LD   A, L
    POP  DE
    POP  HL
    RET

; ============================================================
; tet_delay - Frame delay
; ============================================================
tet_delay:
    PUSH BC
    PUSH HL
    LD   B, 2
tet_delay_outer:
    LD   HL, 3000
tet_delay_inner:
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, tet_delay_inner
    DEC  B
    JP   NZ, tet_delay_outer
    POP  HL
    POP  BC
    RET

; ============================================================
; Strings
; ============================================================
tet_score_str:
    DEFB "Score:", 0
tet_level_str:
    DEFB "  Lv:", 0
tet_lines_str:
    DEFB "  Lines:", 0
tet_eol_str:
    DEFB 0x1B, "[K", 0
tet_gameover_str:
    DEFB "GAME OVER! Press Q to quit.", 0x1B, "[K", 0

; ============================================================
; Speed table: frames per drop for levels 1-10
; ============================================================
tet_speed_table:
    DEFB 30, 27, 24, 21, 18, 15, 12, 9, 6, 3

; ============================================================
; Piece shapes: 7 pieces x 4 rotations x 4 blocks x 2 bytes (row,col)
; Each piece = 32 bytes. Total = 224 bytes.
; Offsets within a 4x4 bounding box.
; ============================================================
tet_shapes:
    ; Piece 0: I
    ; rot 0
    DEFB 1,0, 1,1, 1,2, 1,3
    ; rot 1
    DEFB 0,2, 1,2, 2,2, 3,2
    ; rot 2
    DEFB 2,0, 2,1, 2,2, 2,3
    ; rot 3
    DEFB 0,1, 1,1, 2,1, 3,1

    ; Piece 1: O
    ; rot 0
    DEFB 0,1, 0,2, 1,1, 1,2
    ; rot 1
    DEFB 0,1, 0,2, 1,1, 1,2
    ; rot 2
    DEFB 0,1, 0,2, 1,1, 1,2
    ; rot 3
    DEFB 0,1, 0,2, 1,1, 1,2

    ; Piece 2: T
    ; rot 0
    DEFB 0,1, 1,0, 1,1, 1,2
    ; rot 1
    DEFB 0,1, 1,1, 1,2, 2,1
    ; rot 2
    DEFB 1,0, 1,1, 1,2, 2,1
    ; rot 3
    DEFB 0,1, 1,0, 1,1, 2,1

    ; Piece 3: S
    ; rot 0
    DEFB 0,1, 0,2, 1,0, 1,1
    ; rot 1
    DEFB 0,0, 1,0, 1,1, 2,1
    ; rot 2
    DEFB 0,1, 0,2, 1,0, 1,1
    ; rot 3
    DEFB 0,0, 1,0, 1,1, 2,1

    ; Piece 4: Z
    ; rot 0
    DEFB 0,0, 0,1, 1,1, 1,2
    ; rot 1
    DEFB 0,1, 1,0, 1,1, 2,0
    ; rot 2
    DEFB 0,0, 0,1, 1,1, 1,2
    ; rot 3
    DEFB 0,1, 1,0, 1,1, 2,0

    ; Piece 5: J
    ; rot 0
    DEFB 0,0, 1,0, 1,1, 1,2
    ; rot 1
    DEFB 0,1, 0,2, 1,1, 2,1
    ; rot 2
    DEFB 1,0, 1,1, 1,2, 2,2
    ; rot 3
    DEFB 0,1, 1,1, 2,0, 2,1

    ; Piece 6: L
    ; rot 0
    DEFB 0,2, 1,0, 1,1, 1,2
    ; rot 1
    DEFB 0,1, 1,1, 2,1, 2,2
    ; rot 2
    DEFB 1,0, 1,1, 1,2, 2,0
    ; rot 3
    DEFB 0,0, 0,1, 1,1, 2,1

; ============================================================
; Variables
; ============================================================
tet_board:       DEFS TET_BOARD_SIZE, 0
tet_row:         DEFS 1, 0       ; current piece row
tet_col:         DEFS 1, 0       ; current piece col
tet_rot:         DEFS 1, 0       ; current piece rotation (0-3)
tet_piece:       DEFS 1, 0       ; current piece type (0-6)
tet_score:       DEFS 2, 0
tet_lines:       DEFS 2, 0
tet_level:       DEFS 1, 0
tet_quit:        DEFS 1, 0
tet_game_over:   DEFS 1, 0
tet_gravity_cnt: DEFS 1, 0
tet_rng:         DEFS 2, 0
tet_cc_row:      DEFS 1, 0       ; collision check temp
tet_cc_col:      DEFS 1, 0
tet_cc_rot:      DEFS 1, 0
tet_cc_piece:    DEFS 1, 0
tet_cl_cur_row:  DEFS 1, 0       ; clear lines temp

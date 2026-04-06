; ============================================================
; life.asm - Conway's Game of Life for NostOS
; ============================================================
; Runs on a 20x40 grid, updating in-place via ANSI cursor control.
;
; Controls:
;   Q       - quit
;   SPACE   - pause/resume
;   S       - pause and single step
;   R       - reset with random pattern
;   G       - glider gun (Gosper's)
;   1-9     - set speed (1=fastest, 9=slowest)
;
; Usage: LIFE [seed]
;   seed  - optional PRNG seed (truncated to 16 bits, 0 keeps default)
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point - jump over the header
    JP   life_main

    ; Header pad: 13 bytes reserved (offsets 3-15)
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================
LIFE_ROWS       EQU 20
LIFE_COLS       EQU 40
LIFE_GRID_SIZE  EQU LIFE_ROWS * LIFE_COLS     ; 800 bytes
LIFE_ALIVE      EQU 1
LIFE_DEAD       EQU 0

LIFE_CHAR_ALIVE EQU '#'
LIFE_CHAR_DEAD  EQU ' '

; Display offset: grid starts at row 3 (row 1=title, row 2=top border)
LIFE_DISP_ROW   EQU 3

; ============================================================
; Include shared ANSI routines
; ============================================================
    INCLUDE "ansi.asm"

; ============================================================
; life_main - Entry point
; ============================================================
life_main:
    ; Default RNG seed
    LD   HL, 0xBEEF
    LD   (life_rng_state), HL

    ; Parse optional seed argument
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, life_start
    CALL life_parse_num
    LD   A, H
    OR   L
    JP   Z, life_start           ; if parse returned 0, keep default
    LD   (life_rng_state), HL

life_start:
    ; Set initial speed (5 = medium)
    LD   A, 5
    LD   (life_speed), A

    ; Not paused
    XOR  A
    LD   (life_paused), A

    ; Generation counter
    LD   HL, 0
    LD   (life_gen), HL

    ; Initialize with random pattern
    CALL life_random_fill

    ; Clear screen, hide cursor
    CALL ansi_cls
    CALL ansi_hide_cursor

    ; Draw static header
    LD   B, 1
    LD   C, 1
    CALL ansi_goto
    LD   DE, life_title_str
    CALL ansi_puts

    ; Draw border
    CALL life_draw_border

    ; Draw initial grid and status
    CALL life_draw_grid
    CALL life_draw_status

    ; Main loop
life_loop:
    ; Check for keypress
    CALL ansi_check_key
    JP   Z, life_no_key

    ; Handle key
    CP   'Q'
    JP   Z, life_quit
    CP   'q'
    JP   Z, life_quit
    CP   ' '
    JP   Z, life_toggle_pause
    CP   'S'
    JP   Z, life_step
    CP   's'
    JP   Z, life_step
    CP   'R'
    JP   Z, life_reset_random
    CP   'r'
    JP   Z, life_reset_random
    CP   'G'
    JP   Z, life_reset_gun
    CP   'g'
    JP   Z, life_reset_gun
    ; Check for digit 1-9
    CP   '1'
    JP   C, life_no_key
    CP   '9' + 1
    JP   NC, life_no_key
    SUB  '0'
    LD   (life_speed), A
    CALL life_draw_status
    JP   life_no_key

life_no_key:
    ; If paused, just loop
    LD   A, (life_paused)
    OR   A
    JP   NZ, life_loop

    ; Compute next generation
    CALL life_next_gen

    ; Increment generation counter
    LD   HL, (life_gen)
    INC  HL
    LD   (life_gen), HL

    ; Redraw grid
    CALL life_draw_grid

    ; Update status line
    CALL life_draw_status

    ; Delay based on speed
    CALL life_delay

    JP   life_loop

life_toggle_pause:
    LD   A, (life_paused)
    XOR  1
    LD   (life_paused), A
    CALL life_draw_status
    JP   life_loop

life_step:
    ; Single step: compute one generation even if paused
    LD   A, 1
    LD   (life_paused), A
    CALL life_next_gen
    LD   HL, (life_gen)
    INC  HL
    LD   (life_gen), HL
    CALL life_draw_grid
    CALL life_draw_status
    JP   life_loop

life_reset_random:
    CALL life_random_fill
    LD   HL, 0
    LD   (life_gen), HL
    CALL life_draw_grid
    CALL life_draw_status
    JP   life_loop

life_reset_gun:
    CALL life_glider_gun
    LD   HL, 0
    LD   (life_gen), HL
    CALL life_draw_grid
    CALL life_draw_status
    JP   life_loop

life_quit:
    ; Show cursor, move below grid
    CALL ansi_show_cursor
    LD   B, LIFE_ROWS + LIFE_DISP_ROW + 2
    LD   C, 1
    CALL ansi_goto
    ; Exit
    LD   C, SYS_EXIT
    JP   KERNELADDR

; ============================================================
; life_next_gen - Compute next generation
; Reads life_grid, writes life_grid2, then copies back
; ============================================================
life_next_gen:
    PUSH BC
    PUSH DE
    PUSH HL

    ; For each cell (row in B, col in C), count neighbors
    LD   B, 0               ; row
life_ng_row:
    LD   C, 0               ; col
life_ng_col:
    ; Count neighbors for cell (B, C)
    CALL life_count_neighbors    ; returns A = neighbor count
    LD   D, A                    ; D = count

    ; Get current cell state
    CALL life_get_cell           ; A = 0 or 1
    LD   E, A                    ; E = current state

    ; Apply rules
    LD   A, E
    OR   A
    JP   Z, life_ng_dead

    ; Cell is alive: survive if count is 2 or 3
    LD   A, D
    CP   2
    JP   Z, life_ng_set_alive
    CP   3
    JP   Z, life_ng_set_alive
    JP   life_ng_set_dead

life_ng_dead:
    ; Cell is dead: born if count is exactly 3
    LD   A, D
    CP   3
    JP   Z, life_ng_set_alive
    JP   life_ng_set_dead

life_ng_set_alive:
    LD   A, LIFE_ALIVE
    JP   life_ng_store
life_ng_set_dead:
    LD   A, LIFE_DEAD
life_ng_store:
    ; Store in grid2 at (B, C)
    CALL life_set_cell2

    ; Next column
    INC  C
    LD   A, C
    CP   LIFE_COLS
    JP   C, life_ng_col

    ; Next row
    INC  B
    LD   A, B
    CP   LIFE_ROWS
    JP   C, life_ng_row

    ; Copy grid2 -> grid
    LD   HL, life_grid2
    LD   DE, life_grid
    LD   BC, LIFE_GRID_SIZE
life_ng_copy:
    LD   A, (HL)
    LD   (DE), A
    INC  HL
    INC  DE
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, life_ng_copy

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; life_count_neighbors - Count live neighbors of cell (B, C)
; Inputs:  B = row, C = col
; Outputs: A = count (0-8)
; ============================================================
life_count_neighbors:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   E, 0               ; E = count

    ; Check all 8 directions: (-1,-1) (-1,0) (-1,+1) (0,-1) (0,+1) (+1,-1) (+1,0) (+1,+1)
    ; Row above (B-1)
    LD   A, B
    OR   A
    JP   Z, life_cn_skip_above  ; row 0, no row above

    DEC  B                   ; B = row-1
    ; (row-1, col-1)
    LD   A, C
    OR   A
    JP   Z, life_cn_a1
    DEC  C
    CALL life_get_cell
    ADD  A, E
    LD   E, A
    INC  C
life_cn_a1:
    ; (row-1, col)
    CALL life_get_cell
    ADD  A, E
    LD   E, A
    ; (row-1, col+1)
    LD   A, C
    CP   LIFE_COLS - 1
    JP   Z, life_cn_a3
    INC  C
    CALL life_get_cell
    ADD  A, E
    LD   E, A
    DEC  C
life_cn_a3:
    INC  B                   ; restore B

life_cn_skip_above:
    ; Same row: (row, col-1) and (row, col+1)
    LD   A, C
    OR   A
    JP   Z, life_cn_s1
    DEC  C
    CALL life_get_cell
    ADD  A, E
    LD   E, A
    INC  C
life_cn_s1:
    LD   A, C
    CP   LIFE_COLS - 1
    JP   Z, life_cn_s2
    INC  C
    CALL life_get_cell
    ADD  A, E
    LD   E, A
    DEC  C
life_cn_s2:

    ; Row below (B+1)
    LD   A, B
    CP   LIFE_ROWS - 1
    JP   Z, life_cn_done     ; last row, no row below

    INC  B                   ; B = row+1
    ; (row+1, col-1)
    LD   A, C
    OR   A
    JP   Z, life_cn_b1
    DEC  C
    CALL life_get_cell
    ADD  A, E
    LD   E, A
    INC  C
life_cn_b1:
    ; (row+1, col)
    CALL life_get_cell
    ADD  A, E
    LD   E, A
    ; (row+1, col+1)
    LD   A, C
    CP   LIFE_COLS - 1
    JP   Z, life_cn_b3
    INC  C
    CALL life_get_cell
    ADD  A, E
    LD   E, A
    DEC  C
life_cn_b3:

life_cn_done:
    LD   A, E               ; A = neighbor count
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; life_get_cell - Get cell state at (B=row, C=col) from grid
; Outputs: A = 0 or 1
; ============================================================
life_get_cell:
    PUSH HL
    PUSH DE
    ; index = row * LIFE_COLS + col
    LD   A, B
    LD   HL, 0
    LD   D, 0
    LD   E, A
    ; Multiply row by LIFE_COLS (40) = row*32 + row*8
    ; row * 8
    ADD  HL, DE
    ADD  HL, HL              ; *2
    ADD  HL, HL              ; *4
    ADD  HL, HL              ; *8
    LD   D, H
    LD   E, L                ; DE = row*8
    ; row * 32
    ADD  HL, HL              ; *16
    ADD  HL, HL              ; *32
    ADD  HL, DE              ; HL = row*32 + row*8 = row*40
    ; Add column
    LD   D, 0
    LD   E, C
    ADD  HL, DE
    ; Add base address
    LD   DE, life_grid
    ADD  HL, DE
    LD   A, (HL)
    POP  DE
    POP  HL
    RET

; ============================================================
; life_set_cell2 - Set cell at (B=row, C=col) in grid2
; Inputs: A = value to store
; ============================================================
life_set_cell2:
    PUSH HL
    PUSH DE
    PUSH AF
    ; index = row * 40 + col
    LD   A, B
    LD   HL, 0
    LD   D, 0
    LD   E, A
    ADD  HL, DE
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    LD   D, H
    LD   E, L
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, DE              ; HL = row * 40
    LD   D, 0
    LD   E, C
    ADD  HL, DE
    LD   DE, life_grid2
    ADD  HL, DE
    POP  AF
    LD   (HL), A
    POP  DE
    POP  HL
    RET

; ============================================================
; life_draw_grid - Redraw the entire grid using ANSI cursor
; ============================================================
life_draw_grid:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   HL, life_grid
    LD   B, 0               ; row counter
life_dg_row:
    ; Position cursor at start of this grid row
    PUSH BC
    PUSH HL
    LD   A, B
    ADD  A, LIFE_DISP_ROW
    LD   B, A
    LD   C, 2               ; col 2 (col 1 is border)
    CALL ansi_goto
    POP  HL
    POP  BC

    LD   C, 0               ; col counter
life_dg_col:
    LD   A, (HL)
    OR   A
    JP   Z, life_dg_dead
    LD   E, LIFE_CHAR_ALIVE
    JP   life_dg_out
life_dg_dead:
    LD   E, LIFE_CHAR_DEAD
life_dg_out:
    PUSH BC
    PUSH HL
    CALL ansi_putchar
    POP  HL
    POP  BC
    INC  HL

    INC  C
    LD   A, C
    CP   LIFE_COLS
    JP   C, life_dg_col

    INC  B
    LD   A, B
    CP   LIFE_ROWS
    JP   C, life_dg_row

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; life_draw_border - Draw border around the grid
; ============================================================
life_draw_border:
    PUSH BC
    PUSH DE

    ; Top border: row LIFE_DISP_ROW-1
    LD   B, LIFE_DISP_ROW - 1
    LD   C, 1
    CALL ansi_goto
    LD   E, '+'
    CALL ansi_putchar
    LD   C, LIFE_COLS
life_db_top:
    LD   E, '-'
    CALL ansi_putchar
    DEC  C
    JP   NZ, life_db_top
    LD   E, '+'
    CALL ansi_putchar

    ; Bottom border: row LIFE_DISP_ROW + LIFE_ROWS
    LD   B, LIFE_DISP_ROW + LIFE_ROWS
    LD   C, 1
    CALL ansi_goto
    LD   E, '+'
    CALL ansi_putchar
    LD   C, LIFE_COLS
life_db_bot:
    LD   E, '-'
    CALL ansi_putchar
    DEC  C
    JP   NZ, life_db_bot
    LD   E, '+'
    CALL ansi_putchar

    ; Left and right borders for each row
    LD   B, 0
life_db_side:
    PUSH BC
    LD   A, B
    ADD  A, LIFE_DISP_ROW
    LD   B, A
    LD   C, 1
    CALL ansi_goto
    LD   E, '|'
    CALL ansi_putchar
    POP  BC

    PUSH BC
    LD   A, B
    ADD  A, LIFE_DISP_ROW
    LD   B, A
    LD   C, LIFE_COLS + 2
    CALL ansi_goto
    LD   E, '|'
    CALL ansi_putchar
    POP  BC

    INC  B
    LD   A, B
    CP   LIFE_ROWS
    JP   C, life_db_side

    POP  DE
    POP  BC
    RET

; ============================================================
; life_draw_status - Draw status line below grid
; ============================================================
life_draw_status:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   B, LIFE_DISP_ROW + LIFE_ROWS + 1
    LD   C, 1
    CALL ansi_goto

    LD   DE, life_gen_str
    CALL ansi_puts

    ; Print generation number
    LD   HL, (life_gen)
    CALL life_print_u16

    LD   DE, life_speed_str
    CALL ansi_puts

    LD   A, (life_speed)
    ADD  A, '0'
    LD   E, A
    CALL ansi_putchar

    ; Show paused status
    LD   A, (life_paused)
    OR   A
    JP   Z, life_ds_running
    LD   DE, life_paused_str
    CALL ansi_puts
    JP   life_ds_done
life_ds_running:
    LD   DE, life_running_str
    CALL ansi_puts
life_ds_done:
    ; Clear rest of line
    LD   DE, life_clear_eol
    CALL ansi_puts

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; life_print_u16 - Print unsigned 16-bit number in HL
; ============================================================
life_print_u16:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   C, 0               ; leading zero suppression

    ; 10000s
    LD   DE, 10000
    CALL life_pu_digit
    ; 1000s
    LD   DE, 1000
    CALL life_pu_digit
    ; 100s
    LD   DE, 100
    CALL life_pu_digit
    ; 10s
    LD   DE, 10
    CALL life_pu_digit
    ; 1s (always print)
    LD   A, L
    ADD  A, '0'
    LD   E, A
    CALL ansi_putchar

    POP  HL
    POP  DE
    POP  BC
    RET

life_pu_digit:
    ; HL = value, DE = divisor
    ; Subtract DE from HL repeatedly, count in B
    LD   B, 0
life_pu_div:
    ; Compare HL >= DE using 8080-compatible 16-bit subtract
    LD   A, L
    SUB  E
    LD   A, H
    SBC  A, D
    JP   C, life_pu_div_done     ; HL < DE
    ; HL >= DE, subtract
    LD   A, L
    SUB  E
    LD   L, A
    LD   A, H
    SBC  A, D
    LD   H, A
    INC  B
    JP   life_pu_div
life_pu_div_done:
    ; B = digit
    LD   A, B
    OR   C                   ; check leading zero suppression
    JP   Z, life_pu_skip
    LD   C, 1               ; stop suppressing
    LD   A, B
    ADD  A, '0'
    LD   E, A
    CALL ansi_putchar
life_pu_skip:
    RET

; ============================================================
; life_random_fill - Fill grid with ~25% random live cells
; ============================================================
life_random_fill:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   HL, life_grid
    LD   BC, LIFE_GRID_SIZE
life_rf_loop:
    CALL life_random
    AND  0x03                ; 25% chance: alive if result = 0
    JP   NZ, life_rf_dead
    LD   (HL), LIFE_ALIVE
    JP   life_rf_next
life_rf_dead:
    LD   (HL), LIFE_DEAD
life_rf_next:
    INC  HL
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, life_rf_loop

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; life_glider_gun - Place Gosper's glider gun pattern
; ============================================================
life_glider_gun:
    PUSH BC
    PUSH DE
    PUSH HL

    ; Clear grid first
    LD   HL, life_grid
    LD   BC, LIFE_GRID_SIZE
life_gg_clear:
    LD   (HL), LIFE_DEAD
    INC  HL
    DEC  BC
    LD   A, B
    OR   C
    JP   NZ, life_gg_clear

    ; Place glider gun cells from table
    ; Table format: row, col pairs terminated by 0xFF
    LD   HL, life_gun_data
life_gg_place:
    LD   B, (HL)
    LD   A, B
    CP   0xFF
    JP   Z, life_gg_done
    INC  HL
    LD   C, (HL)
    INC  HL
    PUSH HL
    ; Set cell (B, C) to alive
    CALL life_set_cell_grid
    POP  HL
    JP   life_gg_place

life_gg_done:
    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; life_set_cell_grid - Set cell (B=row, C=col) alive in grid
; ============================================================
life_set_cell_grid:
    PUSH HL
    PUSH DE
    ; index = row * 40 + col
    LD   A, B
    LD   HL, 0
    LD   D, 0
    LD   E, A
    ADD  HL, DE
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, HL
    LD   D, H
    LD   E, L
    ADD  HL, HL
    ADD  HL, HL
    ADD  HL, DE              ; HL = row * 40
    LD   D, 0
    LD   E, C
    ADD  HL, DE
    LD   DE, life_grid
    ADD  HL, DE
    LD   (HL), LIFE_ALIVE
    POP  DE
    POP  HL
    RET

; ============================================================
; life_delay - Delay proportional to life_speed
; ============================================================
life_delay:
    PUSH BC
    PUSH DE
    PUSH HL

    LD   A, (life_speed)
    LD   B, A                ; outer loops = speed * 1
life_delay_outer:
    LD   HL, 5000            ; inner loop count
life_delay_inner:
    DEC  HL
    LD   A, H
    OR   L
    JP   NZ, life_delay_inner
    DEC  B
    JP   NZ, life_delay_outer

    POP  HL
    POP  DE
    POP  BC
    RET

; ============================================================
; life_random - 16-bit Galois LFSR PRNG
; Taps at bits 16, 14, 13, 11 (polynomial 0xB400)
; Returns: A = pseudo-random byte
; ============================================================
life_random:
    PUSH HL
    PUSH DE
    LD   HL, (life_rng_state)
    ; Shift right by 1
    LD   A, H
    OR   A                   ; clear carry
    RRA
    LD   D, A                ; D = new H
    LD   A, L
    RRA
    LD   E, A                ; E = new L
    ; If carry (old bit 0 was 1), XOR with 0xB400
    JP   NC, life_rng_no_xor
    LD   A, D
    XOR  0xB4
    LD   D, A
life_rng_no_xor:
    LD   H, D
    LD   L, E
    LD   (life_rng_state), HL
    LD   A, L               ; return low byte
    POP  DE
    POP  HL
    RET

; ============================================================
; life_parse_num - Parse decimal number from string at HL
; Returns: HL = parsed value (0 on failure)
; ============================================================
life_parse_num:
    PUSH BC
    PUSH DE
    LD   DE, 0               ; accumulator
life_pn_loop:
    LD   A, (HL)
    CP   '0'
    JP   C, life_pn_done
    CP   '9' + 1
    JP   NC, life_pn_done
    SUB  '0'
    LD   C, A                ; save digit
    ; DE = DE * 10 + digit
    PUSH HL
    LD   H, D
    LD   L, E
    ADD  HL, HL              ; *2
    ADD  HL, HL              ; *4
    ADD  HL, DE              ; *5
    ADD  HL, HL              ; *10
    LD   D, 0
    LD   E, C
    ADD  HL, DE
    LD   D, H
    LD   E, L
    POP  HL
    INC  HL
    JP   life_pn_loop
life_pn_done:
    LD   H, D
    LD   L, E
    POP  DE
    POP  BC
    RET

; ============================================================
; Data
; ============================================================
life_title_str:
    DEFB "Conway's Game of Life  Q:quit SP:pause S:step R:rand G:gun", 0

life_gen_str:
    DEFB "Gen: ", 0

life_speed_str:
    DEFB "  Speed: ", 0

life_paused_str:
    DEFB "  [PAUSED]", 0

life_running_str:
    DEFB "  [RUNNING]", 0

life_clear_eol:
    DEFB 0x1B, "[K", 0      ; ESC[K = clear to end of line

; Gosper glider gun pattern (row, col pairs, 0xFF terminated)
; Placed starting at row 1, col 1
life_gun_data:
    ; Left block
    DEFB 5, 1
    DEFB 5, 2
    DEFB 6, 1
    DEFB 6, 2
    ; Left ship
    DEFB 5, 11
    DEFB 6, 11
    DEFB 7, 11
    DEFB 4, 12
    DEFB 8, 12
    DEFB 3, 13
    DEFB 9, 13
    DEFB 3, 14
    DEFB 9, 14
    DEFB 6, 15
    DEFB 4, 16
    DEFB 8, 16
    DEFB 5, 17
    DEFB 6, 17
    DEFB 7, 17
    DEFB 6, 18
    ; Right ship
    DEFB 3, 21
    DEFB 4, 21
    DEFB 5, 21
    DEFB 3, 22
    DEFB 4, 22
    DEFB 5, 22
    DEFB 2, 23
    DEFB 6, 23
    DEFB 1, 25
    DEFB 2, 25
    DEFB 6, 25
    DEFB 7, 25
    ; Right block
    DEFB 3, 35
    DEFB 4, 35
    DEFB 3, 36
    DEFB 4, 36
    DEFB 0xFF

; ============================================================
; Variables
; ============================================================
life_rng_state: DEFS 2, 0
life_speed:     DEFS 1, 0
life_paused:    DEFS 1, 0
life_gen:       DEFS 2, 0
life_grid:      DEFS LIFE_GRID_SIZE, 0    ; 800 bytes - current generation
life_grid2:     DEFS LIFE_GRID_SIZE, 0    ; 800 bytes - next generation

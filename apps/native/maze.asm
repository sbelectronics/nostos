; ============================================================
; maze.asm - Maze generator for NostOS
; ============================================================
; Usage: MAZE [rows] [cols] [seed]
;   rows  - number of rows (default 10, max 40)
;   cols  - number of columns (default 20, max 40)
;   seed  - PRNG seed 1-65535 (default 44257)
;
; Generates a random maze using recursive backtracker (DFS).
; Produces long, winding passages with no directional bias.
;
; Grid storage: 1 byte per cell
;   bit 0 = south passage open
;   bit 1 = east passage open
; Grid stored at maze_grid (rows * cols bytes, max 40*40=1600)
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header
    JP   maze_main

    ; Header pad: 13 bytes reserved (offsets 3-15)
    DEFS 13, 0

MAZE_MAX_DIM    EQU 40
MAZE_DEF_ROWS   EQU 10
MAZE_DEF_COLS   EQU 20

; ============================================================
; maze_main - entry point (at 0x0810)
; ============================================================
maze_main:
    ; Set defaults
    LD   HL, 0xACE1              ; default PRNG seed
    LD   (maze_rng_state), HL
    LD   A, MAZE_DEF_ROWS
    LD   (maze_rows), A
    LD   A, MAZE_DEF_COLS
    LD   (maze_cols), A

    ; Parse optional arguments: MAZE [rows [cols [seed]]]
    LD   HL, (EXEC_ARGS_PTR)
    LD   A, (HL)
    OR   A
    JP   Z, maze_generate         ; no args, use defaults

    ; Parse first number (rows)
    CALL maze_parse_num
    JP   C, maze_err_usage        ; not a number
    LD   A, E
    OR   A
    JP   Z, maze_err_usage        ; zero
    CP   MAZE_MAX_DIM + 1
    JP   NC, maze_err_range       ; too large
    LD   (maze_rows), A

    ; Skip spaces
    CALL maze_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, maze_generate         ; only one arg

    ; Parse second number (cols)
    CALL maze_parse_num
    JP   C, maze_err_usage
    LD   A, E
    OR   A
    JP   Z, maze_err_usage
    CP   MAZE_MAX_DIM + 1
    JP   NC, maze_err_range
    LD   (maze_cols), A

    ; Skip spaces, check for optional seed
    CALL maze_skip_spaces
    LD   A, (HL)
    OR   A
    JP   Z, maze_generate         ; no seed arg

    ; Parse seed (16-bit: up to 65535)
    CALL maze_parse_seed
    JP   C, maze_err_usage
    LD   A, D
    OR   E
    JP   Z, maze_generate         ; zero seed, keep default
    LD   (maze_rng_state), DE

; ============================================================
; maze_generate - build the maze grid
; ============================================================
maze_generate:
    ; Zero the grid
    LD   HL, maze_grid
    LD   A, (maze_rows)
    LD   D, A
    LD   A, (maze_cols)
    LD   E, A
    LD   A, (maze_rows)
    LD   B, A
    LD   A, (maze_cols)
    LD   C, A
    ; B=rows, C=cols, total = B*C
    ; Multiply B * C into DE
    LD   D, 0
    LD   E, C                     ; DE = cols
    LD   A, B                     ; A = rows
    DEC  A                        ; multiply by (rows-1) more
    JP   Z, maze_zero_start       ; only 1 row, DE = cols already
maze_mul_loop:
    LD   H, 0
    LD   L, C
    ADD  HL, DE
    LD   D, H
    LD   E, L                     ; DE += cols
    DEC  A
    JP   NZ, maze_mul_loop
maze_zero_start:
    ; DE = total cells, zero them
    LD   HL, maze_grid
maze_zero_loop:
    LD   (HL), 0
    INC  HL
    DEC  DE
    LD   A, D
    OR   E
    JP   NZ, maze_zero_loop

    ; Recursive backtracker (DFS) maze generation
    ; Grid bit 7 = visited flag (ignored by display via AND masks)
    ; last_row = rows-1, last_col = cols-1
    LD   A, (maze_rows)
    DEC  A
    LD   (maze_last_row), A
    LD   A, (maze_cols)
    DEC  A
    LD   (maze_last_col), A

    ; Mark cell (0,0) as visited
    LD   HL, maze_grid
    LD   (HL), 0x80

    ; Initialize DFS stack, push (0,0)
    LD   HL, maze_stack
    LD   (HL), 0                    ; row = 0
    INC  HL
    LD   (HL), 0                    ; col = 0
    INC  HL
    LD   (maze_sp), HL

maze_dfs_loop:
    ; Check if stack is empty
    LD   HL, (maze_sp)
    LD   DE, maze_stack
    LD   A, H
    CP   D
    JP   NZ, maze_dfs_continue
    LD   A, L
    CP   E
    JP   Z, maze_dfs_done           ; stack empty, maze complete

maze_dfs_continue:
    ; Peek at top of stack: current = (sp[-2], sp[-1])
    LD   HL, (maze_sp)
    DEC  HL
    LD   A, (HL)                    ; col
    LD   (maze_cur_col), A
    DEC  HL
    LD   A, (HL)                    ; row
    LD   (maze_cur_row), A

    ; Find unvisited neighbors, store directions in maze_nbr_list
    LD   A, 0
    LD   (maze_nbr_count), A

    ; Check North (row-1, col)
    LD   A, (maze_cur_row)
    OR   A
    JP   Z, maze_dfs_chk_s          ; row == 0, skip
    DEC  A
    LD   D, A
    LD   A, (maze_cur_col)
    LD   E, A
    CALL maze_cell_ptr
    LD   A, (HL)
    AND  0x80
    JP   NZ, maze_dfs_chk_s         ; visited, skip
    LD   HL, maze_nbr_list
    LD   (HL), 0                    ; 0 = North
    LD   A, 1
    LD   (maze_nbr_count), A

maze_dfs_chk_s:
    ; Check South (row+1, col)
    LD   A, (maze_cur_row)
    LD   B, A
    LD   A, (maze_last_row)
    CP   B
    JP   Z, maze_dfs_chk_e          ; at last row, skip
    LD   A, B
    INC  A
    LD   D, A
    LD   A, (maze_cur_col)
    LD   E, A
    CALL maze_cell_ptr
    LD   A, (HL)
    AND  0x80
    JP   NZ, maze_dfs_chk_e
    LD   A, (maze_nbr_count)
    LD   C, A
    LD   B, 0
    LD   HL, maze_nbr_list
    ADD  HL, BC
    LD   (HL), 1                    ; 1 = South
    INC  C
    LD   A, C
    LD   (maze_nbr_count), A

maze_dfs_chk_e:
    ; Check East (row, col+1)
    LD   A, (maze_cur_col)
    LD   B, A
    LD   A, (maze_last_col)
    CP   B
    JP   Z, maze_dfs_chk_w          ; at last col, skip
    LD   A, (maze_cur_row)
    LD   D, A
    LD   A, B
    INC  A
    LD   E, A
    CALL maze_cell_ptr
    LD   A, (HL)
    AND  0x80
    JP   NZ, maze_dfs_chk_w
    LD   A, (maze_nbr_count)
    LD   C, A
    LD   B, 0
    LD   HL, maze_nbr_list
    ADD  HL, BC
    LD   (HL), 2                    ; 2 = East
    INC  C
    LD   A, C
    LD   (maze_nbr_count), A

maze_dfs_chk_w:
    ; Check West (row, col-1)
    LD   A, (maze_cur_col)
    OR   A
    JP   Z, maze_dfs_pick           ; col == 0, skip
    LD   A, (maze_cur_row)
    LD   D, A
    LD   A, (maze_cur_col)
    DEC  A
    LD   E, A
    CALL maze_cell_ptr
    LD   A, (HL)
    AND  0x80
    JP   NZ, maze_dfs_pick
    LD   A, (maze_nbr_count)
    LD   C, A
    LD   B, 0
    LD   HL, maze_nbr_list
    ADD  HL, BC
    LD   (HL), 3                    ; 3 = West
    INC  C
    LD   A, C
    LD   (maze_nbr_count), A

maze_dfs_pick:
    ; If no unvisited neighbors, backtrack
    LD   A, (maze_nbr_count)
    OR   A
    JP   Z, maze_dfs_backtrack

    ; Pick a random neighbor
    LD   D, A                       ; D = count
    CALL maze_random
    CALL maze_mod_d                 ; A = 0..count-1
    LD   C, A
    LD   B, 0
    LD   HL, maze_nbr_list
    ADD  HL, BC
    LD   A, (HL)                    ; A = direction

    ; Branch by direction
    CP   0
    JP   Z, maze_dfs_go_n
    CP   1
    JP   Z, maze_dfs_go_s
    CP   2
    JP   Z, maze_dfs_go_e
    JP   maze_dfs_go_w

maze_dfs_go_n:
    ; Carve south on neighbor (row-1,col) — that's the wall between them
    LD   A, (maze_cur_row)
    DEC  A
    LD   D, A
    LD   A, (maze_cur_col)
    LD   E, A
    CALL maze_cell_ptr
    LD   A, (HL)
    OR   1                          ; south bit
    LD   (HL), A
    JP   maze_dfs_push

maze_dfs_go_s:
    ; Carve south on current cell
    LD   A, (maze_cur_row)
    LD   D, A
    LD   A, (maze_cur_col)
    LD   E, A
    CALL maze_cell_ptr
    LD   A, (HL)
    OR   1
    LD   (HL), A
    ; Neighbor is (row+1, col)
    LD   A, (maze_cur_row)
    INC  A
    LD   D, A
    LD   A, (maze_cur_col)
    LD   E, A
    JP   maze_dfs_push

maze_dfs_go_e:
    ; Carve east on current cell
    LD   A, (maze_cur_row)
    LD   D, A
    LD   A, (maze_cur_col)
    LD   E, A
    CALL maze_cell_ptr
    LD   A, (HL)
    OR   2
    LD   (HL), A
    ; Neighbor is (row, col+1)
    LD   A, (maze_cur_row)
    LD   D, A
    LD   A, (maze_cur_col)
    INC  A
    LD   E, A
    JP   maze_dfs_push

maze_dfs_go_w:
    ; Carve east on neighbor (row, col-1) — that's the wall between them
    LD   A, (maze_cur_row)
    LD   D, A
    LD   A, (maze_cur_col)
    DEC  A
    LD   E, A
    CALL maze_cell_ptr
    LD   A, (HL)
    OR   2
    LD   (HL), A
    JP   maze_dfs_push

maze_dfs_push:
    ; D = neighbor row, E = neighbor col
    ; Mark neighbor as visited
    CALL maze_cell_ptr
    LD   A, (HL)
    OR   0x80
    LD   (HL), A
    ; Push neighbor onto stack
    LD   HL, (maze_sp)
    LD   (HL), D
    INC  HL
    LD   (HL), E
    INC  HL
    LD   (maze_sp), HL
    JP   maze_dfs_loop

maze_dfs_backtrack:
    ; Pop from stack
    LD   HL, (maze_sp)
    DEC  HL
    DEC  HL
    LD   (maze_sp), HL
    JP   maze_dfs_loop

maze_dfs_done:

; ============================================================
; maze_display - print the maze
; ============================================================
maze_display:
    ; Print top border: +--+--+--+...
    ; First cell has opening (entrance)
    LD   DE, maze_str_entrance
    CALL maze_puts
    LD   A, (maze_cols)
    DEC  A                        ; remaining cols
    LD   B, A
    OR   A
    JP   Z, maze_top_done
maze_top_loop:
    LD   DE, maze_str_wall_top
    CALL maze_puts
    DEC  B
    JP   NZ, maze_top_loop
maze_top_done:
    LD   A, '+'
    CALL maze_putchar
    CALL maze_newline

    ; For each row:
    ;   Row body: |  |  |...  (| where east wall, space where east passage)
    ;   Row bottom: +--+  +--+... (-- where south wall, spaces where south passage)
    LD   A, 0
    LD   (maze_cur_row), A

maze_disp_row:
    ; Print row body
    ; Left wall
    LD   A, '|'
    CALL maze_putchar

    LD   A, 0
    LD   (maze_cur_col), A
maze_disp_body_col:
    ; Cell interior (2 spaces)
    LD   A, ' '
    CALL maze_putchar
    LD   A, ' '
    CALL maze_putchar

    ; East wall or passage
    CALL maze_get_cell_ptr
    LD   A, (HL)
    AND  2                          ; east bit
    JP   NZ, maze_disp_east_open
    LD   A, '|'
    JP   maze_disp_east_done
maze_disp_east_open:
    LD   A, ' '
maze_disp_east_done:
    CALL maze_putchar

    LD   A, (maze_cur_col)
    INC  A
    LD   (maze_cur_col), A
    LD   B, A
    LD   A, (maze_cols)
    CP   B
    JP   NZ, maze_disp_body_col

    CALL maze_newline

    ; Print row bottom border
    LD   A, 0
    LD   (maze_cur_col), A

    ; Check if this is the last row
    LD   A, (maze_cur_row)
    LD   B, A
    LD   A, (maze_last_row)
    CP   B
    JP   Z, maze_disp_last_bottom

maze_disp_bottom_col:
    LD   A, '+'
    CALL maze_putchar

    CALL maze_get_cell_ptr
    LD   A, (HL)
    AND  1                          ; south bit
    JP   NZ, maze_disp_south_open
    LD   A, '-'
    CALL maze_putchar
    LD   A, '-'
    JP   maze_disp_south_done
maze_disp_south_open:
    LD   A, ' '
    CALL maze_putchar
    LD   A, ' '
maze_disp_south_done:
    CALL maze_putchar

    LD   A, (maze_cur_col)
    INC  A
    LD   (maze_cur_col), A
    LD   B, A
    LD   A, (maze_cols)
    CP   B
    JP   NZ, maze_disp_bottom_col

    ; Final + on the right
    LD   A, '+'
    CALL maze_putchar
    CALL maze_newline

    ; Next row
    LD   A, (maze_cur_row)
    INC  A
    LD   (maze_cur_row), A
    LD   B, A
    LD   A, (maze_rows)
    CP   B
    JP   NZ, maze_disp_row

    JP   maze_done

maze_disp_last_bottom:
    ; Last row bottom: all walls except last cell has exit
    LD   A, (maze_cols)
    DEC  A
    LD   B, A                       ; B = cols - 1
    OR   A
    JP   Z, maze_last_exit          ; only 1 column
maze_last_bottom_loop:
    LD   DE, maze_str_wall_top
    CALL maze_puts
    DEC  B
    JP   NZ, maze_last_bottom_loop
maze_last_exit:
    ; Exit opening at last cell
    LD   DE, maze_str_exit
    CALL maze_puts
    CALL maze_newline

maze_done:
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Error handlers
; ============================================================
maze_err_usage:
    LD   DE, maze_msg_usage
    JP   maze_err_print
maze_err_range:
    LD   DE, maze_msg_range
maze_err_print:
    CALL maze_puts
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; maze_get_cell_ptr
; Returns HL = pointer to grid[cur_row][cur_col]
; Wrapper around maze_cell_ptr using cur_row/cur_col.
; Destroys: A, BC
; Preserves: DE
; ============================================================
maze_get_cell_ptr:
    LD   A, (maze_cur_row)
    LD   D, A
    LD   A, (maze_cur_col)
    LD   E, A
    ; fall through

; ============================================================
; maze_cell_ptr
; Returns HL = pointer to grid[D][E]
; Inputs: D = row, E = col
; Outputs: HL = &maze_grid[row * cols + col]
; Destroys: A, BC
; Preserves: DE
; ============================================================
maze_cell_ptr:
    PUSH DE
    LD   A, (maze_cols)
    LD   C, A
    LD   HL, 0
    LD   A, D
    OR   A
    JP   Z, maze_cp_add_col
maze_cp_mul:
    LD   B, 0
    ADD  HL, BC                     ; HL += cols
    DEC  A
    JP   NZ, maze_cp_mul
maze_cp_add_col:
    LD   D, 0
    ADD  HL, DE                     ; HL += col
    LD   DE, maze_grid
    ADD  HL, DE
    POP  DE
    RET

; ============================================================
; maze_random
; Returns a pseudo-random byte in A.
; 16-bit Galois LFSR with taps at bits 16, 14, 13, 11
; (polynomial 0xB400).
; ============================================================
maze_random:
    PUSH HL
    PUSH DE
    LD   HL, (maze_rng_state)
    ; Shift right by 1
    LD   A, H
    OR   A                          ; clear carry
    RRA
    LD   D, A                       ; D = new H
    LD   A, L
    RRA
    LD   E, A                       ; E = new L
    ; If carry (old bit 0 was 1), XOR with 0xB400
    JP   NC, maze_rng_no_xor
    LD   A, D
    XOR  0xB4
    LD   D, A
    LD   A, E
    XOR  0x00
    LD   E, A
maze_rng_no_xor:
    LD   H, D
    LD   L, E
    LD   (maze_rng_state), HL
    LD   A, L                       ; return low byte as random value
    POP  DE
    POP  HL
    RET

; ============================================================
; maze_mod_d
; Unsigned modulo: A = A % D
; Inputs:  A = dividend, D = divisor (must be > 0)
; Outputs: A = remainder
; ============================================================
maze_mod_d:
    CP   D
    RET  C                          ; A < D, done
    SUB  D
    JP   maze_mod_d

; ============================================================
; maze_parse_num
; Parse a decimal number from string at HL.
; Advances HL past the digits.
; Outputs: E = value (0-255), carry set on error
; Destroys: A, D
; ============================================================
maze_parse_num:
    LD   E, 0                       ; accumulator
    LD   A, (HL)
    CP   '0'
    JP   C, maze_parse_err
    CP   '9' + 1
    JP   NC, maze_parse_err
maze_parse_loop:
    LD   A, (HL)
    CP   '0'
    JP   C, maze_parse_done
    CP   '9' + 1
    JP   NC, maze_parse_done
    ; E = E * 10 + digit
    SUB  '0'
    LD   D, A                       ; D = digit
    LD   A, E
    ADD  A, A                       ; A = E*2
    JP   C, maze_parse_err          ; overflow
    ADD  A, A                       ; A = E*4
    JP   C, maze_parse_err
    ADD  A, E                       ; A = E*5
    JP   C, maze_parse_err
    ADD  A, A                       ; A = E*10
    JP   C, maze_parse_err
    ADD  A, D                       ; A = E*10 + digit
    JP   C, maze_parse_err
    LD   E, A
    INC  HL
    JP   maze_parse_loop
maze_parse_done:
    OR   A                          ; clear carry
    RET
maze_parse_err:
    SCF                             ; set carry = error
    RET

; ============================================================
; maze_parse_seed
; Parse a 16-bit decimal number from string at HL.
; Advances HL past the digits.
; Outputs: DE = value (0-65535), carry set on error
; Destroys: A, B
; ============================================================
maze_parse_seed:
    LD   D, 0
    LD   E, 0                       ; DE = accumulator
    LD   A, (HL)
    CP   '0'
    JP   C, maze_parse_err
    CP   '9' + 1
    JP   NC, maze_parse_err
maze_parse_seed_loop:
    LD   A, (HL)
    CP   '0'
    JP   C, maze_parse_seed_done
    CP   '9' + 1
    JP   NC, maze_parse_seed_done
    SUB  '0'
    LD   B, A                       ; B = digit
    ; DE = DE * 10 + B
    ; DE * 10 = DE * 2 + DE * 8 = (DE << 1) + (DE << 3)
    PUSH HL
    LD   H, D
    LD   L, E                       ; HL = DE (original value)
    ADD  HL, HL                     ; HL = val * 2
    JP   C, maze_parse_seed_ovfl
    ADD  HL, HL                     ; HL = val * 4
    JP   C, maze_parse_seed_ovfl
    ADD  HL, DE                     ; HL = val * 5
    JP   C, maze_parse_seed_ovfl
    ADD  HL, HL                     ; HL = val * 10
    JP   C, maze_parse_seed_ovfl
    LD   D, 0
    LD   E, B                       ; DE = digit
    ADD  HL, DE                     ; HL = val * 10 + digit
    JP   C, maze_parse_seed_ovfl
    LD   D, H
    LD   E, L                       ; DE = result
    POP  HL
    INC  HL
    JP   maze_parse_seed_loop
maze_parse_seed_ovfl:
    POP  HL
    SCF
    RET
maze_parse_seed_done:
    OR   A                          ; clear carry
    RET

; ============================================================
; maze_skip_spaces
; Advance HL past any space characters.
; ============================================================
maze_skip_spaces:
    LD   A, (HL)
    CP   ' '
    RET  NZ
    INC  HL
    JP   maze_skip_spaces

; ============================================================
; maze_putchar
; Print character in A to console.
; Preserves HL, BC.
; ============================================================
maze_putchar:
    PUSH HL
    PUSH BC
    LD   E, A
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  BC
    POP  HL
    RET

; ============================================================
; maze_puts
; Print null-terminated string at DE to console.
; Preserves HL.
; ============================================================
maze_puts:
    PUSH HL
    PUSH BC
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  BC
    POP  HL
    RET

; ============================================================
; maze_newline
; Print CR+LF to console.
; ============================================================
maze_newline:
    LD   A, 0x0D
    CALL maze_putchar
    LD   A, 0x0A
    CALL maze_putchar
    RET

; ============================================================
; Data
; ============================================================
maze_rows:
    DEFB MAZE_DEF_ROWS
maze_cols:
    DEFB MAZE_DEF_COLS
maze_cur_row:
    DEFB 0
maze_cur_col:
    DEFB 0
maze_last_row:
    DEFB 0
maze_last_col:
    DEFB 0
maze_nbr_count:
    DEFB 0
maze_nbr_list:
    DEFS 4, 0                       ; up to 4 directions (N=0,S=1,E=2,W=3)
maze_sp:
    DEFW 0                          ; DFS stack pointer
maze_rng_state:
    DEFW 0xACE1

; Strings
maze_str_entrance:
    DEFM "+  ", 0
maze_str_wall_top:
    DEFM "+--", 0
maze_str_exit:
    DEFM "+  +", 0
maze_msg_usage:
    DEFM "Usage: MAZE [rows] [cols] [seed]", 0x0D, 0x0A, 0
maze_msg_range:
    DEFM "Error: max 40 rows/cols", 0x0D, 0x0A, 0

; Grid: max 40*40 = 1600 bytes
maze_grid:
    DEFS 1600, 0

; DFS stack: max 1600 entries * 2 bytes (row, col) = 3200 bytes
maze_stack:
    DEFS 3200, 0

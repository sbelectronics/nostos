; ============================================================
; chess.asm - Chess game for NostOS
; ============================================================
; A complete chess game with AI opponent.
; Human plays White, computer plays Black.
;
; Input format: "E2E4" (from-square to-square)
; Commands: Q = quit, H = help, B = show board
;
; Simplifications:
;   - No castling or en passant
;   - Pawns auto-promote to queen
;   - AI uses 1-ply material search
; ============================================================

    INCLUDE "../../src/include/constants.asm"
    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point - jump over the header
    JP   chess_main

    ; Header pad: 13 bytes reserved (offsets 3-15)
    DEFS 13, 0

; ============================================================
; Constants
; ============================================================

; Piece types (low nibble)
CH_EMPTY    EQU 0
CH_PAWN     EQU 1
CH_KNIGHT   EQU 2
CH_BISHOP   EQU 3
CH_ROOK     EQU 4
CH_QUEEN    EQU 5
CH_KING     EQU 6

; Color flags (high nibble)
CH_WHITE    EQU 0x10
CH_BLACK    EQU 0x20
CH_COLOR    EQU 0x30     ; mask for color bits
CH_TYPE     EQU 0x0F     ; mask for type bits

; Piece values for AI evaluation (kept small so score*4+bonus fits in 8 bits)
VAL_PAWN    EQU 1
VAL_KNIGHT  EQU 3
VAL_BISHOP  EQU 3
VAL_ROOK    EQU 5
VAL_QUEEN   EQU 9
VAL_KING    EQU 0        ; king can't be captured

; Board size
BOARD_SIZE  EQU 64

; ============================================================
; chess_main - entry point
; ============================================================
chess_main:
    ; Print welcome
    LD   DE, ch_msg_welcome
    CALL ch_puts

    ; Initialize board
    CALL ch_init_board

    ; Show initial board
    CALL ch_show_board

    ; Main game loop
ch_game_loop:
    ; Check if game is over (no king on board)
    CALL ch_check_kings
    OR   A
    JP   NZ, ch_game_over

    ; White's turn (human)
    LD   DE, ch_msg_prompt
    CALL ch_puts

    ; Read input
    CALL ch_getline

    ; Check for single-char commands (only if 2nd char is null/non-digit)
    LD   A, (ch_inbuf + 1)
    CP   '1'
    JP   NC, ch_try_move     ; 2nd char is digit = likely a move
    LD   A, (ch_inbuf)
    CP   'Q'
    JP   Z, ch_quit
    CP   'H'
    JP   Z, ch_help
    CP   'B'
    JP   Z, ch_show_and_loop
ch_try_move:

    ; Parse move (e.g. "E2E4")
    CALL ch_parse_move
    OR   A
    JP   NZ, ch_bad_move

    ; Validate move
    CALL ch_validate_move
    OR   A
    JP   NZ, ch_illegal_move

    ; Make the move
    CALL ch_make_move

    ; Check if move left own king in check
    LD   A, CH_WHITE
    CALL ch_in_check
    OR   A
    JP   NZ, ch_undo_in_check

    ; Show board after white's move
    CALL ch_show_board

    ; Check if game is over after white's move
    CALL ch_check_kings
    OR   A
    JP   NZ, ch_game_over

    ; Black's turn (AI)
    LD   DE, ch_msg_thinking
    CALL ch_puts

    CALL ch_ai_move
    OR   A
    JP   NZ, ch_ai_no_move

    ; Show AI's move
    CALL ch_show_ai_move
    CALL ch_show_board

    JP   ch_game_loop

ch_show_and_loop:
    CALL ch_show_board
    JP   ch_game_loop

ch_bad_move:
    LD   DE, ch_msg_badmove
    CALL ch_puts
    JP   ch_game_loop

ch_illegal_move:
    LD   DE, ch_msg_illegal
    CALL ch_puts
    JP   ch_game_loop

ch_undo_in_check:
    ; Undo the move
    CALL ch_undo_move
    LD   DE, ch_msg_incheck
    CALL ch_puts
    JP   ch_game_loop

ch_ai_no_move:
    ; AI can't move - checkmate or stalemate
    LD   DE, ch_msg_youwin
    CALL ch_puts
    JP   ch_exit

ch_game_over:
    ; A=1 means white king missing, A=2 means black king missing
    CP   1
    JP   Z, ch_go_black_wins
    LD   DE, ch_msg_youwin
    CALL ch_puts
    JP   ch_exit
ch_go_black_wins:
    LD   DE, ch_msg_youlose
    CALL ch_puts
    JP   ch_exit

ch_help:
    LD   DE, ch_msg_help
    CALL ch_puts
    JP   ch_game_loop

ch_quit:
    LD   DE, ch_msg_bye
    CALL ch_puts

ch_exit:
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; ch_init_board - Set up starting position
; ============================================================
ch_init_board:
    PUSH HL
    PUSH BC
    PUSH DE

    ; Clear the board
    LD   HL, ch_board
    LD   B, BOARD_SIZE
ch_ib_clear:
    LD   (HL), CH_EMPTY
    INC  HL
    DEC  B
    JP   NZ, ch_ib_clear

    ; Set up black pieces (rank 8 = indices 0-7)
    LD   HL, ch_board
    LD   (HL), CH_BLACK | CH_ROOK     ; A8
    INC  HL
    LD   (HL), CH_BLACK | CH_KNIGHT   ; B8
    INC  HL
    LD   (HL), CH_BLACK | CH_BISHOP   ; C8
    INC  HL
    LD   (HL), CH_BLACK | CH_QUEEN    ; D8
    INC  HL
    LD   (HL), CH_BLACK | CH_KING     ; E8
    INC  HL
    LD   (HL), CH_BLACK | CH_BISHOP   ; F8
    INC  HL
    LD   (HL), CH_BLACK | CH_KNIGHT   ; G8
    INC  HL
    LD   (HL), CH_BLACK | CH_ROOK     ; H8

    ; Black pawns (rank 7 = indices 8-15)
    LD   HL, ch_board + 8
    LD   B, 8
ch_ib_bpawns:
    LD   (HL), CH_BLACK | CH_PAWN
    INC  HL
    DEC  B
    JP   NZ, ch_ib_bpawns

    ; White pawns (rank 2 = indices 48-55)
    LD   HL, ch_board + 48
    LD   B, 8
ch_ib_wpawns:
    LD   (HL), CH_WHITE | CH_PAWN
    INC  HL
    DEC  B
    JP   NZ, ch_ib_wpawns

    ; White pieces (rank 1 = indices 56-63)
    LD   HL, ch_board + 56
    LD   (HL), CH_WHITE | CH_ROOK     ; A1
    INC  HL
    LD   (HL), CH_WHITE | CH_KNIGHT   ; B1
    INC  HL
    LD   (HL), CH_WHITE | CH_BISHOP   ; C1
    INC  HL
    LD   (HL), CH_WHITE | CH_QUEEN    ; D1
    INC  HL
    LD   (HL), CH_WHITE | CH_KING     ; E1
    INC  HL
    LD   (HL), CH_WHITE | CH_BISHOP   ; F1
    INC  HL
    LD   (HL), CH_WHITE | CH_KNIGHT   ; G1
    INC  HL
    LD   (HL), CH_WHITE | CH_ROOK     ; H1

    ; Initialize undo buffer
    LD   A, 0
    LD   (ch_undo_from), A
    LD   (ch_undo_to), A
    LD   (ch_undo_captured), A

    POP  DE
    POP  BC
    POP  HL
    RET

; ============================================================
; ch_show_board - Display the board
; Board layout: index 0 = A8 (top-left), index 63 = H1 (bottom-right)
; Rank 8 = row 0 (indices 0-7), Rank 1 = row 7 (indices 56-63)
; ============================================================
ch_show_board:
    PUSH HL
    PUSH BC
    PUSH DE

    LD   DE, ch_msg_crlf
    CALL ch_puts

    ; Print column header
    LD   DE, ch_msg_colhdr
    CALL ch_puts

    ; Print separator
    LD   DE, ch_msg_sep
    CALL ch_puts

    ; Print rows 8 down to 1
    LD   HL, ch_board        ; start at index 0 (rank 8)
    LD   C, '8'              ; rank number
ch_sb_row:
    ; Print rank number and bar
    LD   E, C
    CALL ch_putchar
    LD   E, '|'
    CALL ch_putchar

    ; Print 8 squares
    LD   B, 8
ch_sb_col:
    LD   A, (HL)
    CALL ch_piece_char       ; A -> character for this piece
    LD   E, A
    CALL ch_putchar
    LD   E, '|'
    CALL ch_putchar
    INC  HL
    DEC  B
    JP   NZ, ch_sb_col

    ; Print newline
    LD   E, 0x0D
    CALL ch_putchar
    LD   E, 0x0A
    CALL ch_putchar

    ; Print separator
    PUSH HL
    LD   DE, ch_msg_sep
    CALL ch_puts
    POP  HL

    ; Next rank
    DEC  C
    LD   A, C
    CP   '0'
    JP   NZ, ch_sb_row

    ; Print column footer
    LD   DE, ch_msg_colhdr
    CALL ch_puts
    LD   DE, ch_msg_crlf
    CALL ch_puts

    POP  DE
    POP  BC
    POP  HL
    RET

; ============================================================
; ch_piece_char - Convert piece byte to display character
; Input: A = piece byte
; Output: A = ASCII character
; White pieces: PNBRQK, Black pieces: pnbrqk, Empty: .
; ============================================================
ch_piece_char:
    PUSH HL
    OR   A
    JP   Z, ch_pc_empty

    PUSH AF
    AND  CH_TYPE
    LD   HL, ch_piece_letters
    ; Add offset (type-1) since type starts at 1
    DEC  A
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)             ; get uppercase letter

    ; Check color - if black, convert to lowercase
    LD   L, A                ; save letter
    POP  AF                  ; get original piece
    AND  CH_COLOR
    CP   CH_BLACK
    LD   A, L                ; restore letter
    JP   NZ, ch_pc_done
    ADD  A, 0x20             ; convert to lowercase for black
ch_pc_done:
    POP  HL
    RET
ch_pc_empty:
    LD   A, '.'
    POP  HL
    RET

ch_piece_letters:
    DEFM "PNBRQK"

; ============================================================
; ch_parse_move - Parse move string from ch_inbuf
; Format: "E2E4" (file A-H, rank 1-8, file A-H, rank 1-8)
; Output: ch_move_from, ch_move_to = board indices (0-63)
;         A = 0 on success, 1 on parse error
; ============================================================
ch_parse_move:
    PUSH HL
    PUSH BC

    LD   HL, ch_inbuf

    ; Parse source file (A-H)
    LD   A, (HL)
    CP   'A'
    JP   C, ch_pm_err
    CP   'I'
    JP   NC, ch_pm_err
    SUB  'A'
    LD   B, A                ; B = source file (0-7)
    INC  HL

    ; Parse source rank (1-8)
    LD   A, (HL)
    CP   '1'
    JP   C, ch_pm_err
    CP   '9'
    JP   NC, ch_pm_err
    SUB  '1'                 ; A = 0-7 (rank 1=0, rank 8=7)
    ; Convert: index = (7-rank)*8 + file
    ; rank 1 -> row 7, rank 8 -> row 0
    LD   C, A                ; C = rank-1 (0-7)
    LD   A, 7
    SUB  C                   ; A = 7 - (rank-1)
    ; Multiply by 8: shift left 3
    ADD  A, A
    ADD  A, A
    ADD  A, A
    ADD  A, B                ; add file
    LD   (ch_move_from), A
    INC  HL

    ; Parse destination file
    LD   A, (HL)
    CP   'A'
    JP   C, ch_pm_err
    CP   'I'
    JP   NC, ch_pm_err
    SUB  'A'
    LD   B, A                ; B = dest file
    INC  HL

    ; Parse destination rank
    LD   A, (HL)
    CP   '1'
    JP   C, ch_pm_err
    CP   '9'
    JP   NC, ch_pm_err
    SUB  '1'
    LD   C, A
    LD   A, 7
    SUB  C
    ADD  A, A
    ADD  A, A
    ADD  A, A
    ADD  A, B
    LD   (ch_move_to), A

    XOR  A                   ; success
    POP  BC
    POP  HL
    RET

ch_pm_err:
    LD   A, 1
    POP  BC
    POP  HL
    RET

; ============================================================
; ch_validate_move - Check if the move is legal
; Uses ch_move_from, ch_move_to
; Returns A=0 if valid, A=1 if invalid
; ============================================================
ch_validate_move:
    PUSH HL
    PUSH BC
    PUSH DE

    ; Get source piece
    LD   A, (ch_move_from)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)

    ; Source must be a white piece
    OR   A
    JP   Z, ch_vm_fail       ; empty square
    LD   B, A                ; B = source piece (saved)
    AND  CH_COLOR
    CP   CH_WHITE
    JP   NZ, ch_vm_fail      ; not white

    ; Get destination piece
    LD   A, (ch_move_to)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)
    LD   (ch_temp_dest), A   ; save dest piece

    ; Can't capture own piece
    OR   A
    JP   Z, ch_vm_dest_ok    ; empty is fine
    AND  CH_COLOR
    CP   CH_WHITE
    JP   Z, ch_vm_fail       ; can't capture own piece

ch_vm_dest_ok:
    LD   A, B                ; restore source piece
    AND  CH_TYPE             ; get piece type
    ; Dispatch based on piece type
    CP   CH_PAWN
    JP   Z, ch_vm_pawn
    CP   CH_KNIGHT
    JP   Z, ch_vm_knight
    CP   CH_BISHOP
    JP   Z, ch_vm_bishop
    CP   CH_ROOK
    JP   Z, ch_vm_rook
    CP   CH_QUEEN
    JP   Z, ch_vm_queen
    CP   CH_KING
    JP   Z, ch_vm_king
    JP   ch_vm_fail          ; unknown piece

ch_vm_fail:
    LD   A, 1
    POP  DE
    POP  BC
    POP  HL
    RET

ch_vm_ok:
    XOR  A
    POP  DE
    POP  BC
    POP  HL
    RET

; --- Pawn validation (white moves up = decreasing index) ---
ch_vm_pawn:
    LD   A, (ch_move_from)
    LD   B, A                ; B = from
    LD   A, (ch_move_to)
    LD   C, A                ; C = to

    ; Get from-file and from-rank
    LD   A, B
    AND  0x07               ; from file
    LD   D, A               ; D = from file
    LD   A, B
    AND  0x38               ; from row*8
    RRA
    RRA
    RRA                     ; A = from row (0=rank8, 7=rank1)
    LD   E, A               ; E = from row

    ; Get to-file and to-rank
    LD   A, C
    AND  0x07
    LD   H, A               ; H = to file (reusing H temporarily)
    LD   A, C
    AND  0x38
    RRA
    RRA
    RRA
    LD   L, A               ; L = to row

    ; White pawn: must move to lower row (toward rank 8)
    ; Forward one square: to_row = from_row - 1, same file
    LD   A, E
    DEC  A                  ; from_row - 1
    CP   L                  ; compare with to_row
    JP   NZ, ch_vm_pawn_dbl

    ; Single forward - must be same file and dest empty
    LD   A, D
    CP   H
    JP   NZ, ch_vm_pawn_cap

    ; Check dest is empty
    LD   A, (ch_temp_dest)
    OR   A
    JP   NZ, ch_vm_fail     ; can't move forward onto a piece

    JP   ch_vm_ok

ch_vm_pawn_dbl:
    ; Double move: only from row 6 (rank 2), to row 4
    LD   A, E
    CP   6                  ; from rank 2 (row 6)?
    JP   NZ, ch_vm_pawn_cap
    LD   A, L
    CP   4                  ; to row 4?
    JP   NZ, ch_vm_pawn_cap

    ; Same file
    LD   A, D
    CP   H
    JP   NZ, ch_vm_fail

    ; Dest must be empty
    LD   A, (ch_temp_dest)
    OR   A
    JP   NZ, ch_vm_fail

    ; Square in between must be empty (row 5, same file)
    LD   A, 5
    ADD  A, A
    ADD  A, A
    ADD  A, A               ; A = 5*8 = 40
    ADD  A, D               ; add file
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)
    OR   A
    JP   NZ, ch_vm_fail

    JP   ch_vm_ok

ch_vm_pawn_cap:
    ; Diagonal capture: to_row = from_row - 1, to_file = from_file +/- 1
    LD   A, E
    DEC  A
    CP   L                  ; to_row must be from_row - 1
    JP   NZ, ch_vm_fail

    ; File difference must be 1
    LD   A, D
    SUB  H
    JP   Z, ch_vm_fail      ; same file, not diagonal
    ; Check |diff| == 1
    CP   1
    JP   Z, ch_vm_pawn_cap2
    CP   0xFF               ; -1
    JP   Z, ch_vm_pawn_cap2
    JP   ch_vm_fail

ch_vm_pawn_cap2:
    ; Must be capturing an enemy piece
    LD   A, (ch_temp_dest)
    OR   A
    JP   Z, ch_vm_fail      ; can't capture empty
    AND  CH_COLOR
    CP   CH_BLACK
    JP   NZ, ch_vm_fail     ; must capture black

    JP   ch_vm_ok

; --- Knight validation ---
ch_vm_knight:
    ; Knight moves in L-shape: (dr,df) must be one of 8 patterns
    LD   A, (ch_move_from)
    LD   B, A
    LD   A, (ch_move_to)
    LD   C, A

    ; Get row and file for from and to
    LD   A, B
    AND  0x38
    RRA
    RRA
    RRA
    LD   D, A               ; D = from row
    LD   A, B
    AND  0x07
    LD   E, A               ; E = from file

    LD   A, C
    AND  0x38
    RRA
    RRA
    RRA
    LD   H, A               ; H = to row
    LD   A, C
    AND  0x07
    LD   L, A               ; L = to file

    ; Calculate |dr| and |df|
    LD   A, D
    SUB  H                  ; dr = from_row - to_row
    JP   NC, ch_vm_kn_dr_pos
    CPL                     ; negate A (8080 compatible)
    INC  A
ch_vm_kn_dr_pos:
    LD   B, A               ; B = |dr|

    LD   A, E
    SUB  L                  ; df = from_file - to_file
    JP   NC, ch_vm_kn_df_pos
    CPL
    INC  A
ch_vm_kn_df_pos:
    LD   C, A               ; C = |df|

    ; Valid knight: (|dr|=1 and |df|=2) or (|dr|=2 and |df|=1)
    LD   A, B
    CP   1
    JP   NZ, ch_vm_kn_try2
    LD   A, C
    CP   2
    JP   Z, ch_vm_ok
    JP   ch_vm_fail

ch_vm_kn_try2:
    LD   A, B
    CP   2
    JP   NZ, ch_vm_fail
    LD   A, C
    CP   1
    JP   Z, ch_vm_ok
    JP   ch_vm_fail

; --- Bishop validation ---
ch_vm_bishop:
    CALL ch_is_diagonal
    OR   A
    JP   NZ, ch_vm_fail
    ; Check path is clear
    CALL ch_path_clear
    OR   A
    JP   NZ, ch_vm_fail
    JP   ch_vm_ok

; --- Rook validation ---
ch_vm_rook:
    CALL ch_is_straight
    OR   A
    JP   NZ, ch_vm_fail
    CALL ch_path_clear
    OR   A
    JP   NZ, ch_vm_fail
    JP   ch_vm_ok

; --- Queen validation ---
ch_vm_queen:
    CALL ch_is_diagonal
    OR   A
    JP   Z, ch_vm_queen_ok
    CALL ch_is_straight
    OR   A
    JP   NZ, ch_vm_fail
ch_vm_queen_ok:
    CALL ch_path_clear
    OR   A
    JP   NZ, ch_vm_fail
    JP   ch_vm_ok

; --- King validation ---
ch_vm_king:
    LD   A, (ch_move_from)
    LD   B, A
    LD   A, (ch_move_to)
    LD   C, A

    ; Get rows and files
    LD   A, B
    AND  0x38
    RRA
    RRA
    RRA
    LD   D, A               ; from row

    LD   A, B
    AND  0x07
    LD   E, A               ; from file

    LD   A, C
    AND  0x38
    RRA
    RRA
    RRA
    LD   H, A               ; to row

    LD   A, C
    AND  0x07
    LD   L, A               ; to file

    ; |dr| <= 1 and |df| <= 1
    LD   A, D
    SUB  H
    JP   NC, ch_vm_ki_dr
    CPL
    INC  A
ch_vm_ki_dr:
    CP   2
    JP   NC, ch_vm_fail
    LD   A, E
    SUB  L
    JP   NC, ch_vm_ki_df
    CPL
    INC  A
ch_vm_ki_df:
    CP   2
    JP   NC, ch_vm_fail
    JP   ch_vm_ok

; ============================================================
; ch_is_diagonal - Check if move is along a diagonal
; Returns A=0 if diagonal, A=1 if not
; ============================================================
ch_is_diagonal:
    PUSH BC
    PUSH DE
    LD   A, (ch_move_from)
    LD   B, A
    LD   A, (ch_move_to)
    LD   C, A

    ; Get rows and files
    LD   A, B
    AND  0x38
    RRA
    RRA
    RRA
    LD   D, A               ; from row
    LD   A, B
    AND  0x07
    LD   E, A               ; from file

    LD   A, C
    AND  0x38
    RRA
    RRA
    RRA
    ; to row in A
    SUB  D                  ; dr
    JP   NC, ch_id_dr
    CPL
    INC  A
ch_id_dr:
    LD   D, A               ; D = |dr|

    LD   A, C
    AND  0x07
    SUB  E                  ; df
    JP   NC, ch_id_df
    CPL
    INC  A
ch_id_df:
    ; |dr| must equal |df| and both nonzero
    CP   D
    JP   NZ, ch_id_no
    OR   A
    JP   Z, ch_id_no        ; can't be zero (same square)
    XOR  A
    POP  DE
    POP  BC
    RET
ch_id_no:
    LD   A, 1
    POP  DE
    POP  BC
    RET

; ============================================================
; ch_is_straight - Check if move is along a rank or file
; Returns A=0 if straight, A=1 if not
; ============================================================
ch_is_straight:
    PUSH BC
    LD   A, (ch_move_from)
    LD   B, A
    LD   A, (ch_move_to)
    LD   C, A

    ; Same row? (same upper 3 bits when masked with 0x38)
    LD   A, B
    AND  0x38
    LD   D, A
    LD   A, C
    AND  0x38
    CP   D
    JP   Z, ch_is_chknotsame

    ; Same file? (same lower 3 bits)
    LD   A, B
    AND  0x07
    LD   D, A
    LD   A, C
    AND  0x07
    CP   D
    JP   Z, ch_is_chknotsame

    LD   A, 1
    POP  BC
    RET

ch_is_chknotsame:
    ; Make sure from != to
    LD   A, B
    CP   C
    JP   Z, ch_is_straight_no
    XOR  A
    POP  BC
    RET
ch_is_straight_no:
    LD   A, 1
    POP  BC
    RET

; ============================================================
; ch_path_clear - Check that all squares between from and to are empty
; Uses ch_move_from, ch_move_to
; Returns A=0 if clear, A=1 if blocked
; ============================================================
ch_path_clear:
    PUSH HL
    PUSH BC
    PUSH DE

    LD   A, (ch_move_from)
    LD   B, A               ; B = current position
    LD   A, (ch_move_to)
    LD   C, A               ; C = target

    ; Calculate step direction
    ; Row step: compare rows
    LD   A, B
    AND  0x38
    LD   D, A
    LD   A, C
    AND  0x38
    CP   D
    JP   Z, ch_pc_rowzero
    JP   C, ch_pc_rowup
    ; Row increases (to > from in row bits)
    LD   D, 8               ; step +8 for rows
    JP   ch_pc_filestep
ch_pc_rowup:
    LD   D, -8              ; step -8
    JP   ch_pc_filestep
ch_pc_rowzero:
    LD   D, 0

ch_pc_filestep:
    LD   A, B
    AND  0x07
    LD   E, A
    LD   A, C
    AND  0x07
    CP   E
    JP   Z, ch_pc_filezero
    JP   C, ch_pc_filedec
    ; File increases
    LD   A, D
    ADD  A, 1
    LD   D, A               ; add +1 for file
    JP   ch_pc_walk
ch_pc_filedec:
    LD   A, D
    SUB  1
    LD   D, A               ; add -1 for file
    JP   ch_pc_walk
ch_pc_filezero:
    ; D already has just the row step

ch_pc_walk:
    ; D = step to add each time
    ; Start from B + step, check each until we reach C
    ; E = current index (tracked explicitly to avoid page-crossing bug)
    LD   A, B
    ADD  A, D               ; first intermediate square
    LD   E, A               ; E = current index
ch_pc_loop:
    LD   A, E
    CP   C
    JP   Z, ch_pc_clear     ; reached destination
    ; Check this square is empty
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)
    OR   A
    JP   NZ, ch_pc_blocked
    ; Advance to next square
    LD   A, E
    ADD  A, D               ; next position
    LD   E, A
    JP   ch_pc_loop

ch_pc_clear:
    XOR  A
    POP  DE
    POP  BC
    POP  HL
    RET

ch_pc_blocked:
    LD   A, 1
    POP  DE
    POP  BC
    POP  HL
    RET

; ============================================================
; ch_make_move - Execute the move on the board
; Saves undo info. Handles pawn promotion.
; ============================================================
ch_make_move:
    PUSH HL
    PUSH BC
    PUSH AF

    ; Save undo info
    LD   A, (ch_move_from)
    LD   (ch_undo_from), A
    LD   A, (ch_move_to)
    LD   (ch_undo_to), A

    ; Get source piece
    LD   A, (ch_move_from)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)
    LD   B, A               ; B = source piece
    LD   (ch_undo_piece), A

    ; Get dest piece (for undo)
    LD   A, (ch_move_to)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)
    LD   (ch_undo_captured), A

    ; Clear source
    LD   A, (ch_move_from)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   (HL), CH_EMPTY

    ; Check for pawn promotion
    LD   A, B
    AND  CH_TYPE
    CP   CH_PAWN
    JP   NZ, ch_mm_nopromo

    ; White pawn reaching row 0 (rank 8)?
    LD   A, B
    AND  CH_COLOR
    CP   CH_WHITE
    JP   NZ, ch_mm_bpromo
    LD   A, (ch_move_to)
    AND  0x38
    JP   Z, ch_mm_wpromote   ; row 0 = rank 8
    JP   ch_mm_nopromo

ch_mm_bpromo:
    ; Black pawn reaching row 7 (rank 1)?
    LD   A, (ch_move_to)
    AND  0x38
    CP   0x38                ; row 7
    JP   NZ, ch_mm_nopromo
    LD   B, CH_BLACK | CH_QUEEN
    JP   ch_mm_nopromo

ch_mm_wpromote:
    LD   B, CH_WHITE | CH_QUEEN

ch_mm_nopromo:
    ; Place piece at destination
    LD   A, (ch_move_to)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   (HL), B

    POP  AF
    POP  BC
    POP  HL
    RET

; ============================================================
; ch_undo_move - Reverse the last move
; ============================================================
ch_undo_move:
    PUSH HL
    PUSH AF

    ; Restore source piece
    LD   A, (ch_undo_from)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (ch_undo_piece)
    LD   (HL), A

    ; Restore captured piece at destination
    LD   A, (ch_undo_to)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (ch_undo_captured)
    LD   (HL), A

    POP  AF
    POP  HL
    RET

; ============================================================
; ch_check_kings - Check if both kings are on the board
; Returns: A=0 both present, A=1 white king missing, A=2 black king missing
; ============================================================
ch_check_kings:
    PUSH HL
    PUSH BC

    LD   HL, ch_board
    LD   B, BOARD_SIZE
    LD   C, 0               ; bit 0 = white king found, bit 1 = black king found
ch_ck_loop:
    LD   A, (HL)
    AND  CH_TYPE
    CP   CH_KING
    JP   NZ, ch_ck_next
    ; It's a king - which color?
    LD   A, (HL)
    AND  CH_COLOR
    CP   CH_WHITE
    JP   NZ, ch_ck_black
    LD   A, C
    OR   0x01
    LD   C, A
    JP   ch_ck_next
ch_ck_black:
    LD   A, C
    OR   0x02
    LD   C, A
ch_ck_next:
    INC  HL
    DEC  B
    JP   NZ, ch_ck_loop

    ; Check results
    LD   A, C
    AND  0x01
    JP   Z, ch_ck_nowhite
    LD   A, C
    AND  0x02
    JP   Z, ch_ck_noblack
    XOR  A                  ; both present
    POP  BC
    POP  HL
    RET
ch_ck_nowhite:
    LD   A, 1
    POP  BC
    POP  HL
    RET
ch_ck_noblack:
    LD   A, 2
    POP  BC
    POP  HL
    RET

; ============================================================
; ch_in_check - Is the given color's king in check?
; Input: A = color to check (CH_WHITE or CH_BLACK)
; Output: A = 0 if not in check, 1 if in check
; ============================================================
ch_in_check:
    PUSH HL
    PUSH BC
    PUSH DE

    LD   D, A               ; D = color to check
    ; Find king of that color
    LD   HL, ch_board
    LD   B, BOARD_SIZE
    LD   C, 0               ; C = index
ch_ic_find:
    LD   A, (HL)
    AND  CH_TYPE
    CP   CH_KING
    JP   NZ, ch_ic_next
    LD   A, (HL)
    AND  CH_COLOR
    CP   D
    JP   Z, ch_ic_found
ch_ic_next:
    INC  HL
    INC  C
    DEC  B
    JP   NZ, ch_ic_find

    ; King not found (already captured) - consider in check
    LD   A, 1
    POP  DE
    POP  BC
    POP  HL
    RET

ch_ic_found:
    ; C = king position
    ; Check if any enemy piece attacks this square
    ; Enemy color
    LD   A, D
    CP   CH_WHITE
    JP   Z, ch_ic_enemy_black
    LD   D, CH_WHITE         ; enemy is white
    JP   ch_ic_scan
ch_ic_enemy_black:
    LD   D, CH_BLACK         ; enemy is black

ch_ic_scan:
    ; Scan all squares for enemy pieces that can attack C
    LD   HL, ch_board
    LD   B, 0               ; B = scanner index
ch_ic_scanloop:
    LD   A, (HL)
    OR   A
    JP   Z, ch_ic_scannext  ; empty
    PUSH AF
    AND  CH_COLOR
    CP   D                  ; is it enemy color?
    JP   NZ, ch_ic_scanpop

    ; Enemy piece at index B, check if it attacks C
    POP  AF
    PUSH HL
    PUSH BC
    PUSH DE

    ; Set up ch_move_from=B (attacker), ch_move_to=C (king)
    LD   A, B
    LD   (ch_move_from), A
    LD   A, C
    LD   (ch_move_to), A

    ; Store king square contents temporarily
    ; We need to check if piece at B can reach C
    ; For this, treat it as if color doesn't matter
    LD   A, (HL)            ; piece at B
    AND  CH_TYPE

    CP   CH_PAWN
    JP   Z, ch_ic_pawn
    CP   CH_KNIGHT
    JP   Z, ch_ic_knight
    CP   CH_BISHOP
    JP   Z, ch_ic_bishop
    CP   CH_ROOK
    JP   Z, ch_ic_rook
    CP   CH_QUEEN
    JP   Z, ch_ic_queen
    CP   CH_KING
    JP   Z, ch_ic_king
    JP   ch_ic_no_attack

ch_ic_pawn:
    ; Pawn attacks diagonally. Check direction based on color.
    ; D = enemy color
    ; B = pawn index, C = king index
    POP  DE
    POP  BC
    POP  HL
    PUSH HL
    PUSH BC
    PUSH DE

    ; Pawn row and file
    LD   A, B
    AND  0x38
    RRA
    RRA
    RRA
    LD   E, A               ; E = pawn row

    LD   A, C
    AND  0x38
    RRA
    RRA
    RRA                     ; A = king row

    ; If enemy is black, pawn attacks downward (row+1)
    ; If enemy is white, pawn attacks upward (row-1)
    LD   H, A               ; H = king row (save)
    LD   A, D
    CP   CH_BLACK
    LD   A, H               ; A = king row (restore, flags preserved)
    JP   Z, ch_ic_pawn_blk

    ; White pawn attacks: king_row = pawn_row - 1
    LD   H, A               ; king row
    LD   A, E
    DEC  A
    CP   H
    JP   NZ, ch_ic_no_attack
    JP   ch_ic_pawn_file

ch_ic_pawn_blk:
    ; Black pawn attacks: king_row = pawn_row + 1
    LD   H, A               ; king row
    LD   A, E
    INC  A
    CP   H
    JP   NZ, ch_ic_no_attack

ch_ic_pawn_file:
    ; File diff must be 1
    LD   A, B
    AND  0x07
    LD   E, A
    LD   A, C
    AND  0x07
    SUB  E
    JP   NC, ch_ic_pf2
    CPL
    INC  A
ch_ic_pf2:
    CP   1
    JP   Z, ch_ic_yes_attack
    JP   ch_ic_no_attack

ch_ic_knight:
    CALL ch_vm_knight_check
    JP   ch_ic_check_result

ch_ic_bishop:
    CALL ch_is_diagonal
    OR   A
    JP   NZ, ch_ic_no_attack
    CALL ch_path_clear
    OR   A
    JP   NZ, ch_ic_no_attack
    JP   ch_ic_yes_attack

ch_ic_rook:
    CALL ch_is_straight
    OR   A
    JP   NZ, ch_ic_no_attack
    CALL ch_path_clear
    OR   A
    JP   NZ, ch_ic_no_attack
    JP   ch_ic_yes_attack

ch_ic_queen:
    CALL ch_is_diagonal
    OR   A
    JP   Z, ch_ic_queen_path
    CALL ch_is_straight
    OR   A
    JP   NZ, ch_ic_no_attack
ch_ic_queen_path:
    CALL ch_path_clear
    OR   A
    JP   NZ, ch_ic_no_attack
    JP   ch_ic_yes_attack

ch_ic_king:
    ; King attacks adjacent squares
    LD   A, B
    AND  0x38
    RRA
    RRA
    RRA
    LD   E, A               ; pawn row (reusing E)
    LD   A, C
    AND  0x38
    RRA
    RRA
    RRA
    SUB  E
    JP   NC, ch_ic_ki1
    CPL
    INC  A
ch_ic_ki1:
    CP   2
    JP   NC, ch_ic_no_attack
    LD   A, B
    AND  0x07
    LD   E, A
    LD   A, C
    AND  0x07
    SUB  E
    JP   NC, ch_ic_ki2
    CPL
    INC  A
ch_ic_ki2:
    CP   2
    JP   NC, ch_ic_no_attack
    JP   ch_ic_yes_attack

ch_ic_check_result:
    ; A=0 means can attack, A=1 means cannot
    OR   A
    JP   Z, ch_ic_yes_attack
    JP   ch_ic_no_attack

ch_ic_yes_attack:
    POP  DE
    POP  BC
    POP  HL
    ; King IS in check
    LD   A, 1
    POP  DE
    POP  BC
    POP  HL
    RET

ch_ic_no_attack:
    POP  DE
    POP  BC
    POP  HL
    JP   ch_ic_scannext

ch_ic_scanpop:
    POP  AF
ch_ic_scannext:
    INC  HL
    INC  B
    LD   A, B
    CP   BOARD_SIZE
    JP   NZ, ch_ic_scanloop

    ; No attack found - not in check
    XOR  A
    POP  DE
    POP  BC
    POP  HL
    RET

; ============================================================
; ch_vm_knight_check - Check if knight move from ch_move_from to ch_move_to is valid
; Returns A=0 valid, A=1 invalid
; ============================================================
ch_vm_knight_check:
    PUSH BC
    PUSH DE

    LD   A, (ch_move_from)
    LD   B, A
    LD   A, (ch_move_to)
    LD   C, A

    LD   A, B
    AND  0x38
    RRA
    RRA
    RRA
    LD   D, A               ; from row
    LD   A, B
    AND  0x07
    LD   E, A               ; from file

    LD   A, C
    AND  0x38
    RRA
    RRA
    RRA                     ; to row

    SUB  D
    JP   NC, ch_vnk_dr
    CPL
    INC  A
ch_vnk_dr:
    LD   B, A               ; |dr|

    LD   A, C
    AND  0x07
    SUB  E
    JP   NC, ch_vnk_df
    CPL
    INC  A
ch_vnk_df:
    LD   C, A               ; |df|

    LD   A, B
    CP   1
    JP   NZ, ch_vnk_try2
    LD   A, C
    CP   2
    JP   Z, ch_vnk_ok
    JP   ch_vnk_no

ch_vnk_try2:
    LD   A, B
    CP   2
    JP   NZ, ch_vnk_no
    LD   A, C
    CP   1
    JP   Z, ch_vnk_ok

ch_vnk_no:
    LD   A, 1
    POP  DE
    POP  BC
    RET

ch_vnk_ok:
    XOR  A
    POP  DE
    POP  BC
    RET

; ============================================================
; ch_ai_move - Computer (Black) makes a move
; Uses 1-ply material search: try all legal moves, pick best
; Returns A=0 if move made, A=1 if no legal move
; ============================================================
ch_ai_move:
    PUSH HL
    PUSH BC
    PUSH DE

    ; Initialize best score to worst possible
    LD   A, 0xFF
    LD   (ch_ai_best_score), A      ; 0xFF = no move found yet

    ; Scan all squares for black pieces
    LD   B, 0               ; B = from index
ch_ai_from_loop:
    LD   HL, ch_board
    LD   A, B
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)
    OR   A
    JP   Z, ch_ai_from_next ; empty
    AND  CH_COLOR
    CP   CH_BLACK
    JP   NZ, ch_ai_from_next ; not black

    ; Try all destination squares
    LD   C, 0               ; C = to index
ch_ai_to_loop:
    LD   A, B
    CP   C
    JP   Z, ch_ai_to_next   ; skip same square

    ; Save from/to
    LD   A, B
    LD   (ch_move_from), A
    LD   A, C
    LD   (ch_move_to), A

    ; Validate move for black
    CALL ch_validate_move_black
    OR   A
    JP   NZ, ch_ai_to_next

    ; Try the move
    PUSH BC
    CALL ch_make_move

    ; Check if this leaves black king in check
    LD   A, CH_BLACK
    CALL ch_in_check
    OR   A
    JP   NZ, ch_ai_undo_skip

    ; Evaluate move score
    ; Base: capture value * 4 (priority)
    LD   A, (ch_undo_captured)
    CALL ch_piece_value      ; A = value of captured piece
    ADD  A, A
    ADD  A, A                ; *4 for capture priority

    ; Add positional bonus for destination row
    ; Black wants to advance (higher row = further advanced)
    LD   E, A                ; save capture score
    POP  BC
    PUSH BC
    LD   A, C                ; C = to index
    AND  0x38
    RRA
    RRA
    RRA                      ; to_row (0-7, 7=rank1)
    ADD  A, E                ; add row bonus (0-7)
    LD   E, A                ; E = total score

    ; Compare with best score
    LD   A, (ch_ai_best_score)
    CP   0xFF
    JP   Z, ch_ai_new_best   ; first legal move

    ; Is this score better (higher)?
    LD   A, E
    LD   D, A
    LD   A, (ch_ai_best_score)
    CP   D
    JP   NC, ch_ai_undo_cont ; current best >= new score

ch_ai_new_best:
    ; Save as new best
    LD   A, E
    LD   (ch_ai_best_score), A
    POP  BC
    PUSH BC
    LD   A, B
    LD   (ch_ai_best_from), A
    LD   A, C
    LD   (ch_ai_best_to), A
    JP   ch_ai_undo_cont

ch_ai_undo_skip:
ch_ai_undo_cont:
    CALL ch_undo_move
    POP  BC

ch_ai_to_next:
    INC  C
    LD   A, C
    CP   BOARD_SIZE
    JP   NZ, ch_ai_to_loop

ch_ai_from_next:
    INC  B
    LD   A, B
    CP   BOARD_SIZE
    JP   NZ, ch_ai_from_loop

    ; Check if we found a move
    LD   A, (ch_ai_best_score)
    CP   0xFF
    JP   Z, ch_ai_nomove

    ; Execute the best move
    LD   A, (ch_ai_best_from)
    LD   (ch_move_from), A
    LD   A, (ch_ai_best_to)
    LD   (ch_move_to), A
    CALL ch_make_move

    XOR  A                  ; success
    POP  DE
    POP  BC
    POP  HL
    RET

ch_ai_nomove:
    LD   A, 1
    POP  DE
    POP  BC
    POP  HL
    RET

; ============================================================
; ch_validate_move_black - Validate a move for black pieces
; Same as ch_validate_move but for black color and reversed pawn direction
; Returns A=0 valid, A=1 invalid
; ============================================================
ch_validate_move_black:
    PUSH HL
    PUSH BC
    PUSH DE

    ; Get source piece
    LD   A, (ch_move_from)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)

    ; Source must be a black piece
    OR   A
    JP   Z, ch_vb_fail
    LD   B, A                ; B = source piece
    AND  CH_COLOR
    CP   CH_BLACK
    JP   NZ, ch_vb_fail

    ; Get destination piece
    LD   A, (ch_move_to)
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)
    LD   (ch_temp_dest), A

    ; Can't capture own piece
    OR   A
    JP   Z, ch_vb_dest_ok
    AND  CH_COLOR
    CP   CH_BLACK
    JP   Z, ch_vb_fail

ch_vb_dest_ok:
    LD   A, B                ; restore source piece
    AND  CH_TYPE

    CP   CH_PAWN
    JP   Z, ch_vb_pawn
    CP   CH_KNIGHT
    JP   Z, ch_vb_knight
    CP   CH_BISHOP
    JP   Z, ch_vb_bishop
    CP   CH_ROOK
    JP   Z, ch_vb_rook
    CP   CH_QUEEN
    JP   Z, ch_vb_queen
    CP   CH_KING
    JP   Z, ch_vb_king
    JP   ch_vb_fail

ch_vb_fail:
    LD   A, 1
    POP  DE
    POP  BC
    POP  HL
    RET

ch_vb_ok:
    XOR  A
    POP  DE
    POP  BC
    POP  HL
    RET

; --- Black pawn (moves down = increasing index) ---
ch_vb_pawn:
    LD   A, (ch_move_from)
    LD   B, A
    LD   A, (ch_move_to)
    LD   C, A

    LD   A, B
    AND  0x07
    LD   D, A               ; D = from file
    LD   A, B
    AND  0x38
    RRA
    RRA
    RRA
    LD   E, A               ; E = from row

    LD   A, C
    AND  0x07
    LD   H, A               ; H = to file
    LD   A, C
    AND  0x38
    RRA
    RRA
    RRA
    LD   L, A               ; L = to row

    ; Forward one: to_row = from_row + 1, same file
    LD   A, E
    INC  A
    CP   L
    JP   NZ, ch_vb_pawn_dbl

    LD   A, D
    CP   H
    JP   NZ, ch_vb_pawn_cap

    LD   A, (ch_temp_dest)
    OR   A
    JP   NZ, ch_vb_fail
    JP   ch_vb_ok

ch_vb_pawn_dbl:
    ; Double move from row 1 (rank 7) to row 3
    LD   A, E
    CP   1
    JP   NZ, ch_vb_pawn_cap
    LD   A, L
    CP   3
    JP   NZ, ch_vb_pawn_cap

    LD   A, D
    CP   H
    JP   NZ, ch_vb_fail

    LD   A, (ch_temp_dest)
    OR   A
    JP   NZ, ch_vb_fail

    ; Check middle square (row 2)
    LD   A, 2
    ADD  A, A
    ADD  A, A
    ADD  A, A               ; 16
    ADD  A, D
    LD   HL, ch_board
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   A, (HL)
    OR   A
    JP   NZ, ch_vb_fail
    JP   ch_vb_ok

ch_vb_pawn_cap:
    ; Diagonal capture: to_row = from_row + 1
    LD   A, E
    INC  A
    CP   L
    JP   NZ, ch_vb_fail

    LD   A, D
    SUB  H
    JP   Z, ch_vb_fail
    CP   1
    JP   Z, ch_vb_pawn_cap2
    CP   0xFF
    JP   Z, ch_vb_pawn_cap2
    JP   ch_vb_fail

ch_vb_pawn_cap2:
    LD   A, (ch_temp_dest)
    OR   A
    JP   Z, ch_vb_fail
    AND  CH_COLOR
    CP   CH_WHITE
    JP   NZ, ch_vb_fail
    JP   ch_vb_ok

; Reuse non-pawn validators (they're color-agnostic for geometry)
ch_vb_knight:
    CALL ch_vm_knight_check
    OR   A
    JP   NZ, ch_vb_fail
    JP   ch_vb_ok

ch_vb_bishop:
    CALL ch_is_diagonal
    OR   A
    JP   NZ, ch_vb_fail
    CALL ch_path_clear
    OR   A
    JP   NZ, ch_vb_fail
    JP   ch_vb_ok

ch_vb_rook:
    CALL ch_is_straight
    OR   A
    JP   NZ, ch_vb_fail
    CALL ch_path_clear
    OR   A
    JP   NZ, ch_vb_fail
    JP   ch_vb_ok

ch_vb_queen:
    CALL ch_is_diagonal
    OR   A
    JP   Z, ch_vb_queen_path
    CALL ch_is_straight
    OR   A
    JP   NZ, ch_vb_fail
ch_vb_queen_path:
    CALL ch_path_clear
    OR   A
    JP   NZ, ch_vb_fail
    JP   ch_vb_ok

ch_vb_king:
    LD   A, (ch_move_from)
    LD   B, A
    LD   A, (ch_move_to)
    LD   C, A

    LD   A, B
    AND  0x38
    RRA
    RRA
    RRA
    LD   D, A
    LD   A, C
    AND  0x38
    RRA
    RRA
    RRA
    SUB  D
    JP   NC, ch_vb_ki1
    CPL
    INC  A
ch_vb_ki1:
    CP   2
    JP   NC, ch_vb_fail
    LD   A, B
    AND  0x07
    LD   D, A
    LD   A, C
    AND  0x07
    SUB  D
    JP   NC, ch_vb_ki2
    CPL
    INC  A
ch_vb_ki2:
    CP   2
    JP   NC, ch_vb_fail
    JP   ch_vb_ok

; ============================================================
; ch_piece_value - Get material value of a piece
; Input: A = piece byte
; Output: A = value (0 for empty/king)
; ============================================================
ch_piece_value:
    OR   A
    JP   Z, ch_pv_zero
    AND  CH_TYPE
    CP   CH_PAWN
    JP   Z, ch_pv_pawn
    CP   CH_KNIGHT
    JP   Z, ch_pv_knight
    CP   CH_BISHOP
    JP   Z, ch_pv_bishop
    CP   CH_ROOK
    JP   Z, ch_pv_rook
    CP   CH_QUEEN
    JP   Z, ch_pv_queen
ch_pv_zero:
    XOR  A
    RET
ch_pv_pawn:
    LD   A, VAL_PAWN
    RET
ch_pv_knight:
    LD   A, VAL_KNIGHT
    RET
ch_pv_bishop:
    LD   A, VAL_BISHOP
    RET
ch_pv_rook:
    LD   A, VAL_ROOK
    RET
ch_pv_queen:
    LD   A, VAL_QUEEN
    RET

; ============================================================
; ch_show_ai_move - Display the AI's move
; ============================================================
ch_show_ai_move:
    PUSH HL
    PUSH AF

    LD   DE, ch_msg_aimove
    CALL ch_puts

    ; Print from square
    LD   A, (ch_ai_best_from)
    CALL ch_print_square

    ; Print to square
    LD   A, (ch_ai_best_to)
    CALL ch_print_square

    LD   DE, ch_msg_crlf
    CALL ch_puts

    POP  AF
    POP  HL
    RET

; ============================================================
; ch_print_square - Print a square name (e.g. "E4")
; Input: A = board index
; ============================================================
ch_print_square:
    PUSH AF
    PUSH BC

    LD   B, A               ; save index
    AND  0x07               ; file
    ADD  A, 'A'
    LD   E, A
    CALL ch_putchar

    LD   A, B
    AND  0x38
    RRA
    RRA
    RRA                     ; row (0-7)
    ; rank = 8 - row
    LD   B, A
    LD   A, 8
    SUB  B
    ADD  A, '0'
    LD   E, A
    CALL ch_putchar

    POP  BC
    POP  AF
    RET

; ============================================================
; I/O Helper Functions
; ============================================================

; ch_puts - Print null-terminated string at DE
ch_puts:
    PUSH BC
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    POP  HL
    POP  BC
    RET

; ch_putchar - Print character in E
ch_putchar:
    PUSH BC
    PUSH HL
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE
    CALL KERNELADDR
    POP  HL
    POP  BC
    RET

; ch_getline - Read a line into ch_inbuf, echo CRLF
ch_getline:
    PUSH BC
    PUSH HL
    LD   B, LOGDEV_ID_CONI
    LD   DE, ch_inbuf
    LD   C, DEV_CREAD_STR
    CALL KERNELADDR
    ; Echo CRLF (piped input doesn't echo Enter)
    LD   E, 0x0D
    CALL ch_putchar
    LD   E, 0x0A
    CALL ch_putchar
    POP  HL
    POP  BC
    RET

; ============================================================
; Messages
; ============================================================
ch_msg_welcome:
    DEFM "NostOS Chess", 0x0D, 0x0A
    DEFM "You are White (uppercase). Computer is Black (lowercase).", 0x0D, 0x0A
    DEFM "Enter moves as: E2E4  (from-to)", 0x0D, 0x0A
    DEFM "Commands: Q=Quit, H=Help, B=Board", 0x0D, 0x0A, 0

ch_msg_prompt:
    DEFM "Your move: ", 0

ch_msg_badmove:
    DEFM "Invalid format. Use e.g. E2E4", 0x0D, 0x0A, 0

ch_msg_illegal:
    DEFM "Illegal move.", 0x0D, 0x0A, 0

ch_msg_incheck:
    DEFM "Move leaves your King in check!", 0x0D, 0x0A, 0

ch_msg_thinking:
    DEFM "Thinking...", 0x0D, 0x0A, 0

ch_msg_aimove:
    DEFM "Computer plays: ", 0

ch_msg_youwin:
    DEFM "You win! Congratulations!", 0x0D, 0x0A, 0

ch_msg_youlose:
    DEFM "Checkmate! You lose.", 0x0D, 0x0A, 0

ch_msg_bye:
    DEFM "Thanks for playing!", 0x0D, 0x0A, 0

ch_msg_help:
    DEFM "Enter moves in coordinate format: E2E4", 0x0D, 0x0A
    DEFM "  File = A-H (columns), Rank = 1-8 (rows)", 0x0D, 0x0A
    DEFM "  Example: E2E4 moves piece from E2 to E4", 0x0D, 0x0A
    DEFM "  Q = Quit, B = Show board", 0x0D, 0x0A
    DEFM "Pieces: K=King Q=Queen R=Rook B=Bishop N=Knight P=Pawn", 0x0D, 0x0A
    DEFM "White=UPPERCASE, Black=lowercase", 0x0D, 0x0A, 0

ch_msg_crlf:
    DEFM 0x0D, 0x0A, 0

ch_msg_colhdr:
    DEFM "  A B C D E F G H", 0x0D, 0x0A, 0

ch_msg_sep:
    DEFM " +-+-+-+-+-+-+-+-+", 0x0D, 0x0A, 0

; ============================================================
; Variables (in RAM area after code)
; ============================================================
ch_board:       DEFS BOARD_SIZE, 0   ; 64-byte board
ch_inbuf:       DEFS 32, 0          ; input buffer
ch_move_from:   DEFS 1, 0           ; move source index
ch_move_to:     DEFS 1, 0           ; move dest index
ch_temp_dest:   DEFS 1, 0           ; temp: piece at destination
ch_undo_from:   DEFS 1, 0           ; undo: source index
ch_undo_to:     DEFS 1, 0           ; undo: dest index
ch_undo_piece:  DEFS 1, 0           ; undo: source piece
ch_undo_captured: DEFS 1, 0         ; undo: captured piece

; AI working storage
ch_ai_best_score: DEFS 1, 0         ; best score found
ch_ai_best_from:  DEFS 1, 0         ; best move from
ch_ai_best_to:    DEFS 1, 0         ; best move to

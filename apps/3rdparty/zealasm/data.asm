; ============================================================
; data.asm - Symbol table (hashmap + sorted linked lists)
; Based on Zealasm by Zeal 8-bit Computer (Apache 2.0)
; Ported to NostOS — 8080-only instructions
; ============================================================
;
; The symbol table is a 256-entry hashmap where each bucket
; points to a sorted linked list of entries. Each list entry
; is LIST_ENTRY_SIZE (21) bytes:
;   bytes 0-15:  key (label name, null-padded)
;   bytes 16-17: value (16-bit)
;   bytes 18-19: next pointer
;   byte  20:    flags
;
; Entries are allocated from a downward-growing heap starting
; at za_heap_top (set to SYS_MEMTOP at startup).
; ============================================================

; ------------------------------------------------------------
; data_init
; Initialize the hashmap and heap
; Must be called before any other data_ function
; ------------------------------------------------------------
data_init:
    ; Clear hashmap (256 entries x 2 bytes = 512 bytes)
    LD   HL, za_hashmap
    LD   B, 0               ; 256 iterations (wraps)
    XOR  A
_data_init_clear:
    LD   (HL), A
    INC  HL
    LD   (HL), A
    INC  HL
    DEC  B
    JP   NZ, _data_init_clear
    RET

; ------------------------------------------------------------
; data_get
; Look up a key in the hashmap
; Inputs:
;   HL - key string (NULL-terminated)
; Outputs:
;   DE - value associated with key
;   A  - 0 if found, non-zero if not found
; Alters:
;   A, BC, DE, HL
; ------------------------------------------------------------
data_get:
    LD   D, H
    LD   E, L               ; DE = key
    CALL _data_hashmap_get_list
    LD   A, H
    OR   L
    JP   Z, _data_get_not_found
    CALL _data_list_search
    OR   A
    JP   NZ, _data_get_not_found
    ; HL = matching entry, get value at offset LIST_VALUE_OFF
    LD   DE, LIST_VALUE_OFF
    ADD  HL, DE
    LD   E, (HL)
    INC  HL
    LD   D, (HL)
    ; Read flags byte (at offset LIST_FLAGS_OFF = value + 4)
    INC  HL                 ; next_lo
    INC  HL                 ; next_hi
    INC  HL                 ; flags
    LD   A, (HL)
    LD   (data_get_flags), A
    XOR  A
    RET
_data_get_not_found:
    LD   A, 1               ; not found
    RET

; ------------------------------------------------------------
; data_insert
; Insert a key/value pair into the hashmap
; Inputs:
;   HL - key string (NULL-terminated)
;   DE - value (16-bit)
; Outputs:
;   A  - 0 on success, 1 = no memory, 2 = already exists
; Alters:
;   A, BC, DE, HL
; ------------------------------------------------------------
data_insert:
    PUSH HL                 ; save key
    CALL _data_hashmap_get_list
    LD   A, H
    OR   L
    JP   Z, _data_insert_first
    ; List not empty: allocate entry, search for position, insert
    EX   (SP), HL           ; HL = key, [SP] = list head addr
    CALL _data_list_alloc_entry
    OR   A
    RET  NZ                 ; out of memory (A=1)
    ; DE = new entry address
    POP  HL                 ; HL = list head
    CALL _data_list_search
    OR   A
    JP   Z, _data_insert_exists
    ; Not found — insert: BC = ptr to prev node's "next" field
    ; Store new entry address in prev's next
    LD   A, E
    LD   (BC), A
    INC  BC
    LD   A, D
    LD   (BC), A
    ; Make new entry's next point to what search returned in HL
    EX   DE, HL             ; HL = new entry
    LD   BC, LIST_NEXT_OFF
    ADD  HL, BC
    LD   (HL), E            ; E = low byte of old next
    INC  HL
    LD   (HL), D            ; D = high byte of old next
    XOR  A
    RET
_data_insert_first:
    ; Empty bucket — allocate entry and set as first
    POP  HL                 ; HL = key
    CALL _data_list_alloc_entry
    OR   A
    RET  NZ                 ; out of memory
    ; DE = new entry, BC = bucket pointer
    LD   H, B
    LD   L, C
    LD   (HL), E
    INC  HL
    LD   (HL), D
    XOR  A
    RET
_data_insert_exists:
    LD   A, 2               ; already exists
    RET

; ------------------------------------------------------------
; data_list_new_entry
; Allocate a new list entry from the heap
; Inputs:
;   HL - key string
;   DE - value
; Outputs:
;   DE - address of new entry
;   A  - 0 on success, 1 on out of memory
; Alters:
;   A, DE
; ------------------------------------------------------------
data_list_new_entry:
_data_list_alloc_entry:
    PUSH HL
    ; Decrement heap head by LIST_ENTRY_SIZE
    LD   HL, (za_heap_top)
    ; Subtract LIST_ENTRY_SIZE (21) from HL
    LD   A, L
    SUB  LIST_ENTRY_SIZE
    LD   L, A
    LD   A, H
    SBC  A, 0
    LD   H, A
    ; Check if we've hit the bottom (below binary output area)
    ; Compare H against a minimum — we use za_heap_bottom
    LD   A, (za_heap_bottom + 1)  ; high byte of bottom limit
    CP   H
    JP   C, _data_alloc_ok
    JP   NZ, _data_alloc_nomem
    ; H equals bottom MSB, check L
    LD   A, (za_heap_bottom)
    CP   L
    JP   C, _data_alloc_ok
    JP   Z, _data_alloc_ok
_data_alloc_nomem:
    POP  HL
    LD   A, 1               ; out of memory
    OR   A
    RET
_data_alloc_ok:
    ; HL is valid new heap head
    LD   (za_heap_top), HL
    ; Copy key from original HL (on stack) to new entry
    EX   DE, HL             ; DE = new entry
    EX   (SP), HL           ; HL = key, [SP] = value
    PUSH DE                 ; save new entry pointer
    PUSH BC
    LD   BC, LIST_KEY_SIZE
    CALL strncpy_unsaved    ; copy key to DE, pad with zeros
    POP  BC
    ; DE now points to end of key = value offset
    ; Store value from stack
    POP  HL                 ; HL = new entry
    EX   (SP), HL           ; HL = value, [SP] = new entry
    EX   DE, HL             ; DE = value, HL = entry + LIST_KEY_SIZE
    LD   (HL), E
    INC  HL
    LD   (HL), D
    ; Clear next pointer
    INC  HL
    XOR  A
    LD   (HL), A
    INC  HL
    LD   (HL), A
    ; Clear flags byte
    INC  HL
    LD   (HL), A
    ; Return new entry in DE
    POP  DE                 ; DE = new entry
    XOR  A
    RET

; ------------------------------------------------------------
; data_list_prepend_entry
; Prepend an entry to a linked list
; Inputs:
;   HL - entry to prepend
;   DE - current list head (may be 0)
; Outputs:
;   HL - new list head (= original HL)
; Alters:
;   A
; ------------------------------------------------------------
data_list_prepend_entry:
    PUSH HL
    ; HL += LIST_NEXT_OFF
    LD   A, LIST_NEXT_OFF
    ADD  A, L
    LD   L, A
    LD   A, 0
    ADC  A, H
    LD   H, A
    LD   (HL), E
    INC  HL
    LD   (HL), D
    POP  HL
    RET

; ------------------------------------------------------------
; data_list_get_value
; Get the value from a list entry
; Inputs:
;   HL - list entry address
; Outputs:
;   HL - value
; Alters:
;   A, BC, HL
; ------------------------------------------------------------
data_list_get_value:
    LD   BC, LIST_VALUE_OFF
    ADD  HL, BC
    LD   A, (HL)
    INC  HL
    LD   H, (HL)
    LD   L, A
    RET

; ------------------------------------------------------------
; data_list_get_next
; Get the next node from a list entry
; Inputs:
;   HL - list entry address
; Outputs:
;   HL - next entry (or 0)
; Alters:
;   HL, BC
; ------------------------------------------------------------
data_list_get_next:
    LD   BC, LIST_NEXT_OFF
    ADD  HL, BC
    LD   A, (HL)
    INC  HL
    LD   H, (HL)
    LD   L, A
    RET

; ============================================================
; PRIVATE ROUTINES
; ============================================================

; Search sorted list for entry matching DE (key string)
; Inputs:
;   HL - list head (MUST NOT be 0)
;   DE - key string to search for
;   BC - pointer to first entry's pointer (bucket addr)
; Outputs:
;   A  - 0 if found, non-zero if not found
;   HL - matching entry (if found), or insertion point entry
;   BC - pointer to previous node's "next" field
_data_list_search:
_data_list_search_loop:
    LD   A, LIST_KEY_SIZE
    CALL strncmp_opt
    OR   A
    RET  Z                  ; found! A=0, HL=entry
    ; If A negative (DE < HL), place here
    JP   M, _data_list_search_place
    ; HL < DE, go to next node
    ; HL += LIST_NEXT_OFF
    PUSH DE
    LD   DE, LIST_NEXT_OFF
    ADD  HL, DE
    POP  DE
    LD   B, H
    LD   C, L               ; BC = addr of this node's next ptr
    ; Dereference
    LD   A, (HL)
    INC  HL
    LD   H, (HL)
    LD   L, A
    ; If HL != 0, continue
    OR   H
    JP   NZ, _data_list_search_loop
    ; End of list
_data_list_search_place:
    LD   A, 1               ; not found
    RET

; Get the bucket list for a given string
; Inputs:
;   HL - NULL-terminated string
; Outputs:
;   HL - first entry in bucket (may be 0)
;   BC - address of bucket pointer (for insertion)
_data_hashmap_get_list:
    CALL _data_hash_str
    ; Hash in B, A is 0
    LD   H, A
    LD   L, B
    ADD  HL, HL             ; hash * 2
    LD   BC, za_hashmap
    ADD  HL, BC
    LD   C, L
    LD   B, H               ; BC = bucket address
    LD   A, (HL)
    INC  HL
    LD   H, (HL)
    LD   L, A               ; HL = first entry
    RET

; Calculate 8-bit hash of string
; Inputs:
;   HL - string
; Outputs:
;   A - 0
;   B - hash value
_data_hash_str:
    LD   BC, 0x0580         ; B=initial hash, C=mask
_data_hash_loop:
    LD   A, (HL)
    OR   A
    RET  Z
    ; hash = (hash << 7) + hash + char
    LD   A, B
    RRCA
    AND  C
    ADD  A, B
    ADD  A, (HL)
    INC  HL
    LD   B, A
    JP   _data_hash_loop

; Data
data_get_flags:     DEFB 0      ; flags byte from last successful data_get

; ============================================================
; Kernel Syscall Entry Point
; ============================================================

KERNELADDR          EQU 0x0010  ; RST 0x10 (RST2) - syscall vector in workspace RAM

; ============================================================
; Syscall Function Numbers (loaded into C register)
; ============================================================

SYS_EXIT            EQU 0
SYS_INFO            EQU 1
SYS_GET_CWD         EQU 2
SYS_SET_CWD         EQU 3
SYS_GET_CMDLINE     EQU 4
SYS_MEMTOP          EQU 5
DEV_LOG_ASSIGN      EQU 6
DEV_LOG_GET         EQU 7
DEV_LOG_LOOKUP      EQU 8
DEV_PHYS_LOOKUP     EQU 9
DEV_INIT            EQU 10
DEV_SHUTDOWN        EQU 11
DEV_STAT            EQU 12
DEV_CREAD_RAW       EQU 13
DEV_CREAD           EQU 14
DEV_CWRITE          EQU 15
DEV_CWRITE_STR      EQU 16
DEV_CREAD_STR       EQU 17
DEV_BREAD           EQU 18
DEV_BWRITE          EQU 19
DEV_BSEEK           EQU 20
DEV_BSETSIZE        EQU 21
DEV_FOPEN           EQU 22
DEV_CLOSE           EQU 23
DEV_FCREATE         EQU 24
DEV_FREMOVE         EQU 25
DEV_FRENAME         EQU 26
DEV_DCREATE         EQU 27
DEV_DOPEN           EQU 28
DIR_FIRST           EQU 29
DIR_NEXT            EQU 30
DEV_PHYS_GET        EQU 31
DEV_BGETPOS         EQU 32
DEV_BGETSIZE        EQU 33
DEV_MOUNT           EQU 34
DEV_LOG_CREATE      EQU 35
DEV_LOOKUP          EQU 36
DEV_GET_NAME        EQU 37
DEV_COPY            EQU 38
SYS_GLOBAL_OPENFILE EQU 39      ; resolve pathname and open file (or return bare device ID)
SYS_GLOBAL_OPENDIR  EQU 40      ; resolve pathname and open directory
SYS_EXEC            EQU 41      ; load relocatable executable (B=handle, DE=load_addr)
DEV_FREE            EQU 42      ; get free block count on a filesystem device
SYS_PATH_PARSE      EQU 43      ; parse pathname into device ID + path component
SYS_SET_MEMBOT      EQU 44      ; set DYNAMIC_MEMBOT (DE = new value)
SYSCALL_COUNT       EQU 45      ; total number of syscalls

; ============================================================
; MOUNT_PARAMS Structure (passed to DEV_MOUNT)
; ============================================================
MOUNT_OFF_BLKDEV    EQU 0       ; physical device ID of block device (1 byte)
MOUNT_OFF_NAME      EQU 1       ; null-terminated name for new FS device (variable)

; ============================================================
; Logical Device IDs (pass in B register for character/device syscalls)
; Top bit set = logical device; top bit clear = physical device.
; ============================================================
LOGDEV_ID_NUL       EQU 0x80    ; logical NUL
LOGDEV_ID_CONI      EQU 0x81    ; logical CONI (console input)
LOGDEV_ID_CONO      EQU 0x82    ; logical CONO (console output)
LOGDEV_ID_SERI      EQU 0x83    ; logical SERI (serial input)
LOGDEV_ID_SERO      EQU 0x84    ; logical SERO (serial output)
LOGDEV_ID_PRN       EQU 0x85    ; logical PRN (printer)

; Well-known logical device indices (table slot, without top bit)
LOGDEV_NUL          EQU 0
LOGDEV_CONI         EQU 1
LOGDEV_CONO         EQU 2
LOGDEV_SERI         EQU 3
LOGDEV_SERO         EQU 4
LOGDEV_PRN          EQU 5

; ============================================================
; Error Codes (returned in A register)
; ============================================================

ERR_SUCCESS         EQU 0
ERR_NOT_FOUND       EQU 1
ERR_EXISTS          EQU 2
ERR_NOT_SUPPORTED   EQU 3
ERR_INVALID_PARAM   EQU 4
ERR_INVALID_DEVICE  EQU 5
ERR_NO_SPACE        EQU 6
ERR_IO              EQU 7
ERR_NOT_OPEN        EQU 8
ERR_TOO_MANY_OPEN   EQU 9
ERR_READ_ONLY       EQU 10
ERR_NOT_DIR         EQU 11
ERR_NOT_FILE        EQU 12
ERR_DIR_NOT_EMPTY   EQU 13
ERR_BAD_FS          EQU 14
ERR_EOF             EQU 15
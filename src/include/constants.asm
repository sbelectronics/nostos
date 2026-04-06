; NostOS Hardware and Software Constants
; All build-time configurable values are defined here, except
; version and build date which are auto-generated in build/build_info.asm.
; ============================================================

; ============================================================
; Memory Layout
; ============================================================

; Workspace lives in high RAM, same address for all builds.
; This lets apps compiled once work on both 16K and 32K ROM systems.
WORKSPACE_BASE      EQU 0xF800  ; workspace start (1920 bytes, 0xF800-0xFF7F)

        IFDEF ROM_32K

; For 32K ROM: 0x0000-0x7FFF is ROM, RAM starts at 0x8000
USER_PROGRAM_BASE   EQU 0x8000  ; user programs loaded and run from here

        ELSE

; For 16K ROM: 0x0000-0x3FFF is ROM, RAM starts at 0x4000
USER_PROGRAM_BASE   EQU 0x4000  ; user programs loaded and run from here

        ENDIF

UNUSED_BASE         EQU WORKSPACE_BASE + 0x0000  ; unused space, previous RAM intvec table (64 bytes)
LOGDEV_TABLE        EQU WORKSPACE_BASE + 0x0040  ; logical device table (128 bytes, 16 x 8)
PHYSDEV_TABLE       EQU WORKSPACE_BASE + 0x00C0  ; RAM physical device table (512 bytes, 16 x 32)
INPUT_BUFFER        EQU WORKSPACE_BASE + 0x02C0  ; command line input buffer (256 bytes)
CUR_DEVICE          EQU WORKSPACE_BASE + 0x03C0  ; current device (1 byte)
CUR_DIR             EQU WORKSPACE_BASE + 0x03C1  ; current directory path (32 bytes)
PHYSDEV_LIST_HEAD   EQU WORKSPACE_BASE + 0x03E1  ; pointer to head of physical device list (2 bytes)
EXEC_CMD_TABLE_HEAD EQU WORKSPACE_BASE + 0x03E3  ; pointer to head of executive command table (2 bytes)
EXEC_ARGS_PTR       EQU WORKSPACE_BASE + 0x03E5  ; executive args pointer (2 bytes)
TRAMP_IN_THUNK      EQU WORKSPACE_BASE + 0x03E7  ; 4 bytes: IN dynamic trampoline (0xDB, port, 0xC9)
TRAMP_OUT_THUNK     EQU WORKSPACE_BASE + 0x03EB  ; 4 bytes: OUT dynamic trampoline (0xD3, port, 0xC9)
PLAY_AUTORUN        EQU WORKSPACE_BASE + 0x03EF  ; 1 byte: autoplay flag (0 = not yet tried, 1 = done)
CF_READ_THUNK       EQU WORKSPACE_BASE + 0x03F0  ; 3 bytes: CF per-read IN thunk (0xDB, port, 0xC9) - cf_read256
CF_WRITE_THUNK      EQU WORKSPACE_BASE + 0x03F4  ; 3 bytes: CF per-write OUT thunk (0xD3, port, 0xC9) - cf_write256
DYNAMIC_MEMTOP      EQU WORKSPACE_BASE + 0x03F7  ; 2 bytes: runtime-adjustable memory top (init = KERNEL_STACK-1)
DYNAMIC_MEMBOT      EQU WORKSPACE_BASE + 0x03F9  ; 2 bytes: runtime-adjustable memory bottom (init = USER_PROGRAM_BASE)
PLAY_HANDLE         EQU WORKSPACE_BASE + 0x03FB  ; 1 byte: PLAY command file handle (0 = inactive)
PLAY_BLOCK          EQU WORKSPACE_BASE + 0x03FC  ; 2 bytes: PLAY command current block number
PLAY_OFFSET         EQU WORKSPACE_BASE + 0x03FE  ; 2 bytes: PLAY command byte offset within block (0-511)
DISK_BUFFER         EQU WORKSPACE_BASE + 0x0400  ; disk buffer (512 bytes)
PATH_WORK_BASE      EQU WORKSPACE_BASE + 0x0600  ; pathname resolver workspace (64 bytes)
PATH_WORK_DEVNAME   EQU PATH_WORK_BASE + 0x00    ; device name scratch space (8 bytes)
PATH_WORK_PATH      EQU PATH_WORK_BASE + 0x08    ; resolved path scratch space (56 bytes)
FS_SPAN_CACHE       EQU WORKSPACE_BASE + 0x0640  ; filesystem inode span cache: 13*(FirstBlock,LastBlock) = 52 bytes
SYS_EXEC_STATE      EQU WORKSPACE_BASE + 0x0674  ; SYS_EXEC persistent state (8 bytes, safe across driver calls)
RND_SEED            EQU WORKSPACE_BASE + 0x067C  ; RND device LFSR state (2 bytes)
KERN_TEMP_SPACE     EQU WORKSPACE_BASE + 0x0700  ; 128 bytes of temporary space for kernel
WORKSPACE_END       EQU WORKSPACE_BASE + 0x0780  ; end of workspace

; sys_dev_mount temporaries (KERN_TEMP_SPACE + 86..89)
MOUNT_NAME_PTR      EQU KERN_TEMP_SPACE + 86 ; 2 bytes: name string pointer
MOUNT_SLOT_PTR      EQU KERN_TEMP_SPACE + 88 ; 2 bytes: PDT slot pointer

EXEC_RAM_START      EQU 0xF000  ; start of RAM usable for executive commands. Overwritten when user program loads.

KERNEL_STACK        EQU 0xF7F0  ; kernel/executive stack top (grows down, below workspace)
KERNEL_BASE         EQU 0x0000  ; kernel start address (ROM, window 0)

; ============================================================
; ACIA (MC6850) Console - ports from EtchedPixels RC2014 emulator
; ============================================================

ACIA_CONTROL        EQU 0x80    ; control (write) / status (read)
ACIA_DATA           EQU 0x81    ; data register

; ACIA physical device user data offsets (within PHYSDEV_OFF_DATA)
ACIA_OFF_PORT_CTRL  EQU 0       ; ACIA_CONTROL port (1 byte)
ACIA_OFF_PORT_DATA  EQU 1       ; ACIA_DATA port (1 byte)

; Control register values
ACIA_RESET          EQU 0x03    ; master reset (CR1:CR0 = 11)
ACIA_INIT           EQU 0x16    ; /64 clock, 8N1, RTS low, no interrupts
                                ; 0x16 = 0001 0110

; Status register bit masks
ACIA_RDRF           EQU 0x01    ; receive data register full (bit 0)
ACIA_TDRE           EQU 0x02    ; transmit data register empty (bit 1)

; ============================================================
; SIO/2 (Z80 SIO) Serial I/O - dual-channel UART
; ============================================================

SIO_BASE            EQU 0x80    ; SIO/2 register base port (RC2014 standard)
SIO_CTRL_A          EQU SIO_BASE + 0 ; channel A control/status
SIO_DATA_A          EQU SIO_BASE + 1 ; channel A data
SIO_CTRL_B          EQU SIO_BASE + 2 ; channel B control/status
SIO_DATA_B          EQU SIO_BASE + 3 ; channel B data

SIO_SB_CTRL_A       EQU SIO_BASE + 2 ; channel A control/status
SIO_SB_DATA_A       EQU SIO_BASE + 0 ; channel A data
SIO_SB_CTRL_B       EQU SIO_BASE + 3 ; channel B control/status
SIO_SB_DATA_B       EQU SIO_BASE + 1 ; channel B data

; SIO/2 physical device user data offsets (within PHYSDEV_OFF_DATA)
SIO_OFF_PORT_CTRL   EQU 0       ; control/status port (1 byte)
SIO_OFF_PORT_DATA   EQU 1       ; data port (1 byte)
SIO_OFF_WR4         EQU 2       ; WR4 value: clock divisor + format (1 byte)

; RR0 status register bit masks
SIO_RX_READY        EQU 0x01    ; bit 0: Rx character available
SIO_TX_EMPTY        EQU 0x04    ; bit 2: Tx buffer empty

; WR4 baud rate divisor presets (8N1: no parity, 1 stop bit)
SIO_8N1_DIV1        EQU 0x04    ; x1 clock, 1 stop bit, no parity
SIO_8N1_DIV16       EQU 0x44    ; x16 clock, 1 stop bit, no parity
SIO_8N1_DIV32       EQU 0x84    ; x32 clock, 1 stop bit, no parity
SIO_8N1_DIV64       EQU 0xC4    ; x64 clock, 1 stop bit, no parity

; ============================================================
; SCC (Z85C30) Serial I/O - dual-channel UART with built-in BRG
; ============================================================

; These SCC port numbers match Scott's board, with A/B on A0
; and control/data on A1.

SCC_BASE            EQU 0x80    ; SCC register base port (RC2014 standard)
SCC_CTRL_B          EQU SCC_BASE + 0 ; channel B control/status
SCC_DATA_B          EQU SCC_BASE + 2 ; channel B data
SCC_CTRL_A          EQU SCC_BASE + 1 ; channel A control/status
SCC_DATA_A          EQU SCC_BASE + 3 ; channel A data

; SCC physical device user data offsets (within PHYSDEV_OFF_DATA)
SCC_OFF_PORT_CTRL   EQU 0       ; control/status port (1 byte)
SCC_OFF_PORT_DATA   EQU 1       ; data port (1 byte)
SCC_OFF_WR4         EQU 2       ; WR4 value: clock divisor + format (1 byte)
SCC_OFF_BRG_TC_LO   EQU 3       ; BRG time constant low byte, WR12 (1 byte)
SCC_OFF_BRG_TC_HI   EQU 4       ; BRG time constant high byte, WR13 (1 byte)

; RR0 status register bit masks (same bit positions as SIO)
SCC_RX_READY        EQU 0x01    ; bit 0: Rx character available
SCC_TX_EMPTY        EQU 0x04    ; bit 2: Tx buffer empty

; WR4 baud rate divisor presets (8N1: no parity, 1 stop bit)
SCC_8N1_DIV1        EQU 0x04    ; x1 clock, 1 stop bit, no parity
SCC_8N1_DIV16       EQU 0x44    ; x16 clock, 1 stop bit, no parity
SCC_8N1_DIV32       EQU 0x84    ; x32 clock, 1 stop bit, no parity
SCC_8N1_DIV64       EQU 0xC4    ; x64 clock, 1 stop bit, no parity

; WR11: clock source = BRG for both Rx and Tx
SCC_WR11_BRG        EQU 0x50    ; D7=0 (ext osc), D6:5=10 (Rx=BRG), D4:3=10 (Tx=BRG)

; WR14: BRG control (bit 1: 0=RTxC, 1=PCLK; bit 0: BRG enable)
SCC_WR14_BRG_SRC    EQU 0x00    ; BRG source = RTxC, BRG disabled
SCC_WR14_BRG_ENA    EQU 0x01    ; BRG source = RTxC, BRG enabled

; BRG time constant presets for 7.3728 MHz RTxC, x16 clock mode
; TC = RTxC / (2 * 16 * baud) - 2
SCC_TC_115200       EQU 0       ; 7372800 / (32 * 115200) - 2 = 0
SCC_TC_57600        EQU 2       ; 7372800 / (32 * 57600)  - 2 = 2
SCC_TC_38400        EQU 4       ; 7372800 / (32 * 38400)  - 2 = 4
SCC_TC_19200        EQU 10      ; 7372800 / (32 * 19200)  - 2 = 10
SCC_TC_9600         EQU 22      ; 7372800 / (32 * 9600)   - 2 = 22

; ============================================================
; Z180 ASCI (built-in serial) - dual-channel UART
; Internal I/O is remapped from default 0x00 to 0xC0 via ICR,
; freeing ports 0x00-0x3E for external devices (e.g. VFD).
; ============================================================

Z180_IO_BASE        EQU 0xC0    ; Z180 internal I/O base (remapped from 0x00)
Z180_ICR            EQU 0x3F    ; I/O Control Register (always at 0x3F, never remapped)

Z180_CNTLA0         EQU Z180_IO_BASE + 0x00 ; control register A, channel 0
Z180_CNTLA1         EQU Z180_IO_BASE + 0x01 ; control register A, channel 1
Z180_CNTLB0         EQU Z180_IO_BASE + 0x02 ; control register B, channel 0
Z180_CNTLB1         EQU Z180_IO_BASE + 0x03 ; control register B, channel 1
Z180_STAT0          EQU Z180_IO_BASE + 0x04 ; status register, channel 0
Z180_STAT1          EQU Z180_IO_BASE + 0x05 ; status register, channel 1
Z180_TDR0           EQU Z180_IO_BASE + 0x06 ; transmit data register, channel 0
Z180_TDR1           EQU Z180_IO_BASE + 0x07 ; transmit data register, channel 1
Z180_RDR0           EQU Z180_IO_BASE + 0x08 ; receive data register, channel 0
Z180_RDR1           EQU Z180_IO_BASE + 0x09 ; receive data register, channel 1
Z180_ASEXT0         EQU Z180_IO_BASE + 0x12 ; ASCI extension register, channel 0
Z180_ASEXT1         EQU Z180_IO_BASE + 0x13 ; ASCI extension register, channel 1
Z180_CMR            EQU Z180_IO_BASE + 0x1E ; clock multiplier register
Z180_CCR            EQU Z180_IO_BASE + 0x1F ; CPU control register (clock divide)

; Z180 ASCI PDT user data: byte 0 = channel number (0 or 1).
; All register ports are computed at runtime as Z180_xxxN + channel.

; STAT register bit masks
Z180_RDRF           EQU 0x80    ; bit 7: receive data register full
Z180_TDRE           EQU 0x02    ; bit 1: transmit data register empty
Z180_OVRN           EQU 0x40    ; bit 6: overrun error

; CNTLA register bits
Z180_CNTLA_RE       EQU 0x40    ; bit 6: receiver enable
Z180_CNTLA_TE       EQU 0x20    ; bit 5: transmitter enable
Z180_CNTLA_8N1      EQU 0x64    ; 8 data bits, no parity, 1 stop, Rx+Tx enable
                                ; bits: 0_1_1_0_0_1_0_0
                                ; bit7=MPE off, bit6=RE, bit5=TE, bit4=RTS0 low
                                ; bit3=EFR off, bit2=8-bit, bit1:0=no parity/1 stop

; ASEXT register: ASCI extension control
; Default 0x60: disable CTS0 and DCD0 flow control (ch0 only).
; Without this, transmitter is blocked if CTS0/DCD0 not asserted.
Z180_ASEXT_INIT     EQU 0x60    ; bit6=DCD0 disable, bit5=CTS0 disable

; CNTLB register: baud rate prescaler, divide ratio, and speed select
; Bits: MPBT(7) | MP(6) | PS(5) | PEO(4) | DR(3) | SS2(2) | SS1(1) | SS0(0)
; Baud = PHI / (PS_div * DR_div * SS_div)
;   PS  (bit 5):   0 = /10,  1 = /30
;   DR  (bit 3):   0 = /16,  1 = /64
;   SS  (bits 2:0): 000=/1, 001=/2, 010=/4, 011=/8, 100=/16, 101=/32, 110=/64
; At 18.432 MHz (total divisor = 18432000 / baud):
;   115200: 160 = 10*16*1  → PS=0, DR=0, SS=000 → 0x00
;    57600: 320 = 10*16*2  → PS=0, DR=0, SS=001 → 0x01
;    38400: 480 = 30*16*1  → PS=1, DR=0, SS=000 → 0x20
;    19200: 960 = 30*16*2  → PS=1, DR=0, SS=001 → 0x21
;     9600: 1920 = 30*64*1 → PS=1, DR=1, SS=000 → 0x28
Z180_BAUD_115200    EQU 0x00    ; PS=0, DR=0, SS=0 → 10*16*1=160
Z180_BAUD_57600     EQU 0x01    ; PS=0, DR=0, SS=1 → 10*16*2=320
Z180_BAUD_38400     EQU 0x20    ; PS=1, DR=0, SS=0 → 30*16*1=480
Z180_BAUD_19200     EQU 0x21    ; PS=1, DR=0, SS=1 → 30*16*2=960
Z180_BAUD_9600      EQU 0x28    ; PS=1, DR=1, SS=0 → 30*64*1=1920

; ============================================================
; CompactFlash / IDE - ports from EtchedPixels RC2014 emulator
; ============================================================

CF_BASE             EQU 0x10    ; CF register base port

CF_DATA             EQU CF_BASE + 0 ; data register
CF_ERROR            EQU CF_BASE + 1 ; error register (read)
CF_FEATURES         EQU CF_BASE + 1 ; features register (write)
CF_SECTOR_COUNT     EQU CF_BASE + 2 ; sector count
CF_SECTOR_NUM       EQU CF_BASE + 3 ; LBA bits 0-7
CF_CYL_LOW          EQU CF_BASE + 4 ; LBA bits 8-15
CF_CYL_HIGH         EQU CF_BASE + 5 ; LBA bits 16-23
CF_HEAD             EQU CF_BASE + 6 ; LBA bits 24-27, device select
CF_STATUS           EQU CF_BASE + 7 ; status (read)
CF_COMMAND          EQU CF_BASE + 7 ; command (write)

; CompactFlash physical device user data offsets (within PHYSDEV_OFF_DATA)
CF_OFF_LBA          EQU 0       ; LBA (4 bytes)
CF_OFF_PORT_DATA    EQU 4       ; CF_DATA port (1 byte)
CF_OFF_PORT_FEAT    EQU 5       ; CF_FEATURES/CF_ERROR port (1 byte)
CF_OFF_PORT_SECCNT  EQU 6       ; CF_SECTOR_COUNT port (1 byte)
CF_OFF_PORT_SECNUM  EQU 7       ; CF_SECTOR_NUM port (1 byte)
CF_OFF_PORT_CYLLOW  EQU 8       ; CF_CYL_LOW port (1 byte)
CF_OFF_PORT_CYLHI   EQU 9       ; CF_CYL_HIGH port (1 byte)
CF_OFF_PORT_HEAD    EQU 10      ; CF_HEAD port (1 byte)
CF_OFF_PORT_STATUS  EQU 11      ; CF_STATUS/CF_COMMAND port (1 byte)

; Status register bit masks
CF_BUSY             EQU 0x80    ; device busy
CF_DRDY             EQU 0x40    ; device ready
CF_DRQ              EQU 0x08    ; data request
CF_ERR              EQU 0x01    ; error

; Commands
CF_CMD_READ         EQU 0x20    ; read sector(s) with retry
CF_CMD_WRITE        EQU 0x30    ; write sector(s) with retry
CF_CMD_IDENTIFY     EQU 0xEC    ; identify device

; Head register: LBA mode, device 0
CF_HEAD_LBA         EQU 0xE0    ; LBA mode, device 0 (1110 0000)

; ============================================================
; WD37C65 Floppy Disk Controller - hardcoded ports
; ============================================================

FDC_PORT_MSR        EQU 0x50    ; Main Status Register (read)
FDC_PORT_DATA       EQU 0x51    ; Data Register (read/write)
FDC_PORT_DOR        EQU 0x58    ; Digital Output Register (write)
FDC_PORT_DCR        EQU 0x48    ; Configuration Control Register (write)

; MSR bit masks
FDC_MSR_RQM         EQU 0x80    ; bit 7: Request for Master (ready for byte transfer)
FDC_MSR_DIO         EQU 0x40    ; bit 6: Data direction (1=FDC->CPU, 0=CPU->FDC)
FDC_MSR_EXM         EQU 0x20    ; bit 5: Execution Mode (data transfer in progress)
FDC_MSR_CB          EQU 0x10    ; bit 4: Controller Busy

; FDC commands (MFM mode)
FDC_CMD_READ        EQU 0x46    ; Read Data (MT=0, MF=1, SK=0)
FDC_CMD_WRITE       EQU 0x45    ; Write Data (MT=0, MF=1, SK=0)
FDC_CMD_RECAL       EQU 0x07    ; Recalibrate
FDC_CMD_SEEK        EQU 0x0F    ; Seek
FDC_CMD_SENSE_INT   EQU 0x08    ; Sense Interrupt Status
FDC_CMD_SPECIFY     EQU 0x03    ; Specify (step rate, head times)

; DOR bit masks
FDC_DOR_DMAGATE     EQU 0x08    ; bit 3: DMA/IRQ gate enable
FDC_DOR_RESET       EQU 0x04    ; bit 2: /RESET (1=normal, 0=reset)

; Specify command parameters (500kbps, ~7.3 MHz clock)
; Byte 1: (SRT << 4) | HUT.  SRT=0xD (3ms step rate), HUT=0xF (240ms head unload)
; Byte 2: (HLT << 1) | ND.   HLT=0x08 (16ms head load), ND=1 (non-DMA mode)
; Per RomWBW: HLT=16ms matches IBM spec; SRT=3ms is standard for HD drives.
FDC_SPECIFY_BYTE1   EQU 0xDF
FDC_SPECIFY_BYTE2   EQU 0x11

; FDC PDT user data offsets (within PHYSDEV_OFF_DATA)
FDC_OFF_LBA         EQU 0       ; current LBA position (2 bytes, little-endian)
FDC_OFF_DRIVE       EQU 2       ; drive number, 0-3 (1 byte)
FDC_OFF_SPT         EQU 3       ; sectors per track (1 byte)
FDC_OFF_HEADS       EQU 4       ; number of heads, 1 or 2 (1 byte)
FDC_OFF_SECSIZE     EQU 5       ; sector size code: 2=512 (1 byte)
FDC_OFF_CYLINDERS   EQU 6       ; total cylinders (1 byte)
FDC_OFF_GPL         EQU 7       ; gap length for read/write (1 byte)
FDC_OFF_DATARATE    EQU 8       ; DCR data rate: 0=500k, 1=300k, 2=250k (1 byte)
FDC_OFF_CUR_CYL     EQU 9       ; current cylinder, runtime (1 byte)
FDC_OFF_MOTOR       EQU 10      ; motor state, runtime: 0=off, 1=on (1 byte)
FDC_OFF_TGT_CYL     EQU 11      ; target cylinder for current I/O (1 byte)
FDC_OFF_TGT_HEAD    EQU 12      ; target head for current I/O (1 byte)
FDC_OFF_TGT_SECTOR  EQU 13      ; target sector for current I/O (1 byte, 1-based)

; ============================================================
; Workspace Dimensions
; ============================================================

LOGDEV_ENTRY_SIZE   EQU 8       ; bytes per logical device entry
LOGDEV_MAX          EQU 16      ; max entries in logical device table

PHYSDEV_ENTRY_SIZE  EQU 32      ; bytes per physical device entry
PHYSDEV_MAX         EQU 16      ; max entries in RAM physical device table

; ============================================================
; Executive Command Descriptor offsets
; Each entry (16 bytes total):
;   3 bytes: short-name (null-terminated, max 2 chars + null)
;   7 bytes: name       (null-terminated, max 6 chars + null)
;   2 bytes: function pointer
;   2 bytes: description string pointer
;   2 bytes: next entry pointer (0 = end of list)
; ============================================================
CMDESC_ENTRY_SIZE    EQU 16     ; bytes per command descriptor
CMDESC_OFF_SHORTNAME EQU 0      ; short-name field (3 bytes, null-terminated)
CMDESC_OFF_NAME      EQU 3      ; name field (7 bytes, null-terminated)
CMDESC_OFF_FN        EQU 10     ; function pointer (2 bytes)
CMDESC_OFF_DESC      EQU 12     ; description pointer (2 bytes)
CMDESC_OFF_NEXT      EQU 14     ; next pointer (2 bytes, 0 = end of list)

; Offsets within a physical device table entry
PHYSDEV_OFF_NEXT    EQU 0       ; next pointer (2 bytes)
PHYSDEV_OFF_ID      EQU 2       ; physical device ID (1 byte)
PHYSDEV_OFF_NAME    EQU 3       ; short ASCII name (7 bytes, null-terminated)
PHYSDEV_OFF_CAPS    EQU 10      ; device capabilities (1 byte)
PHYSDEV_OFF_PARENT  EQU 11      ; parent device physical ID (1 byte)
PHYSDEV_OFF_CHILD   EQU 12      ; child device physical ID (1 byte)
PHYSDEV_OFF_DFT     EQU 13      ; device function table pointer (2 bytes)
PHYSDEV_OFF_DATA    EQU 15      ; user data (17 bytes)

; DFT slot counts by device class
DFT_SLOT_COUNT_CHAR   EQU 4    ; char DFT: Initialize, GetStatus, ReadByte, WriteByte
DFT_SLOT_COUNT_SCREEN EQU 8    ; screen DFT: char slots + ClearScreen, SetCursor, GetCursor, SetAttr
DFT_SLOT_COUNT_BLOCK  EQU 9    ; block DFT: Initialize, GetStatus, ReadBlock, WriteBlock, Seek, GetPosition, GetLength, SetSize, Close
DFT_SLOT_COUNT_FS     EQU 12   ; fs DFT: Initialize, GetStatus, CreateFile, OpenFile, CreateDir, OpenDir, Rename, Remove, SetAttributes, GetAttributes, (reserved), FreeCount

; Function pointer slot indices within a DFT
FNIDX_INITIALIZE    EQU 0       ; Initialize
FNIDX_GETSTATUS     EQU 1       ; GetStatus
FNIDX_READBYTE      EQU 2       ; ReadByte  (character devices)
FNIDX_WRITEBYTE     EQU 3       ; WriteByte (character devices)

FNIDX_READBLOCK     EQU 2       ; ReadBlock (block devices)
FNIDX_WRITEBLOCK    EQU 3       ; WriteBlock (block devices)
FNIDX_SEEK          EQU 4       ; Seek (block devices)
FNIDX_GETPOSITION   EQU 5       ; GetPosition (block devices)
FNIDX_GETLENGTH     EQU 6       ; GetLength (block devices)
FNIDX_SETSIZE       EQU 7       ; SetSize (block devices)
FNIDX_CLOSE         EQU 8       ; Close (block devices)

FNIDX_CLEARSCREEN   EQU 4       ; ClearScreen (screen devices)
FNIDX_SETCURSOR     EQU 5       ; SetCursorPosition (screen devices)
FNIDX_GETCURSOR     EQU 6       ; GetCursorPosition (screen devices)
FNIDX_SETATTR       EQU 7       ; SetAttribute (screen devices)

FNIDX_CREATEFILE    EQU 2       ; CreateFile (filesystem devices)
FNIDX_OPENFILE      EQU 3       ; OpenFile (filesystem devices)
FNIDX_CREATEDIR     EQU 4       ; CreateDirectory (filesystem devices)
FNIDX_OPENDIR       EQU 5       ; OpenDirectory (filesystem devices)
FNIDX_RENAME        EQU 6       ; Rename (filesystem devices)
FNIDX_REMOVE        EQU 7       ; Remove (filesystem devices)
FNIDX_SETFATTR      EQU 8       ; SetAttributes (filesystem devices)
FNIDX_GETFATTR      EQU 9       ; GetAttributes (filesystem devices)
FNIDX_FREECOUNT     EQU 11      ; FreeCount (filesystem devices)

; Offsets within a logical device table entry
LOGDEV_OFF_ID       EQU 0       ; logical device ID (1 byte)
LOGDEV_OFF_NAME     EQU 1       ; short ASCII name (5 bytes, null-terminated, max 4 chars)
LOGDEV_OFF_PHYSPTR  EQU 6       ; pointer to physical device entry (2 bytes)

; ============================================================
; Device Capability Bits
; ============================================================

DEVCAP_CHAR_IN      EQU 0x01    ; bit 0: character input
DEVCAP_CHAR_OUT     EQU 0x02    ; bit 1: character output
DEVCAP_BLOCK_IN     EQU 0x04    ; bit 2: block input
DEVCAP_BLOCK_OUT    EQU 0x08    ; bit 3: block output
DEVCAP_FILESYSTEM   EQU 0x10    ; bit 4: filesystem
DEVCAP_SUBDIRS      EQU 0x20    ; bit 5: filesystem supports subdirectories
DEVCAP_SCREEN       EQU 0x40    ; bit 6: screen device
DEVCAP_HANDLE       EQU 0x80    ; bit 7: open file/dir handle (closeable pseudo-device)

; ============================================================
; Device Identifiers
; ============================================================
; Top bit 0 = physical device, top bit 1 = logical device.
; When passing a device ID to syscalls via register B:
;   0x00-0x7F: physical device ID
;   0x80-0xFF: logical device (index = value & 0x7F)

; Physical device IDs (ROM-resident devices)
PHYSDEV_ID_NUL      EQU 0x01    ; null device
PHYSDEV_ID_ACIA     EQU 0x02    ; ACIA console
PHYSDEV_ID_CF       EQU 0x03    ; CompactFlash block device
PHYSDEV_ID_UNUSED4  EQU 0x04    ; reserved (unused)
PHYSDEV_ID_ROMD     EQU 0x05    ; romdisk block device
PHYSDEV_ID_RAMD     EQU 0x06    ; ramdisk block device
PHYSDEV_ID_SIOA     EQU 0x07    ; SIO/2 channel A
PHYSDEV_ID_SIOB     EQU 0x08    ; SIO/2 channel B
PHYSDEV_ID_Z180A    EQU 0x09    ; Z180 ASCI channel 0
PHYSDEV_ID_Z180B    EQU 0x0A    ; Z180 ASCI channel 1
PHYSDEV_ID_SCCA     EQU 0x0B    ; SCC channel A
PHYSDEV_ID_SCCB     EQU 0x0C    ; SCC channel B
PHYSDEV_ID_FDC      EQU 0x0D    ; WD37C65 floppy disk controller
PHYSDEV_ID_RND      EQU 0x0E    ; random number character device
PHYSDEV_ID_BBL      EQU 0x0F    ; 7220 bubble memory block device
PHYSDEV_ID_UN       EQU 0xFF    ; unassigned device
; RAM-allocated open file/dir handles start at 0x10
PHYSDEV_ID_FILE0    EQU 0x10

; Ramdisk/romdisk PDT user-data offsets (relative to start of user-data field)
RD_OFF_START_PAGE   EQU 0       ; 1 byte: first page of disk
RD_OFF_END_PAGE     EQU 1       ; 1 byte: last page of disk (inclusive)
RD_OFF_CUR_BLOCK    EQU 2       ; 2 bytes: current block position (little-endian)
RD_BLOCKS_PER_PAGE  EQU 32      ; 16KB page / 512B block = 32 blocks per page

; Tiny ramdisk/romdisk PDT user-data offsets (no mapper, direct memory access)
TRD_OFF_START_ADDR  EQU 0       ; 2 bytes: base address of disk in memory (LE)
TRD_OFF_LENGTH      EQU 2       ; 2 bytes: total size in bytes (LE)
TRD_OFF_CUR_BLOCK   EQU 4       ; 2 bytes: current block position (LE)

; Logical device IDs — see src/include/syscall.asm (LOGDEV_ID_*)

; ============================================================
; Filesystem Signature
; ============================================================

FS_SIG_0            EQU 0x53    ; 'S'
FS_SIG_1            EQU 0x43    ; 'C'
FS_SIG_2            EQU 0x4F    ; 'O'
FS_SIG_3            EQU 0x54    ; 'T'
FS_DEFAULT_BLOCK_SIZE EQU 512

; ============================================================
; Directory Entry Structure (32 bytes)
; Returned by DEV_BREAD on an open directory handle.
; ============================================================
DIRENT_OFF_TYPE     EQU 0       ; Type flags (1 byte)
DIRENT_OFF_NAME     EQU 1       ; Name (17 bytes, null-terminated)
DIRENT_OFF_SIZE     EQU 18      ; File size (4 bytes, little-endian)
DIRENT_OFF_MTIME    EQU 22      ; Modification time (4 bytes)
DIRENT_OFF_ATTR     EQU 26      ; Attributes (1 byte)
DIRENT_OFF_OWNER    EQU 27      ; Owner (1 byte)
DIRENT_OFF_INODE    EQU 28      ; Inode block number (2 bytes)
DIRENT_OFF_UNUSED   EQU 30      ; Unused (2 bytes)
DIRENT_SIZE         EQU 32      ; Total entry size

DIRENT_TYPE_USED    EQU 0x80    ; Bit 7: entry is in use
DIRENT_TYPE_DIR     EQU 0x40    ; Bit 6: entry is a directory

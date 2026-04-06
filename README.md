# NostOS: The Nostalgia Operating System

Scott Baker, https://www.smbaker.com/

## What is NostOS?

NostOS is an operating system designed for the RC2014 and similar Z80 or 8080 based computers. NostOS
was meant to invoke the nostalgia of operating systems of years past such as CP/M or HDOS, while at
the same time being a completely new effort. NostOS is not compatible with CP/M binaries or disks. To
the contrary, it's intentionally incompatible, being a new and unique operating system.

For in-depth information about NostOS, read the [specification](specification/README.md).

## NostOS natively supports the following hardware:

* Z80, 8080, or 8085 CPU. Only Z80 is tested at the moment, but the code is written to be compliant
  with the 8080 instruction set only.

* Common serial devices including ACIA, SIO/2, SCC, and Z180-ASCI.

* Floppy drives using the WD37C65 floppy controller.

* CompactFlash Devices.

* Intel Bubble Memory devices.

* ROM and RAM disks.

Extension drivers can be loaded at runtime to support additional hardware:

* VFD and LCD displays.

* SP0256A-AL2 speech synthesizer with built-in text-to-speech capabilities.

NostOS is intended to be **rommable** and it is even expected that it will be burned to ROM. It
requires no physical storage device to operate.

NostOS may use a **512KB ROM/RAM banked configuration** similar to many RC2014 and SBC designs
including the Zeta2 and Grant Searle's SBC, or NostOS may use a simpler non-banked design
based on **32KB of RAM and 32KB of EPROM**. Other configurations may also be possible.

## NostOS devices

NostOS supports a flexible device model, featuring both logical and physical devices. Logical
devices allow reassignment. For example, it's trivial to reassign the console output (CONO:)
device to a different output device. An extension called DUP allows you to duplicate
output across two devices. For example, you can send console output to both the TTS: text
to speech device and your ACIA: UART at the same time.

The NostOS device model is intended to be extended at runtime. You can easily load an extension
in a TSR manner that adds a new physical or logical device.

## The NostOS executive

The executive is the built-in command line interpreter. It resides in ROM alongside
the NostOS kernel, assembled as a single 16KB image. It features the following commands:

* HP / HELP   - Display help text
* IN / INFO   - Display system information
* HT / HALT   - Execute HALT instruction
* LL / LISTL  - List logical devices
* LP / LISTP  - List physical devices
* AS / ASSIGN - Assign logical device to physical device
* CD / CHDIR  - Change directory
* LD / DIR    - List directory
* MD / MKDIR  - Make directory
* RD / RMDIR  - Remove directory
* CF / COPY   - Copy file
* RF / DELETE - Delete file
* NF / RENAME - Rename file
* LF / TYPE   - Display file contents
* HF / HEXDMP - Display file as hex dump
* MT / MOUNT  - Mount filesystem device on block device
* ST / STAT   - Display file status and block map
* #  / REMARK - Remark (comment line, ignored)
* SM / SUM    - SYSV checksum
* FR / FREE   - Display free block count
* PL / PLAY   - Execute commands from a script file

## Software

### Native Applications

* APPEND. Append text to an existing file.
* DEBUG. A tool for examining and changing memory.
* ED. The NostOS line editor.
* FDINIT. For low-level formatting floppy disks.
* FORMAT. For formatting new disk volumes.
* HEAD, TAIL, MORE, WC. The usual Unix-like text utilities.
* XSEND, XRECV. XModem sender and receiver.

### Native Games

* CHESS. A chess game, though I have to warn you the computer is not very good.
* ELIZA. The AI therapist from the 1980s.
* LIFE. Conway's Game of Life.
* MAZE. A maze generator.
* PACMAN. Classic Pacman game.
* STARTREK. Classic Star Trek game.
* TETRIS. Classic Tetris game.

### Ported third-party applications

* Nascom Basic, from the RC2014 port.
* Fig-Forth.
* Zealasm, an 8-bit assembler.
* Zork, the classic adventure by Infocom.

## NostOS user programs

NostOS supports loading user programs. All user programs include relocation data so they
may be used seamlessly across 32K or 512K NostOS variants, and they automatically adapt
to memory changes due to TSR extensions being loaded.

## Build Outputs

The build produces several ROM images, each tailored to a specific UART, block
device, and memory configuration. The 16KB raw kernel images live in `build/`,
and the final flashable ROM images live in `build/rom/`.

### Flashable ROM images (`release/<versio>/`)

These are the final images you would burn to an EPROM (or load into the emulator).
Each combines a kernel image with a starter disk.

#### 512KB banked production images (16KB kernel + production disk)

| File | Serial | Block device |
|------|--------|--------------|
| `nostos-prod-acia-512k.rom` | 6850 ACIA | CompactFlash |
| `nostos-prod-sio-512k.rom` | Z80 SIO/2 | CompactFlash |
| `nostos-prod-sio-sb-512k.rom` | Z80 SIO/2 (SCC) | CompactFlash |
| `nostos-prod-z180-512k.rom` | Z180 ASCI | CompactFlash |
| `nostos-prod-scc-512k.rom` | Z85C30 SCC | CompactFlash |
| `nostos-prod-acia-fdc-512k.rom` | 6850 ACIA | WD37C65 floppy |

#### 32KB non-banked production images (32K RAM + 32K EPROM)

| File | Serial | Block device |
|------|--------|--------------|
| `nostos-prod-acia-32k.rom` | 6850 ACIA | Bubble memory |
| `nostos-prod-acia-32k-bothbank.rom` | 6850 ACIA | Bubble memory (image duplicated for W27C512) |
| `nostos-prod-scc-bub-32k.rom` | Z85C30 SCC | Bubble memory |
| `nostos-prod-scc-bub-32k-bothbank.rom` | Z85C30 SCC | Bubble memory (image duplicated for W27C512) |

#### 512KB testing images (16KB kernel + test disk)

These are used by `make test`. They contain a different starter disk than the
production images.

| File | Serial | Block device |
|------|--------|--------------|
| `nostos-testing-acia-512k.rom` | 6850 ACIA | CompactFlash |
| `nostos-testing-acia-fdc-512k.rom` | 6850 ACIA | WD37C65 floppy |

## I/O Port Map

NostOS uses the following I/O port assignments. Most match RC2014 standard
addressing where applicable.

| Port(s) | Device | Notes |
|---------|--------|-------|
| 0x00–0x03 | VFD/LCD display *(extension)* | HD44780-style, two controllers; default base, configurable |
| 0x10 | Bubble memory data FIFO | Intel 7220 BMC (32K ROM variants) |
| 0x11 | Bubble memory command/status | Intel 7220 BMC |
| 0x10–0x17 | CompactFlash | 8-register IDE/CF interface (RC2014 standard) |
| 0x20 | SP0256A-AL2 speech *(extension)* | Default port, configurable |
| 0x3F | Z180 ICR | I/O Control Register (Z180 only, never remapped) |
| 0x48 | WD37C65 DCR | Floppy Configuration Control Register (write) |
| 0x50 | WD37C65 MSR | Floppy Main Status Register (read) |
| 0x51 | WD37C65 Data | Floppy Data Register (read/write) |
| 0x58 | WD37C65 DOR | Floppy Digital Output Register (write) |
| 0x78 | Memory mapper window 0 | Set page for 0x0000–0x3FFF |
| 0x79 | Memory mapper window 1 | Set page for 0x4000–0x7FFF |
| 0x7A | Memory mapper window 2 | Set page for 0x8000–0xBFFF |
| 0x7B | Memory mapper window 3 | Set page for 0xC000–0xFFFF |
| 0x7C | Memory mapper enable | Write 1 to enable banking |
| 0x80–0x81 | 6850 ACIA | Control/status (0x80), data (0x81) |
| 0x80–0x83 | Z80 SIO/2 | Channels A/B control and data |
| 0x80–0x83 | Z85C30 SCC | Channels A/B control and data |
| 0xC0–0xDF | Z180 internal I/O | ASCI, timers, etc. (remapped from 0x00 via ICR) |

Note that ACIA, SIO/2, and SCC share the same base port (0x80) — only one
serial chip is configured per ROM variant. Likewise, bubble memory and
CompactFlash share port 0x10; only one block device is configured per ROM.

## For more information

For in-depth information about NostOS, read the [specification](specification/README.md).

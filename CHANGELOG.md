# Changelog

All notable changes to this project will be documented in this file.

## NostOS 1.2.0

### Z180 MMU as a memory-mapper option

NostOS's existing 4-window 16KB mapper (`74HCT670`-style, controlled
via I/O ports `0x78`-`0x7C`) requires external glue that SC131-class
boards do not have.  The Z180 has its own internal MMU that can do
the same job using the CPU's built-in `BBR`/`CBR`/`CBAR` registers,
freeing the mapper-control ports and the discrete chip.

- New `mapper_config.asm` dispatcher selects one of three back-end
  mapper files at assembly time based on a build flag:
  `mapper_74hct670.asm` (default), `mapper_z180_mmu.asm`
  (`-DMAPPER_Z180_MMU`), or `mapper_none.asm` (`-DMAPPER_NONE`,
  for 32K builds with no banking at all).
- The kernel and `ramdisk.asm` no longer contain mapper-specific
  port writes.  They use `MAPPER_INIT`, `MAPPER_REMAP_BANK`, and
  `MAPPER_RESTORE_BANK` macros that expand per-mapper.
- Layout (Z180): Common 0 = ROM `0x0000-0x3FFF` (identity),
  Bank = `0x4000-0xBFFF` (paged ramdisk window), Common 1 =
  `0xC000-0xFFFF` (kernel RAM, never disturbed by a page swap).
  Matches the 74HCT670 layout exactly so workspace/stack constants
  don't move.
- `ramdisk.asm`'s page-swap critical section now inlines the
  512-byte copy.  The previous `CALL rd_copy_512` would have
  pushed a return address into whatever page was currently mapped
  — a latent issue under the 74HCT670 mapper that became unsafe
  under the Z180 MMU because the entire Bank gets remapped.
- New ROM variants: `nostos-prod-z180-mmu-int-cf-512k`,
  `nostos-prod-z180-mmu-int-fdc-512k`,
  `nostos-prod-z180-mmu-int-sdcard-512k`.

### SD card driver (SC131)

New SPI block-device driver at `src/drivers/sd.asm` for the SD
card slot on the SC131 and similar Z180-MMU boards that lack CF
or FDC storage.  Both SDSC and SDHC/SDXC cards are supported.

- Z180 CSI/O hardware SPI (`-DSD_USE_CSIO`).  Slow-then-fast clock
  scheduling matches RomWBW: ~14.4 kHz during init, ~921 kHz for
  block transfers.  Chip-select bit drives the SC131's 74HCT259
  latch at port `0x0C`.  CSI/O is LSB-first while SD is MSB-first,
  so every byte gets bit-mirrored at the wire boundary.
- Bit-bang scaffolding (`-DSD_USE_BITBANG`) for the SC611 RCBus
  module — code paths exist but no bootstrap wires it up yet.
- Each init command (CMD0, CMD8, CMD55, ACMD41, CMD58) runs in
  its own CS-bounced transaction with leading/trailing 0xFF
  dummies.  Many cards require this to clock out their response
  state machine before accepting the next command.
- Card type is detected from the CMD58 OCR `CCS` bit and stored
  in the device's PDT user data.  `sd_setup_address` translates
  LBA→byte address (×512) for SDSC; SDHC/SDXC use blocks as-is.
- `sd_check_init` retries init on every read/write call when the
  card type is still `NONE` so a card inserted after boot, or a
  card that needed more wake-up time than was available during
  `devices_init`, becomes usable on first I/O.
- Optional hardware-debug diagnostics gated on `-DSD_DEBUG`: emits
  `SD<phase> <hex(R1)>\r\n` on each init/IO failure phase.  Off by
  default — production boots stay quiet when no card is present.
- New ROM variant: `nostos-prod-z180-mmu-int-sdcard-512k` (Z180
  ASCI interrupt-driven UART + Z180 MMU + SD card; intended for
  the SC131).

### DIR file size for files >= 64 KB

The `DIR` (`LD`) command read only the low 16 bits of the
4-byte file size from the directory entry, silently truncating
any file >= 64 KB.  A 84992-byte file would display as 19456.

- New shared helper `exec_print_dec32` / `exec_print_dec32_w6` in
  `format.asm` (the latter pads to 6 chars to match the legacy
  16-bit column for files < 1 MB and overflows the column for
  larger files).  `cmd_ld` now reads the full 32-bit size and
  uses the new printer.
- `cmd_free` was updated to call into the shared helper rather
  than carry its own private 32-bit decimal printer.
- New regression test `dir_largefile` exercises the 32-bit path
  by creating a > 64 KB file with `RANDDATA` + `APPEND` and
  verifying the DIR output.

### CRLF handling

The kernel's line reader (`sys_dev_cread_str`) previously treated both CR
(0x0D) and LF (0x0A) as line terminators.  This was incorrect for any
client that sends CRLF for Enter (telnet, pasted Windows-line-ending text,
some terminal emulators): the CR terminated the line correctly, but the
trailing LF was then read as the first byte of the next line, producing a
phantom empty line at every prompt.

- `sys_dev_cread_str` now treats CR as the line terminator and silently
  drops LF.  Drivers (`DEV_CREAD_RAW` / `_dev_cread_byte`) remain
  byte-faithful — XMODEM and other binary protocols depend on raw
  pass-through.

- The same bug existed in `ed`'s `ed_getline` and is fixed.

- `eliza`'s `el_read_line` previously stored a stray LF in its input
  buffer; LF is now dropped silently.

- Forth's `EXPECT` has the same shape of issue but is left as-is — see
  `KNOWN-ISSUES.md`.  fig-FORTH dates to 1979 when terminals sent
  CR-only for Enter, so the path is unreachable in normal serial use.

- `basic` (`TTYLIN`) and `zork` (`READBF`) were already correct: both
  filter sub-0x20 bytes during line entry, which catches LF.

- Applications that use `DEV_CREAD_STR` directly (`startrek`, `chess`,
  `debug`) inherit the kernel fix automatically.

### 8080 instruction-set conformance

A second sweep through the codebase removed remaining Z80-only
instructions, bringing the entire system (kernel, executive, drivers,
and all bundled applications) into strict 8080 compatibility.  This
makes NostOS portable to 8085-based hardware without source changes.

- `basic.app` was the last holdout.  ED-prefix loads
  (`LD DE,(nn)`, `LD BC,(nn)`, `LD (nn),DE`) and `LDI` byte copies were
  replaced with three helper subroutines (`MVFPBC`, `MVBCFP`, `MOVFP4`)
  that preserve the A register and flags as the original Z80 sequences
  did.  Preserving A is load-bearing: `SUMSER` drives its coefficient
  loop on A through `MOVFP4`, so every series-based transcendental
  (LOG, EXP, SIN, COS, TAN, ATN, SQR, `^`) depends on it.

- A latent bug in `HLOAD` (Intel HEX loader) was found during the sweep:
  a missing second `EX DE,HL` clobbered the target RAM address before
  the data-read loop.  Fixed.

- `basic_torture` now exercises LOG, EXP, SIN, COS, TAN, ATN, SQR, RND,
  and the `^` operator with tolerance-based comparisons, catching
  transcendental regressions that would otherwise slip past byte-exact
  goldens.

- `basic.app` shrank from 12011 to 11929 bytes.

- All other apps (`apps/native/`, `apps/extensions/`, `apps/3rdparty/`)
  had been converted in the prior pass; no further code changes were
  needed there in this release.

### Terminal program

New `term.app` provides bidirectional dumb-terminal access to any
character device by name (`TERM SIO`, `TERM NET0`, etc.).  Raw
passthrough both ways via polled `DEV_STAT` + `DEV_CREAD_RAW` +
`DEV_CWRITE`; Ctrl-X exits and Ctrl-A is an escape prefix for echo
toggle, hex display, a dialing directory loaded from `TERM.DIR` in
the CWD (`Ctrl-A D`), and modem hangup (`Ctrl-A H`, sends `+++ATH<CR>`
with guard delays).  Also adds Scott's pico networking board:
`NETA`/`NETB` PDT entries at port 0x84, with `PHYSDEV_ID_FILE0`
shifted from 0x10 to 0x20 to free those IDs.

### Zork ring-buffer overflow

Zork produced garbage at the prompt under interrupt-driven UART builds
but was clean under polled drivers.  Its `START3` page-cache sizer
approximated `(MEMTOP - PGBUFP) / 512` using only the high bytes,
which could round up one extra 512-byte page past `SYS_MEMTOP`.  In
polled builds the overflow landed on the (mostly idle) kernel stack
and went unnoticed; under `WITH_RINGBUF` it wrote ZORK1.DAT contents
over `RINGBUF_BOOK` and `RINGBUF_A`, which CIN then read back as
phantom keystrokes.  Fixed by unconditionally `DEC H`-ing the value
returned by Zork's `MEMTOP`, leaving a 256-byte cushion that absorbs
the overshoot.

## NostOS 1.1.0

### Interrupt-driven serial drivers

Added interrupt-driven drivers for all four supported UART chips: ACIA
(MC6850), SIO/2 (Z80 SIO), SCC (Z85C30), and Z180 ASCI.

- Incoming characters are buffered in a 64-byte ring buffer per channel,
  eliminating dropped keystrokes during normal typing while the system is
  busy executing code or performing disk I/O.

- Character drops during large text pastes may still occur when floppy or
  bubble I/O is in progress.  The FDC's real-time data transfer requires
  a ~8 ms critical section with interrupts disabled; any characters that
  arrive during that window beyond the chip's hardware FIFO are lost.

- The ACIA has only 1 byte of internal Rx buffering, vs 4 bytes on the
  SIO/2 and SCC, and up to 5 on the Z180 ASCI (the enhanced Z8S180
  variant adds a 4-deep FIFO; the original Z8018x has only 2).  This
  means the ACIA is more susceptible to character drops during disk I/O
  critical sections.  SIO/2, SCC, or Z180 ASCI are recommended for the
  best keyboard experience.

- Only one interrupt-driven serial driver may be active per ROM build.
  Polled drivers may freely coexist alongside the one interrupt-driven
  driver.

- The SIO/2, SCC, and ACIA interrupt drivers use IM 1 (RST 38).  The
  Z180 ASCI driver uses IM 2 with the Z180's internal vectored interrupt
  dispatch.  The two modes are mutually exclusive at the CPU level.

- Ports used by interrupt-driven serial drivers are hardcoded as
  immediate operands in the ISR and throughout the driver.  This is
  because the ISR cannot safely use the shared tramp_in/tramp_out
  workspace thunks (they would race with main code), and 8080-compatible
  IN/OUT instructions encode the port as an immediate byte.

### ROM image changes

- CompactFlash-based ROM images now include `-cf-` in their filenames
  (e.g. `nostos-prod-acia-cf-512k.rom`) for consistency with the `-fdc-`
  naming used by floppy-based images.  Scripts referencing old filenames
  will need updating.

- New ROM images for all interrupt-driven UART + block-device
  combinations.  See README.md for the full list.

### Kernel changes

- RAM-redefinable vectors added for RST 3 through RST 7.  Each is a
  3-byte JP thunk in workspace RAM, initialized to `JP unexpected_rst`
  by `workspace_init`.  The bootstrap's `platform_init` hook (or any
  other code with interrupts disabled) can overwrite the target address
  to install a custom handler.  RST 7 is used by the IM 1 interrupt
  drivers; RST 6 is used by the DEBUG application for breakpoints.

- Added `platform_init` — a bootstrap-supplied function called by
  `kernel_init` after `devices_init`, `logdev_table_init`, and
  `automount_init`.  This is where interrupt-driven bootstraps install
  their ISR into the RST 7 RAM vector and enable CPU interrupts.
  Non-interrupt bootstraps provide a trivial `RET`.

- FDC read/write block operations now wrap their data-transfer phase
  in DI/EI to prevent interrupt-driven serial ISRs from causing FDC
  overrun/underrun errors.  The write-side error path now also drains
  the FDC result phase before re-enabling interrupts, matching the
  read side.

- Added polled 16550 UART driver (`src/drivers/uart16550.asm`) at base
  port 0x68, with a new `512k-16550-fdc-zeta2` ROM variant for the
  Zeta2 board with WD37C65 floppy.

- Kernel now unconditionally disables interrupts at the start of boot.
  Drivers that need a DI/EI critical section (FDC, ramdisk, bubble) use
  SAFE_DI/SAFE_EI macros that expand to real DI/EI only on interrupt-
  driven builds; on polled builds they are no-ops since interrupts are
  never enabled.

### Application Changes

- DEBUG now includes the ability to load applications, insert breakpoints,
  step, trace, and disassemble.
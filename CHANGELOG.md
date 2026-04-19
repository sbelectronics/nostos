# Changelog

All notable changes to this project will be documented in this file.

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
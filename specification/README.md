# NostOS (the Nostalgia OS) Specification

## Overview

NostOS is a retro operating system designed for 8-bit vintage computers based on the Intel 8080 and Zilog Z80 processors. It targets the RC2014 platform and has the following characteristics:

- Fits within a 16-bit memory space (64 KB).
- Is inherently rommable — code runs directly from ROM, with only a small workspace area in RAM.
- Provides flexible device support with a logical-to-physical indirection layer that allows physical devices to be reassigned at runtime.
- Includes a command-line interpreter called the Executive, with many built-in commands. The executive is also rommable.
- Uses the 8080 instruction set exclusively, for maximum compatibility across 8080, 8085, and Z80 processors.

## Documentation

| Document | Description |
|----------|-------------|
| [Kernel](KERNEL.md) | Kernel architecture, workspace layout, and boot sequence |
| [Device](DEVICE.md) | Logical and physical device layers, device drivers |
| [FileSys](FILESYS.md) | On-disk filesystem format and file I/O semantics |
| [SysCall](SYSCALL.md) | System call conventions, reference table, and data structures |
| [Executive](EXECUTIVE.md) | Command-line interpreter and built-in commands |
| [Tools](TOOLS.md) | External host-side tools (fstool) |

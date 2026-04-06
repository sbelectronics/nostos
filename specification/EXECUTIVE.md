# NostOS Executive

The executive is the command-line interface and includes a command parser. It may be placed in ROM alongside the kernel, or loaded into RAM from a filesystem so it can be replaced by user programs.

The executive has access to RAM starting at `EXEC_RAM_START` (0xF000). This RAM is overwritten when a user program is loaded.

## Prompt

The prompt displays the currently selected logical device and directory (if the device supports directories), terminated by `>`:

```
C:/>
```

## Command Parsing

The executive accepts one line of input. The line is parsed into a command and an argument, separated by the first space character. The command may optionally be prefixed by a device name and directory path. The device name is terminated by a colon.

Examples of valid commands:

| Input | Meaning |
|-------|---------|
| `myprogram` | Run `myprogram` from the current device and directory |
| `A:myprogram` | Run `myprogram` from the root of device A |
| `A:somedir/myprogram` | Run `myprogram` from `somedir` on device A |

## Built-in Commands

Each built-in command has a short name (up to 2 characters) and a long name (up to 6 characters). Commands are matched case-insensitively.

### Core Commands

| Short | Long | Description |
|-------|------|-------------|
| HP | HELP | Display help (list all commands) |
| IN | INFO | Display system information (version, build date) |
| HT | HALT | Execute a HALT instruction |
| LL | LISTL | List logical devices and their physical assignments |
| LP | LISTP | List physical devices |
| AS | ASSIGN | Assign a logical device to a physical device |
| CD | CHDIR | Change current directory |
| LD | DIR | List directory contents |
| MT | MOUNT | Mount a filesystem device on a block device |

### File and Directory Commands

| Short | Long | Description |
|-------|------|-------------|
| MD | MKDIR | Create a directory |
| RD | RMDIR | Remove a directory |
| CF | COPY | Copy a file (supports file-to-file, char-to-file, file-to-char, char-to-char) |
| RF | DELETE | Remove a file |
| NF | RENAME | Rename a file |
| LF | TYPE | Display file contents as text |
| HF | HEXDMP | Hex dump a file |
| ST | STAT | Display file handle internals (flags, inode, size, position, spans) |
| SM | SUM | Compute checksum of a file |
| FR | FREE | Display free block count on the current filesystem |
| PL | PLAY | Execute commands from a script file |
| \# | REMARK | Comment line (no-op, ignored by command parser) |

## Command Table

The executive uses a linked list of command descriptors to dispatch commands. This allows user programs to extend the command table at runtime by prepending new entries.

### Command descriptor layout (16 bytes)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 3 bytes | Short name (up to 2 characters + null terminator) |
| 3 | 7 bytes | Long name (up to 6 characters + null terminator) |
| 10 | 2 bytes | Function pointer |
| 12 | 2 bytes | Description pointer (null-terminated string, stored elsewhere) |
| 14 | 2 bytes | Next descriptor pointer (0 = end of list) |

The pointer to the head of the command table is stored in the workspace at `EXEC_CMD_TABLE_HEAD` (0xFBE3).

## Command Output Formats

### LL (list logical devices)

```
LogID LogName -> PhysID PhysName
```

### LP (list physical devices)

```
PhysID PhysName
```

### IN (system info)

```
NostOs vX.Y.Z built on YYYY-MM-DD
```

## User Programs

User programs are relocatable executables loaded at `DYNAMIC_MEMBOT` and executed from there. The load address varies depending on how many kernel extensions have been loaded.

The executive opens the program file and calls SYS_EXEC with the file handle and `DYNAMIC_MEMBOT` as the load address. SYS_EXEC reads the file, applies relocation fixups, closes the handle, and jumps to the entry point. SYS_EXEC does not return on success.

A user program terminates by calling SYS_EXIT, which restores the stack and returns control to the executive.

## Kernel Extensions

Kernel extensions use the same `.APP`/`.EXT` relocatable format as user programs. They are launched from the executive prompt by typing the program filename, but note that if no dot is present in the name the executive implicitly appends `.APP`. To run a `.EXT` specifically, the full filename including `.EXT` (or otherwise including a dot) must be typed (for example, `SPEECH.EXT` runs the extension, while `SPEECH` would run `SPEECH.APP`).

The difference is that an extension makes itself resident by calling `SYS_SET_MEMBOT` to advance `DYNAMIC_MEMBOT` past its own code before calling `SYS_EXIT`. Subsequent programs then load above the extension, leaving its code and data intact.
Extensions typically register new device drivers or add executive commands during their initialization, then return via SYS_EXIT.

### Relocatable Executable Format (.APP)

Both user programs and kernel extensions use the same relocatable file format. Programs are assembled with `ORG 0` and processed by `mkreloc.py` to produce a `.APP` file.

#### File layout

```
Offset  Size   Description
------  ----   -----------
0       2      code_length (16-bit LE, length of program binary in bytes)
2       N      program binary (N = code_length bytes, assembled with ORG 0)
2+N     2      reloc_count (16-bit LE, number of relocation entries)
4+N     2*R    reloc_entries (R = reloc_count, each a 16-bit LE offset into the program binary)
```

All multi-byte values are little-endian.

#### Relocation

Each relocation entry is a byte offset within the program binary that points to a 16-bit value requiring fixup. SYS_EXEC applies relocations as follows:

1. Compute `program_base = load_addr + 2` (skipping the code_length header).
2. For each relocation entry at offset `off`:
   - Read the 16-bit value at `program_base + off`.
   - Add `program_base` to it.
   - Write the result back.
3. Jump to `program_base`.

After relocation, every address reference in the program points to the correct location in memory. The relocation table is not preserved; it occupies memory above the program binary and is overwritten or ignored after loading.

#### ORG 0 convention

All relocatable programs must be assembled with `ORG 0`. Absolute address references (labels in `LD`, `CALL`, `JP`, etc.) are emitted relative to address 0 by the assembler. The `-reloc-info` flag causes z80asm to record which instruction operands contain absolute addresses; `mkreloc.py` packages these into the relocation table.

Constants that are not addresses (e.g., workspace addresses like `KERNELADDR`, `LOGDEV_ID_CONO`) are not relocated — they are already absolute.

#### Build process

```
z80asm -b -reloc-info -m -l -o=build/prog.bin prog.asm
mkreloc.py build/prog.bin build/prog.reloc build/prog.app
```

1. z80asm assembles the source to `prog.bin` (raw binary) and `prog.reloc` (flat list of 16-bit LE offsets needing fixup).
2. `mkreloc.py` combines them into the `.APP` format: code_length + binary + reloc_count + reloc_entries.

#### Memory available to programs

| Boundary | Address | Description |
|----------|---------|-------------|
| `DYNAMIC_MEMBOT` | 0x4000 initially (16K ROM) or 0x8000 (32K ROM) | Load address; advances as extensions are loaded |
| `DYNAMIC_MEMTOP` | configurable, default 0xF7EF | Top of usable memory (stack starts above this) |

Maximum program size is `DYNAMIC_MEMTOP - DYNAMIC_MEMBOT`, approximately 45 KB (16K ROM) or 29 KB (32K ROM) with no extensions loaded. SYS_MEMTOP returns the current value of `DYNAMIC_MEMTOP`; programs can read `DYNAMIC_MEMBOT` directly from the workspace.

The entry point is at `load_addr + 2` (immediately after the code_length field). SYS_EXEC closes the file handle before jumping; the caller does not need to close it.

### Command-line arguments

User programs access their command-line arguments by calling SYS_GET_CMDLINE, which returns a pointer to the input buffer. The buffer contains the full command line with spaces separating arguments, null-terminated. The executive does not parse arguments for the user program.

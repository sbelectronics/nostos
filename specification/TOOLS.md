# NostOS Tools

## fstool — Filesystem Manipulation Tool

A Go-based command-line tool for creating and manipulating NostOS filesystem images from a Linux host. Located in `tools/fstool/`.

Images created by fstool are bit-compatible with filesystems used by NostOS on real hardware.

### Usage

```
fstool <image-file> <command> [arguments...]
```

The image file must exist but does not need to contain a valid filesystem (use `format` to initialize it).

### Commands

| Command | Arguments | Description |
|---------|-----------|-------------|
| `format` | `<blocks>` | Initialize the filesystem with the specified number of blocks. Image file must be large enough. |
| `info` | — | Print filesystem information: block count, free blocks, directories, files. |
| `dir` | `[pathname]` | List directory contents. Defaults to root. Shows name, type, attributes, size, date, inode. |
| `mkdir` | `<dirname>` | Create a directory. Nesting is not supported. |
| `rmdir` | `<dirname>` | Remove a directory. Fails if not empty. |
| `add` | `<src> <destpath>` | Copy a file from the host into the filesystem. |
| `get` | `<srcpath> [dest]` | Copy a file from the filesystem to the host. Defaults to basename of source. |
| `rm` | `<pathname>` | Remove a file. Works with root and subdirectory files. |
| `rename` | `<old> <new>` | Rename a file or directory. Both names must be in the same directory. |

Filenames are case-insensitive and are converted to uppercase when stored.

### Building

```bash
make tools       # from the project root
```

The `tools/` directory has its own Makefile, invoked by `make tools` from the project root.

#!/usr/bin/env python3
"""mkreloc.py - Generate NostOS relocatable executable file.

Reads the .reloc file produced by z80asm -reloc-info (a flat list of
16-bit LE offsets) and wraps the binary in the NostOS relocatable format.

Output format:
  [code_length : 2 bytes LE]    (length of program binary only)
  [program binary]              (assembled with ORG 0)
  [reloc_count : 2 bytes LE]    (number of relocation entries)
  [reloc_entry : 2 bytes LE] x reloc_count   (offsets within program)

Usage:
  mkreloc.py <binary> <reloc_file> <output>

Example:
  mkreloc.py build/app.bin build/app.reloc build/app.app
"""

import sys
import struct


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <binary> <reloc_file> <output>",
              file=sys.stderr)
        sys.exit(1)

    bin_path = sys.argv[1]
    reloc_path = sys.argv[2]
    out_path = sys.argv[3]

    with open(bin_path, 'rb') as f:
        binary = f.read()

    with open(reloc_path, 'rb') as f:
        reloc_data = f.read()

    if len(reloc_data) % 2 != 0:
        print("Error: .reloc file has odd size", file=sys.stderr)
        sys.exit(1)

    # Parse relocation offsets from the .reloc file
    reloc_count = len(reloc_data) // 2
    relocs = [struct.unpack_from('<H', reloc_data, i * 2)[0]
              for i in range(reloc_count)]

    # Build output: [code_length][binary][reloc_count][entries]
    code_length = len(binary)
    trailer = struct.pack('<H', reloc_count)
    for r in relocs:
        trailer += struct.pack('<H', r)

    with open(out_path, 'wb') as f:
        f.write(struct.pack('<H', code_length))
        f.write(binary)
        f.write(trailer)

    # Report
    total = 2 + code_length + len(trailer)
    print(f"Relocations: {reloc_count}")
    print(f"Code: {code_length} bytes, Trailer: {len(trailer)} bytes, "
          f"Total: {total} bytes")
    for r in relocs:
        val = struct.unpack_from('<H', binary, r)[0]
        print(f"  [0x{r:04X}] = 0x{val:04X}")


if __name__ == '__main__':
    main()

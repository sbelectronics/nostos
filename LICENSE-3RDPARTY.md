# Third-Party Components

NostOS includes several third-party components under `apps/3rdparty/` and
`src/drivers/`. These components are not covered by the project's Apache 2.0
license. Each component retains its original license and copyright as described
below.

---

## NASCOM ROM BASIC (`apps/3rdparty/basic.asm`)

- **Original**: NASCOM ROM BASIC Ver 4.7, (C) 1978 Microsoft
- **Updates**: Grant Searle (http://searle.wales/)
- **Z80 tuning and extensions**: (C) 2020-2023 Phillip Stevens
- **NostOS port**: Scott Baker, 2026
- **License**: Mozilla Public License 2.0 (MPL-2.0)

Grant Searle's modifications require NON-COMMERCIAL USE ONLY with
acknowledgement. See the file header in `apps/3rdparty/basic.asm` for full
terms.

---

## FIG-FORTH 1.1 (`apps/3rdparty/forth.asm`)

- **Original**: (C) 1978-1979 FORTH INTEREST GROUP, P.O. Box 1105, San Carlos, CA 94070
- **Implementation**: John Cassady, FORTH INTEREST GROUP, March 1979
- **CP/M modifications**: Kim Harris, FIT Librarian, September 1979
- **NostOS port**: Claude (Anthropic) / Scott Baker, 2025
- **License**: Public domain, with credit attribution requested

The FIG-FORTH model is released to the public domain by the FORTH INTEREST
GROUP. The original distribution requests that credit be given to the FORTH
INTEREST GROUP and the implementors.

---

## ZIP80 / Zork Interpreter (`apps/3rdparty/zork.asm`)

- **Original**: Z-Code Interpreter, (C) 1984 Infocom, Inc.
- **NostOS port**: Scott Baker, 2026
- **License**: Copyright maintained by its original owner

The original Z-Code interpreter is (C) Infocom, Inc. This port adapts the
interpreter for NostOS but does not alter the original copyright terms. Users
should ensure their use complies with the rights holder's terms.

---

## Zealasm Assembler (`apps/3rdparty/zealasm/`)

- **Original**: Zealasm by Zeal 8-bit Computer
- **NostOS port**: with .APP relocation output support
- **License**: Apache License 2.0

The original Zealasm source is licensed under Apache 2.0. See the Zeal 8-bit
Computer project for the original source and license terms.

---

## Intel 7220 Bubble Memory Driver (`src/drivers/bubble.asm`)

- **7220 register values and command sequences**: Referenced from SBC-85 bubble
  memory routines by Craig Andrews, 2020
- **NostOS driver**: Scott Baker, 2025-2026
- **License**: The NostOS driver code is Apache 2.0. The original SBC-85
  routines by Craig Andrews are copyright their original author.

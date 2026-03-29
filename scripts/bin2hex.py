#!/usr/bin/env python3
"""Convert a raw binary (little-endian RV32I text section) to the
.hex format expected by the NetX RV32I test harness.

Format:
    @XXXXXXXX   word-addressed start (byte_addr >> 2)
    YYYYYYYY    one 32-bit instruction per line, big-endian display
    ...
"""

import sys
import struct


def bin_to_hex(data: bytes, word_base_addr: int = 0) -> str:
    # Pad to a multiple of 4 bytes
    remainder = len(data) % 4
    if remainder:
        data += b'\x00' * (4 - remainder)

    lines = [f'@{word_base_addr:08X}']
    for i in range(0, len(data), 4):
        word = struct.unpack_from('<I', data, i)[0]
        lines.append(f'{word:08X}')
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        print(f'Usage: {sys.argv[0]} <binary_file> [word_base_addr]', file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], 'rb') as f:
        raw = f.read()

    base_addr = int(sys.argv[2], 0) if len(sys.argv) == 3 else 0
    sys.stdout.write(bin_to_hex(raw, base_addr))

#!/usr/bin/env python3
"""Every icon Icons.js names is in the cut fonts/lucide.ttf. After adding an
icon, rerun scripts/subset-icons with the full Lucide font."""
import pathlib
import re
import struct
import sys

root = pathlib.Path(__file__).resolve().parent.parent
icons = dict(re.findall(r'^\s+(\w+):\s+(0x[0-9A-Fa-f]+)', (root / 'plugin/components/Icons.js').read_text(), re.M))
font = (root / 'plugin/components/fonts/lucide.ttf').read_bytes()


def mapped(font):
    """The code points the font's cmap maps, from its format 4 and 12 subtables."""
    tables = {}
    for i in range(struct.unpack_from('>H', font, 4)[0]):
        tables[font[12 + 16 * i:16 + 16 * i]] = struct.unpack_from('>I', font, 20 + 16 * i)[0]
    cmap = tables[b'cmap']
    points = set()
    for i in range(struct.unpack_from('>H', font, cmap + 2)[0]):
        sub = cmap + struct.unpack_from('>I', font, cmap + 8 + 8 * i)[0]
        kind = struct.unpack_from('>H', font, sub)[0]
        if kind == 4:
            segments = struct.unpack_from('>H', font, sub + 6)[0] // 2
            ends = struct.unpack_from(f'>{segments}H', font, sub + 14)
            starts = struct.unpack_from(f'>{segments}H', font, sub + 16 + 2 * segments)
            for start, end in zip(starts, ends):
                if start != 0xFFFF:
                    points.update(range(start, end + 1))
        elif kind == 12:
            for g in range(struct.unpack_from('>I', font, sub + 12)[0]):
                start, end, _ = struct.unpack_from('>3I', font, sub + 16 + 12 * g)
                points.update(range(start, end + 1))
    return points


points = mapped(font)
missing = sorted(name for name, code in icons.items() if int(code, 16) not in points)
if missing:
    sys.exit('Not in fonts/lucide.ttf (rerun scripts/subset-icons): ' + ', '.join(missing))
print(f'PASS: all {len(icons)} icons are in lucide.ttf ({len(points)} glyphs)')

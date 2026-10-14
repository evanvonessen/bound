#!/usr/bin/env python3
"""Create synthetic dex-parser metadata for QA; never use this as a game save."""
import argparse
import struct
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
args = parser.parse_args()
if args.output.exists():
    parser.error("Refusing to overwrite an existing file")
data = bytearray(0x20000)
for slot in range(2):
    for physical in range(14):
        sector = (physical + (11 if slot else 0)) % 14
        offset = slot * 0xe000 + physical * 0x1000
        struct.pack_into("<H", data, offset + 0xff4, sector)
        struct.pack_into("<I", data, offset + 0xff8, 0x08012025)
        struct.pack_into("<I", data, offset + 0xffc, 10 + slot)
        if sector == 0:
            struct.pack_into("<I", data, offset + 0xa, 123456789 if slot else 42)
            data[offset + 0xf2c] = 6 if slot else 0
args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open("xb") as output:
    output.write(data)
print("Created synthetic QA seed 123456789 (random abilities and learnset)")

#!/usr/bin/env python3
"""Execute the owned cartridge's camera/object rebase without changing its ROM.

Run through PrototypeTools/qa-python. This proves the native retained-object
contract used by Bound's reader; Swift tests cover decoding and presentation.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB
from unicorn.arm_const import UC_ARM_REG_SP, UC_ARM_REG_LR


def verify(rom_path):
    rom = Path(rom_path).read_bytes()
    assert len(rom) == 0x2000000, "Expected the owned 32 MiB cartridge"
    machine = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
    machine.mem_map(0x08000000, len(rom)); machine.mem_write(0x08000000, rom)
    machine.mem_map(0x02000000, 0x40000); machine.mem_map(0x03000000, 0x8000)
    address, function, stop = 0x02036E38, 0x0805F82D, 0x03007FF0
    checks = []
    # Pallet->Route 1, Route 1->Viridian, east/west connection offsets,
    # and the reverse legs all keep the original spawn-map bytes.
    for dx, dy in [(0, -40), (-12, -40), (24, 6), (-12, -5), (0, 40), (12, 40)]:
        machine.mem_write(0x02036E18, struct.pack('<Iii', 1, dx, dy))
        objects = bytearray(16 * 36)
        struct.pack_into('<I', objects, 0, 0x10001)
        objects[8:12] = bytes([255, 0, 3, 3])
        for offset in [12, 16, 20]:
            struct.pack_into('<hh', objects, offset, 15, 7)
        machine.mem_write(address, bytes(objects))
        machine.reg_write(UC_ARM_REG_SP, 0x03007E00)
        machine.reg_write(UC_ARM_REG_LR, stop | 1)
        machine.emu_start(function, stop, count=10000)
        result = bytes(machine.mem_read(address, 16 * 36))
        assert result[:12] == objects[:12], "Camera scrolling must retain player identity and spawn map"
        for offset in [12, 16, 20]:
            assert struct.unpack_from('<hh', result, offset) == (15 - dx, 7 - dy)
        assert result[24:] == objects[24:], "Only the native coordinate pairs may change"
        checks.append({'delta': [dx, dy], 'spawn_map': [result[10], result[9]],
                       'current': list(struct.unpack_from('<hh', result, 16))})
    return {'rom_sha256': hashlib.sha256(rom).hexdigest(), 'function': '0x0805F82C',
            'native_connected_map_rebases': checks,
            'rom_unchanged': hashlib.sha256(Path(rom_path).read_bytes()).digest() == hashlib.sha256(rom).digest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rom', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.rom), indent=2))

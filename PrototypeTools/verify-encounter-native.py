#!/usr/bin/env python3
"""Controlled ARM execution of the exact-ROM encounter shim.

Uses the approved QA launcher. Native give/storage, map lookup and UI callbacks
are observed boundaries; this is not a natural capture, raid or shop playthrough.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

game = Path(__file__).resolve().parents[2] / 'multi_red-multiplayer-isolation'
sys.path.insert(0, str(game / 'tools'))
from qa_python import ensure_qa_python
ensure_qa_python()
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_CODE
from unicorn.arm_const import UC_CPU_ARM_TI925T, UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3, UC_ARM_REG_R4, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_CPSR

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--rom', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
rom = a.rom.read_bytes()
assert hashlib.sha256(rom).hexdigest() in {
    '689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066',
    'fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00'}
assert rom[0x40B14:0x40B1C] == bytes.fromhex('0049084791d70709')
assert rom[0x107DF6C:0x107DF74] == bytes.fromhex('10b50748074c00f0')
assert struct.unpack_from('<I', rom, 0x7233D0)[0] == 0x0904575D
assert rom[0x104575D:0x1045765] == bytes.fromhex('695a0f00632a1009')
root = Path(__file__).resolve().parents[1]
header = (root / 'Delta/Bound/SoulLink/BoundSoulCode.h').read_text()
symbols = {name: int(value, 16) for name, value in re.findall(r'(BoundSoul\w+)Address=0x([0-9A-F]+)', header)}
code = bytes(int(value, 16) for value in re.findall(r'0x([0-9A-F]{2})(?=[,}])', header.split('BoundSoulCode[]={')[1]))
u = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
u.ctl_set_cpu_model(UC_CPU_ARM_TI925T)
for address, size in [(0x08000000, 0x2000000), (0x02000000, 0x40000), (0x03000000, 0x8000), (0x04000000, 0x1000), (0x0A000000, 0x1000)]:
    u.mem_map(address, size)
u.mem_write(0x08000000, rom)
u.mem_write(0x09FF8000, code)
# Install the same exact-RR internal gate thunk as the bridge. Native bag and
# quick-ball callers below execute from the verified original image.
u.mem_write(0x0907DF6C, bytes.fromhex('004b1847') + struct.pack('<I', symbols['BoundSoulCatchBlocked']))
symbols['NativeBagCheck'] = 0x0907E02D
symbols['NativeQuickBallCheck'] = 0x0906A455
symbols['NativeBagAction'] = 0x0A000101
symbols['NativeRunScript'] = 0x08069805
u.mem_write(0x0A000100, bytes.fromhex('10b5041c014b1847c046c046') + struct.pack('<I', 0x09042CC9))
checks = []
flags, area, result, give_calls, displayed, removed = set(), 100, 0, 0, 0, 0
close_during_give = False
script_callbacks = {}
def put(address, value, size=4): u.mem_write(address, value.to_bytes(size, 'little'))
def read(address, size=4): return int.from_bytes(u.mem_read(address, size), 'little')
def check(name, actual, expected=True):
    assert actual == expected, (name, actual, expected)
    checks.append(name)
def hook(uc, address, size, data):
    global give_calls, displayed, removed
    if address == 0x0A000000:
        uc.emu_stop()
        return
    if address == 0x08056260: value = area
    elif address == 0x0806E6D0: value = int(uc.reg_read(UC_ARM_REG_R0) in flags)
    elif address == 0x0907D790:
        give_calls += 1
        if result <= 1: put(uc.reg_read(UC_ARM_REG_R0) + 4, 42)
        if close_during_give: put(0x09FFA000, 0)
        value = result
    elif address == 0x0907CFBC: value = 0 # Existing raid-stage prerequisite.
    elif address == 0x090A6944: value = 4 # Existing last-used Poké Ball lookup.
    elif address == 0x08108E70:
        displayed += 1
        value = 0
    elif address == 0x0809A1D8:
        removed += 1
        value = 1
    elif address in script_callbacks:
        kind = script_callbacks[address]
        ctx = uc.reg_read(UC_ARM_REG_R0)
        if kind == 'message':
            put(ctx + 8, read(ctx + 8) + 4)
            value = 1
        elif kind == 'opening': value = 1
        else: value = 0
    else: return
    uc.reg_write(UC_ARM_REG_R0, value)
    uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))
u.hook_add(UC_HOOK_CODE, hook)
def call(name, *args):
    u.reg_write(UC_ARM_REG_CPSR, 0x20)
    u.reg_write(UC_ARM_REG_SP, 0x03007E00)
    u.reg_write(UC_ARM_REG_LR, 0x0A000001)
    for reg, value in zip([UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3], args): u.reg_write(reg, value)
    u.emu_start(symbols[name], 0x0A000002, count=100000)
    assert u.reg_read(UC_ARM_REG_PC) == 0x0A000000
    assert u.reg_read(UC_ARM_REG_SP) == 0x03007E00
    return u.reg_read(UC_ARM_REG_R0)
def reset(*, battle=True, battle_flags=0, egg=False, prize=False):
    global give_calls
    put(0x09FFA000, 0x314C5342)
    u.mem_write(0x09FFE008, bytes(32))
    u.mem_write(0x03004620, bytes(396))
    put(0x02022B4C, battle_flags)
    put(0x03003529, 2 if battle else 0, 1)
    put(0x03005008, 0x02030000)
    put(0x02030004, 10 if prize else 3, 1)
    put(0x02030005, 15 if prize else 1, 1)
    mon = 0x0202402C if battle else 0x02018000
    u.mem_write(mon, bytes(100))
    put(mon, 123)
    put(mon + 4, 17)
    put(mon + 19, 6 if egg else 2, 1)
    give_calls = 0
    return mon
def receipt_kind(): return read(0x0300462C + 8) & 255
def acquire(mon): return call('BoundSoulGive', mon)
for mode in (0, 1):
    result = mode
    mon = reset()
    check('successful party/box result ' + str(mode), acquire(mon), mode)
    check('post-native trainer recorded ' + str(mode), read(0x03004630), 42)
    check('wild receipt kind ' + str(mode), receipt_kind(), 0)
    check('native area recorded ' + str(mode), read(0x03004634) >> 8, area)
    check('same-frame second wild denied ' + str(mode), acquire(mon), 2)
    check('same-frame denial never enters native give ' + str(mode), give_calls, 1)
    check('same-frame catch gate blocks bag/shortcut ' + str(mode), call('BoundSoulCatchBlocked'), 1)
    # Another named area stays available.
    area += 1
    check('different area stays available ' + str(mode), call('BoundSoulCatchBlocked'), 0)
    area -= 1
result = 2
mon = reset()
check('native storage failure forwarded', acquire(mon), 2)
check('native storage failure emits no receipt', read(0x03004624), 0)
check('native storage failure leaves area available', call('BoundSoulCatchBlocked'), 0)
result = 0
for battle_flags, kind in [(0x2000, 4), (0x20000, 4), (0x40000, 4), (0x40002000, 0)]:
    mon = reset(battle_flags=battle_flags)
    put(0x09FFE008 + area // 8, 1 << (area % 8), 1)
    check('static/raid gate ' + hex(battle_flags), call('BoundSoulCatchBlocked'), int(kind == 0))
    check('static/raid acquisition ' + hex(battle_flags), acquire(mon), 2 if kind == 0 else 0)
    if kind == 4: check('static receipt separate from gifts ' + hex(battle_flags), receipt_kind(), 4)
for egg in (False, True):
    mon = reset(battle=False, egg=egg)
    put(0x09FFE008 + area // 8, 1 << (area % 8), 1)
    check('gift/egg bypass occupied area ' + str(egg), acquire(mon), 0)
    check('gift/egg source ' + str(egg), receipt_kind(), 3 if egg else 1)
mon = reset(battle=False, prize=True)
check('first prize succeeds', acquire(mon), 0)
check('prize source', receipt_kind(), 2)
check('second prize denied', acquire(mon), 2)
check('second prize never enters native give', give_calls, 1)
mon = reset(battle=False, prize=True, egg=True)
put(0x09FFE008, 1, 1)
check('egg in prize room remains separate', acquire(mon), 0)
check('egg prize-room classification', receipt_kind(), 3)
mon = reset()
put(0x09FFE008 + area // 8, 1 << (area % 8), 1)
check('durable acquired policy blocks native give', acquire(mon), 2)
check('original native bag checker reports blocked', call('NativeBagCheck', 0), 1)
check('original native bag action displays message', call('NativeBagAction', 0), 1)
check('native bag action never removes ball', removed, 0)
check('native bag check/action each display warning', displayed, 2)
check('original native quick-ball predicate rejects spent area', call('NativeQuickBallCheck'), 1)
# Execute the REAL native bytecode interpreter, native callnative, comparison
# and conditional goto. Only visual lock/face/message callbacks are observed.
# The deny path yields at its message before entering any original shop code.
for opcode, kind in [(0x69, 'lock'), (0x5A, 'face'), (0x67, 'message'), (0x09, 'opening')]:
    script_callbacks[read(0x0815F9B4 + opcode * 4) & ~1] = kind
u.mem_write(0x0904575D, bytes([0x05]) + struct.pack('<I', symbols['BoundSoulPrizeScript']) + bytes(3))
for used in (False, True):
    reset(battle=False, prize=True)
    put(0x09FFE008, int(used), 1)
    put(0x02030290, 123456)
    put(0x02030294, 4321, 2)
    ctx = 0x0201B000
    u.mem_write(ctx, bytes(0x74))
    put(ctx + 1, 1, 1)
    # An already cached or save-restored object retains this ORIGINAL native
    # pointer. The script-entry guard must work without modifying its template.
    put(ctx + 8, 0x0904575D)
    put(ctx + 0x5C, 0x0815F9B4)
    put(ctx + 0x60, 0x0815FD08)
    check('native shop guard yields ' + str(used), call('NativeRunScript', ctx), 1)
    check('native shop guard path from cached template ' + str(used), read(ctx + 8), symbols['BoundSoulPrizeScript'] + 29 if used else 0x09045766)
    check('shop guard preserves money ' + str(used), read(0x02030290), 123456)
    check('shop guard preserves coins ' + str(used), read(0x02030294, 2), 4321)
    check('shop guard creates no Pokemon ' + str(used), give_calls, 0)
check('other prize clerk script untouched', read(0x087233B8), 0x09046500)
check('Pokemon clerk template retains original native pointer', read(0x087233D0), 0x0904575D)
for native_flag in (0x902, 0x904):
    reset(battle_flags=0x40000)
    flags.add(native_flag)
    check('native flag preserved ' + hex(native_flag), call('BoundSoulCatchBlocked'), 1)
    flags.clear()
reset()
put(0x03004620, 0x314C5342)
put(0x03004624, 32)
check('receipt overflow fails closed', acquire(0x0202402C), 2)
check('receipt overflow latched', read(0x03004628), 1)
mon = reset()
put(0x09FFA000, 0)
check('closed policy delegates give', acquire(mon), 0)
check('closed policy produces no receipt', read(0x03004624), 0)
mon = reset()
close_during_give = True
check('closing during native give preserves native result', acquire(mon), 0)
check('closing during native give emits no stale receipt', read(0x03004624), 0)
report = {'passed': True, 'checks': checks, 'rom_sha256': hashlib.sha256(rom).hexdigest(),
          'scope': 'Compiled Thumb enforcement, original native bag action and quick-ball predicate, and original native script interpreter executing the shop guard; give/map/flag/UI boundaries observed.',
          'limits': 'Native storage/capture success is stubbed. No natural field catch, raid completion, completed prize purchase, emulator save restoration or physical-device/WAN claim.'}
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))

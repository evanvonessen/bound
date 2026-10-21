#!/usr/bin/env python3
"""Build or check the small emulated ARM7TDMI battle entry, using devkitARM.

This compiles our entry only, without cartridge bytes or external source code.
It does not run during normal Xcode builds; the generated header is committed.
"""
from pathlib import Path
import argparse,json,subprocess,tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check',action='store_true')
parser.add_argument('--tool-prefix',default='/opt/devkitpro/devkitARM/bin/arm-none-eabi-')
parser.add_argument('--output',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
source=root/'Delta/Bound/NativeBattle/battle-entry.c'
work=tempfile.TemporaryDirectory(prefix='bound-battle-entry-') if args.output is None else None
out=Path(work.name) if work else args.output
out.mkdir(parents=True,exist_ok=True)
tool=args.tool_prefix
ld=out/'entry.ld';ld.write_text('ENTRY(BoundBattleStart)\nSECTIONS { .text 0x09FFF800 : { *(.text.start) *(.text*) *(.rodata*) } /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.eh_frame) *(.ARM.exidx*) } }\n')
command=[tool+'gcc','-mcpu=arm7tdmi','-mthumb','-Os','-ffreestanding','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-fno-builtin','-nostdlib','-Wl,--build-id=none','-Wl,-T,'+str(ld),'-o',str(out/'entry.elf'),str(source)]
subprocess.run(command,check=True,capture_output=True)
subprocess.run([tool+'objcopy','-O','binary',str(out/'entry.elf'),str(out/'entry.bin')],check=True)
syms={}
for line in subprocess.check_output([tool+'nm','-n',str(out/'entry.elf')],text=True).splitlines():
 cols=line.split()
 if len(cols)==3 and cols[2].startswith('BoundBattle'):syms[cols[2]]=int(cols[0],16)|1
code=(out/'entry.bin').read_bytes();assert 0<len(code)<=0x3F0
header='// Generated from NativeBattle/battle-entry.c for ARM7TDMI Thumb.\n#pragma once\n#include <stdint.h>\n'
for k,v in syms.items():header+=f'static const uint32_t {k}Address = 0x{v:08X};\n'
header+='static const uint8_t BoundBattleEntryCode[] = {\n'+''.join('    '+', '.join(f'0x{v:02X}' for v in code[i:i+16])+',\n' for i in range(0,len(code),16))+'};\n'
target=root/'Delta/Bound/NativeBattle/BoundBattleEntryCode.h'
if args.check:
    if target.read_text()!=header: raise SystemExit('Generated battle entry differs; regenerate with this tool')
else: target.write_text(header)
(out/'build.json').write_text(json.dumps(dict(compiler=subprocess.check_output([tool+'gcc','--version'],text=True).splitlines()[0],flags=command[1:],symbols=syms,bytes=len(code)),indent=2)+'\n')
print(dict(bytes=len(code),symbols=syms))

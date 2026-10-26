#!/usr/bin/env python3
"""Build/check the original ARM7TDMI decision-only friendly-battle adapter."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check',action='store_true')
parser.add_argument('--tool-prefix',default='/opt/devkitpro/devkitARM/bin/arm-none-eabi-')
parser.add_argument('--output',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
source=root/'Delta/Bound/NativeBattle/battle-decisions.c'
temporary=tempfile.TemporaryDirectory(prefix='bound-battle-decisions-') if args.output is None else None
out=Path(temporary.name) if temporary else args.output
out.mkdir(parents=True,exist_ok=True)
tool=args.tool_prefix
layout=out/'decisions.ld'
layout.write_text('SECTIONS { .text 0x09FE8000 : { *(.text*) *(.rodata*) } /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.eh_frame) *(.ARM.exidx*) } }\n')
command=[tool+'gcc','-mcpu=arm7tdmi','-mthumb','-Os','-ffreestanding','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-fno-builtin','-nostdlib','-Wl,--build-id=none','-Wl,-T,'+str(layout),'-o',str(out/'decisions.elf'),str(source)]
subprocess.run(command,check=True,capture_output=True)
subprocess.run([tool+'objcopy','-O','binary',str(out/'decisions.elf'),str(out/'decisions.bin')],check=True)
symbols={}
for line in subprocess.check_output([tool+'nm','-n',str(out/'decisions.elf')],text=True).splitlines():
    columns=line.split()
    if len(columns)==3 and columns[2].startswith('BoundDecision'):
        symbols[columns[2]]=int(columns[0],16)|1
code=(out/'decisions.bin').read_bytes()
assert 0<len(code)<=0x8000
header='// Generated from NativeBattle/battle-decisions.c for ARM7TDMI Thumb.\n#pragma once\n#include <stdint.h>\n#include "battle-decisions.h"\n'
for name,value in symbols.items():header+=f'static const uint32_t {name}Address = 0x{value:08X};\n'
header+='static const uint8_t BoundBattleDecisionCode[] = {\n'+''.join('    '+', '.join(f'0x{value:02X}' for value in code[i:i+16])+',\n' for i in range(0,len(code),16))+'};\n'
target=root/'Delta/Bound/NativeBattle/BoundBattleDecisionCode.h'
if args.check:
    if target.read_text()!=header:raise SystemExit('Generated decision adapter differs; regenerate with this tool')
else:target.write_text(header)
(out/'build.json').write_text(json.dumps(dict(compiler=subprocess.check_output([tool+'gcc','--version'],text=True).splitlines()[0],flags=command[1:],symbols=symbols,bytes=len(code)),indent=2)+'\n')
print(dict(bytes=len(code),symbols=symbols))

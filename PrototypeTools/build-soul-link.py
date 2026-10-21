#!/usr/bin/env python3
"""Build/check Bound's original exact-ROM Soul Link Thumb shim (no ROM input)."""
from pathlib import Path
import argparse, subprocess, tempfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--check',action='store_true')
p.add_argument('--qa',action='store_true')
p.add_argument('--tool-prefix',default='/opt/devkitpro/devkitARM/bin/arm-none-eabi-')
a=p.parse_args(); root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='bound-soul-link-') as t:
    out=Path(t); ld=out/'entry.ld'
    ld.write_text('SECTIONS { .text 0x09FF8000 : { *(.text*) *(.rodata*) } /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.ARM.exidx*) } }')
    subprocess.run([a.tool_prefix+'gcc', *(['-DBOUND_SOUL_QA=1'] if a.qa else []), '-mcpu=arm7tdmi','-mthumb','-Os','-ffreestanding','-fno-builtin','-nostdlib','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-Wl,--build-id=none','-Wl,-T,'+str(ld),'-o',str(out/'entry.elf'),str(root/'Delta/Bound/SoulLink/soul-link.c')],check=True,capture_output=True)
    subprocess.run([a.tool_prefix+'objcopy','-O','binary',str(out/'entry.elf'),str(out/'entry.bin')],check=True)
    code=(out/'entry.bin').read_bytes(); assert 0<len(code)<0x2000
    symbols={c[2]:int(c[0],16)|1 for l in subprocess.check_output([a.tool_prefix+'nm','-n',str(out/'entry.elf')],text=True).splitlines() if len(c:=l.split())==3 and c[2] in (['BoundSoulQA','BoundSoulQACatch'] if a.qa else ['BoundSoulGet','BoundSoulSet'])}
    h='// Generated from SoulLink/soul-link.c. Original Bound ARM7TDMI Thumb code.\n#pragma once\n'
    for name,address in symbols.items(): h+=f'static const uint32_t {name}Address=0x{address:08X};\n'
    h+='static const uint8_t '+('BoundSoulQACode' if a.qa else 'BoundSoulCode')+'[]={\n'+''.join('    '+','.join(f'0x{x:02X}' for x in code[i:i+16])+',\n' for i in range(0,len(code),16))+'};\n'
    target=root/('Delta/Bound/SoulLink/BoundSoulQACode.h' if a.qa else 'Delta/Bound/SoulLink/BoundSoulCode.h')
    if a.check: assert target.read_text()==h,'Regenerate Soul Link shim'
    else: target.write_text(h)
    print({'bytes':len(code),'symbols':symbols})

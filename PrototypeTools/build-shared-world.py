#!/usr/bin/env python3
"""Build/check original Bound shared-world Thumb glue, without cartridge input."""
from pathlib import Path
import argparse,subprocess,tempfile
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--check',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parents[1];tool='/opt/devkitpro/devkitARM/bin/arm-none-eabi-'
with tempfile.TemporaryDirectory(prefix='bound-shared-world-') as t:
 out=Path(t);ld=out/'world.ld';ld.write_text('SECTIONS { .text 0x09FF6000 : { *(.text*) *(.rodata*) } /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.ARM.exidx*) } }')
 subprocess.run([tool+'gcc','-mcpu=arm7tdmi','-mthumb','-Os','-ffreestanding','-fno-builtin','-fno-jump-tables','-nostdlib','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-Wl,--build-id=none','-Wl,-T,'+str(ld),'-o',str(out/'world.elf'),str(root/'Delta/Bound/SharedWorld/shared-world.c')],check=True)
 subprocess.run([tool+'objcopy','-O','binary',str(out/'world.elf'),str(out/'world.bin')],check=True)
 code=(out/'world.bin').read_bytes();assert len(code)<0xF00
 names=['BoundWorldFlag','BoundWorldCollisionEntry','BoundWorldTrainer','BoundWorldDoTrainer','BoundWorldCheckTrainer']
 syms={c[2]:int(c[0],16)|1 for l in subprocess.check_output([tool+'nm','-n',str(out/'world.elf')],text=True).splitlines() if len(c:=l.split())==3 and c[2] in names}
 h='// Generated from SharedWorld/shared-world.c. Original Bound Thumb code.\n#pragma once\n'
 for n,v in syms.items():h+=f'static const uint32_t {n}Address=0x{v:08X};\n'
 h+='static const uint8_t BoundSharedWorldCode[]={\n'+''.join('    '+','.join(f'0x{x:02X}' for x in code[i:i+16])+',\n' for i in range(0,len(code),16))+'};\n'
 target=root/'Delta/Bound/SharedWorld/BoundSharedWorldCode.h'
 if a.check:assert target.read_text()==h,'Regenerate shared world shim'
 else:target.write_text(h)
 print({'bytes':len(code),'symbols':syms})

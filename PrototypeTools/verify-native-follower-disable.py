#!/usr/bin/env python3
"""Attempt original follower-return dialogue after native map preparation.

Requires an enabled state produced by the exact supplied ROM. Native warp and
placeholder-removal APIs prepare access to the NPC. Only actual DOWN/A buttons
may disable the service; no service flags, native outcomes or sprites are set.
"""
import argparse,hashlib,json,os,struct,subprocess,sys,zlib
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
for key in ('rom','manifest','state','output'):p.add_argument('--'+key,type=Path,required=True)
a=p.parse_args();game=Path(os.environ['BOUND_GAME_SOURCE']).resolve();sys.path.insert(0,str(game/'tools'))
from qa_python import ensure_qa_python
ensure_qa_python()
from game_elimination_storage_native import Machine
from integrated_game import verify_image
from verify_integrated_gameplay import memory
rom=a.rom.read_bytes();seed=a.state.read_bytes();verify_image(rom,json.loads(a.manifest.read_text()))
assert len(seed)==0x61000 and struct.unpack_from('<I',seed,8)[0]==zlib.crc32(rom)
a.output.mkdir(parents=True,exist_ok=True);checks=[];observations=[]
def require(label,value):
    assert value,label
    checks.append(label)
def read(path,label):
    m=memory(path);save=int.from_bytes(m.read(0x03005008,4),'little');state=m.read(0x0203B818,24)
    value={'label':label,'enabled':bool(m.read(0x0203B25E,1)[0]&0x20),'followerState':state.hex(),
        'map':list(m.read(save+4,2)),'tile':list(struct.unpack('<hh',m.read(save,4))),
        'metadata':list(struct.unpack('<8I',m.read(0x02002060,32)))}
    observations.append(value);return value
require('exact source state has enabled real follower',read(a.state,'source')['enabled'])
def drive(state,label,inputs=(),frames=240):
    out=a.output/label;out.mkdir(parents=True,exist_ok=True)
    cmd=[sys.executable,str(game/'tools/map_emulator.py'),'--rom',str(a.rom),'--state-in',str(state),'--output',str(out),
        '--frames',str(frames),'--rtc-ms','1735689600000','--state-out',f'{frames}:{out}/final.state','--screenshot-at',str(frames)]
    for button in inputs:cmd+=['--input',button]
    subprocess.run(cmd,cwd=game,check=True,stdout=subprocess.DEVNULL)
    result=out/'final.state';read(result,label);return result

def task(state,label,body):
    out=a.output/label;out.mkdir(parents=True,exist_ok=True)
    source=out/'task.c';source.write_text('void Task(unsigned id){'+body+'((void(*)(unsigned))0x08077509)(id);}')
    linker=out/'task.ld';linker.write_text('SECTIONS { .text 0x03004C00 : { *(.text*) *(.rodata*) } /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.ARM.exidx*) } }')
    prefix='/opt/devkitpro/devkitARM/bin/arm-none-eabi-'
    subprocess.run([prefix+'gcc','-mcpu=arm7tdmi','-mthumb','-Os','-ffreestanding','-fno-builtin','-nostdlib','-Wl,-T,'+str(linker),str(source),'-o',str(out/'task.elf')],check=True)
    subprocess.run([prefix+'objcopy','-O','binary',str(out/'task.elf'),str(out/'task.bin')],check=True)
    raw=state.read_bytes();native=Machine(rom,raw);code=(out/'task.bin').read_bytes();assert len(code)<=256
    native.u.mem_write(0x03004C00,code);native.call(0x0807741D,0x03004C01,0)
    prepared=bytearray(raw);prepared[0x19000:0x21000]=native.bytes(0x03000000,0x8000);prepared[0x21000:]=native.bytes(0x02000000,0x40000)
    path=out/'native-task.state';path.write_bytes(prepared)
    return drive(path,label+'-settled',frames=500)
field=task(a.state,'native-center-approach','((void(*)(unsigned,unsigned,int,int,int))0x0805538D)(5,4,-1,10,5);((void(*)(void))0x08055379)();((void(*)(void*))0x08000545)((void*)0x0805671D);')
require('native arrival uses Viridian Center',read(field,'arrival-check')['map']==[5,4])
# Native APIs remove only the same ROM-verified nonprogress placeholders as the
# maintained enable replay. They never target service NPC6 or followerNPC20.
def romword(at):return int.from_bytes(rom[at-0x08000000:at-0x08000000+4],'little')
group=romword(0x083526A8+5*4);header=romword(group+4*4);events=romword(header+4);count=rom[events-0x08000000];templates=romword(events+4)
by_id={rom[templates-0x08000000+n*24]:rom[templates-0x08000000+n*24:templates-0x08000000+(n+1)*24] for n in range(count)}
require('only native dummy flag0x200 templates removed',all(local in by_id and int.from_bytes(by_id[local][20:22],'little')==0x200 for local in range(7,20)))
field=task(field,'native-placeholder-approach','for(unsigned local=7;local<=19;local++)((void(*)(unsigned,unsigned,unsigned))0x0805E4C9)(local,4,5);')
field=drive(field,'face-original-service-npc',('1:4:DOWN',),120)
for page in range(6):
    field=drive(field,f'original-return-dialogue-{page}',('1:4:A',))
    if not read(field,f'choice-{page}')['enabled']:break
result=read(field,'final')
passed=not result['enabled'] and result['metadata'][0]==0 and bytes.fromhex(result['followerState'])[0]==0
if passed:
    require('actual native dialogue cleared flag1055',not result['enabled'])
    require('native follower state became inactive',bytes.fromhex(result['followerState'])[0]==0)
    require('native metadata publishes no follower',result['metadata'][0]==0)
    app=Path(__file__).resolve().parents[1]
    subprocess.run([sys.executable,str(app/'PrototypeTools/verify-followers.py'),'--rom',str(a.rom),'--state',str(field),'--output',str(a.output/'app-decoder-returned')],cwd=app,check=True)
require('source exact ROM unchanged',a.rom.read_bytes()==rom)
require('source enabled state unchanged',a.state.read_bytes()==seed)
report={'passed':passed,'disableDialogueProven':passed,'checks':checks,'count':len(checks),'observations':observations,
    'romSHA256':hashlib.sha256(rom).hexdigest(),'sourceStateSHA256':hashlib.sha256(seed).hexdigest(),
    'provenance':'Native task APIs warp an already real-enabled exact-ROM state to Center10,5 and remove only dummy flag0x200 templates7..19. Native DOWN faces guy, actual A advances original question/Yes. No follower/flag/outcome writes.'}
(a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print('Native follower disable dialogue', 'PASS' if passed else 'UNPROVEN',len(checks))
if not passed:sys.exit(2)

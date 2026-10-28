#!/usr/bin/env python3
"""Replay the original Viridian Center follower service on an exact cartridge.

Native task APIs place the player and remove only flagged placeholder NPCs before
interaction. The real dialogue buttons toggle the service; no flag, Pokémon,
follower state, sprite, or successful gameplay endpoint is patched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import zlib

p=argparse.ArgumentParser(description=__doc__)
for name in ('rom','manifest','state','output'):p.add_argument('--'+name,type=Path,required=True)
p.add_argument('--verify-warp',action='store_true',help='Verify native follower relocation to Oak Lab and run actual app decoder there')
p.add_argument('--verify-disable-navigation',action='store_true',help='Also attempt the currently unverified native return route and require disable dialogue')
a=p.parse_args();game=Path(os.environ['BOUND_GAME_SOURCE']).resolve();sys.path.insert(0,str(game/'tools'))
from qa_python import ensure_qa_python
ensure_qa_python()
from game_elimination_storage_native import Machine
from integrated_game import verify_image
from verify_integrated_gameplay import memory
rom=a.rom.read_bytes();seed=a.state.read_bytes();verify_image(rom,json.loads(a.manifest.read_text()))
assert len(seed)==0x61000 and struct.unpack_from('<I',seed,8)[0]==zlib.crc32(rom)
a.output.mkdir(parents=True,exist_ok=True);checks=[];observations=[]
def require(label,test):
    assert test,label
    checks.append(label)
def word(m,at):return int.from_bytes(m.read(at,4),'little')
def observation(path,label):
    m=memory(path);save=word(m,0x03005008);state=m.read(0x0203B818,24);published=[word(m,0x02002000+n) for n in range(96,128,4)]
    result={'label':label,'state':str(path),'map':list(m.read(save+4,2)),'tile':list(struct.unpack('<hh',m.read(save,4))),
        'enabled':bool(m.read(0x0203B25E,1)[0]&0x20),'followerState':state.hex(),'metadata':published,'active':state[0]==1}
    observations.append(result);return result

def drive(state,label,inputs=(),frames=240):
    out=a.output/label;out.mkdir(parents=True,exist_ok=True)
    cmd=[sys.executable,str(game/'tools/map_emulator.py'),'--rom',str(a.rom),'--state-in',str(state),'--output',str(out),
        '--frames',str(frames),'--rtc-ms','1735689600000','--state-out',f'{frames}:{out}/final.state','--screenshot-at',str(frames)]
    for button in inputs:cmd+=['--input',button]
    subprocess.run(cmd,cwd=game,check=True,stdout=subprocess.DEVNULL)
    path=out/'final.state';observation(path,label);return path

def task(state,label,body):
    out=a.output/label;out.mkdir(parents=True,exist_ok=True)
    source=out/'task.c';source.write_text('void Task(unsigned id){'+body+'((void(*)(unsigned))0x08077509)(id);}')
    layout=out/'task.ld';layout.write_text('SECTIONS { .text 0x03004C00 : { *(.text*) *(.rodata*) } /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.ARM.exidx*) } }')
    prefix='/opt/devkitpro/devkitARM/bin/arm-none-eabi-'
    subprocess.run([prefix+'gcc','-mcpu=arm7tdmi','-mthumb','-Os','-ffreestanding','-fno-builtin','-nostdlib','-Wl,-T,'+str(layout),str(source),'-o',str(out/'task.elf')],check=True)
    subprocess.run([prefix+'objcopy','-O','binary',str(out/'task.elf'),str(out/'task.bin')],check=True)
    raw=state.read_bytes();native=Machine(rom,raw);code=(out/'task.bin').read_bytes();assert len(code)<=256
    native.u.mem_write(0x03004C00,code);native.call(0x0807741D,0x03004C01,0)
    prepared=bytearray(raw);prepared[0x19000:0x21000]=native.bytes(0x03000000,0x8000);prepared[0x21000:]=native.bytes(0x02000000,0x40000)
    path=out/'native-task.state';path.write_bytes(prepared)
    return drive(path,label+'-settled',frames=500)

# Original SetWarpDestination, WarpIntoMap and map-load callback.
field=task(a.state,'native-center-preparation','((void(*)(unsigned,unsigned,int,int,int))0x0805538D)(5,4,-1,10,7);((void(*)(void))0x08055379)();((void(*)(void*))0x08000545)((void*)0x0805671D);')
require('exact Viridian City Pokemon Center selected',observation(field,'center-check')['map']==[5,4])
# The debug seed exposes nonprogress dummy templates with flag0x200. Their native
# removal leaves room for the service script ADDOBJECT20 before specialD1.
def romword(at):return int.from_bytes(rom[at-0x08000000:at-0x08000000+4],'little')
group=romword(0x083526A8+5*4);header=romword(group+4*4);events=romword(header+4)
count=rom[events-0x08000000];templates=romword(events+4)
by_id={rom[templates-0x08000000+n*24]:rom[templates-0x08000000+n*24:templates-0x08000000+(n+1)*24] for n in range(count)}
require('only declared dummy NPC templates removed',all(local in by_id and int.from_bytes(by_id[local][20:22],'little')==0x200 for local in range(7,20)))
cleanup='for(unsigned local=7;local<=19;local++)((void(*)(unsigned,unsigned,unsigned))0x0805E4C9)(local,4,5);'
field=task(field,'native-placeholder-preparation',cleanup)
field=drive(field,'face-service-guy',('1:4:UP',),120)
off=field
require('service starts disabled',not observation(field,'before-dialogue')['enabled'])
for page in range(6):
    field=drive(field,f'native-enable-dialogue-{page}',('1:4:A',))
    if observation(field,f'enable-{page}-check')['active']:break
live=observation(field,'enabled-complete')
require('actual Yes enabled service flag1055',live['enabled'])
require('actual Yes attached native Pokemon follower',live['active'])
require('native exact selected metadata active',live['metadata'][0]&3==3)
require('native follower origin is service Pokemon20',bytes.fromhex(live['followerState'])[4:7]==bytes([20,4,5]))
walk=drive(field,'native-following-walk',('1:8:DOWN',))
after=observation(walk,'walking-complete')
require('native following persists through real walking',after['active'] and after['metadata'][0]==7)
require('real walking changed player position',after['tile']!=live['tile'])
# Native off-state is independently read before service activation. A later
# return-to-service disable route is optional and not claimed by the smoke run.
disable_proven=False
if a.verify_disable_navigation:
    field=drive(walk,'return-to-service-guy',('1:8:LEFT','40:48:UP','80:88:RIGHT','120:124:UP'))
    require('native route around follower returns to guy',observation(field,'return-check')['tile']==[10,7])
    for page in range(6):
        field=drive(field,f'native-disable-dialogue-{page}',('1:4:A',))
        if not observation(field,f'disable-{page}-check')['enabled']:break
    inactive=observation(field,'disabled-complete')
    require('actual dialogue disabled flag1055',not inactive['enabled'])
    require('disabled metadata does not publish active follower',inactive['metadata'][0]&6==0)
    off=field;disable_proven=True
warped=None
if a.verify_warp:
    warped=task(walk,'native-following-warp-preparation','((void(*)(unsigned,unsigned,int,int,int))0x0805538D)(4,3,-1,6,10);((void(*)(void))0x08055379)();((void(*)(void*))0x08000545)((void*)0x0805671D);')
    warped=drive(warped,'native-following-after-warp',('1:8:DOWN',))
    after_warp=observation(warped,'warp-complete')
    require('native follower persists in Oak Lab after warp',after_warp['map']==[4,3] and after_warp['metadata'][0]==7)
    require('native follower object is reassigned after warp',after_warp['metadata'][1]!=after['metadata'][1])
    require('native warp preserves selected Pokemon identity',after_warp['metadata'][2:7]==after['metadata'][2:7])
    require('native warp changes follower generation',after_warp['metadata'][7]!=after['metadata'][7])
# Run the actual app decoder and compositor/packet tests on both real snapshots.
app=Path(__file__).resolve().parents[1]
decoder_states=[('enabled',walk),('disabled' if disable_proven else 'initially-off',off)]
if warped:decoder_states.append(('after-warp',warped))
for label,state in decoder_states:
    subprocess.run([sys.executable,str(app/'PrototypeTools/verify-followers.py'),'--rom',str(a.rom),'--state',str(state),'--output',str(a.output/('app-decoder-'+label))],cwd=app,check=True)
require('source cartridge unchanged',a.rom.read_bytes()==rom)
require('source cold state unchanged',a.state.read_bytes()==seed)
report={'passed':True,'checks':checks,'count':len(checks),'romSHA256':hashlib.sha256(rom).hexdigest(),
    'seedSHA256':hashlib.sha256(seed).hexdigest(),'observations':observations,'disableDialogueProven':disable_proven,
    'unverified':[] if disable_proven else ['Native enabled-to-disabled dialogue navigation; initial native disabled state is verified separately.'],
    'provenance':'Exact supplied cold seed; native task map placement and removal of map dummy NPC7..19 before real service dialogue; no direct service flag/state/special writes. Actual A enable and directional walk; disableDialogueProven records whether the optional return route completed; app source decoder reads resulting RAM/sprite ROM data.'}
(a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print('Actual native follower service PASS',len(checks),'checks',report['romSHA256'])

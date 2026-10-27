#!/usr/bin/env python3
"""Drive an original Route 3 raid den in isolated mGBA fixture branches.

Preparation uses native givemon and warp scripts, never opponent party writes.
The fixture cartridge applies the same verified runtime shim as Bound; source
ROM and source state stay unchanged and their hashes are recorded separately.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import subprocess

ROOT=Path(__file__).resolve().parents[1]
GAME=ROOT.parent/'multi_red-multiplayer-isolation'
sys.path.insert(0,str(GAME/'tools'))
from qa_python import ensure_qa_python
ensure_qa_python()
from integrated_game import verify_image
from verify_doubles_admission import run,script_writes,warp,word
from verify_integrated_gameplay import memory

def native_fixture(image):
    header=(ROOT/'Delta/Bound/SoulLink/BoundSoulCode.h').read_text()
    symbols={n:int(v,16) for n,v in re.findall(r'(BoundSoul\w+)Address=0x([0-9A-F]+)',header)}
    code=bytes(int(v,16) for v in re.findall(r'0x([0-9A-F]{2})(?=[,}])',header.split('BoundSoulCode[]={')[1]))
    result=bytearray(image);assert result[0x1FF8000:0x1FFF800]==bytes([255])*(0x7800)
    result[0x1FF8000:0x1FF8000+len(code)]=code
    for offset,name in [(0x3FBE8,'BoundSoulGet'),(0x4037C,'BoundSoulSet'),(0x107D790,'BoundSoulGive'),(0x107DF6C,'BoundSoulCatchBlocked')]:
        result[offset:offset+8]=bytes.fromhex('004b1847')+struct.pack('<I',symbols[name])
    result[0x104575D:0x1045765]=bytes([5])+struct.pack('<I',symbols['BoundSoulPrizeScript'])+bytes(3)
    struct.pack_into('<II',result,0x1FFA000,0x314C5342,0)
    result[0x1FFE008:0x1FFE028]=bytes(32)
    return bytes(result)

def status(mem):
    save=word(mem,0x03005008)
    save2=word(mem,0x0300500C)
    party=mem.read(0x02024284,600)
    return {'callback':hex(word(mem,0x030030F4)),'battle':bool(mem.read(0x03003529,1)[0]&2),'flags':hex(word(mem,0x02022B4C)),
        'script':hex(word(mem,0x03000EB8)),'outcome':mem.read(0x02023E8A,1)[0],
        'location':list(mem.read(save+4,2)),'count':mem.read(0x02024029,1)[0],'money':word(mem,save+0x290)^word(mem,save2+0xF20),
        'party':[{'species':int.from_bytes(party[n*100+32:n*100+34],'little'),'hp':int.from_bytes(party[n*100+86:n*100+88],'little'),'level':party[n*100+84],
                  'moves':list(struct.unpack_from('<4H',party,n*100+44))} for n in range(6)],
        'enemy':[{'species':int.from_bytes(mem.read(0x0202402C+n*100+32,2),'little'),'hp':int.from_bytes(mem.read(0x0202402C+n*100+86,2),'little')} for n in range(2)],
        'command':mem.read(0x02022BC4,1)[0],'exec':word(mem,0x02023BC8),'acquisitions':word(mem,0x03004884)}

def native_map_loader(output,money=None,full=False):
    source=output/'native-map-loader.c';layout=output/'native-map-loader.ld'
    prepare=''
    if full:
        header=(ROOT/'Delta/Bound/SoulLink/BoundSoulCode.h').read_text()
        original=int(re.search(r'BoundSoulOriginalGiveAddress=0x([0-9A-F]+)',header)[1],16)
        prepare+='unsigned char temporary[100]; void (*create)(void *,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned)=(void *)0x0803DA55; '
        prepare+='for(unsigned i=0;i<6;i++)create((void *)(0x02024284+100*i),4,24,31,1,0xE1000000+i,0,0); *(volatile unsigned char *)0x02024029=6; '
        prepare+=f'for(unsigned i=0;i<750;i++){{create(temporary,129,5,31,1,0xE2000000+i,0,0);((unsigned (*)(void *))0x{original:08X})(temporary);}} '
        prepare+='*(volatile unsigned *)0x03004D00=((unsigned (*)(void))0x08040F6D)(); '
    if money is not None:prepare+=f'((void (*)(void *,unsigned))0x0809FD71)((void *)(*(volatile unsigned *)0x03005008+0x290),{money}); '
    source.write_text('void LoadMap(void) { '+prepare+'((void (*)(void))0x08055379)(); ((void (*)(void *))0x08000545)((void *)0x0805671D); }\n')
    base=0x03004A40 if full else 0x03004C00
    layout.write_text(f'SECTIONS {{ .text 0x{base:08X} : {{ *(.text*) *(.rodata*) }} /DISCARD/ : {{ *(.comment) *(.ARM.attributes) *(.ARM.exidx*) }} }}')
    prefix='/opt/devkitpro/devkitARM/bin/arm-none-eabi-'
    subprocess.run([prefix+'gcc','-mcpu=arm7tdmi','-mthumb','-Os','-ffreestanding','-fno-builtin','-nostdlib','-Wl,-T,'+str(layout),'-o',str(output/'native-map-loader.elf'),str(source)],check=True,capture_output=True)
    subprocess.run([prefix+'objcopy','-O','binary',str(output/'native-map-loader.elf'),str(output/'native-map-loader.bin')],check=True)
    code=(output/'native-map-loader.bin').read_bytes()
    code+=bytes((-len(code))%4)
    assert len(code)<0x03004D00-base
    return [(base+n,int.from_bytes(code[n:n+4],"little"),4) for n in range(0,len(code),4)]

def audit_evidence(root,image):
    """Verify retained real-engine checkpoints; do not manufacture outcomes."""
    raid=root/'raid-den-level24';checks=[]
    def require(label,condition):
        assert condition,label
        checks.append(label)
    def checkpoint(directory):
        data=memory(directory/'final.state')
        report=json.loads((directory/'run-report.json').read_text())
        require(str(directory.relative_to(root))+' has rendered evidence',bool(report['screenshots']))
        return data
    def number(mem,address,width=4):return int.from_bytes(mem.read(address,width),'little')
    def rows(mem):return [mem.read(0x0300488C+i*12,12) for i in range(number(mem,0x03004884))]
    def pc(mem):
        result=[]
        for box in range(25):
            base=struct.unpack_from('<I',image,0x1148930+box*4)[0]
            for slot in range(30):
                record=mem.read(base+slot*58,58)
                if int.from_bytes(record[28:30],'little'):result.append((box,slot,record))
        return result
    def balls(mem):
        base=number(mem,0x0203989C);key=number(mem,0x0300500C)
        key=number(mem,key+0xF20)&65535
        return sum(number(mem,base+i*4+2,2)^key for i in range(50) if number(mem,base+i*4,2)==1)
    prepared=checkpoint(raid/'den-field');start=checkpoint(raid/'start-000');defeat=checkpoint(raid/'fire-fang-000')
    caught=checkpoint(raid/'catch-master-000');field=checkpoint(raid/'reward-held-a')
    require('original native boss starts at 224 HP',number(start,0x0202402C+86,2)==224)
    require('raid flags native DYNAMAX',bool(number(start,0x02022B4C)&0x40000000))
    require('boss defeated by native battle',number(defeat,0x0202402C+86,2)==0)
    require('native caught outcome',number(caught,0x02023E8A,1)==7)
    require('original owner party restored',number(field,0x02024029,1)==3)
    require('native raid rewards finish and field unlocks',number(field,0x03000EB1,1)==0 and number(field,0x03000EB8)==0 and word(field,0x030030F4)==0x080565B5)
    raid_receipt=rows(field)[3]
    require('one Route 3 ordinary/raid receipt',len(rows(field))==4 and int.from_bytes(raid_receipt[8:12],'little')==0x6700)
    stored=[(box,slot,data) for box,slot,data in pc(field) if data[:8]==raid_receipt[:8]]
    require('real caught boss stored in compressed PC',len(stored)==1 and int.from_bytes(stored[0][2][28:30],'little')==1208)
    # Combat and catch inputs must never write an opponent, HP or outcome.
    combat_reports=[]
    for path in sorted(raid.glob('*/run-report.json')):
        if path.parent.name.startswith(('combat-','finish-combat-','fire-fang-','catch-master-','wildfirst-combat-','wildfirst-defeat-')):
            report=json.loads(path.read_text());require(path.parent.name+' uses only controller inputs',not report['requested_memory_writes'] and not report['requested_host_port_writes']);combat_reports.append(str(path))
    after=checkpoint(raid/'postraid-bag-deny-000')
    require('raid then wild preserves Master Ball quantity',balls(field)==balls(after)==2)
    require('raid then wild creates no second receipt',rows(after)==rows(field))
    wild=checkpoint(raid/'wildfirst-catch-000');reverse=checkpoint(raid/'wildfirst-raid-deny-000')
    require('wild first acquired actual fourth party member',number(wild,0x02024029,1)==4 and len(rows(wild))==4)
    require('wild then raid preserves balls and receipts',balls(wild)==balls(reverse)==2 and rows(wild)==rows(reverse))
    shop=root/'celadon-fixed';before=checkpoint(shop/'prepared-field');purchase=checkpoint(shop/'purchase-003');repeat=checkpoint(shop/'purchase-006')
    require('actual clerk purchase costs 200000 once',status(before)['money']==999999 and status(purchase)['money']==799999 and status(repeat)['money']==799999)
    require('actual clerk gives one Dratini and one prize receipt',number(purchase,0x02024029,1)==4 and number(purchase,0x020243B0+32,2)==147 and len(rows(purchase))==5 and rows(purchase)[4][8]==2)
    require('repeat clerk preserves party and acquisition journal',rows(purchase)==rows(repeat) and purchase.read(0x02024284,600)==repeat.read(0x02024284,600))
    full=root/'celadon-full-fixed';fullbefore=checkpoint(full/'prepared-field');fullafter=checkpoint(full/'reject-000')
    require('native full storage fixture has six plus 750',number(fullbefore,0x02024029,1)==6 and len(pc(fullbefore))==750 and number(fullbefore,0x03004D00)==1)
    require('full storage clerk preserves money and receipts',status(fullbefore)['money']==status(fullafter)['money']==999999 and rows(fullbefore)==rows(fullafter))
    require('full storage clerk preserves all 750 PC records',pc(fullbefore)==pc(fullafter))
    health=json.loads((raid/'pc-health.json').read_text());require('native PC conversion restores caught boss health',health['passed'] and health['hp']==health['maximum_hp']==56 and health['identity']==raid_receipt[:8].hex())
    return {'passed':True,'checks':checks,'source_rom_sha256':hashlib.sha256(image).hexdigest(),
        'raid_runtime_fixture_sha256':hashlib.sha256((raid/'runtime-fixture.gba').read_bytes()).hexdigest(),
        'final_clerk_runtime_fixture_sha256':hashlib.sha256((shop/'runtime-fixture.gba').read_bytes()).hexdigest(),
        'raid_provenance':json.loads((raid/'provenance.json').read_text()),'raid_receipt':raid_receipt.hex(),
        'native_own_moves':status(prepared)['party'][:3],
        'move_provenance':'Original native givemon bytecode constructs level24 species5,8,2. No setmove opcode or move-record write is used. Exact-ROM species5 naturally receives move IDs246,431,184,9; rendered labels include Force Palm and Fire Fang. IDs are reported from this modified game, without vanilla name inference.',
        'caught_placement':{'box':stored[0][0],'slot':stored[0][1]},'native_pc_health':health,
        'combat_reports':combat_reports,'observed_rendered_messages':{'raid_then_wild':'postraid-bag-deny-000/frame-000600.png: Pokémon cannot be caught',
        'wild_then_raid':'wildfirst-raid-deny-000/frame-000240.png: Pokémon cannot be caught',
        'repeat_prize':'celadon-fixed/purchase-006/frame-000600.png: One prize POKéMON per Soul Link run',
        'full_storage':'celadon-full-fixed/reject-000/frame-000600.png: No more room for POKéMON'},
        'limits':'Controlled synthetic native party, one-badge eligibility and native map placement; actual original den NPC, selectors, boss, legal native learned moves, turns, capture, rewards and field return run under mGBA with normal buttons. No opponent/outcome/HP writes or UI endpoint stubs. PC withdrawal health is a native conversion boundary in copied RAM; its menu and PC-slot deletion were not exercised. Raid evidence predates the isolated final Celadon capacity guard; final guard separately passes real UI and ten native acquisition/storage cases. No physical-device/WAN claim.'}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rom',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True)
    p.add_argument('--state',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--phase',choices=['prepare','drive','warp','audit'],default='prepare');p.add_argument('--batches',type=int,default=10)
    p.add_argument('--from-state',type=Path);p.add_argument('--keys',default='A')
    p.add_argument('--script',type=lambda v:int(v,0))
    p.add_argument('--native',type=lambda v:int(v,0))
    p.add_argument('--input',action='append',default=[]);p.add_argument('--frames',type=int,default=600)
    p.add_argument('--label');p.add_argument('--level',type=int,default=15);p.add_argument('--species',default='25,1,133')
    p.add_argument('--destination',default='10,15,2,3');p.add_argument('--money',type=int);p.add_argument('--full-storage',action='store_true')
    a=p.parse_args();a.output=a.output.resolve()
    assert a.output.is_relative_to(Path('/Users/evandev/dev/bound_multiplayer/artifacts/multiplayer-isolation/encounter-rules/gameplay'))
    a.output.mkdir(parents=True,exist_ok=True)
    image=a.rom.read_bytes();verify_image(image,json.loads(a.manifest.read_text()))
    if a.phase=='audit':
        report=audit_evidence(a.output,image);(a.output/'full-gameplay-report.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps({'passed':report['passed'],'checks':len(report['checks'])}));return
    fixture=a.output/'runtime-fixture.gba'
    if a.phase=='prepare':
        fixture.write_bytes(native_fixture(image))
        gifts=bytearray([0x23])+struct.pack('<I',0x0803DA15)
        species_list=list(map(int,a.species.split(',')));assert len(species_list)==3 and 1<=a.level<=30
        for species in species_list:gifts+=bytes([0x79])+struct.pack('<HBH',species,a.level,0)+bytes(9)
        # Exact native rank table grants no raid rank at zero badges and rank
        # one after badge 1. This is a synthetic eligibility prerequisite, not
        # evidence of a played Brock victory or any alteration of this boss.
        gifts+=bytes([0x29])+struct.pack('<H',0x820)
        gifts+=bytes([0x44])+struct.pack('<HH',1,3)+bytes([0x6B,2])
        prepared=a.output/'party';m=run(fixture,a.state,prepared,600,writes=script_writes(gifts),screens=[600])
        print('party',json.dumps(status(m)),flush=True)
        # Synthetic location setup invokes the same native WarpIntoMap +
        # SetMainCallback2(CB2_LoadMap) as a completed warp task. It omits the
        # unrelated fade/music wait, while retaining native map initialization.
        warp_script=bytes([0x3E,3,21,255,75,0,12,0,0x23])+struct.pack('<I',0x03004C01)+bytes([2])
        field=a.output/'den-field';m=run(fixture,prepared/'final.state',field,600,writes=script_writes(warp_script)+native_map_loader(a.output),screens=[600])
        print('den-field',json.dumps(status(m)),flush=True)
        previous=field/'final.state'
        provenance={'source_rom_sha256':hashlib.sha256(image).hexdigest(),'runtime_fixture_sha256':hashlib.sha256(fixture.read_bytes()).hexdigest(),
            'source_state_sha256':hashlib.sha256(a.state.read_bytes()).hexdigest(),'native_den':{'group':3,'number':21,'object':10,'script':'0x0905285A'},
            'own_party':{'species':species_list,'level':a.level,'native_generated':True},'opponent_records_written':False,
            'synthetic_progression':{'native_flag_set':'0x820','purpose':'One-badge eligibility for native rank-one raids; not a played Brock victory'},
            'limits':'Synthetic party and native warp to original den; subsequent controls are normal inputs. Runtime-only Bound shim copied to private fixture image, source cartridge/state preserved.'}
        (a.output/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    elif a.phase=='warp':
        if not fixture.exists():fixture.write_bytes(native_fixture(image))
        group,number,x,y=map(int,a.destination.split(','));base=0x03004A40 if a.full_storage else 0x03004C00
        script=bytes([0x3E,group,number,255,x,0,y,0,0x23])+struct.pack('<I',base|1)+bytes([2])
        dest=a.output/'prepared-field';m=run(fixture,a.from_state,dest,900,writes=script_writes(script)+native_map_loader(a.output,a.money,a.full_storage),screens=[900]);previous=dest/'final.state'
        print('prepared-field',json.dumps(status(m)),flush=True)
    else:previous=a.from_state
    assert previous
    history=[]
    for index in range(a.batches):
        dest=a.output/(f'admission-{index:03d}' if a.phase=='prepare' else f'{a.label or "drive-"+previous.parent.name}-{index:03d}')
        inputs=a.input or [f'{n}:{n+3}:{a.keys}' for n in range(10,a.frames-10,60)]
        if a.phase=='prepare' and index==0:inputs=['1:8:UP']+inputs
        writes=script_writes(None,a.script) if a.script and index==0 else script_writes(bytes([0x23])+struct.pack('<I',a.native)+bytes([2])) if a.native and index==0 else ()
        m=run(fixture,previous,dest,a.frames,inputs=inputs,writes=writes,screens=[a.frames]);previous=dest/'final.state'
        event={'branch':str(dest),'status':status(m)};history.append(event);print(json.dumps(event),flush=True)
    (a.output/('prepare-history.json' if a.phase=='prepare' else 'drive-history-'+a.from_state.parent.name+'.json')).write_text(json.dumps(history,indent=2)+'\n')

if __name__=='__main__':main()

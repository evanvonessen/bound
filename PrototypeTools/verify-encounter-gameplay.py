#!/usr/bin/env python3
"""Execute native encounter acquisition/storage against isolated exact-ROM RAM.

Synthetic fixtures branch from an exact-CRC native new-game state. Original
capture, creation and storage endpoints execute; provenance is recorded.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT.parent / 'multi_red-multiplayer-isolation'
sys.path.insert(0, str(GAME / 'tools'))
from qa_python import ensure_qa_python
ensure_qa_python()
from integrated_game import verify_image
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_CODE, UC_HOOK_INTR
from unicorn.arm_const import *
LAYOUT=(ROOT/'Delta/Bound/SoulLink/soul-layout.h').read_text()
RING=int(re.search(r'BOUND_SOUL_ACQUISITION_ADDRESS (0x[0-9A-Fa-f]+)u',LAYOUT)[1],16)

class Machine:
    def __init__(self, rom, seed, code, symbols):
        self.u = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
        self.u.ctl_set_cpu_model(UC_CPU_ARM_TI925T)
        for addr, size in [(0x08000000,0x2000000),(0x02000000,0x40000),(0x03000000,0x8000),(0x04000000,0x1000),(0x05000000,0x1000),(0x06000000,0x20000),(0x07000000,0x1000),(0x0A000000,0x1000)]: self.u.mem_map(addr,size)
        self.u.mem_write(0x08000000,rom)
        self.u.mem_write(0x02000000,seed[0x21000:])
        self.u.mem_write(0x03000000,seed[0x19000:0x21000])
        self.u.mem_write(0x09FF8000,code)
        for addr,name in [(0x0803FBE8,'BoundSoulGet'),(0x0804037C,'BoundSoulSet'),(0x0907D790,'BoundSoulGive'),(0x0907DF6C,'BoundSoulCatchBlocked')]:
            self.u.mem_write(addr,bytes.fromhex('004b1847')+struct.pack('<I',symbols[name]))
        self.u.mem_write(0x0904575D,bytes([5])+struct.pack('<I',symbols['BoundSoulPrizeScript'])+bytes(3))
        self.put(0x09FFA000,0x314C5342)
        self.u.mem_write(0x09FFE008,bytes(32))
        self.u.mem_write(RING,bytes(396))
        self.calls={};self.observers={};self.trace=[]
        self.u.hook_add(UC_HOOK_CODE,self.hook)
        self.u.hook_add(UC_HOOK_INTR,self.interrupt)
    def put(self,addr,value,n=4):self.u.mem_write(addr,value.to_bytes(n,'little'))
    def read(self,addr,n=4):return int.from_bytes(self.u.mem_read(addr,n),'little')
    def hook(self,uc,addr,size,data):
        self.trace.append(addr)
        if len(self.trace)>32:self.trace.pop(0)
        if addr==0x0A000000:uc.emu_stop();return
        if addr in [0x0907D790,0x08040B14,0x0802D800,0x0802D434]:self.calls[hex(addr)]=self.calls.get(hex(addr),0)+1
        if addr in self.observers:
            result=self.observers[addr](self)
            if result is not None:
                uc.reg_write(UC_ARM_REG_R0,result)
                uc.reg_write(UC_ARM_REG_PC,uc.reg_read(UC_ARM_REG_LR))
    def interrupt(self,uc,intno,data):
        pc=uc.reg_read(UC_ARM_REG_PC);opcode=self.read(pc-2,2)&255
        a,b,c=[uc.reg_read(r) for r in [UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2]]
        if opcode in [11,12]:
            width=4 if opcode==12 or c&(1<<26) else 2
            count=(c&0x1fffff)*width
            if opcode==12:count=(count+31)&~31
            source=bytes(uc.mem_read(a,width if c&(1<<24) else count))
            uc.mem_write(b,source*(count//width) if c&(1<<24) else source)
        elif opcode==8:uc.reg_write(UC_ARM_REG_R0,math.isqrt(a))
        else:raise RuntimeError(('unsupported BIOS call',opcode,hex(pc)))
    def call(self,addr,*args,count=2000000):
        self.trace=[]
        self.u.reg_write(UC_ARM_REG_CPSR,0x20)
        self.u.reg_write(UC_ARM_REG_SP,0x03007D00)
        self.u.reg_write(UC_ARM_REG_LR,0x0A000001)
        for reg,val in zip([UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3],args):self.u.reg_write(reg,val)
        for index,val in enumerate(args[4:]):self.put(0x03007D00+index*4,val)
        try:self.u.emu_start(addr|1,0x0A000002,count=count)
        except Exception as e:raise RuntimeError((hex(addr),str(e),[hex(v) for v in self.trace])) from e
        if self.u.reg_read(UC_ARM_REG_PC)!=0x0A000000:raise RuntimeError(('native instruction budget',hex(addr),[hex(v) for v in self.trace]))
        assert self.u.reg_read(UC_ARM_REG_SP)==0x03007D00
        return self.u.reg_read(UC_ARM_REG_R0)
    def field_script(self,script,*,yes=1,menu=0):
        """Native interpreter with UI-only decisions; native grants/costs run."""
        ctx=0x03000EB0;events=[]
        self.u.mem_write(ctx,bytes(0x74));self.put(ctx+1,1,1);self.put(ctx+8,script)
        self.put(ctx+0x5C,0x0815F9B4);self.put(ctx+0x60,0x0815FD08)
        def visual(op,skip):
            def observe(machine):
                pointer=machine.read(ctx+8)
                events.append({'opcode':hex(op),'script':hex(pointer-1)})
                machine.put(ctx+8,pointer+skip)
                return 0
            return observe
        for op,skip in [(0x69,0),(0x6A,0),(0x5A,0),(0x66,0),(0x67,4),(0x6D,0),(0x6B,0),(0x6C,0),(0x27,0),(0x32,0)]:
            self.observers[self.read(0x0815F9B4+4*op)&~1]=visual(op,skip)
        def message(machine):
            pointer=machine.read(ctx+8);kind=machine.read(pointer,1)
            events.append({'opcode':'callstd','kind':kind,'text':hex(machine.read(ctx+100)),'script':hex(pointer-1)})
            machine.put(ctx+8,pointer+1)
            if kind==5:machine.put(0x020370D0,yes,2)
            return 0
        def special(machine):
            pointer=machine.read(ctx+8);kind=machine.read(pointer,2)
            if kind!=0x158:return None
            events.append({'opcode':'special','kind':kind,'selection':menu,'script':hex(pointer-1)})
            machine.put(ctx+8,pointer+2);machine.put(0x020370D0,menu,2)
            return 0
        self.observers[self.read(0x0815F9B4+4*0x09)&~1]=message
        self.observers[self.read(0x0815F9B4+4*0x25)&~1]=special
        for tick in range(100):
            self.call(0x08069805,ctx)
            if self.read(ctx+1,1)==0:break
        else:raise AssertionError(('field script never ended',hex(self.read(ctx+8)),events[-8:]))
        self.observers.clear()
        return events

def capture(rom,seed,code,symbols,*,full=False,raid=False,static=False):
    m=Machine(rom,seed,code,symbols);mon=0x0202402C
    if full:
        for index in range(6):m.call(0x0803DA55,0x02024284+100*index,4,5,31,1,0x10000000+index,0,0)
        m.put(0x02024029,6,1)
    m.call(0x0803DA55,mon,1,5,31,1,0xABCDEF01,0,0)
    m.u.mem_write(0x02010000,bytes(0x4000));m.put(0x0203E038,0x02010000)
    m.u.mem_write(0x02014000,bytes(0x1000));m.put(0x02023FE8,0x02014000)
    m.put(0x02022B4C,0x40002000 if raid else 0x42000 if static else 0);m.put(0x03003529,m.read(0x03003529,1)|2,1)
    m.call(0x0806E681 if raid else 0x0806E6A9,0x0919)
    m.put(0x02023BC8,0);m.put(0x02023BCC,2,1)
    m.u.mem_write(0x02023BCE,bytes(8));m.u.mem_write(0x02023BD6,bytes([0,1,2,3]))
    m.put(0x02023D6B,0,1);m.put(0x02023D6C,1,1);m.put(0x02023D68,1,2)
    # Begin the measured battle after synthetic party construction. Replacing
    # the seed's existing starter is fixture preparation, not a gameplay faint.
    m.u.mem_write(0x03004500,bytes(268))
    if raid:
        m.put(0x0201BFF0,0,2);m.call(0x0804037D,mon,57,0x0201BFF0)
    for bank in [0,1]:
        battlemon=0x02023BE4+bank*88
        m.put(battlemon,1,2);m.put(battlemon+0x28,0 if raid and bank else 15,2);m.put(battlemon+0x2A,5,1);m.put(battlemon+0x2C,20,2)
    before_party=bytes(m.u.mem_read(0x02024284,600))
    m.call(m.read(0x0903F2DC))
    success=m.read(0x02023D74)
    assert success==0x09003231,hex(success)
    steps=[]
    for step in range(250):
        ptr=m.read(0x02023D74);op=m.read(ptr,1);handler=m.read(0x0903EF20+op*4)
        steps.append({'pc':hex(ptr),'opcode':hex(op),'handler':hex(handler)})
        m.put(0x02023BC8,0) # Acknowledge presentation/controller commands only.
        m.put(0x0300311E,2 if op==0xF3 and m.read(0x02023E82,1)==1 else 0,2)
        m.call(handler)
        if op==0xF0:break
    else:raise AssertionError('native successful capture never reached placement')
    assert m.read(RING+4)==1,('ring',hex(RING),m.read(RING+4),'old',m.read(0x03004624),'calls',m.calls,'party',m.read(0x02024029,1),'policy',hex(m.read(0x09FFA000)),'steps',steps[-4:])
    assert m.read(RING+20)&255==(4 if static else 0),'static remains separate; ordinary and raid use area category'
    if raid:assert m.read(0x03004504)==0,'an enemy raid faint before capture must not become an owned loss'
    identity=bytes(m.u.mem_read(mon,8))
    if full:
        assert m.read(0x02024029,1)==6
        assert bytes(m.u.mem_read(0x02024284,600))==before_party
        matches=[]
        for box in range(25):
            base=m.read(0x09148930+box*4)
            for index in range(30):
                candidate=bytes(m.u.mem_read(base+58*index,58))
                if candidate[:8]==identity:matches.append({'box':box,'slot':index,'species':int.from_bytes(candidate[28:30],'little'),'sha256':hashlib.sha256(candidate).hexdigest()})
        assert len(matches)==1 and matches[0]['species']==1,matches
        placement=matches[0]
    else:
        assert m.read(0x02024029,1)==2
        assert bytes(m.u.mem_read(0x02024284+100,8))==identity
        assert m.call(0x0803FBE9,0x02024284+100,11,0)==1
        placement={'party_index':1,'species':1,'hp':m.call(0x0803FBE9,0x02024284+100,57,0)}
    assert m.calls.get('0x907d790')==1
    # The next alternative in this same native named area shares the catch.
    # Static acquisition remains separate from the ordinary/raid allowance.
    m.put(0x02022B4C,0 if raid or static else 0x40002000)
    shared_gate=m.call(symbols['BoundSoulCatchBlocked'])
    assert shared_gate==(0 if static else 1)
    return {'passed':True,'full_party':full,'raid_reward':raid,'static':static,'success_script':hex(success),'placement':placement,'steps':steps,'native_calls':m.calls,
        'next_alternative_blocked':bool(shared_gate),'receipt':bytes(m.u.mem_read(RING+12,12)).hex(),'limits':'Synthetic native battle/capture phase. Controller presentation commands acknowledged between native opcodes; boss defeat, full battle renderer, and overworld return are not exercised.'}

def gifts(rom,seed,code,symbols):
    m=Machine(rom,seed,code,symbols)
    script=0x0201C000
    # Native givemon Eevee and native giveegg Bulbasaur. These source-owned
    # fixture scripts use the exact native acquisition handlers and data types.
    fixture=bytes([0x79])+struct.pack('<H',133)+bytes([5])+bytes(11)+bytes([0x7A])+struct.pack('<H',1)+bytes([2])
    m.u.mem_write(script,fixture)
    ui=m.field_script(script)
    assert m.read(0x02024029,1)==3
    assert m.read(RING+4)==2
    assert m.read(RING+20)&255==1
    assert m.read(RING+32)&255==3
    assert m.call(0x0803FBE9,0x020242E8,11,0)==133
    assert m.read(0x0202434C+19,1)&4
    assert m.call(symbols['BoundSoulCatchBlocked'])==0
    return {'passed':True,'gift_species':133,'gift_source':1,'egg_source':3,'native_calls':m.calls,'ui':ui,
        'limits':'Synthetic givemon/giveegg script; native acquisition/storage endpoints execute without stubs. Hatching and Soul Link transport are validated separately.'}

def prize_shop(rom,seed,code,symbols,*,full=False):
    m=Machine(rom,seed,code,symbols)
    if full:
        for index in range(6):m.call(0x0803DA55,0x02024284+100*index,4,5,31,1,0x10000000+index,0,0)
        m.put(0x02024029,6,1)
    save=m.read(0x03005008);money=save+0x290
    m.put(save+4,10,1);m.put(save+5,15,1)
    m.call(0x0809FD71,money,999999)
    before=m.call(0x0809FD59,money)
    first=m.field_script(0x0904575D)
    after=m.call(0x0809FD59,money)
    assert m.read(0x02024029,1)==(6 if full else 2)
    assert before-after in [100000,200000]
    assert m.read(RING+4)==1 and m.read(RING+20)&255==2
    identity=bytes(m.u.mem_read(RING+12,8));placement={'party_index':1}
    if full:
        matches=[]
        for box in range(25):
            base=m.read(0x09148930+box*4)
            for slot in range(30):
                data=bytes(m.u.mem_read(base+58*slot,58))
                if data[:8]==identity:matches.append({'box':box,'slot':slot,'species':int.from_bytes(data[28:30],'little')})
        assert len(matches)==1 and matches[0]['species']==147,matches
        placement=matches[0]
    else:
        assert bytes(m.u.mem_read(0x020242E8,8))==identity
        assert m.call(0x0803FBE9,0x020242E8,11,0)==147
    assert m.call(symbols['BoundSoulCatchBlocked'])==0,'the city catch remains available after a prize'
    second=m.field_script(0x0904575D)
    assert m.call(0x0809FD59,money)==after
    assert m.read(0x02024029,1)==(6 if full else 2) and m.read(RING+4)==1
    assert bytes(m.u.mem_read(0x09046500,32))==rom[0x1046500:0x1046520]
    return {'passed':True,'placement':placement,'money_before':before,'money_after_first':after,'money_after_second':m.call(0x0809FD59,money),'native_calls':m.calls,'first_script_ui':first,'second_script_ui':second,'other_clerk_script_unchanged':True,
        'limits':'Synthetic direct clerk interaction in exact native interpreter; message/menu responses are UI-only observations. Native checkmoney, removemoney, CreateMon, GiveMonToPlayer and storage execute unchanged.'}

def prize_no_capacity(rom,seed,code,symbols):
    m=Machine(rom,seed,code,symbols)
    for index in range(6):m.call(0x0803DA55,0x02024284+100*index,4,5,31,1,0xE1000000+index,0,0)
    m.put(0x02024029,6,1)
    for index in range(750):
        m.call(0x0803DA55,0x0201D000,129,5,31,1,0xE2000000+index,0,0)
        m.call(symbols['BoundSoulOriginalGive'],0x0201D000)
    assert m.call(0x08040F6D)==1
    save=m.read(0x03005008);m.put(save+4,10,1);m.put(save+5,15,1)
    m.call(0x0809FD71,save+0x290,999999)
    ui=m.field_script(0x0904575D)
    assert m.call(0x0809FD59,save+0x290)==999999
    assert m.read(RING+4)==0 and m.read(0x02024029,1)==6
    assert m.call(0x08040F6D)==1
    return {'passed':True,'party_count':6,'pc_capacity':750,'native_capacity_full':True,
        'money_before':999999,'money_after':999999,'receipts':0,'ui':ui,
        'limits':'Native capacity fixture constructed with original GiveMonToPlayer; actual clerk script runs without currency/create/storage stubs. Visual callbacks only are observed.'}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rom',type=Path,required=True)
    p.add_argument('--state',type=Path,required=True)
    p.add_argument('--manifest',type=Path)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();rom=a.rom.read_bytes();seed=a.state.read_bytes()
    if a.manifest:verify_image(rom,json.loads(a.manifest.read_text()))
    else:assert hashlib.sha256(rom).hexdigest()=='fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00'
    assert len(seed)==0x61000 and int.from_bytes(seed[8:12],'little')==zlib.crc32(rom)
    assert a.output.resolve().is_relative_to(Path('/Users/evandev/dev/bound_multiplayer/artifacts/multiplayer-isolation/encounter-rules/gameplay'))
    a.output.mkdir(parents=True,exist_ok=True)
    header=(ROOT/'Delta/Bound/SoulLink/BoundSoulCode.h').read_text()
    symbols={n:int(v,16) for n,v in re.findall(r'(BoundSoul\w+)Address=0x([0-9A-F]+)',header)}
    code=bytes(int(v,16) for v in re.findall(r'0x([0-9A-F]{2})(?=[,}])',header.split('BoundSoulCode[]={')[1]))
    results={}
    for name,full,raid,static in [('wild-party',False,False,False),('wild-pc',True,False,False),('raid-party',False,True,False),('raid-pc',True,True,False),('static-party',False,False,True),('static-pc',True,False,True)]:
        try:results[name]=capture(rom,seed,code,symbols,full=full,raid=raid,static=static)
        except Exception as error:results[name]={'passed':False,'error':repr(error)}
        (a.output/(name+'.json')).write_text(json.dumps(results[name],indent=2)+'\n')
        print(name,results[name].get('passed'),results[name].get('error',''),flush=True)
    for name,operation in [('prize-shop',lambda:prize_shop(rom,seed,code,symbols)),('prize-shop-pc',lambda:prize_shop(rom,seed,code,symbols,full=True)),('prize-shop-no-capacity',lambda:prize_no_capacity(rom,seed,code,symbols)),('gift-egg',lambda:gifts(rom,seed,code,symbols))]:
        try:results[name]=operation()
        except Exception as error:results[name]={'passed':False,'error':repr(error)}
        (a.output/(name+'.json')).write_text(json.dumps(results[name],indent=2)+'\n')
        print(name,results[name].get('passed'),results[name].get('error',''),flush=True)
    report={'passed':all(v['passed'] for v in results.values()),'rom_sha256':hashlib.sha256(rom).hexdigest(),'seed_sha256':hashlib.sha256(seed).hexdigest(),
        'native_shim_sha256':hashlib.sha256(code).hexdigest(),'manifest_sha256':hashlib.sha256(a.manifest.read_bytes()).hexdigest() if a.manifest else None,
        'seed_provenance':'Exact-ROM-CRC mGBA native new-game state, preserved read-only. Each test constructs a synthetic battle or field-script interaction in copied RAM; CPU save-state compatibility is not inferred.',
        'results':results}
    (a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report['passed']:raise SystemExit(1)

if __name__=='__main__':main()

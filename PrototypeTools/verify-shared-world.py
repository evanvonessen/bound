#!/usr/bin/env python3
"""Execute shared gates against private RR4.1 bytes with Unicorn.

The real FlagGet, expanded storage, trainer dispatcher and checktrainerflag run.
The existing terrain-collision engine's return value is controlled separately;
this is ARM/ABI and predicate proof, not a paired full-game playthrough.
"""
import argparse,hashlib,json,re,struct
from pathlib import Path
from unicorn import Uc,UC_ARCH_ARM,UC_MODE_THUMB,UC_HOOK_CODE
from unicorn.arm_const import *
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rom',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1];rom=a.rom.read_bytes()
assert hashlib.sha256(rom).hexdigest()=='689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066'
h=(root/'Delta/Bound/SharedWorld/BoundSharedWorldCode.h').read_text();syms={n:int(v,16) for n,v in re.findall(r'(BoundWorld\w+)Address=0x([0-9A-F]+)',h)}
code=bytes(int(x,16) for x in re.findall(r'0x([0-9A-F]{2})\b',h.split('Code[]={')[1]))
u=Uc(UC_ARCH_ARM,UC_MODE_THUMB);u.mem_map(0x08000000,0x2000000);u.mem_write(0x08000000,rom)
u.mem_map(0x02000000,0x40000);u.mem_map(0x03000000,0x8000);u.mem_map(0x04000000,0x1000);u.mem_map(0x0A000000,0x1000)
def put(a,v,n=4):u.mem_write(a,v.to_bytes(n,'little'))
def read(a,n=4):return int.from_bytes(u.mem_read(a,n),'little')
u.mem_write(0x09FF6000,code)
u.mem_write(0x0806E6D0,b'\x00\x4b\x18\x47'+struct.pack('<I',syms['BoundWorldFlag']))
u.mem_write(0x080636AC,b'\x08\xb4\x01\x4b\x18\x47\xc0\x46'+struct.pack('<I',syms['BoundWorldCollisionEntry']))
put(0x03005008,0x02010000);put(0x02010004,3,1);put(0x02010005,43,1)
g=read(0x083526A8+3*4);header=read(g+43*4);u.mem_write(0x02036DFC,bytes(u.mem_read(header,28)))
obj=0x02036E38;put(obj,0x10001);put(obj+8,255,1);put(obj+11,3,1)
policy=0x09FF7000;put(policy,0x31575042);put(policy+4,1);put(policy+8,180);put(policy+12,1);put(policy+16,3,1);put(policy+17,43,1)
checks=[];native_collision=0;collision_directions=[]
def hook(uc,address,size,data):
 if address==0x080636B8:
  collision_directions.append(uc.reg_read(UC_ARM_REG_R3)&255);uc.reg_write(UC_ARM_REG_R0,native_collision);uc.reg_write(UC_ARM_REG_PC,0x08063763)
 if address==0x0A000000:uc.emu_stop()
u.hook_add(UC_HOOK_CODE,hook)
def call(addr,*args):
 regs=[UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3]
 for i,reg in enumerate(range(UC_ARM_REG_R4,UC_ARM_REG_R11+1)):u.reg_write(reg,0x12340000+i)
 before=[u.reg_read(r) for r in range(UC_ARM_REG_R4,UC_ARM_REG_R11+1)]
 u.reg_write(UC_ARM_REG_CPSR,0x20);u.reg_write(UC_ARM_REG_SP,0x03007E00);u.reg_write(UC_ARM_REG_LR,0x0A000001)
 for r,v in zip(regs,args):u.reg_write(r,v&0xffffffff)
 try:u.emu_start(addr|1,0x0A000002,count=200000)
 except Exception:
  print("Fault",hex(u.reg_read(UC_ARM_REG_PC)),[hex(u.reg_read(r)) for r in regs]);raise
 assert u.reg_read(UC_ARM_REG_PC)==0x0A000000,hex(u.reg_read(UC_ARM_REG_PC))
 assert u.reg_read(UC_ARM_REG_SP)==0x03007E00
 assert before==[u.reg_read(r) for r in range(UC_ARM_REG_R4,UC_ARM_REG_R11+1)],'callee-saved registers'
 return u.reg_read(UC_ARM_REG_R0)
def flag(id,local=None,peer=None):
 for value,address in [(local,0x02010000+0xEE0+id//8 if id<0x900 else 0x0203B174+(id-0x900)//8),(peer,policy+18+id//8)]:
  if value is not None:put(address,(read(address,1)&~(1<<(id%8)))|((bool(value))<<(id%8)),1)
def check(name,actual,expected):
 assert actual==expected,(name,actual,expected);checks.append(name)
def collision(x,y,d=2):return call(0x080636AC,obj,x+7,y+7,d)
flag(0x820,1,0);check('native badge blocked until both own it',call(0x0806E6D0,0x820),0)
flag(0x820,peer=1);check('both badges permit native field read',call(0x0806E6D0,0x820),1)
flag(0x820,local=0);check('peer badge never grants own badge',call(0x0806E6D0,0x820),0)
flag(0x820,1,0);put(0x03003529,2,1);check('personal battle badge remains personal',call(0x0806E6D0,0x820),1);put(0x03003529,0,1)
flag(0x56E,1,0);check('trainer ownership is never rewritten',call(0x0806E6D0,0x56E),1)
put(obj+16,18,2);put(obj+18,39,2);put(obj+20,18,2);put(obj+22,40,2)
check('first trainer win keeps bridge corridor blocked',collision(11,31),1)
put(obj+18,38,2);check('cannot leave completed trainer line toward next trainer',collision(11,30),1)
check('retreat remains possible',collision(11,32),0)
flag(0x56E,peer=1);check('both wins open first bridge gate',collision(11,31),0)
ctx=0x02008000;script=0x081A96B2
for trainer in [0x6E,0x7B,0x5C,0x7A,0x90]:flag(0x500+trainer,0,0)
for i,trainer in enumerate([0x6E,0x7B,0x5C,0x7A,0x90]):
 # actual command argument bytes for each of the five native trainer scripts
 script=[0x081A9636,0x081A96B2,0x081A95F8,0x081A9674,0x081A972E][i]
 if i:
  flag(0x500+[0x6E,0x7B,0x5C,0x7A,0x90][i-1],1,0)
  put(ctx+8,script);check(f'bridge trainer {i+1} waits for peer prerequisite',call(syms['BoundWorldTrainer'],ctx),0)
  check(f'bridge trainer {i+1} uses native waiting script',read(ctx+8),0x03004200)
  flag(0x500+[0x6E,0x7B,0x5C,0x7A,0x90][i-1],peer=1)
 put(ctx+8,script);check(f'bridge trainer {i+1} native handler returns normally',call(syms['BoundWorldTrainer'],ctx),0)
 assert read(ctx+8)!=0x03004200;checks.append(f'bridge trainer {i+1} enters original native handler')
flag(0x56E,1,0);put(ctx+8,0x081A95F8);call(syms['BoundWorldTrainer'],ctx)
check('trainer three checks every earlier prerequisite, not only trainer two',read(ctx+8),0x03004200)
flag(0x56E,0,1);put(ctx+8,0x081A96B2);call(syms['BoundWorldTrainer'],ctx)
check('partner win never substitutes for my missing earlier win',read(ctx+8),0x03004200)
# Native script checktrainerflag comparison consumes exactly one u16 operand.
flag(0x56E,1,0);put(ctx+8,0x081A9637)
check('native prerequisite comparison stays pending',call(syms['BoundWorldCheckTrainer'],ctx),0);check('peer missing trainer clears native comparison',read(ctx+2,1),0)
flag(0x56E,peer=1);put(ctx+8,0x081A9637);call(syms['BoundWorldCheckTrainer'],ctx);check('native prerequisite comparison opens after both wins',read(ctx+2,1),1)
# Real map object hide flag (Nugget Bridge Rocket), unchanged local ownership.
flag(0x31,1,0);check('removed story NPC remains a shared obstacle',collision(12,15),1)
flag(0x31,peer=1);check('both story NPC clears open tile',collision(12,15),0)
# Controlled native map event template for temporary Cut/Rock Smash flags.
events=0x09FF6E00;template=events+32;put(events,1,1);put(events+4,template);put(template+4,8,2);put(template+6,9,2);put(template+8,3,1);put(template+20,0x11,2);put(0x02036E00,events)
flag(0x11,1,0);check('one cut cannot clear partner tree',collision(8,9),1)
flag(0x11,peer=1);check('both cuts open the tree tile',collision(8,9),0)
put(policy+17,42,1);check('temporary flags from a different map never unlock tree',collision(8,9),1);put(policy+17,43,1)
put(template+1,97,1);put(template+20,0,2);put(policy+17,42,1)
check('boulder home stays blocked before partner reaches map',collision(8,9),1)
put(policy+17,43,1)
put(policy+818,1,1);u.mem_write(policy+820,struct.pack('<BBhh',9,3,5,6))
check('moved boulder retains partner collision',collision(5,6),1)
put(obj+36,1);put(obj+36+8,9,1);put(obj+36+16,12,2);put(obj+36+18,13,2)
native_collision=4;check('first native Strength push is preserved',collision(5,6),4);native_collision=0
put(policy+8,0);check('expired peer lease blocks forward movement',collision(9,10),1)
put(ctx+8,0x081A9636);call(syms['BoundWorldTrainer'],ctx);check('expired peer lease blocks battle launch',read(ctx+8),0x03004200)
put(policy+4,0);check('disabled feature restores ordinary collision',collision(9,10),0)
check('fourth collision ABI argument survives thunk',collision_directions[-1],2)
# Neither side's actual progress bits may be altered by any gate.
check('original trainer flag remains earned',read(0x02010000+0xEE0+0x56E//8,1)&(1<<(0x56E%8)),1<<(0x56E%8))
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps({'passed':True,'checks':checks,'count':len(checks),'limits':'Actual ARM predicates/ABI and native trainer dispatch; terrain engine result controlled. Not a paired gameplay playthrough.'},indent=2)+'\n')
print(f'{len(checks)} native shared-world checks passed')

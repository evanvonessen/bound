#!/usr/bin/env python3
"""Exercise exact RR action dispatch for automatic moves and party responses.

The controlled fixture supplies the move-availability classification and marks
selection text complete. The real cartridge dispatcher, no-more-moving helper,
response emitters, and Bound adapter execute as ARM instructions. This verifies
branch/ABI behavior, not complete battles or every move restriction.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct
from unicorn import Uc,UC_ARCH_ARM,UC_MODE_THUMB,UC_HOOK_CODE
from unicorn.arm_const import UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3,UC_ARM_REG_SP,UC_ARM_REG_LR,UC_ARM_REG_PC

ROOT=Path(__file__).resolve().parents[1]
ROM,CODE,STATE=0x08000000,0x09FE8000,0x03004620
STOP,STACK,DATA=0x08000100,0x03007F00,0x02008000
ACTIVE,EXEC,COMM=0x02023BC4,0x02023BC8,0x02023E82
BUFFER_A,BUFFER_B=0x02022BC4,0x020233C4

def verify(path,allowed,symbols,code):
    image=path.read_bytes();digest=hashlib.sha256(image).hexdigest()
    assert digest in allowed and len(image)==0x2000000,'Unsupported ROM profile'
    results=[]
    for role in (0,1):
        for kind in ('struggle','encore','normal','no-more-moving'):
            cpu=Uc(UC_ARCH_ARM,UC_MODE_THUMB)
            for address,size in ((ROM,len(image)),(0x02000000,0x40000),(0x03000000,0x8000)):
                cpu.mem_map(address,size)
            cpu.mem_write(ROM,image);cpu.mem_write(CODE,code)
            for address,name in ((0x0800D8B0,'BoundDecisionTransfer'),(0x0800D9EC,'BoundDecisionLinkTransfer'),(0x08017248,'BoundDecisionMark')):
                cpu.mem_write(address,bytes.fromhex('004b1847')+struct.pack('<I',symbols[name]))
            def word(address,value=None,size=4):
                if value is None:return int.from_bytes(cpu.mem_read(address,size),'little')
                cpu.mem_write(address,value.to_bytes(size,'little'))
            def call(address,*args):
                for register,value in zip((UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3),args):cpu.reg_write(register,value)
                cpu.reg_write(UC_ARM_REG_SP,STACK);cpu.reg_write(UC_ARM_REG_LR,STOP|1)
                cpu.emu_start(address|1,STOP,count=100000)
                assert cpu.reg_read(UC_ARM_REG_PC)==STOP,hex(cpu.reg_read(UC_ARM_REG_PC))
                assert cpu.reg_read(UC_ARM_REG_SP)==STACK,'Dispatcher stack changed'
            def transfer(buffer,payload):
                word(ACTIVE,role,1);cpu.mem_write(DATA,bytes(payload));call(0x0800D8B0,buffer,DATA,len(payload))
            moves=[];automatic=[]
            def observe(machine,address,size,user):
                if address==STOP:machine.emu_stop()
                elif address==0x08017998:
                    # Deliberately controlled availability classification. The
                    # branch, state updates and later standby are real native.
                    machine.reg_write(UC_ARM_REG_R0,1 if kind=='struggle' else 0)
                    machine.reg_write(UC_ARM_REG_PC,machine.reg_read(UC_ARM_REG_LR))
                elif address==0x0800E520:
                    moves.append(word(ACTIVE,size=1))
                    machine.reg_write(UC_ARM_REG_PC,machine.reg_read(UC_ARM_REG_LR))
                elif address==0x090AA73C:automatic.append(word(ACTIVE,size=1))
            cpu.hook_add(UC_HOOK_CODE,observe)
            word(0x09FFFCF0,role,1);word(0x02023BCC,2,1)
            word(0x02022B4C,2|8|(4 if role==0 else 0));word(STATE,0x31444242)
            word(STATE+12,1);word(STATE+32,1)
            for bank in (0,1):
                word(0x02023BD6+bank,bank^role,1)
                word(COMM+bank,4,1)
                cpu.mem_write(0x02023BE4+bank*88+12,struct.pack('<4H',1,2,3,4))
                word(0x02023BE4+bank*88+40,20,2)
                word(STATE+40+12*bank+9,255,1)
            word(0x02023FE8,0x02010000);word(0x0203E038,0x02012000)
            if kind=='encore':word(0x02023E0C+28*role+6,1,2)
            if kind=='no-more-moving':word(0x02012000+0xC1,1<<role,1)
            word(0x03004FF4,role^1,1)
            transfer(0,[18,0,0,0]);transfer(1,[33,0,0,0])
            assert word(STATE+18,size=2)==0
            word(COMM+role,1,1)
            call(0x08014040)
            first=word(COMM+role,size=1)
            assert not word(STATE+8),('Adapter error',kind,role,word(STATE+8))
            if kind=='struggle':
                assert first==5 and word(0x02010000+0x84+role,size=1)==3
                # Skip only presentation: signal the real selection-script
                # completion byte and let native dispatch reach standby.
                word(0x02010000+0x54+role,1,1)
                call(0x08014040)
                assert word(COMM+role,size=1)==3,('after selection script',role,word(COMM+role,size=1))
                call(0x08014040)
            elif kind=='no-more-moving':
                assert automatic==[role] and first==2
                # The derived response was emitted directly while handling
                # Fight, not through a menu or a network decision.
                assert bytes(cpu.mem_read(BUFFER_B+role*512,8))==bytes([33,10,0,role^1,0,0,0,0])
                assert word(STATE+18,size=2)==0
                # The same native dispatcher consumes the derived response
                # and reaches its final standby state without another input.
                transfer(2,[role,0,0,0])
                call(0x08014040)
                assert word(COMM+role,size=1)==3,('after automatic response',role,word(COMM+role,size=1),hex(word(EXEC)))
                call(0x08014040)
            else:
                # RR replaces the vanilla direct Encore shortcut. The real
                # cartridge requests its expanded move menu in both cases.
                assert moves==[role] and first==2
                assert word(STATE+18,size=2)==0
            outgoing=word(STATE+18,size=2)
            if kind in ('struggle','no-more-moving'):
                assert outgoing==1 and bytes(cpu.mem_read(STATE+64+9,3))==bytes([18,255,4])
                assert bytes(cpu.mem_read(STATE+64+12,4))==bytes([33,0,0,0])
            assert not word(STATE+8)
            results.append(dict(role=role,case=kind,nativeStateAfterFight=first,moveMenus=len(moves),automaticResponses=len(automatic),decisionRecords=outgoing))
    party_results=[]
    # Execute the real five-byte party response emitter and switchhandleorder
    # command (normal switching uses mode1; forced switching uses mode2). The
    # packed order response belongs to MULTI battles; friendly singles derive
    # their order from the canonical battler index and chosen party slot.
    table=struct.unpack_from('<I',image,0x14C1C)[0]
    switch_command=struct.unpack_from('<I',image,table-ROM+0x51*4)[0]
    assert switch_command==0x090BF4B9,'Unexpected RR switch command'
    for role in (0,1):
        for bank in (0,1):
            for mode in (0,1,2):
                orders=[]
                for response_order in (bytes([0x10,0x23,0x45]),bytes([0xFF,0xFF,0xFF])):
                    cpu=Uc(UC_ARCH_ARM,UC_MODE_THUMB)
                    for address,size in ((ROM,len(image)),(0x02000000,0x40000),(0x03000000,0x8000)):
                        cpu.mem_map(address,size)
                    cpu.mem_write(ROM,image);cpu.mem_write(CODE,code)
                    cpu.mem_write(0x0800D8B0,bytes.fromhex('004b1847')+struct.pack('<I',symbols['BoundDecisionTransfer']))
                    def word(address,value=None,size=4):
                        if value is None:return int.from_bytes(cpu.mem_read(address,size),'little')
                        cpu.mem_write(address,value.to_bytes(size,'little'))
                    def call(address,*args):
                        for register,value in zip((UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3),args):cpu.reg_write(register,value)
                        cpu.reg_write(UC_ARM_REG_SP,STACK);cpu.reg_write(UC_ARM_REG_LR,STOP|1)
                        cpu.emu_start(address|1,STOP,count=100000)
                        assert cpu.reg_read(UC_ARM_REG_PC)==STOP,hex(cpu.reg_read(UC_ARM_REG_PC))
                        assert cpu.reg_read(UC_ARM_REG_SP)==STACK,'Switch command stack changed'
                    word(0x09FFFCF0,role,1);word(0x02023BCC,2,1)
                    word(0x02022B4C,2|8|(4 if role==0 else 0));word(STATE,0x31444242)
                    word(0x02023FE8,0x02010000)
                    word(0x02023D74,0x02009000);cpu.mem_write(0x02009000,bytes([0x51,1,mode]))
                    word(0x02023D6B,bank,1);word(ACTIVE,bank,1)
                    cpu.mem_write(0x02010000+0x60,bytes([0x01,0x23,0x45])*4)
                    word(0x02010000+0x5C+bank,1,1)
                    word(STATE+40+12*bank+8,22,1);word(STATE+40+12*bank+9,255,1)
                    cpu.mem_write(DATA,response_order)
                    call(0x0800E874,1,1,DATA)
                    payload=bytes(cpu.mem_read(BUFFER_B+512*bank,5))
                    assert payload==bytes([34,1])+response_order,'Native party response was truncated'
                    if bank==role:
                        assert word(STATE+18,size=2)==1
                        assert bytes(cpu.mem_read(STATE+64+12,5))==payload
                    call(switch_command)
                    assert word(0x02023D74)==0x02009003
                    assert word(0x02010000+0x5C+bank,size=1)==1
                    order=bytes(cpu.mem_read(0x02010000+0x60+3*bank,3))
                    assert order==bytes([0x01 if mode==0 else 0x10,0x23,0x45]),(role,bank,mode,order.hex())
                    assert bytes(cpu.mem_read(0x02010000+0x60+3*(bank^1),3))==bytes([0x01,0x23,0x45])
                    assert not word(STATE+8)
                    orders.append(order.hex())
                assert orders[0]==orders[1],'Singles consumed the MULTI-only packed order response'
                party_results.append(dict(role=role,battler=bank,mode=mode,canonicalOrder=orders[0],responseBytes=5))
    return dict(sha256=digest,checks=results,partyOrderChecks=party_results,passed=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rom',type=Path,action='append',required=True);parser.add_argument('--output',type=Path)
    args=parser.parse_args();header=(ROOT/'Delta/Bound/NativeBattle/BoundBattleDecisionCode.h').read_text()
    symbols={name:int(value,16) for name,value in re.findall(r'(BoundDecision\w+)Address = 0x([0-9A-Fa-f]+)',header)}
    code=bytes(int(value,16) for value in re.findall(r'0x([0-9A-Fa-f]{2})\b',header.split('BoundBattleDecisionCode[] = {')[1]))
    allowed={'689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066',json.loads((ROOT/'PrototypeTools/bundled-rom.json').read_text())['sha256']}
    report=dict(profiles=[verify(path,allowed,symbols,code) for path in args.rom],passed=True)
    if args.output:args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()

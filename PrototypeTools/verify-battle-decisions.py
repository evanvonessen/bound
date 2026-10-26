#!/usr/bin/env python3
"""Execute the decision adapter and exact RR emitters with guarded Unicorn.

Run with PrototypeTools/qa-python. These are native instruction/ABI checks,
not a substitute for two-core gameplay, real devices, or internet validation.
ROM bytes stay local and are never embedded in reports.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_CODE
from unicorn.arm_const import (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2,
    UC_ARM_REG_R3, UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_SP,
    UC_ARM_REG_LR, UC_ARM_REG_PC)

ROOT = Path(__file__).resolve().parents[1]
ROM, CODE, STATE = 0x08000000, 0x09FE8000, 0x03004620
STOP, MAIN, CONTROLLER, DATA = 0x08000100, 0x08000120, 0x08000140, 0x02008000
ACTIVE, COUNT, FLAGS, EXEC, RNG = 0x02023BC4, 0x02023BCC, 0x02022B4C, 0x02023BC8, 0x03005000
BUFFER_A, BUFFER_B = 0x02022BC4, 0x020233C4
STACK, ROLE = 0x03007F00, 0x09FFFCF0


def verify(path, allowed, symbols, code):
    image = path.read_bytes()
    digest = hashlib.sha256(image).hexdigest()
    assert digest in allowed and len(image) == 0x2000000, 'Unsupported ROM profile'
    assert image[CODE-ROM:0x1FF0000] == bytes([255]) * (0x09FF0000-CODE), 'Decision code allocation occupied'

    class Core:
        def __init__(self, role=0):
            self.role = role
            self.cpu = cpu = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
            for address, size in [(ROM,len(image)),(0x02000000,0x40000),(0x03000000,0x8000)]:
                cpu.mem_map(address,size)
            cpu.mem_write(ROM,image); cpu.mem_write(CODE,code)
            for address,name in [(0x0800D8B0,'BoundDecisionTransfer'),(0x0800D9EC,'BoundDecisionLinkTransfer'),
                    (0x08017248,'BoundDecisionMark'),(0x080123E4,'BoundDecisionFrame')]:
                cpu.mem_write(address,bytes.fromhex('004b1847')+struct.pack('<I',symbols[name]))
            cpu.mem_write(ROLE,bytes([role])); cpu.mem_write(COUNT,b'\x02')
            self.word(FLAGS,2 | (4 if role==0 else 0)); self.word(STATE,0x31444242)
            self.word(STATE+4,0x12345678)
            for bank in (0,1):
                cpu.mem_write(0x02023BE4+bank*88+12,struct.pack('<4H',1,2,3,4))
                self.word(0x02023BE4+bank*88+40,20,2)
            self.word(0x0202402A,2,1)
            self.word(0x0202402C+100+86,20,2)
            self.word(0x03004F84,MAIN|1)
            self.word(0x03004FE0,CONTROLLER|1);self.word(0x03004FE4,CONTROLLER|1)
            self.main_seeds=[];self.controllers=0;self.native_sends=[];self.mutate_seed=False
            self.vblank_mutates=False;self.stop_at_music=False
            self.terrain_var=None;self.terrain_scripts=[]
            self.cpu.hook_add(UC_HOOK_CODE,self.observe)

        def word(self,address,value=None,size=4):
            if value is None:return int.from_bytes(self.cpu.mem_read(address,size),'little')
            self.cpu.mem_write(address,value.to_bytes(size,'little'))

        def observe(self,cpu,address,size,user):
            if address==STOP:cpu.emu_stop()
            elif address==MAIN:
                self.main_seeds.append(self.word(RNG))
                if self.mutate_seed:self.word(RNG,(1103515245*self.word(RNG)+24691)&0xffffffff)
                cpu.reg_write(UC_ARM_REG_PC,cpu.reg_read(UC_ARM_REG_LR))
            elif address==CONTROLLER:
                self.controllers+=1
                cpu.reg_write(UC_ARM_REG_PC,cpu.reg_read(UC_ARM_REG_LR))
            elif address==0x0800072C and self.vblank_mutates:
                # The wrapper has replayed native VBlank's exact prologue.
                # Model the asynchronous body's RNG use, then its real ABI
                # epilogue; no presentation code is needed for this test.
                self.word(RNG,0xDEADBEEF)
                sp=cpu.reg_read(UC_ARM_REG_SP)
                r4,r5,pc=struct.unpack('<III',cpu.mem_read(sp,12))
                cpu.reg_write(UC_ARM_REG_R4,r4);cpu.reg_write(UC_ARM_REG_R5,r5)
                cpu.reg_write(UC_ARM_REG_SP,sp+12);cpu.reg_write(UC_ARM_REG_PC,pc)
            elif address==0x0800A448:
                self.native_sends.append([cpu.reg_read(r) for r in (UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2)])
                raise AssertionError('Presentation emitted a native link block')
            elif address==0x08071AB4 and self.stop_at_music:cpu.emu_stop()
            elif address==0x0806E568 and self.terrain_var is not None:
                assert cpu.reg_read(UC_ARM_REG_R0)==0x5000,'Unexpected native terrain variable'
                cpu.reg_write(UC_ARM_REG_R0,self.terrain_var)
                cpu.reg_write(UC_ARM_REG_PC,cpu.reg_read(UC_ARM_REG_LR))
            elif address==0x0801BC24 and self.terrain_var is not None:
                self.terrain_scripts.append(cpu.reg_read(UC_ARM_REG_R0))
                cpu.reg_write(UC_ARM_REG_PC,cpu.reg_read(UC_ARM_REG_LR))

        def call(self,address,*args):
            for register,value in zip((UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3),args):
                self.cpu.reg_write(register,value)
            self.cpu.reg_write(UC_ARM_REG_SP,STACK);self.cpu.reg_write(UC_ARM_REG_LR,STOP|1)
            self.cpu.emu_start(address|1,STOP,count=100000)
            assert self.cpu.reg_read(UC_ARM_REG_PC)==STOP,'Guest did not return'
            assert self.cpu.reg_read(UC_ARM_REG_SP)==STACK,'Guest stack changed'

        def frame(self):self.call(0x080123E4)

        def transfer(self,bank,buffer,payload):
            self.word(ACTIVE,bank,1);self.cpu.mem_write(DATA,bytes(payload))
            self.call(0x0800D8B0,buffer,DATA,len(payload))

        def response(self,bank,action,packed=0):
            self.word(ACTIVE,bank,1)
            self.call(0x0800E848,1,action,packed) # Exact cartridge TwoReturnValues emitter.

        def mark(self,bank):self.call(0x08017248,bank)

        def complete(self,bank):
            self.word(ACTIVE,bank,1);self.cpu.mem_write(DATA,bytes([self.role,0,0,0]))
            self.call(0x0800D9EC,2,4,DATA)

        def outgoing(self):
            return [bytes(self.cpu.mem_read(STATE+64+(i&7)*32,32))
                for i in range(self.word(STATE+16,size=2),self.word(STATE+18,size=2))]

        def receive(self,record):
            write=self.word(STATE+22,size=2)
            self.cpu.mem_write(STATE+320+(write&7)*32,record)
            self.word(STATE+22,(write+1)&0xffff,2)

        def error(self):return self.word(STATE+8)

    checks=[]
    # Original cartridge environment functions expose local map/save state to
    # linked battle mechanics. Keep exact-entrypoint evidence here so the
    # friendly-only neutral hooks cannot drift to unrelated field routines.
    assert image[0x7AF98:0x7AFA0]==bytes.fromhex('0248da21c9004018')
    assert image[0x106E52C:0x106E534]==bytes.fromhex('a02070b5234bc001')
    for role in (0,1):
        original=[]
        for terrain in (0,1,2,3,4):
            c=Core(role);c.terrain_var=terrain;c.word(0x0203E038,0x02010000)
            c.call(0x0906E52C)
            assert c.word(0x0203E028,size=1)==terrain
            assert c.cpu.reg_read(UC_ARM_REG_R0)==bool(terrain)
            assert len(c.terrain_scripts)==bool(terrain)
            original.append(c.word(0x0203E028,size=1))
        for weather in (0,3,7,12):
            c=Core(role);c.word(0x02038604,weather,1);c.call(0x0807AF98)
            assert c.cpu.reg_read(UC_ARM_REG_R0)==weather
        checks.append(dict(role=role,originalLinkedTerrainReadsLocalVariable=original,
                           originalWeatherReadsLocalMap=True))
        for inactive in (None,'ordinary','no-magic'):
            for terrain in (0,1,4):
                c=Core(role);c.terrain_var=terrain;c.word(0x0203E038,0x02010000)
                c.word(0x02038604,7,1)
                if inactive=='ordinary':c.word(FLAGS,0)
                elif inactive=='no-magic':c.word(STATE,0)
                for address,name in [(0x0807AF98,'BoundDecisionOverworldWeather'),
                                     (0x0906E52C,'BoundDecisionOverworldTerrain')]:
                    c.cpu.mem_write(address,bytes.fromhex('004b1847')+struct.pack('<I',symbols[name]))
                c.call(0x0807AF98)
                assert c.cpu.reg_read(UC_ARM_REG_R0)==(7 if inactive else 0)
                assert c.word(0x02038604,size=1)==7,'Friendly hook changed field weather'
                c.call(0x0906E52C)
                assert c.word(0x0203E028,size=1)==(terrain if inactive else 0)
                assert len(c.terrain_scripts)==(bool(terrain) if inactive else 0)
                assert c.cpu.reg_read(UC_ARM_REG_R0)==(bool(terrain) if inactive else 0)
                # Removing the friendly hooks exposes the unchanged local
                # environment again. Actual battle-generated terrain is not
                # reset by the overworld activation helper.
                if not inactive:
                    c.word(0x0203E028,4,1);c.call(0x0906E52C)
                    assert c.word(0x0203E028,size=1)==4
                    for address in (0x0807AF98,0x0906E52C):
                        c.cpu.mem_write(address,image[address-ROM:address-ROM+8])
                        c.cpu.ctl_remove_cache(address,address+8)
                    c.call(0x0807AF98);assert c.cpu.reg_read(UC_ARM_REG_R0)==7
        checks.append(dict(role=role,friendlyEnvironmentNeutral=True,
                           normalBattleEnvironmentPreserved=True,fieldWeatherUnchanged=True,
                           battleGeneratedTerrainUnchanged=True))
    presentation_commands=(0,2,4,5,6,7,10,15,16,17,24,26,27,41,43,44,52,53,54)
    for role in (0,1):
        c=Core(role);c.frame()
        for bank in (0,1):
            for command in presentation_commands:
                payload=bytes([command,1,2,3])
                c.transfer(bank,0,payload);c.mark(bank)
                assert bytes(c.cpu.mem_read(BUFFER_A+512*bank,4))==payload
                assert c.word(EXEC)&(1<<bank)
                c.complete(bank)
                assert not c.word(EXEC)&(1<<bank),'Local presentation waited for peer ACK'
        assert not c.outgoing() and not c.error() and not c.native_sends
        checks.append(dict(role=role,presentationCommandsLocal=len(presentation_commands)*2))

    # Opening Fight, moving back, and reopening is local. Only the final move
    # response is sent, tagged with its canonical battler and parent action.
    for role in (0,1):
        c=Core(role);c.frame()
        c.transfer(role,0,[18,0,0,0]);c.mark(role);c.response(role,0);c.complete(role)
        assert not c.outgoing()
        c.transfer(role,0,[20,0,0,0]);c.mark(role);c.response(role,10,0xffff);c.complete(role)
        assert not c.outgoing(),'Back produced a peer decision'
        c.transfer(role,0,[18,0,0,0]);c.response(role,0)
        c.transfer(role,0,[20,0,0,0]);c.response(role,10,1)
        records=c.outgoing();assert len(records)==1
        record=records[0]
        assert struct.unpack_from('<I',record)[0]==1 and record[8:12]==bytes([role,20,0,4])
        assert record[12:16]==bytes([33,10,1,0]) and not c.error()
        remote=Core(role^1);remote.frame()
        remote.transfer(role,0,[18,9,8,7]);remote.mark(role);remote.complete(role)
        assert remote.word(EXEC)&(1<<role),'Remote input must wait for the player'
        remote.frame();assert remote.word(EXEC)&(1<<role)
        remote.receive(record);remote.frame()
        assert not remote.word(EXEC)&(1<<role) and remote.word(STATE+20,size=2)==0
        assert bytes(remote.cpu.mem_read(BUFFER_B+512*role,4))==bytes([33,0,0,0])
        remote.transfer(role,0,[20,0,0,0]);remote.mark(role);remote.frame()
        assert remote.word(STATE+20,size=2)==1 and remote.word(STATE+28)==1
        assert bytes(remote.cpu.mem_read(BUFFER_B+512*role,4))==record[12:16]
        assert not remote.error()
        # A late retry is consumed without applying its old decision again.
        remote.transfer(role,0,[18,0,0,0]);remote.mark(role);remote.receive(record);remote.frame()
        assert remote.word(EXEC)&(1<<role) and not remote.error()
        checks.append(dict(role=role,moveBackLocal=True,confirmedMoveRecords=1,remoteReplayAndDuplicateSafe=True))

    # Native forced-action routes skip ChooseMove and commit at LinkStandby.
    # The adapter must send that final Fight, not wait forever for a move menu.
    for label in ('Struggle','Automatic Fight'):
        c=Core();c.frame();c.transfer(0,0,[18,0,0,0]);c.response(0,0)
        assert not c.outgoing();c.transfer(0,0,[53,0,0,0])
        record=c.outgoing()[0]
        assert record[9]==18 and record[12:16]==bytes([33,0,0,0])
        assert len(c.outgoing())==1 and not c.error()
        checks.append(dict(automaticAction=label,committedAtStandby=True))

    c=Core();c.frame();c.transfer(0,0,[18,0,0,0]);c.response(0,2)
    c.transfer(0,0,[22,0,0,0]);c.transfer(0,1,[34,6,0,0,0])
    assert not c.outgoing(),'Canceled party selection must remain local'
    c.transfer(0,0,[18,0,0,0]);c.response(0,2)
    c.transfer(0,0,[22,0,0,0]);c.transfer(0,1,[34,1,0,0,0])
    assert len(c.outgoing())==1 and c.outgoing()[0][9:12]==bytes([22,2,5])
    checks.append(dict(switchCancelLocal=True,confirmedSwitchRecords=1))

    # The host drains bounded rings; neither a stalled host nor a corrupt
    # producer may overwrite decisions the cartridge has not consumed.
    c=Core();c.frame()
    for _ in range(8):
        c.transfer(0,0,[18,0,0,0]);c.response(0,3)
    queued=bytes(c.cpu.mem_read(STATE+64,256))
    c.transfer(0,0,[18,0,0,0]);c.response(0,3)
    assert c.error()==2 and c.word(STATE+18,size=2)==8
    assert bytes(c.cpu.mem_read(STATE+64,256))==queued
    c=Core();c.frame();c.word(STATE+24,0xffffffff)
    c.transfer(0,0,[18,0,0,0]);c.response(0,3)
    assert c.error()==2 and c.word(STATE+18,size=2)==0
    c=Core(1);c.frame();c.transfer(0,0,[18,0,0,0]);c.mark(0)
    c.word(STATE+22,9,2);c.frame()
    assert c.error()==3 and c.word(STATE+20,size=2)==0 and c.word(EXEC)&1
    checks.append(dict(outgoingOverflowPreservesRecords=True,ordinalExhaustionRejected=True,incomingOverflowRejected=True))

    # Ring indices deliberately wrap independently of the monotonic decision
    # ordinal. A long session must still consume each action exactly once.
    sender=Core();sender.frame()
    sender.word(STATE+16,0xffff,2);sender.word(STATE+18,0xffff,2)
    sender.transfer(0,0,[18,0,0,0]);sender.response(0,3)
    record=bytes(sender.cpu.mem_read(STATE+64+7*32,32))
    assert sender.word(STATE+18,size=2)==0 and not sender.error()
    remote=Core(1);remote.frame()
    remote.word(STATE+20,0xffff,2);remote.word(STATE+22,0xffff,2)
    remote.transfer(0,0,[18,0,0,0]);remote.mark(0);remote.receive(record);remote.frame()
    assert remote.word(STATE+20,size=2)==0 and remote.word(STATE+28)==1
    assert not remote.word(EXEC)&1 and not remote.error()
    checks.append(dict(ringIndicesWrapSafely=True))

    # Fingerprints ignore native uninitialized/name padding, but include
    # gameplay data such as HP, PP bonuses, PP, and status.
    baseline=Core();baseline.frame();baseline.transfer(0,0,[18,0,0,0]);baseline.response(0,3)
    fingerprint=baseline.outgoing()[0][4:8]
    for offset in (0x23,0x30,0x3a,0x3c,0x43):
        c=Core();c.frame();c.word(0x02023BE4+offset,0xa5,1)
        c.transfer(0,0,[18,0,0,0]);c.response(0,3)
        assert c.outgoing()[0][4:8]==fingerprint,('Unstable fingerprint byte',offset)
    for offset in (0x24,0x28,0x3b,0x44):
        c=Core();c.frame();c.word(0x02023BE4+offset,0xa5,1)
        c.transfer(0,0,[18,0,0,0]);c.response(0,3)
        assert c.outgoing()[0][4:8]!=fingerprint,('Gameplay omitted from fingerprint',offset)
    checks.append(dict(fingerprintIgnoresNativePadding=True,fingerprintDetectsGameplayChanges=True))

    for corruption,error in [('ordinal',4),('battler',4),('size',4),('reserved',4),('fingerprint',5),('request',6)]:
        sender=Core();sender.frame();sender.transfer(0,0,[18,0,0,0]);sender.response(0,3)
        record=bytearray(sender.outgoing()[0]);remote=Core(1);remote.frame()
        remote.transfer(0,0,[18,0,0,0]);remote.mark(0)
        if corruption=='ordinal':struct.pack_into('<I',record,0,2)
        elif corruption=='battler':record[8]=1
        elif corruption=='size':record[11]=17
        elif corruption=='reserved':record[28]=1
        elif corruption=='fingerprint':record[4]^=1
        else:record[9]=22;record[11]=5;record[12:17]=bytes([34,1,0,0,0])
        remote.receive(bytes(record));remote.frame()
        assert remote.error()==error,(corruption,remote.error())
        assert remote.word(EXEC)&1 and remote.word(STATE+20,size=2)==0
        checks.append(dict(rejected=corruption,error=error))

    for corruption in ('move-slot','move-empty','target','opcode','transformation','switch-current','switch-fainted','switch-empty'):
        sender=Core();sender.frame();sender.transfer(0,0,[18,0,0,0]);sender.response(0,0)
        sender.transfer(0,0,[20,0,0,0]);sender.response(0,10,1)
        record=bytearray(sender.outgoing()[0]);remote=Core(1);remote.frame()
        remote.transfer(0,0,[18,0,0,0]);remote.mark(0)
        if corruption=='move-slot':record[14]=4
        elif corruption=='move-empty':remote.word(0x02023BE4+14,0,2)
        elif corruption=='target':record[15]=2
        elif corruption=='opcode':record[12]=0xff
        elif corruption=='transformation':record[11]=8;record[16]=2
        else:
            record[9]=22;record[10]=2;record[11]=5;record[12:17]=bytes([34,1,0,0,0])
            if corruption=='switch-current':remote.word(0x02023BCE,1,2)
            elif corruption=='switch-fainted':remote.word(0x0202402C+100+86,0,2)
            else:remote.word(0x0202402A,1,1)
        remote.receive(bytes(record));remote.frame()
        assert remote.error()==4,(corruption,remote.error())
        assert remote.word(EXEC)&1 and remote.word(STATE+20,size=2)==0
        checks.append(dict(rejected=corruption,error=4))

    for role in (0,1):
        c=Core(role);c.word(RNG,0xABC00000+role);c.mutate_seed=True
        c.frame();c.frame()
        first=(1103515245*0x12345678+24691)&0xffffffff
        assert c.main_seeds==[0x12345678,first]
        assert c.word(RNG)==0xABC00000+role and c.word(STATE+32)==0
        assert c.controllers==4 and not c.error()
        for simulation in (0,1):
            c.word(STATE+32,simulation);c.word(RNG,123);c.vblank_mutates=True
            c.call(symbols['BoundDecisionVBlank'])
            assert c.word(RNG)==(123 if simulation else 0xDEADBEEF)
        checks.append(dict(role=role,simulationRNGIsolated=True,vblankRNGPreserved=True))

    # Native terminal commands on the guest use the opponent controller, whose
    # handler flips master-relative outcomes. Normalize before that handler.
    for role in (0,1):
        for outcome in (1,2,3,0x81,0x82,0x83):
            c=Core(role);c.frame();c.transfer(0,0,[55,outcome])
            payload=c.word(BUFFER_A+1,size=1)
            assert payload==(outcome if role==0 or outcome==3 else outcome^3),(role,outcome,payload)
            c.word(ACTIVE,0,1);c.stop_at_music=True
            c.cpu.reg_write(UC_ARM_REG_SP,STACK);c.cpu.reg_write(UC_ARM_REG_LR,STOP|1)
            c.cpu.emu_start(0x08033A79 if role==0 else 0x0803D915,0x08071AB4,count=1000)
            assert c.cpu.reg_read(UC_ARM_REG_PC)==0x08071AB4
            assert c.word(0x02023E8A,size=1)==outcome,'Native terminal handler reversed a local result'
            checks.append(dict(role=role,outcome=outcome,terminalPayload=payload,nativeOutcomePreserved=True))
    return dict(sha256=digest,checks=checks,passed=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rom',type=Path,action='append',required=True)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    header=(ROOT/'Delta/Bound/NativeBattle/BoundBattleDecisionCode.h').read_text()
    symbols={name:int(value,16) for name,value in re.findall(r'(BoundDecision\w+)Address = 0x([0-9A-Fa-f]+)',header)}
    code=bytes(int(value,16) for value in re.findall(r'0x([0-9A-Fa-f]{2})\b',header.split('BoundBattleDecisionCode[] = {')[1]))
    allowed={'689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066',json.loads((ROOT/'PrototypeTools/bundled-rom.json').read_text())['sha256']}
    report=dict(profiles=[verify(path,allowed,symbols,code) for path in args.rom],passed=True)
    if args.output:args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()

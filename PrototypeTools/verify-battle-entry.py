#!/usr/bin/env python3
"""Prove native terminal-command routing using private, exact-profile ROMs.

Run with PrototypeTools/qa-python. ROM bytes are read locally, never embedded in
this verifier or written to its report. This is a focused instruction-level
regression; actual paired gameplay is covered by native-link-battle.py.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_CODE
from unicorn.arm_const import (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2,
    UC_ARM_REG_R3, UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7,
    UC_ARM_REG_R8, UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11,
    UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_CPSR)

ROOT = Path(__file__).resolve().parents[1]
ROM_BASE, ENTRY, CLEANUP, FLAGS = 0x08000000, 0x09FFF800, 0x09090958, 0x02022B4C
STACK, STOP, SEND_LINK, EMIT_END = 0x03007000, 0x08000100, 0x0800D9EC, 0x0800EB94
RESTORED = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R4,
            UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7]
PRESERVED = [UC_ARM_REG_R8, UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11]


def verify(path, allowed, code, hook, choice_hook):
    image = path.read_bytes()
    digest = hashlib.sha256(image).hexdigest()
    assert digest in allowed and len(image) == 0x2000000, "Unsupported ROM profile"

    def case(flags, patched, outcome=2):
        cpu = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
        for address, size in [(ROM_BASE, len(image)), (0x02000000, 0x40000), (0x03000000, 0x8000)]:
            cpu.mem_map(address, size)
        cpu.mem_write(ROM_BASE, image)
        if patched:
            cpu.mem_write(ENTRY, code)
            # The bridge uses the same temporary Thumb branch and restores the
            # profile's exact original eight bytes on close.
            cpu.mem_write(CLEANUP, bytes.fromhex("00480047") + struct.pack("<I", hook))
        cpu.mem_write(FLAGS, struct.pack("<I", flags))
        cpu.reg_write(UC_ARM_REG_CPSR, 0xA0000010)
        saved = [0x10001000 + i * 0x100 for i in range(7)]
        cpu.mem_write(STACK, struct.pack("<8I", *saved, STOP | 1))
        cpu.reg_write(UC_ARM_REG_SP, STACK)
        cpu.reg_write(UC_ARM_REG_R7, FLAGS)
        cpu.reg_write(UC_ARM_REG_R4, 0)
        for i, register in enumerate(PRESERVED):
            cpu.reg_write(register, 0x80008000 + i * 0x100)
        sent = []

        def observe(machine, address, size, user):
            if address == STOP:
                machine.emu_stop()
            elif address == SEND_LINK:
                buffer = machine.reg_read(UC_ARM_REG_R0)
                count = machine.reg_read(UC_ARM_REG_R1)
                source = machine.reg_read(UC_ARM_REG_R2)
                sent.append((buffer, bytes(machine.mem_read(source, count)).hex()))
                machine.reg_write(UC_ARM_REG_PC, machine.reg_read(UC_ARM_REG_LR))

        cpu.hook_add(UC_HOOK_CODE, observe)
        cpu.emu_start(CLEANUP | 1, STOP, count=1000)
        assert cpu.reg_read(UC_ARM_REG_PC) == STOP, "Cleanup did not return through its native epilogue"
        assert cpu.reg_read(UC_ARM_REG_SP) == STACK + 32, "Native cleanup stack changed"
        assert [cpu.reg_read(r) for r in RESTORED] == saved, "Native cleanup restore registers changed"
        assert [cpu.reg_read(r) for r in PRESERVED] == [0x80008000 + i * 0x100 for i in range(4)]
        after = int.from_bytes(cpu.mem_read(FLAGS, 4), "little")
        condition = cpu.reg_read(UC_ARM_REG_CPSR) & 0xF0000000
        # Execute the ROM's actual command-55 producer and routing gate. Only
        # the downstream link queue is observed, without constructing a battle
        # heap or simulating a peer result.
        cpu.reg_write(UC_ARM_REG_R0, 0)
        cpu.reg_write(UC_ARM_REG_R1, outcome)
        cpu.reg_write(UC_ARM_REG_LR, STOP | 1)
        cpu.emu_start(EMIT_END | 1, STOP, count=1000)
        assert cpu.reg_read(UC_ARM_REG_PC) == STOP
        assert cpu.reg_read(UC_ARM_REG_SP) == STACK + 32
        local = bytes(cpu.mem_read(0x02022BC4, 2)).hex()
        return after, condition, sent, local

    cases = []
    for flags in [0, 8, 0x400, 0x408, 2, 0x2A, 0x4002A, 0x402]:
        original, fixed = case(flags, False), case(flags, True)
        if flags & 2:
            assert fixed[0] == flags, "Native link flags were cleared before the terminal command"
            assert fixed[2] == [(0, "3702")] and fixed[3] == "0000", "Native loss did not enter the link route"
            if not flags & 0x400:
                assert original[0] == 0 and original[2] == [] and original[3] == "3702", "Expected original failure was not reproduced"
            for outcome in [1, 3]:
                value = case(flags, True, outcome)
                assert value[2] == [(0, bytes([0x37, outcome]).hex())], "Native outcome was altered"
        else:
            assert fixed == original, "Non-link flags, condition codes or routing changed"
        cases.append({"flags": flags, "originalFlags": original[0], "fixedFlags": fixed[0], "linkTransfers": fixed[2]})
    run_outcomes=[]
    for choices,expected in [((3,0),0x82),((0,3),0x81),((3,3),0x83)]:
        cpu=Uc(UC_ARCH_ARM,UC_MODE_THUMB)
        for address,size in [(ROM_BASE,len(image)),(0x02000000,0x40000),(0x03000000,0x8000)]:cpu.mem_map(address,size)
        cpu.mem_write(ROM_BASE,image);cpu.mem_write(FLAGS,struct.pack('<I',2))
        cpu.mem_write(0x02023BCC,b'\x02');cpu.mem_write(0x02023BDE,b'\x00\x01')
        cpu.mem_write(0x02023D7C,bytes(choices));cpu.reg_write(UC_ARM_REG_SP,STACK);cpu.reg_write(UC_ARM_REG_LR,STOP|1)
        def observe_run(machine,address,size,user):
            if address==STOP:machine.emu_stop()
            elif address==0x080751C4:
                # Two fixture battlers, one on each side. All Run decision and
                # outcome instructions execute directly from the real ROM.
                machine.reg_write(UC_ARM_REG_R0,machine.reg_read(UC_ARM_REG_R0)&1)
                machine.reg_write(UC_ARM_REG_PC,machine.reg_read(UC_ARM_REG_LR))
        cpu.hook_add(UC_HOOK_CODE,observe_run);cpu.emu_start(0x080168A5,STOP,count=1000)
        outcome=cpu.mem_read(0x02023E8A,1)[0]
        assert cpu.reg_read(UC_ARM_REG_PC)==STOP and outcome==expected,'Native Run result changed'
        run_outcomes.append({'choices':choices,'nativeOutcome':outcome})
    selections=[]
    for action in range(13):
        results=[]
        for patched in (False,True):
            cpu=Uc(UC_ARCH_ARM,UC_MODE_THUMB)
            for address,size in [(ROM_BASE,len(image)),(0x02000000,0x40000),(0x03000000,0x8000)]:cpu.mem_map(address,size)
            cpu.mem_write(ROM_BASE,image)
            if patched:
                cpu.mem_write(ENTRY,code);cpu.mem_write(0x090A9F10,bytes.fromhex('004b1847')+struct.pack('<I',choice_hook))
            cpu.mem_write(0x0300402E,b'\xa5\0');cpu.reg_write(UC_ARM_REG_SP,STACK)
            cpu.reg_write(UC_ARM_REG_R0,1);cpu.reg_write(UC_ARM_REG_R1,action);cpu.reg_write(UC_ARM_REG_R2,0x1234)
            calls=[]
            def observe_choice(machine,address,size,user):
                if address==0x090A9EFE:machine.emu_stop()
                elif address==0x0800E848:
                    calls.append([machine.reg_read(register) for register in [UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2]])
                    machine.reg_write(UC_ARM_REG_PC,machine.reg_read(UC_ARM_REG_LR))
            cpu.hook_add(UC_HOOK_CODE,observe_choice);cpu.emu_start(0x090A9F11,0x090A9EFE,count=1000)
            assert cpu.reg_read(UC_ARM_REG_PC)==0x090A9EFE and cpu.reg_read(UC_ARM_REG_SP)==STACK
            results.append((calls,bytes(cpu.mem_read(0x0300402E,2))))
        assert results[0][0]==results[1][0]==[[1,action,0x1234]],'Native choice dispatch changed'
        assert results[1][1]==bytes([0xA5,3 if action==3 else 0]),'Run intent was ambiguous or corrupted disconnect flag'
        selections.append({'action':action,'runIntent':action==3})
    return {"romSHA256": digest, "entryBytes": len(code), "cases": cases, "runOutcomes":run_outcomes,"runSelectionCases":selections,"passed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    metadata = json.loads((ROOT / "PrototypeConfiguration/integrated-game.json").read_text())
    allowed = {metadata["baseline_sha256"], metadata["integrated_sha256"]}
    header = (ROOT / "Delta/Bound/NativeBattle/BoundBattleEntryCode.h").read_text()
    body = header.split("BoundBattleEntryCode[] = {", 1)[1].split("};", 1)[0]
    code = bytes(int(value, 16) for value in re.findall(r"0x([0-9A-Fa-f]{2})", body))
    hook = int(re.search(r"BoundBattlePreserveLinkFlagsAddress = 0x([0-9A-Fa-f]+)", header)[1], 16)
    choice_hook = int(re.search(r"BoundBattleChoiceAddress = 0x([0-9A-Fa-f]+)", header)[1], 16)
    assert len(code) <= 0x3F0, "Entry overlaps the role byte"
    report = {"profiles": [verify(path, allowed, code, hook,choice_hook) for path in args.rom], "passed": True}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()

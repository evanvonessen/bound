#!/usr/bin/env python3
"""Exact owned ROM native restoration and pinned raw-state layout checks."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
for name in ['original', 'current', 'base', 'output']: parser.add_argument('--' + name, type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
gba = (ROOT / 'Cores/GBADeltaCore/visualboyadvance-m/src/gba/GBA.cpp').read_text()
fields = gba.split('variable_desc saveGameStruct[] = {')[1].split('};')[0]
sizes = {'uint16_t': 2, 'uint32_t': 4, 'int': 4, 'bool': 1}
offset = 4+16+4+45*4+sum(sizes[t] for t in re.findall(r'sizeof\((\w+)\)', fields))+8+0x8000+0x400
assert offset == 34271
assert 'stateWorkRAMOffset=34271' in (ROOT / 'Delta/Bound/BoundVBABattleBridge.mm').read_text()
source = r'''
#include "MultiRedProfiles.h"
#include <CommonCrypto/CommonDigest.h>
#include <vector>
#include <fstream>
#include <iostream>
#include <cassert>
static std::vector<uint8_t> read(const char *path) { std::ifstream f(path,std::ios::binary); return {std::istreambuf_iterator<char>(f),{}}; }
static void hash(const uint8_t *p,unsigned n,uint8_t *d) { CC_SHA256(p,n,d); }
static void put(std::vector<uint8_t>&p,size_t n,unsigned v) { for(unsigned j=0;j<4;j++)p[n+j]=v>>(j*8); }
int main(int argc,char **argv) {
 assert(argc==4);const auto base=read(argv[3]);assert(base.size()==0x2000000);
 const MultiRedNativeProfile *profiles[]={&MultiRedOriginalProfile,&MultiRedCurrentProfile};
 unsigned checks=0;
 for(unsigned i=0;i<2;i++) {
  const auto original=read(argv[i+1]);assert(original.size()==base.size());
  const auto &profile=*profiles[i], &other=*profiles[1-i];
  assert(multiRedProfile(original.data())==&profile); checks++;
  auto restored=original; assert(profile.restoreCanonical(restored.data(),hash));assert(restored==base);checks+=2;
  auto dynamic=original;memset(dynamic.data()+profile.hostOffset,0xAA,profile.hostSize);memset(dynamic.data()+profile.uiHostOffset,0x55,profile.uiHostSize);
  if(profile.cooperative())memset(dynamic.data()+profile.cooperativeHostOffset,0xCC,profile.cooperativeHostSize);
  assert(profile.restoreCanonical(dynamic.data(),hash));assert(dynamic==base);checks+=2;
  auto corrupt=original;corrupt[0x1000]^=1;assert(!profile.restoreCanonical(corrupt.data(),hash));checks++;
  auto wrong=original;assert(!other.restoreCanonical(wrong.data(),hash));assert(wrong==original);checks+=2;
  std::vector<uint8_t> ram(0x40000);put(ram,0,0x31434D52);put(ram,4,profile.major);put(ram,8,profile.snapshotRegionSize);put(ram,16,profile.snapshotSize);
  put(ram,64,0x31534D52);put(ram,68,profile.major);put(ram,72,profile.snapshotSize);put(ram,76,2);
  memcpy(ram.data()+96,profile.ruleset,16);put(ram,112,1);put(ram,116,1);put(ram,120,profile.layout);
  assert(profile.admitsStateRAM(ram.data(),ram.size()));assert(!other.admitsStateRAM(ram.data(),ram.size()));checks+=2;
  put(ram,120,other.layout);assert(!profile.admitsStateRAM(ram.data(),ram.size()));checks++;
  put(ram,120,profile.layout);put(ram,76,3);assert(!profile.admitsStateRAM(ram.data(),ram.size()));checks++;
  put(ram,76,2);assert(!profile.admitsStateRAM(ram.data(),100));checks++;
 }
 std::cout << "{\"passed\":true,\"nativeChecks\":" << checks << "}\n";
}
'''
cpp = args.output / 'profiles.cpp'; cpp.write_text(source)
binary = args.output / 'profiles'
command = ['xcrun', 'clang++', '-std=c++17', '-Wno-deprecated-declarations', '-I', str(ROOT / 'Delta/Bound/SharedWorld'), str(cpp), '-o', str(binary)]
subprocess.run(command, check=True)
result = subprocess.run([str(binary), str(args.original), str(args.current), str(args.base)], text=True, capture_output=True, check=True)
report = json.loads(result.stdout)
report.update(stateWorkRAMOffset=offset, inputs={name: hashlib.sha256(getattr(args,name).read_bytes()).hexdigest() for name in ['original','current','base']})
(args.output / 'results.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))

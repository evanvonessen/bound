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
for name in ['stack-safe', 'debug-defaults', 'friends-multiview', 'pre-shiny-magikarp', 'pre-links-menu']:
    parser.add_argument('--' + name, type=Path, help='Frozen exact cartridge; verify alongside the current profile')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
gba = (ROOT / 'Cores/GBADeltaCore/visualboyadvance-m/src/gba/GBA.cpp').read_text()
fields = gba.split('variable_desc saveGameStruct[] = {')[1].split('};')[0]
sizes = {'uint16_t': 2, 'uint32_t': 4, 'int': 4, 'bool': 1}
offset = 4+16+4+45*4+sum(sizes[t] for t in re.findall(r'sizeof\((\w+)\)', fields))+8+0x8000+0x400
assert offset == 34271
assert 'stateWorkRAMOffset=34271' in (ROOT / 'Delta/Bound/BoundVBABattleBridge.mm').read_text()
fixtures = [('original', 'MultiRedOriginalProfile'), ('current', 'MultiRedCurrentProfile')]
fixtures += [(name, profile) for name, profile in [('stack_safe', 'MultiRedStackSafeProfile'), ('debug_defaults', 'MultiRedDebugDefaultsProfile'), ('friends_multiview', 'MultiRedFriendsMultiviewProfile'), ('pre_shiny_magikarp', 'MultiRedPreShinyMagikarpProfile'), ('pre_links_menu', 'MultiRedPreLinksMenuProfile')] if getattr(args, name)]
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
 const auto base=read(argv[1]);assert(base.size()==0x2000000);
 const MultiRedNativeProfile *profiles[]={PROFILE_FIXTURES};
 const unsigned count=sizeof(profiles)/sizeof(*profiles);assert(argc==int(count)+2);
 unsigned checks=0;
 for(unsigned i=0;i<count;i++) {
  const auto original=read(argv[i+2]);assert(original.size()==base.size());
  const auto &profile=*profiles[i], &other=*profiles[(i+1)%count];
  assert(multiRedProfile(original.data())==&profile); checks++;
  auto restored=original; assert(profile.restoreCanonical(restored.data(),hash));assert(restored==base);checks+=2;
  auto dynamic=original;memset(dynamic.data()+profile.hostOffset,0xAA,profile.hostSize);memset(dynamic.data()+profile.uiHostOffset,0x55,profile.uiHostSize);
  if(profile.cooperative())memset(dynamic.data()+profile.cooperativeHostOffset,0xCC,profile.cooperativeHostSize);
  if(profile.linksHostSize)memset(dynamic.data()+profile.linksHostOffset,0xDD,profile.linksHostSize);
  assert(profile.restoreCanonical(dynamic.data(),hash));assert(dynamic==base);checks+=2;
  auto corrupt=original;corrupt[0x1000]^=1;assert(!profile.restoreCanonical(corrupt.data(),hash));checks++;
  if(profile.linksHostSize) {
   assert(profile.linksHostOffset+profile.linksHostSize<=base.size());
   assert(profile.linksCodeStart<profile.linksCodeEnd&&profile.linksCodeEnd<=base.size());
   assert(profile.linksHostOffset+profile.linksHostSize<=profile.linksCodeStart);
   assert(profile.linksCodeEnd<=profile.cooperativeCodeStart);
   for(unsigned k=0;k<profile.linksHostSize;k++)assert(base[profile.linksHostOffset+k]==0xFF);
   for(unsigned k=profile.linksCodeStart;k<profile.linksCodeEnd;k++)assert(base[k]==0xFF);
   auto wrongCode=original;wrongCode[profile.linksCodeStart]^=1;
   assert(!profile.restoreCanonical(wrongCode.data(),hash));checks++;
  }
  for(unsigned j=0;j<count;j++)if(j!=i) {
   auto wrong=original;assert(!profiles[j]->restoreCanonical(wrong.data(),hash));assert(wrong==original);checks+=2;
  }
  std::vector<uint8_t> ram(0x40000);put(ram,0,0x31434D52);put(ram,4,profile.major);put(ram,8,profile.snapshotRegionSize);put(ram,16,profile.snapshotSize);
  put(ram,64,0x31534D52);put(ram,68,profile.major);put(ram,72,profile.snapshotSize);put(ram,76,2);
  memcpy(ram.data()+96,profile.ruleset,16);put(ram,112,1);put(ram,116,1);put(ram,120,profile.layout);
  assert(profile.admitsStateRAM(ram.data(),ram.size()));checks++;
  for(unsigned j=0;j<count;j++)if(j!=i) {assert(!profiles[j]->admitsStateRAM(ram.data(),ram.size()));checks++;}
  put(ram,120,other.layout);assert(!profile.admitsStateRAM(ram.data(),ram.size()));checks++;
  put(ram,120,profile.layout);put(ram,76,3);assert(!profile.admitsStateRAM(ram.data(),ram.size()));checks++;
  put(ram,76,2);assert(!profile.admitsStateRAM(ram.data(),100));checks++;
 }
 std::cout << "{\"passed\":true,\"nativeChecks\":" << checks << "}\n";
}
'''
source = source.replace('PROFILE_FIXTURES', ','.join('&'+profile for _, profile in fixtures))
cpp = args.output / 'profiles.cpp'; cpp.write_text(source)
binary = args.output / 'profiles'
command = ['xcrun', 'clang++', '-std=c++11', '-Wno-deprecated-declarations', '-I', str(ROOT / 'Delta/Bound/SharedWorld'), str(cpp), '-o', str(binary)]
subprocess.run(command, check=True)
inputs = [str(binary), str(args.base)] + [str(getattr(args, name)) for name, _ in fixtures]
result = subprocess.run(inputs, text=True, capture_output=True, check=True)
report = json.loads(result.stdout)
names = ['base'] + [name for name, _ in fixtures]
report.update(stateWorkRAMOffset=offset, inputs={name: hashlib.sha256(getattr(args,name).read_bytes()).hexdigest() for name in names})
(args.output / 'results.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))

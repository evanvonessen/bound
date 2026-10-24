#!/usr/bin/env python3
"""Import/check the data ABI exported by integratedred; no game code is built here."""
from pathlib import Path
import argparse,hashlib,json,re,struct
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--from-game',type=Path)
p.add_argument('--check',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1]
sha=lambda b:hashlib.sha256(b).hexdigest()
manifest_path=root/'PrototypeConfiguration/integrated-game.json'
header_path=root/'Delta/Bound/SharedWorld/BoundGameABI.h'
swift=root/'Delta/Bound/BoundSharedProgression.swift'
if a.from_game:
 m=json.loads((a.from_game/'manifest.json').read_text())
 header=(a.from_game/'BoundGameABI.h').read_bytes();contract=(a.from_game/'contract.json').read_bytes()
 if sha(header)!=m['bound_abi_header_sha256'] or sha(contract)!=m['contract_sha256']:
  raise SystemExit('Game ABI export hashes differ')
 if json.loads(contract)!=m['contract']:
  raise SystemExit('Game contract differs from its release manifest')
 if m['contract']['abi_major']!=1 or m['contract']['wire_version']!=2:
  raise SystemExit('Unsupported game ABI export')
else:
 m=json.loads(manifest_path.read_text())
 if sha(header_path.read_bytes())!=m['bound_abi_header_sha256']:raise SystemExit('Generated ABI header changed')
c=m['contract']
supported={'abi_major':1,'abi_minor':0,'wire_version':2,'checkpoint_format':1,
           'battery_save_version':1,'save_state_layout':2,'snapshot_size':960,
           'snapshot_region_size':2048,'snapshot_buffer_offset':64,'snapshot_buffers':2,
           'host_port_size':1024,'reserved_heap_bytes':4096,
           'ui_abi_major':1,'ui_abi_minor':0,'ui_host_port_size':2048,'ui_snapshot_size':256}
if c.get('independent_progression'):
 supported.update(save_state_layout=5, setup_settings_version=5, independent_progression=True)
if c.get('cooperative_doubles'):
 supported.update(save_state_layout=6 if c.get('independent_progression') else 4,reserved_heap_bytes=8192,cooperative_abi_major=1,cooperative_abi_minor=0,
  cooperative_host_port_offset=0x1FE0000,cooperative_host_port_size=16384,cooperative_snapshot_address=0x02001800,cooperative_snapshot_size=2048)
if any(c.get(key)!=value for key,value in supported.items()):
 raise SystemExit('This Bound adapter does not support the exported game layout')
if a.from_game:
 header_path.write_bytes(header);manifest_path.write_text(json.dumps(m,indent=2)+'\n')
signature=bytes.fromhex(c['ruleset_id'])+struct.pack('<HHHH',c['abi_major'],c['abi_minor'],c['checkpoint_format'],c['battery_save_version'])
constants='// BEGIN GENERATED GAME CONTRACT\n'
constants+='enum BoundWorldContract {\n'
constants+=f'    static let romSHA256 = "{m["integrated_sha256"]}"\n'
constants+='    static let compatibility = Data(['+','.join(str(x) for x in signature)+'])\n'
constants+=f'    static let ruleset = Data([{",".join(str(x) for x in bytes.fromhex(c["ruleset_id"]))}])\n'
constants+='}\n// END GENERATED GAME CONTRACT'
s=swift.read_text()
pattern=r'// BEGIN GENERATED GAME CONTRACT.*?// END GENERATED GAME CONTRACT'
if re.search(pattern,s,re.S):expected=re.sub(pattern,lambda _:constants,s,flags=re.S)
else:expected=s.replace('import DeltaCore','import DeltaCore\n\n'+constants,1)
if a.check:
 if s!=expected:raise SystemExit('Generated Swift ABI constants changed')
else:swift.write_text(expected)
print(json.dumps({'verified':True,'abi':c['abi_major'],'wire':c['wire_version'],'rom_sha256':m['integrated_sha256'],'game_code_in_bound':False},indent=2))

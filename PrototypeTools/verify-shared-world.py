#!/usr/bin/env python3
"""Validate this app's exported ABI against the game source's native verifier."""
from pathlib import Path
import argparse,hashlib,json,subprocess
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--game-source',type=Path,required=True);p.add_argument('--rom',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
m=json.loads((root/'PrototypeConfiguration/integrated-game.json').read_text())
game=json.loads((a.game_source/'build/integrated-contract/manifest.json').read_text())
assert game['integrated_sha256']==m['integrated_sha256'],'App/game releases differ'
assert hashlib.sha256((root/'Delta/Bound/SharedWorld/BoundGameABI.h').read_bytes()).hexdigest()==game['bound_abi_header_sha256']
subprocess.run([str(a.game_source/'.venv/bin/python'),str(a.game_source/'tools/verify_shared_world.py'),'--integrated','--rom',str(a.rom.resolve()),'--output',str(a.output.resolve())],cwd=a.game_source,check=True)
print('Bound ABI matches the verified game release; no app-owned game rules')

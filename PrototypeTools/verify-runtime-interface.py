#!/usr/bin/env python3
"""Verify frozen 508 bindings and current runtime admission against exact ROMs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LEGACY_SHA = '24e391382f8d64119f29fb87c8886955885a88d196c79a79e7e41d2fb79a0f08'
TABLE_SHA = 'e27a1e5ff9624f84460775755704e0cfd18a9523db282a44819e32e062c8792b'
HEADER_SHA = '228e1162e77f6f779bd5ce986defc691742f8bc6d57caeb3770e7d5e8a689121'
SOUL_QUERY = 0x09FCA195

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--legacy-rom', type=Path, required=True)
p.add_argument('--legacy-manifest', type=Path, required=True)
p.add_argument('--rom', type=Path, action='append', default=[], help='Additional exact current cartridge; repeatable')
p.add_argument('--manifest', type=Path, action='append', default=[], help='Matching game export for each --rom, in order')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
assert all(path.is_absolute() for path in [a.legacy_rom, a.legacy_manifest, a.output, *a.rom, *a.manifest]), 'Use explicit absolute paths'
assert len(a.rom) == len(a.manifest), 'Supply one selected --manifest per --rom'
sha = lambda data: hashlib.sha256(data).hexdigest()
legacy = a.legacy_rom.read_bytes()
assert sha(legacy) == LEGACY_SHA, 'Legacy input must be the exact reviewed published508 ROM'
header = ROOT / 'Delta/Bound/SharedWorld/BoundLegacyRuntimeBindings.h'
assert sha(header.read_bytes()) == HEADER_SHA, 'Frozen legacy header changed'
body = header.read_text().split('BoundLegacyRuntimeBindings[]={\n', 1)[1].split('};', 1)[0]
rows = [(int(offset), int(size), bytes(int(v, 16) for v in data.split(',') if v))
        for offset, size, data in re.findall(r'\{(\d+),(\d+),\{([^}]*)\}\}', body)]
assert len(rows) == struct.unpack_from('<I', legacy, 0x1FE4014)[0] == 105
table = b''.join(struct.pack('<II16s', offset, size, data) for offset, size, data in rows)
assert sha(table) == TABLE_SHA
assert table == legacy[0x1FE4040:0x1FE4040 + len(table)], 'Frozen bindings differ from reviewed cartridge'
# The Soul Link shim calls one cartridge-owned function directly. Compatible
# restoration records alone do not establish that executable binding. Keep
# the exact pair's shared target/data ABI pinned until per-ROM resolution is
# implemented; never silently ship a new shim that calls into the wrong508 code.
legacy_manifest = json.loads(a.legacy_manifest.read_text())
assert legacy_manifest['integrated_sha256'] == LEGACY_SHA
assert legacy_manifest['symbols']['GameEliminationIsMon'] == SOUL_QUERY
current_header = ROOT / 'Delta/Bound/SharedWorld/BoundGameABI.h'
query = re.search(r'GameEliminationQueryAddress=(\d+)u;', current_header.read_text())
assert query and int(query[1]) == SOUL_QUERY, 'Soul Link target moved: implement per-ROM binding before importing this pair'
imported_path = ROOT / 'PrototypeConfiguration/integrated-game.json'
imported = json.loads(imported_path.read_text())
assert imported['bound_abi_header_sha256'] == sha(current_header.read_bytes())
contracts = [imported]
for rom_path, manifest_path in zip(a.rom, a.manifest):
    manifest = json.loads(manifest_path.read_text())
    assert manifest['integrated_sha256'] == sha(rom_path.read_bytes()), 'Selected ROM/export identity differs'
    assert manifest['symbols']['GameEliminationIsMon'] == SOUL_QUERY, 'Selected ROM relocated the embedded Soul Link target'
    contracts.append(manifest)
for manifest in contracts:
    # Rulesets can change, but all bridge-owned data locations, capacities,
    # versions and restore regions in this exact pair remain the reviewed ABI.
    for key, value in legacy_manifest['contract'].items():
        if key not in ('ruleset_id', 'source_of_truth'):
            assert manifest['contract'].get(key) == value, f'Legacy bridge ABI changed: {key}'
soul_headers = [ROOT / f'Delta/Bound/SoulLink/{name}.h' for name in ('BoundSoulCode', 'BoundSoulQACode')]
soul_imports = {}
for path in soul_headers:
    name = path.stem
    body = path.read_text().split(name + '[]={', 1)[1].split('};', 1)[0]
    code = bytes(int(value, 16) for value in re.findall(r'0x([0-9A-Fa-f]{2})', body))
    imports = {struct.unpack_from('<I', code, offset)[0]
               for offset in range(0, len(code) - 3, 4)
               if 0x09FC7000 <= struct.unpack_from('<I', code, offset)[0] < 0x09FF4000}
    host = 0x08000000 + legacy_manifest['contract']['elimination_host_port_offset']
    assert imports == {SOUL_QUERY, host, host + 4, host + 8, host + 16}, 'Review changed cartridge imports in Soul Link shim'
    assert code.count(struct.pack('<I', SOUL_QUERY)) == 2, 'Compiled Soul Link calls do not match the reviewed query target'
    soul_imports[name] = {'codeSHA256': sha(code), 'cartridgeAddresses': sorted(imports)}
a.output.mkdir(parents=True, exist_ok=True)
source = ROOT / 'PrototypeTools/test-runtime-interface.cpp'
binary = a.output / 'runtime-interface'
command = ['xcrun', 'clang++', '-std=c++11', '-Wno-deprecated-declarations',
           '-I', str(ROOT / 'Delta/Bound/SharedWorld'), str(source), '-o', str(binary)]
subprocess.run(command, check=True)
result = subprocess.run([str(binary), str(a.legacy_rom), *map(str, a.rom)], capture_output=True, text=True, check=True)
(a.output / 'runtime-interface.log').write_text(result.stdout + result.stderr)
report = {'passed': True, 'legacyRecords': len(rows), 'legacyTableSHA256': TABLE_SHA,
          'inputs': {str(path): sha(path.read_bytes()) for path in [a.legacy_rom, *a.rom]},
          'manifests': {str(path): sha(path.read_bytes()) for path in [a.legacy_manifest, imported_path, *a.manifest]},
          'soulQueryAddress': SOUL_QUERY, 'soulImports': soul_imports,
          'sources': {str(path.relative_to(ROOT)): sha(path.read_bytes()) for path in [
              source, Path(__file__), header,
              ROOT / 'Delta/Bound/SharedWorld/MultiRedRuntime.h',
              current_header, *soul_headers]},
          'scope': 'Complete current/legacy binding sets, canonical original-engine restoration, changed-ROM hash isolation, every record field/padding, counts, ordering, duplicates, mixed sets when distinct, capabilities/layout/payload/engine corruption, unchanged bridge data ABI and actual compiled Soul Link cartridge target imports. No state migration or simulator claim.'}
(a.output / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))

#!/usr/bin/env python3
"""Render the offline cleanup catalogue from verified release/profile evidence."""
import argparse
import json
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--check', action='store_true')
a = p.parse_args()
rows = json.loads((ROOT/'PrototypeConfiguration/recognized-multi-red-roms.json').read_text())['identities']
assert len({r['sha256'] for r in rows}) == len(rows)
assert len({r['gameID'] for r in rows}) == len(rows)
lines = ['// Verified release downloads and frozen exact profiles; see recognized-multi-red-roms.json.', 'import Foundation', '',
         'enum BoundRecognizedROMs {', '    static let all: [BoundROMCleanupIdentity] = [']
for r in rows:
    assert re.fullmatch('[a-f0-9]{64}', r['sha256']) and re.fullmatch('[a-f0-9]{40}', r['gameID'])
    assert r['size'] == 33554432
    if r['source'].startswith('https://'):
        assert r['source'].startswith('https://github.com/evanvonessen/multi_red/releases/download/')
        assert '/'+r['release']+'/' in r['source']
    else:
        source = json.loads((ROOT/r['source']).read_text())
        assert source['integrated_sha256'] == r['sha256']
    lines.append('        .init(sha256: "'+r['sha256']+'", gameID: "'+r['gameID']+'", evidence: "'+r['source']+'"),')
lines += ['    ]', '}', '']
expected = '\n'.join(lines)
output = ROOT/'Delta/Bound/BoundRecognizedROMs.swift'
if a.check: assert output.read_text() == expected, 'Stale recognized-ROM catalogue'
else: output.write_text(expected)
print(json.dumps({'verified': True, 'identities': len(rows)}))

#!/usr/bin/env python3
"""Compile the actual metadata/map factory and its focused Swift test bodies.

This is pure metadata validation, with no simulated battle/native endpoints.
Source identity/record/ledger validators and codec models are extracted intact.
Only the XCTest runner is replaced by direct assertion adapters.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
soul=(ROOT/'Delta/Bound/BoundSoulLink.swift').read_text()
identity=soul[soul.index('struct BoundSoulIdentity:'):soul.index('struct BoundSoulMon:')]
record=soul[soul.index('struct BoundSoulRecord:'):soul.index('struct BoundSoulLedger:')]
ledger=soul[soul.index('struct BoundSoulLedger:'):soul.index('    var lossBits:')]
ledger=ledger.replace('    var acquisitionBits: Data { Self.bits(acquired) }\n','')+'}\n'
links=(ROOT/'Delta/Bound/BoundSoulLinks.swift').read_text()
presentation=links[links.index('struct BoundSoulLinkPresentation:'):links.index('/// BLP1')]
losses=(ROOT/'Delta/Bound/BoundBattleLosses.swift').read_text()
losses=losses[losses.index('/// Presentation history'):losses.index('/// Each device always')]
cooperative=(ROOT/'Delta/Bound/BoundCooperativeDoubles.swift').read_text()
model=cooperative[cooperative.index('private func coopWord'):cooperative.index('/// Exact device-local execution;')]
model+=cooperative[cooperative.index('struct BoundCooperativeSnapshot:'):cooperative.index('/// Bounded binary messages')]
tests=(ROOT/'PrototypeIntegrationTests/CooperativeSoulPairTests.swift').read_text().replace('@testable import Delta','').replace('import XCTest','')
runner_source=(ROOT/'PrototypeTools/test-battle-loss-model.py').read_text()
assertions=next(ast.literal_eval(node.value) for node in ast.parse(runner_source).body if isinstance(node,ast.Assign) and any(isinstance(target,ast.Name) and target.id=='assertions' for target in node.targets))
assertions+='\nfunc XCTAssertNotEqual<T:Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T) { do { let left=try a(),right=try b(); precondition(left != right) } catch { preconditionFailure(String(describing:error)) } }\n'
names=re.findall(r'    func (test\w+)\(',tests)
source='import Foundation\nimport CryptoKit\n'+identity+record+ledger+presentation+losses+model+assertions+tests+'\nlet tests=CooperativeSoulPairTests()\n'+'\n'.join('try tests.'+name+'()' for name in names)+'\nprint("PASS")\n'
main=out/'main.swift';main.write_text(source)
subprocess.run(['xcrun','swiftc','-module-cache-path',str(out/'modules'),str(main),'-o',str(out/'cooperative-soul-pair-tests')],check=True)
r=subprocess.run([str(out/'cooperative-soul-pair-tests')],capture_output=True,text=True);(out/'tests.log').write_text(r.stdout+r.stderr);r.check_returncode();assert r.stdout.strip()=='PASS'
report={'passed':True,'pureSwiftMapCases':len(names),'modelSHA256':hashlib.sha256(model.encode()).hexdigest(),'cases':names}
(out/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))

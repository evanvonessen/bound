#!/usr/bin/env python3
"""Run actual Foundation-only encounter ledger and XCTest cases without a simulator.

Extracts maintained declarations/tests verbatim; no parallel policy model.
Use --output inside the isolated artifact tree.
"""
from pathlib import Path
import argparse, re, subprocess
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args(); root = Path(__file__).resolve().parents[1]
battle_source=(root/'Delta/Bound/BoundBattleLosses.swift').read_text()
battle_models=battle_source[battle_source.index('/// Presentation history'):battle_source.index('/// Each device always')]

s = (root/'Delta/Bound/BoundSoulLink.swift').read_text()
model = s[s.index('struct BoundSoulIdentity:'):s.index('/// The frame owner')]
t = (root/'PrototypeIntegrationTests/SoulLinkTests.swift').read_text()
tests = t[t.index('final class EncounterAllowanceTests:'):]
names = re.findall(r'    func (test\w+)\(\) throws', tests)
assert len(names) >= 5
source = 'import Foundation\nimport XCTest\n' + battle_models + model + (root/'Delta/Bound/BoundSoulExtras.swift').read_text() + (root/'Delta/Bound/BoundSoulLinks.swift').read_text() + tests
source += '\nlet suite = XCTestSuite(name: "Encounter allowances")\n'
source += '\n'.join(f'suite.addTest(EncounterAllowanceTests(selector: NSSelectorFromString("{n}")))' for n in names)
source += '\nsuite.run()\nguard let run = suite.testRun, run.executionCount == ' + str(len(names)) + ', run.hasSucceeded else { exit(1) }\n'
a.output.mkdir(parents=True, exist_ok=True)
main = a.output/'main.swift'; main.write_text(source)
frameworks = str(Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'], text=True).strip())/'Developer/Library/Frameworks')
subprocess.run(['swiftc', '-I', str(Path(frameworks).parent.parent/'usr/lib'), '-F', frameworks, '-L', str(Path(frameworks).parent.parent/'usr/lib'), '-lXCTestSwiftSupport', '-Xlinker', '-rpath', '-Xlinker', str(Path(frameworks).parent.parent/'usr/lib'), '-Xlinker', '-rpath', '-Xlinker', frameworks, '-module-cache-path', str(a.output/'ModuleCache'), str(main), '-o', str(a.output/'encounter-ledger-tests')], check=True)
subprocess.run([str(a.output/'encounter-ledger-tests')], check=True)

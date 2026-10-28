#!/usr/bin/env python3
"""Execute the maintained gift/static wire codec and XCTest tests locally.

Run through PrototypeTools/qa-python with --output in the task artifact tree.
No simulator, ROM, account, backend, or player data is used.
"""
import argparse
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
battle_source=(root/'Delta/Bound/BoundBattleLosses.swift').read_text()
battle_models=battle_source[battle_source.index('/// Presentation history'):battle_source.index('/// Each device always')]

model = (root / 'Delta/Bound/BoundSoulLink.swift').read_text()
model = model[model.index('struct BoundSoulIdentity:'):model.index('struct BoundSoulPacket:')]
codec = (root / 'Delta/Bound/BoundSoulExtras.swift').read_text()
tests = (root / 'PrototypeIntegrationTests/SoulExtrasTests.swift').read_text().replace('@testable import Delta\n', '')
names = re.findall(r'    func (test\w+)\(', tests)
assert len(names) == 6
source = 'import Foundation\nimport XCTest\n' + battle_models + model + codec + (root / 'Delta/Bound/BoundSoulLinks.swift').read_text() + tests
source += '\nlet suite = XCTestSuite(name: "Soul Link gift/static wire codec")\n'
source += '\n'.join(f'suite.addTest(SoulExtrasTests(selector: NSSelectorFromString("{name}")))' for name in names)
source += f'\nsuite.run()\nguard let run = suite.testRun, run.executionCount == {len(names)}, run.hasSucceeded else {{ exit(1) }}\n'
a.output.mkdir(parents=True, exist_ok=True)
main = a.output / 'main.swift'
main.write_text(source)
platform = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'], text=True).strip())
frameworks, libraries = str(platform / 'Developer/Library/Frameworks'), str(platform / 'Developer/usr/lib')
subprocess.run(['swiftc', '-I', libraries, '-F', frameworks, '-L', libraries, '-lXCTestSwiftSupport',
                '-Xlinker', '-rpath', '-Xlinker', libraries, '-Xlinker', '-rpath', '-Xlinker', frameworks,
                '-module-cache-path', str(a.output / 'ModuleCache'), str(main), '-o', str(a.output / 'soul-extras-tests')], check=True)
subprocess.run([str(a.output / 'soul-extras-tests')], check=True)

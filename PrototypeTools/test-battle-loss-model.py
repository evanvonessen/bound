#!/usr/bin/env python3
"""Run the actual pure Swift battle journal/codec cases without a simulator.

The generated host executable uses the source model, source slot validators and
source XCTest case bodies. Small assertion adapters replace only XCTest's test
runner; no emulation, native outcome, persistence or transport is simulated.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
model_source = (ROOT / 'Delta/Bound/BoundBattleLosses.swift').read_text()
ledger_source = (ROOT / 'Delta/Bound/BoundSoulLink.swift').read_text()
slot_start = ledger_source.index('    static func validSlot(_ slot: String)')
slots = ledger_source[slot_start:ledger_source.index('    var valid: Bool {', slot_start)]
model = model_source[model_source.index('/// Presentation history'):model_source.index('/// Each device always')]
tests = (ROOT / 'PrototypeIntegrationTests/BattleLossTests.swift').read_text().replace('@testable import Delta', '').replace('import XCTest', '')
names = re.findall(r'    func (test\w+)\(', tests)
assert names and len(names) == len(set(names))
assertions = '''
class XCTestCase {}
func XCTAssertTrue(_ x: @autoclosure () throws -> Bool, _ message: String = "") { do { let value = try x(); precondition(value, message) } catch { preconditionFailure(String(describing:error)) } }
func XCTAssertFalse(_ x: @autoclosure () throws -> Bool, _ message: String = "") { do { let value = try x(); precondition(!value, message) } catch { preconditionFailure(String(describing:error)) } }
func XCTAssertNil<T>(_ x: @autoclosure () throws -> T?, _ message: String = "") { do { let value = try x(); precondition(value == nil, message) } catch { preconditionFailure(String(describing:error)) } }
func XCTAssertEqual<T:Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "") { do { let left = try a(), right = try b(); precondition(left == right, message) } catch { preconditionFailure(String(describing:error)) } }
func XCTAssertThrowsError<T>(_ x: @autoclosure () throws -> T, _ message: String = "") { do { _ = try x() } catch { return }; preconditionFailure("Expected error. "+message) }
func XCTUnwrap<T>(_ x: T?) throws -> T { guard let value=x else { preconditionFailure("Expected a value") };return value }
'''
source = 'import Foundation\nstruct BoundSoulLedger {\n' + slots + '}\n' + model + assertions + '\n' + tests
source += '\nlet tests=BattleLossTests()\n' + '\n'.join('try tests.' + name + '()' for name in names) + '\nprint("PASS")\n'
main = output / 'main.swift'
main.write_text(source)
binary = output / 'battle-loss-tests'
subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(output / 'modules'), str(main), '-o', str(binary)], check=True)
result = subprocess.run([str(binary)], capture_output=True, text=True)
(output / 'model-tests.log').write_text(result.stdout + result.stderr)
result.check_returncode()
assert result.stdout.strip() == 'PASS'
report = {'passed': True, 'pureSwiftModelCases': len(names), 'modelSHA256': hashlib.sha256(model_source.encode()).hexdigest(), 'cases': names}
(output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))

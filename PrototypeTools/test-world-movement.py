#!/usr/bin/env python3
"""Run the source movement coordinator and source XCTest cases without a core.

The controlled observations and message loss/reordering are coordinator fixtures,
not native gameplay evidence. Native walking/terrain acceptance is a separate gate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
model=(ROOT/'Delta/Bound/BoundWorldMovement.swift').read_text()
tests=(ROOT/'PrototypeIntegrationTests/BoundWorldMovementTests.swift').read_text()
names=re.findall(r'    func (test\w+)\(',tests);assert names and len(names)==len(set(names))
adapters=r'''
@MainActor class XCTestCase {}
@MainActor func XCTAssertTrue(_ x:@autoclosure ()->Bool,_ message:String="") {precondition(x(),message)}
@MainActor func XCTAssertFalse(_ x:@autoclosure ()->Bool,_ message:String="") {precondition(!x(),message)}
@MainActor func XCTAssertNil<T>(_ x:@autoclosure ()->T?,_ message:String="") {precondition(x()==nil,message)}
@MainActor func XCTAssertEqual<T:Equatable>(_ a:@autoclosure ()->T,_ b:@autoclosure ()->T,_ message:String="") {let left=a(),right=b();precondition(left==right,"Expected \(right), got \(left). "+message)}
@MainActor func XCTAssertNotEqual<T:Equatable>(_ a:@autoclosure ()->T,_ b:@autoclosure ()->T,_ message:String="") {precondition(a() != b(),message)}
@MainActor func XCTAssertGreaterThan<T:Comparable>(_ a:@autoclosure ()->T,_ b:@autoclosure ()->T,_ message:String="") {precondition(a()>b(),message)}
@MainActor func XCTAssertLessThanOrEqual<T:Comparable>(_ a:@autoclosure ()->T,_ b:@autoclosure ()->T,_ message:String="") {precondition(a()<=b(),message)}
struct BoundPlayerState {struct Point {let x:Int,y:Int}}
final class EmulatorCore {}
enum BoundVBABattleBridge {
    static func setWorldMovementHost(_ d:Data){}
    static func worldMovementSnapshot()->Data {Data()}
    static func worldMovementPublicationInProgress()->Bool {false}
    static func worldMovementTimeline()->UInt64 {0}
    static func requestWorldMovementRevocation(){}
}
'''
preferences=(ROOT/'Delta/Bound/BoundAppearancePreferences.swift').read_text()
preferences=preferences[preferences.index('enum BoundLetPassButton {'):preferences.index('/// Retired customization-visibility')]
source=model.replace('import DeltaCore','')+preferences+adapters+tests.replace('import XCTest','').replace('@testable import Delta','')
source+='\nMainActor.assumeIsolated {let tests=BoundWorldMovementTests()\n'
source+='\n'.join('print("'+name+'");fflush(stdout);tests.'+name+'()' for name in names)
source+='\n}\nprint("PASS")\n'
main=out/'main.swift';main.write_text(source);binary=out/'world-movement-tests'
compiled=subprocess.run(['xcrun','swiftc','-module-cache-path',str(out/'modules'),str(main),'-o',str(binary)],capture_output=True,text=True)
(out/'compile.log').write_text(compiled.stdout+compiled.stderr);compiled.check_returncode()
run=subprocess.run([str(binary)],capture_output=True,text=True)
(out/'model-tests.log').write_text(run.stdout+run.stderr);run.check_returncode();assert run.stdout.rstrip().endswith('PASS')
report={'passed':True,'pureSwiftModelCases':len(names),'cases':names,'modelSHA256':hashlib.sha256(model.encode()).hexdigest(),
        'limits':'Controlled native observations and transport faults test coordinator only. No native endpoint, gameplay, device or WAN outcome is simulated or claimed.'}
(out/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))

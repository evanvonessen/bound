#!/usr/bin/env python3
"""Execute actual native follower binding and compositor models on macOS.

Only UIKit/native I/O adapter methods are omitted from the extracted sources.
No parallel policy models, simulator, ROM writes or backend calls are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zlib

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
p.add_argument('--rom',type=Path);p.add_argument('--state',type=Path);a=p.parse_args()
if bool(a.rom)!=bool(a.state):raise ValueError('Supply both exact ROM and fresh native state')
if a.rom:
    image=a.rom.read_bytes();raw=a.state.read_bytes()
    assert len(image)==0x2000000 and len(raw)==0x61000 and int.from_bytes(raw[8:12],'little')==zlib.crc32(image)
root=Path(__file__).resolve().parents[1]
def read(name):return (root/name).read_text()
def cut(source,start,end):return source[source.index(start):source.index(end)]
state=read('Delta/Bound/BoundPlayerState.swift')
declarations=cut(state,'struct BoundPlayerState:','final class BoundPlayerROMProfile')
declarations+=cut(state,'struct BoundGBAMemorySnapshot:','enum BoundPlayerStateDecoder')
scene=read('Delta/Bound/BoundPlayerScene.swift')
declarations+=cut(scene,'struct BoundPlayerScene:','/// Small bounded ROM-only cache')
if a.rom:
    declarations+=read('Delta/Bound/BoundFriendRouteAccess.swift')
else:
    # This follower-only harness never queries route policy. The full ROM mode
    # below compiles the actual navigation access implementation instead.
    declarations+='struct BoundFriendRouteAccess: Equatable, Sendable {}\n'
if a.rom:
    adapter=scene[scene.index('/// Small bounded ROM-only cache'):]
    start=adapter.index('    static func read(player: BoundPlayerState, memory: BoundGBAMemorySnapshot, profile:')
    end=adapter.index('    static func read(player: BoundPlayerState, memory: BoundGBAMemorySnapshot,\n',start+1)
    declarations+=adapter[:start]+adapter[end:]
    decoder=cut(state,'enum BoundPlayerStateDecoder {','struct BoundPlayerPresenceTracker')
    start=decoder.index('    static func read(profile:')
    end=decoder.index('    /// Pure decoder seam',start)
    declarations+=decoder[:start]+decoder[end:]

feature=read('Delta/Bound/BoundAppearancePreferences.swift')
declarations+=cut(feature,'enum BoundMultiplayerFeatures {','/// Retired customization-visibility')
battle=read('Delta/Bound/BoundBattleLosses.swift')
declarations+=cut(battle,'/// Presentation history','/// Each device always')
soul=read('Delta/Bound/BoundSoulLink.swift')
declarations+=cut(soul,'struct BoundSoulIdentity:','/// The frame owner commits')
declarations+=read('Delta/Bound/BoundSoulExtras.swift')+read('Delta/Bound/BoundSoulLinks.swift')
follower=read('Delta/Bound/BoundPresenceFollower.swift')
declarations+=follower[:follower.index('    func rendered(profile:')]+'}\n'
presence=read('Delta/Bound/BoundLivePresence.swift')
pose=cut(presence,'struct BoundPresencePose:','/// Main-actor, bounded receive buffer')
pose=pose[:pose.index('    func rendered(profile:')]+'}\n'+pose[pose.index('struct BoundPresenceCollision:'):]
declarations+=pose
friend=read('Delta/Bound/BoundFriendInteraction.swift')
declarations+=cut(friend,'struct BoundFriendWorldPosition:','/// A separate namespace')
recorded=read('Delta/Bound/BoundRecordedPlayer.swift')
declarations+=cut(recorded,'struct BoundRecordedPlayerPose:','/// A bounded, memory-only recording')
declarations+=cut(recorded,'enum BoundRecordedPlayerRasterizer {','@MainActor\nfinal class BoundRecordedPlayerOverlay')
display=read('Delta/Bound/BoundPlayerStateDisplay.swift')
methods=display[display.index('    @discardableResult\n    static func composite'):display.index('\n}\n\nprivate final class BoundPresenceVideoRenderer')]
declarations+='enum BoundPresenceFrameCompositor {\n'+methods+'\n}\n'
test_sources=[read('PrototypeIntegrationTests/'+name).replace('@testable import Delta\n','')
    for name in ['FollowerPresentationTests.swift']]
source='import Foundation\nimport CryptoKit\nimport SwiftUI\nimport XCTest\n'+declarations+'\n'+'\n'.join(test_sources)
source+='\nMainActor.assumeIsolated {\nlet suite=XCTestSuite(name:"Actual-source follower presentation models")\n'
count=0
for tests in test_sources:
    name=re.search(r'final class (\w+):?\s*XCTestCase',tests).group(1)
    for method in re.findall(r'func (test\w+)\(',tests):
        source+=f'suite.addTest({name}(selector:NSSelectorFromString("{method}")))\n';count+=1
source+=f'suite.run()\nguard let run=suite.testRun,run.executionCount=={count},run.hasSucceeded else {{ exit(1) }}\n}}\n'
if a.rom:
    source+=r'''
let rom=try Data(contentsOf:URL(fileURLWithPath:ROM_PATH))
let raw=try Data(contentsOf:URL(fileURLWithPath:STATE_PATH))
let snapshot=BoundGBAMemorySnapshot(copyingWorkRAM:raw.subdata(in:0x21000..<0x61000),internalRAM:raw.subdata(in:0x19000..<0x21000))!
func romBytes(_ at:Int,_ count:Int)->[UInt8]? {
 let offset=at-0x08000000
 guard offset>=0,count>=0,offset<=rom.count,count<=rom.count-offset else { return nil }
 return Array(rom[offset..<offset+count])
}
let observed=BoundPlayerStateDecoder.decode(memory:snapshot,frame:1,romBytes:romBytes,presentationOnly:true)
guard var player=observed.player else { fatalError("Actual native player: \(observed.status) \(observed.detail)") }
player.scene=BoundPlayerSceneDecoder.read(player:player,memory:snapshot,rom:romBytes,assets:BoundPlayerSceneAssets())
let reading=BoundPlayerStateReading(frame:1,status:observed.status,detail:observed.detail,player:player)
let binding=BoundNativeFollowerBinding.read(memory:snapshot,player:player)
let follower=BoundPresenceFollower(reading:reading)
let enabled=snapshot.bytes(at:0x0203B25E,count:1)![0]&0x20 != 0
let expected=snapshot.bytes(at:0x02002060,count:1)![0]==7
assert((binding != nil)==expected,"Native BWO publication and host binding disagree")
assert((follower != nil)==expected,"Actual native sprite failed appearance extraction")
func digest(_ data:Data)->String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
var report:[String:Any]=["romSHA256":digest(rom),"stateSHA256":digest(raw),"serviceEnabled":enabled,"nativeVisible":expected,
 "sceneAvailable":player.scene != nil,"playerTile":[player.tile.x,player.tile.y],"map":[player.mapGroup,player.mapNumber],"snapshotUnchanged":Data(snapshot.workRAM)==raw.subdata(in:0x21000..<0x61000)]
if expected {
 let reader=NSObject(),profile=NSObject(),cache=BoundNativeFollowerCache()
 let scope=BoundNativeFollowerScope(core:ObjectIdentifier(reader),profile:ObjectIdentifier(profile),timeline:1)
 func sceneFollower(_ work:Data,_ scope:BoundNativeFollowerScope)->BoundPlayerFollower? {
  var observed=BoundGBAMemorySnapshot(copyingWorkRAM:work,internalRAM:Data(snapshot.internalRAM))!
  observed.followerObservation = .init(cache:cache,scope:scope)
  return BoundPlayerSceneDecoder.read(player:player,memory:observed,rom:romBytes,assets:BoundPlayerSceneAssets())?.follower
 }
 let work=Data(snapshot.workRAM)
 guard let live=sceneFollower(work,scope) else {fatalError("Actual scene cache did not prime")}
 var odd=work
 let old=(0..<4).reduce(UInt32(0)) {$0|UInt32(work[0x2008+$1])<<(8*$1)}
 for n in 0..<4 {odd[0x2008+n]=UInt8(truncatingIfNeeded:(old&+1)>>(8*n))}
 // Deliberately torn selected fields must not replace the committed choice.
 odd[0x2068]=255;odd[0x206C]=99
 for _ in 0..<3 {assert(sceneFollower(odd,scope)==live)}
 assert(sceneFollower(odd,scope)==nil)
 assert(sceneFollower(work,scope)==live)
 var off=odd;off[0x3B25E]&=0xDF
 assert(sceneFollower(off,scope)==nil);assert(sceneFollower(odd,scope)==nil)
 assert(sceneFollower(work,scope)==live)
 assert(sceneFollower(odd,.init(core:scope.core,profile:scope.profile,timeline:2))==nil)
 report["syntheticInterruptedSceneChecks"]=["3oddretainActualFollower","4thOddDrops","nativeOffRevokesImmediately","loadTimelineRevokes"]
}
if let follower,let native=player.scene?.follower {
 report["follower"]=["identity":String(follower.identity,radix:16),"species":follower.species,"selectedSlot":binding!.partySlot,
 "object":follower.objectID,"generation":follower.generation,"frame":follower.frameAddress,"size":[follower.width,follower.height],
 "current":[follower.current.x,follower.current.y],"previous":[follower.previous.x,follower.previous.y],"foot":[follower.x,follower.y],
 "tileSHA256":digest(native.appearance.tiles),"paletteSHA256":digest(native.appearance.palette),"wireBytes":try JSONEncoder().encode(follower).count]
}
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:REPORT_PATH))
print("Actual native follower snapshot PASS",enabled,expected)
'''.replace('ROM_PATH',json.dumps(str(a.rom.resolve()))).replace('STATE_PATH',json.dumps(str(a.state.resolve()))).replace('REPORT_PATH',json.dumps(str((a.output/'native-source.json').resolve())))
a.output.mkdir(parents=True,exist_ok=True);main=a.output/'main.swift';main.write_text(source)
platform=Path(subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-platform-path'],text=True).strip())
frameworks,libraries=str(platform/'Developer/Library/Frameworks'),str(platform/'Developer/usr/lib')
subprocess.run(['swiftc','-I',libraries,'-F',frameworks,'-L',libraries,'-lXCTestSwiftSupport',
    '-Xlinker','-rpath','-Xlinker',libraries,'-Xlinker','-rpath','-Xlinker',frameworks,
    '-module-cache-path',str(a.output/'ModuleCache'),str(main),'-o',str(a.output/'follower-tests')],check=True)
subprocess.run([str(a.output/'follower-tests')],check=True)

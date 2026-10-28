#!/usr/bin/env python3
"""Compile actual read-only friend route policy and exercise native layouts."""
import argparse
from pathlib import Path
import subprocess
import json
import hashlib
import zlib

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--rom', type=Path)
p.add_argument('--state', type=Path)
a = p.parse_args()
if bool(a.rom) != bool(a.state):
    raise ValueError('Supply both exact ROM and fresh owned native state')
if a.rom:
    image, raw = a.rom.read_bytes(), a.state.read_bytes()
    assert len(image) == 0x2000000 and len(raw) == 0x61000
    assert int.from_bytes(raw[8:12], 'little') == zlib.crc32(image), 'State does not match exact ROM'
root = Path(__file__).resolve().parents[1]
a.output.mkdir(parents=True, exist_ok=True)
source = '''import Foundation
enum BoundPlayerMapConnections { struct Map: Hashable, Sendable { let group:Int; let number:Int } }
struct BoundPlayerState { struct Point: Equatable, Sendable { let x:Int; let y:Int } }
struct BoundGBAMemorySnapshot { let memory:[Int:UInt8]
func bytes(at address:Int,count:Int)->[UInt8]? { var result:[UInt8]=[]; for i in 0..<count { guard let byte=memory[address+i] else{return nil};result.append(byte) };return result }
}
'''
source += (root / 'Delta/Bound/BoundFriendRouteAccess.swift').read_text()
# Instrument unsupported handlers only in this standalone audit executable;
# product evaluation and control flow remain the actual owning source.
source = 'var unsupportedRouteOpcodes: [Int:Int] = [:]\n' + source
needle = '''guard let opcode = rom(pc, 1)?.first, let expected = handlers[Int(opcode)],
                  let handler = rom(0x0815F9B4 + Int(opcode) * 4, 4), Self.word(handler) == expected else { return false }'''
replacement = '''guard let opcode = rom(pc, 1)?.first else { return false }
            guard let expected = handlers[Int(opcode)],
                  let handler = rom(0x0815F9B4 + Int(opcode) * 4, 4), Self.word(handler) == expected else {
                unsupportedRouteOpcodes[Int(opcode), default: 0] += 1; return false
            }'''
assert needle in source
source = source.replace(needle, replacement)
source += r'''
var storage:[Int:UInt8]=[:]
func put(_ address:Int,_ value:Int,_ count:Int=4) { for i in 0..<count { storage[address+i]=UInt8(truncatingIfNeeded:value>>(8*i)) } }
func fill(_ address:Int,_ count:Int) { for i in 0..<count {storage[address+i]=0} }
func read(_ address:Int,_ count:Int)->[UInt8]? { guard count>=0,count<100000 else{return nil}; var result:[UInt8]=[];for i in 0..<count{guard let byte=storage[address+i] else{return nil};result.append(byte)};return result }
let m0=BoundPlayerMapConnections.Map(group:0,number:0),m1=BoundPlayerMapConnections.Map(group:0,number:1)
let table=0x08001000,primary=0x08008000,secondary=0x08008100,attributes=0x08009000
put(0x083526A8,table); fill(primary,24);fill(secondary,24);put(primary+20,attributes);put(secondary+20,attributes);fill(attributes,1024*4)
for n in 0..<2 {let h=0x08002000+n*0x1000,l=h+0x100,e=h+0x200,g=h+0x300
    put(table+n*4,h);fill(h,28);fill(l,24);fill(e,20);put(h,l);put(h+4,e)
    put(l,5);put(l+4,5);put(l+12,g);put(l+16,primary);put(l+20,secondary)
    for i in 0..<25 {put(g+i*2,i/5==2 ? 0:0xC00,2)}
}
var flags=[UInt8](repeating:0,count:0x120)
func access(_ flags:[UInt8],objects:[BoundFriendRouteAccess.Object]=[],gridOverride:[Int:Int]=[:],templates:[UInt8]=Array(repeating:0,count:1536))->BoundFriendRouteAccess {
    var grid=[UInt16](repeating:0xC00,count:20*19)
    for i in 0..<25 {grid[(i/5+7)*20+i%5+7]=i/5==2 ? 0:0xC00}
    for (index,value) in gridOverride {grid[(index/5+7)*20+index%5+7]=UInt16(value)}
    return .init(currentMap:m0,flags:flags,expandedFlags:Array(repeating:0,count:512),variables:Array(repeating:0,count:512),expandedVariables:Array(repeating:0,count:1024),specialVariables:Array(repeating:0,count:40),specialFlags:[0],gridWidth:20,gridHeight:19,grid:grid,templates:templates,objects:objects)
}
let start=BoundPlayerState.Point(x:0,y:2),goal=BoundPlayerState.Point(x:4,y:2)
func reaches(_ a:BoundFriendRouteAccess,_ map:BoundPlayerMapConnections.Map=m0)->Bool { guard let map=a.map(map,rom:read) else{return false};return map.canReachTarget(goal,reachable:map.reachable(from:start)) }
assert(reaches(access(flags)),"native open corridor")
assert(!reaches(access(flags,gridOverride:[12:0xC00])),"live map changes override ROM collision")
let object=BoundFriendRouteAccess.Object(localID:1,map:m0,tile:.init(x:2,y:2),previous:.init(x:1,y:2),elevation:0)
assert(!reaches(access(flags,objects:[object])),"active native objects block current and previous tiles")
assert(access(flags).hasSameProgression(as:access(flags,objects:[object])),"moving occupancy excluded from progression invalidation")
assert(!access(flags).hasSameProgression(as:access(flags,gridOverride:[12:0xC00])),"native grid immediately invalidates progression")
let script=0x08006000,end=script+0x40
for (op,handler) in [0x02:0x08069ED9,0x06:0x08069FED,0x2B:0x0806A855,0xA2:0x0806C555] {put(0x0815F9B4+op*4,handler)}
put(script,0x2B,1);put(script+1,0x81,2);put(script+3,0x06,1);put(script+4,1,1);put(script+5,end);put(script+9,0x23,1);put(end,0x02,1)
let events=0x08002200,coords=0x08007000
put(events+2,1,1);put(events+12,coords);fill(coords,16);put(coords,2,2);put(coords+2,2,2);put(coords+12,script)
assert(!reaches(access(flags)),"unresolved active story script cannot be traversed")
flags[0x81/8] |= 1 << (0x81&7)
assert(reaches(access(flags)),"native flag condition unlocks story path")
put(0x0815F9B4+0x2B*4,0x09000001)
assert(!reaches(access(flags)),"replaced RR handler cannot borrow vanilla opcode semantics")
put(0x0815F9B4+0x2B*4,0x0806A855)
// Remote ON_LOAD script uses the same flag, then modifies the native tile.
let remoteHeader=0x08003000,loadTable=0x08007500,load=0x08007600,loadEnd=load+0x40
put(remoteHeader+8,loadTable);put(loadTable,1,1);put(loadTable+1,load);put(loadTable+5,0,1)
put(load,0x2B,1);put(load+1,0x82,2);put(load+3,0x06,1);put(load+4,1,1);put(load+5,loadEnd)
put(load+9,0xA2,1);put(load+10,2,2);put(load+12,2,2);put(load+14,0,2);put(load+16,1,2);put(load+18,0x02,1);put(loadEnd,0x02,1)
assert(!reaches(access(flags),m1),"remote on-load metatile story gate is applied")
flags[0x82/8] |= 1 << (0x82&7)
assert(reaches(access(flags),m1),"native unlock selects alternate on-load branch")
put(load+9,0x25,1)
flags[0x82/8] &= ~(1 << (0x82&7))
assert(access(flags).map(m1,rom:read)==nil,"unknown on-load special withholds inaccessible route")
// Only the proved no-card branch of the exact native validator is modeled.
put(0x0815F9B4+0x26*4,0x08069F3D);put(0x0815FD60+0x180*4,0x08143FC9)
put(load,0x26,1);put(load+1,0x800D,2);put(load+3,0x180,2);put(load+5,0x02,1)
var noCard=access(flags);noCard.wonderCardFlagID=0
assert(noCard.map(m1,rom:read) != nil,"verified empty WonderCard native branch permits ordinary loader")
noCard.wonderCardFlagID=1
assert(noCard.map(m1,rom:read)==nil,"real card validation is unknown rather than assumed invalid")
// Native templates use flag visibility and remain collision objects offscreen.
put(events+2,0,1);put(events,1,1)
var templates=[UInt8](repeating:0,count:1536)
templates[0]=1;templates[4]=2;templates[6]=2;templates[22]=0x83
assert(!reaches(access(flags,templates:templates)),"visible story NPC blocks route")
flags[0x83/8] |= 1 << (0x83&7)
assert(reaches(access(flags,templates:templates)),"native hide flag removes blocker")
// A door can be entered northward even with its native collision bits set.
put(events,0,1);put(attributes+4,0x69)
let doorway=access(flags,gridOverride:[9:0xC01]).map(m0,rom:read)!
assert(doorway.canReachTarget(.init(x:4,y:1),reachable:doorway.reachable(from:start),doorway:true))
assert(!doorway.canReachTarget(.init(x:3,y:1),reachable:doorway.reachable(from:start),doorway:true),"adjacent walls never become doors")
assert(access(flags).flag(0x1900,on:m0)==nil,"unknown flag sentinel not guessed")
assert(access(flags).variable(0x4000,on:m1)==nil,"scene variables cannot leak into another map")
let zeroFlag=0x08007A00,zeroDanger=zeroFlag+0x40
put(0x0815F9B4+0x29*4,0x0806A82D)
put(zeroFlag,0x29,1);put(zeroFlag+1,0,2);put(zeroFlag+3,0x2B,1);put(zeroFlag+4,0,2)
put(zeroFlag+6,0x06,1);put(zeroFlag+7,1,1);put(zeroFlag+8,zeroDanger);put(zeroFlag+12,0x02,1);put(zeroDanger,0x25,1)
assert(access(flags).scriptAllowsPassage(zeroFlag,on:m0,rom:read),"native FlagSet0 cannot turn null flag true in dry projection")
// Native warp events can also be script-only arrival coordinates on normal
// floor. They must neither offer a departure nor stop the walking flood.
let warpRows=0x08007B00
put(events+1,1,1);put(events+8,warpRows);fill(warpRows,8);put(warpRows,2,2);put(warpRows+2,2,2)
let dormant=access(flags).map(m0,rom:read)!
assert(!dormant.hasWarp(at:.init(x:2,y:2)) && reaches(access(flags)),"ordinary-floor event is not an active warp or walking barrier")
put(attributes,0x61)
let ladder=access(flags).map(m0,rom:read)!
assert(ladder.hasWarp(at:.init(x:2,y:2)) && !reaches(access(flags)),"active ladder stops the flood at the actual transition")
put(attributes,0);put(events+1,0,1)
// Directional ledges jump two tiles. The opposite approach cannot walk through
// their collision, and an invalid landing never becomes a route shortcut.
for (dx,dy,behavior) in [(1,0,0x38),(-1,0,0x39),(0,-1,0x3A),(0,1,0x3B)] {
    let origin=BoundPlayerState.Point(x:2-dx,y:2-dy),landing=BoundPlayerState.Point(x:2+dx,y:2+dy)
    var cells=[UInt16](repeating:0xC00,count:25),behaviors=[UInt8](repeating:0,count:25)
    cells[origin.y*5+origin.x]=0;cells[landing.y*5+landing.x]=0;behaviors[12]=UInt8(behavior)
    let jump=BoundFriendRouteAccess.MapAccess(width:5,height:5,cells:cells,behaviors:behaviors,objects:[],blockedScripts:[],warps:[])
    assert(jump.walkingDistance(to:landing,distances:jump.walkingDistances(from:origin))==2,"ledge has two-tile directional walking cost")
    assert(jump.walkingDistance(to:origin,distances:jump.walkingDistances(from:landing))==nil,"ledge cannot be climbed backward")
    cells[landing.y*5+landing.x]=0xC00
    let blocked=BoundFriendRouteAccess.MapAccess(width:5,height:5,cells:cells,behaviors:behaviors,objects:[],blockedScripts:[],warps:[])
    assert(blocked.walkingDistance(to:landing,distances:blocked.walkingDistances(from:origin))==nil,"blocked ledge landing stays unavailable")
}
let edgeWall=BoundFriendRouteAccess.MapAccess(width:1,height:1,cells:[0],behaviors:[0x30],objects:[],blockedScripts:[],warps:[])
assert(edgeWall.walkingDistance(to:.init(x:1,y:0),distances:[0:0])==nil,"seam respects directional wall on departure")
assert(!edgeWall.canEnter(.init(x:0,y:0),elevation:0,direction:3),"seam respects directional wall on arrival")
let edgeWater=BoundFriendRouteAccess.MapAccess(width:1,height:1,cells:[0],behaviors:[0x10],objects:[],blockedScripts:[],warps:[])
assert(!edgeWater.canEnter(.init(x:0,y:0),elevation:0,direction:1),"seam cannot seed an ordinary walk in water")
var doorCells=[UInt16](repeating:0,count:9),doorBehaviors=[UInt8](repeating:0,count:9)
doorCells[4]=0xC00;doorBehaviors[4]=0x69
let exitDoor=BoundFriendRouteAccess.MapAccess(width:3,height:3,cells:doorCells,behaviors:doorBehaviors,objects:[],blockedScripts:[],warps:[4])
assert(exitDoor.warpArrival(at:.init(x:1,y:1)) == .init(x:1,y:2),"animated door arrives south after native exit animation")
doorBehaviors[4]=0x60
let caveDoor=BoundFriendRouteAccess.MapAccess(width:3,height:3,cells:doorCells,behaviors:doorBehaviors,objects:[],blockedScripts:[],warps:[4])
assert(caveDoor.warpArrival(at:.init(x:1,y:1)) == .init(x:1,y:2),"nonanimated cave door restores south facing and exits south")
doorCells[7]=0xC00
let blockedExit=BoundFriendRouteAccess.MapAccess(width:3,height:3,cells:doorCells,behaviors:doorBehaviors,objects:[],blockedScripts:[],warps:[4])
assert(blockedExit.warpArrival(at:.init(x:1,y:1))==nil,"blocked door exit cannot seed a sideward flood")
let raisedWarp=BoundFriendRouteAccess.MapAccess(width:1,height:1,cells:[0x3000],behaviors:[0x61],objects:[],blockedScripts:[],warps:[0])
assert(raisedWarp.warpDistance(to:.init(x:0,y:0),distances:[0:0],elevation:3,eventElevation:3)==0,"warp event matches its native endpoint elevation")
assert(raisedWarp.warpDistance(to:.init(x:0,y:0),distances:[0:0],elevation:3,eventElevation:4)==nil,"warp event on another layer cannot activate")
let carriedWarp=BoundFriendRouteAccess.MapAccess(width:1,height:1,cells:[0xF000],behaviors:[0x61],objects:[],blockedScripts:[],warps:[0])
assert(carriedWarp.warpDistance(to:.init(x:0,y:0),distances:[0:0],elevation:3,eventElevation:3)==0,"bridge warp retains proved carried elevation")
assert(carriedWarp.warpDistance(to:.init(x:0,y:0),distances:[0:0],elevation:0,eventElevation:3)==nil,"unknown carried elevation never guesses a matching warp layer")
let elevatedDoor=BoundFriendRouteAccess.MapAccess(width:1,height:2,cells:[0x3C00,0x4000],behaviors:[0x69,0],objects:[],blockedScripts:[],warps:[0])
assert(elevatedDoor.warpDistance(to:.init(x:0,y:0),distances:[1:0],elevation:4,eventElevation:3)==nil,"door event checks the player's adjacent layer before entry")
assert(elevatedDoor.warpDistance(to:.init(x:0,y:0),distances:[1:0],elevation:4,eventElevation:4)==1,"door activation retains the matching adjacent layer")
put(0x0815F9B4+0x65*4,0x0806B629)
put(load,0x65,1);put(load+1,1,2);put(load+3,7,1);put(load+4,0x02,1)
assert(access(flags).map(m1,rom:read) != nil,"exact stationary-facing template command preserves collision position")
put(load+3,0,1)
assert(access(flags).map(m1,rom:read)==nil,"unmodeled moving template command stays unknown")
print("PASS: native flags/grids/objects, predicates, handler identity, script gates, dormant warps, directed ledges, seam boundaries and native door arrivals")
'''
if a.rom:
    source += r'''
let nativeROM=Array(try Data(contentsOf:URL(fileURLWithPath:ROM_PATH)))
let nativeState=Array(try Data(contentsOf:URL(fileURLWithPath:STATE_PATH)))
func nativeROMRead(_ address:Int,_ count:Int)->[UInt8]? { let offset=address-0x08000000;guard offset>=0,count>=0,offset<=nativeROM.count,count<=nativeROM.count-offset else{return nil};return Array(nativeROM[offset..<offset+count]) }
var ram:[Int:UInt8]=[:]
for i in 0..<0x40000 {ram[0x02000000+i]=nativeState[0x21000+i]}
for i in 0..<0x8000 {ram[0x03000000+i]=nativeState[0x19000+i]}
let nativeMemory=BoundGBAMemorySnapshot(memory:ram)
func h(_ a:[UInt8],_ i:Int=0)->Int {Int(a[i])|Int(a[i+1])<<8}
func w(_ a:[UInt8],_ i:Int=0)->Int {h(a,i)|h(a,i+2)<<16}
let save=w(nativeMemory.bytes(at:0x03005008,count:4)!),saved=nativeMemory.bytes(at:save,count:12)!
let nativeMap=BoundPlayerMapConnections.Map(group:Int(saved[4]),number:Int(saved[5]))
let nativeAccess=BoundFriendRouteAccess.capture(memory:nativeMemory,save:save,currentMap:nativeMap,rom:nativeROMRead)!
let nativeHere=nativeAccess.map(nativeMap,rom:nativeROMRead)
assert(nativeHere != nil,"Actual current native map must be routable")
let nativeTile=BoundPlayerState.Point(x:h(saved),y:h(saved,2))
let nativeReach=nativeHere!.reachable(from:nativeTile)
var actualGate:[String:Any]=[:]
if nativeMap.group==4 && nativeMap.number==3 {
    func labAccess(_ scene:Int)->BoundFriendRouteAccess {
        var vars=nativeAccess.variables; vars[(0x4055-0x4000)*2]=UInt8(scene);vars[(0x4055-0x4000)*2+1]=0
        return .init(currentMap:nativeAccess.currentMap,flags:nativeAccess.flags,expandedFlags:nativeAccess.expandedFlags,
          variables:vars,expandedVariables:nativeAccess.expandedVariables,specialVariables:nativeAccess.specialVariables,
          specialFlags:nativeAccess.specialFlags,gridWidth:nativeAccess.gridWidth,gridHeight:nativeAccess.gridHeight,
          grid:nativeAccess.grid,templates:nativeAccess.templates,objects:nativeAccess.objects)
    }
    let locked=labAccess(2).map(nativeMap,rom:nativeROMRead)!,unlocked=labAccess(4).map(nativeMap,rom:nativeROMRead)!
    let eventTile=8*locked.width+6
    assert(locked.blockedScripts.contains(eventTile),"Actual Oak lab startup scene2 blocks its active native coordinate script")
    assert(!unlocked.blockedScripts.contains(eventTile),"Actual Oak lab completed scene4 has no active coordinate gate")
    let destination=BoundPlayerState.Point(x:6,y:7)
    let lockedReach=locked.reachable(from:nativeTile),unlockedReach=unlocked.reachable(from:nativeTile)
    assert(!locked.canReachTarget(destination,reachable:lockedReach),"Actual tutorial barrier cannot be crossed as ordinary walking")
    assert(unlocked.canReachTarget(destination,reachable:unlockedReach),"Actual lab corridor opens after native scene milestone")
    actualGate=["map":[4,3],"variable":"0x4055","lockedValue":2,"unlockedValue":4,"coordinateScript":"0x081692C3",
      "nativeTile":[6,8],"target":[6,7],"lockedReachable":lockedReach.count,"unlockedReachable":unlockedReach.count,
      "provenance":"hypothetical local scene values applied to immutable native QA snapshot; no gameplay mutation"]
}
var total=0,eligible=0,eligibleMaps:[[Int]]=[],unsupportedMaps:[[Int]]=[]
var cardUnknown=nativeAccess;cardUnknown.wonderCardFlagID=1
var noCardSpecificMaps:[[Int]]=[]
unsupportedRouteOpcodes=[:]
let groupStarts=(0..<43).map { w(nativeROMRead(0x083526A8+$0*4,4)!) }+[0x083526A8]
for group in 0..<43 {
    let base=groupStarts[group],end=groupStarts.filter{$0>base}.min() ?? base+256*4
    for number in 0..<min(256,max(0,(end-base)/4)) {
        guard let p=nativeROMRead(base+number*4,4),let header=nativeROMRead(w(p),28),let layout=nativeROMRead(w(header),24),
              (1...1024).contains(w(layout)),(1...1024).contains(w(layout,4)),nativeROMRead(w(header,4),20) != nil else{break}
        total+=1
        if nativeAccess.map(.init(group:group,number:number),rom:nativeROMRead) != nil {
            eligible+=1;eligibleMaps.append([group,number])
            let histogram=unsupportedRouteOpcodes
            if cardUnknown.map(.init(group:group,number:number),rom:nativeROMRead)==nil {noCardSpecificMaps.append([group,number])}
            unsupportedRouteOpcodes=histogram
        }
        else {unsupportedMaps.append([group,number])}
    }
}
let report:[String:Any]=["romSHA256":ROM_HASH,"stateSHA256":STATE_HASH,"currentMap":[nativeMap.group,nativeMap.number],
 "currentTile":[nativeTile.x,nativeTile.y],"currentReachableTiles":nativeReach.count,"nativeMapCount":total,"eligibleMapCount":eligible,
 "eligibleMaps":eligibleMaps,"unsupportedMaps":unsupportedMaps,"actualGate":actualGate,
 "nativeWonderCardFlagID":nativeAccess.wonderCardFlagID as Any,"provenNoCardSpecificMaps":noCardSpecificMaps,
 "unsupportedOpcodeHistogram":Dictionary(uniqueKeysWithValues:unsupportedRouteOpcodes.map{(String(format:"0x%02X",$0.key),$0.value)}),
 "stateProvenance":"owned exact-ROM native QA fixture; hypothetical future-map scripts projected read-only"]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:REPORT_PATH))
print("Actual ROM native state maps supported",eligible,"of",total,"current reachable",nativeReach.count)
'''.replace('ROM_PATH',json.dumps(str(a.rom.resolve()))).replace('STATE_PATH',json.dumps(str(a.state.resolve()))).replace('ROM_HASH',json.dumps(hashlib.sha256(image).hexdigest())).replace('STATE_HASH',json.dumps(hashlib.sha256(raw).hexdigest())).replace('REPORT_PATH',json.dumps(str((a.output/'native-route-access.json').resolve())))
swift = a.output / 'friend-route-access.swift'
binary = a.output / 'friend-route-access'
swift.write_text(source)
subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(a.output / 'SwiftModuleCache'), str(swift), '-o', str(binary)], check=True)
subprocess.run([str(binary)], check=True)

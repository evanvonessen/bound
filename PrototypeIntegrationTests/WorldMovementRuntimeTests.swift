import XCTest
import UIKit
import SwiftUI
import CryptoKit
import DeltaCore
import GBADeltaCore
@testable import Delta

private struct MovementRuntimeGame:GameProtocol {
    let fileURL:URL,gameSaveURL:URL
    var type:GameType { .gba }
}

/// Optional read-only diagnostics for the known center-screen paved-road tape.
/// Keep eight tiny trainer templates and one sparse background sample, never a
/// video history. Ambiguous matches remain diagnostics and cannot prove motion.
private final class MovementCadencePixelDiagnostics {
    private struct Pixel {let x:Int,y:Int,r:Int,g:Int,b:Int}
    private struct Template {let appearance:BoundPlayerSprite,pixels:[Pixel]}
    private var templates=[Template](),previousStrips=[[UInt32]]()
    private let stripRows=[12,20,28,36,104,112,120,128]
    func reset(){templates=[];previousStrips=[]}
    func observe(_ core:EmulatorCore,reading:BoundPlayerStateReading)->[String:Any] {
        let started=ProcessInfo.processInfo.systemUptime
        guard let buffer=core.deltaCore.emulatorBridge.videoRenderer?.videoBuffer else{return ["bufferAvailable":false]}
        var output:[String:Any]=["bufferAvailable":true]
        if let avatar=core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x37078,size:8),avatar.count==8,avatar[4]<64,
           let data=core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x2063C+Int(avatar[4])*68,size:68),data.count==68,
           let offset=core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x21BC8,size:4),offset.count==4 {
            let raw=Array(data),cameraOffset=Array(offset),a0=BoundSceneBytes.half(raw),a1=BoundSceneBytes.half(raw,2)
            let x=(a1&511)+8,y=(a0&255)+32
            output["spriteID"]=Int(avatar[4]);output["builtAttr0"]=a0;output["builtAttr1"]=a1
            output["builtOAMFootX"]=x&511;output["builtOAMFootY"]=y&255
            output["liveFootX"]=BoundSceneBytes.wrap(BoundSceneBytes.signed(raw,0x20)+BoundSceneBytes.signed(raw,0x24)+BoundSceneBytes.signed(cameraOffset))
            output["liveFootY"]=BoundSceneBytes.wrap(BoundSceneBytes.signed(raw,0x22)+BoundSceneBytes.signed(raw,0x26)+BoundSceneBytes.signed(cameraOffset,2))+16
            output["spritePos1X"]=BoundSceneBytes.signed(raw,0x20);output["spritePos1Y"]=BoundSceneBytes.signed(raw,0x22)
            output["spriteCoordOffsetX"]=BoundSceneBytes.signed(cameraOffset);output["spriteCoordOffsetY"]=BoundSceneBytes.signed(cameraOffset,2)
        }
        if let camera=core.deltaCore.emulatorBridge.readMemory?(at:0xE90,size:12),camera.count==12,
           let applied=core.deltaCore.emulatorBridge.readMemory?(at:0x14,size:4),applied.count==4 {
            let raw=Array(camera),shadow=Array(applied)
            output["fieldCameraOffsetX"]=Int(raw[0]);output["fieldCameraOffsetY"]=Int(raw[1])
            output["cameraPanX"]=BoundSceneBytes.signed(raw,8);output["cameraPanY"]=BoundSceneBytes.signed(raw,10)
            output["desiredScrollX"]=Int(raw[0])+BoundSceneBytes.signed(raw,8)
            output["desiredScrollY"]=Int(raw[1])+BoundSceneBytes.signed(raw,10)+8
            output["appliedBG1ScrollX"]=BoundSceneBytes.half(shadow);output["appliedBG1ScrollY"]=BoundSceneBytes.half(shadow,2)
        }
        if let appearance=reading.player?.scene?.appearance,appearance.width==16,appearance.height==32,
           !templates.contains(where:{$0.appearance==appearance}) {
            var pixels=[Pixel]()
            for y in 0..<24 {for x in 0..<16 {
                let color=appearance.colorIndex(x:x,y:y);guard color != 0 else{continue}
                let word=Int(appearance.palette[color*2])|Int(appearance.palette[color*2+1])<<8
                pixels.append(.init(x:x,y:y,r:(word&31)*255/31,g:((word>>5)&31)*255/31,b:((word>>10)&31)*255/31))
            }}
            if pixels.count>=40 {templates.append(.init(appearance:appearance,pixels:pixels));if templates.count>8 {templates.removeFirst()}}
        }
        // This fixture's native trainer foot is near (120,88). Do not infer a
        // location outside this explicitly bounded, visible road search window.
        var scores=[(x:Int,y:Int,score:Double,template:Int)]()
        for x in 112...128 {
            let y=88
            var best=(score:0.0,template:0)
            for (index,t) in templates.enumerated() {
                var matched=0
                for p in t.pixels {
                    let at=((y-32+p.y)*240+x-8+p.x)*4
                    if abs(Int(buffer[at+2])-p.r)<=8 && abs(Int(buffer[at+1])-p.g)<=8 && abs(Int(buffer[at])-p.b)<=8 {matched+=1}
                }
                let fraction=Double(matched)/Double(t.pixels.count)
                if fraction>best.score {best=(fraction,index)}
            }
            scores.append((x,y,best.score,best.template))
        }
        scores.sort{$0.score>$1.score}
        if !templates.isEmpty,let best=scores.first,scores.count>1 {
            let second=scores[1],margin=best.score-second.score
            output["trainerTemplate"]=["footX":best.x,"footY":best.y,"matchFraction":best.score,
                "runnerUpFootX":second.x,"runnerUpMatchFraction":second.score,"margin":margin,
                "confident":best.score>=0.8 && margin>=0.05,"templateCount":templates.count,
                "templateROMAddress":templates[best.template].appearance.romAddress ?? 0,
                "search":"footX112...128 footY88, opaque upper24 trainer rows, BGRA RGB tolerance8"] as [String:Any]
        }
        let strips=stripRows.map{y in (0..<240).map{x in let at=(y*240+x)*4;return UInt32(buffer[at])|UInt32(buffer[at+1])<<8|UInt32(buffer[at+2])<<16}}
        if previousStrips.count==strips.count {
            var matches=[(shift:Int,score:Double)]()
            for shift in [-6,-4,-2,0,2,4,6] {
                var equal=0,total=0
                for row in strips.indices {for x in stride(from:16,to:224,by:2) {
                    if strips[row][x]==previousStrips[row][x+shift] {equal+=1};total+=1
                }}
                matches.append((shift,Double(equal)/Double(total)))
            }
            matches.sort{$0.score>$1.score}
            let best=matches[0],second=matches[1],margin=best.score-second.score
            let colors=Set(strips.flatMap{$0}).count
            output["backgroundStrips"]=["previousXMinusCurrentX":best.shift,"matchFraction":best.score,
                "runnerUpShift":second.shift,"runnerUpMatchFraction":second.score,"margin":margin,
                "distinctColors":colors,"confident":best.score>=0.9 && margin>=0.02 && colors>=8,
                "scores":matches.map{["shift":Double($0.shift),"matchFraction":$0.score]},
                "scope":"Sparse native BGRA row correlation; ambiguity, sprites and animated tiles can invalidate inference"] as [String:Any]
        }
        previousStrips=strips;output["workMs"]=(ProcessInfo.processInfo.systemUptime-started)*1000
        return output
    }
}

/// A frame-driven input tape, with observations taken on the real core owner.
/// Each mode restores the same state captured from the exact selected ROM.
/// Synthetic peers occupy a separate row; they must never block this tape.
private final class MovementCadenceTape: @unchecked Sendable {
    private let lock=NSLock()
    private var rows=[[String:Double]](),index=0,lastMask=0,limit=0
    private var videoRows=[[String:Any]]()
    private let pixels=ProcessInfo.processInfo.environment["BOUND_MOVEMENT_PIXEL_DIAGNOSTICS"]=="1" ? MovementCadencePixelDiagnostics():nil
    private var mode="native",anchor=BoundMovementTile(x:0,y:0)
    let probe=BoundMovementProbe()
    let senderProbe=BoundVBAPlayerStateProbe()
    func arm(frames:Int,preRollFrames:Int,mode:String,anchor:BoundMovementTile) {
        lock.lock();defer{lock.unlock()}
        rows=[];rows.reserveCapacity(frames);videoRows=[];videoRows.reserveCapacity(frames)
        pixels?.reset()
        index = -preRollFrames;lastMask=0;limit=frames;self.mode=mode;self.anchor=anchor
    }
    var finished:Bool {lock.lock();defer{lock.unlock()};return limit>0 && index>=limit}
    func result()->[[String:Double]] {lock.lock();defer{lock.unlock()};return rows}
    func videoResult()->[[String:Any]] {lock.lock();defer{lock.unlock()};return videoRows}
    func receiveVideo(_ core:EmulatorCore,_ reading:BoundPlayerStateReading,pixels:Int) {
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock();defer{lock.unlock()}
        guard limit>0,index>=0,index<limit else{return}
        var row:[String:Any]=["frame":Double(videoRows.count),"completedFrameIndex":Double(index),
            "time":now,"input":Double(lastMask),"status":reading.status.rawValue,"detail":reading.detail,
            "overlayPixels":Double(pixels),"safeField":reading.status == .live ? 1.0:0.0]
        if let player=reading.player {
            row["tileX"]=Double(player.tile.x);row["tileY"]=Double(player.tile.y)
            row["previousTileX"]=Double(player.previousTile.x);row["previousTileY"]=Double(player.previousTile.y)
            if let cameraTile=player.cameraTile {row["cameraTileX"]=Double(cameraTile.x);row["cameraTileY"]=Double(cameraTile.y)}
            row["mapGroup"]=Double(player.mapGroup);row["mapNumber"]=Double(player.mapNumber)
            if let scene=player.scene {
                row["pixelX"]=Double(scene.worldFoot.x);row["pixelY"]=Double(scene.worldFoot.y)
                row["cameraX"]=Double(scene.camera.x);row["cameraY"]=Double(scene.camera.y)
            }
        }
        if let diagnostic=self.pixels {row["nativePixelDiagnostic"]=diagnostic.observe(core,reading:reading)}
        videoRows.append(row)
    }
    func receive(_ core:EmulatorCore,profile:BoundPlayerROMProfile,field:Bool) {
        let started=ProcessInfo.processInfo.systemUptime
        lock.lock();defer{lock.unlock()}
        probe.receive(core)
        guard limit>0,index<limit else{return}
        let snapshot=probe.read()
        if mode != "native",let s=snapshot {
            var d=Data(repeating:0,count:1024)
            let put=BoundMovementSnapshot.put
            put(0x31574C42,&d,0);put(1,&d,4);put(2,&d,8);put(1,&d,12);put(15,&d,16)
            put(s.generation,&d,20);put(1,&d,24);put(2,&d,28)
            for at in [32,48] {put(UInt32(truncatingIfNeeded:s.instance),&d,at);put(UInt32(s.instance>>32),&d,at+4)}
            d[64]=UInt8(s.group);d[65]=UInt8(s.number);d[66]=UInt8(s.elevation);put(2,&d,68)
            let dx=mode=="moving" ? (max(0,index)/3)%7-3:0
            for actor in 0..<2 {
                let at=128+actor*32
                let tile=BoundMovementTile(x:anchor.x+dx-actor,y:anchor.y+(mode=="far" ? 40:2))
                put(1,&d,at);BoundMovementSnapshot.putTile(tile,&d,at+4);BoundMovementSnapshot.putTile(tile,&d,at+8)
                d[at+12]=UInt8(s.elevation);d[at+13]=UInt8(actor)
                if actor==1 {put(0x12345678,&d,at+20)}
            }
            probe.publish(d,epoch:probe.epoch(),local:s)
        }
        let senderReading=senderProbe.receive(core)
        // Count native completed frames with all input released. Both shipping
        // probes and the video compositor still run during this deterministic
        // warmup; only measurement and the input tape wait for frame zero.
        if index<0 {index+=1;return}
        var row:[String:Double]=["frame":Double(index),"time":started,"input":Double(lastMask),"safeField":field ? 1:0]
        if let s=snapshot {
            row["guestFrame"]=Double(s.frame);row["guestFlags"]=Double(s.flags)
            row["mapGroup"]=Double(s.group);row["mapNumber"]=Double(s.number)
            row["tileX"]=Double(s.current.x);row["tileY"]=Double(s.current.y)
            row["previousTileX"]=Double(s.previous.x);row["previousTileY"]=Double(s.previous.y)
        }
        if let memory=BoundGBAMemorySnapshot.capture(readMemory:{core.deltaCore.emulatorBridge.readMemory?(at:$0,size:$1)}) {
            row["followerActive"]=(memory.workRAM[0x3B25E]&0x20 != 0 && memory.workRAM[0x3B818]==1) ? 1:0
        }
        if let reading=senderReading {
            row["senderLive"]=reading.status == .live ? 1:0
            row["senderScene"]=reading.player?.scene == nil ? 0:1
            if let scene=reading.player?.scene {
                row["pixelX"]=Double(scene.worldFoot.x);row["pixelY"]=Double(scene.worldFoot.y)
                row["cameraX"]=Double(scene.camera.x);row["cameraY"]=Double(scene.camera.y)
            }
        }
        row["probeMs"]=(ProcessInfo.processInfo.systemUptime-started)*1000;rows.append(row)
        // A short straight paved-road loop avoids walls, grass and natural NPCs.
        // Retain the historical 32-frame run / 8-frame release input pattern.
        let phase=index%80,mask=phase%40<32 ? (phase<40 ? 32:16)|2:0
        for bit in [2,16,32] where mask&bit != lastMask&bit {
            if mask&bit != 0 {core.deltaCore.emulatorBridge.activateInput(bit,value:1,playerIndex:0)}
            else {core.deltaCore.emulatorBridge.deactivateInput(bit,playerIndex:0)}
        }
        lastMask=mask;index+=1
        if index==limit {for bit in [2,16,32] {core.deltaCore.emulatorBridge.deactivateInput(bit,playerIndex:0)}}
    }
    static func metrics(_ rows:[[String:Double]])->[String:Any] {
        let pairs=Array(zip(rows,rows.dropFirst()))
        let gaps=pairs.map{($1["time"]!-$0["time"]!)*1000}.sorted()
        func percentile(_ values:[Double],_ fraction:Double)->Double {values.isEmpty ? 0:values[Int(Double(values.count-1)*fraction)]}
        var changes=[Int](),pixelHolds=[Int](),held=0,guestHolds=[Int](),guestHeld=0
        var movingInHeldDirection=false,measuredPixelPairs=0,backward=0
        for (a,b) in pairs {
            if a["tileX"] != b["tileX"] || a["tileY"] != b["tileY"] {changes.append(Int(b["frame"]!))}
            if a["guestFrame"]==b["guestFrame"] {guestHeld+=1} else {guestHolds.append(guestHeld);guestHeld=0}
            let stableInput=a["input"]==b["input"] && (Int(b["input"]!)&48 != 0)
            // Ignore intentional releases and direction-change startup. Begin
            // counting only after real pixel motion under the new held input.
            if stableInput,let x=a["pixelX"],let y=a["pixelY"],let bx=b["pixelX"],let by=b["pixelY"] {
                if x != bx || y != by {
                    let delta=(bx-x)*(Int(b["input"]!)&32 != 0 ? -1:1)
                    if movingInHeldDirection && delta<0 {backward+=1}
                    if delta>0 {movingInHeldDirection=true};pixelHolds.append(held);held=0
                }
                else if movingInHeldDirection {held+=1}
                if movingInHeldDirection {measuredPixelPairs+=1}
            } else {movingInHeldDirection=false;pixelHolds.append(held);held=0}
        }
        pixelHolds.append(held);guestHolds.append(guestHeld)
        let steps=zip(changes,changes.dropFirst()).map{$1-$0}
        let stepHistogram=Dictionary(grouping:steps,by:{$0}).map{["frames":$0.key,"count":$0.value.count]}.sorted{$0["frames"]!<$1["frames"]!}
        let probe=rows.compactMap{$0["probeMs"]}.sorted()
        return ["frames":rows.count,"tileTransitions":changes.count,"stepFrameHistogram":stepHistogram,
                "longestHeldInputPixelFreeze":pixelHolds.max() ?? 0,"longestGuestFrameFreeze":guestHolds.max() ?? 0,
                "heldMotionPairs":measuredPixelPairs,"pixelFreezeHistogram":Dictionary(grouping:pixelHolds.filter{$0>0},by:{$0}).map{["frames":$0.key,"count":$0.value.count]}.sorted{$0["frames"]!<$1["frames"]!},
                "missingPixelSamples":rows.filter{$0["pixelX"]==nil}.count,
                "backwardStepsAfterMotionBegan":backward,
                "activeFollowerSamples":rows.filter{$0["followerActive"]==1}.count,
                "fieldSamples":rows.filter{$0["safeField"]==1}.count,
                "admittedPortSamples":rows.filter{Int($0["guestFlags"] ?? 0)&6==6}.count,
                "remoteBlockedSamples":rows.filter{Int($0["guestFlags"] ?? 0)&(32|64) != 0}.count,
                "meanGapMs":gaps.isEmpty ? 0:gaps.reduce(0,+)/Double(gaps.count),
                "p95GapMs":percentile(gaps,0.95),"p99GapMs":percentile(gaps,0.99),"maxGapMs":gaps.last ?? 0,
                "over50ms":gaps.filter{$0>50}.count,"p99ProbeMs":percentile(probe,0.99)]
    }
    static func videoMetrics(_ rows:[[String:Any]])->[String:Any] {
        let numeric=rows.map{$0.compactMapValues{$0 as? Double}}
        var result=metrics(numeric)
        for key in ["longestGuestFrameFreeze","activeFollowerSamples","admittedPortSamples","remoteBlockedSamples","p99ProbeMs"] {result.removeValue(forKey:key)}
        var deltas=[Int](),backward=0,moving=false
        for (a,b) in zip(numeric,numeric.dropFirst()) {
            guard a["input"]==b["input"],let mask=b["input"],Int(mask)&48 != 0,
                  let x=a["pixelX"],let bx=b["pixelX"] else{moving=false;continue}
            let directional=(bx-x)*(Int(mask)&32 != 0 ? -1:1)
            if directional>0 {moving=true}
            if moving {deltas.append(Int(directional));if directional<0 {backward+=1}}
        }
        result["heldMotionDeltaHistogram"]=Dictionary(grouping:deltas,by:{$0}).map{["pixels":$0.key,"count":$0.value.count]}.sorted{$0["pixels"]!<$1["pixels"]!}
        result["backwardStepsAfterMotionBegan"]=backward
        result["overlayPixelSamples"]=numeric.filter{($0["overlayPixels"] ?? 0)>0}.count
        result["observationBoundary"]="Actual native video processFrame; completed-frame RAM observations are separate diagnostics"
        return result
    }
    static func pixelValidation(_ rows:[[String:Any]])->[String:Int] {
        var result=["videoFrames":rows.count,"trainerChecks":0,"trainerMismatches":0,"nativeCenterMismatches":0,
                    "cameraChecks":0,"cameraMismatches":0]
        for row in rows {
            guard let d=row["nativePixelDiagnostic"] as? [String:Any],let t=d["trainerTemplate"] as? [String:Any],
                  t["confident"] as? Bool == true,let x=t["footX"] as? Int,let y=t["footY"] as? Int,
                  let px=row["pixelX"] as? Double,let py=row["pixelY"] as? Double,
                  let cx=row["cameraX"] as? Double,let cy=row["cameraY"] as? Double else{continue}
            result["trainerChecks",default:0]+=1
            if px+cx != Double(x) || py+cy != Double(y) {result["trainerMismatches",default:0]+=1}
            if x != 120 || y != 88 {result["nativeCenterMismatches",default:0]+=1}
        }
        for (a,b) in zip(rows,rows.dropFirst()) {
            guard let d=b["nativePixelDiagnostic"] as? [String:Any],let background=d["backgroundStrips"] as? [String:Any],
                  background["confident"] as? Bool == true,let shift=background["previousXMinusCurrentX"] as? Int,
                  let ax=a["cameraX"] as? Double,let bx=b["cameraX"] as? Double,
                  let ay=a["cameraY"] as? Double,let by=b["cameraY"] as? Double else{continue}
            result["cameraChecks",default:0]+=1
            if bx-ax != -Double(shift) || by != ay {result["cameraMismatches",default:0]+=1}
        }
        return result
    }
}

extension WorldMovementRuntimeTests {
    /// Set BOUND_MOVEMENT_SMOOTHNESS=1 only on a dedicated simulator, with an
    /// explicit exact ROM/hash. Reports remain in its Documents directory and
    /// XCTest attachments. This is native movement, not phone/WAN acceptance.
    func testRepeatedNativeMovementCadence() async throws {
        let env=ProcessInfo.processInfo.environment
        guard env["BOUND_MOVEMENT_SMOOTHNESS"]=="1" else {throw XCTSkip("Requires explicit isolated movement replay")}
        continueAfterFailure=false
        let rom=URL(fileURLWithPath:try XCTUnwrap(env["BOUND_MOVEMENT_ROM"]))
        let image=try Data(contentsOf:rom),digest=SHA256.hash(data:image).map{String(format:"%02x",$0)}.joined()
        XCTAssertEqual(digest,try XCTUnwrap(env["BOUND_MOVEMENT_SHA256"]))
        let profile=try BoundPlayerROMProfile(rom:image)
        XCTAssertEqual(try MultiRedAdapter(rom:image).profile.romSHA256,digest)
        let frames=Int(env["BOUND_MOVEMENT_FRAMES"] ?? "3600") ?? 0
        let repeats=Int(env["BOUND_MOVEMENT_REPEATS"] ?? "3") ?? 0
        let rates=(env["BOUND_MOVEMENT_RATES"] ?? "1,3").split(separator:",").compactMap{Double($0)}
        let modes=(env["BOUND_MOVEMENT_MODES"] ?? "native,far,near,moving").split(separator:",").map(String.init)
        let phaseValues=(env["BOUND_MOVEMENT_PHASES"] ?? "0").split(separator:",",omittingEmptySubsequences:false)
        let phases=phaseValues.compactMap{Int($0)}
        XCTAssertTrue((160...36000).contains(frames));XCTAssertTrue((1...10).contains(repeats))
        XCTAssertFalse(rates.isEmpty);XCTAssertTrue(rates.allSatisfy{[1.0,3.0].contains($0)})
        XCTAssertFalse(modes.isEmpty);XCTAssertTrue(modes.allSatisfy{["native","far","near","moving"].contains($0)})
        XCTAssertFalse(phases.isEmpty);XCTAssertEqual(phases.count,phaseValues.count)
        XCTAssertTrue(phases.allSatisfy{(0...600).contains($0)})
        let output=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("MovementCadence-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let battery=output.appendingPathComponent("disposable.sav")
        try Data(repeating:255,count:131072).write(to:battery)
        let core=try XCTUnwrap(EmulatorCore(game:MovementRuntimeGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
        var options=BoundMultiplayerSetupOptions()
        options.name="RED";options.gender=0;options.partnerName="BLUE";options.partnerGender=0;options.rival="BLUE"
        options.difficulty=0;options.minimalGrinding=false;options.species=0;options.randomMoves=false;options.randomAbilities=false
        options.cheats=false;options.nicknames=true;options.debug=true;options.deleteSaveOnGameOver=true
        let tape=MovementCadenceTape(),setup=NativePlayerSceneSetup(core:core,debugPlayer:1,
            run:UUID(uuidString:"11111111-2222-3333-4444-555555555555")!,
            localSeed:0x12345678,partnerSeed:0x87654321,settings:options.settings,playerProfile:options.profile)
        let stateProbe=BoundVBAPlayerStateProbe(),videoCompositor=BoundPresenceFrameCompositor()
        stateProbe.configure(coreID:ObjectIdentifier(core),profile:profile,active:true,status:.waiting,detail:"Movement cadence",sceneEnabled:true)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let oldWindow=scene.windows.first(where:\.isKeyWindow),window=UIWindow(windowScene:scene)
        let owner=UIViewController(),view=GameView()
        window.rootViewController=owner;window.windowLevel = .alert+1;window.makeKeyAndVisible()
        view.frame=CGRect(x:0,y:160,width:owner.view.bounds.width,height:owner.view.bounds.width*2/3)
        owner.view.addSubview(view);core.add(view);core.audioManager.isEnabled=false
        defer {
            _=core.pause();videoCompositor.observeFrame=nil;videoCompositor.configure(profile:nil,pose:nil)
            BoundVBABattleBridge.setWorldMovementHost(Data());_=core.stop()
            window.isHidden=true;oldWindow?.makeKeyAndVisible()
        }
        let booted=expectation(description:"Exact-ROM native field ready")
        var ready=false
        core.updateHandler={core in
            BoundFrameMemory.perform {
                setup.receive(core)
                if let reading=stateProbe.receive(core),!ready,setup.isReady,reading.player?.scene != nil {ready=true;booted.fulfill()}
            }
        }
        core.rate=8;XCTAssertTrue(core.start());core.audioManager.isEnabled=false
        await fulfillment(of:[booted],timeout:90);XCTAssertTrue(core.pause())
        let followerRequested=env["BOUND_MOVEMENT_FOLLOWER"] != "0"
        func memory() throws->BoundGBAMemorySnapshot {
            try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory:{core.deltaCore.emulatorBridge.readMemory?(at:$0,size:$1)}))
        }
        if followerRequested {
            if try memory().workRAM[0x24029]==0 {
                XCTAssertTrue(BoundVBABattleBridge.qaStartNativePartyFixture())
                XCTAssertTrue(core.resume());try await Task.sleep(for:.milliseconds(500));XCTAssertTrue(core.pause())
            }
            XCTAssertTrue(BoundVBABattleBridge.qaWarpViridianFollowerService())
            XCTAssertTrue(core.resume());try await Task.sleep(for:.seconds(1));XCTAssertTrue(core.pause())
            core.deltaCore.emulatorBridge.activateInput(64,value:1,playerIndex:0)
            XCTAssertTrue(core.resume());try await Task.sleep(for:.milliseconds(30))
            core.deltaCore.emulatorBridge.deactivateInput(64,playerIndex:0)
            try await Task.sleep(for:.milliseconds(100));XCTAssertTrue(core.pause())
            var active=false
            for _ in 0..<14 {
                core.deltaCore.emulatorBridge.activateInput(1,value:1,playerIndex:0)
                XCTAssertTrue(core.resume());try await Task.sleep(for:.milliseconds(100))
                core.deltaCore.emulatorBridge.deactivateInput(1,playerIndex:0)
                try await Task.sleep(for:.milliseconds(150));XCTAssertTrue(core.pause())
                let m=try memory();active=m.workRAM[0x3B25E]&0x20 != 0 && m.workRAM[0x3B818]==1
                if active {break}
            }
            XCTAssertTrue(active,"The native service must enable the actual follower before measurement")
            if let png=core.videoManager.snapshot()?.pngData() {try png.write(to:output.appendingPathComponent("follower-service.png"))}
        }
        XCTAssertTrue(BoundVBABattleBridge.qaWarpViridianMartEntrance())
        XCTAssertTrue(core.resume());try await Task.sleep(for:.seconds(1));XCTAssertTrue(core.pause())
        let reading=try XCTUnwrap(stateProbe.takeLatest()),player=try XCTUnwrap(reading.player)
        XCTAssertEqual(player.mapGroup,3);XCTAssertEqual(player.mapNumber,1);XCTAssertNotNil(player.scene)
        // A real, valid pose remains far offscreen in every case. It activates
        // the shipping video wrapper without contributing any overlay pixels.
        var offscreen=try XCTUnwrap(BoundPresencePose(reading:reading));offscreen.x+=512;offscreen.follower=nil
        videoCompositor.configure(profile:profile,pose:offscreen,coreID:ObjectIdentifier(core))
        videoCompositor.observeFrame={reading,_,pixels in tape.receiveVideo(core,reading,pixels:pixels)}
        videoCompositor.receive(core)
        let anchor=MultiRedAdapter.captureState();XCTAssertFalse(anchor.isEmpty)
        try anchor.write(to:output.appendingPathComponent("exact-ROM-anchor.state"))
        let fixture:[String:Any]=["romSHA256":digest,"localSeed":UInt32(0x12345678),"partnerSeed":UInt32(0x87654321),
            "run":"11111111-2222-3333-4444-555555555555","debugPlayer":1,"settings":options.settings.base64EncodedString(),
            "followerRequested":followerRequested,"anchorSHA256":SHA256.hash(data:anchor).map{String(format:"%02x",$0)}.joined(),
            "pixelDiagnostics":env["BOUND_MOVEMENT_PIXEL_DIAGNOSTICS"]=="1",
            "phaseFrames":phases,"preRollFramesByRepeat":(0..<repeats).map{phases[$0%phases.count]},
            "scope":"Native New Game, QA party preparation if absent, native warp/script and actual follower dialogue; no position/collision/follower state endpoint writes"]
        try JSONSerialization.data(withJSONObject:fixture,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fixture.json"))
        var reports=[[String:Any]]()
        for repetition in 0..<repeats {
            let preRollFrames=phases[repetition%phases.count]
            for rate in rates {
                for mode in repetition%2==0 ? modes:Array(modes.reversed()) {
                    XCTAssertTrue(MultiRedAdapter.restoreState(anchor));core.rate=rate
                    for bit in [2,16,32] {core.deltaCore.emulatorBridge.deactivateInput(bit,playerIndex:0)}
                    videoCompositor.receive(core)
                    tape.probe.configure(core:core)
                    tape.senderProbe.configure(coreID:ObjectIdentifier(core),profile:profile,active:true,status:.waiting,
                        detail:"Production sender cadence",sceneEnabled:true)
                    tape.arm(frames:frames,preRollFrames:preRollFrames,mode:mode,anchor:.init(player.tile))
                    core.updateHandler={core in
                        BoundFrameMemory.perform {setup.receive(core);videoCompositor.receive(core);tape.receive(core,profile:profile,field:setup.request?.safeField==true)}
                    }
                    XCTAssertTrue(core.resume())
                    let deadline=ProcessInfo.processInfo.systemUptime+Double(frames+preRollFrames)/(60*rate)+30
                    while !tape.finished,ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(for:.milliseconds(10))}
                    XCTAssertTrue(core.pause())
                    let rows=tape.result(),completedMetrics=MovementCadenceTape.metrics(rows),videoRows=tape.videoResult()
                    let metrics=MovementCadenceTape.videoMetrics(videoRows)
                    let pixelValidation=MovementCadenceTape.pixelValidation(videoRows)
                    let name="repeat-\(repetition+1)-\(mode)-\(rate)"
                    let report:[String:Any]=["name":name,"romSHA256":digest,"mode":mode,"rate":rate,
                        "preRollFrames":preRollFrames,
                        "repeat":repetition+1,"metrics":metrics,"videoRaw":videoRows,"completedFrameMetrics":completedMetrics,"raw":rows,
                        "pixelValidation":pixelValidation,
                        "scope":"Movement cadence at actual VBA-M video processFrame, native DPad and BoundMovementProbe; raw/completedFrameMetrics use production BoundVBAPlayerStateProbe sender, not the video boundary; synthetic occupancy, no network/backend/checkpoint/physical scanout"]
                    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent(name+".json"))
                    reports.append(report.filter{$0.key != "raw" && $0.key != "videoRaw"})
                    print("BOUND_MOVEMENT_CADENCE \(name) \(metrics) output=\(output.path)")
                    XCTAssertTrue(tape.finished);XCTAssertEqual(rows.count,frames)
                    XCTAssertGreaterThan(videoRows.count,Int(Double(frames)/(rate*2)),"Exercise actual rendered frames at both playback rates")
                    XCTAssertEqual(metrics["overlayPixelSamples"] as? Int,0,"All modes use the same invisible observation wrapper")
                    XCTAssertGreaterThan(completedMetrics["tileTransitions"] as? Int ?? 0,frames/40,"Replay must actually traverse the floor")
                    XCTAssertGreaterThan(completedMetrics["fieldSamples"] as? Int ?? 0,frames*9/10)
                    XCTAssertEqual(completedMetrics["remoteBlockedSamples"] as? Int,0,"Synthetic peers are on another row")
                    if mode != "native" {XCTAssertGreaterThan(completedMetrics["admittedPortSamples"] as? Int ?? 0,frames*9/10)}
                    if followerRequested {XCTAssertGreaterThan(completedMetrics["activeFollowerSamples"] as? Int ?? 0,frames*9/10)}
                    if env["BOUND_MOVEMENT_PIXEL_DIAGNOSTICS"]=="1" {
                        XCTAssertGreaterThan(pixelValidation["trainerChecks"] ?? 0,videoRows.count*9/10,"Require confident native trainer pixel evidence, not an empty diagnostic")
                        XCTAssertGreaterThan(pixelValidation["cameraChecks"] ?? 0,max(0,videoRows.count-1)*9/10,"Require confident background shifts for nearly all frames")
                        XCTAssertEqual(pixelValidation["trainerMismatches"],0,"Decoded native screen foot must match actual trainer pixels")
                        XCTAssertEqual(pixelValidation["nativeCenterMismatches"],0,"The center-screen road fixture stays at the native pixel center without a clamp")
                        XCTAssertEqual(pixelValidation["cameraMismatches"],0,"Every confident native background shift must match decoded camera motion")
                    }
                }
            }
        }
        let data=try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:output.appendingPathComponent("summary.json"))
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        attachment.name="repeated-native-movement-cadence";attachment.lifetime = .keepAlways;add(attachment)
    }
}
private final class MovementRuntimeController:NSObject,GameController {
    let name="World movement native input QA"
    var playerIndex:Int?=0
    let inputType=GameControllerInputType.mfi
    var defaultInputMapping:GameControllerInputMappingProtocol? {nil}
}
private final class MovementRuntimeClock:@unchecked Sendable {
    private let lock=NSLock()
    private var value:TimeInterval=100
    func read()->TimeInterval {lock.lock();defer{lock.unlock()};return value}
    func set(_ next:TimeInterval) {lock.lock();value=next;lock.unlock()}
}
private final class MovementRuntimeFrames:@unchecked Sendable {
    private let lock=NSLock()
    private var count:UInt64=0,enabled=true
    private var stepOrigin:BoundMovementTile?,stepFrame:UInt32=0,stepFinished=false
    private var stepSnapshot:BoundMovementSnapshot?
    let probe:BoundMovementProbe
    init(probe:BoundMovementProbe){self.probe=probe}
    func enable(_ value:Bool){lock.lock();enabled=value;lock.unlock()}
    func read()->UInt64 {lock.lock();defer{lock.unlock()};return count}
    func armStep(_ snapshot:BoundMovementSnapshot) {
        lock.lock();stepOrigin=snapshot.current;stepFrame=BoundMovementSnapshot.word(snapshot.bytes,12)
        stepFinished=false;stepSnapshot=nil;lock.unlock()
    }
    func stepResult()->(Bool,BoundMovementSnapshot?) {
        lock.lock();defer{lock.unlock()};return(stepFinished,stepSnapshot)
    }
    func cancelStep(){lock.lock();stepOrigin=nil;lock.unlock()}
    func receive(_ core:EmulatorCore) {
        lock.lock();let apply=enabled;lock.unlock()
        if apply {probe.receive(core)}
        lock.lock();let origin=stepOrigin,initialFrame=stepFrame,finished=stepFinished;lock.unlock()
        if let origin,!finished {
            let snapshot=BoundMovementSnapshot(BoundVBABattleBridge.worldMovementSnapshot())
            // Delta's read-only bank maps EWRAM at0x8000, after IWRAM.
            let avatar=core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x3707D,size:1)
            var physical:BoundMovementTile?
            if let avatar,let index=avatar.first,index<16,
               let bytes=core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x36E38+Int(index)*36+16,size:4),bytes.count==4 {
                let x=Int(Int16(bitPattern:UInt16(bytes[0])|UInt16(bytes[1])<<8))-7
                let y=Int(Int16(bitPattern:UInt16(bytes[2])|UInt16(bytes[3])<<8))-7
                physical = .init(x:x,y:y)
            }
            let blocked=snapshot.map{BoundMovementSnapshot.word($0.bytes,12) != initialFrame && $0.flags&(32|64|16) != 0} ?? false
            if physical.map({$0 != origin}) == true || blocked {
                // Release on the emulation callback, before another native
                // step can begin. MainActor polling can span multiple frames.
                core.deltaCore.emulatorBridge.deactivateInput(32,playerIndex:0)
                lock.lock();stepFinished=true;stepSnapshot=snapshot;lock.unlock()
            }
        }
        lock.lock();count &+= 1;lock.unlock()
    }
}

@MainActor private final class MovementRuntimeWorker {
    let core:EmulatorCore,output:URL,image:Data
    private(set) var state:Data
    let probe:BoundMovementProbe,frames:MovementRuntimeFrames,clock:MovementRuntimeClock
    private let host=BoundROMMultiplayerProbe()
    init(name:String) throws {
        let clock=MovementRuntimeClock();self.clock=clock
        let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Phase6SoulQA-"+String(BoundWorldContract.romSHA256.prefix(12)))
        let rom=root.appendingPathComponent("current.gba"),frozen=root.appendingPathComponent("observer.state")
        guard FileManager.default.fileExists(atPath:rom.path),FileManager.default.fileExists(atPath:frozen.path) else {
            throw XCTSkip("Requires the dedicated exact-ROM Phase6SoulQA fixture")
        }
        image=try Data(contentsOf:rom);state=try Data(contentsOf:frozen)
        guard SHA256.hash(data:image).map({String(format:"%02x",$0)}).joined()==BoundWorldContract.romSHA256 else {
            throw NSError(domain:"WorldMovementFixtureHash",code:1)
        }
        output=root.appendingPathComponent(name+"-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let battery=output.appendingPathComponent("work.sav")
        try Data(repeating:255,count:131072).write(to:battery)
        core=try XCTUnwrap(EmulatorCore(game:MovementRuntimeGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
        core.audioManager.isEnabled=false
        try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(core)
        guard MultiRedAdapter.restoreState(state) else {throw NSError(domain:"WorldMovementRestore",code:1)}
        probe=BoundMovementProbe(clock:{clock.read()});frames=MovementRuntimeFrames(probe:probe)
        probe.configure(core:core);host.configure(core:core);host.setVerified(true)
        var status=BoundROMHostState();status.enabled=true;status.ended=true;status.status = .complete;host.publish(status)
        let host=host,frames=frames
        core.updateHandler={core in BoundFrameMemory.perform{host.receive(core);frames.receive(core)}}
        core.rate=1;_=core.pause()
        BoundFrameMemory.perform{host.receive(core);probe.receive(core)}
    }
    func close(){_=core.pause();BoundVBABattleBridge.setWorldMovementHost(Data());BoundVBABattleBridge.closeSoulLink();_=core.stop()}
    func preparePalletFixture() async throws {
        let initial=try snapshot()
        if initial.group==4 && [0,1].contains(initial.number) {
            // A fresh current-cartridge state starts in the bedroom. Use the
            // original native warp opcode to prepare the same open Pallet floor;
            // do not transplant an older ROM's emulator state or patch movement.
            XCTAssertTrue(BoundVBABattleBridge.qaWarpPalletEntrance())
            try await advance(180)
            state=MultiRedAdapter.captureState()
        }
        let ready=try snapshot()
        XCTAssertEqual(ready.group,3);XCTAssertEqual(ready.number,0)
    }
    func memory() throws->BoundGBAMemorySnapshot {
        try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory:{core.deltaCore.emulatorBridge.readMemory?(at:$0,size:$1)}))
    }
    func snapshot() throws->BoundMovementSnapshot {try XCTUnwrap(BoundMovementSnapshot(BoundVBABattleBridge.worldMovementSnapshot()))}
    func publish(_ data:Data?) {
        XCTAssertEqual(core.state,.paused)
        probe.publish(data)
        // Prime the completed-frame port before introducing the first input.
        // A connected live session normally already has this admitted data.
        BoundFrameMemory.perform{probe.receive(core)}
    }
    func admit(_ data:Data) async throws {
        let previous=BoundMovementSnapshot.word(try snapshot().bytes,76)
        publish(data)
        // Writing PH does not synchronously ingest native PC_INPUT. A restored
        // CPU can be between BeforeCallbacks and its collision query. Wait for
        // native acknowledgement before introducing a connected peer's input.
        for _ in 0..<90 {
            try await advance(1)
            let accepted=try snapshot()
            if accepted.flags&6==6 && BoundMovementSnapshot.word(accepted.bytes,76) != previous {return}
        }
        throw NSError(domain:"WorldMovementNativeAdmissionTimeout",code:1)
    }
    func rewind() throws {
        _=core.pause()
        for key in [1,2,8,16,32,64,128]{core.deltaCore.emulatorBridge.deactivateInput(key,playerIndex:0)}
        BoundVBABattleBridge.setWorldMovementHost(Data());XCTAssertTrue(MultiRedAdapter.restoreState(state))
        probe.configure(core:core);frames.enable(true);clock.set(100)
        BoundFrameMemory.perform{host.receive(core);probe.receive(core)}
    }
    func advance(_ count:UInt64) async throws {
        let target=frames.read()+count
        XCTAssertTrue(core.resume())
        for _ in 0..<600 {
            if frames.read()>=target {
                _=core.pause()
                // A video frame can end midway through a native callback.
                // An odd BWO sequence is a legal partial writer. Observe only
                // a completed native publication before asserting its fields.
                if BoundMovementSnapshot(BoundVBABattleBridge.worldMovementSnapshot()) != nil {return}
                XCTAssertTrue(core.resume())
            }
            try await Task.sleep(for:.milliseconds(10))
        }
        _=core.pause();throw NSError(domain:"WorldMovementFrameTimeout",code:Int(count))
    }
    func press(_ mask:Int,held:UInt64=4,release:UInt64=20) async throws {
        core.deltaCore.emulatorBridge.activateInput(mask,value:1,playerIndex:0)
        try await advance(held);core.deltaCore.emulatorBridge.deactivateInput(mask,playerIndex:0)
        try await advance(release)
    }
    @discardableResult func leftStep() async throws->BoundMovementSnapshot {
        let start=try snapshot();frames.armStep(start)
        core.deltaCore.emulatorBridge.activateInput(32,value:1,playerIndex:0)
        defer{frames.cancelStep();core.deltaCore.emulatorBridge.deactivateInput(32,playerIndex:0)}
        XCTAssertTrue(core.resume())
        for _ in 0..<600 {
            if frames.stepResult().0 {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        _=core.pause();guard frames.stepResult().0 else {throw NSError(domain:"WorldMovementNativeStepStartTimeout",code:1)}
        core.deltaCore.emulatorBridge.deactivateInput(32,playerIndex:0)
        if BoundMovementSnapshot(BoundVBABattleBridge.worldMovementSnapshot()) == nil {try await advance(1)}
        let observed:BoundMovementSnapshot
        if let captured=frames.stepResult().1 {observed=captured} else {observed=try snapshot()}
        if try snapshot().current != start.current {
            for _ in 0..<90 {
                let now=try snapshot(),ram=try memory().workRAM
                if now.current==now.previous && ram[0x3707A]==0 && ram[0x3707B]==0 {return observed}
                try await advance(1)
            }
            throw NSError(domain:"WorldMovementNativeStepSettleTimeout",code:1)
        }
        return observed
    }
    func hostData(_ s:BoundMovementSnapshot,actors:[BoundMovementActor],flags:UInt32=1,sequence:UInt32=42)->Data {
        var d=Data(repeating:0,count:1024)
        func put(_ value:UInt32,_ at:Int){BoundMovementSnapshot.put(value,&d,at)}
        put(0x31574C42,0);put(1,4);put(sequence,8);put(flags,12);put(15,16);put(s.generation,20);put(1,24);put(2,28)
        for at in [32,48]{put(UInt32(truncatingIfNeeded:s.instance),at);put(UInt32(truncatingIfNeeded:s.instance>>32),at+4)}
        d[64]=UInt8(s.group);d[65]=UInt8(s.number);d[66]=UInt8(s.elevation);put(UInt32(actors.count),68)
        for (index,a) in actors.enumerated() {
            let at=128+index*32;put(1,at);BoundMovementSnapshot.putTile(a.current,&d,at+4);BoundMovementSnapshot.putTile(a.previous,&d,at+8)
            d[at+12]=UInt8(a.elevation);d[at+13]=UInt8(a.kind)
            put(UInt32(truncatingIfNeeded:a.identity),at+20);put(UInt32(truncatingIfNeeded:a.identity>>32),at+24)
        }
        return d
    }
    func actor(_ s:BoundMovementSnapshot,dx:Int=0,kind:Int=0)->BoundMovementActor {
        let tile=BoundMovementTile(x:s.current.x+dx,y:s.current.y)
        return .init(current:tile,previous:tile,elevation:s.elevation,kind:kind,identity:kind==1 ? 0x1234567887654321:0)
    }
    func report(_ name:String,_ values:[String:Any]) throws {
        var v=values;v["romSHA256"]=BoundWorldContract.romSHA256
        try JSONSerialization.data(withJSONObject:v,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent(name+".json"))
    }
}

@MainActor final class WorldMovementRuntimeTests:XCTestCase {
    private var previous:Any?
    override func setUp(){super.setUp();previous=UserDefaults.standard.object(forKey:BoundMultiplayerFeatures.key);BoundMultiplayerFeatures.setEnabled(true)}
    override func tearDown(){UserDefaults.standard.set(previous,forKey:BoundMultiplayerFeatures.key);NotificationCenter.default.post(name:BoundMultiplayerFeatures.didChange,object:nil);super.tearDown()}
    private func required() throws {
        guard ProcessInfo.processInfo.environment["BOUND_ENCOUNTER_GAMEPLAY"]=="1" else {throw XCTSkip("Requires isolated current-ROM runtime fixture")}
        continueAfterFailure=false
    }
    func testActualNativeWorldPortBlocksOccupiedTilesAndAllowsImmediateOverlapExit() async throws {
        try required();let w=try MovementRuntimeWorker(name:"world-native-movement");defer{w.close()}
        try await w.preparePalletFixture()
        let initial=try w.snapshot();XCTAssertNotEqual(initial.flags&1,0)
        XCTAssertEqual(initial.group,3);XCTAssertEqual(initial.number,0,"Fixture must expose the verified native Pallet floor")
        let target=BoundMovementTile(x:initial.current.x-1,y:initial.current.y)
        try await w.leftStep();XCTAssertEqual(try w.snapshot().current,target,"Native baseline must walk on the real floor")
        var checked=[String]()
        for kind in [0,1] {
            try w.rewind();let s=try w.snapshot();try await w.admit(w.hostData(s,actors:[w.actor(s,dx:-1,kind:kind)]))
            let attempt=try await w.leftStep();let blocked=try w.snapshot();XCTAssertEqual(blocked.current,s.current);XCTAssertNotNil(attempt.request)
            XCTAssertNotEqual(attempt.flags&32,0);checked.append(kind==0 ? "player blocked":"follower blocked")
            w.publish(nil);try await w.leftStep()
            XCTAssertEqual(try w.snapshot().current,target,"Revocation must release an already held blocker")
        }
        // Match production's GP_ENABLED publication. GP_NEGOTIATE is retired;
        // explicitly enabling its legacy gate would manufacture the old delay.
        try w.rewind();let overlap=try w.snapshot();try await w.admit(w.hostData(overlap,actors:[w.actor(overlap)]))
        let escape=try await w.leftStep()
        XCTAssertEqual(try w.snapshot().current,target,"Native overlap recovery must move immediately without a network grant")
        XCTAssertNil(escape.request)
        try w.rewind();let near=try w.snapshot();try await w.admit(w.hostData(near,actors:[w.actor(near,dx:-2)]))
        let beside=try await w.leftStep(),arrived=try w.snapshot()
        XCTAssertEqual(arrived.current,target,"An adjacent open tile must not become an invisible collision border")
        XCTAssertNil(beside.request);XCTAssertEqual(beside.flags&64,0)
        try w.report("movement",["passed":true,"checked":checked+["immediate overlap escape","adjacent open tile without grant"],"nativeGeneration":arrived.generation,"scope":"Real VBA-M frames and DPad; synthetic declared peer occupancy, no position writes"])
    }
    func testActualNativePortAtomicValidationTTLMapAndBagTransition() async throws {
        try required();let w=try MovementRuntimeWorker(name:"world-native-port");defer{w.close()}
        try await w.preparePalletFixture()
        let s=try w.snapshot();w.frames.enable(false)
        let valid=w.hostData(s,actors:[w.actor(s,dx:-1)],sequence:42)
        BoundVBABattleBridge.setWorldMovementHost(valid);try await w.advance(1)
        XCTAssertEqual(BoundMovementSnapshot.word(try w.snapshot().bytes,76),42);XCTAssertNotEqual(try w.snapshot().flags&4,0)
        var odd=valid;BoundMovementSnapshot.put(43,&odd,8)
        for rejected in [odd,Data(valid.prefix(17))] {
            BoundVBABattleBridge.setWorldMovementHost(rejected);try await w.advance(1)
            XCTAssertEqual(BoundMovementSnapshot.word(try w.snapshot().bytes,76),42,"Invalid publication must preserve the committed host transaction")
        }
        try await w.advance(16);XCTAssertEqual(try w.snapshot().flags&4,0,"Unchanged native input expires within15 frames")
        try await w.leftStep();XCTAssertEqual(try w.snapshot().current,.init(x:s.current.x-1,y:s.current.y))
        try w.rewind();let fresh=try w.snapshot();var wrong=w.hostData(fresh,actors:[w.actor(fresh,dx:-1)])
        wrong[48] ^= 1;w.publish(wrong);try await w.advance(3);XCTAssertEqual(try w.snapshot().flags&4,0)
        wrong=w.hostData(fresh,actors:[w.actor(fresh,dx:-1)]);wrong[64]=UInt8((fresh.group+1)%43)
        w.publish(wrong);try await w.advance(3);XCTAssertEqual(try w.snapshot().flags&4,0,"A different current native map cannot admit peer occupancy")
        w.publish(w.hostData(fresh,actors:[w.actor(fresh,dx:-4)]));try await w.advance(2)
        try await w.press(8);let menu=try w.memory().workRAM,count=Int(menu[0x370F5]),cursor=Int(menu[0x370F4])
        XCTAssertTrue((1...9).contains(count));let order=Array(menu[0x370F6..<0x370F6+count]),bag=try XCTUnwrap(order.firstIndex(of:2))
        XCTAssertLessThan(cursor,count)
        for _ in 0..<count*3 {
            if Int(try w.memory().workRAM[0x370F4])==bag {break}
            try await w.press(128)
        }
        XCTAssertEqual(Int(try w.memory().workRAM[0x370F4]),bag)
        try await w.press(1,release:80)
        let bagSnapshot=try w.snapshot();XCTAssertEqual(bagSnapshot.flags&(1|4),0);XCTAssertNil(bagSnapshot.request,"Native menu/fade removes movement authority")
        try w.report("port",["passed":true,"checks":["atomic odd/short rejection","native15-frame TTL","different current map","different map instance","Bag transition removes authority"],"snapshot":bagSnapshot.bytes.base64EncodedString()])
    }
    func testRetiredCosmeticBerryLeavesRAMUnchangedAndInteractionFilterSuppressesA() async throws {
        try required();let w=try MovementRuntimeWorker(name:"world-cosmetic-berry");defer{w.close()}
        try await w.preparePalletFixture()
        let paused=try w.memory(),receiver=BoundFollowerInteractionSession()
        let ramBefore=Data(paused.workRAM)+Data(paused.internalRAM)
        receiver.receive(Data("BFC1".utf8)+Data(repeating:0,count:96))
        let ramAfter=try w.memory()
        XCTAssertEqual(Data(ramAfter.workRAM)+Data(ramAfter.internalRAM),ramBefore,"Retired cosmetic packets cannot mutate native RAM")
        let gate=BoundFriendWorldInputGate(),controller=MovementRuntimeController();gate.updateSocial(available:true,blocked:false)
        let interact=gate.filter(GBAGameInput.a);XCTAssertEqual(BoundFriendWorldInput(input:interact),.interact)
        w.core.gameController(controller,didActivate:interact,value:1);try await w.advance(3)
        var keys=try w.memory().internalRAM;XCTAssertEqual(keys[0x311C]&1,0,"Production app-only namespace cannot press native A")
        w.core.gameController(controller,didDeactivate:interact);gate.updateSocial(available:true,blocked:true)
        let blocked=gate.filter(GBAGameInput.a);XCTAssertEqual(BoundFriendWorldInput(input:blocked),.blockedA)
        w.core.gameController(controller,didActivate:blocked,value:1);try await w.advance(3)
        keys=try w.memory().internalRAM;XCTAssertEqual(keys[0x311C]&1,0)
        w.core.gameController(controller,didDeactivate:blocked)
        try w.report("retired-cosmetic",["passed":true,"nativeRAMBytesCompared":ramBefore.count,"productionANamespaceSuppressed":true,"scope":"Retired cosmetic packets cannot mutate RAM; native feeding has separate script/effect tests"])
    }
    func testActualPreFrameRevocationAndWallClockExpiryClearOnlyDeclaredHostPort() async throws {
        try required()
        #if targetEnvironment(simulator)
        let w=try MovementRuntimeWorker(name:"world-preframe-revocation");defer{w.close()}
        try await w.preparePalletFixture()
        let s=try w.snapshot();try await w.admit(w.hostData(s,actors:[w.actor(s,dx:-1)]))
        w.frames.enable(false)
        let zero=Data(repeating:0,count:1024),committed=BoundVBABattleBridge.qaWorldMovementHost()
        XCTAssertEqual(committed.count,1024);XCTAssertNotEqual(committed,zero)
        let before=try w.memory(),ram=Data(before.workRAM)+Data(before.internalRAM)
        BoundVBABattleBridge.requestWorldMovementRevocation()
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),committed,"Paused revocation queues a fence; it does not race a ROM writer")
        var paused=try w.memory();XCTAssertEqual(Data(paused.workRAM)+Data(paused.internalRAM),ram)
        // Exactly one original core frame through the production swizzled
        // selector, with the core paused and automatic probe refresh disabled.
        w.core.deltaCore.emulatorBridge.runFrame(processVideo:false)
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),zero,"The queued revoke clears before the next native frame")

        let valid=w.hostData(s,actors:[w.actor(s,dx:-1)],sequence:100)
        BoundVBABattleBridge.setWorldMovementHost(valid)
        let deadlineRAM=try w.memory(),deadlineBytes=Data(deadlineRAM.workRAM)+Data(deadlineRAM.internalRAM)
        try await Task.sleep(for:.milliseconds(220))
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),valid,"Wall-clock expiration waits for the core's frame fence")
        paused=try w.memory();XCTAssertEqual(Data(paused.workRAM)+Data(paused.internalRAM),deadlineBytes)
        w.core.deltaCore.emulatorBridge.runFrame(processVideo:false)
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),zero,"The first actual frame clears data older than150ms")

        BoundVBABattleBridge.requestWorldMovementRevocation()
        BoundVBABattleBridge.setWorldMovementHost(valid)
        w.core.deltaCore.emulatorBridge.runFrame(processVideo:false)
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),valid,"Fresh committed host data supersedes an older queued revocation")
        try w.report("preframe",["passed":true,"queuedRevocationClearedFirstFrame":true,"wallClockExpiryClearedFirstFrame":true,"freshPublicationSupersededOlderRevoke":true,"pausedNativeRAMBytesCompared":ram.count,"scope":"Read-only actual1024B ROM-port inspection, production pre-frame selector, no CPU coordinate or RAM writes"])
        #else
        throw XCTSkip("Requires the Debug simulator read-only host-port getter")
        #endif
    }
}

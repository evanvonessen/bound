import XCTest
@testable import Delta

final class FollowerPresentationTests: XCTestCase {
    private func sprite(_ color:UInt16=31,width:Int=32)->BoundPlayerSprite {
        var palette=Data(repeating:0,count:32);palette[2]=UInt8(truncatingIfNeeded:color);palette[3]=UInt8(color>>8)
        return .init(width:width,height:32,tiles:Data(repeating:0x11,count:width*16),palette:palette,
            flipX:false,flipY:false,priority:2,romAddress:0x08100000)
    }
    private func reading(_ frame:UInt64,x:Int,y:Int=4,footX:Int?=nil,previousX:Int?=nil,key:UInt64=0x08350D6C082D52FC,id:UInt64=42,mapGroup:Int=4,mapNumber:Int=1,elevation:Int=0)->BoundPlayerStateReading {
        let scene=BoundPlayerScene(worldFoot:.init(x:footX ?? x*16+8,y:y*16+16),camera:.init(x:0,y:0),appearance:sprite(width:16),
            background:.init(tiles:Data(repeating:0,count:32768),layers:[]),objects:[],mapInstance:key)
        let player=BoundPlayerState(mapGroup:mapGroup,mapNumber:mapNumber,tile:.init(x:x,y:y),previousTile:.init(x:previousX ?? x,y:y),facing:"East",
            elevation:elevation,graphicsID:0,runningState:0,tileTransitionState:0,scene:scene,mapInstance:key)
        return .init(frame:frame,status:.live,detail:"Synthetic native party/icon fixture",player:player)
    }

    func testCompactFollowerRoundTripHasFixedPaletteBoundAndRejectsMalformedFlags() throws {
        var value=reading(1,x:1030)
        var player=try XCTUnwrap(value.player),scene=try XCTUnwrap(player.scene)
        scene.follower = .init(identity:UInt64.max,species:4095,objectID:15,generation:UInt32.max,
            current:.init(x:1030,y:1030),previous:.init(x:1029,y:1030),worldFoot:.init(x:16488,y:16496),
            elevation:15,facing:4,appearance:.init(width:64,height:64,tiles:Data(repeating:0,count:2048),palette:Data(repeating:255,count:32),flipX:true,flipY:true,priority:3,romAddress:0x09FFF800))
        player.scene=scene;value = .init(frame:1,status:.live,detail:"Bounded codec fixture",player:player)
        var follower=try XCTUnwrap(BoundPresenceFollower(reading:value));follower.x=16487.9375
        let encoded=try JSONEncoder().encode(follower)
        print("FOLLOWER_WIRE_BYTES",encoded.count)
        XCTAssertLessThanOrEqual(encoded.count,150);XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("\\/"))
        XCTAssertEqual(try JSONDecoder().decode(BoundPresenceFollower.self,from:encoded),follower)
        var array=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [Any])
        array[6]=UInt64(1)<<31
        XCTAssertThrowsError(try JSONDecoder().decode(BoundPresenceFollower.self,from:JSONSerialization.data(withJSONObject:array)))
        array=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [Any]);array.append(0)
        XCTAssertThrowsError(try JSONDecoder().decode(BoundPresenceFollower.self,from:JSONSerialization.data(withJSONObject:array)))
        follower.x=1_000_000;XCTAssertFalse(follower.isValid,"Visual foot must agree with collision/interaction tiles")
    }



    private func nativeFixture() -> (Data, BoundPlayerState) {
        var work=Data(repeating:0,count:0x40000)
        func put(_ at:Int,_ value:UInt32,_ size:Int=4) { for n in 0..<size { work[at+n]=UInt8(truncatingIfNeeded:value>>(8*n)) } }
        let key:UInt64=0x08350D6C082D52FC
        put(0x2000,0x314F5742);put(0x2004,1);put(0x2008,2);put(0x2020,0x00000104)
        put(0x2050,UInt32(truncatingIfNeeded:key));put(0x2054,UInt32(key>>32))
        for (offset,value):(Int,UInt32) in [(96,7),(100,7),(104,1),(108,2),(112,0x12345678),(116,4),(120,237),(124,3)] { put(0x2000+offset,value) }
        put(0x3B25E,0x20,1)
        put(0x3B818,1,1);put(0x3B819,7,1);put(0x3B81C,20,1);put(0x3B81D,4,1);put(0x3B81E,5,1)
        put(0x3B824,0x09049966);put(0x3B828,0x1054,2);put(0x3B82A,237,2)
        put(0x24029,2,1)
        for slot in 0..<2 { let at=0x24284+slot*100;put(at,UInt32(slot+1));put(at+4,0x12345678);put(at+19,2,1);put(at+32,4,2);put(at+86,20,2);put(at+88,20,2) }
        let object=0x36E38+7*36
        put(object,1);put(object+4,12,1);put(object+5,237,1);put(object+11,3,1)
        put(object+16,17,2);put(object+18,14,2);put(object+20,17,2);put(object+22,14,2);put(object+24,1,1)
        put(0x2063C+12*68+0x2E,7,2);put(0x2063C+12*68+0x3E,1,1)
        return (work,BoundPlayerState(mapGroup:4,mapNumber:1,tile:.init(x:10,y:8),previousTile:.init(x:10,y:8),facing:"North",
            elevation:3,graphicsID:0,runningState:0,tileTransitionState:0,mapInstance:key))
    }
    func testNativeBindingUsesExactGameSelectionAndNeverWritesMemory() throws {
        let (work,player)=nativeFixture()
        let memory=try XCTUnwrap(BoundGBAMemorySnapshot(copyingWorkRAM:work,internalRAM:Data(repeating:0,count:0x8000)))
        let selected=try XCTUnwrap(BoundNativeFollowerBinding.read(memory:memory,player:player))
        XCTAssertEqual(selected.partySlot,1,"The game may skip a healthy first party member with unsupported overworld graphics")
        XCTAssertEqual(selected.identity,0x0000000212345678);XCTAssertEqual(selected.species,4)
        XCTAssertEqual(selected.objectID,7);XCTAssertEqual(selected.spriteID,12);XCTAssertEqual(selected.generation,3)
        XCTAssertEqual(selected.current,.init(x:10,y:7));XCTAssertEqual(selected.previous,selected.current)
        XCTAssertEqual(Data(memory.workRAM),work,"Metadata decoding is a read-only snapshot operation")
    }
    func testNativeBindingFailsClosedForDisabledHiddenStaleOrDifferentCompanion() throws {
        let (original,player)=nativeFixture()
        let cases:[(Int,UInt8,String)]=[(0x3B25E,0,"service disabled"),(0x2060,1,"not active"),(0x2008,3,"torn publication"),
            (0x3B81C,19,"human companion"),(0x3B824,0,"different script"),(0x2078,238,"selected graphics stale"),
            (0x24284+100,9,"identity changed"),(0x24284+100+19,6,"egg"),(0x24284+100+86,0,"fainted"),
            (0x36E38+7*36+1,0x20,"hidden object"),(0x2063C+12*68+0x2E,8,"sprite reassigned")]
        for (offset,value,label) in cases {
            var work=original;work[offset]=value
            let snapshot=try XCTUnwrap(BoundGBAMemorySnapshot(copyingWorkRAM:work,internalRAM:Data(repeating:0,count:0x8000)))
            XCTAssertNil(BoundNativeFollowerBinding.read(memory:snapshot,player:player),label)
        }
        var warped=player;warped.mapInstance=1
        let snapshot=try XCTUnwrap(BoundGBAMemorySnapshot(copyingWorkRAM:original,internalRAM:Data(repeating:0,count:0x8000)))
        XCTAssertNil(BoundNativeFollowerBinding.read(memory:snapshot,player:warped),"Old map instance cannot publish a follower")
        XCTAssertNil(BoundPresenceFollower(reading:reading(1,x:4)),"No synthetic follower is created when the game provides none")
    }
    func testOwnerCameraCullingDoesNotEraseWorldFollower() throws {
        let (original,player)=nativeFixture()
        var work=original
        work[0x2060]=3 // Enabled and active; outside the owner's camera.
        work[0x36E38+7*36+1]=0x40
        work[0x2063C+12*68+0x3E]=5
        func binding(_ bytes:Data) throws -> BoundNativeFollowerBinding? {
            BoundNativeFollowerBinding.read(memory:try XCTUnwrap(BoundGBAMemorySnapshot(copyingWorkRAM:bytes,
                internalRAM:Data(repeating:0,count:0x8000))),player:player)
        }
        XCTAssertNotNil(try binding(work))
        work[0x36E38+7*36+1]=0x60
        XCTAssertNil(try binding(work),"An explicitly hidden native follower stays hidden")
        work[0x36E38+7*36+1]=0
        XCTAssertNil(try binding(work),"Unexplained sprite invisibility cannot authorize a world actor")
    }
    func testOddPublicationCacheIsBoundedAndRevokesNativeChangesImmediately() throws {
        let (original,player)=nativeFixture(),core=NSObject(),profile=NSObject()
        let scope=BoundNativeFollowerScope(core:ObjectIdentifier(core),profile:ObjectIdentifier(profile),timeline:1)
        let cache=BoundNativeFollowerCache()
        func snapshot(_ work:Data)->BoundGBAMemorySnapshot { BoundGBAMemorySnapshot(copyingWorkRAM:work,internalRAM:Data(repeating:0,count:0x8000))! }
        let committed=try XCTUnwrap(cache.read(memory:snapshot(original),player:player,scope:scope))
        var odd=original;odd[0x2008]=3
        // Uncommitted selected metadata must never replace the committed choice.
        odd[0x2068]=0;odd[0x206C]=99
        for _ in 0..<3 { XCTAssertEqual(cache.read(memory:snapshot(odd),player:player,scope:scope),committed) }
        XCTAssertNil(cache.read(memory:snapshot(odd),player:player,scope:scope),"An indefinitely interrupted publisher loses its follower")
        XCTAssertNil(cache.read(memory:snapshot(odd),player:player,scope:scope),"An odd publication cannot revive its expired cache")
        XCTAssertNotNil(cache.read(memory:snapshot(original),player:player,scope:scope))
        var missedFrames=odd;missedFrames[0x2008]=13
        XCTAssertNil(cache.read(memory:snapshot(missedFrames),player:player,scope:scope),"Suspended readers cannot borrow an old committed choice")
        let revocations:[(Int,UInt8)]=[(0x3B25E,0),(0x3B819,8),(0x24284+100,9),
            (0x36E38+7*36+1,0x20),(0x2063C+12*68+0x3E,5),(0x2010,1)]
        for (offset,value) in revocations {
            XCTAssertNotNil(cache.read(memory:snapshot(original),player:player,scope:scope))
            var changed=odd;changed[offset]=value
            XCTAssertNil(cache.read(memory:snapshot(changed),player:player,scope:scope),"Current native toggle/identity/object/sprite changes revoke even during an interrupted publication")
            XCTAssertNil(cache.read(memory:snapshot(odd),player:player,scope:scope),"Returning bytes cannot revive a revoked old publication")
        }
    }
    func testOddPublicationNeverCarriesAcrossLoadCoreProfileOrMap() throws {
        let (original,player)=nativeFixture(),core=NSObject(),profile=NSObject(),other=NSObject()
        let scope=BoundNativeFollowerScope(core:ObjectIdentifier(core),profile:ObjectIdentifier(profile),timeline:1)
        var odd=original;odd[0x2008]=3
        func snapshot(_ work:Data)->BoundGBAMemorySnapshot { BoundGBAMemorySnapshot(copyingWorkRAM:work,internalRAM:Data(repeating:0,count:0x8000))! }
        let contexts=[BoundNativeFollowerScope(core:scope.core,profile:scope.profile,timeline:2),
            .init(core:ObjectIdentifier(other),profile:scope.profile,timeline:1),
            .init(core:scope.core,profile:ObjectIdentifier(other),timeline:1)]
        for changed in contexts {
            let cache=BoundNativeFollowerCache()
            XCTAssertNotNil(cache.read(memory:snapshot(original),player:player,scope:scope))
            XCTAssertNil(cache.read(memory:snapshot(odd),player:player,scope:changed))
            XCTAssertNil(cache.read(memory:snapshot(odd),player:player,scope:scope))
        }
        let cache=BoundNativeFollowerCache();var warped=player;warped.mapInstance=1
        XCTAssertNotNil(cache.read(memory:snapshot(original),player:player,scope:scope))
        XCTAssertNil(cache.read(memory:snapshot(odd),player:warped,scope:scope))
        XCTAssertNil(cache.read(memory:snapshot(odd),player:player,scope:scope))
    }
    func testVisualMapProjectionKeepsFollowerValidAndScreenPixelsStable() throws {
        var value=reading(1,x:4),player=try XCTUnwrap(value.player),scene=try XCTUnwrap(player.scene)
        let appearance=sprite()
        scene.follower = .init(identity:42,species:4,objectID:7,generation:1,current:.init(x:4,y:4),previous:.init(x:3,y:4),
            worldFoot:.init(x:72,y:80),elevation:0,facing:4,appearance:appearance)
        player.scene=scene;value = .init(frame:1,status:.live,detail:"Native scene in source map",player:player)
        let original=try XCTUnwrap(BoundPresenceFollower(reading:value))
        var projected=original
        let offset=BoundPlayerState.Point(x:20,y:-3)
        projected.x+=Double(offset.x*16);projected.y+=Double(offset.y*16)
        projected.current = .init(x:projected.current.x+offset.x,y:projected.current.y+offset.y)
        projected.previous = .init(x:projected.previous.x+offset.x,y:projected.previous.y+offset.y)
        XCTAssertTrue(projected.isValid,"Foot and both native tile anchors must use the same projected map basis")
        XCTAssertEqual(try JSONDecoder().decode(BoundPresenceFollower.self,from:JSONEncoder().encode(projected)),projected)
        let before=BoundRecordedPlayerPose(mapGroup:4,mapNumber:1,elevation:0,x:original.x,y:original.y,appearance:appearance)
        let after=BoundRecordedPlayerPose(mapGroup:4,mapNumber:2,elevation:0,x:projected.x,y:projected.y,appearance:appearance)
        let translatedScene=BoundPlayerScene(worldFoot:.init(x:scene.worldFoot.x+offset.x*16,y:scene.worldFoot.y+offset.y*16),
            camera:.init(x:scene.camera.x-offset.x*16,y:scene.camera.y-offset.y*16),appearance:scene.appearance,
            background:scene.background,objects:scene.objects)
        let first=BoundRecordedPlayerRasterizer.rgba(pose:before,scene:scene)
        let second=BoundRecordedPlayerRasterizer.rgba(pose:after,scene:translatedScene)
        XCTAssertEqual(first.0,second.0);XCTAssertEqual(first.1,second.1)
        XCTAssertEqual(original.current,.init(x:4,y:4),"Visual projection must not mutate the authoritative sample")
    }
    @MainActor func testWorstCaseFullVersionOnePresenceStaysBelowServerLimit() throws {
        var value=reading(1,x:1030,mapGroup:255,mapNumber:255,elevation:15),player=try XCTUnwrap(value.player)
        let follower=BoundPlayerFollower(identity:UInt64.max,species:4095,objectID:15,generation:UInt32.max,
            current:.init(x:1030,y:1030),previous:.init(x:1029,y:1030),worldFoot:.init(x:16488,y:16496),
            elevation:15,facing:4,appearance:.init(width:64,height:64,tiles:Data(repeating:0,count:2048),palette:Data(repeating:255,count:32),
                flipX:true,flipY:true,priority:3,romAddress:0x09FFF800))
        player.mapInstance=UInt64.max
        player.scene = .init(worldFoot:.init(x:1_048_592,y:1_048_592),camera:.init(x:0,y:0),
            appearance:.init(width:16,height:32,tiles:Data(repeating:0,count:256),palette:Data(repeating:255,count:32),
                flipX:true,flipY:true,priority:3,romAddress:0x09FFFF00),
            background:.init(tiles:Data(repeating:0,count:32768),layers:[]),objects:[],follower:follower,mapInstance:UInt64.max)
        value = .init(frame:1,status:.live,detail:"Worst bounded wire fixture",player:player)
        var pose=try XCTUnwrap(BoundPresencePose(reading:value));pose.follower?.x=16487.9375;pose.passing=true
        pose.collisionTiles=(0..<4).reduce(UInt64(0)) { $0 | UInt64(1037)<<(11*$1) };pose.collisionElevation=15
        let packet=BoundPresencePacket(version:1,rom:String(repeating:"f",count:64),
            sender:UUID(uuidString:"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            receiver:UUID(uuidString:"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,sequence:UInt64.max,
            time:Double.greatestFiniteMagnitude,pose:pose,withdrawn:true)
        let bytes=try XCTUnwrap(packet.encoded(),"Oversize presence disconnects at the existing server")
        print("FULL_PRESENCE_WIRE_BYTES",bytes.count)
        XCTAssertLessThanOrEqual(bytes.count,768);XCTAssertNotNil(BoundPresencePacket.decode(bytes))
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertEqual(json["version"] as? Int,1);XCTAssertNotNil(json["pose"] as? [String:Any],"Existing retained-presence server contract stays intact")
    }
    func testMultiActorDepthPassingBlendAndNativeFramebufferRestoration() throws {
        let scene=try XCTUnwrap(reading(1,x:4).player?.scene)
        var trainer=BoundRecordedPlayerPose(mapGroup:4,mapNumber:1,elevation:0,x:80,y:80,appearance:sprite(31,width:16))
        let follower=BoundRecordedPlayerPose(mapGroup:4,mapNumber:1,elevation:0,x:80,y:80,appearance:sprite(31<<10))
        var buffer=[UInt8](repeating:34,count:240*160*4),calls=0,opaque=[UInt8](),ghost=[UInt8]()
        let original=buffer
        _ = buffer.withUnsafeMutableBufferPointer { pixels in
            BoundPresenceFrameCompositor.composite([trainer,follower],scene:scene,into:pixels.baseAddress!) {
                calls+=1;opaque=Array(pixels)
            }
        }
        XCTAssertEqual(calls,1);XCTAssertEqual(buffer,original)
        let center=(70*240+80)*4
        XCTAssertEqual(Array(opaque[center..<center+3]),[0,0,255],"Trainer wins equal-foot tie without erasing follower around it")
        trainer.opacity=0.5
        _ = buffer.withUnsafeMutableBufferPointer { pixels in
            BoundPresenceFrameCompositor.composite([trainer,follower],scene:scene,into:pixels.baseAddress!) { ghost=Array(pixels) }
        }
        XCTAssertEqual(Array(ghost[center..<center+3]),[127,0,128],"Passing blends over the actor behind it")
        XCTAssertEqual(buffer,original,"Overlapping translucent layers must restore in reverse order")
    }
}

import Foundation

/// Metadata for the actual native Pokémon follower. Its own sprite already
/// belongs to the game framebuffer; only a peer draws an additional sprite.
struct BoundPlayerFollower: Equatable, Sendable {
    let identity: UInt64
    let species: Int
    let objectID: Int
    let generation: UInt32
    let current: BoundPlayerState.Point
    let previous: BoundPlayerState.Point
    let worldFoot: BoundPlayerState.Point
    let elevation: Int
    let facing: Int
    let appearance: BoundPlayerSprite
}

/// A reader owns its cache independently of the video compositor. Core, ROM
/// profile and load timeline distinguish observations across native lifetimes.
struct BoundNativeFollowerScope: Equatable, Sendable {
    let core: ObjectIdentifier
    let profile: ObjectIdentifier
    let timeline: UInt64
}
struct BoundNativeFollowerObservation: Sendable {
    let cache: BoundNativeFollowerCache
    let scope: BoundNativeFollowerScope
}

/// A native publication may be interrupted by VBlank. Only committed selected
/// metadata survives at most three odd observations; live native ownership and
/// visibility still have to agree on every read.
final class BoundNativeFollowerCache: @unchecked Sendable {
    private let lock=NSLock()
    private var scope: BoundNativeFollowerScope?
    private var map: [UInt64]?
    private var committed: [UInt8]?
    private var interrupted=0

    func read(memory:BoundGBAMemorySnapshot,player:BoundPlayerState,scope:BoundNativeFollowerScope)->BoundNativeFollowerBinding? {
        lock.lock();defer { lock.unlock() }
        func clear() { committed=nil;interrupted=0 }
        guard (0...255).contains(player.mapGroup),(0...255).contains(player.mapNumber) else { clear();return nil }
        let currentMap=player.mapInstance.map { [$0,UInt64(player.mapGroup),UInt64(player.mapNumber)] }
        if self.scope != scope || map != currentMap { clear();self.scope=scope;map=currentMap }
        guard currentMap != nil,let bytes=memory.bytes(at:0x02002000,count:256) else { clear();return nil }
        func word(_ p:Int)->UInt32 { (0..<4).reduce(0) { $0|UInt32(bytes[p+$1])<<(8*$1) } }
        guard word(0)==0x314F5742,word(4)==1,word(8)>0 else { clear();return nil }
        if word(8)&1==0 {
            guard let value=BoundNativeFollowerBinding.read(memory:memory,player:player,publication:bytes) else { clear();return nil }
            committed=bytes;interrupted=0;return value
        }
        guard interrupted<3,let committed else { clear();return nil }
        let oldSequence=(0..<4).reduce(UInt32(0)) { $0|UInt32(committed[8+$1])<<(8*$1) }
        // A reader that was suspended cannot borrow metadata from an old map
        // visit merely because it first resumes during an interrupted write.
        let distance=word(8) &- oldSequence
        let oldVisit=(0..<4).reduce(UInt32(0)) { $0|UInt32(committed[16+$1])<<(8*$1) }
        guard distance>0,distance<=7,word(16)==oldVisit,
              let value=BoundNativeFollowerBinding.read(memory:memory,player:player,publication:committed) else { clear();return nil }
        interrupted+=1
        return value
    }
}

/// Read-only cross-check of the game-owned selected-follower publication.
/// Flag1055 is the Viridian Pokémon Center service; the other binding fields
/// distinguish its Pokémon from an unrelated CFRU NPC companion.
struct BoundNativeFollowerBinding: Equatable, Sendable {
    let identity: UInt64
    let species: Int
    let objectID: Int
    let partySlot: Int
    let generation: UInt32
    let spriteID: Int
    let current: BoundPlayerState.Point
    let previous: BoundPlayerState.Point
    let elevation: Int
    let facing: Int

    static func read(memory:BoundGBAMemorySnapshot,player:BoundPlayerState,publication:[UInt8]?=nil)->Self? {
        guard let bytes=publication ?? memory.bytes(at:0x02002000,count:256),bytes.count==256,
              let toggle=memory.bytes(at:0x0203B25E,count:1)?.first,toggle&0x20 != 0,
              let state=memory.bytes(at:0x0203B818,count:24) else { return nil }
        func word(_ b:[UInt8],_ p:Int)->UInt32 { (0..<4).reduce(0) { $0|UInt32(b[p+$1])<<(8*$1) } }
        func half(_ b:[UInt8],_ p:Int)->Int { Int(b[p])|Int(b[p+1])<<8 }
        guard word(bytes,0)==0x314F5742,word(bytes,4)==1,word(bytes,8)>0,word(bytes,8)&1==0,
              word(bytes,96)&3==3,word(bytes,100)<16,word(bytes,104)<6,
              (1...4095).contains(word(bytes,116)),word(bytes,120)<=65535,word(bytes,124)>0,
              bytes[32]==player.mapGroup,bytes[33]==player.mapNumber,
              let key=player.mapInstance,key==(UInt64(word(bytes,80))|UInt64(word(bytes,84))<<32),
              state[0]==1,state[1]==word(bytes,100),state[4]==20,state[5]==4,state[6]==5,
              word(state,12)==0x09049966,half(state,16)==0x1054,half(state,18)==word(bytes,120) else { return nil }
        let objectID=Int(word(bytes,100)),partySlot=Int(word(bytes,104))
        guard let count=memory.bytes(at:0x02024029,count:1)?.first,count<=6,partySlot<Int(count),
              let monData=memory.bytes(at:0x02024284+100*partySlot,count:100),
              let mon=BoundSoulMon.decode(Data(monData),stride:100).first,!mon.isEgg,(mon.hp ?? 0)>0,
              mon.identity.personality==word(bytes,108),mon.identity.trainer==word(bytes,112),mon.species==word(bytes,116),
              let object=memory.bytes(at:0x02036E38+36*objectID,count:36),object[0]&1 != 0,word(object,0)&(1<<13)==0,
              object[4]<64,Int(object[5])|Int(object[35])<<8==word(bytes,120),
              let sprite=memory.bytes(at:0x0202063C+68*Int(object[4]),count:68),half(sprite,0x2E)==objectID,
              half(sprite,0)&0x2F00==0,sprite[0x3F]&0x40==0,sprite[0x3E]&1==1,
              // Native sprite invisibility also means outside its owner's
              // camera. That must not remove a world actor from the peer's
              // camera or collision; explicit object invisibility still does.
              sprite[0x3E]&4==0 || word(object,0)&(1<<14) != 0,
              (1...4).contains(Int(object[24]&15)) else { return nil }
        let current=BoundPlayerState.Point(x:Int(Int16(bitPattern:UInt16(half(object,16))))-7,y:Int(Int16(bitPattern:UInt16(half(object,18))))-7)
        let previous=BoundPlayerState.Point(x:Int(Int16(bitPattern:UInt16(half(object,20))))-7,y:Int(Int16(bitPattern:UInt16(half(object,22))))-7)
        guard [current.x,current.y,previous.x,previous.y].allSatisfy({(-7...1030).contains($0)}) else { return nil }
        return .init(identity:UInt64(mon.identity.personality)<<32|UInt64(mon.identity.trainer),species:mon.species,
            objectID:objectID,partySlot:partySlot,generation:word(bytes,124),spriteID:Int(object[4]),current:current,previous:previous,
            elevation:Int(object[11]&15),facing:Int(object[24]&15))
    }
}

/// Optional presentation within the existing version1 presence pose. Eight
/// compact array fields stay below150 bytes at the admitted bounds. ROM tiles
/// are resolved by the receiving device; no images, RAM or gameplay state are
/// sent. Identity scopes follower interactions and never enrolls a Soul Link catch.
struct BoundPresenceFollower: Codable, Equatable, Sendable {
    let identity: UInt64
    let species: Int
    let objectID: Int
    let generation: UInt32
    var current: BoundPlayerState.Point
    var previous: BoundPlayerState.Point
    var x: Double
    var y: Double
    let elevation: Int
    let facing: Int
    let frameAddress: Int
    let palette: Data
    let width: Int
    let height: Int
    let flipX: Bool
    let flipY: Bool
    let priority: Int

    init?(reading: BoundPlayerStateReading) {
        guard reading.status == .live, let value = reading.player?.scene?.follower,
              let address = value.appearance.romAddress else { return nil }
        identity=value.identity; species=value.species; objectID=value.objectID; generation=value.generation
        current=value.current; previous=value.previous; x=Double(value.worldFoot.x); y=Double(value.worldFoot.y)
        elevation=value.elevation; facing=value.facing; frameAddress=address; palette=value.appearance.palette
        width=value.appearance.width; height=value.appearance.height
        flipX=value.appearance.flipX; flipY=value.appearance.flipY; priority=value.appearance.priority
        guard isValid else { return nil }
    }

    var isValid: Bool {
        (1...4095).contains(species) && generation>0 && (0..<16).contains(objectID) && (0...15).contains(elevation)
        && (1...4).contains(facing) && (0...3).contains(priority) && palette.count==32
        && [8,16,32,64].contains(width) && [8,16,32,64].contains(height)
        && x.isFinite && y.isFinite && (-104...1_048_592).contains(x) && (-96...1_048_592).contains(y)
        && [current.x,current.y,previous.x,previous.y].allSatisfy { (-7...1030).contains($0) }
        && abs(current.x-previous.x)+abs(current.y-previous.y)<=2
        && (Double(min(current.x,previous.x)*16+8-32)...Double(max(current.x,previous.x)*16+8+32)).contains(x)
        && (Double(min(current.y,previous.y)*16+16-32)...Double(max(current.y,previous.y)*16+16+32)).contains(y)
        && (0x08000000...(0x0A000000-width*height/2)).contains(frameAddress)
    }

    private static let sizes=[8,16,32,64]
    func encode(to encoder: Encoder) throws {
        guard isValid else { throw EncodingError.invalidValue(self,.init(codingPath:encoder.codingPath,debugDescription:"Invalid follower")) }
        var values=encoder.unkeyedContainer()
        let hex=String(identity,radix:16), token=String(repeating:"0",count:16-hex.count)+hex
        try values.encode(token)
        // Native positions are integer pixels; interpolation may use fractions.
        // Sixteenths preserve subpixel presentation without unbounded decimals.
        try values.encode((x*16).rounded()/16);try values.encode((y*16).rounded()/16)
        let points=[current.x,current.y,previous.x,previous.y]
        let tiles=points.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element+7) << (11*$1.offset) }
        try values.encode(tiles);try values.encode(frameAddress-0x08000000)
        // JSONEncoder may escape every slash in ordinary base64. URL-safe
        // base64 has a fixed44-byte bound even for an all-FF palette.
        try values.encode(palette.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_"))
        var flags=UInt32(objectID)|UInt32(species)<<4|UInt32(facing)<<16|UInt32(elevation)<<19|UInt32(priority)<<23
        flags |= (flipX ? 1:0)<<25;flags |= (flipY ? 1:0)<<26
        flags |= UInt32(Self.sizes.firstIndex(of:width)!)<<27;flags |= UInt32(Self.sizes.firstIndex(of:height)!)<<29
        try values.encode(flags);try values.encode(generation)
    }

    init(from decoder: Decoder) throws {
        var values=try decoder.unkeyedContainer()
        func invalid() -> DecodingError { .dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid follower")) }
        let token=try values.decode(String.self)
        guard token.utf8.count==16,token.utf8.allSatisfy({ (48...57).contains($0)||(97...102).contains($0) }),
              let identity=UInt64(token,radix:16) else { throw invalid() }
        self.identity=identity;x=try values.decode(Double.self);y=try values.decode(Double.self)
        let tiles=try values.decode(UInt64.self)
        guard tiles>>44==0 else { throw invalid() }
        current = .init(x:Int(tiles&2047)-7,y:Int((tiles>>11)&2047)-7)
        previous = .init(x:Int((tiles>>22)&2047)-7,y:Int((tiles>>33)&2047)-7)
        let address=try values.decode(UInt32.self)
        guard address<0x02000000 else { throw invalid() };frameAddress=Int(address)+0x08000000
        let encodedPalette=try values.decode(String.self)
        guard encodedPalette.utf8.count==44,
              let palette=Data(base64Encoded:encodedPalette.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")),
              palette.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_")==encodedPalette else { throw invalid() }
        self.palette=palette
        let flags=try values.decode(UInt32.self)
        guard flags>>31==0 else { throw invalid() }
        objectID=Int(flags&15);species=Int((flags>>4)&4095);facing=Int((flags>>16)&7)
        elevation=Int((flags>>19)&15);priority=Int((flags>>23)&3)
        flipX=flags&(1<<25) != 0;flipY=flags&(1<<26) != 0
        width=Self.sizes[Int((flags>>27)&3)];height=Self.sizes[Int((flags>>29)&3)]
        generation=try values.decode(UInt32.self)
        guard values.isAtEnd,isValid else { throw invalid() }
    }

    func rendered(profile: BoundPlayerROMProfile, viewer: BoundPlayerState,
                  mapGroup: Int, mapNumber: Int) -> BoundRecordedPlayerPose? {
        guard isValid,viewer.scene != nil,
              let offset=profile.sceneAssets.mapOffset(fromGroup:viewer.mapGroup,number:viewer.mapNumber,
                toGroup:mapGroup,number:mapNumber,rom:profile.bytes),
              let tiles=profile.bytes(at:frameAddress,count:width*height/2) else { return nil }
        return .init(mapGroup:viewer.mapGroup,mapNumber:viewer.mapNumber,elevation:elevation,
            x:x+Double(offset.x*16),y:y+Double(offset.y*16),
            appearance:.init(width:width,height:height,tiles:Data(tiles),palette:palette,
                flipX:flipX,flipY:flipY,priority:priority,romAddress:frameAddress))
    }
}

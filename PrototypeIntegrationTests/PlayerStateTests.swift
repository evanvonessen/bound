import XCTest
import UIKit
import CryptoKit
import DeltaCore
@testable import Delta

private final class PendingPlayerImageFixture {
    let core=NSObject(), profile=NSObject(), cache=BoundNativePresentationCache(), assets=BoundPlayerSceneAssets()
    var work=Data(repeating:0,count:0x40000), internalRAM=Data(repeating:0,count:0x8000)
    var rom:[Int:[UInt8]]=[:]
    let sprite=0x0202063C
    var scope:BoundNativePresentationScope { .init(core:ObjectIdentifier(core),profile:ObjectIdentifier(profile),timeline:1) }
    var player:BoundPlayerState {
        .init(mapGroup:3,mapNumber:1,tile:.init(x:6,y:6),previousTile:.init(x:6,y:6),
              facing:"North",elevation:3,graphicsID:0,runningState:2,tileTransitionState:1,mapInstance:1)
    }
    init() {
        put(0x8000|96,sprite,2);put(0x8000|112,sprite+2,2);put(2<<10,sprite+4,2)
        put(0x08010000,sprite+8);put(0x08011000,sprite+12);put(0x03007D60,sprite+20);put(0x0805B3B9,sprite+28)
        put(120,sprite+0x20,2);put(112,sprite+0x22,2);put(0xF8,sprite+0x28,1);put(0xF0,sprite+0x29,1)
        put(3,sprite+0x2B,1);put(3,sprite+0x3E,1);put(0x08001000,0x02036DFC);put(8,0x03000016,2)
        rom=[0x08001000:bytes(0)+bytes(0)+bytes(0)+bytes(0)+bytes(0x08002000)+bytes(0x08003000),
             0x08002000:bytes(0)+bytes(0x08004000),0x08003000:bytes(0)+bytes(0x08009000),
             0x08004000:Array(repeating:0,count:640*32),0x08009000:Array(repeating:0,count:384*32),
             0x08010000:bytes(0x08010100)+bytes(0x08010200),
             0x08010100:Array(repeating:bytes(11|(3<<16)),count:4).flatMap{$0},
             0x08010200:bytes(9|(5<<16)),
             0x08011000+11*8:bytes(0x08012000)+bytes(256),0x08011000+9*8:bytes(0x08013000)+bytes(256),
             0x08012000:Array(repeating:0x11,count:256),0x08013000:Array(repeating:0x22,count:256)]
    }
    func bytes(_ value:Int,_ count:Int=4)->[UInt8] { (0..<count).map{UInt8(truncatingIfNeeded:value>>($0*8))} }
    func put(_ value:Int,_ address:Int,_ count:Int=4) {
        if address>=0x03000000 { let offset=address-0x03000000;internalRAM.replaceSubrange(offset..<offset+count,with:bytes(value,count)) }
        else { let offset=address-0x02000000;work.replaceSubrange(offset..<offset+count,with:bytes(value,count)) }
    }
    func seek() { put(1,sprite+0x2A,1);put(255,sprite+0x2B,1) }
    func read(player:BoundPlayerState?=nil,scope:BoundNativePresentationScope?=nil,cached:Bool=true)->BoundPlayerScene? {
        var memory=BoundGBAMemorySnapshot(copyingWorkRAM:work,internalRAM:internalRAM)!
        if cached { memory.presentationObservation = .init(cache:cache,scope:scope ?? self.scope) }
        return BoundPlayerSceneDecoder.read(player:player ?? self.player,memory:memory,rom:{ address,count in
            for (base,data) in self.rom where address>=base && address-base<=data.count && count<=data.count-(address-base) {
                return Array(data[(address-base)..<(address-base+count)])
            }
            return nil
        },assets:assets)
    }
}

extension PlayerStateTests {
    func testPendingPlayerSeekRetainsPreviousImageOnceWithCurrentPaletteAndOAMAttributes() throws {
        let f=PendingPlayerImageFixture(), first=try XCTUnwrap(f.read())
        XCTAssertEqual(first.appearance.romAddress,0x08012000)
        f.seek();f.put(0xB0,f.sprite+3,1);f.put((1<<12)|(1<<10),f.sprite+4,2)
        f.put(0x1234,0x020375F8+512+32+2,2)
        let pending=try XCTUnwrap(f.read())
        XCTAssertEqual(pending.appearance.tiles,first.appearance.tiles)
        XCTAssertEqual(pending.appearance.romAddress,0x08012000,"New animation frame9 must not replace the retained displayed frame11")
        XCTAssertTrue(pending.appearance.flipX);XCTAssertTrue(pending.appearance.flipY);XCTAssertEqual(pending.appearance.priority,1)
        XCTAssertEqual(Array(pending.appearance.palette[2..<4]),[0x34,0x12])
        XCTAssertEqual(pending.worldFoot,first.worldFoot);XCTAssertEqual(pending.camera,first.camera)
        XCTAssertNil(f.read(),"A fallback must not refresh its one-observation allowance")
        XCTAssertNil(f.read())
        f.put(0,f.sprite+0x2B,1)
        XCTAssertEqual(try XCTUnwrap(f.read()).appearance.romAddress,0x08013000)
        f.seek();XCTAssertEqual(try XCTUnwrap(f.read()).appearance.romAddress,0x08013000)
    }

    func testPendingPlayerSeekRequiresPriorCompleteSceneAndFreshValidFirstFrame() throws {
        let f=PendingPlayerImageFixture();f.seek()
        XCTAssertNil(f.read());XCTAssertNil(f.read(cached:false))
        let ended=PendingPlayerImageFixture()
        ended.rom[0x08010100]! += ended.bytes(0xFFFF);ended.put(4,ended.sprite+0x2B,1)
        XCTAssertEqual(ended.read()?.appearance.romAddress,0x08012000,"Ordinary ANIM_END still resolves the preceding frame")
        for command in [64,254] {
            let f=PendingPlayerImageFixture();XCTAssertNotNil(f.read());f.put(command,f.sprite+0x2B,1);XCTAssertNil(f.read())
        }
        for invalid in 0..<4 {
            let f=PendingPlayerImageFixture();XCTAssertNotNil(f.read());f.seek()
            switch invalid {
            case 0:f.rom[0x08010200]=f.bytes(0xFFFF)
            case 1:f.rom[0x08010200]=f.bytes(64)
            case 2:f.rom[0x08011000+9*8]=f.bytes(0x08013000)+f.bytes(128)
            default:f.rom.removeValue(forKey:0x08013000)
            }
            XCTAssertNil(f.read());f.put(0,f.sprite+0x2A,1);XCTAssertNil(f.read(),"Invalid metadata clears prior appearance evidence")
        }
        // FF is written before these bits are cleared. Both early and late
        // native Seek prefixes must retain the same prior image.
        for delayAndPause in [0,5,0x40,0x45,0xC5] {
            for beginAndEnd in [0,4,0x10,0x14] {
                let f=PendingPlayerImageFixture();XCTAssertNotNil(f.read());f.seek()
                f.put(delayAndPause,f.sprite+0x2C,1);f.put(beginAndEnd|8,f.sprite+0x3F,1)
                XCTAssertEqual(f.read()?.appearance.romAddress,0x08012000)
            }
        }
    }

    func testPendingPlayerSeekRejectsIdentityAndLifecycleChanges() {
        for (offset,value,count) in [(8,0x08014000,4),(12,0x08015000,4),(20,0x03007D64,4),(28,0x0805B3BD,4),
                                      (4,1,2),(0x40,1,2),(0,96,2),(2,112,2)] {
            let f=PendingPlayerImageFixture();XCTAssertNotNil(f.read());f.seek();f.put(value,f.sprite+offset,count)
            if offset==8 { f.rom[value]=f.rom[0x08010000] }
            if offset==12 { f.rom[value+9*8]=f.rom[0x08011000+9*8];f.rom[value+11*8]=f.rom[0x08011000+11*8] }
            XCTAssertNil(f.read(),"Identity offset\(offset) must not borrow old image data")
        }
        for avatarOffset in [4,5] {
            let f=PendingPlayerImageFixture();XCTAssertNotNil(f.read());f.seek()
            if avatarOffset==4 {
                let bytes=Array(f.work[0x2063C..<0x2063C+68]);f.work.replaceSubrange(0x2063C+68..<0x2063C+136,with:bytes)
            }
            f.put(1,0x02037078+avatarOffset,1);XCTAssertNil(f.read())
        }
        for change in 0..<6 {
            let f=PendingPlayerImageFixture();XCTAssertNotNil(f.read());f.seek()
            let other=NSObject()
            let scope:BoundNativePresentationScope = .init(core:change==0 ? ObjectIdentifier(other):ObjectIdentifier(f.core),
                profile:change==1 ? ObjectIdentifier(other):ObjectIdentifier(f.profile),timeline:change==2 ? 2:1)
            let p=BoundPlayerState(mapGroup:3,mapNumber:change==3 ? 2:1,tile:f.player.tile,previousTile:f.player.previousTile,
                facing:"North",elevation:3,graphicsID:change==4 ? 1:0,runningState:2,tileTransitionState:1,mapInstance:change==5 ? 2:1)
            XCTAssertNil(f.read(player:p,scope:scope))
        }
        let f=PendingPlayerImageFixture();XCTAssertNotNil(f.read());f.seek();f.cache.reset();XCTAssertNil(f.read())
    }

    func testPendingPlayerSeekPreservesVisibilityCameraAndNativeSegmentGuards() {
        for (offset,value,count) in [(0,0x8100|96,2),(0x3E,2,1),(0x3E,7,1),(0x3E,1,1),(0x3F,0x40,1),
                                      (0x24,1,2),(0x26,1,2),(0x28,0xF0,1),(0x29,0xF8,1)] {
            let f=PendingPlayerImageFixture();XCTAssertNotNil(f.read());f.seek();f.put(value,f.sprite+offset,count)
            XCTAssertNil(f.read(),"Invalid native sprite offset\(offset) remains rejected")
        }
        let f=PendingPlayerImageFixture();XCTAssertNotNil(f.read());f.seek()
        f.put(17,0x03005060)
        XCTAssertNil(f.read(),"Retaining image data cannot admit a malformed camera")
        f.put(0,0x03005060);XCTAssertNil(f.read(),"A failed scene clears retained appearance")
        let displaced=PendingPlayerImageFixture();XCTAssertNotNil(displaced.read());displaced.seek()
        displaced.put(114,displaced.sprite,1)
        XCTAssertNil(displaced.read(),"Built foot outside the native segment remains rejected")
    }
}

private struct ResidualNormalizationFixture {
    typealias Point = BoundPlayerState.Point
    let core = NSObject(), profile = NSObject(), cache = BoundNativePresentationCache()
    var scope: BoundNativePresentationScope { .init(core: ObjectIdentifier(core), profile: ObjectIdentifier(profile), timeline: 1) }
    var player: BoundPlayerState {
        .init(mapGroup: 3, mapNumber: 1, tile: .init(x: 33, y: 20), previousTile: .init(x: 33, y: 20),
              facing: "West", elevation: 3, graphicsID: 0, runningState: 2, tileTransitionState: 1,
              mapInstance: 591385746614379492)
    }
    func bytes(speed: Point = .init(x: -2, y: 0), residual: Point = .init(x: -16, y: 0)) -> [UInt8] {
        [0x0805AB31, 3, speed.x, speed.y, residual.x, residual.y].flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
    }
    func seed() -> Point? {
        cache.camera(proposed: .init(x: -420, y: -248), appliedScroll: .init(x: 212, y: 40), desiredScroll: .init(x: 212, y: 40),
            liveFoot: .init(x: 120, y: 72), builtFoot: .init(x: 120, y: 72), map: .init(group: 3, number: 1),
            instance: player.mapInstance!, nativeTiles: .init(current: player.tile, previous: .init(x: 34, y: 20)),
            scope: scope, project: { _, _ in nil })
    }
    func observe(scope: BoundNativePresentationScope? = nil, map: BoundPlayerMapConnections.Map = .init(group: 3, number: 1),
                 instance: UInt64? = nil, applied: Point = .init(x: 210, y: 40), built: Point = .init(x: 120, y: 72),
                 coherent: Bool = false) -> Point? {
        cache.camera(proposed: .init(x: 9000, y: 9000), appliedScroll: applied, desiredScroll: applied,
            liveFoot: .init(x: built.x + (coherent ? 0 : -2), y: built.y), builtFoot: built, map: map,
            instance: instance ?? player.mapInstance!, nativeTiles: .init(current: player.tile, previous: player.previousTile),
            normalizingResidual: true, scope: scope ?? self.scope, project: { _, _ in .init(x: 0, y: 0) })
    }
}

extension PlayerStateTests {
    func testCapturedCameraResidualNormalizationUsesExistingAppliedScrollAndSegment() {
        let f = ResidualNormalizationFixture()
        XCTAssertTrue(BoundPlayerSceneDecoder.isPendingResidualNormalization(camera: f.bytes(), player: f.player,
            live: .init(x: 118, y: 72), built: .init(x: 120, y: 72), applied: .init(x: 210, y: 40), desired: .init(x: 210, y: 40)))
        XCTAssertEqual(f.seed(), .init(x: -420, y: -248))
        XCTAssertEqual(f.observe(), .init(x: -418, y: -248),
            "Frame1473's captured -16 intermediate keeps foot538 inside the prior33→34 segment; its raw camera is never used")
        XCTAssertEqual(f.observe(), .init(x: -418, y: -248), "An identical framebuffer remains the same admitted point")
    }

    func testCameraResidualNormalizationRejectsMalformedOrDifferentNativePhases() {
        let f = ResidualNormalizationFixture(), origin = ResidualNormalizationFixture.Point(x: 120, y: 72)
        func admitted(_ bytes: [UInt8], player: BoundPlayerState? = nil,
                      live: ResidualNormalizationFixture.Point = .init(x: 118, y: 72),
                      desired: ResidualNormalizationFixture.Point = .init(x: 210, y: 40)) -> Bool {
            BoundPlayerSceneDecoder.isPendingResidualNormalization(camera: bytes, player: player ?? f.player,
                live: live, built: origin, applied: .init(x: 210, y: 40), desired: desired)
        }
        for speed in [-2, -1, 1, 2] {
            XCTAssertTrue(admitted(f.bytes(speed: .init(x: speed, y: 0), residual: .init(x: speed < 0 ? -16 : 16, y: 0)),
                live: .init(x: 120 + speed, y: 72)))
            XCTAssertTrue(admitted(f.bytes(speed: .init(x: 0, y: speed), residual: .init(x: 0, y: speed < 0 ? -16 : 16)),
                live: .init(x: 120, y: 72 + speed)))
        }
        for residual in [-17, -15, 0, 15, 16, 17] { XCTAssertFalse(admitted(f.bytes(residual: .init(x: residual, y: 0)))) }
        for speed in [-3, 0, 1, 2, 3] { XCTAssertFalse(admitted(f.bytes(speed: .init(x: speed, y: 0)))) }
        XCTAssertFalse(admitted(f.bytes(speed: .init(x: -2, y: 1))))
        XCTAssertFalse(admitted(f.bytes(residual: .init(x: -16, y: 1))))
        XCTAssertFalse(admitted(f.bytes(), live: origin), "Coherent live/built positions are not this interrupted native phase")
        XCTAssertFalse(admitted(f.bytes(), desired: .init(x: 212, y: 40)))
        XCTAssertFalse(admitted(f.bytes(), desired: .init(x: 210, y: 42)))
        XCTAssertTrue(admitted(f.bytes(), desired: .init(x: 466, y: 296)), "Desired/applied equality is modulo256")
        for length in [0, 23, 25] { XCTAssertFalse(admitted(Array(f.bytes().prefix(length)) + (length == 25 ? [0] : []))) }
        for index in [0, 4] {
            var bytes = f.bytes(); bytes[index] = 0xFF; XCTAssertFalse(admitted(bytes))
        }
        var detachedCamera = f.bytes(); detachedCamera[4] = 0; XCTAssertFalse(admitted(detachedCamera))
        for (running, transition, previous) in [(0, 1, f.player.tile), (2, 0, f.player.tile), (2, 2, f.player.tile),
                                                (2, 1, .init(x: 34, y: 20)), (2, 1, .init(x: 33, y: 21))] {
            let player = BoundPlayerState(mapGroup: 3, mapNumber: 1, tile: f.player.tile, previousTile: previous,
                facing: "West", elevation: 3, graphicsID: 0, runningState: running, tileTransitionState: transition)
            XCTAssertFalse(admitted(f.bytes(), player: player))
        }
    }

    func testCameraResidualNormalizationCannotSeedRescopeOrBypassNativeSegmentBounds() {
        let f = ResidualNormalizationFixture()
        XCTAssertNil(f.observe(), "No unnormalized observation may establish a camera")
        func seed() { f.cache.reset(); XCTAssertNotNil(f.seed()) }
        seed(); XCTAssertNil(f.observe(coherent: true), "An unnormalized raw origin cannot reseed")
        seed(); XCTAssertNil(f.observe(instance: 123))
        seed(); XCTAssertNil(f.observe(map: .init(group: 3, number: 19)), "Even a connected seam cannot borrow an unnormalized origin")
        let otherCore = NSObject(), otherProfile = NSObject()
        for scope in [BoundNativePresentationScope(core: ObjectIdentifier(otherCore), profile: ObjectIdentifier(f.profile), timeline: 1),
                      .init(core: ObjectIdentifier(f.core), profile: ObjectIdentifier(otherProfile), timeline: 1),
                      .init(core: ObjectIdentifier(f.core), profile: ObjectIdentifier(f.profile), timeline: 2)] {
            seed(); XCTAssertNil(f.observe(scope: scope))
        }
        seed(); f.cache.reset(); XCTAssertNil(f.observe())
        seed(); XCTAssertNil(f.observe(applied: .init(x: 230, y: 40)), "Foot outside the current/prior segment remains invalid")
        XCTAssertNil(f.observe(), "Invalid presentation clears old evidence")
        seed(); XCTAssertNil(f.observe(built: .init(x: 120, y: 74)), "Horizontal segment evidence cannot hide a Y displacement")
    }
}

private struct ReaderFixture {
    var work = Data(repeating: 0, count: 0x40000)
    var internalRAM = Data(repeating: 0, count: 0x8000)
    var rom: [Int: [UInt8]] = [:]
    init() {
        put(0x08056535, at: 0x030030F0); put(0x080565B5, at: 0x030030F4)
        put(0x0202552C, at: 0x03005008)
        put(6, at: 0x0202552C, count: 2); put(6, at: 0x0202552E, count: 2)
        put(4, at: 0x02025530, count: 1); put(1, at: 0x02025531, count: 1)
        put(0x082D52FC, at: 0x02036DFC)
        put(0x10001, at: 0x02036E38)
        put(255, at: 0x02036E40, count: 1)
        put(1, at: 0x02036E41, count: 1); put(4, at: 0x02036E42, count: 1)
        for offset in [0x10, 0x12, 0x14, 0x16] { put(13, at: 0x02036E38 + offset, count: 2) }
        put(0x11, at: 0x02036E50, count: 1)
        put(3, at: 0x0202063C + 0x3E, count: 1)
        rom[0x083526B8] = Self.bytes(0x083523FC)
        rom[0x08352400] = Self.bytes(0x08350D6C)
        rom[0x08350D6C] = Array(work[0x36DFC..<0x36DFC + 28])
        rom[0x082D52FC] = Self.bytes(12) + Self.bytes(9)
    }
    static func bytes(_ value: Int, count: Int = 4) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    mutating func put(_ value: Int, at address: Int, count: Int = 4) {
        let bytes = Self.bytes(value, count: count)
        if address >= 0x03000000 { internalRAM.replaceSubrange(address - 0x03000000..<address - 0x03000000 + count, with: bytes) }
        else { work.replaceSubrange(address - 0x02000000..<address - 0x02000000 + count, with: bytes) }
    }
    func decode(frame: UInt64 = 1, presentationOnly: Bool = false) -> BoundPlayerStateReading {
        let snapshot = BoundGBAMemorySnapshot(copyingWorkRAM: work, internalRAM: internalRAM)!
        return BoundPlayerStateDecoder.decode(memory: snapshot, frame: frame, romBytes: { address, count in
            guard let value = rom[address], value.count == count else { return nil }; return value
        }, presentationOnly: presentationOnly)
    }
}

private struct ReaderGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

private final class ReaderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [BoundPlayerStateReading] = []
    func record(_ reading: BoundPlayerStateReading) { lock.lock(); readings.append(reading); lock.unlock() }
    func snapshot() -> [BoundPlayerStateReading] { lock.lock(); defer { lock.unlock() }; return readings }
}

@MainActor
final class PlayerStateTests: XCTestCase {
    func testDynamicReturnUsesCurrentOwnerSaveAndSignedWarpCoordinates() throws {
        var fixture = ReaderFixture()
        let warp = 0x0202552C + 0x14
        fixture.put(3, at: warp, count: 1)
        fixture.put(7, at: warp + 1, count: 1)
        fixture.put(-1, at: warp + 2, count: 1)
        fixture.put(-1, at: warp + 4, count: 2)
        fixture.put(12, at: warp + 6, count: 2)
        let player = try XCTUnwrap(fixture.decode().player)
        XCTAssertEqual(player.dynamicWarp, .init(mapGroup: 3, mapNumber: 7, warpID: -1, x: -1, y: 12))
        fixture.put(127, at: warp + 1, count: 1)
        XCTAssertNil(fixture.decode().player?.dynamicWarp, "A native dynamic sentinel is not a resolved destination")
        fixture.put(7, at: warp + 1, count: 1)
        fixture.put(-2, at: warp + 2, count: 1)
        XCTAssertNil(fixture.decode().player?.dynamicWarp)
    }
    func testROMIdentityAndNormalizedLiveCoordinates() throws {
        XCTAssertThrowsError(try BoundPlayerROMProfile(rom: Data(repeating: 0, count: 512)))
        let reading = ReaderFixture().decode()
        XCTAssertEqual(reading.status, .live)
        let player = try XCTUnwrap(reading.player)
        XCTAssertEqual(player.mapGroup, 4); XCTAssertEqual(player.mapNumber, 1)
        XCTAssertEqual(player.tile, .init(x: 6, y: 6))
        XCTAssertEqual(player.previousTile, player.tile)
        XCTAssertEqual(player.facing, "South")
    }

    func testPendingNativeStepKeepsFreshCoordinatesAndActualCameraTile() throws {
        for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
            var fixture = ReaderFixture()
            fixture.put(13 + dx, at: 0x02036E38 + 0x10, count: 2)
            fixture.put(13 + dy, at: 0x02036E38 + 0x12, count: 2)
            fixture.put(2, at: 0x02037078 + 2, count: 1)
            fixture.put(2, at: 0x02037078 + 3, count: 1)
            for presentationOnly in [false, true] {
                let player = try XCTUnwrap(fixture.decode(presentationOnly: presentationOnly).player)
                XCTAssertEqual(player.tile, .init(x: 6 + dx, y: 6 + dy))
                XCTAssertEqual(player.previousTile, .init(x: 6, y: 6))
                XCTAssertEqual(player.cameraTile, .init(x: 6, y: 6))
                XCTAssertEqual(player.runningState, 2)
                XCTAssertEqual(player.tileTransitionState, 2)
            }
        }
    }

    func testPendingNativeStepRejectsMalformedAndHiddenStates() {
        var pending = ReaderFixture()
        pending.put(12, at: 0x02036E38 + 0x12, count: 2)
        pending.put(2, at: 0x02037078 + 2, count: 1)
        pending.put(2, at: 0x02037078 + 3, count: 1)
        let mutations: [(Int, Int, Int)] = [
            (0x02036E38 + 0x10, 12, 2), // Diagonal destination.
            (0x02036E38 + 0x12, 11, 2), // Two-tile displacement.
            (0x02036E38 + 0x14, 12, 2), // Previous no longer equals saved camera.
            (0x02037078 + 2, 0, 1), (0x02037078 + 2, 1, 1),
            (0x02037078 + 3, 0, 1), (0x02037078 + 3, 1, 1),
            (0x02036E39, 32, 1), (0x0202063C + 0x3E, 7, 1),
            (0x02037ABF, 128, 1), (0x02036DFC, 0, 4),
            (0x02025531, 2, 1), // Save map does not own the verified header.
        ]
        for (address, value, count) in mutations {
            var fixture = pending
            fixture.put(value, at: address, count: count)
            XCTAssertNil(fixture.decode().player, String(format: "%08x = %d", address, value))
        }
    }

    func testPendingNativeStepOutsideCurrentMapRemainsPresentationOnly() throws {
        for (savedX, destinationX) in [(0, -1), (-1, 0), (11, 12), (12, 11)] {
            var fixture = ReaderFixture()
            fixture.put(savedX, at: 0x0202552C, count: 2)
            fixture.put(savedX + 7, at: 0x02036E38 + 0x14, count: 2)
            fixture.put(destinationX + 7, at: 0x02036E38 + 0x10, count: 2)
            fixture.put(2, at: 0x02037078 + 2, count: 1)
            fixture.put(2, at: 0x02037078 + 3, count: 1)
            XCTAssertEqual(fixture.decode().status, .invalidMemory)
            XCTAssertNotNil(fixture.decode(presentationOnly: true).player)
        }
    }

    func testPendingNativeStepDoesNotResetConsecutiveFrameAdmission() throws {
        var fixture = ReaderFixture(), tracker = BoundPlayerPresenceTracker()
        XCTAssertEqual(tracker.update(fixture.decode(frame: 1)).status, .waiting)
        XCTAssertEqual(tracker.update(fixture.decode(frame: 2)).status, .live)
        fixture.put(12, at: 0x02036E38 + 0x12, count: 2)
        fixture.put(2, at: 0x02037078 + 2, count: 1)
        fixture.put(2, at: 0x02037078 + 3, count: 1)
        let moving = try XCTUnwrap(tracker.update(fixture.decode(frame: 3)).player)
        XCTAssertEqual(moving.tile, .init(x: 6, y: 5))
        XCTAssertEqual(moving.cameraTile, .init(x: 6, y: 6))
        fixture.put(5, at: 0x0202552E, count: 2)
        let committed = try XCTUnwrap(tracker.update(fixture.decode(frame: 4)).player)
        XCTAssertEqual(committed.tile, moving.tile)
        XCTAssertNil(committed.cameraTile)
    }

    func testPendingBoundaryRebaseUsesDestinationCameraOrigin() throws {
        var fixture = ReaderFixture()
        fixture.put(0x08001000, at: 0x02036DFC + 12)
        fixture.rom[0x08350D6C] = Array(fixture.work[0x36DFC..<0x36DFC + 28])
        fixture.rom[0x08001000] = ReaderFixture.bytes(1) + ReaderFixture.bytes(0x08002000)
        fixture.rom[0x08002000] = ReaderFixture.bytes(2) + ReaderFixture.bytes(0) + [4, 2, 0, 0]
        fixture.rom[0x08352404] = ReaderFixture.bytes(0x08003000)
        fixture.rom[0x08003000] = ReaderFixture.bytes(0x08004000) + Array(repeating: 0, count: 24)
        fixture.rom[0x08004000] = ReaderFixture.bytes(12) + ReaderFixture.bytes(40)
        fixture.put(-1, at: 0x0202552E, count: 2)
        fixture.put(47, at: 0x02036E38 + 0x12, count: 2)
        fixture.put(46, at: 0x02036E38 + 0x16, count: 2)
        fixture.put(2, at: 0x02037078 + 2, count: 1)
        fixture.put(2, at: 0x02037078 + 3, count: 1)
        XCTAssertEqual(fixture.decode().status, .invalidMemory)
        let player = try XCTUnwrap(fixture.decode(presentationOnly: true).player)
        XCTAssertEqual(player.tile, .init(x: 6, y: 0))
        XCTAssertEqual(player.previousTile, .init(x: 6, y: -1))
        XCTAssertNil(player.cameraTile, "Native residuals use the rebased destination tile")
        fixture.put(-2, at: 0x0202552E, count: 2)
        XCTAssertNil(fixture.decode(presentationOnly: true).player)
    }

    func testBorrowedVBAViewsAreCopiedAndAddressTranslationIsBounded() throws {
        let work = UnsafeMutableRawPointer.allocate(byteCount: 0x40000, alignment: 4)
        let internalRAM = UnsafeMutableRawPointer.allocate(byteCount: 0x8000, alignment: 4)
        let palette = UnsafeMutableRawPointer.allocate(byteCount: 0x400, alignment: 4)
        defer { work.deallocate(); internalRAM.deallocate(); palette.deallocate() }
        work.initializeMemory(as: UInt8.self, repeating: 19, count: 0x40000)
        internalRAM.initializeMemory(as: UInt8.self, repeating: 27, count: 0x8000)
        palette.initializeMemory(as: UInt8.self, repeating: 43, count: 0x400)
        var requests: [(Int, Int)] = []
        let snapshot = try XCTUnwrap(BoundGBAMemorySnapshot.capture { address, count in
            requests.append((address, count))
            if address == 0x48000 { return Data(bytesNoCopy: palette, count: count, deallocator: .none) }
            return Data(bytesNoCopy: address == 0x8000 ? work : internalRAM, count: count, deallocator: .none)
        })
        work.storeBytes(of: UInt8(99), as: UInt8.self)
        internalRAM.storeBytes(of: UInt8(88), as: UInt8.self)
        palette.advanced(by: 0x200).storeBytes(of: UInt8(99), as: UInt8.self)
        XCTAssertEqual(requests.map { $0.0 }, [0x8000, 0, 0x48000])
        XCTAssertEqual(requests.map { $0.1 }, [0x40000, 0x8000, 0x400])
        XCTAssertEqual(snapshot.bytes(at: 0x02000000, count: 1), [19])
        XCTAssertEqual(snapshot.bytes(at: 0x03000000, count: 1), [27])
        XCTAssertEqual(snapshot.bytes(at: 0x05000200, count: 32), Array(repeating: 43, count: 32))
        XCTAssertNil(snapshot.bytes(at: 0x05000400, count: 1))
        for address in [0, 0x02040000, 0x03008000, 0x04000000] {
            XCTAssertNil(snapshot.bytes(at: address, count: 1))
        }
        XCTAssertNil(BoundGBAMemorySnapshot.capture { _, _ in Data() })
    }

    func testBattleMenuHiddenPlayerAndBlackFadeNeverExposeCoordinates() {
        let cases: [(Int, Int, Int, BoundPlayerStateReading.Status)] = [
            (0x03003529, 2, 1, .battle), (0x030030F4, 0, 4, .outsideOverworld),
            (0x02037ABF, 128, 1, .transition),
            // Fade active has cleared but its coefficient remains fully black.
            (0x02037ABC, 16 << 6, 2, .transition),
            (0x02036E39, 32, 1, .transition), (0x0202063C + 0x3E, 7, 1, .transition),
            (0x03005008, 0, 4, .invalidMemory), (0x0203707D, 16, 1, .invalidMemory),
            (0x0203707C, 64, 1, .invalidMemory), (0x0202552C, 7, 2, .invalidMemory),
            (0x02036E50, 0, 1, .invalidMemory), (0x02036DFC, 0, 4, .invalidMemory)
        ]
        for (address, value, count, status) in cases {
            var fixture = ReaderFixture(); fixture.put(value, at: address, count: count)
            let reading = fixture.decode()
            XCTAssertEqual(reading.status, status, String(format: "%08x", address))
            XCTAssertNil(reading.player)
        }
    }

    func testLiveSavePointerAndObjectSlotsAreFollowed() {
        var fixture = ReaderFixture()
        fixture.work.replaceSubrange(0x3E000..<0x3E00C, with: fixture.work[0x2552C..<0x25538])
        fixture.put(0x0203E000, at: 0x03005008)
        fixture.put(99, at: 0x0202552C, count: 2)
        fixture.work.replaceSubrange(0x36E38 + 72..<0x36E38 + 108, with: fixture.work[0x36E38..<0x36E38 + 36])
        fixture.put(0, at: 0x02036E38)
        fixture.put(2, at: 0x0203707D, count: 1)
        fixture.put(2, at: 0x0202063C + 0x2E, count: 2)
        XCTAssertEqual(fixture.decode().player?.tile, .init(x: 6, y: 6))
    }

    func testConnectedMapCrossingKeepsPlayerSpawnIdentityAndPublishesCurrentMap() throws {
        var fixture = ReaderFixture()
        // Native camera connections rebase this retained object's coordinates;
        // only a full object rebuild changes its spawn map 4:1.
        fixture.rom[0x08352404] = ReaderFixture.bytes(0x08350D6C)
        var tracker = BoundPlayerPresenceTracker()
        _ = tracker.update(fixture.decode(frame: 1))
        XCTAssertEqual(tracker.update(fixture.decode(frame: 2)).status, .live)
        fixture.put(2, at: 0x02025531, count: 1)
        XCTAssertEqual(fixture.decode().player?.mapNumber, 2)
        XCTAssertEqual(tracker.update(fixture.decode(frame: 3)).status, .waiting)
        XCTAssertEqual(tracker.update(fixture.decode(frame: 4)).player?.mapNumber, 2)
        fixture.put(7, at: 0x0202552C, count: 2)
        for offset in [0x10, 0x14] { fixture.put(14, at: 0x02036E38 + offset, count: 2) }
        XCTAssertEqual(tracker.update(fixture.decode(frame: 5)).player?.tile.x, 7)
        fixture.put(1, at: 0x02025531, count: 1)
        XCTAssertEqual(tracker.update(fixture.decode(frame: 6)).status, .waiting)
        XCTAssertEqual(tracker.update(fixture.decode(frame: 7)).player?.mapNumber, 1)
        // The authoritative header agreement and unique player/sprite ownership
        // remain mandatory even though spawn-map bytes are not live identity.
        fixture.put(3, at: 0x02025531, count: 1)
        XCTAssertEqual(fixture.decode().status, .invalidMemory)
    }

    func testConsecutiveFramesInvalidateOnGapRewindMapChangeAndBattle() {
        var tracker = BoundPlayerPresenceTracker()
        XCTAssertEqual(tracker.update(ReaderFixture().decode(frame: 1)).status, .waiting)
        XCTAssertEqual(tracker.update(ReaderFixture().decode(frame: 2)).status, .live)
        XCTAssertNil(tracker.update(ReaderFixture().decode(frame: 2)).player)
        XCTAssertEqual(tracker.update(ReaderFixture().decode(frame: 3)).status, .live)
        XCTAssertNil(tracker.update(ReaderFixture().decode(frame: 20)).player)
        XCTAssertNil(tracker.update(.inactive(.battle, "Battle", frame: 21)).player)
        XCTAssertNil(tracker.update(ReaderFixture().decode(frame: 22)).player)
        XCTAssertEqual(tracker.update(ReaderFixture().decode(frame: 23)).status, .live)
        XCTAssertNil(tracker.update(ReaderFixture().decode(frame: 1)).player)
        let player = ReaderFixture().decode().player!
        let differentMap = BoundPlayerState(mapGroup: 3, mapNumber: 0, tile: player.tile,
            previousTile: player.previousTile, facing: player.facing, elevation: 0, graphicsID: 0, runningState: 0, tileTransitionState: 0)
        XCTAssertNil(tracker.update(.init(frame: 2, status: .live, detail: "", player: differentMap)).player)
    }

    func testDisabledAndWrongOwnerProbeDoesNotReadRAM() {
        let probe = BoundVBAPlayerStateProbe(), owner = NSObject()
        probe.configure(coreID: ObjectIdentifier(owner), profile: nil, active: false, status: .disabled, detail: "Off")
        probe.receive(coreID: ObjectIdentifier(owner)) { _, _ in XCTFail("Disabled reader must not read RAM"); return nil }
        XCTAssertEqual(probe.takeLatest()?.status, .disabled)
        XCTAssertNil(probe.takeLatest())
    }

    func testHUDClearsCoordinatesAndPreferenceResetsAndExports() throws {
        let hud = BoundPlayerStateHUD()
        hud.update(ReaderFixture().decode())
        XCTAssertTrue(hud.text?.contains("Map 4:1") == true)
        XCTAssertTrue(hud.text?.contains("Position 6, 6") == true)
        XCTAssertTrue(hud.text?.contains("Facing South") == true)
        hud.update(.inactive(.paused, "Paused"))
        XCTAssertFalse(hud.text?.contains("6, 6") == true)
        XCTAssertEqual(hud.accessibilityValue, "paused")
        let name = "PlayerStatePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: BoundPlayerStatePreferences.key)
        let export = try BoundConfigurationExport.snapshot(defaults: defaults, mappings: [])
        let preferences = try XCTUnwrap(export["preferences"] as? [String: [String: Any]])
        XCTAssertEqual(preferences["settings"]?[BoundPlayerStatePreferences.key] as? Bool, true)
        Settings.resetPreferenceValues(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: BoundPlayerStatePreferences.key))
    }

    /// Opt-in private fixture, installed under the dedicated QA app's Documents.
    /// It is a disposable ROM and battery copy; neither is a bundled resource.
    func testActualRadicalRedColdBootAndMovementInVBAM() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiplayerValidation", isDirectory: true)
        let romURL = root.appendingPathComponent("RadicalRed.gba")
        guard FileManager.default.fileExists(atPath: romURL.path) else {
            throw XCTSkip("Install the private exact-ROM and disposable generated battery fixtures described in Docs/BOUND-MULTIPLAYER.md")
        }
        let rom = try Data(contentsOf: romURL)
        _ = try BoundPlayerROMProfile(rom: rom)
        let battery = root.appendingPathComponent("seed.sav")
        let workBattery = root.appendingPathComponent("vbam-test.sav")
        try Data(contentsOf: battery).write(to: workBattery, options: .atomic)
        let seedHash = SHA256.hash(data: try Data(contentsOf: battery))
        let core = try XCTUnwrap(EmulatorCore(game: ReaderGame(fileURL: romURL, gameSaveURL: workBattery), options: [.metal: true]))
        let oldPreference = UserDefaults.standard.object(forKey: BoundPlayerStatePreferences.key)
        let oldDeveloperPreference = UserDefaults.standard.object(forKey: BoundDeveloperFeatures.key)
        let oldMultiplayerPreference = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        UserDefaults.standard.set(true, forKey: BoundDeveloperFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), owner = UIViewController(), gameView = GameView()
        owner.view.backgroundColor = .black
        window.rootViewController = owner; window.makeKeyAndVisible()
        gameView.frame = CGRect(x: 0, y: 200, width: window.bounds.width, height: window.bounds.width * 2 / 3)
        owner.view.addSubview(gameView); core.add(gameView)
        let display = BoundPlayerStateDisplay(), recorder = ReaderRecorder()
        display.install(in: owner); display.bind(core: core)
        let probe = display.probe
        defer {
            display.stop(); _ = core.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible()
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: BoundPlayerStatePreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: BoundPlayerStatePreferences.key) }
            UserDefaults.standard.set(oldDeveloperPreference, forKey: BoundDeveloperFeatures.key)
            UserDefaults.standard.set(oldMultiplayerPreference, forKey: BoundMultiplayerFeatures.key)
        }
        let completed = expectation(description: "VBA-M reaches overworld and reads moving player")
        let setup = NativePlayerSceneSetup(core: core)
        // All counters and input scheduling below belong only to the core's owner.
        var frame = 0, movingSince: Int?, previousMask = 0, finished = false
        core.updateHandler = { core in
            frame += 1
            setup.receive(core)
            if let reading = probe.receive(core) {
                recorder.record(reading)
                if reading.status == .live, setup.isReady, movingSince == nil { movingSince = frame }
            }
            let mask: Int
            if let since = movingSince {
                let elapsed = frame - since
                mask = elapsed < 40 ? 32 : elapsed < 80 ? 64 : elapsed < 120 ? 16 : elapsed < 160 ? 128 : 0
                if elapsed >= 200, !finished { finished = true; completed.fulfill() }
            } else {
                mask = 0 // Bound setup starts the current cartridge automatically.
                if frame >= 7000, !finished { finished = true; completed.fulfill() }
            }
            for bit in [1, 8, 16, 32, 64, 128] where (mask & bit) != (previousMask & bit) {
                if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
                else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
            }
            previousMask = mask
        }
        core.rate = 8
        XCTAssertTrue(core.start())
        await fulfillment(of: [completed], timeout: 90)
        display.refreshDisplay(); display.layout(in: owner, gameView: gameView)
        XCTAssertEqual(display.hud.reading.status, .live)
        XCTAssertTrue(display.hud.text?.contains("VBA-M · Live") == true)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "VBA-M live player-state display"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: root.appendingPathComponent("vbam-reader-display.png"), options: .atomic)
        XCTAssertTrue(core.pause())
        display.refreshDisplay()
        XCTAssertEqual(display.hud.reading.status, .paused)
        XCTAssertNil(display.hud.reading.player)
        let readings = recorder.snapshot(), live = readings.compactMap(\.player)
        XCTAssertGreaterThan(live.count, 100)
        let first = try XCTUnwrap(live.first)
        XCTAssertEqual(first.mapGroup, 4); XCTAssertEqual(first.mapNumber, 1)
        XCTAssertEqual(first.tile, .init(x: 6, y: 6))
        XCTAssertEqual(Set(live.map(\.facing)), Set(["North", "South", "East", "West"]))
        XCTAssertTrue(live.contains { $0.tile != first.tile })
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: battery)), seedHash)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: romURL)), SHA256.hash(data: rom))
        _ = core.stop()
        XCTAssertEqual(core.state, .stopped)
        let summary: [String: Any] = ["engine": "VBA-M", "romSHA256": BoundPlayerROMProfile.supportedSHA256,
            "frames": readings.count, "liveFrames": live.count, "firstMap": [first.mapGroup, first.mapNumber],
            "firstTile": [first.tile.x, first.tile.y], "facings": Array(Set(live.map(\.facing))).sorted(),
            "moved": live.contains { $0.tile != first.tile }, "seedBatteryUnchanged": true]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("vbam-reader-report.json"), options: .atomic)
    }
}

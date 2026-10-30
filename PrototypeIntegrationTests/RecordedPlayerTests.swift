import XCTest
import UIKit
import CryptoKit
@preconcurrency import DeltaCore
@testable import Delta
@testable import class Delta.GameViewController

private struct ReplayGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

#if DEBUG && targetEnvironment(simulator)
/// Only native input and bounded numeric observation. The production coordinator
/// retains its complete callback chain, transport, reader and presentation owners.
private final class HostMovementTraceTape: @unchecked Sendable {
    private let lock = NSLock()
    private let movement: BoundMovementProbe
    private let soul: BoundSoulProbe
    private let scene: BoundVBAPlayerStateProbe
    private let faintedParty: Bool
    private var finalSoulMetrics: [String:UInt64]?
    private var afterStartupSoulMetrics: [String:UInt64]?
    private var finalSceneMetrics: [String:UInt64]?
    private var afterStartupSceneMetrics: [String:UInt64]?
    private let portDiagnostics = ProcessInfo.processInfo.environment["BOUND_HOST_PORT_DIAGNOSTICS"] == "1"
    private var limit = 0, count = 0, direction = 32, mask = 0
    private var moving = false, running = true, vertical = false
    init(movement: BoundMovementProbe, soul: BoundSoulProbe, scene: BoundVBAPlayerStateProbe, faintedParty: Bool = false) {
        self.movement = movement; self.soul = soul; self.scene = scene; self.faintedParty = faintedParty
    }
    func arm(frames: Int, moving: Bool, running: Bool, vertical: Bool) {
        lock.lock(); defer { lock.unlock() }
        limit = frames; count = 0; self.moving = moving; self.running = running; self.vertical = vertical
        direction = vertical ? 128:32; mask = 0
    }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return limit > 0 && count >= limit }
    var soulMetricsAtEnd: [String:UInt64]? { lock.lock(); defer { lock.unlock() }; return finalSoulMetrics }
    var soulMetricsAfterStartup: [String:UInt64]? { lock.lock(); defer { lock.unlock() }; return afterStartupSoulMetrics }
    var sceneMetricsAtEnd: [String:UInt64]? { lock.lock(); defer { lock.unlock() }; return finalSceneMetrics }
    var sceneMetricsAfterStartup: [String:UInt64]? { lock.lock(); defer { lock.unlock() }; return afterStartupSceneMetrics }
    /// Preserve the actual installed host policies and native runtime for
    /// bounded discovery. Only called while paused, outside the measured tape;
    /// never restore these buffers or mix them into another ROM/core state.
    @MainActor static func captureNativeContext(_ core: EmulatorCore, output: URL, sourceHash: String) throws {
        XCTAssertEqual(core.state,.paused)
        _ = try XCTUnwrap(core.state == .paused ? true:nil)
        let directory=output.appendingPathComponent("native-context",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        var files=[String:[String:Any]]()
        func preserve(_ name:String,_ data:Data) throws {
            try data.write(to:directory.appendingPathComponent(name),options:.withoutOverwriting)
            files[name] = ["bytes":data.count,"sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()]
        }
        for (name,size) in [("rom",0x2000000),("workRAM",0x40000),("internalRAM",0x8000),
                            ("ioMem",0x400),("paletteRAM",0x400),("vram",0x20000),("oam",0x400)] {
            let symbol=try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern:-2),name))
            var owner=Dl_info()
            XCTAssertNotEqual(dladdr(symbol,&owner),0)
            let path=String(cString:try XCTUnwrap(owner.dli_fname))
            XCTAssertTrue(path.hasSuffix("/GBADeltaCore.framework/GBADeltaCore"))
            _ = try XCTUnwrap(path.hasSuffix("/GBADeltaCore.framework/GBADeltaCore") ? true:nil)
            let pointer=try XCTUnwrap(symbol.assumingMemoryBound(to:UnsafeMutablePointer<UInt8>?.self).pointee)
            try preserve(name+".bin",Data(bytes:pointer,count:size))
        }
        let state=MultiRedAdapter.captureState()
        _ = try XCTUnwrap(state.isEmpty ? nil:true)
        try preserve("exact-runtime.state",state)
        let manifest:[String:Any] = ["schema":1,"sourceROM_SHA256":sourceHash,"files":files,
            "scope":"Paused exact app/core runtime before measured input, after native setup and paired readiness. Resident ROM includes installed host policies and hooks. Artifact-only diagnostic; no guest writes, restore or performance acceptance."]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("manifest.json"),options:.withoutOverwriting)
    }
    @MainActor static func writeSceneDiagnostics(_ value:(observed:Int,captures:[BoundVBAPlayerStateProbe.SceneFailureCapture]),
                                                 output:URL,sourceHash:String) throws {
        let directory=output.appendingPathComponent("scene-diagnostics",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        var files=[String:[String:Any]]()
        func preserve(_ name:String,_ data:Data) throws {
            try data.write(to:directory.appendingPathComponent(name),options:.withoutOverwriting)
            files[name]=["bytes":data.count,"sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()]
        }
        for (index,capture) in value.captures.enumerated() {
            let name="failure-\(index)"
            try FileManager.default.createDirectory(at:directory.appendingPathComponent(name),withIntermediateDirectories:false)
            try preserve(name+"/workRAM.bin",Data(capture.memory.workRAM))
            try preserve(name+"/internalRAM.bin",Data(capture.memory.internalRAM))
            try preserve(name+"/paletteRAM.bin",Data(try XCTUnwrap(capture.memory.paletteRAM)))
            try preserve(name+"/decision.json",JSONSerialization.data(withJSONObject:capture.decision,options:[.prettyPrinted,.sortedKeys]))
        }
        let manifest:[String:Any] = ["schema":1,"sourceROM_SHA256":sourceHash,"observedFailures":value.observed,
            "capturedCount":value.captures.count,"droppedFailures":value.observed-value.captures.count,"files":files,
            "scope":"DEBUG completed-owner nil-scene diagnosis, measured frames61...requestedFrames only. First four failures retain the reader's already-owned RAM and exact presentation-cache prestate/decision. No guest writes; serialization occurs after pause. Diagnostic only, not performance acceptance."]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("manifest.json"),options:.withoutOverwriting)
    }
    /// QA input uses the same tiny native object read in every mode. It does
    /// not depend on the experimental feature's admitted/cached world probe.
    static func rawTile(_ core: EmulatorCore) -> (x: Int, y: Int, group: Int, number: Int, cameraX:Int, cameraY:Int,
                                                previousX:Int, previousY:Int, running:Int, transition:Int)? {
        func bytes(_ at: Int, _ count: Int) -> [UInt8]? {
            guard let data = core.deltaCore.emulatorBridge.readMemory?(at: at, size: count), data.count == count else { return nil }
            return Array(data)
        }
        guard let avatar = bytes(0x8000+0x37078, 8), avatar[5] < 16,
              let object = bytes(0x8000+0x36E38+Int(avatar[5])*36, 36),
              BoundSceneBytes.word(object)&0x10001 == 0x10001, object[8] == 255,
              let pointer = bytes(0x5008, 4) else { return nil }
        let saveAddress = BoundSceneBytes.word(pointer)
        guard (0x02000000...0x0203FFF4).contains(saveAddress), saveAddress&3 == 0,
              let save = bytes(0x8000+saveAddress-0x02000000, 12) else { return nil }
        return (BoundSceneBytes.signed(object,0x10)-7, BoundSceneBytes.signed(object,0x12)-7, Int(save[4]), Int(save[5]),
                BoundSceneBytes.signed(save,0),BoundSceneBytes.signed(save,2),
                BoundSceneBytes.signed(object,0x14)-7,BoundSceneBytes.signed(object,0x16)-7,Int(avatar[2]),Int(avatar[3]))
    }
    func receive(_ core: EmulatorCore) {
        lock.lock(); defer { lock.unlock() }
        guard limit > 0, count < limit else { return }
        let trace = core.debugFrameTrace, started = ProcessInfo.processInfo.systemUptime
        let soulStatus = BoundVBABattleBridge.qaSoulPolicyStatus()
        trace?.record("qa.soulPolicy",value:Double(soulStatus&0xFFFFFFFF),detail:soulStatus>>32)
        trace?.record("qa.soulFence.afterOwner",value:BoundVBABattleBridge.qaSoulFrameBlocked() ? 1:0)
        if faintedParty,
           let count = core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x24029,size:1)?.first,
           let party = core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x24284,size:200), party.count == 200 {
            let hp0 = UInt64(party[86]) | UInt64(party[87])<<8
            let hp1 = UInt64(party[186]) | UInt64(party[187])<<8
            trace?.record("qa.faintedParty",value:Double(count),detail:hp0<<16|hp1)
        }
        if portDiagnostics, let trace { Self.observePort(core,trace:trace,frame:trace.currentFrame,phase:"afterOwner") }
        if let native = movement.read() {
            trace?.record("probe.cachedGuest", value: Double(native.frame), detail: UInt64(native.flags))
        }
        if let host = movement.hostInput() {
            trace?.record("probe.hostInput", value:Double(BoundMovementSnapshot.word(host,12)),detail:UInt64(BoundMovementSnapshot.word(host,68)))
        }
        if let native = Self.rawTile(core) {
            trace?.record("native.tileX", value: Double(native.x))
            trace?.record("native.tileY", value: Double(native.y))
            trace?.record("native.map", value: Double(native.group), detail: UInt64(native.number))
            if portDiagnostics {
                trace?.record("native.cameraTileX",value:Double(native.cameraX))
                trace?.record("native.cameraTileY",value:Double(native.cameraY))
                trace?.record("native.previousTile",value:Double(native.previousX),detail:UInt64(bitPattern:Int64(native.previousY)))
                trace?.record("native.movementState",value:Double(native.running),detail:UInt64(native.transition))
            }
            // Current is the committed step target; keep input held while that
            // step finishes, then reverse on the verified horizontal or
            // vertical field lane. The vertical endpoint stops before grass.
            if vertical {
                if native.y <= 20 { direction = 128 }
                if native.y >= 22 { direction = 64 }
            } else {
                if native.x <= 33 { direction = 16 }
                if native.x >= 36 { direction = 32 }
            }
        } else { trace?.record("native.tileMissing") }
        if let data = core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x2008,size:16), data.count == 16 {
            let raw = Array(data)
            // Unfenced writer bytes, distinct from the retained admitted probe.
            trace?.record("native.rawWorldFrame", value:Double(BoundSceneBytes.word(raw,4)),detail:UInt64(BoundSceneBytes.word(raw)))
            trace?.record("native.rawWorldFlags", value:Double(BoundSceneBytes.word(raw,12)),detail:UInt64(BoundSceneBytes.word(raw)))
        }
        if let enabled = core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x3B25E,size:1)?.first,
           let active = core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x3B818,size:1)?.first {
            trace?.record("native.followerActive",value:enabled&0x20 != 0 && active == 1 ? 1:0)
        }
        count += 1
        if count == 60 {
            afterStartupSoulMetrics = soul.observationMetrics()
            afterStartupSceneMetrics = scene.qaPlayerImageMetrics()
        }
        let next = count == limit || !moving ? 0 : direction | (running ? 2 : 0)
        trace?.record("qa.input", value: Double(mask), detail: UInt64(next))
        for bit in [2,16,32,64,128] where next & bit != mask & bit {
            if next & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
            else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
        }
        mask = next
        trace?.record("qa.controller", at: started, duration: ProcessInfo.processInfo.systemUptime - started)
        if count == limit {
            finalSoulMetrics = soul.observationMetrics()
            finalSceneMetrics = scene.qaPlayerImageMetrics()
            trace?.record("qa.measureEnd")
        }
    }
    static func observeVideo(_ core: EmulatorCore, trace: EmulatorFrameTrace, frame: UInt64) {
        let started = ProcessInfo.processInfo.systemUptime
        func bytes(_ at: Int, _ count: Int) -> [UInt8]? {
            guard let data = core.deltaCore.emulatorBridge.readMemory?(at: at, size: count), data.count == count else { return nil }
            return Array(data)
        }
        func half(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at+1]) << 8 }
        guard let avatar = bytes(0x8000+0x37078, 8), avatar[4] < 64,
              let sprite = bytes(0x8000+0x2063C+Int(avatar[4])*68, 68),
              let scroll = bytes(0x14, 4) else { trace.record("native.videoMissing", frame: frame); return }
        // Built sprite OAM, not live pos1/pos2. Same phase/registers as the
        // prior bitmap-matched native diagnostic; wrap at the GBA OAM widths.
        trace.record("native.builtX", frame: frame, value: Double(((half(sprite,2)&511)-Int(Int8(bitPattern:sprite[0x28])))&511))
        trace.record("native.builtFootY", frame: frame, value: Double(((half(sprite,0)&255)-Int(Int8(bitPattern:sprite[0x29]))+16)&255))
        trace.record("native.scrollX", frame: frame, value: Double(half(scroll,0)&255))
        trace.record("native.scrollY", frame: frame, value: Double(half(scroll,2)&255))
        trace.record("qa.videoObservation", frame: frame, at: started, duration: ProcessInfo.processInfo.systemUptime-started)
    }
    /// Read-only, exact native pinput/pauthority diagnostics for this pinned ROM.
    /// No guest writes, relaxed guards or retained authority. Opt-in600-frame
    /// discovery only; the ordinary host timing baseline does not run this scan.
    static func observePort(_ core: EmulatorCore, trace: EmulatorFrameTrace, frame: UInt64, phase: String) {
        let started = ProcessInfo.processInfo.systemUptime
        let host = BoundVBABattleBridge.qaWorldMovementHost()
        guard host.count == 1024,
              let state = core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x2000,size:256),state.count == 256 else {
            trace.record("qa.port.\(phase).missing",frame:frame);return
        }
        func word(_ data:Data,_ offset:Int)->UInt32 { BoundMovementSnapshot.word(data,offset) }
        func half(_ data:Data,_ offset:Int)->UInt32 { UInt32(data[offset])|UInt32(data[offset+1])<<8 }
        func key(_ data:Data,_ offset:Int)->UInt64 { UInt64(word(data,offset))|UInt64(word(data,offset+4))<<32 }
        func record(_ stage:String,_ value:Double=0,_ detail:UInt64=0) { trace.record("qa.port.\(phase).\(stage)",frame:frame,value:value,detail:detail) }
        var reject:UInt64=0
        if word(host,0) != 0x31574C42 || half(host,4) != 1 || half(host,6) != 0 { reject |= 1 }
        if word(host,8) == 0 || word(host,8)&1 != 0 { reject |= 2 }
        let flags=word(host,12),lease=word(host,16),count=word(host,68)
        if flags>3 || flags&1 == 0 || lease == 0 || lease>15 || count>2 { reject |= 4 }
        if word(host,24) == 0 || word(host,28) == 0 { reject |= 8 }
        var firstReserved:Int?
        for range in [40..<48,56..<64,67..<68,92..<128,192..<1024] {
            if let offset=range.first(where:{host[$0] != 0}) { firstReserved=firstReserved ?? offset;reject |= 16 }
        }
        if word(host,88)>3 { reject |= 32 }
        var kindMask:UInt32=0
        if count<=2 {
            for i in 0..<Int(count) {
                let offset=128+i*32,kind=UInt32(host[offset+13])
                if word(host,offset)>1 || host[offset+12]>15 || kind>1 || half(host,offset+14) != 0 || word(host,offset+28) != 0 { reject |= 64 }
                if kind<=1 { if kindMask&(1<<kind) != 0 { reject |= 128 };kindMask |= 1<<kind }
                let current=BoundMovementSnapshot.tile(host,offset+4),previous=BoundMovementSnapshot.tile(host,offset+8)
                if !current.valid || !previous.valid || current.distance(previous)>2 { reject |= 256 }
                record("actor\(i)",Double(word(host,offset)),key(host,offset+4))
                record("actor\(i)Meta",Double(half(host,offset+12)),key(host,offset+20))
            }
            for i in Int(count)..<2 where host[(128+i*32)..<(160+i*32)].contains(where:{$0 != 0}) { reject |= 512 }
        }
        var authority:UInt64=0
        if word(state,136)==0 || word(state,180)==0 || word(state,128)==0 { authority |= 1 }
        if word(host,20) != word(state,16) { authority |= 2 }
        if key(host,32) != key(state,140) || key(host,48) != key(state,140) { authority |= 4 }
        if word(host,64) != word(state,32)&0x00FFFFFF { authority |= 8 }
        if word(host,24) != word(state,152) || word(host,28) != word(state,156) { authority |= 16 }
        record("reject",Double(reject),UInt64(word(host,8)))
        record("authority",Double(authority),UInt64(word(state,8)))
        record("flags",Double(flags),UInt64(word(state,20)))
        record("lease",Double(lease),UInt64(word(state,128)))
        record("consumed",Double(word(state,132)),UInt64(word(state,76)))
        record("input",Double(word(state,180)),UInt64(word(state,136)))
        record("generation",Double(word(host,20)),UInt64(word(state,16)))
        record("map",Double(word(host,64)),UInt64(word(state,32)))
        record("ownEpoch",Double(word(host,24)),UInt64(word(state,152)))
        record("peerEpoch",Double(word(host,28)),UInt64(word(state,156)))
        record("ownKey",0,key(host,32));record("peerKey",0,key(host,48));record("nativeKey",0,key(state,140))
        if let firstReserved { record("reserved",Double(firstReserved),UInt64(host[firstReserved])) }
        trace.record("qa.port.\(phase).duration",frame:frame,at:started,duration:ProcessInfo.processInfo.systemUptime-started)
    }
}

extension RecordedPlayerTests {
    func testFullCoordinatorLocalHostFrameCadence() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BOUND_HOST_TRACE"] == "1", let path = env["BOUND_MOVEMENT_ROM"],
              let namespace = env["BOUND_PAIR_NAMESPACE"], UUID(uuidString: namespace) != nil,
              let peer = env["BOUND_PAIR_PEER"], ["A","B"].contains(peer),
              let port = env["BOUND_PAIR_PORT"].flatMap(Int.init), (1024...65535).contains(port),
              env["BOUND_PAIR_PRESENCE_ONLY"] == "1" else { throw XCTSkip("Explicit localhost host-trace fixture required") }
        let mode = env["BOUND_HOST_MODE"] ?? "no-peer"
        guard ["off","no-peer","peer"].contains(mode) else { throw XCTSkip("Unknown host trace mode") }
        let axis = env["BOUND_HOST_AXIS"] ?? "horizontal"
        guard ["horizontal","vertical"].contains(axis) else { throw XCTSkip("Unknown host movement axis") }
        let rate = Double(env["BOUND_HOST_RATE"] ?? "1") ?? 1
        let frames = Int(env["BOUND_HOST_FRAMES"] ?? "1800") ?? 1800
        guard [1.0,3.0].contains(rate), (120...21600).contains(frames) else { throw XCTSkip("Bounded1x/3x trace required") }
        let portDiagnostics = env["BOUND_HOST_PORT_DIAGNOSTICS"] == "1"
        let sceneDiagnostics = env["BOUND_HOST_SCENE_DIAGNOSTICS"] == "1"
        let followerRequested = env["BOUND_HOST_FOLLOWER"] == "1"
        let faintedPartyRequested = env["BOUND_HOST_FAINTED_PARTY"] == "1"
        let soulPolicyOption = env["BOUND_HOST_SOUL_POLICY"] ?? "0"
        guard ["0","1"].contains(soulPolicyOption) else { throw XCTSkip("Explicit Soul policy0/1 required") }
        let soulPolicyRequested = soulPolicyOption == "1"
        guard !portDiagnostics || frames<=600 else { throw XCTSkip("Port diagnostics are bounded to600 frames") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = SHA256.hash(data:image).map { String(format:"%02x",$0) }.joined()
        XCTAssertEqual(digest, try XCTUnwrap(env["BOUND_MOVEMENT_SHA256"]))
        _ = try BoundPlayerROMProfile(rom:image)
        let oldEnabled = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        let oldHUD = UserDefaults.standard.object(forKey: BoundPlayerStatePreferences.key)
        UserDefaults.standard.set(mode != "off", forKey: BoundMultiplayerFeatures.key)
        UserDefaults.standard.set(false, forKey: BoundPlayerStatePreferences.key)
        defer {
            UserDefaults.standard.set(oldEnabled, forKey: BoundMultiplayerFeatures.key)
            UserDefaults.standard.set(oldHUD, forKey: BoundPlayerStatePreferences.key)
        }
        let output = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("MovementHost-\(namespace)-\(peer)-\(mode)-\(rate)-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let battery = output.appendingPathComponent("disposable.sav")
        try Data(repeating:255,count:131072).write(to:battery)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let priorWindow = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        XCTAssertEqual(BoundLocalPairedTransport.qaInstanceDiagnostics().filter{$0["running"] as? Bool == true}.count,0)
        let owner = BoundCompanionCoordinator.makeHostTraceController()
        window.rootViewController = owner; window.windowLevel = .alert+1
        window.makeKeyAndVisible(); owner.loadViewIfNeeded()
        let coordinator = owner.boundCompanionForTesting
        XCTAssertTrue(coordinator.qaUsesLocalPairedFixture, "The explicit host-trace environment must select the local fixture")
        guard coordinator.account.session == nil else { throw XCTSkip("A dedicated simulator without a production account is required") }
        owner.game = ReplayGame(fileURL:URL(fileURLWithPath:path),gameSaveURL:battery)
        owner.view.layoutIfNeeded()
        let core = try XCTUnwrap(owner.emulatorCore)
        _ = core.pause(); core.audioManager.isEnabled = false
        var taskSoulConfigured = false
        defer {
            _ = core.pause(); core.debugFrameTrace = nil
            BoundLocalPairedTransport.qaSetTrace(nil)
            if taskSoulConfigured {
                // This probe and ledger belong only to this disposable core.
                // Flush/retire its actual policy before releasing the owner.
                do { try coordinator.sharing.soulLink.probe.endRun() }
                catch { XCTFail("Task Soul ledger teardown failed: \(error)") }
                XCTAssertTrue(coordinator.sharing.soulLink.probe.configure(core:nil,url:nil))
                BoundVBABattleBridge.closeSoulLink()
                let status = BoundVBABattleBridge.qaSoulPolicyStatus()
                XCTAssertEqual(status&13,0); XCTAssertEqual(status>>32,0)
                let cleanup:[String:Any] = ["flags":status&0xFFFFFFFF,"sequence":status>>32,"taskPolicyClosed":status&13 == 0 && status>>32 == 0]
                try? JSONSerialization.data(withJSONObject:cleanup,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("soul-teardown.json"))
            }
            _ = coordinator.stop(); _ = core.stop(); owner.game = nil
            window.rootViewController = nil; window.isHidden = true; priorWindow?.makeKeyAndVisible()
        }
        XCTAssertFalse(core.gameViews.isEmpty, "Use the production GameViewController's actual GameViews")
        let fullOwner = try XCTUnwrap(core.updateHandler)
        var options = BoundMultiplayerSetupOptions()
        options.name="RED"; options.gender=0; options.partnerName="BLUE"; options.partnerGender=0; options.rival="BLUE"
        options.difficulty=0; options.minimalGrinding=false; options.species=0; options.randomMoves=false; options.randomAbilities=false
        options.cheats=false; options.nicknames=true; options.debug=true; options.deleteSaveOnGameOver=true
        let setup = NativePlayerSceneSetup(core:core,debugPlayer:1,
            run:UUID(uuidString:"11111111-2222-3333-4444-555555555555")!,settings:options.settings,playerProfile:options.profile)
        core.updateHandler = { core in setup.receive(core); fullOwner(core) }
        core.rate = 8
        if core.state == .stopped { XCTAssertTrue(core.start()) } else { XCTAssertTrue(core.resume()) }
        let bootDeadline = ProcessInfo.processInfo.systemUptime+90
        while !setup.isReady, ProcessInfo.processInfo.systemUptime < bootDeadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(setup.isReady); XCTAssertTrue(core.pause())
        if followerRequested || soulPolicyRequested || faintedPartyRequested {
            let partyCount = try XCTUnwrap(core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x24029,size:1)?.first)
            if partyCount == 0 {
                XCTAssertTrue(BoundVBABattleBridge.qaStartNativePartyFixture())
                XCTAssertTrue(core.resume()); try await Task.sleep(for:.milliseconds(500)); XCTAssertTrue(core.pause())
            }
        }
        if faintedPartyRequested {
            // Existing disposable battle fixture: preserve the native-created
            // mon, add one distinct living sibling and faint slot zero.
            // Configure before enabling the follower or starting the ledger.
            XCTAssertTrue(BoundVBABattleBridge.qaConfigureBattleParty(2))
        }
        if followerRequested {
            // Enable through the actual native service, as in the guest pixel
            // replay. Keep the full coordinator owner active during setup.
            func memory() throws -> BoundGBAMemorySnapshot {
                try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory:{core.deltaCore.emulatorBridge.readMemory?(at:$0,size:$1)}))
            }
            XCTAssertTrue(BoundVBABattleBridge.qaWarpViridianFollowerService())
            XCTAssertTrue(core.resume()); try await Task.sleep(for:.seconds(1)); XCTAssertTrue(core.pause())
            core.deltaCore.emulatorBridge.activateInput(64,value:1,playerIndex:0)
            XCTAssertTrue(core.resume()); try await Task.sleep(for:.milliseconds(30))
            core.deltaCore.emulatorBridge.deactivateInput(64,playerIndex:0)
            try await Task.sleep(for:.milliseconds(100)); XCTAssertTrue(core.pause())
            var active = false
            for _ in 0..<14 {
                core.deltaCore.emulatorBridge.activateInput(1,value:1,playerIndex:0)
                XCTAssertTrue(core.resume()); try await Task.sleep(for:.milliseconds(100))
                core.deltaCore.emulatorBridge.deactivateInput(1,playerIndex:0)
                try await Task.sleep(for:.milliseconds(150)); XCTAssertTrue(core.pause())
                let m = try memory()
                active = m.workRAM[0x3B25E]&0x20 != 0 && m.workRAM[0x3B818] == 1
                if active { break }
            }
            XCTAssertTrue(active,"The native service must enable the actual follower before host measurement")
            if let png = core.videoManager.snapshot()?.pngData() {
                try png.write(to:output.appendingPathComponent("follower-service.png"))
            }
        }
        XCTAssertTrue(BoundVBABattleBridge.qaWarpViridianMartEntrance())
        coordinator.romMultiplayer.probe.setVerified(true)
        core.updateHandler = fullOwner; core.rate = 1
        XCTAssertTrue(core.resume()); try await Task.sleep(for:.seconds(2)); XCTAssertTrue(core.pause())
        if mode == "peer", peer == "B" {
            // A distinct native row avoids a synthetic occupancy override or
            // player collision changing A's continuous movement measurement.
            core.deltaCore.emulatorBridge.activateInput(128,value:1,playerIndex:0)
            XCTAssertTrue(core.resume())
            let deadline = ProcessInfo.processInfo.systemUptime+6
            while (coordinator.sharing.livePresence.movement.probe.read()?.current.y ?? 0) < 24,
                  ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for:.milliseconds(8)) }
            core.deltaCore.emulatorBridge.deactivateInput(128,playerIndex:0)
            try await Task.sleep(for:.milliseconds(200)); XCTAssertTrue(core.pause())
            XCTAssertEqual(coordinator.sharing.livePresence.movement.probe.read()?.current.y,24)
        }
        var soulSetup:[String:Any] = ["requested":soulPolicyRequested,"historyScope":"offlineNone"]
        if soulPolicyRequested {
            let soul = coordinator.sharing.soulLink.probe
            let ledgerURL = output.appendingPathComponent("host-soul.json")
            let gameID = UUID().uuidString
            let run = try XCTUnwrap(UUID(uuidString:namespace))
            let binding = SHA256.hash(data:Data("host-soul:\(namespace):\(peer):\(digest)".utf8)).map { String(format:"%02x",$0) }.joined()
            _ = try XCTUnwrap(soul.configure(core:core,url:ledgerURL,gameID:gameID) ? true:nil,
                              "The task Soul probe must own its explicit ledger before starting a policy")
            taskSoulConfigured = true
            soul.setVerified(true); soul.setNativeObservationAllowed(true)
            try soul.startPreparedRun(run:run,binding:binding)
            XCTAssertTrue(core.resume())
            let deadline = ProcessInfo.processInfo.systemUptime+30
            // Only fullOwner installs/observes/applies policy. Main reads its
            // published durable receipt, never native bytes while it runs.
            while ProcessInfo.processInfo.systemUptime < deadline {
                let snapshot = soul.read()
                if snapshot.error != nil || (snapshot.ready && !snapshot.mons.isEmpty && snapshot.ledger?.run == run
                    && snapshot.ledger?.binding == binding && snapshot.ledger?.ended == false) { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            if core.state == .running { XCTAssertTrue(core.pause()) }
            // A committed observation receipt can precede its next native
            // owner application. Resume that same owner, without installing
            // or forcing a policy from the test, until it has applied it.
            while soul.read().error == nil && BoundVBABattleBridge.qaSoulPolicyStatus()&13 != 13,
                  ProcessInfo.processInfo.systemUptime < deadline {
                XCTAssertTrue(core.resume()); try await Task.sleep(for:.milliseconds(100)); XCTAssertTrue(core.pause())
            }
            if faintedPartyRequested && mode != "off" {
                // Creating a fainted fixture legitimately creates a death
                // notice. Acknowledge its exact native batch before timing
                // steady field movement; never erase the durable notice.
                let beforeNotice = try XCTUnwrap(soul.read().ledger)
                let pending = try XCTUnwrap(beforeNotice.battleLosses?.pending)
                var sawActive = false, sawAcknowledgment = false, completed = false, presses = 0
                let noticeDeadline = ProcessInfo.processInfo.systemUptime+30
                XCTAssertTrue(core.resume())
                while ProcessInfo.processInfo.systemUptime < noticeDeadline {
                    let snapshot = soul.read()
                    if snapshot.nativeBattleLoss?.acknowledged == pending.id { sawAcknowledgment = true }
                    if sawAcknowledgment && snapshot.nativeBattleLoss?.active == false
                        && snapshot.ledger?.battleLosses?.notices.first(where:{$0.id == pending.id})?.announced == true {
                        completed = true; break
                    }
                    if snapshot.error != nil { break }
                    if snapshot.nativeBattleLoss?.active == true {
                        sawActive = true; presses += 1
                        core.deltaCore.emulatorBridge.activateInput(1,value:1,playerIndex:0)
                        try await Task.sleep(for:.milliseconds(50))
                        core.deltaCore.emulatorBridge.deactivateInput(1,playerIndex:0)
                        try await Task.sleep(for:.milliseconds(100))
                    } else { try await Task.sleep(for:.milliseconds(20)) }
                }
                core.deltaCore.emulatorBridge.deactivateInput(1,playerIndex:0)
                XCTAssertTrue(core.pause())
                let afterNotice = try XCTUnwrap(soul.read().ledger)
                let retained = afterNotice.dead == beforeNotice.dead && afterNotice.records == beforeNotice.records
                    && afterNotice.battleLosses?.notices.first(where:{$0.id == pending.id})?.slots == pending.slots
                let noticeProof:[String:Any] = ["id":pending.id.uuidString,"sawActive":sawActive,
                    "sawNativeAcknowledgment":sawAcknowledgment,"announced":completed,"nativeAPresses":presses,
                    "deathAndRecordsRetained":retained]
                try JSONSerialization.data(withJSONObject:noticeProof,options:[.prettyPrinted,.sortedKeys])
                    .write(to:output.appendingPathComponent("death-notice-setup.json"))
                guard sawActive && sawAcknowledgment && completed && retained else {
                    XCTFail("Acknowledge the actual fixture loss without discarding its durable history")
                    return
                }
                soulSetup["deathNoticeSetup"] = noticeProof
            }
            let ready = soul.read(), installed = BoundVBABattleBridge.qaSoulPolicyStatus()
            soulSetup.merge(["gameID":gameID,"run":run.uuidString,"binding":binding,"ready":ready.ready,
                "monCount":ready.mons.count,"error":ready.error as Any? ?? NSNull(),
                "flags":installed&0xFFFFFFFF,"sequence":installed>>32,
                "ledgerFile":"host-soul-ready.json","originalLedgerFile":"host-soul.json"]) { _,new in new }
            if let data = try? Data(contentsOf:ledgerURL) {
                try data.write(to:output.appendingPathComponent("host-soul-ready.json"))
                soulSetup["ledgerSHA256"] = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
                let ledger = try JSONDecoder().decode(BoundSoulLedger.self,from:data)
                XCTAssertTrue(ledger.valid); XCTAssertEqual(ledger.run,run); XCTAssertEqual(ledger.binding,binding); XCTAssertFalse(ledger.ended)
            } else { XCTFail("The actual Soul observation pipeline must persist its task ledger") }
            try JSONSerialization.data(withJSONObject:soulSetup,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("soul-setup.json"))
            XCTAssertTrue(ready.ready); XCTAssertGreaterThan(ready.mons.count,0); XCTAssertNil(ready.error)
            XCTAssertEqual(installed&15,13); XCTAssertGreaterThan(installed>>32,0); XCTAssertEqual((installed>>32)&1,0)
            _ = try XCTUnwrap(ready.ready && !ready.mons.isEmpty && ready.error == nil
                             && installed&15 == 13 && installed>>32>0 && (installed>>32)&1 == 0 ? true:nil,
                             "Do not measure before the actual Soul owner applies its durable receipt")
        } else {
            let status = BoundVBABattleBridge.qaSoulPolicyStatus()
            soulSetup["flags"] = status&0xFFFFFFFF; soulSetup["sequence"] = status>>32
            XCTAssertEqual(status&13,0); XCTAssertEqual(status>>32,0)
        }
        if mode != "off" {
            let deadline = ProcessInfo.processInfo.systemUptime+30
            while (!coordinator.sharing.joined || !coordinator.sharing.livePresence.connectionReaderCheck(at:ProcessInfo.processInfo.systemUptime).romVerified
                   || (mode == "peer" && (coordinator.sharing.livePresence.receivedPackets < 3
                       || coordinator.sharing.livePresence.movement.reconnecting
                       || (coordinator.sharing.livePresence.movement.probe.read()?.flags ?? 0)&7 != 7))),
                  ProcessInfo.processInfo.systemUptime < deadline {
                if core.state == .paused { _ = core.resume() }
                try await Task.sleep(for:.milliseconds(20))
            }
            if core.state == .running { XCTAssertTrue(core.pause()) }
            XCTAssertTrue(coordinator.sharing.joined)
            XCTAssertTrue(coordinator.sharing.livePresence.connectionReaderCheck(at:ProcessInfo.processInfo.systemUptime).romVerified)
            if mode == "peer" {
                XCTAssertNotNil(coordinator.sharing.livePresence.peerEpoch); XCTAssertGreaterThanOrEqual(coordinator.sharing.livePresence.receivedPackets,3)
                XCTAssertFalse(coordinator.sharing.livePresence.movement.reconnecting)
                XCTAssertEqual((coordinator.sharing.livePresence.movement.probe.read()?.flags ?? 0)&7,7)
                XCTAssertNotNil(coordinator.sharing.livePresence.movement.probe.hostInput())
            }
        }
        func rendezvous(_ phase: String) async throws {
            let url = try XCTUnwrap(URL(string:"http://127.0.0.1:\(port)/\(phase)/\(namespace.uppercased())/\(peer)"))
            var request = URLRequest(url:url); request.httpMethod = "PUT"; request.httpBody = Data()
            let (_, response) = try await URLSession.shared.data(for:request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            let deadline = ProcessInfo.processInfo.systemUptime+40
            var bothReady = false
            while !bothReady, ProcessInfo.processInfo.systemUptime < deadline {
                let (data, _) = try await URLSession.shared.data(from:url)
                let value = try JSONSerialization.jsonObject(with:data) as? [String:[String]]
                bothReady = value?["ready"] == ["A","B"]
                if !bothReady { try await Task.sleep(for:.milliseconds(50)) }
            }
            XCTAssertTrue(bothReady)
        }
        if mode == "peer" {
            // A fresh namespace is required for every invocation. Both peers
            // remain live until setup and the native control handshake finish.
            XCTAssertTrue(core.resume()); try await rendezvous("ready"); XCTAssertTrue(core.pause())
        }
        let startTile = try XCTUnwrap(HostMovementTraceTape.rawTile(core))
        let fixtureInstances = BoundLocalPairedTransport.qaInstanceDiagnostics()
        XCTAssertEqual(fixtureInstances.filter{$0["running"] as? Bool == true}.count,1,"Exactly one fixture publisher may own this simulator process")
        XCTAssertEqual(startTile.group,3); XCTAssertEqual(startTile.number,1)
        XCTAssertEqual(startTile.x,36); XCTAssertEqual(startTile.y,mode == "peer" && peer == "B" ? 24:20)
        if portDiagnostics { try HostMovementTraceTape.captureNativeContext(core,output:output,sourceHash:digest) }
        // Long acceptance must cross the retained native deadline failure
        // beyond frame13000. Keep a fixed upper bound and preserve every event;
        // the existing dropped-event and per-frame gates still fail closed.
        let trace = EmulatorFrameTrace(capacity:max(250_000,frames*72))
        let soulMetricsBefore = coordinator.sharing.soulLink.probe.observationMetrics()
        let sceneMetricsBefore = coordinator.playerStateDisplay.probe.qaPlayerImageMetrics()
        let tape = HostMovementTraceTape(movement:coordinator.sharing.livePresence.movement.probe,
                                         soul:coordinator.sharing.soulLink.probe,
                                         scene:coordinator.playerStateDisplay.probe,
                                         faintedParty:faintedPartyRequested)
        trace.observeVideo = { [weak core, weak trace] frame in
            if let core, let trace {
                HostMovementTraceTape.observeVideo(core,trace:trace,frame:frame)
                if portDiagnostics { HostMovementTraceTape.observePort(core,trace:trace,frame:frame,phase:"video") }
            }
        }
        core.debugFrameTrace = trace
        if portDiagnostics { BoundLocalPairedTransport.qaSetTrace(trace) }
        core.updateHandler = { core in
            core.debugFrameTrace?.record("qa.soulFence.beforeOwner",value:BoundVBABattleBridge.qaSoulFrameBlocked() ? 1:0)
            if portDiagnostics, let trace=core.debugFrameTrace { HostMovementTraceTape.observePort(core,trace:trace,frame:trace.currentFrame,phase:"beforeOwner") }
            fullOwner(core); tape.receive(core)
        }
        tape.arm(frames:frames,moving:peer == "A" || mode != "peer",running:env["BOUND_HOST_WALK"] != "1",vertical:axis == "vertical")
        coordinator.playerStateDisplay.probe.qaConfigureSceneDiagnostics(frames:sceneDiagnostics ? 61...UInt64(frames):nil)
        core.rate = rate
        XCTAssertTrue(core.resume())
        let deadline = ProcessInfo.processInfo.systemUptime+Double(frames)/rate/30+20
        while !tape.finished, ProcessInfo.processInfo.systemUptime < deadline {
            if portDiagnostics {
                let now=ProcessInfo.processInfo.systemUptime
                let presence=coordinator.sharing.livePresence, check=presence.connectionReaderCheck(at:now)
                trace.record("main.reader.\(check.status)",value:check.localPoseFresh ? 1:0,
                             detail:UInt64(check.lastReceiveAgeMS ?? 1_000_000))
                trace.record("main.movement",value:presence.movement.reconnecting ? 1:0,
                             detail:presence.movementContext(at:now) == nil ? 0:1)
                trace.record("main.presence",value:Double(check.sent),detail:UInt64(check.received))
            }
            try await Task.sleep(for:.milliseconds(20))
        }
        _ = try XCTUnwrap(tape.finished ? true:nil,"Do not announce completion before the measured tape ends")
        let finishRendezvousStartedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(core.state,.running)
        if mode == "peer" {
            // The faster peer must keep its real native/presence/control lane
            // continuously running until both tapes finish. Even a brief pause
            // publishes an inactive reader and can revoke the other peer's
            // authority during its final measured frames. receive() is bounded
            // by its tape limit and has already released this peer's input.
            try await rendezvous("finished")
        }
        let finishRendezvousEndedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(core.state,.running)
        let finalPauseStartedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(core.pause())
        core.debugFrameTrace = nil
        BoundLocalPairedTransport.qaSetTrace(nil)
        if sceneDiagnostics {
            try HostMovementTraceTape.writeSceneDiagnostics(coordinator.playerStateDisplay.probe.qaSceneDiagnostics(),
                                                           output:output,sourceHash:digest)
        }
        try await Task.sleep(for:.milliseconds(300))
        let events = trace.snapshot()
        try JSONEncoder().encode(events).write(to:output.appendingPathComponent("events.json"))
        let stages = Dictionary(grouping:events,by:\.stage).mapValues(\.count)
        let activeHostSamples = events.filter{$0.stage == "probe.cachedGuest" && $0.detail&7 == 7}.count
        let blockedSamples = events.filter{$0.stage == "probe.cachedGuest" && $0.detail&(32|64) != 0}.count
        let report: [String:Any] = ["romSHA256":digest,"namespace":namespace,"peer":peer,"mode":mode,"axis":axis,"rate":rate,
            "requestedFrames":frames,"finished":tape.finished,"droppedTraceEvents":trace.droppedEvents,"stages":stages,
            "joined":coordinator.sharing.joined,"peerConfirmed":coordinator.sharing.livePresence.peerEpoch != nil,
            "presenceSent":coordinator.sharing.livePresence.sentPackets,"presenceReceived":coordinator.sharing.livePresence.receivedPackets,
            "nativeActiveHostSamples":activeHostSamples,"nativeBlockedSamples":blockedSamples,
            "portDiagnostics":portDiagnostics,
            "sceneDiagnostics":sceneDiagnostics,
            "fixtureInstances":BoundLocalPairedTransport.qaInstanceDiagnostics(),
            "gameViews":core.gameViews.count,"output":output.path,
            "nativeFollowerRequested":followerRequested,"settings":options.settings.base64EncodedString(),
            "faintedPartyRequested":faintedPartyRequested,
            "finishLifecycle":["schema":1,"keptRunningThroughPeerFinish":mode == "peer",
                "rendezvousStartedAt":finishRendezvousStartedAt,"rendezvousEndedAt":finishRendezvousEndedAt,
                "finalPauseStartedAt":finalPauseStartedAt,
                "scope":"No pause, trace detach, or owner replacement between the measured tape end and finished rendezvous. The exact measured interval ends at qa.measureEnd; later frame and asynchronous render events remain bounded and retained."],
            "soulPolicyRequested":soulPolicyRequested,"soulPolicySetup":soulSetup,
            "soulObservationBefore":soulMetricsBefore,"soulObservationAfter":try XCTUnwrap(tape.soulMetricsAtEnd),
            "soulObservationAfterStartup":try XCTUnwrap(tape.soulMetricsAfterStartup),
            "playerImageObservationBefore":sceneMetricsBefore,
            "playerImageObservationAfterStartup":try XCTUnwrap(tape.sceneMetricsAfterStartup),
            "playerImageObservationAfter":try XCTUnwrap(tape.sceneMetricsAtEnd),
            "playerImageObservationScope":"DEBUG pending-image decoder counters at the same measured-owner boundaries as Soul metrics; scene and authority gates independently establish complete-frame acceptance.",
            "soulObservationInterval":"Before trace, after measured owner60, and after the final measured owner; all before peer rendezvous/drain.",
            "soulPolicyScope":"Optional production probe with a task-owned durable offline ledger; no paired battle history or backend admission. Status is observed after the full frame owner, not inferred from settings.",
            "scope":"Production GameViewController/coordinator/updateHandler and GameView rendering; exact-ROM native input, published-ABI cold fixture, UUID-scoped localhost presence and ordered control packets including the real movement handshake. Requested follower uses native service dialogue and per-frame observation; otherwise it retains the cold-boot setting. No backend account/server-save admission or physical phone scanout. Metal presentCommandCompleted is presentation-command-buffer completion, not drawable presentation or Core Image completion; GL draw is handoff only. Crop frames at qa.measureEnd; probe.cachedGuest is admitted cached state, native.rawWorldFrame/Flags are unfenced with writer sequence in detail."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("summary.json"))
        XCTAssertTrue(tape.finished); XCTAssertEqual(trace.droppedEvents,0)
        XCTAssertEqual(BoundLocalPairedTransport.qaInstanceDiagnostics().filter{$0["running"] as? Bool == true}.count,1)
        if mode == "peer" { XCTAssertGreaterThan(activeHostSamples,frames*9/10); XCTAssertGreaterThan(stages["probe.hostInput"] ?? 0,frames*9/10) }
        else { XCTAssertEqual(activeHostSamples,0) }
        XCTAssertEqual(blockedSamples,0)
        XCTAssertEqual(stages["native.tileX"],frames); XCTAssertEqual(stages["native.tileMissing"] ?? 0,0)
        let stationary = mode == "peer" && peer == "B"
        XCTAssertTrue(events.filter{$0.stage == "native.tileX"}.allSatisfy{
            axis == "vertical" || stationary ? Int($0.value) == 36:(33...36).contains(Int($0.value))})
        XCTAssertTrue(events.filter{$0.stage == "native.tileY"}.allSatisfy{
            stationary ? Int($0.value) == 24:(axis == "vertical" ? (20...22).contains(Int($0.value)):Int($0.value) == 20)})
        XCTAssertTrue(events.filter{$0.stage == "native.map"}.allSatisfy{$0.value == 3 && $0.detail == 1})
        let measuredIDs = events.filter{$0.stage == "qa.input"}.map(\.frame)
        let postStartup = Set(measuredIDs.dropFirst(60))
        let soulRows = events.filter{$0.stage == "qa.soulPolicy" && postStartup.contains($0.frame)}
        XCTAssertEqual(soulRows.map(\.frame),Array(measuredIDs.dropFirst(60)))
        XCTAssertTrue(soulRows.allSatisfy { soulPolicyRequested
            ? UInt64($0.value) == 13 && $0.detail>0 && $0.detail&1 == 0
            : UInt64($0.value)&13 == 0 && $0.detail == 0 })
        for stage in ["qa.soulFence.beforeOwner","qa.soulFence.afterOwner"] {
            let rows = events.filter{$0.stage == stage && postStartup.contains($0.frame)}
            XCTAssertEqual(rows.map(\.frame),Array(measuredIDs.dropFirst(60)))
            XCTAssertTrue(rows.allSatisfy{$0.value == 0},"Routine field movement must not close the Soul frame fence")
        }
        if faintedPartyRequested {
            let rows = events.filter{$0.stage == "qa.faintedParty" && postStartup.contains($0.frame)}
            XCTAssertEqual(rows.map(\.frame),Array(measuredIDs.dropFirst(60)))
            XCTAssertTrue(rows.allSatisfy{$0.value == 2 && $0.detail>>16 == 0 && $0.detail&0xFFFF>0})
        }
        for stage in ["owner.romService","owner.movement","owner.world","owner.reader","owner.cooperative","owner.soul","owner.battle","render.request","render.accept","view.input"] { XCTAssertGreaterThan(stages[stage] ?? 0,0,stage) }
        XCTAssertGreaterThan((stages["view.metal.commit"] ?? 0)+(stages["view.gl.draw"] ?? 0),0)
        print("MOVEMENT_HOST_TRACE",output.path)
    }
}
#endif

/// Current cartridges require Bound's admitted New Game data, not a legacy
/// Continue button sequence. Only the published host ABI is written; the ROM
/// performs its own intro, settings, map and player initialization.
final class NativePlayerSceneSetup {
    private let probe = BoundROMMultiplayerProbe()
    private var host = BoundROMHostState()
    private var frames = 0
    var request: BoundROMRequest? { probe.read() }
    var isReady: Bool {
        guard let request else { return false }
        return request.permitsFieldInterruption && request.settingsApplied
    }

    init(core: EmulatorCore, debugPlayer: UInt8 = 0, run: UUID = UUID(),
         localSeed: UInt32 = 0x12345678, partnerSeed: UInt32 = 0x87654321,
         settings: Data? = nil, playerProfile: BoundNakamaRunService.PlayerProfile? = nil,
         chooser: Bool = false) {
        var options = BoundMultiplayerSetupOptions()
        options.debug = debugPlayer != 0
        host.debugPlayer = debugPlayer
        host.enabled = true; host.linked = true; host.setupCommitted = true
        host.externalSetup = true; host.status = .complete; host.run = run; host.chooser = chooser
        host.localSeed = localSeed; host.partnerSeed = partnerSeed
        host.settings = settings ?? options.settings; host.playerProfile = playerProfile ?? options.profile
        probe.configure(core: core); probe.setVerified(true)
    }

    // Accessed only from the emulator's completed-frame callback after init.
    func receive(_ core: EmulatorCore) {
        if frames % 60 == 0 { probe.publish(host) }
        frames += 1; probe.receive(core)
        // The bedroom can report field callbacks before the native first-options
        // continuation. Keep admission until settings and that continuation end.
        if let request = probe.read(), request.settingsApplied, request.permitsFieldInterruption {
            host.externalSetup = false
        }
    }
}

private final class ReplayReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BoundPlayerStateReading] = []
    func append(_ value: BoundPlayerStateReading) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [BoundPlayerStateReading] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class PresenceVideoCadenceReadings: @unchecked Sendable {
    private let lock=NSLock()
    private var rows=[[String:Double]]()
    private var start=0.0,origin=0.0,speed=0.0
    func arm(start:Double,origin:Double,speed:Double) {
        lock.lock();defer{lock.unlock()};rows=[];self.start=start;self.origin=origin;self.speed=speed
    }
    func append(_ reading:BoundPlayerStateReading,_ pose:BoundRecordedPlayerPose?,_ pixels:Int) {
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock();defer{lock.unlock()}
        guard now>=start+0.2 else{return}
        var row:[String:Double]=["time":now,"elapsed":now-start,"pixels":Double(pixels),"scene":reading.player?.scene == nil ? 0:1]
        if let pose {row["x"]=pose.x;row["y"]=pose.y;row["expectedX"]=origin+speed*(now-start-0.1)}
        rows.append(row)
    }
    func snapshot()->[[String:Double]] {lock.lock();defer{lock.unlock()};return rows}
    static func metrics(_ rows:[[String:Double]])->[String:Double] {
        let poses=rows.filter{$0["x"] != nil},pairs=Array(zip(poses,poses.dropFirst()))
        let repeated=pairs.filter{abs($0["x"]!-$1["x"]!)<0.00001}.count
        let errors=poses.map{abs($0["x"]!-$0["expectedX"]!)}.sorted()
        let steps=pairs.map{abs($1["x"]!-$0["x"]!)}.sorted()
        func q(_ values:[Double],_ fraction:Double)->Double {values.isEmpty ? 0:values[Int(Double(values.count-1)*fraction)]}
        return ["frames":Double(rows.count),"resolvedFrames":Double(poses.count),
            "visibleFrames":Double(rows.filter{($0["pixels"] ?? 0)>0}.count),
            "repeatedPositionRatio":Double(repeated)/Double(max(1,pairs.count)),
            "p95PositionErrorPixels":q(errors,0.95),"maxPositionErrorPixels":errors.last ?? 0,
            "p95StepPixels":q(steps,0.95),"maximumStepPixels":steps.last ?? 0]
    }
}

private final class NativePresentationCacheFixture {
    typealias Point=BoundPlayerState.Point
    let cache=BoundNativePresentationCache(),core=NSObject(),profile=NSObject()
    var scope:BoundNativePresentationScope {.init(core:ObjectIdentifier(core),profile:ObjectIdentifier(profile),timeline:1)}
    func observe(_ proposed:Point = .init(x:16,y:-24),applied:Point = .init(x:40,y:8),
                 desired:Point?=nil,coherent:Bool=true,live:Point = .init(x:120,y:72),built:Point = .init(x:120,y:72),
                 map:BoundPlayerMapConnections.Map = .init(group:3,number:0),instance:UInt64=1,
                 nativeTiles:BoundNativePresentationCache.NativeTiles?=nil,
                 scope:BoundNativePresentationScope?=nil,
                 project:(BoundPlayerMapConnections.Map,BoundPlayerMapConnections.Map)->Point? = {_,_ in nil})->Point? {
        cache.camera(proposed:proposed,appliedScroll:applied,
            desiredScroll:desired ?? .init(x:applied.x+(coherent ? 0:2),y:applied.y),
            liveFoot:live,builtFoot:built,map:map,instance:instance,nativeTiles:nativeTiles,scope:scope ?? self.scope,project:project)
    }
}

extension RecordedPlayerTests {
    func testPresentationCameraUsesOnlyPreviousObservedTileSegmentForRenderedLag() {
        let f=NativePresentationCacheFixture()
        let walking=BoundNativePresentationCache.NativeTiles(current:.init(x:35,y:20),previous:.init(x:36,y:20))
        let settled=BoundNativePresentationCache.NativeTiles(current:.init(x:35,y:20),previous:.init(x:35,y:20))
        XCTAssertEqual(f.observe(.init(x:-452,y:-248),applied:.init(x:244,y:40),nativeTiles:walking),.init(x:-452,y:-248))
        XCTAssertEqual(f.observe(applied:.init(x:242,y:40),coherent:false,nativeTiles:settled),.init(x:-450,y:-248),
            "Actual foot570 still belongs to the observed35→36 segment when raw tiles collapse to35")
        XCTAssertEqual(f.observe(applied:.init(x:240,y:40),coherent:false,
            nativeTiles:.init(current:.init(x:34,y:20),previous:.init(x:35,y:20))),.init(x:-448,y:-248))
        XCTAssertEqual(f.observe(.init(x:-446,y:-248),applied:.init(x:238,y:40),
            nativeTiles:.init(current:.init(x:34,y:20),previous:.init(x:35,y:20))),.init(x:-446,y:-248))
        f.cache.reset()
        XCTAssertNotNil(f.observe(.init(x:-452,y:-248),applied:.init(x:244,y:40),nativeTiles:walking))
        XCTAssertEqual(f.observe(applied:.init(x:242,y:40),coherent:false,nativeTiles:settled),.init(x:-450,y:-248))
        XCTAssertEqual(f.observe(applied:.init(x:242,y:40),coherent:false,nativeTiles:settled),.init(x:-450,y:-248),
            "An exact repeated framebuffer observation keeps its previously admitted foot")
        XCTAssertEqual(f.observe(applied:.init(x:240,y:40),coherent:false,nativeTiles:settled),.init(x:-448,y:-248))
        XCTAssertNil(f.observe(applied:.init(x:242,y:40),coherent:false,nativeTiles:settled),
            "Reaching the current tile retires the old segment; it cannot admit a later backward foot")
        f.cache.reset()
        XCTAssertNotNil(f.observe(.init(x:-452,y:-248),applied:.init(x:244,y:40),nativeTiles:walking))
        XCTAssertNotNil(f.observe(applied:.init(x:242,y:40),coherent:false,nativeTiles:settled))
        XCTAssertNil(f.observe(applied:.init(x:242,y:40),coherent:false,
            nativeTiles:.init(current:.init(x:34,y:20),previous:.init(x:34,y:20))),
            "A changed native interval cannot borrow the identical-foot exception without current or prior segment evidence")
    }

    func testPresentationCameraRejectsFootOutsideCurrentAndPriorSegments() {
        let f=NativePresentationCacheFixture()
        let walking=BoundNativePresentationCache.NativeTiles(current:.init(x:35,y:20),previous:.init(x:36,y:20))
        let settled=BoundNativePresentationCache.NativeTiles(current:.init(x:35,y:20),previous:.init(x:35,y:20))
        XCTAssertNotNil(f.observe(.init(x:-452,y:-248),applied:.init(x:244,y:40),nativeTiles:walking))
        XCTAssertNil(f.observe(applied:.init(x:262,y:40),coherent:false,nativeTiles:settled),"Foot590 lies outside both observed intervals")
        XCTAssertNil(f.observe(applied:.init(x:242,y:40),coherent:false,nativeTiles:settled),"Rejection also retires old interval evidence")
        XCTAssertNotNil(f.observe(.init(x:-452,y:-248),applied:.init(x:244,y:40),nativeTiles:walking))
        XCTAssertNil(f.observe(applied:.init(x:242,y:40),coherent:false,built:.init(x:120,y:74),nativeTiles:settled),
            "Horizontal segment history must not admit a different vertical coordinate")
    }

    func testPresentationCameraDoesNotBorrowOldSegmentForCoherentReseed() {
        let f=NativePresentationCacheFixture()
        let walking=BoundNativePresentationCache.NativeTiles(current:.init(x:35,y:20),previous:.init(x:36,y:20))
        let settled=BoundNativePresentationCache.NativeTiles(current:.init(x:35,y:20),previous:.init(x:35,y:20))
        XCTAssertNotNil(f.observe(.init(x:-452,y:-248),applied:.init(x:244,y:40),nativeTiles:walking))
        XCTAssertNil(f.observe(.init(x:-450,y:-248),applied:.init(x:242,y:40),nativeTiles:settled),
            "A fresh coherent origin requires its own current native interval")
        XCTAssertEqual(f.observe(.init(x:-448,y:-248),applied:.init(x:240,y:40),nativeTiles:settled),.init(x:-448,y:-248))
    }

    func testPresentationCameraTranslatesPriorSegmentAcrossVerifiedSeam() {
        let f=NativePresentationCacheFixture(),next=BoundPlayerMapConnections.Map(group:3,number:19)
        XCTAssertNotNil(f.observe(.init(x:-452,y:-248),applied:.init(x:244,y:40),
            nativeTiles:.init(current:.init(x:35,y:20),previous:.init(x:36,y:20))))
        XCTAssertEqual(f.observe(applied:.init(x:242,y:40),coherent:false,map:next,instance:2,
            nativeTiles:.init(current:.init(x:45,y:20),previous:.init(x:45,y:20)),project:{_,_ in .init(x:10,y:0)}),
            .init(x:-610,y:-248),"The same verified map projection translates both camera and previous tile evidence")
    }

    func testPresentationCameraDropsTileEvidenceAcrossScopeMapAndLoadReset() {
        let f=NativePresentationCacheFixture()
        let walking=BoundNativePresentationCache.NativeTiles(current:.init(x:35,y:20),previous:.init(x:36,y:20))
        let settled=BoundNativePresentationCache.NativeTiles(current:.init(x:35,y:20),previous:.init(x:35,y:20))
        func seed(){f.cache.reset();XCTAssertNotNil(f.observe(.init(x:-452,y:-248),applied:.init(x:244,y:40),nativeTiles:walking))}
        seed();f.cache.reset();XCTAssertNil(f.observe(applied:.init(x:242,y:40),coherent:false,nativeTiles:settled))
        seed();XCTAssertNil(f.observe(applied:.init(x:242,y:40),coherent:false,instance:2,nativeTiles:settled))
        seed();XCTAssertNil(f.observe(applied:.init(x:242,y:40),coherent:false,map:.init(group:5,number:4),nativeTiles:settled))
        seed();XCTAssertNil(f.observe(applied:.init(x:242,y:40),coherent:false,nativeTiles:settled,
            scope:.init(core:ObjectIdentifier(f.core),profile:ObjectIdentifier(f.profile),timeline:2)))
    }

    func testPresentationCameraSeedsOnlyFromCoherentNativeState() {
        let f=NativePresentationCacheFixture()
        XCTAssertNil(f.observe(coherent:false))
        XCTAssertNil(f.observe(live:.init(x:122,y:72)))
        XCTAssertNil(f.observe(live:.init(x:120,y:74)))
        XCTAssertEqual(f.observe(desired:.init(x:296,y:264)),.init(x:16,y:-24),"Scroll coherence is modulo256")
        XCTAssertEqual(f.observe(.init(x:18,y:-24),coherent:false),.init(x:16,y:-24),"An incomplete native update cannot move a stable rendered background")
    }

    func testPresentationCameraFollowsAppliedScrollThroughPartialFieldWrites() {
        let f=NativePresentationCacheFixture()
        XCTAssertEqual(f.observe(),.init(x:16,y:-24))
        for wobble in [14,18,14,18] {
            XCTAssertEqual(f.observe(.init(x:wobble,y:-24),coherent:false,live:.init(x:122,y:72)),.init(x:16,y:-24))
        }
        XCTAssertEqual(f.observe(.init(x:12,y:-24),applied:.init(x:42,y:8),coherent:false),.init(x:14,y:-24))
        XCTAssertEqual(f.observe(.init(x:16,y:-24),applied:.init(x:42,y:8),coherent:false),.init(x:14,y:-24))
        XCTAssertEqual(f.observe(.init(x:14,y:-24),applied:.init(x:42,y:8)),.init(x:14,y:-24))
    }

    func testPresentationCameraUnwrapsScrollAndPreservesPanning() {
        let f=NativePresentationCacheFixture()
        XCTAssertEqual(f.observe(.init(x:-464,y:-248),applied:.init(x:254,y:255)),.init(x:-464,y:-248))
        XCTAssertEqual(f.observe(applied:.init(x:0,y:1),coherent:false),.init(x:-466,y:-250))
        XCTAssertEqual(f.observe(applied:.init(x:254,y:255),coherent:false),.init(x:-464,y:-248))
        XCTAssertEqual(f.observe(applied:.init(x:1,y:4),coherent:false),.init(x:-467,y:-253),"Applied camera panning remains visible on both axes")
        XCTAssertEqual(f.observe(.init(x:2400,y:-1600),applied:.init(x:1,y:4)),.init(x:2400,y:-1600),"A coherent origin jump reseeds, without a smoothing clamp")
    }

    func testPresentationCameraProjectsConnectedMapSeamsInBothDirections() {
        let f=NativePresentationCacheFixture(),pallet=BoundPlayerMapConnections.Map(group:3,number:0),route=BoundPlayerMapConnections.Map(group:3,number:19)
        XCTAssertEqual(f.observe(map:pallet),.init(x:16,y:-24))
        XCTAssertEqual(f.observe(applied:.init(x:42,y:8),coherent:false,map:route,instance:2,project:{next,old in
            XCTAssertEqual(next,route);XCTAssertEqual(old,pallet);return .init(x:0,y:20)
        }),.init(x:14,y:-344))
        XCTAssertEqual(f.observe(applied:.init(x:40,y:8),coherent:false,map:pallet,instance:3,project:{next,old in
            XCTAssertEqual(next,pallet);XCTAssertEqual(old,route);return .init(x:0,y:-20)
        }),.init(x:16,y:-24))
    }

    func testPresentationCameraRejectsUnconnectedMapsAndReplacedInstances() {
        let f=NativePresentationCacheFixture(),room=BoundPlayerMapConnections.Map(group:5,number:4)
        XCTAssertNotNil(f.observe())
        XCTAssertNil(f.observe(coherent:false,map:room,instance:2))
        XCTAssertNil(f.observe(coherent:false),"An unconnected warp retires the old camera")
        XCTAssertEqual(f.observe(.init(x:100,y:200),map:room,instance:2),.init(x:100,y:200))
        XCTAssertNil(f.observe(coherent:false,map:room,instance:3),"A new same-map instance cannot inherit the preceding camera")
        XCTAssertEqual(f.observe(.init(x:300,y:400),map:room,instance:3),.init(x:300,y:400))
    }

    func testPresentationCameraInvalidatesForCoreProfileLoadAndExplicitReset() {
        let f=NativePresentationCacheFixture(),otherCore=NSObject(),otherProfile=NSObject()
        let scopes:[BoundNativePresentationScope]=[
            .init(core:ObjectIdentifier(otherCore),profile:ObjectIdentifier(f.profile),timeline:1),
            .init(core:ObjectIdentifier(f.core),profile:ObjectIdentifier(otherProfile),timeline:1),
            .init(core:ObjectIdentifier(f.core),profile:ObjectIdentifier(f.profile),timeline:2)]
        for scope in scopes {
            XCTAssertNotNil(f.observe())
            XCTAssertNil(f.observe(coherent:false,scope:scope))
            XCTAssertEqual(f.observe(.init(x:45000,y:-45000),scope:scope),.init(x:45000,y:-45000))
        }
        f.cache.reset();XCTAssertNil(f.observe(coherent:false,scope:scopes.last!))
    }

    func testPresentationCameraInvalidatesAfterAnUndecodableScene() throws {
        let f=NativePresentationCacheFixture();XCTAssertNotNil(f.observe())
        var memory=try XCTUnwrap(BoundGBAMemorySnapshot(copyingWorkRAM:Data(repeating:0,count:0x40000),internalRAM:Data(repeating:0,count:0x8000)))
        memory.presentationObservation = .init(cache:f.cache,scope:f.scope)
        XCTAssertNil(BoundPlayerSceneDecoder.read(player:try XCTUnwrap(reading(frame:1).player),memory:memory,
            rom:{_,_ in nil},assets:BoundPlayerSceneAssets()))
        XCTAssertNil(f.observe(coherent:false),"A missing scene must not reuse a camera across a fade/menu gap")
    }

    func testBuiltOAMCenterUnwrapsBothAxesWithoutClampingToLivePosition() {
        func raw(center:BoundPlayerState.Point)->[UInt8] {
            var bytes=[UInt8](repeating:0,count:68)
            let x=(center.x-8)&511,y=(center.y-16)&255
            bytes[0]=UInt8(y);bytes[2]=UInt8(x&255);bytes[3]=UInt8(x>>8)
            bytes[0x28]=0xF8;bytes[0x29]=0xF0;return bytes
        }
        for point in [BoundPlayerState.Point(x:-4,y:-8),.init(x:520,y:260),.init(x:120,y:72)] {
            XCTAssertEqual(BoundPlayerSceneDecoder.builtSpriteCenter(raw(center:point),live:.init(x:point.x+2,y:point.y-2)),point)
        }
    }

    /// The same native core/ROM and presentation path compare a held UI pose
    /// with the production immutable timeline. Samples are confirmed, past-only
    /// 20 Hz observations; no network, future position or extrapolation is used.
    func testActualVideoOwnerInterpolatesBetweenJitteredMainPublications() async throws {
        let env=ProcessInfo.processInfo.environment
        guard env["BOUND_MOVEMENT_PRESENTATION"]=="1" else {throw XCTSkip("Requires isolated exact-ROM video cadence fixture")}
        continueAfterFailure=false
        let rom=URL(fileURLWithPath:try XCTUnwrap(env["BOUND_MOVEMENT_ROM"]))
        let image=try Data(contentsOf:rom),digest=SHA256.hash(data:image).map{String(format:"%02x",$0)}.joined()
        XCTAssertEqual(digest,try XCTUnwrap(env["BOUND_MOVEMENT_SHA256"]))
        let profile=try BoundPlayerROMProfile(rom:image)
        XCTAssertEqual(try MultiRedAdapter(rom:image).profile.romSHA256,digest)
        let output=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("MovementPresentation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let battery=output.appendingPathComponent("disposable.sav")
        try Data(repeating:255,count:131072).write(to:battery)
        let core=try XCTUnwrap(EmulatorCore(game:ReplayGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
        var options=BoundMultiplayerSetupOptions()
        options.name="RED";options.gender=0;options.partnerName="BLUE";options.partnerGender=0;options.rival="BLUE"
        options.difficulty=0;options.minimalGrinding=false;options.species=0;options.randomMoves=false;options.randomAbilities=false
        options.cheats=false;options.nicknames=true;options.debug=true;options.deleteSaveOnGameOver=true
        let setup=NativePlayerSceneSetup(core:core,debugPlayer:1,run:UUID(uuidString:"11111111-2222-3333-4444-555555555555")!,
            localSeed:0x12345678,partnerSeed:0x87654321,settings:options.settings,playerProfile:options.profile)
        let probe=BoundVBAPlayerStateProbe(),compositor=BoundPresenceFrameCompositor(),frames=PresenceVideoCadenceReadings()
        probe.configure(coreID:ObjectIdentifier(core),profile:profile,active:true,status:.waiting,detail:"Video cadence",sceneEnabled:true)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let oldWindow=scene.windows.first(where:\.isKeyWindow),window=UIWindow(windowScene:scene)
        let owner=UIViewController(),view=GameView()
        window.rootViewController=owner;window.windowLevel = .alert+1;window.makeKeyAndVisible()
        view.frame=CGRect(x:0,y:160,width:owner.view.bounds.width,height:owner.view.bounds.width*2/3)
        owner.view.addSubview(view);core.add(view);core.audioManager.isEnabled=false
        defer {
            _=core.pause();compositor.observeFrame=nil;compositor.configure(profile:nil,pose:nil);_=core.stop()
            window.isHidden=true;oldWindow?.makeKeyAndVisible()
        }
        let booted=expectation(description:"Exact-ROM field for native video owner")
        var ready=false
        core.updateHandler={core in
            BoundFrameMemory.perform {
                setup.receive(core);compositor.receive(core)
                if let reading=probe.receive(core),!ready,setup.isReady,reading.player?.scene != nil {ready=true;booted.fulfill()}
            }
        }
        core.rate=8;XCTAssertTrue(core.start());core.audioManager.isEnabled=false
        await fulfillment(of:[booted],timeout:90);XCTAssertTrue(core.pause())
        XCTAssertTrue(BoundVBABattleBridge.qaWarpViridianMartEntrance())
        XCTAssertTrue(core.resume());try await Task.sleep(for:.seconds(1));XCTAssertTrue(core.pause())
        let reading=try XCTUnwrap(probe.takeLatest()),player=try XCTUnwrap(reading.player)
        XCTAssertEqual(player.mapGroup,3);XCTAssertEqual(player.mapNumber,1)
        var base=try XCTUnwrap(BoundPresencePose(reading:reading));base.follower=nil;base.x-=40;base.y+=16
        let anchor=MultiRedAdapter.captureState();XCTAssertFalse(anchor.isEmpty)
        try anchor.write(to:output.appendingPathComponent("exact-ROM-anchor.state"))
        if let png=core.videoManager.snapshot()?.pngData(){try png.write(to:output.appendingPathComponent("native-anchor.png"))}
        let speed=16.0,duration=4.0,jitter=[0.010,0.024,0.012,0.031,0.013,0.028]
        var summaries=[[String:Any]]()
        for repetition in 0..<3 {
            for rate in [1.0,3.0] {
                var pair=[String:[String:Double]]()
                for mode in repetition%2==0 ? ["held-ui-pose","frame-timeline"]:["frame-timeline","held-ui-pose"] {
                    XCTAssertTrue(MultiRedAdapter.restoreState(anchor));core.rate=rate
                    let started=ProcessInfo.processInfo.systemUptime
                    frames.arm(start:started,origin:base.x,speed:speed)
                    compositor.observeFrame={reading,pose,pixels in frames.append(reading,pose,pixels)}
                    var refreshes=[[String:Double]]()
                    func publish(at now:Double) {
                        let newest=Int(floor((now-started)/0.05))
                        let samples=(newest-7...newest).map { step -> BoundPresencePresentationSample in
                            let time=started+Double(step)*0.05
                            var pose=base;pose.x+=speed*(time-started)
                            return .init(time:time,pose:pose,followerPresentation:nil)
                        }
                        let snapshot=BoundPresencePresentationSnapshot(needsReader:true,enabled:true,romVerified:true,
                            lastPoseReceived:samples.last!.time,clockOffset:0,samples:samples,
                            retainedPose:samples.last!.pose,retainedAt:samples.last!.time,sceneProfile:profile)
                        compositor.configure(profile:profile,pose:mode=="held-ui-pose" ? snapshot.pose(at:now):nil,
                            coreID:ObjectIdentifier(core),presentation:mode=="frame-timeline" ? snapshot:nil)
                        refreshes.append(["time":now,"latestConfirmedSample":samples.last!.time])
                    }
                    publish(at:started);XCTAssertTrue(core.resume())
                    var next=started,index=0
                    while ProcessInfo.processInfo.systemUptime<started+duration {
                        next+=jitter[index%jitter.count];index+=1
                        let wait=max(0,next-ProcessInfo.processInfo.systemUptime)
                        if wait>0 {try await Task.sleep(for:.seconds(wait))}
                        let now=ProcessInfo.processInfo.systemUptime
                        publish(at:now)
                        if next<now-0.04 {next=now}
                    }
                    XCTAssertTrue(core.pause());compositor.observeFrame=nil
                    let rows=frames.snapshot(),metrics=PresenceVideoCadenceReadings.metrics(rows)
                    let name="repeat-\(repetition+1)-\(rate)-\(mode)"
                    let report:[String:Any]=["name":name,"romSHA256":digest,"repeat":repetition+1,"rate":rate,"mode":mode,
                        "metrics":metrics,"raw":rows,"mainPublications":refreshes,"output":output.path,
                        "scope":"Actual VBA-M video renderer and composited pixels; synthetic confirmed 20Hz remote samples and jittered MainActor publication, no network or physical scanout"]
                    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent(name+".json"))
                    if let png=core.videoManager.snapshot()?.pngData(){try png.write(to:output.appendingPathComponent(name+".png"))}
                    summaries.append(report.filter{!["raw","mainPublications"].contains($0.key)});pair[mode]=metrics
                    try JSONSerialization.data(withJSONObject:summaries,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("summary.json"))
                    print("BOUND_MOVEMENT_PRESENTATION \(name) \(metrics) output=\(output.path)")
                    XCTAssertGreaterThan(metrics["frames"] ?? 0,100,"The real native video owner must be exercised")
                    XCTAssertGreaterThan(metrics["resolvedFrames"] ?? 0,(metrics["frames"] ?? 0)*0.95)
                    XCTAssertGreaterThan(metrics["visibleFrames"] ?? 0,(metrics["frames"] ?? 0)*0.8,"The real compositor must draw visible pixels")
                    XCTAssertTrue(refreshes.allSatisfy{$0["latestConfirmedSample"]! <= $0["time"]!},"No future samples may mask starvation")
                }
                let old=try XCTUnwrap(pair["held-ui-pose"]),fixed=try XCTUnwrap(pair["frame-timeline"])
                XCTAssertGreaterThan(old["repeatedPositionRatio"] ?? 0,0.10,"The control must reproduce held-pose stutter")
                XCTAssertLessThan(fixed["repeatedPositionRatio"] ?? 1,0.03,"Native-frame sampling must remove repeated moving poses")
                XCTAssertLessThan(fixed["repeatedPositionRatio"] ?? 1,(old["repeatedPositionRatio"] ?? 0)*0.25)
                XCTAssertLessThan(fixed["p95PositionErrorPixels"] ?? 999,0.5,"Native frames must follow the existing delayed interpolation clock")
            }
        }
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:summaries,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name="actual-video-owner-cadence";attachment.lifetime = .keepAlways;add(attachment)
    }
}

@MainActor
final class RecordedPlayerTests: XCTestCase {
    private var previousExperimentalFeature: Any?
    override func setUp() {
        super.setUp()
        previousExperimentalFeature = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
    }
    override func tearDown() {
        UserDefaults.standard.set(previousExperimentalFeature, forKey: BoundMultiplayerFeatures.key)
        NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        super.tearDown()
    }

    private func sprite(priority: Int = 2, flip: Bool = false) -> BoundPlayerSprite {
        var palette = Data(repeating: 0, count: 32); palette[2] = 31
        return .init(width: 16, height: 32, tiles: Data(repeating: 0x11, count: 256), palette: palette,
                     flipX: flip, flipY: false, priority: priority)
    }
    private func scene(x: Int = 104, y: Int = 112, cameraX: Int = 16, cameraY: Int = -24,
                       background: BoundPlayerBackground? = nil, objects: [BoundPlayerSceneObject] = []) -> BoundPlayerScene {
        .init(worldFoot: .init(x: x, y: y), camera: .init(x: cameraX, y: cameraY), appearance: sprite(),
              background: background ?? .init(tiles: Data(repeating: 0, count: 32768), layers: []), objects: objects)
    }
    private func pose(x: Double = 104, y: Double = 112, map: Int = 1) -> BoundRecordedPlayerPose {
        .init(mapGroup: 4, mapNumber: map, elevation: 0, x: x, y: y, appearance: sprite())
    }
    private func reading(frame: UInt64, x: Int = 104, map: Int = 1) -> BoundPlayerStateReading {
        var player = BoundPlayerState(mapGroup: 4, mapNumber: map, tile: .init(x: 6, y: 6), previousTile: .init(x: 6, y: 6),
            facing: "South", elevation: 0, graphicsID: 0, runningState: 0, tileTransitionState: 0)
        player.scene = scene(x: x)
        return .init(frame: frame, status: .live, detail: "Fixture", player: player)
    }

    func testScriptLockedFieldKeepsSceneAndMasksOnlyNativeWindowTiles() throws {
        var work = Data(repeating: 0, count: 0x40000)
        var internalRAM = Data(repeating: 0, count: 0x8000)
        func bytes(_ value: Int, _ count: Int = 4) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        func put(_ value: Int, _ address: Int, _ count: Int = 4) {
            if address >= 0x03000000 {
                let offset = address - 0x03000000
                internalRAM.replaceSubrange(offset..<offset + count, with: bytes(value, count))
            } else {
                let offset = address - 0x02000000
                work.replaceSubrange(offset..<offset + count, with: bytes(value, count))
            }
        }
        let sprite = 0x0202063C
        put(0x08010000, sprite + 8); put(0x08011000, sprite + 12)
        put(120, sprite + 0x20, 2); put(112, sprite + 0x22, 2)
        put(0xF8, sprite + 0x28, 1); put(0xF0, sprite + 0x29, 1)
        put(3, sprite + 0x3E, 1); put(2 << 10, sprite + 4, 2)
        put(0x08001000, 0x02036DFC)
        put(0x100, 0x03000000, 2) // Native text BG0 remains enabled.
        put(0x02010000, 0x030008EC)
        put(0xF038, 0x02010000 + (15 * 32 + 14) * 2, 2)
        let rom: [Int: [UInt8]] = [
            0x08001000: bytes(0) + bytes(0) + bytes(0) + bytes(0) + bytes(0x08002000) + bytes(0x08003000),
            0x08002000: bytes(0) + bytes(0x08004000),
            0x08003000: bytes(0) + bytes(0x08009000),
            0x08004000: Array(repeating: 0, count: 640 * 32),
            0x08009000: Array(repeating: 0, count: 384 * 32),
            0x08010000: bytes(0x08010010), 0x08010010: bytes(0),
            0x08011000: bytes(0x08012000) + bytes(256),
            0x08012000: Array(repeating: 0x11, count: 256)
        ]
        let player = try XCTUnwrap(reading(frame: 1).player)
        let assets = BoundPlayerSceneAssets()
        func decode() -> BoundPlayerScene? {
            BoundPlayerSceneDecoder.read(player: player,
                memory: BoundGBAMemorySnapshot(copyingWorkRAM: work, internalRAM: internalRAM)!,
                rom: { address, count in
                    guard let value = rom[address], value.count == count else { return nil }
                    return value
                }, assets: assets)
        }
        let unlocked = try XCTUnwrap(decode())
        put(1, 0x03000F9C, 1) // Mom, friend prompts and ordinary scripts lock controls.
        let dialogue = try XCTUnwrap(decode())
        XCTAssertEqual(dialogue.worldFoot, unlocked.worldFoot)
        XCTAssertEqual(dialogue.appearance, unlocked.appearance)
        XCTAssertTrue(dialogue.background.covers(x: 112, y: 120, priority: 2))
        XCTAssertFalse(dialogue.background.covers(x: 112, y: 96, priority: 2))
        let rendered = BoundRecordedPlayerRasterizer.rgba(pose: pose(), scene: dialogue).0
        XCTAssertTrue(stride(from: 3, to: rendered.count, by: 4).contains { rendered[$0] != 0 },
                      "Dialogue must not hide the entire friend")
        // ClearWindowTilemap preserves palette 15 when it selects blank tile 0.
        put(0xF000, 0x02010000 + (15 * 32 + 14) * 2, 2)
        XCTAssertFalse(try XCTUnwrap(decode()).background.covers(x: 112, y: 120, priority: 2),
                       "Closing a window removes its occlusion")
    }

    func testClearedWindowPaletteAndFlipAttributesDoNotHideFriend() {
        for attributes in 0..<64 {
            let entry = attributes << 10 // Tile 0, with every palette/flip combination.
            var map = Data(repeating: 0, count: 2048)
            for offset in stride(from: 0, to: map.count, by: 2) {
                map[offset] = UInt8(truncatingIfNeeded: entry)
                map[offset + 1] = UInt8(entry >> 8)
            }
            let background = BoundPlayerBackground(tiles: Data(), layers: [
                .init(priority: 0, scrollX: 253, scrollY: 255, map: map, masksWholeTiles: true)
            ])
            for point in [(0, 0), (7, 7), (112, 120), (239, 159)] {
                XCTAssertFalse(background.covers(x: point.0, y: point.1, priority: 2),
                               "Blank UI tile must stay transparent regardless of attributes: \(entry)")
            }
        }
    }

    func testFriendCrossesClearedDialogueRegionAndViewportEdgesWithoutPixelLoss() {
        // Native bedroom state after intro dialogue: the bottom six tile rows
        // retain palette 14 (border) and 15 (text) even though the window is gone.
        var map = Data(repeating: 0, count: 2048)
        for row in 14..<20 {
            for column in 0..<30 {
                map[(row * 32 + column) * 2 + 1] =
                    (15..<19).contains(row) && (2..<28).contains(column) ? 0xF0 : 0xE0
            }
        }
        let background = BoundPlayerBackground(tiles: Data(), layers: [
            .init(priority: 0, scrollX: 0, scrollY: 0, map: map, masksWholeTiles: true)
        ])
        let friend = pose(x: 104, y: 144)
        for shift in -176...160 {
            for camera in [(16, shift), (shift, 0)] {
                let actual = scene(cameraX: camera.0, cameraY: camera.1, background: background)
                let clear = scene(cameraX: camera.0, cameraY: camera.1)
                XCTAssertEqual(BoundRecordedPlayerRasterizer.rgba(pose: friend, scene: actual).0,
                               BoundRecordedPlayerRasterizer.rgba(pose: friend, scene: clear).0,
                               "A closed dialogue must not clip the friend at camera \(camera)")
            }
        }
    }

    func testCameraMovesByOnePixelAcrossDestinationTileAndSignedWrap() {
        func camera(x: Int = 6, y: Int = 6, rx: Int = 0, ry: Int = 0, total: Int = 0) -> BoundPlayerState.Point {
            BoundPlayerSceneDecoder.camera(save: .init(x: x, y: y), residual: .init(x: rx, y: ry),
                total: .init(x: total, y: total), offset: .init(x: BoundSceneBytes.wrap(total), y: BoundSceneBytes.wrap(total - 40)))
        }
        XCTAssertEqual(camera(), .init(x: 16, y: -24))
        for progress in 1...15 {
            XCTAssertEqual(camera(x: 7, rx: progress).x, 16 - progress)
            XCTAssertEqual(camera(x: 5, rx: -progress).x, 16 + progress)
            XCTAssertEqual(camera(y: 7, ry: progress).y, -24 - progress)
            XCTAssertEqual(camera(y: 5, ry: -progress).y, -24 + progress)
        }
        XCTAssertEqual(camera(x: 7).x, 0)
        XCTAssertEqual(camera(total: 32760), camera())
        XCTAssertEqual(camera(total: -32760), camera())
    }

    func testFourBitTilesRespectTransparencyAndHorizontalFlip() {
        var bytes = Data(repeating: 0, count: 256); bytes[0] = 0x21; bytes[32] = 0x43
        let normal = BoundPlayerSprite(width: 16, height: 32, tiles: bytes, palette: Data(repeating: 0, count: 32),
                                       flipX: false, flipY: false, priority: 2)
        let flipped = BoundPlayerSprite(width: 16, height: 32, tiles: bytes, palette: normal.palette,
                                        flipX: true, flipY: false, priority: 2)
        XCTAssertEqual(normal.colorIndex(x: 0, y: 0), 1); XCTAssertEqual(normal.colorIndex(x: 1, y: 0), 2)
        XCTAssertEqual(normal.colorIndex(x: 8, y: 0), 3)
        XCTAssertEqual(flipped.colorIndex(x: 15, y: 0), 1)
        XCTAssertEqual(flipped.colorIndex(x: 7, y: 0), 3)
        XCTAssertEqual(normal.colorIndex(x: -1, y: 0), 0)
    }

    func testLZ77BoundsAndOverlappingCopy() {
        func decode(_ bytes: [UInt8]) -> [UInt8]? {
            BoundPlayerSceneAssets.decompress(address: 0) { address, count in
                guard address >= 0, address + count <= bytes.count else { return nil }
                return Array(bytes[address..<address + count])
            }
        }
        XCTAssertEqual(decode([0x10, 6, 0, 0, 0x40, 7, 0x20, 0]), [7, 7, 7, 7, 7, 7])
        XCTAssertNil(decode([0x10, 6, 0, 0, 0x80, 0, 0]))
        XCTAssertNil(decode([0x10, 0, 0, 1]))
        XCTAssertNil(decode([0x10, 1, 0, 0, 0]))
    }

    func testTrackInterpolatesOnlyContinuousWorldMovementAndHasBoundedDuration() {
        var track = BoundRecordedPlayerTrack()
        track.append(frame: 0, pose: pose()); track.append(frame: 4, pose: pose(x: 108))
        XCTAssertEqual(track.pose(at: 2)?.x, 106)
        track.append(frame: 5, pose: nil); track.append(frame: 7, pose: pose(x: 112))
        XCTAssertNil(track.pose(at: 6))
        track.append(frame: 10, pose: pose(x: 112, map: 2))
        XCTAssertNil(track.pose(at: 8))
        track.append(frame: 30, pose: pose(x: 113, map: 2))
        XCTAssertNil(track.pose(at: 15))
        track.append(frame: 31, pose: pose(x: 999, map: 2))
        track.append(frame: 1801, pose: pose())
        XCTAssertEqual(track.end, 31)
        XCTAssertNil(track.pose(at: 32))
    }

    func testRecordingPlaybackPauseMapMismatchAndSaveRestoreNeverKeepOldPose() {
        let session = BoundRecordedPlayerSession()
        session.record()
        for frame in UInt64(1)...20 { session.consume(reading(frame: frame, x: 104 + Int(frame))) }
        session.suspend()
        XCTAssertTrue(session.hasRecording); XCTAssertEqual(session.mode, .idle)
        session.play(); session.consume(reading(frame: 1))
        XCTAssertEqual(session.pose?.x, 105)
        session.consume(.inactive(.paused, "Pause")); XCTAssertNil(session.pose)
        session.consume(reading(frame: 1, map: 2)); XCTAssertNil(session.pose)
        session.consume(reading(frame: 2)); XCTAssertNotNil(session.pose)
        session.stop(); XCTAssertNil(session.pose)
        session.play()
        for frame in UInt64(1)...25 { session.consume(reading(frame: frame)) }
        XCTAssertEqual(session.mode, .idle); XCTAssertNil(session.pose)
        session.clear(); XCTAssertFalse(session.hasRecording)
    }

    func testRasterizerUsesViewerCameraClipsAndMasksForegroundAndNearerObjects() {
        let p = pose(), s = scene()
        let (pixels, origin) = BoundRecordedPlayerRasterizer.rgba(pose: p, scene: s)
        XCTAssertEqual(origin, .init(x: 112, y: 56))
        XCTAssertEqual(pixels[3], 255); XCTAssertEqual(pixels[0], 255)
        let shifted = BoundRecordedPlayerRasterizer.rgba(pose: p, scene: scene(cameraX: -16)).1
        XCTAssertEqual(shifted.x, origin.x - 32)
        var tiles = Data(repeating: 0, count: 32768)
        tiles.replaceSubrange(32..<64, with: repeatElement(UInt8(0x11), count: 32))
        var map = Data(repeating: 0, count: 2048)
        for index in stride(from: 0, to: map.count, by: 2) { map[index] = 1 }
        let foreground = BoundPlayerBackground(tiles: tiles, layers: [.init(priority: 1, scrollX: 0, scrollY: 0, map: map)])
        let hidden = BoundRecordedPlayerRasterizer.rgba(pose: p, scene: scene(background: foreground)).0
        XCTAssertFalse(stride(from: 3, to: hidden.count, by: 4).contains { hidden[$0] != 0 })
        let behind = BoundPlayerBackground(tiles: tiles, layers: [.init(priority: 2, scrollX: 0, scrollY: 0, map: map)])
        XCTAssertEqual(BoundRecordedPlayerRasterizer.rgba(pose: p, scene: scene(background: behind)).0, pixels)
        let nearer = BoundPlayerSceneObject(origin: origin, footY: 88, appearance: sprite())
        let masked = BoundRecordedPlayerRasterizer.rgba(pose: p, scene: scene(objects: [nearer])).0
        XCTAssertFalse(stride(from: 3, to: masked.count, by: 4).contains { masked[$0] != 0 })
        let offscreen = BoundRecordedPlayerRasterizer.rgba(pose: pose(x: -100), scene: s).0
        XCTAssertFalse(stride(from: 3, to: offscreen.count, by: 4).contains { offscreen[$0] != 0 })
    }

    func testViewportUsesCameraRatherThanDistanceAndSwitchesAtSpriteBounds() throws {
        let local = scene()
        for tiles in [1, 3, 5] {
            let remote = pose(x: 104 + Double(tiles * 16))
            XCTAssertNil(BoundPlayerViewport.indicator(pose: remote, scene: local))
            let pixels = BoundRecordedPlayerRasterizer.rgba(pose: remote, scene: local).0
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 0 })
        }
        let distant = pose(x: 264)
        XCTAssertEqual(try XCTUnwrap(BoundPlayerViewport.indicator(pose: distant, scene: local)).distanceInTiles, 10)
        // The same retained world position immediately appears when the camera
        // reaches it, without receiving another network packet.
        let movedCamera = scene(x: 200, cameraX: -80)
        XCTAssertNil(BoundPlayerViewport.indicator(pose: distant, scene: movedCamera))
        let partial = pose(x: 231) // Origin 239; one column is still visible.
        XCTAssertNil(BoundPlayerViewport.indicator(pose: partial, scene: local))
        XCTAssertNotNil(BoundPlayerViewport.indicator(pose: pose(x: 232), scene: local))
    }

    func testOffscreenIndicatorsFollowEveryDirectionAndKeepEntireLabelInset() throws {
        let label = CGSize(width: 100, height: 14)
        for (x, y) in [(500.0, 112.0), (-500, 112), (104, -500), (104, 500), (500, 500), (-500, -500)] {
            let indicator = try XCTUnwrap(BoundPlayerViewport.indicator(pose: pose(x: x, y: y), scene: scene()))
            let center = indicator.center(labelSize: label)
            XCTAssertGreaterThanOrEqual(center.x - label.width / 2, 4)
            XCTAssertLessThanOrEqual(center.x + label.width / 2, 236)
            XCTAssertGreaterThanOrEqual(center.y - label.height / 2, 4)
            XCTAssertLessThanOrEqual(center.y + label.height / 2, 156)
            let expectedAngle = atan2(y - 24 - 80, x + 16 - 120)
            XCTAssertEqual(Double(indicator.angle), expectedAngle, accuracy: 0.0001)
        }
        let remote = pose(x: 500, y: 500)
        let before = try XCTUnwrap(BoundPlayerViewport.indicator(pose: remote, scene: scene()))
        let after = try XCTUnwrap(BoundPlayerViewport.indicator(pose: remote, scene: scene(x: 300, cameraX: -180)))
        XCTAssertNotEqual(before.angle, after.angle)
        XCTAssertGreaterThan(before.distanceInTiles, after.distanceInTiles)
    }

    func testOverlaySwitchesSpriteAndIndicatorWithoutMistakingOcclusionForOffscreen() throws {
        let overlay = BoundRecordedPlayerOverlay(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        overlay.show(pose: pose(x: 264), scene: scene(), offscreenName: "Alex")
        overlay.layoutIfNeeded()
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.visiblePixels, 0)
        XCTAssertEqual(overlay.offscreenText, "Alex · 10 tiles")
        XCTAssertNotNil(overlay.offscreenIndicator)
        overlay.show(pose: pose(x: 264), scene: scene(x: 200, cameraX: -80), offscreenName: "Alex")
        XCTAssertFalse(overlay.isHidden)
        XCTAssertGreaterThan(overlay.visiblePixels, 0)
        XCTAssertNil(overlay.offscreenIndicator)

        let origin = BoundPlayerViewport.origin(pose: pose(), scene: scene())
        let nearer = BoundPlayerSceneObject(origin: origin, footY: 88, appearance: sprite())
        overlay.show(pose: pose(), scene: scene(objects: [nearer]), offscreenName: "Alex")
        XCTAssertEqual(overlay.visiblePixels, 0)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertNil(overlay.offscreenIndicator, "Foreground occlusion is not physical offscreen movement")
        overlay.show(pose: nil, scene: nil, offscreenName: "Alex")
        XCTAssertNil(overlay.offscreenText)
        XCTAssertNil(overlay.offscreenIndicator)
    }

    func testRecordingLargeMovementStepOnlyDisablesSmoothing() {
        var track = BoundRecordedPlayerTrack()
        track.append(frame: 0, pose: pose()); track.append(frame: 4, pose: pose(x: 500))
        XCTAssertEqual(track.pose(at: 2)?.x, 104)
        XCTAssertEqual(track.pose(at: 4)?.x, 500)
    }

    func testPresenceFrameCompositionTracksCameraAndRestoresSourcePixels() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 240 * 160 * 4)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 37, count: 240 * 160 * 4)
        let original = Data(bytes: buffer, count: 240 * 160 * 4)
        let peer = pose(x: 104)
        // A stationary friend must move by exactly the local camera delta in
        // every immutable presentation, including reversals and running steps.
        for x in [16, 14, 12, 10, 12, 14, 16, 18] {
            let local = scene(cameraX: x)
            let origin = BoundPlayerViewport.origin(pose: peer, scene: local)
            BoundPresenceFrameCompositor.composite(peer, scene: local, into: buffer) {
                let pixel = (origin.y * 240 + origin.x) * 4
                XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer + pixel, count: 4)), [0, 0, 255, 255])
                XCTAssertEqual(buffer[pixel - 4], 37)
            }
            XCTAssertEqual(Data(bytes: buffer, count: original.count), original, "Compositing must not alter the core's source pixels")
        }
        let covered = BoundPlayerBackground(tiles: Data(repeating: 0x11, count: 32768),
            layers: [.init(priority: 0, scrollX: 0, scrollY: 0, map: Data(repeating: 0, count: 2048))])
        BoundPresenceFrameCompositor.composite(peer, scene: scene(background: covered), into: buffer) {
            XCTAssertEqual(Data(bytes: buffer, count: original.count), original, "Foreground terrain still occludes the friend")
        }
    }

    func testFriendPromptWaitsForNativeMusicResume() async throws {
        try await runNativeMusicOwnerScenario(protect: true)
    }
    func testLegacyFriendPromptDropsNativeMusicResume() async throws {
        try await runNativeMusicOwnerScenario(protect: false)
    }
    private func runNativeMusicOwnerScenario(protect: Bool) async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(ProcessInfo.processInfo.environment["BOUND_NATIVE_FIXTURE_NAME"] ?? "MultiplayerValidation")
        let rom = root.appendingPathComponent("RadicalRed.gba")
        guard FileManager.default.fileExists(atPath: rom.path) else { throw XCTSkip("Requires owned ROM fixture") }
        let output = root.appendingPathComponent("music-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav")
        try Data(repeating: 0xFF, count: 0x20000).write(to: battery)
        let core = try XCTUnwrap(EmulatorCore(game: ReplayGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
        let setup = NativePlayerSceneSetup(core: core, debugPlayer: 1)
        let dialogue = BoundFriendDialogueProbe()
        dialogue.configure(core: core)
        BoundVBABattleBridge.qaSetLegacyFieldTextAdmission(!protect)
        let booted = expectation(description: "Native field ready")
        var ready = false
        core.updateHandler = { core in
            autoreleasepool {
                setup.receive(core); dialogue.receive(core)
                if !ready, setup.isReady { ready = true; booted.fulfill() }
            }
        }
        defer { _ = core.stop(); BoundVBABattleBridge.qaSetLegacyFieldTextAdmission(false) }
        core.rate = 8; XCTAssertTrue(core.start())
        await fulfillment(of: [booted], timeout: 60)
        XCTAssertTrue(core.pause()); core.rate = 1
        XCTAssertTrue(BoundVBABattleBridge.qaWarpViridianMartEntrance())
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .seconds(3)); XCTAssertTrue(core.pause())
        let fieldMemory = try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }))
        try Data(fieldMemory.workRAM).write(to: output.appendingPathComponent("field.ewram"))
        try Data(fieldMemory.internalRAM).write(to: output.appendingPathComponent("field.iwram"))
        NSLog("Native music owner fixture: %@", output.path)
        let initialMusic = BoundVBABattleBridge.qaFieldMusicStatus()["status"] as? UInt32 ?? 0
        XCTAssertNotEqual(initialMusic & 0xFFFF, 0)
        XCTAssertEqual(initialMusic & 0x80000000, 0, "Both causal cases start with normally playing music")
        XCTAssertTrue(BoundVBABattleBridge.qaStartMusicPauseText())
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .milliseconds(500)); XCTAssertTrue(core.pause())
        var audio = BoundVBABattleBridge.qaFieldMusicStatus()
        NSLog("Native music pause text: %@", audio)
        XCTAssertEqual((audio["status"] as? UInt32 ?? 0) & 0x80000000, 0x80000000)
        XCTAssertEqual(audio["printerActive"] as? Int, 1)
        XCTAssertTrue(BoundVBABattleBridge.qaHideMusicPauseText())
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .milliseconds(250)); XCTAssertTrue(core.pause())
        audio = BoundVBABattleBridge.qaFieldMusicStatus()
        XCTAssertEqual(audio["messageMode"] as? Int, 0)
        XCTAssertEqual(audio["printerActive"] as? Int, 1)
        XCTAssertEqual(audio["field"] as? Bool, true, "An unlocked field can still have an active native printer")
        XCTAssertEqual(BoundVBABattleBridge.friendDialogueReady(), !protect, "Native text ownership must gate a replacement prompt")
        XCTAssertEqual(setup.isReady, !protect, "An unfinished native message cannot be advertised as a safe field checkpoint")
        let request = BoundFriendDialogueProbe.Request(id: UUID(), mode: 2, text: "Waiting for your friend.\nA or B: Cancel.")
        dialogue.show(request)
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .milliseconds(350)); XCTAssertTrue(core.pause())
        XCTAssertEqual(dialogue.read().active, !protect, "The queued invitation must wait for its text owner")
        core.deltaCore.emulatorBridge.activateInput(1, value: 1, playerIndex: 0)
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .milliseconds(100)); XCTAssertTrue(core.pause())
        core.deltaCore.emulatorBridge.deactivateInput(1, playerIndex: 0)
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .seconds(1)); XCTAssertTrue(core.pause())
        audio = BoundVBABattleBridge.qaFieldMusicStatus()
        XCTAssertEqual(audio["musicState"] as? Int, 2, "Door-state recovery cannot affect this causal check")
        if !protect {
            XCTAssertEqual((audio["status"] as? UInt32 ?? 0) & 0x80000000, 0x80000000,
                           "Legacy admission destroys the native resume command before any door transition")
            dialogue.show(nil)
            XCTAssertTrue(core.resume()); try await Task.sleep(for: .seconds(1)); XCTAssertTrue(core.pause())
            return
        }
        XCTAssertTrue(dialogue.read().active, "The queued prompt opens after the native text finishes")
        XCTAssertTrue(dialogue.read().menuReady)
        XCTAssertEqual((audio["status"] as? UInt32 ?? 0) & 0x80000000, 0, "The original native RESUME_MUSIC must run before the prompt replaces its window")
        dialogue.show(nil)
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .seconds(1)); XCTAssertTrue(core.pause())
        XCTAssertFalse(dialogue.read().active)
        XCTAssertTrue(BoundVBABattleBridge.friendDialogueReady())
        core.deltaCore.emulatorBridge.activateInput(64, value: 1, playerIndex: 0)
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .seconds(1)); XCTAssertTrue(core.pause())
        core.deltaCore.emulatorBridge.deactivateInput(64, playerIndex: 0)
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .seconds(3)); XCTAssertTrue(core.pause())
        let memory = try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }))
        let profile = try BoundPlayerROMProfile(rom: Data(contentsOf: rom))
        let interior = try XCTUnwrap(BoundPlayerStateDecoder.read(profile: profile, memory: memory, frame: 1, includeScene: true).player)
        XCTAssertEqual(interior.mapGroup, 5); XCTAssertEqual(interior.mapNumber, 3)
        XCTAssertNotNil(interior.scene)
    }

    func testActualViridianMartDoorEntry() async throws {
        try await runViridianMartDoorEntry(stoppedMusic: false, debugPlayer: 1)
    }
    func testStoppedMusicMartEntryKeepsNativeRInDebug() async throws {
        try await runViridianMartDoorEntry(stoppedMusic: true, debugPlayer: 1)
    }
    func testNormalModeNativeRDoesNotWarp() async throws {
        try await runViridianMartDoorEntry(stoppedMusic: true, debugPlayer: 0)
    }
    private func runViridianMartDoorEntry(stoppedMusic: Bool, debugPlayer: UInt8) async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(ProcessInfo.processInfo.environment["BOUND_NATIVE_FIXTURE_NAME"] ?? "MultiplayerValidation")
        let fixtureROM = root.appendingPathComponent("RadicalRed.gba")
        // Explicit QA fixtures take precedence. Distribution builds correctly
        // omit the cartridge, so the private fixture also supports those builds.
        let romURL = ProcessInfo.processInfo.environment["BOUND_NATIVE_FIXTURE_NAME"] != nil
            ? fixtureROM
            : Bundle(for: Game.self).url(forResource: "multiplayer", withExtension: "gba") ?? fixtureROM
        guard FileManager.default.fileExists(atPath: romURL.path) else { throw XCTSkip("Requires owned ROM fixture") }
        let profile = try BoundPlayerROMProfile(rom: Data(contentsOf: romURL))
        let output = root.appendingPathComponent("mart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav")
        try Data(repeating: 0xFF, count: 0x20000).write(to: battery)
        let core = try XCTUnwrap(EmulatorCore(game: ReplayGame(fileURL: romURL, gameSaveURL: battery), options: [.metal: true]))
        let setup = NativePlayerSceneSetup(core: core, debugPlayer: debugPlayer)
        let captured = ReplayReadings()
        let booted = expectation(description: "Admitted native field")
        var ready = false, frame: UInt64 = 0
        core.updateHandler = { core in
            autoreleasepool {
                setup.receive(core); frame += 1
                BoundVBABattleBridge.enforceSoulLink()
                BoundVBABattleBridge.advanceSharedWorld()
                guard let memory = BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }) else { return }
                let reading = BoundPlayerStateDecoder.read(profile: profile, memory: memory, frame: frame, includeScene: true)
                captured.append(reading)
                if !ready, setup.isReady, reading.player?.scene != nil { ready = true; booted.fulfill() }
            }
        }
        defer { _ = core.stop() }
        core.rate = 8; XCTAssertTrue(core.start())
        await fulfillment(of: [booted], timeout: 60)
        XCTAssertTrue(core.pause()); core.rate = 1
        XCTAssertTrue(BoundVBABattleBridge.installSoulLink())
        XCTAssertTrue(BoundVBABattleBridge.installSharedWorld())
        XCTAssertTrue(BoundVBABattleBridge.qaWarpViridianMartEntrance())
        XCTAssertTrue(core.resume())
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(core.pause())
        if debugPlayer == 0 {
            core.deltaCore.emulatorBridge.activateInput(256, value: 1, playerIndex: 0)
            XCTAssertTrue(core.resume()); try await Task.sleep(for: .milliseconds(150)); XCTAssertTrue(core.pause())
            core.deltaCore.emulatorBridge.deactivateInput(256, playerIndex: 0)
            XCTAssertEqual(captured.snapshot().last?.player?.mapNumber, 1, "R does not warp a normal run")
        }
        if stoppedMusic { XCTAssertTrue(BoundVBABattleBridge.qaStopMapMusicRetainingTracks()) }
        let saved = BoundVBABattleBridge.captureServerState()
        XCTAssertFalse(saved.isEmpty)
        XCTAssertTrue(BoundVBABattleBridge.restoreServerState(saved))
        let exterior = try XCTUnwrap(captured.snapshot().last?.player)
        XCTAssertEqual(exterior.mapGroup, 3); XCTAssertEqual(exterior.mapNumber, 1)
        try core.videoManager.snapshot()?.pngData()?.write(to: output.appendingPathComponent("outside.png"))
        core.deltaCore.emulatorBridge.activateInput(64, value: 1, playerIndex: 0)
        XCTAssertTrue(core.resume())
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(core.pause())
        core.deltaCore.emulatorBridge.deactivateInput(64, playerIndex: 0)
        let doorway = BoundVBABattleBridge.captureServerState()
        XCTAssertTrue(BoundVBABattleBridge.restoreServerState(doorway))
        XCTAssertTrue(core.resume())
        try await Task.sleep(for: .seconds(4))
        XCTAssertTrue(core.pause())
        try core.videoManager.snapshot()?.pngData()?.write(to: output.appendingPathComponent("entered.png"))
        NSLog("Mart diagnostics: %@ native=%@ reading=%@", output.path, BoundVBABattleBridge.qaNuggetBridgeStatus(), String(describing: captured.snapshot().last))
        let interior = try XCTUnwrap(captured.snapshot().last?.player)
        XCTAssertEqual(interior.mapGroup, 5); XCTAssertEqual(interior.mapNumber, 3)
        XCTAssertNotNil(interior.scene)
        if debugPlayer != 0 {
            // First entry runs the parcel cutscene. R must not replace its
            // script; finish the ordinary dialogue before testing idle R.
            XCTAssertFalse(setup.isReady)
            core.deltaCore.emulatorBridge.activateInput(256, value: 1, playerIndex: 0)
            XCTAssertTrue(core.resume()); try await Task.sleep(for: .milliseconds(150)); XCTAssertTrue(core.pause())
            core.deltaCore.emulatorBridge.deactivateInput(256, playerIndex: 0)
            XCTAssertEqual(captured.snapshot().last?.player?.mapGroup, 5)
            for _ in 0..<60 {
                if setup.isReady { break }
                core.deltaCore.emulatorBridge.activateInput(1, value: 1, playerIndex: 0)
                XCTAssertTrue(core.resume()); try await Task.sleep(for: .milliseconds(100)); XCTAssertTrue(core.pause())
                core.deltaCore.emulatorBridge.deactivateInput(1, playerIndex: 0)
                XCTAssertTrue(core.resume()); try await Task.sleep(for: .milliseconds(150)); XCTAssertTrue(core.pause())
            }
            XCTAssertTrue(setup.isReady, "Parcel dialogue must finish without replacing the native script")
            core.deltaCore.emulatorBridge.activateInput(256, value: 1, playerIndex: 0)
            // Holding R must retain native behavior and never inject a warp.
            XCTAssertTrue(core.resume()); try await Task.sleep(for: .seconds(3)); XCTAssertTrue(core.pause())
            XCTAssertTrue(setup.isReady, "Holding R must leave field controls available")
            core.deltaCore.emulatorBridge.deactivateInput(256, playerIndex: 0)
            XCTAssertTrue(core.resume()); try await Task.sleep(for: .seconds(3)); XCTAssertTrue(core.pause())
            let pallet = try XCTUnwrap(captured.snapshot().last?.player)
            XCTAssertEqual(pallet.mapGroup, 5); XCTAssertEqual(pallet.mapNumber, 3)
            XCTAssertNotNil(pallet.scene)
            XCTAssertTrue(setup.isReady, "Native R must not inject a Debug return warp")
        }
    }

    func testInterruptedViridianMartDoorEntry() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(ProcessInfo.processInfo.environment["BOUND_NATIVE_FIXTURE_NAME"] ?? "MultiplayerValidation")
        let romURL = root.appendingPathComponent("RadicalRed.gba")
        guard FileManager.default.fileExists(atPath: romURL.path) else { throw XCTSkip("Requires owned ROM fixture") }
        let profile = try BoundPlayerROMProfile(rom: Data(contentsOf: romURL))
        let output = root.appendingPathComponent("mart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav")
        try Data(repeating: 0xFF, count: 0x20000).write(to: battery)
        let core = try XCTUnwrap(EmulatorCore(game: ReplayGame(fileURL: romURL, gameSaveURL: battery), options: [.metal: true]))
        let setup = NativePlayerSceneSetup(core: core, debugPlayer: 1)
        let captured = ReplayReadings()
        let booted = expectation(description: "Admitted native field")
        var ready = false, frame: UInt64 = 0
        core.updateHandler = { core in
            autoreleasepool {
                setup.receive(core); frame += 1
                BoundVBABattleBridge.enforceSoulLink()
                BoundVBABattleBridge.advanceSharedWorld()
                guard let memory = BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }) else { return }
                let reading = BoundPlayerStateDecoder.read(profile: profile, memory: memory, frame: frame, includeScene: true)
                captured.append(reading)
                if !ready, setup.isReady, reading.player?.scene != nil { ready = true; booted.fulfill() }
            }
        }
        defer { _ = core.stop() }
        core.rate = 8; XCTAssertTrue(core.start())
        await fulfillment(of: [booted], timeout: 60)
        XCTAssertTrue(core.pause()); core.rate = 1
        XCTAssertTrue(BoundVBABattleBridge.installSoulLink())
        XCTAssertTrue(BoundVBABattleBridge.installSharedWorld())
        let checkpoint = root.appendingPathComponent("mart-stuck.state")
        guard FileManager.default.fileExists(atPath: checkpoint.path) else { throw XCTSkip("Optional private interrupted Mac checkpoint") }
        XCTAssertTrue(BoundVBABattleBridge.restoreServerState(try Data(contentsOf: checkpoint)))
        XCTAssertTrue(core.resume()); try await Task.sleep(for: .seconds(4)); XCTAssertTrue(core.pause())
        NSLog("Mart diagnostics: %@ native=%@ reading=%@", output.path, BoundVBABattleBridge.qaNuggetBridgeStatus(), String(describing: captured.snapshot().last))
        let interior = try XCTUnwrap(captured.snapshot().last?.player)
        XCTAssertEqual(interior.mapGroup, 5); XCTAssertEqual(interior.mapNumber, 3)
        XCTAssertNotNil(interior.scene)
    }

    func testActualPalletRouteOneCrossingKeepsDecodedScene() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProcessInfo.processInfo.environment["BOUND_NATIVE_FIXTURE_NAME"] ?? "MultiplayerValidation")
        let romURL = ProcessInfo.processInfo.environment["BOUND_MOVEMENT_ROM"].map { URL(fileURLWithPath:$0) }
            ?? root.appendingPathComponent("RadicalRed.gba")
        guard FileManager.default.fileExists(atPath: romURL.path) else { throw XCTSkip("Requires owned ROM fixture") }
        let romImage=try Data(contentsOf:romURL)
        if let expected=ProcessInfo.processInfo.environment["BOUND_MOVEMENT_SHA256"] {
            XCTAssertEqual(SHA256.hash(data:romImage).map{String(format:"%02x",$0)}.joined(),expected)
        }
        let profile = try BoundPlayerROMProfile(rom:romImage)
        let output = root.appendingPathComponent("map-crossing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav")
        try Data(repeating: 0xFF, count: 0x20000).write(to: battery)
        let core = try XCTUnwrap(EmulatorCore(game: ReplayGame(fileURL: romURL, gameSaveURL: battery), options: [.metal: true]))
        let setup = NativePlayerSceneSetup(core: core)
        let captured = ReplayReadings(), presented = ReplayReadings()
        let compositor = BoundPresenceFrameCompositor()
        let booted = expectation(description: "Admitted native field")
        var ready = false, frame: UInt64 = 0
        core.updateHandler = { core in
            autoreleasepool {
                setup.receive(core); compositor.receive(core); frame += 1
                guard let memory = BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }) else { return }
                let reading = BoundPlayerStateDecoder.read(profile: profile, memory: memory, frame: frame, includeScene: true)
                captured.append(reading)
                if !ready, setup.isReady, reading.player?.scene != nil { ready = true; booted.fulfill() }
            }
        }
        defer { _ = core.stop() }
        core.rate = 8; XCTAssertTrue(core.start())
        await fulfillment(of: [booted], timeout: 60)
        XCTAssertTrue(core.pause()); core.rate = 1
        let warpFrame = captured.snapshot().last?.frame ?? 0
        XCTAssertTrue(BoundVBABattleBridge.qaWarpPalletEntrance())
        XCTAssertTrue(core.resume())
        for _ in 0..<300 {
            // The last pre-warp frame is already in Pallet. Wait for new,
            // settled frames before measuring walking/rendering behavior.
            if let reading = captured.snapshot().last, reading.frame >= warpFrame + 120,
               let p = reading.player, p.mapGroup == 3, p.mapNumber == 0, p.scene != nil,
               setup.isReady { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(core.pause())
        XCTAssertTrue(setup.isReady, "Setup warp must finish before the crossing begins")
        let start = captured.snapshot().count
        let waitingFriend = try XCTUnwrap(captured.snapshot().last.flatMap(BoundPresencePose.init(reading:)))
        compositor.configure(profile: profile, pose: waitingFriend, coreID: ObjectIdentifier(core))
        compositor.observeFrame = { reading, rendered, pixels in
            presented.append(reading)
            if let scene = reading.player?.scene, let rendered,
               abs(rendered.y - Double(scene.worldFoot.y)) >= 32 {
                let origin = BoundPlayerViewport.origin(pose: rendered, scene: scene)
                if origin.x >= 0, origin.x + 16 <= 240, origin.y >= 32, origin.y + 32 <= 160 {
                    XCTAssertGreaterThan(pixels, 0, "Stationary friend vanished from the actual native presentation")
                }
            }
        }
        try core.videoManager.snapshot()?.pngData()?.write(to: output.appendingPathComponent("pallet.png"))
        // Hold B and use native running shoes to reproduce a stationary peer
        // viewed by a running player crossing the seam in both directions.
        core.deltaCore.emulatorBridge.activateInput(2, value: 1, playerIndex: 0)
        var fastForwardFrame: UInt64?
        // Cross the seam and turn back on the clear road before the grass;
        // a wild battle would intentionally remove the overworld presentation.
        for (input, rate, milliseconds) in [(64, 1.0, 650), (128, 1.0, 650), (32, 3.0, 1200), (16, 3.0, 1200)] {
            if rate > 1, fastForwardFrame == nil { fastForwardFrame = captured.snapshot().last?.frame }
            core.rate = rate
            core.deltaCore.emulatorBridge.activateInput(input, value: 1, playerIndex: 0)
            XCTAssertTrue(core.resume())
            try await Task.sleep(for: .milliseconds(milliseconds))
            XCTAssertTrue(core.pause())
            core.deltaCore.emulatorBridge.deactivateInput(input, playerIndex: 0)
        }
        let crossings = Array(captured.snapshot().dropFirst(start))
        let diagnostic = crossings.map { r -> [String: Any] in
            ["frame": r.frame, "status": r.status.rawValue, "detail": r.detail,
             "map": r.player.map { [$0.mapGroup, $0.mapNumber] } ?? [],
             "tile": r.player.map { [$0.tile.x, $0.tile.y, $0.elevation] } ?? [],
             "scene": r.player?.scene != nil,
             "foot": r.player?.scene.map { [$0.worldFoot.x, $0.worldFoot.y] } ?? [],
             "camera": r.player?.scene.map { [$0.camera.x, $0.camera.y] } ?? []]
        }
        try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("frames.json"))
        NSLog("Native map crossing diagnostics: %@", output.path)
        let route = crossings.filter { $0.player?.mapNumber == 19 }
        XCTAssertGreaterThan(presented.snapshot().count, 60, "Exercise the actual video-renderer delegate, not only a UIKit overlay")
        let missing = presented.snapshot().filter { $0.status != .live || $0.player?.scene == nil }
        XCTAssertTrue(missing.isEmpty, "No presentation gaps while running across the seamless boundary: \(missing.prefix(3))")
        XCTAssertGreaterThan(route.count, 10, "Must walk into Route 1, not just warp to it")
        XCTAssertGreaterThan(route.filter { $0.player?.scene != nil }.count, 10)
        XCTAssertEqual(crossings.last?.player?.mapNumber, 0, "Must walk back into Pallet Town")
        XCTAssertNotNil(crossings.last?.player?.scene)
        let stationary = try XCTUnwrap(crossings.first { $0.player?.mapNumber == 0 && $0.player?.scene != nil })
        let stationaryPose = try XCTUnwrap(BoundPresencePose(reading: stationary))
        let stationaryViewer = try XCTUnwrap(stationary.player)
        let receiver = BoundLivePresenceSession(), sender = UUID()
        receiver.setROMVerified(true, profile: profile); receiver.setEnabled(true); receiver.start { _ in true }
        var previousSmoothed: BoundRecordedPlayerPose?
        var visibleAcrossBoundary = 0
        var clippedRoadFrames: [String] = []
        // Both viewpoints use actual RAM tilemaps/cameras and ROM connections:
        // one player waits in Pallet while the other walks into Route 1.
        for (index, reading) in crossings.enumerated() {
            let now = 20 + Double(index) / 60
            let packet = BoundPresencePacket(version: 1, rom: profile.gameProfile.romSHA256,
                sender: sender, receiver: receiver.epoch, sequence: UInt64(index + 1), time: now - 10,
                pose: BoundPresencePose(reading: reading))
            receiver.receive(try XCTUnwrap(packet.encoded()), at: now)
            if let smoothed = receiver.pose(at: now + 0.05)?.rendered(profile: profile, viewer: stationaryViewer) {
                if let previousSmoothed {
                    // Fast-forward can batch three native 2px running steps
                    // between host samples. Keep the tighter normal-speed
                    // bound for both actual town/route seam crossings.
                    let maximumStep = reading.frame >= (fastForwardFrame ?? .max) ? 6.01 : 4.01
                    XCTAssertLessThanOrEqual(abs(smoothed.x - previousSmoothed.x) + abs(smoothed.y - previousSmoothed.y), maximumStep,
                        "Crossing a connected map must not jump ahead of delayed interpolation")
                }
                previousSmoothed = smoothed
            }
            guard reading.player?.scene != nil else { continue }
            let moving = try XCTUnwrap(reading.player), movingPose = try XCTUnwrap(receiver.pose(at: now + 0.101))
            XCTAssertEqual(movingPose.mapNumber, moving.mapNumber, "The receiving client must switch maps with the native sender")
            for (peer, viewer) in [(movingPose, stationaryViewer), (stationaryPose, moving)] {
                let rendered = try XCTUnwrap(peer.rendered(profile: profile, viewer: viewer))
                let scene = try XCTUnwrap(viewer.scene)
                let origin = BoundPlayerViewport.origin(pose: rendered, scene: scene)
                guard abs(rendered.y - Double(scene.worldFoot.y)) >= 32,
                      origin.x >= 0, origin.x + 16 <= 240, origin.y >= 0, origin.y + 32 <= 160 else { continue }
                let rgba = BoundRecordedPlayerRasterizer.rgba(pose: rendered, scene: scene).0
                let visible = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] != 0 }.count
                XCTAssertGreaterThan(visible, 0, "Native road sprite disappeared: viewer \(viewer.mapNumber), peer \(peer.mapNumber), origin \(origin)")
                let opaque = (0..<32).reduce(0) { count, y in
                    count + (0..<16).filter { rendered.appearance.colorIndex(x: $0, y: y) != 0 }.count
                }
                // The real, visible Pallet/Route name popup legitimately
                // covers pixels. Terrain on the entrance path must not.
                let ui = BoundPlayerBackground(tiles: scene.background.tiles,
                    layers: scene.background.layers.filter(\.masksWholeTiles))
                let uiPixels = (0..<32).reduce(0) { count, y in count + (0..<16).filter {
                    rendered.appearance.colorIndex(x: $0, y: y) != 0 && ui.covers(x: origin.x + $0, y: origin.y + y, priority: rendered.appearance.priority)
                }.count }
                if visible != opaque - uiPixels {
                    clippedRoadFrames.append("\(viewer.mapNumber)/\(peer.mapNumber) \(origin) pixels=\(visible)/\(opaque - uiPixels)")
                }
                if peer.mapNumber != viewer.mapNumber { visibleAcrossBoundary += 1 }
            }
        }
        XCTAssertGreaterThan(visibleAcrossBoundary, 10)
        XCTAssertEqual(receiver.receivedPackets, crossings.count)
        XCTAssertTrue(clippedRoadFrames.isEmpty, "The clear entrance path must not partially erase the friend: \(clippedRoadFrames.prefix(3))")
    }

    func testActualVBAMRecordingAndReplayAgainstMovingCamera() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProcessInfo.processInfo.environment["BOUND_NATIVE_FIXTURE_NAME"] ?? "MultiplayerValidation", isDirectory: true)
        let rom = root.appendingPathComponent("RadicalRed.gba")
        guard FileManager.default.fileExists(atPath: rom.path) else { throw XCTSkip("Install private fixtures per Docs/BOUND-MULTIPLAYER.md") }
        let originalROM = SHA256.hash(data: try Data(contentsOf: rom))
        let battery = root.appendingPathComponent("vbam-replay-test-\(UUID().uuidString).sav")
        let blankInput = Data(repeating: 0xFF, count: 131_072)
        let originalInput = SHA256.hash(data: blankInput)
        try blankInput.write(to: battery, options: .atomic)
        // This tests a native cold start and camera replay, not SRAM restore.
        // The blank input is fenced; the cartridge initializes its own state.
        XCTAssertTrue(BoundVBABattleBridge.setServerOnlyGameSave(true, for: battery))
        let core = try XCTUnwrap(EmulatorCore(game: ReplayGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = windowScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: windowScene), owner = UIViewController(), gameView = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.frame = window.bounds
        owner.view.backgroundColor = .black
        gameView.frame = CGRect(x: 0, y: 180, width: owner.view.bounds.width, height: owner.view.bounds.width * 2 / 3)
        owner.view.addSubview(gameView); core.add(gameView)
        let display = BoundPlayerStateDisplay(), readings = ReplayReadings()
        let oldPreference = UserDefaults.standard.object(forKey: BoundPlayerStatePreferences.key)
        let oldDeveloperPreference = UserDefaults.standard.object(forKey: BoundDeveloperFeatures.key)
        UserDefaults.standard.set(true, forKey: BoundDeveloperFeatures.key)
        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        display.install(in: owner); display.bind(core: core); display.layout(in: owner, gameView: gameView)
        defer {
            BoundVBABattleBridge.resetFriendDialogueOwner()
            display.stop(); _ = core.stop(); window.isHidden = true; oldWindow?.makeKeyAndVisible()
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: BoundPlayerStatePreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: BoundPlayerStatePreferences.key) }
            UserDefaults.standard.set(oldDeveloperPreference, forKey: BoundDeveloperFeatures.key)
        }
        let probe = display.probe, booted = expectation(description: "VBA-M overworld")
        let setup = NativePlayerSceneSetup(core: core, debugPlayer: 1,
            playerProfile: .init(name: "RED", gender: 0))
        var bootFinished = false
        core.updateHandler = { core in
            setup.receive(core)
            if let reading = probe.receive(core), reading.status == .live, setup.isReady, !bootFinished {
                bootFinished = true; booted.fulfill()
            }
        }
        core.rate = 8; XCTAssertTrue(core.start()); await fulfillment(of: [booted], timeout: 60)
        XCTAssertTrue(core.pause()); core.rate = 1
        let nativeTrainer = try MultiRedAdapter.debugTrainer(core: core)
        XCTAssertEqual(nativeTrainer.id, 0x12345678); XCTAssertEqual(nativeTrainer.name, "RED")
        XCTAssertEqual(nativeTrainer.gender, 0); XCTAssertTrue(setup.isReady)
        let nativeRAM = try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory: {
            core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1)
        }))
        XCTAssertEqual(nativeRAM.bytes(at: 0x02024029, count: 1), [1])
        let nativeParty = BoundSoulMon.decode(Data(try XCTUnwrap(nativeRAM.bytes(at: 0x02024284, count: 100))), stride: 100)
        XCTAssertEqual(nativeParty.count, 1)
        XCTAssertEqual(nativeParty.first?.identity.trainer, 0x12345678)
        XCTAssertEqual(nativeParty.first?.species, 4); XCTAssertEqual(nativeParty.first?.level, 5)
        // Exercise the same real native message window whose palette-only
        // clear exposed the clipping regression. The new cold start must not
        // depend on a historical seed having happened to open that window.
        XCTAssertTrue(BoundVBABattleBridge.beginFriendDialogue(2, text: "Camera replay check."))
        let dialogueClosed = expectation(description: "Native message closes before camera recording")
        var dialogueInput = 0, finishedDialogue = false
        core.updateHandler = { core in
            setup.receive(core)
            let status = BoundVBABattleBridge.advanceFriendDialogue()
            if dialogueInput == 0, status["menuReady"] as? Bool == true {
                core.deltaCore.emulatorBridge.activateInput(1, value: 1, playerIndex: 0)
                dialogueInput = 1
            } else if dialogueInput == 1 {
                core.deltaCore.emulatorBridge.deactivateInput(1, playerIndex: 0)
                dialogueInput = 2
            }
            if dialogueInput == 2, status["active"] as? Bool == false,
               status["ready"] as? Bool == true, !finishedDialogue {
                finishedDialogue = true; dialogueClosed.fulfill()
            }
        }
        XCTAssertTrue(core.resume()); await fulfillment(of: [dialogueClosed], timeout: 10)
        XCTAssertTrue(core.pause()); XCTAssertTrue(finishedDialogue)
        gameView.frame = CGRect(x: 0, y: 180, width: owner.view.bounds.width, height: owner.view.bounds.width * 2 / 3)
        gameView.layoutIfNeeded()

        func movement(_ segments: [(Int, Int)], name: String) async {
            let done = expectation(description: name)
            var frame = 0, lastMask = 0, finished = false
            let duration = segments.reduce(0) { $0 + $1.1 }
            core.updateHandler = { core in
                setup.receive(core)
                if let reading = probe.receive(core) {
                    readings.append(reading)
                }
                var start = 0, mask = 0
                for (buttons, count) in segments {
                    if frame >= start, frame < start + count { mask = buttons; break }; start += count
                }
                for bit in [16, 32, 64, 128] where (mask & bit) != (lastMask & bit) {
                    if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
                    else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
                }
                lastMask = mask; frame += 1
                if frame > duration, !finished { finished = true; done.fulfill() }
            }
            XCTAssertTrue(core.resume()); await fulfillment(of: [done], timeout: 20)
            XCTAssertTrue(core.pause())
        }

        UserDefaults.standard.set(false, forKey: BoundPlayerStatePreferences.key)
        NotificationCenter.default.post(name: BoundPlayerStatePreferences.didChange, object: nil)
        display.recordingSession.record()
        XCTAssertTrue(display.hud.isHidden, "Recording works independently of the diagnostic card")
        await movement([(32, 40), (64, 40), (16, 40), (128, 40), (0, 40)], name: "Record four directions")
        let captured = readings.snapshot(), scenes = captured.compactMap { $0.player?.scene }
        let diagnostic: [String: Any] = ["readings": captured.count, "scenes": scenes.count,
            "camera": scenes.prefix(40).map { [$0.camera.x, $0.camera.y] },
            "world": scenes.prefix(40).map { [$0.worldFoot.x, $0.worldFoot.y] }]
        try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("vbam-replay-diagnostic.json"), options: .atomic)
        XCTAssertGreaterThan(scenes.count, 100)
        XCTAssertTrue(display.recordingSession.hasRecording)
        XCTAssertGreaterThan(display.recordingSession.track.samples.count, 60)
        XCTAssertGreaterThan(Set(scenes.map { $0.camera.x }).count, 16)
        XCTAssertGreaterThan(Set(scenes.map { $0.worldFoot.x }).count, 16)
        XCTAssertGreaterThan(Set(scenes.map(\.appearance)).count, 6)

        // Exercise the actual native tilemaps, not just a zero-filled synthetic
        // scene. Closing native windows leaves palette-only entries behind.
        var clearedWindowTiles = 0
        for scene in scenes {
            for layer in scene.background.layers where layer.masksWholeTiles {
                let windows = BoundPlayerBackground(tiles: Data(), layers: [layer])
                for y in stride(from: 0, to: 160, by: 8) {
                    for x in stride(from: 0, to: 240, by: 8) {
                        let offset = (((y + layer.scrollY) & 255) / 8 * 32 + ((x + layer.scrollX) & 255) / 8) * 2
                        let entry = Int(layer.map[offset]) | Int(layer.map[offset + 1]) << 8
                        if entry != 0, entry & 1023 == 0 {
                            clearedWindowTiles += 1
                            XCTAssertFalse(windows.covers(x: x, y: y, priority: 2),
                                           "Native cleared window must not erase the friend: \(entry)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(clearedWindowTiles, 0, "Native run must exercise the reported window-clear regression")

        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        NotificationCenter.default.post(name: BoundPlayerStatePreferences.didChange, object: nil)
        await movement([(16, 40), (0, 8)], name: "Move viewer independently")
        display.recordingSession.play()
        // A different input route runs while the recorded player follows its own.
        var replayFrame = 0
        core.updateHandler = { core in
            setup.receive(core)
            if let reading = probe.receive(core) { readings.append(reading) }
            if replayFrame == 0 { core.deltaCore.emulatorBridge.activateInput(64, value: 1, playerIndex: 0) }
            if replayFrame == 40 { core.deltaCore.emulatorBridge.deactivateInput(64, playerIndex: 0) }
            replayFrame += 1
        }
        XCTAssertTrue(core.resume())
        var visible = 0, positions = Set<String>(), screenshot: UIImage?, replayDiagnostic: [[String: Any]] = []
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(16))
            display.refreshDisplay(); display.layout(in: owner, gameView: gameView); gameView.layoutIfNeeded()
            let current = display.hud.reading
            replayDiagnostic.append(["status": current.status.rawValue, "mode": String(describing: display.recordingSession.mode),
                "message": display.recordingSession.message, "frame": current.frame, "scene": current.player?.scene != nil,
                "pose": display.recordingSession.pose.map { [$0.x, $0.y] } ?? [],
                "pixels": display.recordedPlayerOverlay.visiblePixels,
                "layers": current.player?.scene?.background.layers.map { [$0.priority, $0.scrollX, $0.scrollY] } ?? []])
            if display.recordedPlayerOverlay.visiblePixels > 20, !display.recordedPlayerOverlay.isHidden {
                visible += 1
                positions.insert(display.recordedPlayerOverlay.accessibilityValue ?? "")
                var separation = 0.0
                if let pose = display.recordingSession.pose, let local = current.player?.scene {
                    separation = abs(pose.x - Double(local.worldFoot.x)) + abs(pose.y - Double(local.worldFoot.y))
                }
                if screenshot == nil, separation >= 32 {
                    screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                }
            }
        }
        XCTAssertGreaterThan(visible, 30); XCTAssertGreaterThan(positions.count, 10)
        XCTAssertNotNil(screenshot, "Capture two separately positioned player sprites")
        try JSONSerialization.data(withJSONObject: replayDiagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("vbam-replay-ticks.json"), options: .atomic)
        if let screenshot {
            let attachment = XCTAttachment(image: screenshot); attachment.name = "VBA-M recorded player on live map"; attachment.lifetime = .keepAlways; add(attachment)
            try screenshot.pngData()?.write(to: root.appendingPathComponent("vbam-recorded-player.png"), options: .atomic)
        }
        XCTAssertTrue(core.pause())
        XCTAssertTrue(display.recordedPlayerOverlay.isHidden)
        display.didLoadSaveState(); XCTAssertEqual(display.recordingSession.mode, .idle)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: rom)), originalROM)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: battery)), originalInput)
        let report: [String: Any] = ["engine": "VBA-M", "sceneFrames": scenes.count, "recordedSamples": display.recordingSession.track.samples.count,
            "visibleReplayTicks": visible, "distinctReplayPositions": positions.count, "cameraPixelPositions": Set(scenes.map { $0.camera.x }).count,
            "worldPixelPositions": Set(scenes.map { $0.worldFoot.x }).count, "spriteFrames": Set(scenes.map(\.appearance)).count,
            "recordedWithDiagnosticCardOff": true, "romAndBlankInputUnchanged": true,
            "nativeInitialization": "Admitted Debug New Game; original starter created by ROM; no historical save or SRAM restoration claim",
            "nativeTrainerID": nativeTrainer.id, "nativeTrainerName": nativeTrainer.name,
            "nativeDialogueOpenedAndClosed": finishedDialogue,
            "nativeStarterSpecies": nativeParty.first?.species ?? 0,
            "blankInputSHA256": originalInput.map { String(format: "%02x", $0) }.joined()]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("vbam-recorded-player-report.json"), options: .atomic)
    }
}

@MainActor
final class DirectionalFriendRouteTests: XCTestCase {
    func testRouteRefreshesForEitherPlayerMovementAndInvalidatesAtTransitions() {
        func request(map: Int = 0, x: Int = 10, elevation: Int = 3,
                     friendMap: Int = 1, friendX: Int = 20) -> BoundPlayerStateDisplay.FriendRouteRequest {
            .init(mapGroup: 3, mapNumber: map, instance: 1, tile: .init(x: x, y: 5),
                elevation: elevation, dynamicWarp: nil, access: nil,
                friendGroup: 3, friendNumber: friendMap, friendInstance: 2,
                friendTile: .init(x: friendX, y: 10))
        }
        let current = request()
        for moved in [request(x: 11), request(friendX: 21)] {
            XCTAssertNotEqual(current, moved, "Either player's movement refreshes route selection")
            XCTAssertTrue(current.sharesScope(with: moved), "Keep the exit visible during an in-map refresh")
        }
        for transitioned in [request(map: 19), request(friendMap: 19), request(elevation: 4)] {
            XCTAssertFalse(current.sharesScope(with: transitioned), "A route from an old map or elevation cannot survive a transition")
        }
    }

    func testDirectionalOverrideHidesInFrameAndPointsAcrossRoomsWithLetPassHidden() throws {
        let previous = UserDefaults.standard.object(forKey: BoundLetPassButton.key)
        UserDefaults.standard.set(false, forKey: BoundLetPassButton.key)
        defer { UserDefaults.standard.set(previous, forKey: BoundLetPassButton.key) }
        let appearance = BoundPlayerSprite(width: 16, height: 32, tiles: Data(repeating: 0x11, count: 256),
            palette: Data(repeating: 0, count: 32), flipX: false, flipY: false, priority: 2)
        // At a camera boundary the local player is far from viewport center.
        let scene = BoundPlayerScene(worldFoot: .init(x: 24, y: 32), camera: .init(x: 0, y: 0), appearance: appearance,
            background: .init(tiles: Data(repeating: 0, count: 32768), layers: []), objects: [])
        let pose = BoundRecordedPlayerPose(mapGroup: 4, mapNumber: 0, elevation: 0, x: 40, y: 32, appearance: appearance)
        let overlay = BoundRecordedPlayerOverlay(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        overlay.show(pose: pose, scene: scene, offscreenName: "Friend", drawsSprite: false, directionTarget: .init(x: 40, y: 32))
        XCTAssertFalse(overlay.isHidden)
        XCTAssertNil(overlay.offscreenIndicator)
        XCTAssertGreaterThan(overlay.visiblePixels, 0, "Direction UI preserves sprite visibility diagnostics")
        // Every edge includes a one-pixel partial sprite, then a fully offscreen
        // sprite. Camera movement alone must restore/hide the pointer immediately.
        for (x, y, visible) in [(-7.0, 32.0, true), (-8, 32, false),
                               (247, 32, true), (248, 32, false),
                               (40, 1, true), (40, 0, false),
                               (40, 191, true), (40, 192, false)] {
            let peer = BoundRecordedPlayerPose(mapGroup: 4, mapNumber: 0, elevation: 0,
                x: x, y: y, appearance: appearance)
            overlay.show(pose: peer, scene: scene, offscreenName: "Friend", drawsSprite: false,
                directionTarget: .init(x: Int(x), y: Int(y)))
            XCTAssertEqual(overlay.offscreenIndicator == nil, visible)
        }
        let offscreen = BoundRecordedPlayerPose(mapGroup: 4, mapNumber: 0, elevation: 0,
            x: 248, y: 32, appearance: appearance)
        let panned = BoundPlayerScene(worldFoot: scene.worldFoot, camera: .init(x: -16, y: 0),
            appearance: appearance, background: scene.background, objects: [])
        overlay.show(pose: offscreen, scene: panned, offscreenName: "Friend", drawsSprite: false,
            directionTarget: .init(x: 248, y: 32))
        XCTAssertNil(overlay.offscreenIndicator)
        XCTAssertGreaterThan(overlay.visiblePixels, 0)
        let occluder = BoundPlayerSceneObject(origin: .init(x: 32, y: 0), footY: 33, appearance: appearance)
        let occluded = BoundPlayerScene(worldFoot: scene.worldFoot, camera: scene.camera,
            appearance: appearance, background: scene.background, objects: [occluder])
        overlay.show(pose: pose, scene: occluded, offscreenName: "Friend", drawsSprite: false,
            directionTarget: .init(x: 40, y: 32))
        XCTAssertNil(overlay.offscreenIndicator, "Occlusion inside the frame must not create an arrow")
        XCTAssertEqual(overlay.visiblePixels, 0)
        // A route waypoint remains visible without compositing a friend through walls.
        overlay.show(pose: nil, scene: scene, offscreenName: "Friend", drawsSprite: false, directionTarget: .init(x: 24, y: 16))
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(try XCTUnwrap(overlay.offscreenIndicator).angle, -.pi / 2, accuracy: 0.001)
        overlay.show(pose: pose, scene: scene, offscreenName: nil, drawsSprite: false)
        XCTAssertNil(overlay.offscreenIndicator, "Turning the arrow off does not create a fallback indicator")
        overlay.showUnavailableRoute(friendName: "Friend")
        XCTAssertFalse(overlay.isHidden)
        XCTAssertNil(overlay.offscreenIndicator, "An unavailable route never invents a direction")
        XCTAssertTrue(overlay.subviews.compactMap { $0 as? UILabel }.contains { $0.text == "Friend · Route unavailable" && !$0.isHidden })
        overlay.show(pose: nil, scene: nil)
        XCTAssertTrue(overlay.isHidden, "No stale route status survives a disabled or missing scene")
    }
}

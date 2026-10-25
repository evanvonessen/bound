import XCTest
import UIKit
import CryptoKit
import DeltaCore
import Network
import zlib
@testable import Delta

private struct NativeBattleGame:GameProtocol {
    let fileURL:URL
    let gameSaveURL:URL
    var type:GameType { .gba }
}
private final class NativeBattleDriver:@unchecked Sendable {
    private let lock=NSLock()
    private let reader=BoundVBAPlayerStateProbe()
    private let setup:NativePlayerSceneSetup?
    private var frame=0,battleFrame:Int?,lastMask=0
    private var playing=false,moves=false,run=false,didBoot=false,didDamage=false
    private var firstMenuHP:[Int]?,firstMenuEnemyHP:[Int]?
    private var initialHP:[Int]?
    private var menuCheckStage=0,menuCheckFrame=0
    private var measuredMenuFrames:[Int]=[]
    private var checkedMoveCursor=false
    private let menuChecks=ProcessInfo.processInfo.environment["BOUND_NATIVE_LOCAL_MENUS"]=="1"
    var menuFrames:[Int] { lock.lock();defer { lock.unlock() };return measuredMenuFrames }
    var moveCursorResponded:Bool { lock.lock();defer { lock.unlock() };return checkedMoveCursor }
    let booted=XCTestExpectation(description:"Native overworld")
    let entered=XCTestExpectation(description:"Native battle")
    let damage=XCTestExpectation(description:"Native battle damage")
    init(core:EmulatorCore,profile:BoundPlayerROMProfile,admittedSetup:Bool=false) {
        setup=admittedSetup ? NativePlayerSceneSetup(core:core):nil
        reader.configure(coreID:ObjectIdentifier(core),profile:profile,active:true,status:.waiting,detail:"Native battle cold boot")
    }
    func play(moves:Bool,run:Bool=false) { lock.lock(); playing=true; self.moves=moves;self.run=run; lock.unlock() }
    var damaged:Bool { lock.lock(); defer { lock.unlock() }; return didDamage }
    var menuHP:[Int]? { lock.lock();defer { lock.unlock() };return firstMenuHP }
    var menuEnemyHP:[Int]? { lock.lock();defer { lock.unlock() };return firstMenuEnemyHP }
    func receive(_ core:EmulatorCore) {
        frame+=1
        lock.lock(); let playing=playing,moves=moves,run=run; lock.unlock()
        if !playing {
            setup?.receive(core)
            let value=reader.receive(core)
            if value?.status == .live,setup?.isReady != false,!didBoot { didBoot=true; booted.fulfill() }
            if frame%1800==0,!didBoot { NSLog("Native battle boot frame=%d status=%@ setupReady=%d",frame,String(describing:value?.status),setup?.isReady == true) }
            apply(didBoot || setup != nil ? 0:(1300..<1302).contains(frame) ? 8:(1600..<1602).contains(frame)||(2200..<2202).contains(frame) ? 1:0,core:core)
            return
        }
        let battle=BoundVBABattleBridge.isInBattle()
        if battle,battleFrame==nil { battleFrame=frame; entered.fulfill() }
        let menu=BoundVBABattleBridge.qaBattleMenu()
        if menu["battler"] != nil {
            lock.lock()
            if firstMenuHP==nil,menu["kind"] as? String == "action" {
                firstMenuHP=menu["playerHP"] as? [Int];firstMenuEnemyHP=menu["enemyHP"] as? [Int]
                NSLog("Native first action menu HP=%@ enemyHP=%@",String(describing:firstMenuHP),String(describing:firstMenuEnemyHP))
            }
            lock.unlock()
        }
        let hp=BoundVBABattleBridge.playerHP().map { $0.intValue }
        if battle,hp.first ?? 0>0,initialHP==nil { initialHP=hp }
        if battle,let initialHP,hp != initialHP {
            lock.lock(); let first = !didDamage; didDamage=true; lock.unlock()
            if first { damage.fulfill() }
        }
        if battle,menuChecks,menuCheckStage<6 {
            let kind=menu["kind"] as? String
            var mask=0
            switch menuCheckStage {
            case 0:
                if kind=="action" {
                    if lastMask==0 { menuCheckFrame=frame;menuCheckStage=1;mask=1 }
                } else { mask=frame%12<2 ? 1:0 } // Dismiss native introduction text first.
            case 1:
                if kind=="move" { lock.lock();measuredMenuFrames.append(frame-menuCheckFrame);lock.unlock();menuCheckFrame=frame;menuCheckStage=2 }
            case 2:
                if frame-menuCheckFrame==4 { mask=16 } // Growl/second move, local cursor input.
                if frame-menuCheckFrame==7 { lock.lock();checkedMoveCursor=menu["cursor"] as? Int == 1;lock.unlock() }
                if frame-menuCheckFrame>=8 { menuCheckFrame=frame;menuCheckStage=3;mask=2 } // Back, without submitting.
            case 3:
                if kind=="action" { lock.lock();measuredMenuFrames.append(frame-menuCheckFrame);lock.unlock();menuCheckFrame=frame;menuCheckStage=4 }
            case 4:
                if frame-menuCheckFrame>=4 { menuCheckFrame=frame;menuCheckStage=5;mask=1 }
            case 5:
                if kind=="move" { lock.lock();measuredMenuFrames.append(frame-menuCheckFrame);lock.unlock();menuCheckStage=6 }
            default:break
            }
            apply(mask,core:core);return
        }
        if battle,run,let cursor=menu["cursor"] as? Int {
            let button=cursor&1==0 ? 16:cursor&2==0 ? 128:1
            apply(frame%12<2 ? button:0,core:core)
        }
        else if battle,moves,let battleFrame,frame-battleFrame>120 {
            let cursor=menu["cursor"] as? Int ?? 0
            let button=menu["kind"] as? String == "move" && cursor != 0 ? (cursor&1 != 0 ? 32:64):1
            apply((frame-battleFrame)%12<2 ? button:0,core:core)
        }
        else { apply(0,core:core) }
    }
    private func apply(_ mask:Int,core:EmulatorCore) {
        for bit in [1,2,8,16,32,64,128] where mask&bit != lastMask&bit {
            if mask&bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit,value:1,playerIndex:0) }
            else { core.deltaCore.emulatorBridge.deactivateInput(bit,playerIndex:0) }
        }
        lastMask=mask
    }
}

private final class NativeTradeDriver:@unchecked Sendable {
    private let lock=NSLock(),reader=BoundVBAPlayerStateProbe()
    private let setup:NativePlayerSceneSetup?
    private var frame=0,lastMask=0,playing=false,boot=false
    private var callbackID = -1,stateFrame=0
    private var count=0,marker=0
    private var offersEnabled:Bool,exitEnabled=true
    let booted=XCTestExpectation(description:"Trade overworld boot")
    init(core:EmulatorCore,profile:BoundPlayerROMProfile,offersEnabled:Bool=true,admittedSetup:Bool=false) {
        self.offersEnabled=offersEnabled
        setup=admittedSetup ? NativePlayerSceneSetup(core:core):nil
        reader.configure(coreID:ObjectIdentifier(core),profile:profile,active:true,status:.waiting,detail:"Trade boot")
    }
    func begin() { lock.lock(); playing=true; lock.unlock() }
    func progress(offers:Bool,exit:Bool) { lock.lock(); offersEnabled=offers; exitEnabled=exit; lock.unlock() }
    var currentMarker:Int { lock.lock(); defer { lock.unlock() }; return marker }
    func receive(_ core:EmulatorCore) {
        frame+=1
        lock.lock(); let playing=playing,offersEnabled=offersEnabled,exitEnabled=exitEnabled; lock.unlock()
        if !playing {
            setup?.receive(core)
            if reader.receive(core)?.status == .live,setup?.isReady != false,!boot { boot=true; booted.fulfill() }
            if frame%1800==0,!boot { NSLog("Native trade boot frame=%d setupReady=%d",frame,setup?.isReady == true) }
            apply(boot || setup != nil ? 0:(1300..<1302).contains(frame) ? 8:(1600..<1602).contains(frame)||(2200..<2202).contains(frame) ? 1:0,core)
            return
        }
        let value=BoundVBABattleBridge.advanceAndObserve()
        let callback=value["callback"] as? Int ?? 0
        let trades=value["tradeCount"] as? Int ?? 0
        let bytes=BoundVBABattleBridge.qaTradeParty()
        lock.lock(); marker=bytes.count>8 ? Int(bytes[8]):0; count=trades; lock.unlock()
        var mask=0,id = -1,cursor = -1
        if callback==0x0804D639,
           let p=core.deltaCore.emulatorBridge.readMemory?(at:0x39DA8,size:4),p.count==4 {
            let address=p.enumerated().reduce(0) { $0 | Int($1.element)<<($1.offset*8) }
            if (0x02000000..<0x02040000-128).contains(address),
               let menu=core.deltaCore.emulatorBridge.readMemory?(at:address-0x02000000+0x8000,size:128),menu.count==128 {
                id=Int(menu[0x6F]); cursor=Int(menu[0x35])
            }
        }
        if id != callbackID {
            NSLog("Trade fixture menu id=%d cursor=%d native=%08x trades=%d",id,cursor,callback,trades)
            callbackID=id; stateFrame=frame
        }
        let elapsed=frame-stateFrame
        if id==0 {
            if trades==0 { mask=offersEnabled && elapsed%30<2 ? 1:0 }
            else if exitEnabled,cursor != 12 { mask=elapsed%30<2 ? 64:0 } // Up selects native Cancel with one party member.
            else if exitEnabled { mask=elapsed%30<2 ? 1:0 }
        } else if id==1 {
            if elapsed==8 || elapsed==9 { mask=128 } // Native Summary/Trade selector: Down.
            else if elapsed>=20 { mask=elapsed%30<2 ? 1:0 }
        } else if [3,4,7,14].contains(id) { mask=elapsed%30<2 ? 1:0 }
        else if value["tradeOpened"] as? Bool != true { mask=frame%30<2 ? 1:0 } // Save/link confirmations only.
        apply(mask,core)
    }
    private func apply(_ mask:Int,_ core:EmulatorCore) {
        for bit in [1,2,8,64,128] where mask&bit != lastMask&bit {
            if mask&bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit,value:1,playerIndex:0) }
            else { core.deltaCore.emulatorBridge.deactivateInput(bit,playerIndex:0) }
        }
        lastMask=mask
    }
}

/// Captures native state only on the completed-frame owner. The test thread
/// changes bounded input requests, never reads a running core directly.
private final class BridgePairDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var frame = 0, lastMask = 0, wasBattle = false, up = false, autoA = false
    private var value: [String: Any] = [:], opponents: [Int] = []
    func input(up: Bool = false, autoA: Bool = false) {
        lock.lock(); self.up = up; self.autoA = autoA; lock.unlock()
    }
    var observation: [String: Any] { lock.lock(); defer { lock.unlock() }; return value }
    var entries: [Int] { lock.lock(); defer { lock.unlock() }; return opponents }
    func receive(_ core: EmulatorCore) {
        frame += 1
        if core.audioManager.isEnabled { core.audioManager.isEnabled = false }
        let state = BoundVBABattleBridge.qaNuggetBridgeStatus()
        let battle = state["battle"] as? Bool == true
        lock.lock()
        value = state
        if battle && !wasBattle { opponents.append(state["opponent"] as? Int ?? -1) }
        let up = up, autoA = autoA
        lock.unlock()
        wasBattle = battle
        // Never tap A in an idle field: after dismissing a denied encounter,
        // that would immediately talk to the adjacent trainer again.
        let talking = state["ready"] as? Bool != true
        let mask = (up ? 64 : 0) | (autoA && talking && frame % 24 < 2 ? 1 : 0)
        for bit in [1,64] where mask & bit != lastMask & bit {
            if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
            else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
        }
        lastMask = mask
    }
}

@MainActor
final class NativeBattleRuntimeTests:XCTestCase {
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

    func testActualFrameSnapshotsReleaseTemporaryMemory() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["BOUND_FRAME_MEMORY_RUNTIME"] == "1" else {
            throw XCTSkip("Requires the explicit owned-simulator frame memory fixture")
        }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FullAppGameplayQA")
        let rom = root.appendingPathComponent("RadicalRed.gba")
        let originalROM = try Data(contentsOf: rom), profile = try BoundPlayerROMProfile(rom: originalROM)
        let output = root.appendingPathComponent("frame-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav")
        try Data(repeating: 0xFF, count: 0x20000).write(to: battery)
        let core = try XCTUnwrap(EmulatorCore(game: NativeBattleGame(fileURL: rom, gameSaveURL: battery), options: [.metal:true]))
        for _ in 0..<100 where UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene), owner = UIViewController(), view = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 150, width: window.bounds.width, height: window.bounds.width * 2/3); core.add(view)
        let driver = NativeBattleDriver(core: core, profile: profile, admittedSetup: true)
        core.audioManager.pausesOtherAudio = false; core.audioManager.mixesWithOtherAudio = true; core.audioManager.isEnabled = false
        core.updateHandler = { core in BoundFrameMemory.perform { driver.receive(core) } }
        defer { _ = core.pause(); _ = core.stop(); window.isHidden = true; previous?.makeKeyAndVisible() }
        core.rate = 8; XCTAssertTrue(core.start()); core.deltaCore.emulatorBridge.audioRenderer = nil
        await fulfillment(of: [driver.booted], timeout: 90); _ = core.pause()
        XCTAssertEqual((BoundVBABattleBridge.soulLinkSnapshot()["boxes"] as? Data)?.count, 25 * 30 * 58)
        // A single long-lived worker turn models Delta's emulation loop. The
        // paused core makes each native observation identical; no frame, save,
        // party, or caller-retained buffer changes during either measurement.
        let measurements: [String:Int] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                func resident() -> Int {
                    var info = mach_task_basic_info()
                    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
                    let result = withUnsafeMutablePointer(to: &info) { pointer in
                        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                        }
                    }
                    return result == KERN_SUCCESS ? Int(info.resident_size) : -1
                }
                var observedBytes = 0, invalidSnapshots = 0
                func observe() {
                    let snapshot = BoundVBABattleBridge.soulLinkSnapshot()
                    let count = (snapshot["boxes"] as? Data)?.count ?? 0
                    observedBytes += count
                    if count != 25 * 30 * 58 || snapshot["ready"] as? Bool != true { invalidSnapshots += 1 }
                }
                for _ in 0..<128 { BoundFrameMemory.perform(observe) }
                let unpooledGrowth = autoreleasepool { () -> Int in
                    let before = resident()
                    for _ in 0..<1024 { observe() }
                    return resident() - before
                }
                for _ in 0..<128 { BoundFrameMemory.perform(observe) }
                let beforePooled = resident()
                var pooledPeak = beforePooled
                for index in 0..<4096 {
                    BoundFrameMemory.perform(observe)
                    if index % 256 == 255 { pooledPeak = max(pooledPeak, resident()) }
                }
                continuation.resume(returning: ["unpooledSnapshots":1024,"pooledSnapshots":4096,
                    "unpooledGrowth":unpooledGrowth,"pooledPeakGrowth":pooledPeak - beforePooled,
                    "observedBoxBytes":observedBytes,"invalidSnapshots":invalidSnapshots])
            }
        }
        NSLog("Actual native frame memory %@", String(describing: measurements))
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("measurements.json"))
        XCTAssertEqual(measurements["invalidSnapshots"], 0)
        XCTAssertGreaterThan(measurements["unpooledGrowth"] ?? 0, 32 * 1024 * 1024,
            "The control must reproduce retained Objective-C native-snapshot allocations")
        XCTAssertLessThan(measurements["pooledPeakGrowth"] ?? Int.max, 16 * 1024 * 1024,
            "Four times as many production-scoped observations must have bounded working memory")
        XCTAssertEqual(try Data(contentsOf: rom), originalROM)
    }

    func testActualSharedWorldCollisionAndNativeCoexistence() async throws {
        try await verifySharedWorldRuntime(sightline: false)
    }

    func testTwoPlayerNuggetBridgePrerequisite() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["BOUND_SHARED_WORLD_PAIR"] == "1",
              let peer = env["BOUND_NATIVE_BATTLE_PEER"], ["A","B"].contains(peer),
              let port = env["BOUND_NATIVE_BATTLE_PORT"].flatMap(Int.init),
              let relayPort = env["BOUND_NATIVE_BATTLE_RELAY_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Requires two dedicated simulators and the --shared-world coordinator")
        }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FullAppGameplayQA")
        let rom = root.appendingPathComponent("RadicalRed.gba"), seed = root.appendingPathComponent("seed.sav")
        let originalROM = try Data(contentsOf: rom), originalSeed = try Data(contentsOf: seed)
        let output = root.appendingPathComponent("paired-nugget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav"); try originalSeed.write(to: battery)
        let profile = try BoundPlayerROMProfile(rom: originalROM)
        let core = try XCTUnwrap(EmulatorCore(game: NativeBattleGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene), owner = UIViewController(), view = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 150, width: window.bounds.width, height: window.bounds.width * 2/3); core.add(view)
        let boot = NativeBattleDriver(core: core, profile: profile), driver = BridgePairDriver()
        let world = BoundSharedProgression(), probe = world.probe
        var channel: NativeBattleRelayChannel?, transportFailed = false
        var cases: [[String: Any]] = []
        var pumping = true
        core.audioManager.pausesOtherAudio = false
        core.audioManager.mixesWithOtherAudio = true
        core.audioManager.isEnabled = false
        core.updateHandler = { core in
            if core.audioManager.isEnabled { core.audioManager.isEnabled = false }
            boot.receive(core)
        }
        defer {
            pumping = false; channel?.close(); world.stop(); _ = core.pause()
            BoundVBABattleBridge.closeSharedWorld(); _ = core.stop()
            window.isHidden = true; previous?.makeKeyAndVisible()
        }
        core.rate = 8; XCTAssertTrue(core.start())
        core.deltaCore.emulatorBridge.audioRenderer = nil
        await fulfillment(of: [boot.booted], timeout: 90)
        _ = core.pause(); core.rate = 4
        world.bind(core: core)
        core.updateHandler = { core in probe.receive(core); driver.receive(core) }
        channel = NativeBattleRelayChannel(port: relayPort, peer: peer, receive: { data in
            Task { @MainActor in world.receive(data) }
        }, failed: { Task { @MainActor in transportFailed = true } })
        world.send = { channel?.send($0) == true }
        let pump = Task { @MainActor in
            while pumping && !Task.isCancelled {
                world.tick(enabled: true, connected: true)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { pump.cancel() }
        _ = core.resume()
        func wait(_ label: String, seconds: Int = 15, _ condition: () -> Bool) async throws {
            for _ in 0..<(seconds * 20) {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("\(peer) \(label): \(driver.observation), battles \(driver.entries), transport failed \(transportFailed)")
            throw NSError(domain: "PairedBridgeTimeout", code: 1)
        }
        func barrier(_ phase: Int) async throws {
            _ = try await request(port: port, peer: peer, body: ["stage":"running","phase":phase,"cases":cases])
            for _ in 0..<2400 {
                let value = try await request(port: port)
                if let peers = value["peers"] as? [String:[String:Any]], peers.count == 2,
                   peers.values.allSatisfy({ ($0["phase"] as? Int ?? -1) >= phase }) { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("\(peer) pair barrier \(phase) timed out")
            throw NSError(domain: "PairedBridgeBarrier", code: phase)
        }
        func fresh(local: Bool, remote: Bool) async throws {
            try await wait("fresh real checkpoint packets local=\(local) remote=\(remote)") {
                guard let state = world.timeline.state, world.timeline.fresh(at: ProcessInfo.processInfo.systemUptime),
                      let own = probe.read() else { return false }
                return (own.checkpoints[0x56e/8] & (1 << (0x56e%8)) != 0) == local
                    && (state.checkpoints[0x56e/8] & (1 << (0x56e%8)) != 0) == remote
            }
        }
        func warp(_ y: Int) async throws {
            driver.input(); _ = core.pause()
            XCTAssertTrue(BoundVBABattleBridge.qaWarpNuggetBridge(UInt(y)), "Warp fixture requires idle native field: \(BoundVBABattleBridge.qaNuggetBridgeStatus())")
            _ = core.resume()
            try await wait("native Route 24 warp") {
                let s = driver.observation
                return s["ready"] as? Bool == true && s["group"] as? Int == 3 && s["number"] as? Int == 43 && s["y"] as? Int == y
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = peer + " " + name; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: output.appendingPathComponent(name + ".png"))
            core.saveSaveState(to: output.appendingPathComponent(name + ".sgm"))
        }
        func attemptSecond(_ name: String, local: Bool, remote: Bool, allowed: Bool) async throws {
            // Restore this same player's earned state between independent
            // attempts. The current peer-data port is deliberately not restored.
            let origin = output.appendingPathComponent(name + "-origin.sgm")
            _ = core.pause(); core.saveSaveState(to: origin); _ = core.resume()
            try await warp(29); try await fresh(local: local, remote: remote)
            if allowed { try await barrier(8) }
            let before = driver.entries.count
            driver.input(up: true)
            try await wait("trainer #2 native approach") {
                let s = driver.observation
                return driver.entries.count > before || (s["opponent"] as? Int == 0x7b && s["ready"] as? Bool == false)
            }
            driver.input(autoA: true)
            if allowed {
                try await wait("trainer #2 real battle entry", seconds: 25) { driver.entries.count > before }
                driver.input(); _ = core.pause()
                XCTAssertEqual(driver.entries.last, 0x7b)
                XCTAssertTrue(BoundVBABattleBridge.isInBattle())
            } else {
                // Advance the trainer's ordinary introduction to its final
                // launch command, where automatic sightlines enforce the gate.
                try await wait("trainer #2 reaches the final launch guard") {
                    let script = driver.observation["script"] as? Int ?? 0
                    return driver.entries.count > before || (0x09ff0000..<0x09ff4000).contains(script)
                }
                driver.input(); try await Task.sleep(for: .milliseconds(500)); _ = core.pause()
                XCTAssertEqual(driver.entries.count, before, "Trainer #2 must stay blocked for \(name)")
                let state = BoundVBABattleBridge.qaNuggetBridgeStatus()
                NSLog("Paired bridge %@ %@ result %@",peer,name,String(describing:state))
                try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent(name + "-native.json"))
                try capture(name + "-observed")
                XCTAssertFalse(BoundVBABattleBridge.isInBattle())
                let script = try XCTUnwrap(state["script"] as? Int)
                XCTAssertTrue((0x09ff0000..<0x09ff4000).contains(script), "The game must display its real waiting dialogue: \(state)")
                XCTAssertEqual(state["secondWin"] as? Int, 0)
            }
            XCTAssertEqual(BoundVBABattleBridge.qaSharedWorldImmutableDigest(), Data(SHA256.hash(data: originalROM)))
            try capture(name)
            cases.append(["case":name,"localFirstWin":local,"peerFirstWin":remote,"trainer2Battle":allowed,"nativeBattleEntries":driver.entries])
            if !allowed {
                driver.input()
                try core.load(DeltaCore.SaveState(fileURL: origin, gameType: .gba)); _ = core.resume()
                try await fresh(local: local, remote: remote)
            }
        }
        func winFirst() async throws {
            try await warp(33)
            let before = driver.entries.count
            driver.input(up: true)
            try await wait("trainer #1 native approach") {
                let s = driver.observation
                return driver.entries.count > before || (s["opponent"] as? Int == 0x6e && s["ready"] as? Bool == false)
            }
            driver.input(autoA: true)
            try await wait("trainer #1 real battle starts", seconds: 25) { driver.entries.count > before }
            XCTAssertEqual(driver.entries.last, 0x6e)
            try await wait("trainer #1 native victory flag and overworld return", seconds: 75) {
                let s = driver.observation
                return s["firstWin"] as? Int == 1 && s["ready"] as? Bool == true && s["battle"] as? Bool == false
            }
            driver.input(); _ = core.pause(); try capture("earned-first-win"); _ = core.resume()
        }
        try await wait("game ABI attachment") { probe.read() != nil }
        _ = core.pause(); XCTAssertTrue(BoundVBABattleBridge.qaPrepareNuggetBridgeFixture()); _ = core.resume()
        try await warp(33); try await fresh(local: false, remote: false)
        let initial = output.appendingPathComponent("initial.sgm"), earned = output.appendingPathComponent("earned.sgm")
        _ = core.pause(); core.saveSaveState(to: initial); _ = core.resume()
        try await barrier(0)
        try await attemptSecond("neither-won", local: false, remote: false, allowed: false)
        try await barrier(1)
        if peer == "A" { try await winFirst() }
        try await barrier(2)
        try await attemptSecond("only-a-won", local: peer == "A", remote: peer == "B", allowed: false)
        try await barrier(3)
        if peer == "A" {
            _ = core.pause(); core.saveSaveState(to: earned)
            try core.load(DeltaCore.SaveState(fileURL: initial, gameType: .gba)); _ = core.resume()
        }
        try await barrier(4)
        if peer == "B" { try await winFirst() }
        try await barrier(5)
        try await attemptSecond("only-b-won", local: peer == "B", remote: peer == "A", allowed: false)
        try await barrier(6)
        if peer == "A" {
            _ = core.pause(); try core.load(DeltaCore.SaveState(fileURL: earned, gameType: .gba)); _ = core.resume()
        }
        try await barrier(7)
        try await attemptSecond("both-won", local: true, remote: true, allowed: true)
        try await barrier(9)
        XCTAssertFalse(transportFailed)
        XCTAssertEqual(try Data(contentsOf: rom), originalROM); XCTAssertEqual(try Data(contentsOf: seed), originalSeed)
        let report: [String: Any] = ["stage":"done","phase":10,"sharedWorld":true,"peer":peer,"cases":cases,
                                   "nativeBattleEntries":driver.entries,"romSHA256":BoundPlayerROMProfile.supportedSHA256,
                                   "fixture":"Native warp, cleared initial flags and boosted disposable party; both first wins are awarded by real battles. Local reliable relay carries production BWP2 packets."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        _ = try await request(port: port, peer: peer, body: report)
    }

    func testActualSharedWorldSightlineLaunchWaits() async throws {
        try await verifySharedWorldRuntime(sightline: true)
    }

    private func verifySharedWorldRuntime(sightline: Bool) async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["BOUND_WORLD_RUNTIME"] == "1" else {
            throw XCTSkip("Requires the explicit owned-simulator shared world fixture")
        }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FullAppGameplayQA")
        let rom = root.appendingPathComponent("RadicalRed.gba"), seed = root.appendingPathComponent("seed.sav")
        let originalROM = try Data(contentsOf: rom), originalSeed = try Data(contentsOf: seed)
        let output = root.appendingPathComponent("shared-world-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav"); try originalSeed.write(to: battery)
        let core = try XCTUnwrap(EmulatorCore(game: NativeBattleGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
        let profile = try BoundPlayerROMProfile(rom: originalROM)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene), owner = UIViewController(), view = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 150, width: window.bounds.width, height: window.bounds.width * 2/3); core.add(view)
        let driver = NativeBattleDriver(core: core, profile: profile), reader = BoundVBAPlayerStateProbe(), world = BoundWorldProbe()
        world.configure(core: core); world.setVerified(true)
        reader.configure(coreID: ObjectIdentifier(core), profile: profile, active: true, status: .waiting, detail: "Shared world runtime")
        core.updateHandler = { core in driver.receive(core); reader.receive(core); world.receive(core) }
        defer {
            _ = core.pause(); BoundVBABattleBridge.closeSharedWorld(); BoundVBABattleBridge.closeSoulLink(); _ = core.stop()
            window.isHidden = true; previous?.makeKeyAndVisible()
        }
        core.rate = 8; XCTAssertTrue(core.start()); await fulfillment(of: [driver.booted], timeout: 90)
        _ = core.pause(); core.rate = 1; driver.play(moves: false)
        XCTAssertTrue(BoundVBABattleBridge.installSharedWorld())
        XCTAssertEqual(BoundVBABattleBridge.qaSharedWorldImmutableDigest(), Data(SHA256.hash(data: originalROM)), "Attaching the ABI must not install game instructions")
        let state = BoundVBABattleBridge.sharedWorldSnapshot()
        let flags = try XCTUnwrap(state["checkpoints"] as? Data)
        XCTAssertEqual(flags.count, 800)
        func position() throws -> BoundPlayerState.Point {
            guard let memory = BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }) else { throw NSError(domain: "snapshot", code: 1) }
            return try XCTUnwrap(BoundPlayerStateDecoder.read(profile: profile, memory: memory, frame: 1).player?.tile)
        }
        let initial = try position()
        world.publishPolicy(enabled: true, peer: nil, fresh: false)
        _ = core.resume()
        for input in [64,128,32,16] {
            core.deltaCore.emulatorBridge.activateInput(input, value: 1, playerIndex: 0)
            try await Task.sleep(for: .milliseconds(220))
            core.deltaCore.emulatorBridge.deactivateInput(input, playerIndex: 0)
        }
        _ = core.pause(); XCTAssertEqual(try position(), initial, "A missing partner must block real native player movement in every direction")
        XCTAssertEqual(world.read()?.checkpoints, flags, "The production completed-frame mailbox must publish a usable local snapshot")
        let peer = BoundWorldState(group: try XCTUnwrap(state["group"] as? UInt8), number: try XCTUnwrap(state["number"] as? UInt8),
                                   checkpoints: flags, boulders: state["boulders"] as? Data ?? Data())
        world.publishPolicy(enabled: true, peer: peer, fresh: true)
        _ = core.resume()
        var moved = false
        for input in [64,128,32,16] {
            core.deltaCore.emulatorBridge.activateInput(input, value: 1, playerIndex: 0)
            try await Task.sleep(for: .milliseconds(220))
            core.deltaCore.emulatorBridge.deactivateInput(input, playerIndex: 0)
            _ = core.pause(); moved = try position() != initial
            if moved { break }
            _ = core.resume()
        }
        XCTAssertTrue(moved, "Fresh matching partner progress must restore ordinary native movement")
        XCTAssertEqual(BoundVBABattleBridge.sharedWorldSnapshot()["checkpoints"] as? Data, flags, "Collision gates must never edit earned progress")
        XCTAssertEqual(BoundVBABattleBridge.qaSharedWorldImmutableDigest(), Data(SHA256.hash(data: originalROM)), "All session updates are confined to the declared host data port")
        BoundVBABattleBridge.closeSharedWorld()
        XCTAssertEqual(BoundVBABattleBridge.qaSharedWorldImmutableDigest(), Data(SHA256.hash(data: originalROM)), "Closing the ABI must preserve permanent game instructions")
        XCTAssertTrue(BoundVBABattleBridge.installSharedWorld())
        XCTAssertTrue(BoundVBABattleBridge.installSoulLink(), "The integrated game and Soul Link must coexist")
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady(), "Native link admission must validate the integrated game's base view")
        BoundVBABattleBridge.setSharedWorldPeer(Data(), group: 0, number: 0, boulders: Data(), fresh: false)
        XCTAssertTrue(sightline ? BoundVBABattleBridge.qaStartSharedWorldSightlineWait() : BoundVBABattleBridge.qaStartSharedWorldWait())
        world.publishPolicy(enabled: true, peer: nil, fresh: false)
        // The native trainer command must enter the permanent waiting game script first.
        _ = core.resume(); try await Task.sleep(for: .milliseconds(350)); _ = core.pause()
        let pointer = try XCTUnwrap(core.deltaCore.emulatorBridge.readMemory?(at: 0xEB8, size: 4))
        let address = pointer.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        XCTAssertTrue((0x08000000..<0x0A000000).contains(address), "The native denied-trainer script must reside in the permanent game ROM")
        let waitURL = output.appendingPathComponent("waiting.sgm"); core.saveSaveState(to: waitURL)
        world.publishPolicy(enabled: false, peer: nil, fresh: false)
        BoundVBABattleBridge.closeSharedWorld(); BoundVBABattleBridge.closeSoulLink()
        try core.load(DeltaCore.SaveState(fileURL: waitURL, gameType: .gba))
        _ = core.resume()
        for _ in 0..<8 {
            core.deltaCore.emulatorBridge.activateInput(1, value: 1, playerIndex: 0)
            try await Task.sleep(for: .milliseconds(70))
            core.deltaCore.emulatorBridge.deactivateInput(1, playerIndex: 0)
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = core.pause()
        XCTAssertTrue(BoundVBABattleBridge.friendDialogueReady(), "The saved native waiting window must release normally after the host session is ended")
        XCTAssertEqual(try Data(contentsOf: rom), originalROM); XCTAssertEqual(try Data(contentsOf: seed), originalSeed)
    }

    func testActualNativeFriendDialogue() async throws {
        continueAfterFailure=false
        guard ProcessInfo.processInfo.environment["BOUND_INVITATION_RUNTIME"] == "1" else {
            throw XCTSkip("Requires the explicit owned-simulator native invitation fixture")
        }
        let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("FullAppGameplayQA")
        let rom=root.appendingPathComponent("RadicalRed.gba"), seed=root.appendingPathComponent("seed.sav")
        let originalROM=try Data(contentsOf:rom), originalSeed=try Data(contentsOf:seed)
        let output=root.appendingPathComponent("native-invitation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let battery=output.appendingPathComponent("work.sav"); try originalSeed.write(to:battery)
        let core=try XCTUnwrap(EmulatorCore(game:NativeBattleGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
        let scene=try await nativeWindowScene()
        let previous=scene.windows.first { $0.isKeyWindow }, window=UIWindow(windowScene:scene), owner=UIViewController(), view=GameView()
        window.rootViewController=owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame=CGRect(x:0,y:150,width:window.bounds.width,height:window.bounds.width*2/3); core.add(view)
        let profile=try BoundPlayerROMProfile(rom:originalROM)
        let driver=NativeBattleDriver(core:core,profile:profile),probe=BoundFriendDialogueProbe()
        probe.configure(core:core)
        core.updateHandler={ core in driver.receive(core); probe.receive(core) }
        defer {
            probe.show(nil); _=core.pause(); BoundVBABattleBridge.close(); _=core.stop()
            window.isHidden=true; previous?.makeKeyAndVisible()
        }
        core.rate=8; XCTAssertTrue(core.start()); await fulfillment(of:[driver.booted],timeout:90)
        _=core.pause(); core.rate=1; _=core.resume()
        func wait(_ predicate:()->Bool) async throws {
            for _ in 0..<200 {
                if predicate() { return }
                try await Task.sleep(for:.milliseconds(25))
            }
            XCTFail("Native invitation did not reach expected state")
        }
        func press(_ mask:Int) async throws {
            core.deltaCore.emulatorBridge.activateInput(mask,value:1,playerIndex:0)
            try await Task.sleep(for:.milliseconds(100))
            core.deltaCore.emulatorBridge.deactivateInput(mask,playerIndex:0)
            try await Task.sleep(for:.milliseconds(150))
        }
        for (mode,button,expected) in [(0,128,1),(1,0,1),(1,128,0),(1,2,0)] {
            let request=BoundFriendDialogueProbe.Request(id:UUID(),mode:mode,text:mode==0 ? "What would you like to do?":"Your friend wants to trade.\nWill you accept?")
            probe.show(request)
            try await wait { probe.read().menuReady }
            try await Task.sleep(for:.milliseconds(350))
            _=core.pause()
            let memory=try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory: {
                core.deltaCore.emulatorBridge.readMemory?(at:$0,size:$1)
            }))
            let reading=BoundPlayerStateDecoder.read(profile:profile,memory:memory,frame:1,includeScene:true)
            XCTAssertEqual(reading.status,.live,"Native text windows retain the field identity")
            if reading.player?.scene == nil {
                try Data(memory.workRAM).write(to:output.appendingPathComponent("dialogue-ewram.bin"))
                try Data(memory.internalRAM).write(to:output.appendingPathComponent("dialogue-iwram.bin"))
                print("DIALOGUE_SCENE_DIAGNOSTICS",output.path)
            }
            let nativeScene=try XCTUnwrap(reading.player?.scene,"Native dialogue must retain the friend-rendering scene")
            XCTAssertNotNil(BoundPresencePose(reading:reading),"Dialogue must continue publishing the standing player's appearance")
            XCTAssertTrue(nativeScene.background.layers.contains { $0.masksWholeTiles && $0.map.contains { $0 != 0 } },
                          "Native window tiles mask sprites without hiding the entire field")
            _=core.resume()
            if button==128 { try await press(128) }
            try await press(button==2 ? 2:1)
            try await wait { probe.read().id==request.id }
            XCTAssertEqual(probe.read().result,expected)
            probe.show(nil); try await wait { probe.read().ready }
            _=core.pause(); XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady(),"Native task, window, script lock and menu table must be restored"); _=core.resume()
        }
        let pending=BoundFriendDialogueProbe.Request(id:UUID(),mode:1,text:"Will you accept?")
        probe.show(pending); try await wait { probe.read().menuReady }
        probe.show(nil); try await wait { !probe.read().active && probe.read().ready }
        let detached=BoundFriendDialogueProbe.Request(id:UUID(),mode:1,text:"Will you accept?")
        probe.show(detached); try await wait { probe.read().menuReady }
        probe.configure(core:nil); probe.configure(core:core)
        try await wait { probe.read().ready && !probe.read().active }
        _=core.pause(); XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady())
        XCTAssertEqual(try Data(contentsOf:rom),originalROM); XCTAssertEqual(try Data(contentsOf:seed),originalSeed)
    }

    func testActualROMMultiplayerMailboxAndPauseGate() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["BOUND_ROM_MULTIPLAYER_RUNTIME"] == "1" else {
            throw XCTSkip("Requires the explicit owned-simulator ROM multiplayer fixture")
        }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FullAppGameplayQA")
        let rom = root.appendingPathComponent("RadicalRed.gba"), seed = root.appendingPathComponent("seed.sav")
        let originalROM = try Data(contentsOf: rom), originalSeed = try Data(contentsOf: seed)
        let profile = try BoundPlayerROMProfile(rom: originalROM)
        let output = root.appendingPathComponent("rom-multiplayer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav"); try originalSeed.write(to: battery)
        let core = try XCTUnwrap(EmulatorCore(game: NativeBattleGame(fileURL: rom, gameSaveURL: battery), options: [.metal:true]))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene), owner = UIViewController(), view = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 150, width: window.bounds.width, height: window.bounds.width * 2/3); core.add(view)
        let driver = NativeBattleDriver(core: core, profile: profile), probe = BoundROMMultiplayerProbe()
        probe.configure(core: core); probe.setVerified(true)
        core.audioManager.pausesOtherAudio = false; core.audioManager.mixesWithOtherAudio = true; core.audioManager.isEnabled = false
        core.updateHandler = { core in driver.receive(core); probe.receive(core) }
        defer {
            _ = core.pause(); probe.configure(core:nil); _ = core.stop()
            _ = BoundVBABattleBridge.setROMGameSaveAllowed(true,for:battery)
            window.isHidden = true; previous?.makeKeyAndVisible()
        }
        core.rate = 8; XCTAssertTrue(core.start()); core.deltaCore.emulatorBridge.audioRenderer = nil
        await fulfillment(of: [driver.booted], timeout: 90)
        _ = core.pause(); core.rate = 1; driver.play(moves:false)
        func position() throws -> BoundPlayerState.Point {
            guard let memory = BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }) else { throw NSError(domain:"snapshot",code:1) }
            return try XCTUnwrap(BoundPlayerStateDecoder.read(profile:profile,memory:memory,frame:1).player?.tile)
        }
        func waitForPause(_ paused: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            for _ in 0..<80 {
                if probe.read()?.paused == paused { return }
                try await Task.sleep(for:.milliseconds(25))
            }
            XCTFail("Expected native pause gate \(paused), observed \(String(describing: probe.read()?.paused))", file: file, line: line)
        }
        let initial = try position()
        var host = BoundROMHostState(); host.enabled = true; host.linked = true; host.run = UUID()
        host.message = "Waiting for friend"
        probe.publish(host); _ = core.resume(); try await waitForPause(true)
        let pausedFrame = try XCTUnwrap(probe.read()).frame
        for input in [64,128,32,16] {
            core.deltaCore.emulatorBridge.activateInput(input,value:1,playerIndex:0)
            try await Task.sleep(for:.milliseconds(220))
            core.deltaCore.emulatorBridge.deactivateInput(input,playerIndex:0)
        }
        _ = core.pause()
        XCTAssertEqual(try position(),initial,"A disconnected linked run must block native movement")
        XCTAssertFalse(BoundVBABattleBridge.verifyBattleEntryReady(), "Paused cartridge callbacks cannot admit a new friend battle")
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady(), "Host pause policy must not invalidate a restored overworld snapshot")
        XCTAssertGreaterThan(try XCTUnwrap(probe.read()).frame,pausedFrame,"The mailbox keeps processing while gameplay is paused")
        // A battery-only boot has no paired RAM provenance. Connectivity alone
        // must not authorize the cold linked guest to resume.
        host.connected = true; probe.publish(host); _ = core.resume(); try await waitForPause(true)
        let connectedFrame = try XCTUnwrap(probe.read()).frame
        for input in [64,128,32,16] {
            probe.publish(host)
            core.deltaCore.emulatorBridge.activateInput(input,value:1,playerIndex:0)
            try await Task.sleep(for:.milliseconds(220))
            core.deltaCore.emulatorBridge.deactivateInput(input,playerIndex:0)
        }
        _ = core.pause()
        XCTAssertTrue(try XCTUnwrap(probe.read()).paused,"CONNECTED must preserve the cold linked recovery gate")
        XCTAssertGreaterThan(try XCTUnwrap(probe.read()).frame,connectedFrame)
        XCTAssertEqual(try position(),initial,"Connectivity alone cannot resume a battery-only linked guest")
        host.enabled = false; probe.publish(host); _ = core.resume(); try await waitForPause(true); _ = core.pause()
        let disabledPosition = try position()
        _ = core.resume()
        for input in [64,128,32,16] {
            core.deltaCore.emulatorBridge.activateInput(input,value:1,playerIndex:0)
            try await Task.sleep(for:.milliseconds(220))
            core.deltaCore.emulatorBridge.deactivateInput(input,playerIndex:0)
        }
        _ = core.pause()
        XCTAssertEqual(try position(),disabledPosition,"Disabling services must preserve a linked run's pause fence")
        let suspended = output.appendingPathComponent("paused.state")
        core.saveSaveState(to:suspended)
        XCTAssertTrue(BoundVBABattleBridge.setROMGameSaveAllowed(false,for:battery))
        let protectedBytes = Data(repeating:0xA5,count:originalSeed.count)
        try protectedBytes.write(to:battery)
        core.deltaCore.emulatorBridge.saveGameSave(to:battery)
        XCTAssertEqual(try Data(contentsOf:battery),protectedBytes,"A direct bridge save cannot overwrite an unauthorized battery")
        let alias = output.appendingPathComponent("battery-alias.sav")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:battery)
        core.deltaCore.emulatorBridge.saveGameSave(to:alias)
        XCTAssertEqual(try Data(contentsOf:battery),protectedBytes,"Canonical destination aliases share the same fence")
        let export = output.appendingPathComponent("unrelated-export.sav")
        core.deltaCore.emulatorBridge.saveGameSave(to:export)
        XCTAssertEqual(try Data(contentsOf:export).count,originalSeed.count,"The exact-path fence leaves unrelated exports available")
        XCTAssertTrue(core.stop()); probe.configure(core:core); probe.setVerified(true)
        XCTAssertEqual(try Data(contentsOf:battery),protectedBytes,"Core.stop must cross the same battery fence")
        XCTAssertTrue(core.start()); _ = core.pause()
        try core.load(DeltaCore.SaveState(fileURL:suspended,gameType:.gba))
        _ = core.resume(); try await waitForPause(true)
        for input in [64,128,32,16] {
            core.deltaCore.emulatorBridge.activateInput(input,value:1,playerIndex:0)
            try await Task.sleep(for:.milliseconds(220))
            core.deltaCore.emulatorBridge.deactivateInput(input,playerIndex:0)
        }
        _ = core.pause()
        XCTAssertEqual(try position(),disabledPosition,"A cold core restoring a linked state must wait for a fresh host lease")
        XCTAssertEqual(try Data(contentsOf:battery),protectedBytes,"Restart and restored guest frames retain the blocked destination")
        XCTAssertTrue(BoundVBABattleBridge.setROMGameSaveAllowed(true,for:battery))
        core.deltaCore.emulatorBridge.saveGameSave(to:battery)
        XCTAssertEqual(try Data(contentsOf:battery),try Data(contentsOf:export),"Authorized battery writes reach the original core implementation")
        host.enabled = true; host.linked = false; host.connected = false; host.ended = true; host.status = .complete
        probe.publish(host); _ = core.resume(); try await waitForPause(false)
        var moved = false
        for input in [64,128,32,16] {
            probe.publish(host)
            core.deltaCore.emulatorBridge.activateInput(input,value:1,playerIndex:0)
            try await Task.sleep(for:.milliseconds(220))
            core.deltaCore.emulatorBridge.deactivateInput(input,playerIndex:0)
            _ = core.pause(); moved = try position() != disabledPosition
            if moved { break }; _ = core.resume()
        }
        XCTAssertTrue(moved,"Ending the matching run releases the cold linked pause gate")
        XCTAssertEqual(try Data(contentsOf:rom),originalROM); XCTAssertEqual(try Data(contentsOf:seed),originalSeed)
    }

    func testActualSoulLinkNativeHPAndStateRecovery() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["BOUND_SOUL_RUNTIME"] == "1" else {
            throw XCTSkip("Requires the explicit owned-simulator Soul Link fixture")
        }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FullAppGameplayQA")
        let rom = root.appendingPathComponent("RadicalRed.gba"), seed = root.appendingPathComponent("seed.sav")
        let originalROM = try Data(contentsOf: rom), originalSeed = try Data(contentsOf: seed)
        let profile = try BoundPlayerROMProfile(rom: originalROM)
        let output = root.appendingPathComponent("soul-link-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav"); try originalSeed.write(to: battery)
        let core = try XCTUnwrap(EmulatorCore(game: NativeBattleGame(fileURL: rom, gameSaveURL: battery), options: [.metal:true]))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene), owner = UIViewController(), view = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 150, width: window.bounds.width, height: window.bounds.width * 2/3); core.add(view)
        let driver = NativeBattleDriver(core: core, profile: profile), probe = BoundSoulProbe()
        let journal = output.appendingPathComponent("run.json")
        probe.configure(core: core, url: journal); probe.setVerified(true); probe.setPreviewEnabled(true)
        core.audioManager.pausesOtherAudio = false; core.audioManager.mixesWithOtherAudio = true; core.audioManager.isEnabled = false
        core.updateHandler = { core in
            if core.audioManager.isEnabled { core.audioManager.isEnabled = false }
            driver.receive(core); probe.receive(core)
        }
        defer {
            _ = core.pause(); BoundVBABattleBridge.closeSoulLink(); _ = core.stop()
            window.isHidden = true; previous?.makeKeyAndVisible()
        }
        core.rate = 8; XCTAssertTrue(core.start()); core.deltaCore.emulatorBridge.audioRenderer = nil; await fulfillment(of: [driver.booted], timeout: 90)
        for _ in 0..<20 {
            if probe.read().ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = core.pause(); core.rate = 1
        XCTAssertTrue(probe.read().ready, "Wait for the Soul Link observation cadence after the first native overworld frame")
        XCTAssertEqual(probe.read().mons.count, 1, "Only the disposable starter is owned")
        let before = output.appendingPathComponent("before.state"); core.saveSaveState(to: before)
        try probe.start(run: UUID(), binding: String(repeating: "a", count: 64))
        _ = core.resume(); try await Task.sleep(for: .milliseconds(150)); _ = core.pause()
        let starter = try XCTUnwrap(probe.read().ledger?.records.first)
        let starterTeam = try XCTUnwrap(probe.read().team)
        XCTAssertEqual(starterTeam.party.count,1)
        XCTAssertEqual(starterTeam.party.first?.slot,starter.slot)
        XCTAssertGreaterThan(starterTeam.party.first?.level ?? 0,0)
        XCTAssertGreaterThan(starterTeam.party.first?.maxHP ?? 0,0)
        let friendlyBefore = output.appendingPathComponent("friendly-before.state")
        core.saveSaveState(to: friendlyBefore)
        let friendlyLedger = try XCTUnwrap(probe.read().ledger)
        let friendlyJournal = try Data(contentsOf: journal)
        let friendlyTimeline = probe.timeline.read().events
        let friendlyHP = BoundVBABattleBridge.playerHP().map(\.intValue)
        probe.setFriendlyBattleActive(true, for: core)
        XCTAssertTrue(BoundVBABattleBridge.qaStartSoulCheck()); _ = core.resume()
        try await Task.sleep(for: .milliseconds(250)); _ = core.pause()
        let friendlyFaint = BoundVBABattleBridge.qaSoulCheckResult().map(\.intValue)
        XCTAssertEqual(friendlyFaint.count, 3)
        XCTAssertGreaterThan(friendlyFaint[1], 0, "The friendly battle fixture really faints and heals a Pokemon in native guest code")
        XCTAssertEqual(friendlyFaint[1], friendlyFaint[2])
        XCTAssertEqual(probe.read().ledger, friendlyLedger, "Temporary battle HP cannot change catches, deaths or memorials")
        XCTAssertEqual(probe.read().ledger?.lossBits, friendlyLedger.lossBits, "No friendly battle loss can be sent to the partner")
        XCTAssertEqual(probe.read().team, starterTeam, "Temporary battle team state must not replace the overworld team")
        XCTAssertEqual(probe.timeline.read().events, friendlyTimeline)
        XCTAssertEqual(try Data(contentsOf: journal), friendlyJournal, "Friendly battles must not rewrite the durable run journal")
        let retainedFaints = try XCTUnwrap(BoundVBABattleBridge.soulLinkSnapshot()["faints"] as? Data)
        XCTAssertEqual(retainedFaints, starter.identity.bytes, "Quarantine must not acknowledge the native faint buffer before recovery")
        BoundVBABattleBridge.qaFinishSoulCheck()
        try core.load(DeltaCore.SaveState(fileURL: friendlyBefore, gameType: .gba))
        probe.setFriendlyBattleActive(false, for: core)
        _ = core.resume(); try await Task.sleep(for: .milliseconds(200)); _ = core.pause()
        XCTAssertEqual(BoundVBABattleBridge.playerHP().map(\.intValue), friendlyHP)
        XCTAssertEqual(probe.read().ledger, friendlyLedger, "Restored temporary faints cannot become delayed permanent deaths")
        XCTAssertEqual(probe.read().ledger?.memorials, friendlyLedger.memorials)
        XCTAssertEqual(try Data(contentsOf: journal), friendlyJournal)
        XCTAssertTrue((BoundVBABattleBridge.soulLinkSnapshot()["faints"] as? Data)?.isEmpty == true)
        // The normal native faint below must still become permanent after the
        // friendly battle fence has been released.
        probe.setNativeObservationAllowed(false)
        XCTAssertTrue(BoundVBABattleBridge.qaStartSoulCheck()); _ = core.resume()
        try await Task.sleep(for:.milliseconds(150)); _ = core.pause()
        XCTAssertFalse(probe.read().ledger?.dead.contains(starter.slot) == true,
                       "Unauthorized working RAM must not alter the durable Soul Link journal")
        probe.setNativeObservationAllowed(true); _ = core.resume()
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(25))
            if probe.read().ledger?.dead.contains(starter.slot) == true { break }
        }
        _ = core.pause()
        let first = BoundVBABattleBridge.qaSoulCheckResult().map(\.intValue)
        XCTAssertEqual(first.count, 3)
        XCTAssertGreaterThan(first[0], 0, "Original GetMonData species forwarding still works")
        XCTAssertGreaterThan(first[1], 0, "Native zero-HP then heal occurred in one guest frame")
        XCTAssertEqual(first[1], first[2])
        XCTAssertTrue(probe.read().ledger?.dead.contains(starter.slot) == true, "Native faint latch survives healing")
        XCTAssertEqual(BoundVBABattleBridge.playerHP().first?.intValue, 0)
        XCTAssertEqual(probe.read().ledger?.memorials?.count, 1)
        XCTAssertEqual(probe.read().ledger?.memorials?.first?.slot, starter.slot)
        XCTAssertEqual(probe.read().ledger?.memorials?.first?.announced, false)
        BoundVBABattleBridge.qaFinishSoulCheck()
        _ = core.resume(); try await Task.sleep(for: .milliseconds(100)); _ = core.pause()
        XCTAssertTrue(BoundVBABattleBridge.qaStartSoulCheck()); _ = core.resume()
        try await Task.sleep(for: .milliseconds(250)); _ = core.pause()
        let second = BoundVBABattleBridge.qaSoulCheckResult().map(\.intValue)
        XCTAssertEqual(second.count, 3); XCTAssertEqual(second[1], 0); XCTAssertEqual(second[2], 0, "Native healing cannot revive a denied Pokemon")
        BoundVBABattleBridge.qaFinishSoulCheck()
        try core.load(DeltaCore.SaveState(fileURL: before, gameType: .gba))
        XCTAssertGreaterThan(BoundVBABattleBridge.playerHP().first?.intValue ?? 0, 0, "The old state really contained a healthy party")
        let reopened = BoundSoulProbe(); reopened.configure(core: core, url: journal)
        try reopened.prepareRestoredState(core)
        XCTAssertEqual(core.state, .paused)
        XCTAssertEqual(BoundVBABattleBridge.playerHP().first?.intValue, 0,
            "Durable losses must be enforced before the first restored frame and before asynchronous verification completes")
        core.updateHandler = { core in
            if core.audioManager.isEnabled { core.audioManager.isEnabled = false }
            driver.receive(core); reopened.receive(core)
        }
        _ = core.resume(); try await Task.sleep(for: .milliseconds(200)); _ = core.pause()
        XCTAssertTrue(reopened.read().ledger?.dead.contains(starter.slot) == true)
        XCTAssertEqual(BoundVBABattleBridge.playerHP().first?.intValue, 0, "Old-state load and journal reload cannot revive the link")
        XCTAssertNil(reopened.read().error)
        XCTAssertEqual(reopened.read().ledger?.memorials?.count, 1, "The real native loss queues one moment despite healing and raw-state rollback")
        try reopened.acknowledgeDeath(run: try XCTUnwrap(reopened.read().ledger?.run), slot: starter.slot)
        for mode in 1...3 {
            let beforeCount = reopened.read().ledger?.records.count ?? 0
            XCTAssertTrue(BoundVBABattleBridge.qaStartSoulCatch(UInt(mode))); _ = core.resume()
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(25))
                if (reopened.read().ledger?.records.count ?? 0) > beforeCount { break }
            }
            _ = core.pause()
            let record = try XCTUnwrap(reopened.read().ledger?.records.last)
            let result = BoundVBABattleBridge.qaSoulCheckResult().map(\.intValue)
            XCTAssertEqual(result.count, 3)
            if mode == 1 {
                XCTAssertEqual(record.slot, starter.slot); XCTAssertFalse(record.eligible)
                XCTAssertEqual(BoundVBABattleBridge.playerHP().last?.intValue, 0, "Second catch in the same area is unusable")
            } else if mode == 2 {
                XCTAssertEqual(record.slot, "egg:1"); XCTAssertTrue(record.eligible)
                XCTAssertEqual(result[2], 0, "A zero-HP write to an unhatched egg does not emit a native faint")
                XCTAssertFalse(reopened.read().ledger?.dead.contains("egg:1") == true)
            } else {
                XCTAssertEqual(result[0], 1, "Actual native GiveMonToPlayer sent the catch to a PC box")
                XCTAssertTrue(record.slot.hasPrefix("area:")); XCTAssertNotEqual(record.slot, starter.slot)
                XCTAssertTrue(record.eligible)
                let boxed = try XCTUnwrap(reopened.read().mons.first { $0.identity == record.identity })
                XCTAssertNil(boxed.hp, "Read the real native 58-byte compressed PC catch")
                XCTAssertTrue(BoundSoulLedger.losses(try XCTUnwrap(reopened.read().team).boxed).contains(record.slot), "The dashboard identifies the actual native PC catch")
            }
            BoundVBABattleBridge.qaFinishSoulCheck()
        }
        BoundVBABattleBridge.closeSoulLink()
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady(), "Original ROM hash and native link ABI remain intact after unhooking")
        BoundVBABattleBridge.close()
        XCTAssertEqual(try Data(contentsOf: rom), originalROM); XCTAssertEqual(try Data(contentsOf: seed), originalSeed)
    }

    func testActualNativeTrade() async throws {
        continueAfterFailure=false
        let env=ProcessInfo.processInfo.environment
        guard let peer=env["BOUND_NATIVE_BATTLE_PEER"],["A","B"].contains(peer),
              let port=env["BOUND_NATIVE_BATTLE_PORT"].flatMap(Int.init),
              let relayPort=env["BOUND_NATIVE_BATTLE_RELAY_PORT"].flatMap(UInt16.init),
              let id=env["BOUND_NATIVE_BATTLE_RELAY_ID"].flatMap(UUID.init(uuidString:)) else {
            throw XCTSkip("Requires two owned simulators and the native --trade coordinator")
        }
        let fixtures=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("FullAppGameplayQA")
        let rom=fixtures.appendingPathComponent("RadicalRed.gba"),seed=fixtures.appendingPathComponent("seed.sav")
        let originalROM=try Data(contentsOf:rom),originalSeed=try Data(contentsOf:seed)
        let cancelMode=env["BOUND_NATIVE_TRADE_CANCEL"]=="1"
        let disconnectSeconds=Double(env["BOUND_NATIVE_DISCONNECT_SECONDS"] ?? "0") ?? 0
        let disconnectStage=env["BOUND_NATIVE_DISCONNECT_STAGE"] ?? "menu"
        let silentDisconnect=env["BOUND_NATIVE_SILENT_DISCONNECT"]=="1"
        let profile=try BoundPlayerROMProfile(rom:originalROM)
        let output=fixtures.appendingPathComponent("native-trade-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        // Admitted New Game owns a fresh battery. A previous trainer's seed
        // would introduce an unrelated native overwrite-confirmation prompt.
        let battery=output.appendingPathComponent("work.sav"); try Data(repeating:0xFF,count:0x20000).write(to:battery)
        let core=try XCTUnwrap(EmulatorCore(game:NativeBattleGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
        let scene=try await nativeWindowScene()
        let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene),owner=UIViewController(),view=GameView()
        window.rootViewController=owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame=CGRect(x:0,y:150,width:window.bounds.width,height:window.bounds.width*2/3); core.add(view)
        let driver=NativeTradeDriver(core:core,profile:profile,offersEnabled:!cancelMode,admittedSetup:true),interactions=BoundFriendInteractionSession()
        var native=BoundNativeBattleSession()
        native.continuationContext=BoundNativeContinuationContext(owner:UUID(),roomID:id.uuidString,runID:id)
        native.continuationHeadsProvider={ _ in BoundContinuationHeads(checkpoints:[],permitsNoCheckpoint:true) }
        try primeNativeInteraction(interactions,activity:.trade)
        driver.progress(offers:!cancelMode && !(disconnectSeconds>0 && disconnectStage=="menu"),exit:disconnectSeconds==0)
        let probe=native.probe
        core.updateHandler={ core in driver.receive(core); probe.receive(core) }
        var channel:NativeBattleRelayChannel?
        var networkAvailable=true,disconnectResumed=false,bridgeRestored=false
        defer {
            native.cancel(resume:false); channel?.close(); _=core.pause(); BoundVBABattleBridge.close(); _=core.stop()
            window.isHidden=true; previous?.makeKeyAndVisible()
        }
        core.rate=8; XCTAssertTrue(core.start()); await fulfillment(of:[driver.booted],timeout:90)
        _=core.pause(); core.rate=1
        try await prepareNativeParty(core)
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady())
        let offered=peer=="A" ? 0xBB:0xBC
        let expected=cancelMode ? offered : peer=="A" ? 0xBC:0xBB
        XCTAssertTrue(BoundVBABattleBridge.qaPrepareTradeFixture(UInt(offered)))
        let beforeTrade=BoundVBABattleBridge.qaTradeParty()
        native.bind(core:core,gameID:output.lastPathComponent,interactions:interactions); native.canResume={ true }
        func configureTransport(_ session:BoundNativeBattleSession) {
            session.makeChannel={ receiver,failed in
                guard networkAvailable else { return nil }
                let value=NativeBattleRelayChannel(port:relayPort,peer:peer,receive:{ data in
                    if data.starts(with:BoundBattleControlPacket.prefix) { Task { @MainActor in session.receive(data) } }
                    else { receiver(data) }
                },failed:failed)
                channel=value; return value
            }
            session.sendControl={ channel?.send($0)==true }
        }
        configureTransport(native)
        driver.begin(); _=core.resume(); native.begin(activity:.trade,id:id,initiator:peer=="A")
        for tick in 0..<9000 {
            if tick%200==0 { NSLog("Native trade %@ callback=%08x script=%d trades=%d %@",peer,native.observation?.callback ?? 0,native.observation?.scriptResult ?? -1,native.observation?.tradeCount ?? 0,native.probe.diagnostics) }
            if !bridgeRestored,native.observation?.callback==0x0804D639 {
                try verifyNativeBridgeRestore(core)
                native=try restoreNativeOwner(native,core:core,gameID:output.lastPathComponent,interactions:interactions,
                    receive:{ driver.receive($0) },configure:configureTransport)
                bridgeRestored=true
            }
            let reachedDisconnect = disconnectStage=="exchange" ? native.observation?.callback==0x08053D85
                : disconnectStage=="saved" ? (native.observation?.tradeCount ?? 0)>0 : native.observation?.callback==0x0804D639
            if disconnectSeconds>0,!disconnectResumed,reachedDisconnect {
                try await verifyNativeReconnect(native:native,id:id,core:core,interactions:interactions,port:port,peer:peer,seconds:disconnectSeconds,
                    silent:silentDisconnect,disconnect:{ networkAvailable=false; if silentDisconnect { channel?.dropTraffic() } else { channel?.close() } },reconnect:{ networkAvailable=true })
                disconnectResumed=true; driver.progress(offers:!cancelMode,exit:true)
            }
            if cancelMode,native.observation?.tradeOpened==true {
                _=try await request(port:port,peer:peer,body:["stage":"menu"])
                for _ in 0..<200 {
                    let status=try await request(port:port)
                    if let peers=status["peers"] as? [String:[String:Any]],peers.count==2,peers.values.allSatisfy({ ["menu","done"].contains($0["stage"] as? String ?? "") }) { break }
                    try await Task.sleep(for:.milliseconds(50))
                }
                if peer=="A" { native.cancel() }
                for _ in 0..<200 where native.isActive { try await Task.sleep(for:.milliseconds(50)) }
                XCTAssertFalse(native.isActive); break
            }
            if native.completedTrades>0 || !native.isActive { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertEqual(native.completedTrades,cancelMode ? 0:1,"Native trade failed: \(native.lastFailure) \(native.lastCableDiagnostic) callback=\(String(native.observation?.callback ?? 0,radix:16)) scriptResult=\(native.observation?.scriptResult ?? -1) returned=\(native.observation?.returned == true) cancellation=\(native.lastCancellation)")
        _=core.pause()
        if !cancelMode {
            let received=BoundVBABattleBridge.qaTradeParty()
            XCTAssertEqual(received[8],UInt8(expected),"Native swap must deliver the peer's offered Pokémon")
            XCTAssertEqual(received[4],UInt8(expected),"The original trainer identity must travel with the offered Pokémon")
            XCTAssertEqual(received.subdata(in:100..<200),beforeTrade.subdata(in:100..<200),"The unoffered party member stays unchanged")
            XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady(),"Return to the real overworld with all hooks removed")
        }
        XCTAssertFalse(native.blocksAutoSave)
        // Current Bound reopens server checkpoints; the cartridge deliberately
        // has no legacy battery Continue. Recreate the actual production pair
        // of native state and battery on a fresh core after the native save.
        let savedState=BoundVBABattleBridge.captureServerState()
        let savedBattery=BoundVBABattleBridge.captureServerBattery()
        XCTAssertFalse(savedState.isEmpty); XCTAssertFalse(savedBattery.isEmpty)
        XCTAssertTrue(core.stop()); core.updateHandler=nil
        let reopened=try XCTUnwrap(EmulatorCore(game:NativeBattleGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
        let reboot=NativeTradeDriver(core:reopened,profile:profile)
        reopened.updateHandler={ reboot.receive($0) }; reopened.rate=8; reopened.add(view)
        XCTAssertTrue(reopened.start()); _=reopened.pause()
        XCTAssertTrue(BoundVBABattleBridge.restoreServerBattery(savedBattery))
        XCTAssertTrue(BoundVBABattleBridge.restoreServerState(savedState))
        _=reopened.resume(); await fulfillment(of:[reboot.booted],timeout:90); _=reopened.pause()
        let persisted=BoundVBABattleBridge.qaTradeParty(); XCTAssertEqual(persisted[8],UInt8(expected))
        XCTAssertEqual(persisted[4],UInt8(expected))
        XCTAssertEqual(persisted.subdata(in:100..<200),beforeTrade.subdata(in:100..<200))
        XCTAssertTrue(reopened.stop())
        XCTAssertEqual(try Data(contentsOf:rom),originalROM); XCTAssertEqual(try Data(contentsOf:seed),originalSeed)
        XCTAssertEqual(disconnectResumed,disconnectSeconds>0)
        let report:[String:Any]=["stage":"done","trade":native.completedTrades==1,"canceled":cancelMode && !native.isActive,"persisted":persisted[8]==UInt8(expected),"restorationMode":"server-state-and-battery","ownerRestored":bridgeRestored,"cable":native.lastCableDiagnostic,
            "disconnectResumed":disconnectResumed,"disconnectSeconds":disconnectSeconds,"disconnectPhase":4,"silentDisconnect":silentDisconnect]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        _=try await request(port:port,peer:peer,body:report)
    }
    func testActualNativeLinkBattle() async throws { try await runNativeBattle(entryOnly:false) }
    func testNativeSessionForwardedEntry() async throws { try await runNativeBattle(entryOnly:true) }
    private func runNativeBattle(entryOnly:Bool) async throws {
        continueAfterFailure=false
        let env=ProcessInfo.processInfo.environment
        let runBattle=env["BOUND_NATIVE_BATTLE_RUN"]=="1"
        let partyMode=Int(env["BOUND_NATIVE_BATTLE_PARTY"] ?? "0") ?? 0
        let disconnectSeconds=Double(env["BOUND_NATIVE_DISCONNECT_SECONDS"] ?? "0") ?? 0
        let silentDisconnect=env["BOUND_NATIVE_SILENT_DISCONNECT"]=="1"
        let battleRate=Double(env["BOUND_NATIVE_BATTLE_RATE"] ?? "1") ?? 1
        guard let peer=env["BOUND_NATIVE_BATTLE_PEER"],["A","B"].contains(peer),
              let raw=env["BOUND_NATIVE_BATTLE_PORT"],let port=Int(raw),(1024...65535).contains(port),
              let relayPort=env["BOUND_NATIVE_BATTLE_RELAY_PORT"].flatMap(UInt16.init),
              let uuid=env["BOUND_NATIVE_BATTLE_RELAY_ID"].flatMap(UUID.init(uuidString:)) else {
            throw XCTSkip("Requires the explicit two-owned-simulator native command coordinator with --relay")
        }
        let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("FullAppGameplayQA")
        let romURL=root.appendingPathComponent("RadicalRed.gba"),seed=root.appendingPathComponent("seed.sav")
        let rom=try Data(contentsOf:romURL),profile=try BoundPlayerROMProfile(rom:rom),seedBytes=try Data(contentsOf:seed)
        let output=root.appendingPathComponent("native-battle-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let battery=output.appendingPathComponent("work.sav"); try Data(repeating:0xFF,count:0x20000).write(to:battery)
        let core=try XCTUnwrap(EmulatorCore(game:NativeBattleGame(fileURL:romURL,gameSaveURL:battery),options:[.metal:true]))
        let scene=try await nativeWindowScene()
        let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene),owner=UIViewController(),gameView=GameView()
        window.rootViewController=owner; window.makeKeyAndVisible()
        gameView.frame=CGRect(x:0,y:150,width:window.bounds.width,height:window.bounds.width*2/3)
        owner.view.addSubview(gameView); core.add(gameView)
        let driver=NativeBattleDriver(core:core,profile:profile,admittedSetup:true)
        var native=BoundNativeBattleSession()
        native.continuationContext=BoundNativeContinuationContext(owner:UUID(),roomID:uuid.uuidString,runID:uuid)
        native.continuationHeadsProvider={ _ in BoundContinuationHeads(checkpoints:[],permitsNoCheckpoint:true) }
        let interactions=BoundFriendInteractionSession(),probe=native.probe
        try primeNativeInteraction(interactions,activity:.battle)
        let soulProbe=BoundSoulProbe(),soulJournal=output.appendingPathComponent("run.json")
        soulProbe.configure(core:core,url:soulJournal); soulProbe.setVerified(true); soulProbe.setPreviewEnabled(true)
        native.soulProbe=partyMode==1 ? nil:soulProbe
        core.updateHandler={ core in driver.receive(core); soulProbe.receive(core); probe.receive(core) }
        var channel:NativeBattleRelayChannel?
        var networkAvailable=true,disconnectResumed=false
        defer {
            native.cancel(resume:false); channel?.close(); native.makeChannel=nil; native.sendControl=nil
            _=core.pause(); BoundVBABattleBridge.close(); _=core.stop()
            window.isHidden=true; previous?.makeKeyAndVisible()
        }
        core.rate=8; XCTAssertTrue(core.start())
        await fulfillment(of:[driver.booted],timeout:90)
        for _ in 0..<20 {
            if soulProbe.read().ready { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        _=core.pause(); core.rate=1
        try await prepareNativeParty(core)
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady())
        // Native givemon can finish between the idle Soul probe's 30-frame
        // samples. Start the ledger only after it observes the actual party.
        for _ in 0..<60 {
            let snapshot=soulProbe.read()
            if snapshot.ready,snapshot.mons.count==1 { break }
            _=core.resume(); try await Task.sleep(for:.milliseconds(50)); _=core.pause()
        }
        XCTAssertTrue(soulProbe.read().ready)
        XCTAssertEqual(soulProbe.read().mons.count,1)
        try soulProbe.start(run:UUID(),binding:String(repeating:"a",count:64))
        _=core.resume(); try await Task.sleep(for:.milliseconds(150)); _=core.pause()
        if partyMode>0 {
            // Fixture writes are not gameplay faints. Ordinary 0HP has no Soul
            // death; the denied case deliberately lets the real probe record it.
            if partyMode==1 { soulProbe.setNativeObservationAllowed(false) }
            XCTAssertTrue(BoundVBABattleBridge.qaConfigureBattleParty(UInt(partyMode)))
            if partyMode==2 {
                for _ in 0..<60 {
                    _=core.resume();try await Task.sleep(for:.milliseconds(50));_=core.pause()
                    if soulProbe.read().mons.count==2,soulProbe.read().ledger?.dead.isEmpty==false { break }
                }
                XCTAssertEqual(soulProbe.read().mons.count,2)
                XCTAssertFalse(try XCTUnwrap(soulProbe.read().ledger).dead.isEmpty)
            }
        }
        let soulBefore=try XCTUnwrap(soulProbe.read().ledger)
        let journalBefore=try Data(contentsOf:soulJournal)
        let hpBefore=BoundVBABattleBridge.playerHP().map(\.intValue)
        let partyBefore=BoundVBABattleBridge.qaTradeParty()
        let timelineBefore=soulProbe.timeline.read().events
        let before=output.appendingPathComponent("before.state"); core.saveSaveState(to:before)
        native.bind(core:core,gameID:output.lastPathComponent,interactions:interactions)
        native.canResume={ true }
        func configureTransport(_ session:BoundNativeBattleSession) {
            session.makeChannel={ receiver,failed in
                guard networkAvailable else { return nil }
                let value=NativeBattleRelayChannel(port:relayPort,peer:peer,receive:{ data in
                    if data.starts(with:BoundBattleControlPacket.prefix) { Task { @MainActor in session.receive(data) } }
                    else { receiver(data) }
                },failed:failed)
                channel=value; return value
            }
            session.sendControl={ channel?.send($0)==true }
        }
        configureTransport(native)
        core.rate=battleRate
        driver.play(moves:!entryOnly && !(runBattle && peer=="B"),run:runBattle && peer=="A"); _=core.resume()
        native.begin(activity:.battle,id:uuid,initiator:peer=="A")
        XCTAssertEqual(core.rate,battleRate,"Friendly entry preserves local fast-forward")
        if partyMode != 1 { soulProbe.setNativeObservationAllowed(true) }
        var entered=false
        for tick in 0..<1200 {
            if tick%100==0 { NSLog("Native entry %@: frame=%llu callback=%08x result=%d %@",peer,native.observation?.frame ?? 0,native.observation?.callback ?? 0,native.observation?.scriptResult ?? -1,native.probe.diagnostics) }
            if native.observation?.battle==true { entered=true; break }
            if !native.isActive { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertTrue(entered,"Native entry failed: \(native.lastFailure), \(native.lastCableDiagnostic), result \(native.observation?.scriptResult ?? -1)")
        XCTAssertEqual(soulProbe.read().ledger,soulBefore,"Native friend battle entry cannot mutate the Soul Link ledger")
        _=try await request(port:port,peer:peer,body:["stage":"entered"])
        for _ in 0..<200 {
            let status=try await request(port:port)
            if let peers=status["peers"] as? [String:[String:Any]],peers.count==2,peers.values.allSatisfy({ ["entered","disconnect","done"].contains($0["stage"] as? String ?? "") }) { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        try verifyNativeBridgeRestore(core)
        native=try restoreNativeOwner(native,core:core,gameID:output.lastPathComponent,interactions:interactions,soulProbe:soulProbe,
            receive:{ driver.receive($0);soulProbe.receive($0) },configure:configureTransport)
        if disconnectSeconds>0 {
            try await verifyNativeReconnect(native:native,id:uuid,core:core,interactions:interactions,port:port,peer:peer,seconds:disconnectSeconds,
                silent:silentDisconnect,disconnect:{ networkAvailable=false; if silentDisconnect { channel?.dropTraffic() } else { channel?.close() } },reconnect:{ networkAvailable=true })
            disconnectResumed=true
        }
        XCTAssertEqual(core.rate,battleRate,"Continuation/reconnect preserves local fast-forward")
        if entryOnly { native.cancel() }
        else {
            var done=false,terminalCaptured=false
            var terminalObservedAt:TimeInterval?
            for tick in 0..<8000 {
                let terminal=Dictionary(uniqueKeysWithValues:Mirror(reflecting:native).children.compactMap { child -> (String,Bool)? in
                    guard let name=child.label,["localFinished","peerFinished","peerLinkClosed","played","isTransportSuspended","pausedForTransport"].contains(name),let value=child.value as? Bool else { return nil }
                    return (name,value)
                })
                if tick%200==0 {
                    let value=native.observation
                    NSLog("Native battle %@: frame=%llu callback=%08x HP=%@ enemyHP=%@ outcome=%d flags=%08x returned=%d connected=%d battle=%d error=%d %@ %@",
                        peer,value?.frame ?? 0,value?.callback ?? 0,String(describing:value?.playerHP),String(describing:value?.enemyHP),value?.outcome ?? -1,value?.flags ?? 0,
                        value?.returned == true,value?.connected == true,value?.battle == true,value?.error == true,native.probe.diagnostics,String(describing:terminal))
                }
                if terminalObservedAt==nil,(terminal["localFinished"]==true || terminal["peerFinished"]==true) {
                    terminalObservedAt=ProcessInfo.processInfo.systemUptime
                }
                if !terminalCaptured,let terminalObservedAt,ProcessInfo.processInfo.systemUptime-terminalObservedAt>=10 {
                    terminalCaptured=true
                    let running=core.state == .running; _=core.pause()
                    try BoundVBABattleBridge.captureServerState().write(to:output.appendingPathComponent("native-terminal.vba-state"))
                    func word(_ address:Int,size:Int=4)->Int {
                        guard let data=core.deltaCore.emulatorBridge.readMemory?(at:address,size:size) else { return -1 }
                        return data.enumerated().reduce(0) { $0 | Int($1.element)<<($1.offset*8) }
                    }
                    let registers=["receivedRemoteLinkPlayers":word(0x3F64,size:1),"callback1":word(0x30F0),
                        "battleScript":word(0x23D74+0x8000),"battleMain":word(0x4F84),"battleControllerExecFlags":word(0x23BC8+0x8000),"disconnectRequested":word(0x402E,size:1)]
                    NSLog("Native terminal %@: %@",peer,String(describing:registers))
                    try JSONSerialization.data(withJSONObject:registers,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("native-terminal.json"))
                    if running,!native.isTransportSuspended { _=core.resume() }
                }
                if native.completedBattles==1 || runBattle && !native.isActive && native.restoredBattles==1 { done=true; break }
                if !native.isActive { break }
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTAssertTrue(done,"Native battle failed: \(native.lastFailure), \(native.lastCableDiagnostic)")
            XCTAssertTrue(native.lastFailure.isEmpty)
            if env["BOUND_NATIVE_LOCAL_MENUS"]=="1" {
                XCTAssertEqual(driver.menuFrames.count,3)
                XCTAssertTrue(driver.moveCursorResponded,"Growl cursor navigation must respond locally")
                XCTAssertTrue(driver.menuFrames.allSatisfy { $0<=12 },"Fight/back/Fight must render within 12 local frames: \(driver.menuFrames)")
            }
            if runBattle,peer=="A" { XCTAssertTrue(native.observation?.runRequested==true,"Only actual native Run input may trigger unilateral exit") }
            if !runBattle { XCTAssertTrue(driver.damaged,"A native move must change party HP") }
            XCTAssertEqual(driver.menuHP?.count,1,"Only the eligible mon enters this fixture battle")
            XCTAssertTrue(driver.menuHP?.allSatisfy { $0>0 } == true,"Native action selection cannot start with zero HP")
            XCTAssertGreaterThan(driver.menuEnemyHP?.first ?? 0,0,"The peer's exchanged lead must also be healed")
        }
        try await Task.sleep(for:.milliseconds(200))
        _=core.pause()
        XCTAssertEqual(native.restoredBattles,1)
        XCTAssertEqual(BoundVBABattleBridge.playerHP().map(\.intValue),hpBefore,"Friendly completion and cancellation restore the prebattle party")
        XCTAssertEqual(BoundVBABattleBridge.qaTradeParty(),partyBefore,"All original party bytes survive temporary healing and eligibility filtering")
        XCTAssertEqual(soulProbe.read().ledger,soulBefore,"Friendly battle faints never become permanent Soul Link deaths")
        XCTAssertEqual(soulProbe.read().ledger?.lossBits,soulBefore.lossBits)
        XCTAssertEqual(soulProbe.read().ledger?.memorials,soulBefore.memorials)
        XCTAssertEqual(soulProbe.timeline.read().events,timelineBefore)
        XCTAssertEqual(try Data(contentsOf:soulJournal),journalBefore)
        XCTAssertNil(soulProbe.read().error)
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady())
        XCTAssertEqual(try Data(contentsOf:romURL),rom)
        XCTAssertEqual(try Data(contentsOf:seed),seedBytes)
        let report:[String:Any]=["stage":"done","entryOnly":entryOnly,"battle":entered,
            "damaged":driver.damaged,"restored":native.restoredBattles==1,"cable":native.lastCableDiagnostic,
            "outcome":native.observation?.outcome ?? 0,"soulLedgerUnchanged":soulProbe.read().ledger==soulBefore,
            "battleRate":battleRate,"menuFrames":driver.menuFrames,"ownerRestored":true,"ran":runBattle,"nativeRunIntent":native.observation?.runRequested==true,"partyMode":partyMode,"checkedSoulHistory":partyMode != 1,"startingHP":driver.menuHP ?? [],"startingEnemyHP":driver.menuEnemyHP ?? [],"partyUnchanged":BoundVBABattleBridge.qaTradeParty()==partyBefore,
            "disconnectResumed":disconnectResumed,"disconnectSeconds":disconnectSeconds,"disconnectPhase":4,"silentDisconnect":silentDisconnect]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        _=try await request(port:port,peer:peer,body:report)
    }
    private func nativeWindowScene() async throws -> UIWindowScene {
        for _ in 0..<100 {
            if let scene=UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { return scene }
            try await Task.sleep(for:.milliseconds(50))
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,"QA application did not connect its window scene")
    }
    private func restoreNativeOwner(_ previous:BoundNativeBattleSession,core:EmulatorCore,gameID:String,
        interactions:BoundFriendInteractionSession,soulProbe:BoundSoulProbe?=nil,
        receive:@escaping @Sendable (EmulatorCore)->Void,configure:(BoundNativeBattleSession)->Void) throws -> BoundNativeBattleSession {
        previous.canResume={ false }
        XCTAssertTrue(previous.checkpointForContinuation(),previous.lastFailure)
        XCTAssertEqual(core.state,.paused)
        let context=try XCTUnwrap(previous.continuationContext)
        let party=BoundVBABattleBridge.qaTradeParty()
        let nativeState=BoundVBABattleBridge.captureNativeSession()
        let cableState=previous.probe.recoveryData()
        let observation=previous.observation
        previous.bind(core:nil,gameID:gameID,interactions:interactions)
        previous.makeChannel=nil;previous.sendControl=nil
        core.updateHandler=nil
        BoundVBABattleBridge.closeSoulLink()
        XCTAssertTrue(core.stop());XCTAssertTrue(core.start());_=core.pause()
        let reopened=BoundNativeBattleSession()
        reopened.continuationContext=context;reopened.soulProbe=previous.soulProbe;reopened.canResume={ false }
        reopened.continuationHeadsProvider=previous.continuationHeadsProvider
        configure(reopened)
        reopened.bind(core:core,gameID:gameID,interactions:interactions)
        XCTAssertTrue(try reopened.restoreContinuationIfAvailable())
        try soulProbe?.reloadContinuationMemory(for:core)
        XCTAssertEqual(core.state,.paused)
        XCTAssertEqual(BoundVBABattleBridge.qaTradeParty(),party,"Relaunch must preserve the in-flight party without healing or swapping twice")
        XCTAssertEqual(BoundVBABattleBridge.captureNativeSession(),nativeState,"Relaunch restores exact native ring cursors and entry phase")
        XCTAssertEqual(try JSONSerialization.jsonObject(with:reopened.probe.recoveryData()) as? NSDictionary,
            try JSONSerialization.jsonObject(with:cableState) as? NSDictionary,"Relaunch restores queued native commands without replaying consumed records")
        XCTAssertEqual(reopened.observation?.frame,observation?.frame)
        XCTAssertEqual(reopened.observation?.callback,observation?.callback)
        let newProbe=reopened.probe
        core.updateHandler={ core in receive(core);newProbe.receive(core) }
        reopened.canResume={ true };reopened.resumeTransport()
        NSLog("Native owner and cold core restored with exact native/cable queues")
        return reopened
    }
    private func verifyNativeBridgeRestore(_ core:EmulatorCore) throws {
        // A native checkpoint recreates temporary ROM hooks after RAM restore;
        // it must never re-run entry, heal again or reset command queues.
        _=core.pause()
        let checkpoint=BoundVBABattleBridge.captureServerState(),bridge=BoundVBABattleBridge.captureNativeSession()
        XCTAssertFalse(checkpoint.isEmpty);XCTAssertFalse(bridge.isEmpty)
        let checkpointParty=BoundVBABattleBridge.qaTradeParty()
        BoundVBABattleBridge.close()
        XCTAssertTrue(BoundVBABattleBridge.restoreServerState(checkpoint))
        XCTAssertFalse(BoundVBABattleBridge.restoreNativeSession(Data("{}".utf8)))
        XCTAssertFalse(BoundVBABattleBridge.restoreCooperativeSession(bridge))
        let metadata=try XCTUnwrap(JSONSerialization.jsonObject(with:bridge) as? [String:Any])
        for (key,value) in [("version",UInt64(1)<<32|1),("installed",UInt64(1)<<32)] {
            var invalid=metadata;invalid[key]=value
            XCTAssertFalse(BoundVBABattleBridge.restoreNativeSession(try JSONSerialization.data(withJSONObject:invalid)))
        }
        XCTAssertTrue(BoundVBABattleBridge.restoreNativeSession(bridge))
        XCTAssertEqual(BoundVBABattleBridge.qaTradeParty(),checkpointParty)
        XCTAssertEqual(BoundVBABattleBridge.captureNativeSession(),bridge)
        _=core.resume()
    }
    /// New cartridges start before a starter exists. The same native givemon
    /// recipe as integrated ROM gameplay QA creates this disposable party.
    private func prepareNativeParty(_ core:EmulatorCore) async throws {
        XCTAssertEqual(core.state,.paused)
        XCTAssertTrue(BoundVBABattleBridge.qaStartNativePartyFixture())
        for _ in 0..<200 {
            _=core.resume(); try await Task.sleep(for:.milliseconds(50)); _=core.pause()
            if BoundVBABattleBridge.verifyBattleReady() { return }
        }
        XCTFail("Native givemon did not return a valid party to the overworld")
    }
    /// The paired runtime harness bypasses Friends/UI but still establishes the
    /// production chooser's activity and input-gate state before native entry.
    /// Actual friend identity and UI consent remain the full-app suite's job.
    private func primeNativeInteraction(_ interactions:BoundFriendInteractionSession,
        activity:BoundFriendInteractionPacket.Activity) throws {
        func position(_ x:Int,facing:Int) throws -> BoundFriendWorldPosition {
            let value=["mapGroup":4,"mapNumber":3,"elevation":0,"x":x,"y":8,"facing":facing]
            return try JSONDecoder().decode(BoundFriendWorldPosition.self,from:JSONSerialization.data(withJSONObject:value))
        }
        let local=try position(6,facing:4),peer=try position(7,facing:3),localSession=UUID(),peerSession=UUID()
        interactions.context={ .init(localSession:localSession,peerSession:peerSession,local:local,peer:peer) }
        interactions.start { _ in true }
        XCTAssertTrue(interactions.open())
        interactions.request(activity)
        XCTAssertEqual(interactions.activity,activity)
        XCTAssertNotNil(interactions.requestID)
    }
    /// Disconnect actual channels while the native activity owns the cartridge.
    /// The same running core and journal must survive longer than the former
    /// fifteen-second cable timeout, then complete via newly created channels.
    private func verifyNativeReconnect(native:BoundNativeBattleSession,id:UUID,core:EmulatorCore,
        interactions:BoundFriendInteractionSession,port:Int,peer:String,seconds:Double,
        silent:Bool,disconnect:()->Void,reconnect:()->Void) async throws {
        func barrier(_ phase:Int) async throws {
            _=try await request(port:port,peer:peer,body:["stage":"disconnect","disconnectPhase":phase])
            for _ in 0..<1200 {
                let status=try await request(port:port)
                if let peers=status["peers"] as? [String:[String:Any]],peers.count==2,
                   peers.values.allSatisfy({ ($0["disconnectPhase"] as? Int ?? 0)>=phase }) { return }
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTFail("Both native peers did not reach reconnect phase \(phase)")
            throw NSError(domain:"NativeReconnectBarrier",code:phase)
        }
        // A restored owner starts paused while its fresh peer handshake runs.
        // Drop an established connection, not that still-pending handshake.
        for _ in 0..<600 {
            if !native.isTransportSuspended { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertFalse(native.isTransportSuspended,"Restore handshake must finish before injecting an outage")
        try await barrier(1)
        let activity=native.activity,consent=interactions.requestID
        let disconnectedAt=ProcessInfo.processInfo.systemUptime
        disconnect()
        if silent {
            // No error callback and no explicit suspension: successful sends
            // disappear until production liveness detection stops the engine.
            for _ in 0..<100 {
                if native.isTransportSuspended { break }
                XCTAssertTrue(native.isActive,"Native timeout fired before the transport liveness guard: \(native.lastFailure)")
                try await Task.sleep(for:.milliseconds(50))
            }
        } else { native.suspendTransport() }
        if silent {
            let elapsed=ProcessInfo.processInfo.systemUptime-disconnectedAt
            XCTAssertGreaterThan(elapsed,0.8,"Fast-forward must not accelerate the two-second wall-clock liveness timeout")
            XCTAssertLessThan(elapsed,5,"Silent loss must be detected using real elapsed time")
            NSLog("Native silent-loss detection %@: %.3f seconds",peer,elapsed)
        }
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertTrue(native.isTransportSuspended)
        XCTAssertEqual(core.state,.paused,"The native engine must not run link timeouts while transport is unavailable")
        for packet in [BoundBattleControlPacket(id:id,kind:.prepared),BoundBattleControlPacket(id:id,kind:.connected),
            BoundBattleControlPacket(id:id,kind:.resumeReady,nonce:UUID(),acknowledgement:UUID()),
            BoundBattleControlPacket(id:UUID(),kind:.abort)] {
            native.receive(try XCTUnwrap(packet.encoded()))
            XCTAssertTrue(native.isTransportSuspended,"Old barriers and another activity cannot satisfy fresh reconnect consent")
            XCTAssertTrue(native.isActive)
            XCTAssertEqual(core.state,.paused)
        }
        let heldFrame=native.observation?.frame
        let heldHP=native.observation?.playerHP
        let heldTrades=native.observation?.tradeCount
        try await barrier(2)
        for _ in 0..<Int(ceil(seconds*10)) {
            XCTAssertTrue(native.isActive,"Temporary loss must not end the native activity: \(native.lastFailure)")
            XCTAssertTrue(native.blocksAutoSave,"A suspended native transaction remains protected")
            XCTAssertTrue(native.isTransportSuspended)
            XCTAssertEqual(native.activity,activity)
            XCTAssertEqual(interactions.requestID,consent)
            XCTAssertEqual(interactions.phase,.connecting)
            XCTAssertTrue(interactions.blocksGameplay,"Reconnect must not let new input mutate a paused transaction")
            XCTAssertEqual(core.state,.paused)
            XCTAssertEqual(native.observation?.frame,heldFrame)
            XCTAssertEqual(native.observation?.playerHP,heldHP)
            XCTAssertEqual(native.observation?.tradeCount,heldTrades)
            XCTAssertEqual(native.restoredBattles,0)
            XCTAssertEqual(native.completedTrades,0)
            XCTAssertTrue(native.lastFailure.isEmpty)
            try await Task.sleep(for:.milliseconds(100))
        }
        try await barrier(3)
        reconnect(); native.resumeTransport()
        for _ in 0..<600 {
            if !native.isTransportSuspended { break }
            XCTAssertTrue(native.isActive,"Fresh-channel handshake must retain the same activity")
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertFalse(native.isTransportSuspended,"Both peers must agree to resume through the replacement channels")
        XCTAssertTrue(native.isActive)
        XCTAssertEqual(core.state,.running)
        XCTAssertEqual(native.activity,activity)
        XCTAssertEqual(interactions.phase,.playing)
        XCTAssertTrue(native.lastFailure.isEmpty)
        try await barrier(4)
    }
    private func request(port:Int,peer:String?=nil,body:[String:Any]?=nil) async throws->[String:Any] {
        var request=URLRequest(url:URL(string:"http://127.0.0.1:\(port)/"+(peer ?? "status"))!)
        request.timeoutInterval=5
        if let body { request.httpMethod="POST"; request.httpBody=try JSONSerialization.data(withJSONObject:body) }
        let (data,_)=try await URLSession.shared.data(for:request)
        return try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
    }
}

/// Test-only reliable message channel. The host relay sees cable frames only;
/// wire framing, command admission and native queues use production code.
private final class NativeBattleRelayChannel:BoundBattleChannel,@unchecked Sendable {
    private let queue=DispatchQueue(label:"Native battle test messages")
    private let connection:NWConnection
    private var buffered=Data()
    private var active=true
    private var ready=false
    private var dropping=false
    private var waiting:[Data]=[]
    private let receive:@Sendable (Data)->Void
    private let failed:@Sendable ()->Void
    init(port:UInt16,peer:String,receive:@escaping @Sendable (Data)->Void,failed:@escaping @Sendable ()->Void) {
        self.receive=receive; self.failed=failed
        let tcp=NWProtocolTCP.Options(); tcp.noDelay=true
        connection=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:NWParameters(tls:nil,tcp:tcp))
        connection.stateUpdateHandler={ [weak self] state in
            guard let self,self.active else { return }
            if case .ready=state {
                self.connection.send(content:Data(peer.utf8),completion:.contentProcessed { _ in })
                self.ready=true
                let waiting=self.waiting; self.waiting.removeAll()
                for data in waiting { self.write(data) }
                self.read()
            }
            if case .failed=state { self.failed() }
        }
        connection.start(queue:queue)
    }
    func send(_ data:Data)->Bool {
        guard data.count<=4134 else { return false }
        queue.async { [self] in
            guard active else { return }
            if ready { write(data) }
            else if waiting.count<64 { waiting.append(data) }
            else { failed() }
        }
        return true
    }
    private func write(_ data:Data) {
        guard !dropping else { return }
        let count=data.count
        let header=Data([UInt8(count>>24),UInt8(truncatingIfNeeded:count>>16),UInt8(truncatingIfNeeded:count>>8),UInt8(truncatingIfNeeded:count)])
        connection.send(content:header+data,completion:.contentProcessed { [weak self] error in
            if error != nil,self?.active==true { self?.failed() }
        })
    }
    private func read() {
        connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] data,_,ended,error in
            guard let self,self.active else { return }
            if let data { self.buffered.append(data) }
            guard self.buffered.count<=131072 else { self.failed(); return }
            while self.buffered.count>=4 {
                let count=self.buffered.prefix(4).reduce(0) { ($0<<8)|Int($1) }
                guard count>=38,count<=4134 else { self.failed(); return }
                guard self.buffered.count>=count+4 else { break }
                if !self.dropping { self.receive(Data(self.buffered.dropFirst(4).prefix(count))) }
                self.buffered.removeFirst(count+4)
            }
            if ended || error != nil { self.failed(); return }
            self.read()
        }
    }
    func close() { queue.async { [self] in active=false; connection.cancel() } }
    func dropTraffic() { queue.sync { dropping=true } }
}

final class BoundHandoffSafetyTests: XCTestCase {
    private let iwram = 479
    private var ewram: Int { iwram + 0x8400 }
    private func fixture() -> Data {
        var value = Data(repeating: 0, count: ewram + 0x40000)
        set(10, at: 0, in: &value)
        return value
    }
    private func set(_ word: UInt32, at offset: Int, in data: inout Data) {
        for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: word >> (byte * 8)) }
    }
    private func withGzip(_ bytes: Data, _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".state")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try XCTUnwrap(gzopen(url.path, "wb"))
        let count = bytes.withUnsafeBytes { gzwrite(file, $0.baseAddress, UInt32($0.count)) }
        XCTAssertEqual(count, Int32(bytes.count)); XCTAssertEqual(gzclose(file), Z_OK)
        try body(url)
    }
    func testCleanAndClosedTradeStatesRemainTransferable() throws {
        var bytes = fixture()
        set(0x314D4642, at: iwram + 0x4030, in: &bytes)
        set(0x09FFFC20, at: iwram + 0xEB8, in: &bytes)
        try withGzip(bytes) { try BoundHandoffSaveStatePolicy.validateGBAState(at: $0, nativeBoundROM: true) }
        // The mailbox and stopped script pointer are inert after native exit.
        bytes[iwram + 0x3529] = 2
        set(8, at: ewram + 0x22B4C, in: &bytes) // An ordinary trainer battle.
        try withGzip(bytes) { try BoundHandoffSaveStatePolicy.validateGBAState(at: $0, nativeBoundROM: true) }
    }
    func testActiveNativeBattleTradeAndDialogueStatesAreRejectedBeforeLoad() throws {
        var cases: [Data] = []
        var bytes = fixture()
        set(0x314D4642, at: iwram + 0x4030, in: &bytes)
        bytes[iwram + 0x3FB1] = 4; cases.append(bytes) // Native trade/link menu.
        bytes[iwram + 0x3FB1] = 0
        bytes[iwram + 0x3529] = 2
        set(2, at: ewram + 0x22B4C, in: &bytes); cases.append(bytes)
        bytes = fixture(); bytes[iwram + 0xEB1] = 2
        set(0x09FFFD20, at: iwram + 0xEB8, in: &bytes); cases.append(bytes)
        bytes = fixture(); set(0x09FFF849, at: iwram + 0x30F4, in: &bytes); cases.append(bytes)
        bytes = fixture(); set(0x09FFF8AD, at: 24 + 15 * 4, in: &bytes); cases.append(bytes)
        bytes = fixture(); set(0x09FFF8AD, at: 459, in: &bytes); cases.append(bytes)
        bytes = fixture(); bytes[iwram + 0x5094] = 1
        set(0x09FFF89D, at: iwram + 0x5090, in: &bytes); cases.append(bytes)
        for candidate in cases {
            try withGzip(candidate) {
                XCTAssertThrowsError(try BoundHandoffSaveStatePolicy.validateGBAState(at: $0, nativeBoundROM: true)) {
                    guard case BoundHandoffSaveStatePolicy.Failure.temporaryNativeState = $0 else { return XCTFail("Unexpected error: \($0)") }
                }
            }
        }
    }
    func testUnrelatedGBAGamesDoNotUseBoundNativeAddressPolicy() throws {
        var bytes = fixture()
        set(0x09FFF849, at: iwram + 0x30F4, in: &bytes)
        try withGzip(bytes) { try BoundHandoffSaveStatePolicy.validateGBAState(at: $0, nativeBoundROM: false) }
    }
    func testUnknownTruncatedAndCorruptSnapshotsFailClosed() throws {
        var unknown = fixture(); set(11, at: 0, in: &unknown)
        for bytes in [unknown, Data(fixture().prefix(100))] {
            try withGzip(bytes) { XCTAssertThrowsError(try BoundHandoffSaveStatePolicy.validateGBAState(at: $0, nativeBoundROM: true)) }
        }
        try withGzip(fixture()) { url in
            var encoded = try Data(contentsOf: url)
            encoded[encoded.count - 8] ^= 0xff // Gzip CRC.
            try encoded.write(to: url)
            XCTAssertThrowsError(try BoundHandoffSaveStatePolicy.validateGBAState(at: url, nativeBoundROM: true))
        }
        try withGzip(fixture()) { url in
            let encoded = try Data(contentsOf: url)
            try Data(encoded.dropLast(6)).write(to: url)
            XCTAssertThrowsError(try BoundHandoffSaveStatePolicy.validateGBAState(at: url, nativeBoundROM: true))
        }
        try withGzip(Data(repeating: 0, count: 2 * 1024 * 1024 + 1)) {
            XCTAssertThrowsError(try BoundHandoffSaveStatePolicy.validateGBAState(at: $0, nativeBoundROM: true))
        }
    }
    func testAsyncHandoffCannotFollowAReplacementCoreOrNewProtection() {
        let original = NSObject(), replacement = NSObject()
        let identity = BoundHandoffCoreIdentity(gameID: "rom", core: original)
        XCTAssertTrue(identity.matches(gameID: "rom", core: original, allowed: true))
        XCTAssertFalse(identity.matches(gameID: "rom", core: replacement, allowed: true))
        XCTAssertFalse(identity.matches(gameID: "other", core: original, allowed: true))
        XCTAssertFalse(identity.matches(gameID: "rom", core: original, allowed: false))
        XCTAssertFalse(identity.matches(gameID: "rom", core: nil, allowed: true))
    }
}

import XCTest
import UIKit
import CryptoKit
import DeltaCore
import Network
@testable import Delta

private struct NativeBattleGame:GameProtocol {
    let fileURL:URL
    let gameSaveURL:URL
    var type:GameType { .gba }
}
private final class NativeBattleDriver:@unchecked Sendable {
    private let lock=NSLock()
    private let reader=BoundVBAPlayerStateProbe()
    private var frame=0,battleFrame:Int?,lastMask=0
    private var playing=false,moves=false,didBoot=false,didDamage=false
    private var initialHP:[Int]?
    let booted=XCTestExpectation(description:"Native overworld")
    let entered=XCTestExpectation(description:"Native battle")
    let damage=XCTestExpectation(description:"Native battle damage")
    init(core:EmulatorCore,profile:BoundPlayerROMProfile) {
        reader.configure(coreID:ObjectIdentifier(core),profile:profile,active:true,status:.waiting,detail:"Native battle cold boot")
    }
    func play(moves:Bool) { lock.lock(); playing=true; self.moves=moves; lock.unlock() }
    var damaged:Bool { lock.lock(); defer { lock.unlock() }; return didDamage }
    func receive(_ core:EmulatorCore) {
        frame+=1
        lock.lock(); let playing=playing,moves=moves; lock.unlock()
        if !playing {
            let value=reader.receive(core)
            if value?.status == .live,!didBoot { didBoot=true; booted.fulfill() }
            apply(didBoot ? 0:(1300..<1302).contains(frame) ? 8:(1600..<1602).contains(frame)||(2200..<2202).contains(frame) ? 1:0,core:core)
            return
        }
        let battle=BoundVBABattleBridge.isInBattle()
        if battle,battleFrame==nil { battleFrame=frame; entered.fulfill() }
        let hp=BoundVBABattleBridge.playerHP().map { $0.intValue }
        if battle,hp.first ?? 0>0,initialHP==nil { initialHP=hp }
        if battle,let initialHP,hp != initialHP {
            lock.lock(); let first = !didDamage; didDamage=true; lock.unlock()
            if first { damage.fulfill() }
        }
        if battle,moves,let battleFrame,frame-battleFrame>120 { apply((frame-battleFrame)%12<2 ? 1:0,core:core) }
        else { apply(0,core:core) }
    }
    private func apply(_ mask:Int,core:EmulatorCore) {
        for bit in [1,8] where mask&bit != lastMask&bit {
            if mask&bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit,value:1,playerIndex:0) }
            else { core.deltaCore.emulatorBridge.deactivateInput(bit,playerIndex:0) }
        }
        lastMask=mask
    }
}

private final class NativeTradeDriver:@unchecked Sendable {
    private let lock=NSLock(),reader=BoundVBAPlayerStateProbe()
    private var frame=0,lastMask=0,playing=false,boot=false
    private var callbackID = -1,stateFrame=0
    private var count=0,marker=0
    private let offersEnabled:Bool
    let booted=XCTestExpectation(description:"Trade overworld boot")
    init(core:EmulatorCore,profile:BoundPlayerROMProfile,offersEnabled:Bool=true) {
        self.offersEnabled=offersEnabled
        reader.configure(coreID:ObjectIdentifier(core),profile:profile,active:true,status:.waiting,detail:"Trade boot")
    }
    func begin() { lock.lock(); playing=true; lock.unlock() }
    var currentMarker:Int { lock.lock(); defer { lock.unlock() }; return marker }
    func receive(_ core:EmulatorCore) {
        frame+=1
        lock.lock(); let playing=playing; lock.unlock()
        if !playing {
            if reader.receive(core)?.status == .live,!boot { boot=true; booted.fulfill() }
            apply(boot ? 0:(1300..<1302).contains(frame) ? 8:(1600..<1602).contains(frame)||(2200..<2202).contains(frame) ? 1:0,core)
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
            else if cursor != 12 { mask=elapsed%30<2 ? 64:0 } // Up selects native Cancel with one party member.
            else { mask=elapsed%30<2 ? 1:0 }
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

    func testActualSharedWorldCollisionAndNativeCoexistence() async throws {
        try await verifySharedWorldRuntime(sightline: false)
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
        XCTAssertTrue(BoundVBABattleBridge.installSoulLink(), "Both independent hook owners must admit the same base hash")
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady(), "Native trade/battle admission strips both owned hooks when verifying the original ROM")
        let state = BoundVBABattleBridge.sharedWorldSnapshot()
        let flags = try XCTUnwrap(state["flags"] as? Data)
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
        XCTAssertEqual(world.read()?.flags, flags, "The production completed-frame mailbox must publish a usable local snapshot")
        let peer = BoundWorldState(group: try XCTUnwrap(state["group"] as? UInt8), number: try XCTUnwrap(state["number"] as? UInt8),
                                   flags: flags, boulders: state["boulders"] as? Data ?? Data())
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
        XCTAssertEqual(BoundVBABattleBridge.sharedWorldSnapshot()["flags"] as? Data, flags, "Collision gates must never edit earned progress")
        BoundVBABattleBridge.setSharedWorldPeer(Data(), group: 0, number: 0, boulders: Data(), fresh: false)
        XCTAssertTrue(sightline ? BoundVBABattleBridge.qaStartSharedWorldSightlineWait() : BoundVBABattleBridge.qaStartSharedWorldWait())
        world.publishPolicy(enabled: true, peer: nil, fresh: false)
        // The native trainer command must stage the waiting RAM script first.
        _ = core.resume(); try await Task.sleep(for: .milliseconds(350)); _ = core.pause()
        let pointer = try XCTUnwrap(core.deltaCore.emulatorBridge.readMemory?(at: 0xEB8, size: 4))
        let address = pointer.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        XCTAssertTrue((0x03004200..<0x03004220).contains(address), "The native denied-trainer script must already be waiting in serialized RAM")
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
        XCTAssertTrue(BoundVBABattleBridge.friendDialogueReady(), "The saved native waiting window must release normally with all multiplayer ROM code removed")
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
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous=scene.windows.first { $0.isKeyWindow }, window=UIWindow(windowScene:scene), owner=UIViewController(), view=GameView()
        window.rootViewController=owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame=CGRect(x:0,y:150,width:window.bounds.width,height:window.bounds.width*2/3); core.add(view)
        let driver=NativeBattleDriver(core:core,profile:try BoundPlayerROMProfile(rom:originalROM)),probe=BoundFriendDialogueProbe()
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
        core.updateHandler = { core in driver.receive(core); probe.receive(core) }
        defer {
            _ = core.pause(); BoundVBABattleBridge.closeSoulLink(); _ = core.stop()
            window.isHidden = true; previous?.makeKeyAndVisible()
        }
        core.rate = 8; XCTAssertTrue(core.start()); await fulfillment(of: [driver.booted], timeout: 90)
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
        XCTAssertTrue(BoundVBABattleBridge.qaStartSoulCheck()); _ = core.resume()
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
        BoundVBABattleBridge.qaFinishSoulCheck()
        _ = core.resume(); try await Task.sleep(for: .milliseconds(100)); _ = core.pause()
        XCTAssertTrue(BoundVBABattleBridge.qaStartSoulCheck()); _ = core.resume()
        try await Task.sleep(for: .milliseconds(250)); _ = core.pause()
        let second = BoundVBABattleBridge.qaSoulCheckResult().map(\.intValue)
        XCTAssertEqual(second.count, 3); XCTAssertEqual(second[1], 0); XCTAssertEqual(second[2], 0, "Native healing cannot revive a denied Pokemon")
        BoundVBABattleBridge.qaFinishSoulCheck()
        try core.load(DeltaCore.SaveState(fileURL: before, gameType: .gba))
        XCTAssertGreaterThan(BoundVBABattleBridge.playerHP().first?.intValue ?? 0, 0, "The old state really contained a healthy party")
        let reopened = BoundSoulProbe(); reopened.configure(core: core, url: journal); reopened.setVerified(true)
        core.updateHandler = { core in driver.receive(core); reopened.receive(core) }
        _ = core.resume(); try await Task.sleep(for: .milliseconds(200)); _ = core.pause()
        XCTAssertTrue(reopened.read().ledger?.dead.contains(starter.slot) == true)
        XCTAssertEqual(BoundVBABattleBridge.playerHP().first?.intValue, 0, "Old-state load and journal reload cannot revive the link")
        XCTAssertNil(reopened.read().error)
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
        let profile=try BoundPlayerROMProfile(rom:originalROM)
        let output=fixtures.appendingPathComponent("native-trade-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let battery=output.appendingPathComponent("work.sav"); try originalSeed.write(to:battery)
        let core=try XCTUnwrap(EmulatorCore(game:NativeBattleGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene),owner=UIViewController(),view=GameView()
        window.rootViewController=owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame=CGRect(x:0,y:150,width:window.bounds.width,height:window.bounds.width*2/3); core.add(view)
        let driver=NativeTradeDriver(core:core,profile:profile,offersEnabled:!cancelMode),native=BoundNativeBattleSession(),interactions=BoundFriendInteractionSession()
        let probe=native.probe
        core.updateHandler={ core in driver.receive(core); probe.receive(core) }
        var channel:NativeBattleRelayChannel?
        defer {
            native.cancel(resume:false); channel?.close(); _=core.pause(); BoundVBABattleBridge.close(); _=core.stop()
            window.isHidden=true; previous?.makeKeyAndVisible()
        }
        core.rate=8; XCTAssertTrue(core.start()); await fulfillment(of:[driver.booted],timeout:90)
        _=core.pause(); core.rate=1
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady())
        let offered=peer=="A" ? 0xBB:0xBC
        let expected=cancelMode ? offered : peer=="A" ? 0xBC:0xBB
        XCTAssertTrue(BoundVBABattleBridge.qaPrepareTradeFixture(UInt(offered)))
        let beforeTrade=BoundVBABattleBridge.qaTradeParty()
        native.bind(core:core,gameID:output.lastPathComponent,interactions:interactions); native.canResume={ true }
        native.makeChannel={ receiver,failed in
            let value=NativeBattleRelayChannel(port:relayPort,peer:peer,receive:{ data in
                if data.starts(with:BoundBattleControlPacket.prefix) { Task { @MainActor in native.receive(data) } }
                else { receiver(data) }
            },failed:failed)
            channel=value; return value
        }
        native.sendControl={ channel?.send($0)==true }
        driver.begin(); _=core.resume(); native.begin(activity:.trade,id:id,initiator:peer=="A")
        for tick in 0..<9000 {
            if tick%200==0 { NSLog("Native trade %@ callback=%08x script=%d trades=%d %@",peer,native.observation?.callback ?? 0,native.observation?.scriptResult ?? -1,native.observation?.tradeCount ?? 0,native.probe.diagnostics) }
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
        XCTAssertEqual(native.completedTrades,cancelMode ? 0:1,"Native trade failed: \(native.lastFailure) \(native.lastCableDiagnostic)")
        _=core.pause()
        if !cancelMode {
            let received=BoundVBABattleBridge.qaTradeParty()
            XCTAssertEqual(received[8],UInt8(expected),"Native swap must deliver the peer's offered Pokémon")
            XCTAssertEqual(received[4],UInt8(expected),"The original trainer identity must travel with the offered Pokémon")
            XCTAssertEqual(received.subdata(in:100..<200),beforeTrade.subdata(in:100..<200),"The unoffered party member stays unchanged")
            XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady(),"Return to the real overworld with all hooks removed")
        }
        XCTAssertFalse(native.blocksAutoSave)
        // Start a new emulator instance from the actual cartridge save, not a state.
        XCTAssertTrue(core.stop()); core.updateHandler=nil
        let reopened=try XCTUnwrap(EmulatorCore(game:NativeBattleGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
        let reboot=NativeTradeDriver(core:reopened,profile:profile)
        reopened.updateHandler={ reboot.receive($0) }; reopened.rate=8; reopened.add(view)
        XCTAssertTrue(reopened.start()); await fulfillment(of:[reboot.booted],timeout:90); _=reopened.pause()
        let persisted=BoundVBABattleBridge.qaTradeParty(); XCTAssertEqual(persisted[8],UInt8(expected))
        XCTAssertEqual(persisted[4],UInt8(expected))
        XCTAssertEqual(persisted.subdata(in:100..<200),beforeTrade.subdata(in:100..<200))
        XCTAssertTrue(reopened.stop())
        XCTAssertEqual(try Data(contentsOf:rom),originalROM); XCTAssertEqual(try Data(contentsOf:seed),originalSeed)
        let report:[String:Any]=["stage":"done","trade":native.completedTrades==1,"canceled":cancelMode && !native.isActive,"persisted":persisted[8]==UInt8(expected),"cable":native.lastCableDiagnostic]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        _=try await request(port:port,peer:peer,body:report)
    }
    func testActualNativeLinkBattle() async throws { try await runNativeBattle(entryOnly:false) }
    func testNativeSessionForwardedEntry() async throws { try await runNativeBattle(entryOnly:true) }
    private func runNativeBattle(entryOnly:Bool) async throws {
        continueAfterFailure=false
        let env=ProcessInfo.processInfo.environment
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
        let battery=output.appendingPathComponent("work.sav"); try seedBytes.write(to:battery)
        let core=try XCTUnwrap(EmulatorCore(game:NativeBattleGame(fileURL:romURL,gameSaveURL:battery),options:[.metal:true]))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene),owner=UIViewController(),gameView=GameView()
        window.rootViewController=owner; window.makeKeyAndVisible()
        gameView.frame=CGRect(x:0,y:150,width:window.bounds.width,height:window.bounds.width*2/3)
        owner.view.addSubview(gameView); core.add(gameView)
        let driver=NativeBattleDriver(core:core,profile:profile)
        let native=BoundNativeBattleSession(),interactions=BoundFriendInteractionSession(),probe=native.probe
        core.updateHandler={ core in driver.receive(core); probe.receive(core) }
        var channel:NativeBattleRelayChannel?
        defer {
            native.cancel(resume:false); channel?.close(); native.makeChannel=nil; native.sendControl=nil
            _=core.pause(); BoundVBABattleBridge.close(); _=core.stop()
            window.isHidden=true; previous?.makeKeyAndVisible()
        }
        core.rate=8; XCTAssertTrue(core.start())
        await fulfillment(of:[driver.booted],timeout:90)
        _=core.pause(); core.rate=1
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady())
        let before=output.appendingPathComponent("before.state"); core.saveSaveState(to:before)
        native.bind(core:core,gameID:output.lastPathComponent,interactions:interactions)
        native.canResume={ true }
        native.makeChannel={ receiver,failed in
            let value=NativeBattleRelayChannel(port:relayPort,peer:peer,receive:{ data in
                if data.starts(with:BoundBattleControlPacket.prefix) { Task { @MainActor in native.receive(data) } }
                else { receiver(data) }
            },failed:failed)
            channel=value; return value
        }
        native.sendControl={ data in channel?.send(data)==true }
        driver.play(moves:!entryOnly); _=core.resume()
        native.begin(activity:.battle,id:uuid,initiator:peer=="A")
        var entered=false
        for tick in 0..<1200 {
            if tick%100==0 { NSLog("Native entry %@: frame=%llu callback=%08x result=%d %@",peer,native.observation?.frame ?? 0,native.observation?.callback ?? 0,native.observation?.scriptResult ?? -1,native.probe.diagnostics) }
            if native.observation?.battle==true { entered=true; break }
            if !native.isActive { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertTrue(entered,"Native entry failed: \(native.lastFailure), \(native.lastCableDiagnostic), result \(native.observation?.scriptResult ?? -1)")
        _=try await request(port:port,peer:peer,body:["stage":"entered"])
        for _ in 0..<200 {
            let status=try await request(port:port)
            if let peers=status["peers"] as? [String:[String:Any]],peers.count==2,peers.values.allSatisfy({ ["entered","done"].contains($0["stage"] as? String ?? "") }) { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        if entryOnly { native.cancel() }
        else {
            var done=false
            for tick in 0..<8000 {
                if tick%200==0 { NSLog("Native battle %@: frame=%llu callback=%08x HP=%@ %@",peer,native.observation?.frame ?? 0,native.observation?.callback ?? 0,String(describing:native.observation?.playerHP),native.probe.diagnostics) }
                if native.completedBattles==1 { done=true; break }
                if !native.isActive { break }
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTAssertTrue(done,"Native battle failed: \(native.lastFailure), \(native.lastCableDiagnostic)")
            XCTAssertTrue(driver.damaged,"A native move must change party HP")
        }
        _=core.pause()
        XCTAssertEqual(native.restoredBattles,1)
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady())
        XCTAssertEqual(try Data(contentsOf:romURL),rom)
        XCTAssertEqual(try Data(contentsOf:seed),seedBytes)
        let report:[String:Any]=["stage":"done","entryOnly":entryOnly,"battle":entered,
            "damaged":driver.damaged,"restored":native.restoredBattles==1,"cable":native.lastCableDiagnostic,
            "outcome":native.observation?.outcome ?? 0]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        _=try await request(port:port,peer:peer,body:report)
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
        guard data.count<=4126 else { return false }
        queue.async { [self] in
            guard active else { return }
            if ready { write(data) }
            else if waiting.count<64 { waiting.append(data) }
            else { failed() }
        }
        return true
    }
    private func write(_ data:Data) {
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
                guard count>30,count<=4126 else { self.failed(); return }
                guard self.buffered.count>=count+4 else { break }
                self.receive(Data(self.buffered.dropFirst(4).prefix(count)))
                self.buffered.removeFirst(count+4)
            }
            if ended || error != nil { self.failed(); return }
            self.read()
        }
    }
    func close() { queue.async { [self] in active=false; connection.cancel() } }
}

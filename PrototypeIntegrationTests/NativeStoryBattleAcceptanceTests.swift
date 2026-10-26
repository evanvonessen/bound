import XCTest
import CryptoKit
import UIKit
@preconcurrency import DeltaCore
@testable import Delta

private struct StoryBattleGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}
private struct StoryBattleFailure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}

/// Ordinary input only: a delivered edge and native menu acceptance are separate.
private struct StoryBattleTap {
    let key: Int
    var phase = 0, polls = 0
    var acknowledged = false, complete = false, failed = false
    mutating func observe(held: Int) -> Int {
        guard !complete && !failed else { return 0 }
        polls += 1
        switch phase {
        case 0:
            if held == 0 { phase = 1; polls = 0; return key }
        case 1:
            if held & key == key { acknowledged = true; phase = 2; polls = 0; return 0 }
        default:
            if held == 0 { complete = true; return 0 }
        }
        if polls >= 12 { failed = true; return 0 }
        return phase == 1 ? key : 0
    }
}

private enum StoryBattlePartyOrder {
    /// Native GetPartyIdFromBattleSlot (08127F7C), not the field-party index.
    static func decode(_ packed: [UInt8]) -> [Int]? {
        guard packed.count == 3 else { return nil }
        let order = packed.flatMap { [Int($0 >> 4), Int($0 & 15)] }
        return Set(order) == Set(0..<6) ? order : nil
    }
}

/// Exact02f97 read-only view. Native helper/table evidence is retained in
/// phase8/native-battle-acceptance-design; no method calls a guest function.
private struct StoryBattleView {
    let memory: BoundGBAMemorySnapshot
    let callback: UInt64
    let time: UInt64
    let request: BoundROMRequest?
    func bytes(_ address: Int, _ count: Int) -> Data { Data(memory.bytes(at: address, count: count) ?? []) }
    func byte(_ address: Int) -> Int { Int(memory.bytes(at: address, count: 1)?.first ?? 0) }
    func half(_ address: Int) -> Int { byte(address) | byte(address + 1) << 8 }
    func word(_ address: Int) -> Int { half(address) | half(address + 2) << 16 }
    var save: Int { word(0x03005008) }
    var validSave: Bool { (0x02000000...0x0203C000).contains(save) }
    func flag(_ id: Int) -> Bool {
        guard validSave, (1..<0x1900).contains(id) else { return false }
        let at = id < 0x900 ? save + 0xEE0 + id / 8 : 0x0203B174 + (id - 0x900) / 8
        return byte(at) & (1 << (id & 7)) != 0
    }
    func variable(_ id: Int) -> Int {
        guard validSave, (0x4000..<0x4100).contains(id) else { return -1 }
        return half(save + 0x1000 + (id - 0x4000) * 2)
    }
    var map: [Int] { validSave ? [byte(save + 4), byte(save + 5), half(save), half(save + 2)] : [] }
    var battle: Bool { byte(0x03003529) & 2 != 0 }
    var outcome: Int { byte(0x02023E8A) }
    var trainer: Int { half(0x020386AE) }
    var battleType: Int { word(0x02022B4C) }
    var held: Int { half(0x0300311C) }
    var count: Int { byte(0x02024029) }
    var party: Data { (1...6).contains(count) ? bytes(0x02024284, count * 100) : Data() }
    var mons: [BoundSoulMon] { BoundSoulMon.decode(party, stride: 100) }
    var controllers: [Int] { (0..<4).map { word(0x03004FE0 + 4 * $0) } }
    var pending: Int { word(0x02023BC8) }
    var battler: Int? {
        guard battle else { return nil }
        return [0, 2].first { pending & (1 << $0) != 0 && [0x0802E439,0x090A9EA1,0x0802EA11].contains(controllers[$0]) }
    }
    var menu: String? { battler.map { controllers[$0] == 0x0802EA11 ? "move" : "action" } }
    func cursor(_ battler: Int, move: Bool) -> Int { byte((move ? 0x02023FFC : 0x02023FF8) + battler) }
    func partyIndex(_ battler: Int) -> Int { byte(0x02023BCE + battler * 2) }
    var partyOrder: [Int]? { StoryBattlePartyOrder.decode(Array(bytes(0x0203B0DC, 3))) }
    func response(_ battler: Int) -> Data { bytes(0x020233C4 + battler * 512, 5) }
    func pp(_ slot: Int) -> [Int] { (0..<4).map { byte(0x02024284 + slot * 100 + 52 + $0) } }
    func moves(_ slot: Int) -> [Int] { (0..<4).map { half(0x02024284 + slot * 100 + 44 + 2 * $0) } }
    var tasks: [Int] { (0..<16).filter { byte(0x03005094 + 40 * $0) != 0 }.map { word(0x03005090 + 40 * $0) } }
    var fadeClear: Bool { byte(0x02037ABF) & 0x80 == 0 }
    var partyScreen: Bool { battle && word(0x030030F4) == 0x0811EBA1 && byte(0x0203B0A8) & 15 == 1 && fadeClear }
    var partyReady: Bool { partyScreen && tasks.contains { [0x0811FB29,0x090B6231].contains($0) } }
    var partyContextReady: Bool { partyScreen && tasks.contains(0x08122C5D) }
    var selectedMon: Int { byte(0x0203B0A9) }
    var partyAction: Int { byte(0x0203B0AB) }
    var contextCursor: Int { byte(0x0203ADE6) }
    var contextActions: [Int] {
        let pointer = word(0x0203B09C)
        guard (0x02000000...0x0203FFE0).contains(pointer), (1...8).contains(byte(pointer + 0x17)) else { return [] }
        return (0..<byte(pointer + 0x17)).map { byte(pointer + 0xF + $0) }
    }
    var fieldReady: Bool {
        !battle && validSave && word(0x030030F0) == 0x08056535 && word(0x030030F4) == 0x080565B5
            && byte(0x03000F9C) == 0 && byte(0x03000EA8) == 2 && request?.permitsFieldInterruption == true && held == 0
    }
    var story: [Int] { [flag(0x500 + 0x2C) ? 1 : 0, variable(0x4013), flag(0x906) ? 1 : 0] }
    func itemQuantity(_ item: Int) -> Int? {
        var total = 0
        for pocket in 0..<5 {
            let base = word(0x0203988C + pocket * 8), capacity = half(0x02039890 + pocket * 8)
            guard (1...1024).contains(capacity), base >= 0x02000000, base + capacity * 4 <= 0x02040000 else { return nil }
            // Exact02f GetBagItemQuantity08099DA0 reads the native halfword.
            for index in 0..<capacity where half(base + index * 4) == item { total += half(base + index * 4 + 2) }
        }
        return total
    }
    var facts: [String: Any] {
        ["callback": callback, "monotonicNanoseconds": time, "nativeFrame": request?.frame as Any? ?? NSNull(),
         "battle": battle, "trainer": trainer, "battleType": battleType, "outcome": outcome,
         "mainCallbacks": [word(0x030030F0),word(0x030030F4)], "controllers": controllers,
         "pendingControllers": pending, "menu": menu as Any? ?? NSNull(),
         "actionCursors": (0..<4).map { cursor($0,move:false) }, "moveCursors": (0..<4).map { cursor($0,move:true) },
         "partyIndexes": (0..<4).map(partyIndex), "partyScreenOrder": partyOrder as Any? ?? NSNull(),
         "responses": (0..<4).map { response($0).map { String(format:"%02x",$0) }.joined() },
         "party": mons.enumerated().map { i,m in ["pid":m.identity.personality,"ot":m.identity.trainer,"species":m.species,"level":m.level ?? 0,"hp":m.hp ?? -1,"pp":pp(i)] as [String:Any] },
         "enemyHP": (0..<6).map { half(0x0202402C + 100 * $0 + 86) },
         "tasks": tasks, "partyReady": partyReady, "partyContextReady": partyContextReady,
         "selectedMon":selectedMon,"partyAction":partyAction,"contextCursor":contextCursor,"contextActions":contextActions,
         "heldKeys":held,"newKeys":half(0x0300311E),"fadeClear":fadeClear,"map":map,"story":story,
         "scriptState":byte(0x03000EA8),"scriptLock":byte(0x03000F9C),"fieldReady":fieldReady]
    }
}

private final class NativeStoryBattleDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: UInt64 = 0, hostSequence: UInt32 = 0
    private var lastMask = 0, tap: StoryBattleTap?, tapID = 0, finishedTap = 0
    private var tapRows: [[String:Any]] = [], trace: [[String:Any]] = [], receipts: [[String:Any]] = []
    private var latest: StoryBattleView?, failure: String?, stage = "restored", signature = ""
    func setStage(_ value: String) { lock.lock(); stage = value; lock.unlock() }
    func enqueue(_ key: Int) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard tap == nil, lastMask == 0, failure == nil, [1,2,16,32,64,128].contains(key), tapID < 1000 else {
            throw StoryBattleFailure("Input owner busy, invalid key or request bound exceeded")
        }
        tapID += 1; tap = StoryBattleTap(key:key); tapRows = []; return tapID
    }
    func state() -> (StoryBattleView?, Int, String?, Bool) {
        lock.lock(); defer { lock.unlock() }; return (latest,finishedTap,failure,tap == nil && lastMask == 0)
    }
    func evidence() -> [String:Any] {
        lock.lock(); defer { lock.unlock() }
        return ["trace":trace,"inputReceipts":receipts,"failure":failure as Any? ?? NSNull(),"callbacks":frame]
    }
    func receive(_ core: EmulatorCore) {
        BoundFrameMemory.perform {
            lock.lock(); defer { lock.unlock() }
            frame += 1
            // Declared fixture host port only, with no native recovery/QA script.
            if frame % 60 == 1 {
                var host = BoundROMHostState(); host.enabled = true; host.ended = true; host.status = .complete
                hostSequence &+= 2; if hostSequence == 0 { hostSequence = 2 }
                MultiRedAdapter.applySetupHost(host.encoded(sequence:hostSequence))
            }
            guard let memory = BoundGBAMemorySnapshot.capture(readMemory:{ core.deltaCore.emulatorBridge.readMemory?(at:$0,size:$1) }) else {
                failure = "Native memory unavailable on callback"; apply(0,core); return
            }
            let view = StoryBattleView(memory:memory,callback:frame,time:DispatchTime.now().uptimeNanoseconds,request:MultiRedAdapter.readSetupRequest())
            latest = view
            let responses = (0..<4).map { view.response($0).base64EncodedString() }.joined(separator:",")
            let key = "\(stage):\(view.menu ?? "-"):\(view.controllers):\(responses):\(view.partyReady):\(view.partyContextReady):\(view.selectedMon):\(view.contextCursor):\(view.outcome):\(view.partyIndex(0)):\(view.map):\(view.story)"
            if key != signature || frame % 60 == 0 {
                if trace.count >= 20000 { failure = "Native trace capacity exceeded" }
                else { var row=view.facts;row["stage"]=stage;trace.append(row);signature=key }
            }
            guard failure == nil else { apply(0,core); return }
            if var pending = tap {
                let priorPhase=pending.phase,mask=pending.observe(held:view.held)
                tapRows.append(["callback":frame,"time":view.time,"phase":priorPhase,"held":view.held,"newKeys":view.half(0x0300311E)])
                apply(mask,core)
                if pending.complete || pending.failed {
                    receipts.append(["id":tapID,"key":pending.key,"stage":stage,"acknowledged":pending.acknowledged,"released":pending.complete,"polls":tapRows])
                    finishedTap=tapID;tap=nil
                    if pending.failed { failure="Native key poll did not acknowledge/release within12 callback polls" }
                } else { tap=pending }
            } else { apply(0,core) }
        }
    }
    private func apply(_ mask:Int,_ core:EmulatorCore) {
        for bit in [1,2,16,32,64,128] where mask & bit != lastMask & bit {
            if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit,value:1,playerIndex:0) }
            else { core.deltaCore.emulatorBridge.deactivateInput(bit,playerIndex:0) }
        }
        lastMask=mask
    }
}

@MainActor
final class NativeStoryBattleAcceptanceTests: XCTestCase {
    private static let romSHA = "02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79"
    private struct FilePin: Codable { let bytes: Int; let sha256: String }
    private struct Request: Codable {
        let version: Int, attempt: UUID, role: String, run: UUID
        let romSHA256: String, ownerOT: UInt32, sourcePointID: String, source: [String:FilePin]
        let startingMap: [Int], triggerKeys: [Int], expectedOutcome: String
    }
    private func require(_ value: Bool, _ reason: String) throws { if !value { throw StoryBattleFailure(reason) } }
    private func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private func view(_ core: EmulatorCore) throws -> StoryBattleView {
        guard let memory=BoundGBAMemorySnapshot.capture(readMemory:{ core.deltaCore.emulatorBridge.readMemory?(at:$0,size:$1) }) else {
            throw StoryBattleFailure("Paused native RAM unavailable")
        }
        return StoryBattleView(memory:memory,callback:0,time:DispatchTime.now().uptimeNanoseconds,request:MultiRedAdapter.readSetupRequest())
    }
    func testNativeInputReceiptRequiresObservedPressAndRelease() {
        var tap=StoryBattleTap(key:1)
        XCTAssertEqual(tap.observe(held:0),1)
        XCTAssertFalse(tap.acknowledged)
        XCTAssertEqual(tap.observe(held:0),1)
        XCTAssertEqual(tap.observe(held:1),0)
        XCTAssertTrue(tap.acknowledged);XCTAssertFalse(tap.complete)
        XCTAssertEqual(tap.observe(held:1),0)
        XCTAssertEqual(tap.observe(held:0),0)
        XCTAssertTrue(tap.complete);XCTAssertFalse(tap.failed)
        XCTAssertEqual(tap.observe(held:0),0,"A completed receipt cannot create another edge")
    }
    func testNativeInputReceiptFailsWithoutInventingAcknowledgement() {
        var tap=StoryBattleTap(key:2)
        _=tap.observe(held:0)
        for _ in 0..<12 { _=tap.observe(held:0) }
        XCTAssertTrue(tap.failed);XCTAssertFalse(tap.acknowledged);XCTAssertFalse(tap.complete)
    }
    func testNativePartyOrderMapsScreenSlotsWithoutAssumingActiveBattlerTwo() {
        XCTAssertEqual(StoryBattlePartyOrder.decode([0x20,0x13,0x45]),[2,0,1,3,4,5])
        XCTAssertEqual(StoryBattlePartyOrder.decode([0x20,0x13,0x45])?[2],1,
                       "Screen slot2 names battle party1 after native menu reordering")
        XCTAssertNil(StoryBattlePartyOrder.decode([0x00,0x23,0x45]))
        XCTAssertNil(StoryBattlePartyOrder.decode([0x61,0x23,0x45]))
        XCTAssertNil(StoryBattlePartyOrder.decode([0x01,0x23]))
    }

    func testPreBrendanNativeMenusSwitchAndNaturalContinuation() async throws {
        let env=ProcessInfo.processInfo.environment
        guard env["BOUND_NATIVE_STORY_BATTLE"] == "1" else { throw XCTSkip("Requires reviewed exact02f multi-party pre-Brendan native fixture and exclusive simulator") }
        try require(["92586556-6715-4BA0-98FC-5C1FF776F0A9","14BD3EC6-B57B-49A1-98D1-457A9DC0C088"].contains(env["SIMULATOR_UDID"] ?? ""),"Only task-owned simulators are admitted")
        let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Phase8NativeStoryBattleQA")
        let requestBytes=try Data(contentsOf:root.appendingPathComponent("request.json"))
        try require(env["BOUND_NATIVE_STORY_REQUEST_SHA256"] == hash(requestBytes),"Externally reviewed request hash missing or changed")
        let request=try JSONDecoder().decode(Request.self,from:requestBytes)
        try require(request.version==1 && request.romSHA256==Self.romSHA && request.sourcePointID=="02-pre-brendan", "Wrong fixture contract")
        try require(["controller","buddy"].contains(request.role) && ["either","win","loss"].contains(request.expectedOutcome),"Invalid role/outcome policy")
        try require(request.ownerOT == (request.role == "controller" ? 0x12345678:0x87654321),"Wrong fixture owner")
        try require(request.startingMap.count==4 && request.startingMap.prefix(2)==[1,0],"Requires actual pre-Brendan Forest field")
        try require((1...30).contains(request.triggerKeys.count) && request.triggerKeys.allSatisfy { [1,16,32,64,128].contains($0) },"Trigger must be a bounded reviewed ordinary input sequence")
        let names:Set<String>=["checkpoint.state","game.sav","party.bin","native-route.json","native-audit.json"]
        try require(Set(request.source.keys)==names,"Exact native fixture files required")
        let input=root.appendingPathComponent("inputs").appendingPathComponent(request.attempt.uuidString)
        var originals:[String:Data]=[:]
        for name in names {
            let data=try Data(contentsOf:input.appendingPathComponent(name)),pin=request.source[name]!
            try require(data.count==pin.bytes && hash(data)==pin.sha256,"Changed source file: "+name);originals[name]=data
        }
        let report=try JSONSerialization.jsonObject(with:originals["native-route.json"]!) as? [String:Any]
        let audit=try JSONSerialization.jsonObject(with:originals["native-audit.json"]!) as? [String:Any]
        try require(report?["status"] as? String == "passed-bounded-route" && report?["pointID"] as? String == request.sourcePointID
                    && report?["role"] as? String == request.role && UUID(uuidString:report?["run"] as? String ?? "")==request.run,
                    "Native route report does not identify this owner/pre-trigger fixture")
        try require(report?["romSHA256"] as? String == Self.romSHA
                    && report?["gameID"] as? String == "4b792d8f8b86e1a65b27965bb523fe0a48a20190"
                    && report?["coreIdentifier"] as? String == "com.rileytestut.GBADeltaCore"
                    && report?["coreStateVersion"] as? Int == 10 && report?["saveStateLayout"] as? Int == 6
                    && report?["coldRestorationVerified"] as? Bool == true,"Native report has a different profile or lacks cold-restore proof")
        try require(audit?["status"] as? String == "passed: supplemental copied-RAM native instruction audit"
                    && audit?["candidate_report_sha256"] as? String == hash(originals["native-route.json"]!),"Independent native audit missing/mismatched")
        let fileReport=report?["files"] as? [String:[String:Any]]
        for name in ["checkpoint.state","game.sav","party.bin"] {
            try require(fileReport?[name]?["sha256"] as? String == request.source[name]?.sha256,"Native report file mismatch: "+name)
        }
        let romURL=root.appendingPathComponent("current.gba"),rom=try Data(contentsOf:romURL,options:.mappedIfSafe)
        try require(hash(rom)==Self.romSHA,"Wrong exact cartridge")
        let profile=try BoundPlayerROMProfile(rom:rom)
        try require(profile.gameProfile==BoundGameProfiles.current && profile.gameProfile.coreStateVersion==10 && profile.gameProfile.saveStateLayout==6,"Wrong adapter/core layout")
        let output=root.appendingPathComponent("results").appendingPathComponent(request.attempt.uuidString)
        try require(!FileManager.default.fileExists(atPath:output.path),"Attempt output already exists")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func write(_ value:Any,_ name:String) throws {
            try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent(name),options:.atomic)
        }
        let batteryURL=output.appendingPathComponent("scratch.sav"),scratch=Data(repeating:0xFF,count:131072)
        try scratch.write(to:batteryURL)
        try require(BoundVBABattleBridge.setServerOnlyGameSave(true,for:batteryURL),"Battery fence unavailable")
        var core:EmulatorCore?,driver:NativeStoryBattleDriver?,stage="restore",passed=false
        let started=ProcessInfo.processInfo.systemUptime
        var timings:[[String:Any]]=[],checkpoints:[String:[String:String]]=[:]
        let previousFeature=UserDefaults.standard.object(forKey:BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer {
            if let core {
                if core.state == .running { _=core.pause() }
                core.updateHandler=nil
                for key in [1,2,16,32,64,128] { core.deltaCore.emulatorBridge.deactivateInput(key,playerIndex:0) }
                _=core.stop()
            }
            UserDefaults.standard.set(previousFeature,forKey:BoundMultiplayerFeatures.key)
            NotificationCenter.default.post(name:BoundMultiplayerFeatures.didChange,object:nil)
        }
        func makeCore() throws -> EmulatorCore {
            guard let value=EmulatorCore(game:StoryBattleGame(fileURL:romURL,gameSaveURL:batteryURL),options:[.metal:true]) else { throw StoryBattleFailure("VBA core unavailable") }
            try require(value.deltaCore.identifier=="com.rileytestut.GBADeltaCore","Unexpected core")
            value.rate=1;value.audioManager.isEnabled=false
            try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(value)
            return value
        }
        func capture(_ label:String) throws -> StoryBattleView {
            guard let core,core.state == .paused else { throw StoryBattleFailure("Capture requires paused native owner") }
            let result=try view(core)
            let files=["checkpoint.state":MultiRedAdapter.captureState(),"game.sav":BoundVBABattleBridge.captureServerBattery(),
                       "party.bin":result.party,"ewram.bin":Data(result.memory.workRAM),"iwram.bin":Data(result.memory.internalRAM)]
            let directory=output.appendingPathComponent(label)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
            var hashes:[String:String]=[:]
            for (name,data) in files { try require(!data.isEmpty,"Empty native capture");try data.write(to:directory.appendingPathComponent(name));hashes[name]=hash(data) }
            try JSONSerialization.data(withJSONObject:result.facts,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("observation.json"))
            checkpoints[label]=hashes;return result
        }
        do {
            core=try makeCore();let running=core!
            try require(BoundVBABattleBridge.restoreServerBattery(originals["game.sav"]!) && MultiRedAdapter.restoreState(originals["checkpoint.state"]!),"Exact native input restore rejected")
            try require(BoundVBABattleBridge.installROMMultiplayer(),"Current ROM UI contract unavailable")
            let initial=try view(running)
            try require(initial.party==originals["party.bin"]! && initial.map==request.startingMap && initial.story==[0,0,0] && !initial.battle,"Input is not the reviewed undefeated pre-trigger state")
            try require(initial.mons.count==initial.count && initial.mons.count>=2 && Set(initial.mons.map(\.identity)).count==initial.count
                        && initial.mons.allSatisfy { $0.identity.trainer==request.ownerOT && !$0.isEgg && ($0.hp ?? 0)>0 && (1...15).contains($0.level ?? 0) },"Requires distinct healthy legitimate owner mons below the native pre-Brock cap")
            let identities=Set(initial.mons.map(\.identity)),initialParty=initial.party
            guard let initialRewardA=initial.itemQuantity(0xB6),let initialRewardB=initial.itemQuantity(0x16A) else {
                throw StoryBattleFailure("Native reward inventory unavailable; do not initialize it from the host")
            }
            _=try capture("initial")
            let active=NativeStoryBattleDriver();driver=active;running.updateHandler={ active.receive($0) }
            try require(running.resume(),"Initial resume failed")
            func wait(_ label:String,seconds:Double=15,_ predicate:(StoryBattleView)->Bool) async throws -> StoryBattleView {
                let begin=ProcessInfo.processInfo.systemUptime
                while true {
                    try Task.checkCancellation()
                    let state=active.state()
                    if let failure=state.2 { throw StoryBattleFailure(failure) }
                    try require(running.state == .running,"Unexpected native stop/pause during "+label)
                    try require(ProcessInfo.processInfo.systemUptime-started<900,"Overall native battle deadline exceeded")
                    if let sample=state.0 {
                        try require(sample.callback<=54000,"Native callback budget exceeded")
                        if predicate(sample) { return sample }
                    }
                    try require(ProcessInfo.processInfo.systemUptime-begin<seconds,"Timed out: "+label)
                    try await Task.sleep(for:.milliseconds(5))
                }
            }
            func tap(_ key:Int,_ label:String) async throws -> StoryBattleView {
                stage=label;active.setStage(label)
                let id=try active.enqueue(key)
                return try await wait(label) { _ in active.state().1>=id && active.state().3 }
            }
            func field(_ label:String) async throws -> StoryBattleView {
                var previous:UInt32?,consecutive=0
                return try await wait(label,seconds:30) { sample in
                    if let frame=sample.request?.frame,frame != previous {
                        previous=frame;consecutive=sample.fieldReady ? consecutive+1:0
                    }
                    return consecutive>=12
                }
            }
            func pauseCapture(_ label:String) throws -> StoryBattleView {
                try require(active.state().3,"Capture attempted with a pending input edge")
                try require(running.pause(),"Normal native pause failed")
                let sample=try capture(label)
                try require(running.resume(),"Normal native resume failed")
                return sample
            }
            _=try await field("restored native idle")
            try require(active.state().0?.party==initialParty,"Unexpected party mutation before initiation")
            stage="trigger";active.setStage(stage)
            for key in request.triggerKeys {
                if active.state().0?.battle == true { break }
                _=try await tap(key,"trigger")
                _=try await wait("trigger input settles",seconds:3) { $0.battle || $0.held==0 }
            }
            var action=try await wait("native Brendan action menu",seconds:60) { $0.battle && $0.menu=="action" }
            try require(action.trainer==0x2C && action.battleType & 8 != 0 && action.byte(0x02023BCC)==2,"Wrong naturally initiated trainer/format")
            _=try pauseCapture("first-action")
            let originalSlot=action.partyIndex(action.battler!)
            func cursor(_ target:Int,move:Bool) async throws -> StoryBattleView {
                for _ in 0..<4 {
                    let sample=try await wait("menu cursor") { $0.menu==(move ? "move":"action") }
                    let current=sample.cursor(sample.battler!,move:move)
                    if current==target { return sample }
                    let key = current & 1 != target & 1 ? (target & 1 != 0 ? 16:32):(target & 2 != 0 ? 128:64)
                    _=try await tap(key,"navigate-"+(move ? "move":"action"))
                }
                throw StoryBattleFailure("Native menu cursor did not reach requested option")
            }
            func menuTransition(_ key:Int,from:String,to:String,label:String) async throws -> StoryBattleView {
                let before=try await wait(label+" source") { $0.menu==from }
                let partyBefore=before.party,enemyBefore=before.bytes(0x0202402C,600)
                _=try await tap(key,label)
                let arrived=try await wait(label+" destination") { $0.menu==to }
                let trace=active.evidence()["trace"] as? [[String:Any]] ?? []
                let first=trace.first { ($0["stage"] as? String)==label && ($0["menu"] as? String)==to && ($0["callback"] as? UInt64 ?? 0)>before.callback }
                guard let event=first,let frame=event["callback"] as? UInt64,let time=event["monotonicNanoseconds"] as? UInt64 else { throw StoryBattleFailure("Native menu arrival receipt missing") }
                let frames=frame-before.callback
                let receipts=active.evidence()["inputReceipts"] as? [[String:Any]] ?? []
                let delivered=receipts.last { ($0["stage"] as? String)==label }
                let polls=delivered?["polls"] as? [[String:Any]] ?? []
                guard let acknowledgement=polls.first(where:{ ($0["phase"] as? Int)==1 && (($0["held"] as? Int ?? 0) & key)==key }),
                      let acknowledgedAt=acknowledgement["callback"] as? UInt64 else { throw StoryBattleFailure("Native input acknowledgement missing") }
                timings.append(["label":label,"scheduledCallback":before.callback,"acknowledgedCallback":acknowledgedAt,
                                "arrivalCallback":frame,"localFrames":frames,"wallNanoseconds":time-before.time])
                try require(frames<=12,"Acknowledged local menu transition exceeded12frames: "+label)
                try require(arrived.party==partyBefore && arrived.bytes(0x0202402C,600)==enemyBefore,"Menu/cancel unexpectedly consumed a turn")
                if from=="move" && to=="action" {
                    try require(trace.contains { row in
                        (row["callback"] as? UInt64 ?? 0)>before.callback
                            && ((row["responses"] as? [String]) ?? []).contains { $0.hasPrefix("210affff") }
                    },"Native move cancellation response missing")
                }
                return arrived
            }
            action=try await cursor(0,move:false)
            _=try await menuTransition(1,from:"action",to:"move",label:"fight-to-move")
            let slot=action.partyIndex(action.battler!)
            let alternate=(0..<4).first { $0 != 0 && action.moves(slot)[$0]>0 && action.pp(slot)[$0]>0 }
            try require(alternate != nil,"Fixture needs a second legal move for navigation/cancel proof")
            _=try await cursor(alternate!,move:true)
            _=try await menuTransition(2,from:"move",to:"action",label:"move-back")
            _=try await menuTransition(1,from:"action",to:"move",label:"fight-again")
            _=try await menuTransition(2,from:"move",to:"action",label:"move-back-for-party")
            _=try await cursor(2,move:false)
            let beforeParty=active.state().0!
            _=try await tap(1,"party-open-cancel")
            _=try await wait("native party selector") { $0.partyReady && $0.partyAction != 1 }
            _=try await tap(2,"party-cancel")
            action=try await wait("action after party cancel") { $0.menu=="action" }
            try require(action.party==beforeParty.party && action.partyIndex(action.battler!)==originalSlot,"Party cancel changed battle owner or party")
            _=try await cursor(2,move:false);_=try await tap(1,"party-open-switch")
            var selector=try await wait("native party selector for switch") { $0.partyReady }
            func chooseMon(_ selector:StoryBattleView,_ label:String) async throws -> StoryBattleView {
                try require(selector.byte(0x02023BCC)==2,"Only the reviewed native single battle is admitted")
                guard let order=selector.partyOrder else { throw StoryBattleFailure("Native party order is not a six-slot permutation") }
                guard let wanted=selector.mons.indices.first(where:{ order[$0] != selector.partyIndex(0) && (selector.mons[$0].hp ?? 0)>0 && !selector.mons[$0].isEgg }) else {
                    throw StoryBattleFailure("No distinct healthy owner mon for native switch")
                }
                let targetIdentity=selector.mons[wanted].identity,targetBattleID=order[wanted]
                var selected=selector
                for _ in 0..<12 {
                    if selected.selectedMon==wanted { break }
                    // Native single-party layout: slot0 is left, slots1...5 right.
                    let key=selected.selectedMon==0 ? 16:(wanted==0 ? 32:(selected.selectedMon<wanted ? 128:64))
                    _=try await tap(key,label+"-cursor")
                    selected=try await wait("native selected slot") { $0.partyReady }
                }
                try require(selected.selectedMon==wanted,"Native party cursor failed to select eligible mon")
                _=try await tap(1,label+"-context")
                selected=try await wait("native send-out context") { $0.partyContextReady }
                guard let actionIndex=selected.contextActions.firstIndex(where:{ [10,11].contains($0) }) else { throw StoryBattleFailure("Native context does not allow send-out") }
                for _ in 0..<8 {
                    if selected.contextCursor==actionIndex { break }
                    _=try await tap(selected.contextCursor<actionIndex ? 128:64,label+"-context-cursor")
                    selected=try await wait("context cursor") { $0.partyContextReady }
                }
                try require(selected.contextCursor==actionIndex,"Native send-out context cursor mismatch")
                let startedAt=selected.callback
                _=try await tap(1,label+"-submit")
                let result=try await wait("actual native party switch",seconds:60) { sample in
                    guard !sample.partyScreen, sample.battle, sample.partyIndex(0)==targetBattleID else { return false }
                    return sample.mons.indices.contains(targetBattleID) && sample.mons[targetBattleID].identity==targetIdentity
                }
                let trace=active.evidence()["trace"] as? [[String:Any]] ?? []
                let expected=String(format:"22%02x",targetBattleID)
                try require(trace.contains { row in
                    (row["callback"] as? UInt64 ?? 0)>=startedAt && ((row["responses"] as? [String]) ?? []).contains { $0.hasPrefix(expected) }
                },"Native chosen-mon response missing; a cursor is not a switch")
                return result
            }
            action=try await chooseMon(selector,"switch")
            try require(action.partyIndex(0) != originalSlot,"Active party slot never changed")
            _=try pauseCapture("after-switch")
            var turns=0
            while true {
                let sample=try await wait("next turn, forced switch or terminal",seconds:60) { $0.menu=="action" || $0.partyReady || [1,2].contains($0.outcome) }
                if [1,2].contains(sample.outcome) { break }
                if sample.partyReady { selector=sample;_=try await chooseMon(selector,"forced-switch");continue }
                try require(turns<30,"Bounded natural-turn budget exhausted")
                _=try await cursor(0,move:false);_=try await tap(1,"turn-\(turns)-fight")
                let moves=try await wait("move selection") { $0.menu=="move" }
                let index=moves.partyIndex(moves.battler!)
                guard moves.mons.indices.contains(index),let move=(0..<4).first(where:{ moves.moves(index)[$0]>0 && moves.pp(index)[$0]>0 }) else { throw StoryBattleFailure("No legal PP-backed move; no forced outcome") }
                _=try await cursor(move,move:true)
                let submittedAt=active.state().0!.callback
                _=try await tap(1,"turn-\(turns)-submit")
                _=try await wait("move submitted",seconds:10) { $0.menu != "move" }
                let expected=String(format:"210a%02x",move)
                let trace=active.evidence()["trace"] as? [[String:Any]] ?? []
                try require(trace.contains { row in
                    (row["callback"] as? UInt64 ?? 0)>submittedAt
                        && ((row["responses"] as? [String]) ?? []).contains { $0.hasPrefix(expected) }
                },"Native move-selection response missing")
                turns+=1
            }
            stage="native-continuation";active.setStage(stage)
            var terminal=active.state().0!,outcome=terminal.outcome
            try require([1,2].contains(outcome),"No natural win/loss outcome")
            // Native messages and whiteout only. No menu cursor or script writes.
            for _ in 0..<80 {
                terminal=active.state().0!
                if terminal.fieldReady { break }
                _=try await tap(2,"continue-native-text")
                let until=active.state().0!.callback+12
                _=try await wait("native text interval",seconds:3) { $0.callback>=until || $0.fieldReady }
            }
            terminal=try await field("natural fully idle field")
            try require(request.expectedOutcome=="either" || (request.expectedOutcome=="win" ? outcome==1:outcome==2),"Natural outcome differs from requested policy; never relabel it")
            try require(terminal.story == (outcome==1 ? [1,1,1]:[0,0,0]),"Target/reward continuation does not match natural outcome")
            try require(terminal.itemQuantity(0xB6)==initialRewardA+(outcome==1 ? 1:0)
                        && terminal.itemQuantity(0x16A)==initialRewardB+(outcome==1 ? 1:0),"Native reward inventory does not match the natural script outcome")
            try require(Set(terminal.mons.map(\.identity))==identities,"Native party identities changed unexpectedly")
            // A normal pause can land inside the guest's odd/write/even UI
            // publication. Resume normally until a committed safe cut exists;
            // no counters, callbacks or RAM are edited to manufacture it.
            var pauseRows:[[String:Any]]=[]
            for attempt in 0..<12 {
                try require(active.state().3 && running.pause(),"Final neutral pause failed")
                let paused=try view(running)
                pauseRows.append(["attempt":attempt,"fieldReady":paused.fieldReady,"observation":paused.facts])
                if paused.fieldReady { break }
                try require(running.resume(),"Final publication retry resume failed")
                _=try await field("committed final field retry")
            }
            try write(pauseRows,"final-pause-observations.json")
            try require(running.state == .paused,"Final committed native cut deadline exhausted")
            let final=try capture(outcome==1 ? "natural-win":"natural-loss")
            try require(final.fieldReady,"Paused final field boundary is not coherent")
            let finalState=MultiRedAdapter.captureState(),finalBattery=BoundVBABattleBridge.captureServerBattery(),finalParty=final.party
            running.updateHandler=nil;_=running.stop();core=nil
            let reopened=try makeCore();core=reopened
            try require(BoundVBABattleBridge.restoreServerBattery(finalBattery) && MultiRedAdapter.restoreState(finalState),"Fresh-core final restore failed")
            try require(BoundVBABattleBridge.installROMMultiplayer(),"Fresh-core UI ownership unavailable")
            let restored=try view(reopened)
            try require(restored.party==finalParty && restored.map==final.map && restored.story==final.story && !restored.battle,"Cold restore changed native continuation")
            for (name,bytes) in originals { try require(try Data(contentsOf:input.appendingPathComponent(name))==bytes,"Original input changed") }
            try require(try Data(contentsOf:batteryURL)==scratch,"Native test touched ordinary battery path")
            try write(active.evidence(),"native-trace.json")
            try write(["status":"passed","romSHA256":Self.romSHA,"requestSHA256":hash(requestBytes),"role":request.role,
                "nativeOutcome":outcome,"naturalOutcome":outcome==1 ? "win":"loss","turnsSubmitted":turns,
                "menuTimings":timings,"final":final.facts,"coldRestored":true,"successfulNativeSwitch":true,
                "rewardQuantitiesBefore":[initialRewardA,initialRewardB],
                "rewardQuantitiesAfter":[terminal.itemQuantity(0xB6)!,terminal.itemQuantity(0x16A)!],
                "checkpoints":checkpoints,"wallSeconds":ProcessInfo.processInfo.systemUptime-started,
                "scope":"Current actual VBA story battle, ordinary controller input, local fixture host; no paired/network/Soul-loss claim"],"result.json")
            passed=true
        } catch {
            if let core,core.state == .running { _=core.pause() }
            if let core,core.state == .paused { _=try? capture("failure") }
            try? write(driver?.evidence() ?? [:],"native-trace.json")
            try? write(["status":"failed","stage":stage,"error":String(describing:error),"errorType":String(reflecting:type(of:error)),"checkpoints":checkpoints,"menuTimings":timings,"wallSeconds":ProcessInfo.processInfo.systemUptime-started],"result.json")
            throw error
        }
        try require(passed,"Native acceptance did not complete")
    }
}

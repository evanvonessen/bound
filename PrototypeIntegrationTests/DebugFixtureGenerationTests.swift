import XCTest
import UIKit
import CryptoKit
@preconcurrency import DeltaCore
@testable import Delta

private struct DebugFixtureGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

/// Read-only views of candidate 02f97's actual menu/task storage. The runner uses
/// controller edges only; none of these accessors call a guest function or write
/// a cursor. Native entry points were inspected before adding this narrow path.
private struct DebugFixtureNativeMenus {
    let memory: BoundGBAMemorySnapshot
    func byte(_ address: Int) -> Int { Int(memory.bytes(at: address, count: 1)?.first ?? 0) }
    func half(_ address: Int) -> Int { byte(address) | byte(address + 1) << 8 }
    func word(_ address: Int) -> Int { half(address) | half(address + 2) << 16 }
    func task(_ function: Int) -> Int? {
        (0..<16).first { byte(0x03005090 + $0 * 40 + 4) != 0 && word(0x03005090 + $0 * 40) == function }
    }
    func data(_ task: Int, _ field: Int) -> Int { half(0x03005098 + task * 40 + field * 2) }
    var tasks: [Int] { (0..<16).filter { byte(0x03005094 + $0 * 40) != 0 }.map { word(0x03005090 + $0 * 40) } }
    var fadeClear: Bool { byte(0x02037ABF) & 0x80 == 0 }
    var startReady: Bool {
        guard let id = task(0x0806F1F1) else { return false }
        return data(id, 0) == 1 && word(0x020370F0) == 0x0806F281 && fadeClear
    }
    var startAction: Int {
        let cursor = byte(0x020370F4)
        return cursor < 10 ? byte(0x020370F6 + cursor) : -1
    }
    var bagReady: Bool {
        // The list task exists briefly during CB2_InitBagMenu (08107F11),
        // before it starts the fade. Only the active Bag callback runs input.
        word(0x030030F4) == 0x08107EE1 && task(0x08108F0D) != nil
            && task(0x08108CFD) == nil && fadeClear
    }
    var bagPocket: Int { byte(0x0203AD02) }
    var bagCursor: Int {
        guard let id = task(0x08108F0D) else { return -1 }
        let list = data(id, 0)
        guard list < 16 else { return -1 }
        return data(list, 12) + data(list, 13)
    }
    func item(_ position: Int, pocket: Int = 0) -> (id: Int, quantity: Int)? {
        guard (0..<5).contains(pocket), position >= 0 else { return nil }
        let base = word(0x0203988C + pocket * 8), count = half(0x02039890 + pocket * 8)
        guard count <= 1024, position < count, base >= 0x02000000, base + count * 4 <= 0x02040000 else { return nil }
        // Native GetBagItemQuantity at08099DA0 is ldrh; 02f97 does not
        // encrypt quantities. This is a read, never a bag initialization.
        return (half(base + position * 4), half(base + position * 4 + 2))
    }
    var candyQuantity: Int {
        let count = half(0x02039890)
        guard count <= 1024 else { return -1 }
        return (0..<count).reduce(0) { sum, index in
            guard let value = item(index), value.id == 68 else { return sum }
            return sum + value.quantity
        }
    }
    func itemQuantity(_ id: Int, pocket: Int) -> Int {
        guard (0..<5).contains(pocket) else { return -1 }
        let count = half(0x02039890 + pocket * 8)
        guard count > 0, count <= 1024 else { return -1 }
        var total = 0
        for index in 0..<count {
            guard let value = item(index, pocket: pocket) else { return -1 }
            if value.id == id { total += value.quantity }
        }
        return total
    }
    var selectedItem: Int { half(0x0203AD30) }
    var contextReady: Bool { task(0x08109BE5) != nil && selectedItem == 68 && fadeClear }
    var contextCursor: Int { byte(0x0203ADE6) }
    var contextAction: Int {
        let pointer = word(0x0203AD24)
        guard (0x08000000..<0x0A000000).contains(pointer), contextCursor < 8 else { return -1 }
        return pointer + contextCursor // Resolved against the immutable cartridge by the test.
    }
    var partyReady: Bool {
        task(0x0811FB29) != nil && task(0x08120329) == nil && fadeClear
            && selectedItem == 68 && byte(0x0203B0AB) == 3
    }
    var selectedMon: Int { byte(0x0203B0A9) }
    var level: Int { byte(0x02024284 + 84) }
    var postCandyReady: Bool { task(0x090B39DD) != nil && task(0x08120329) == nil && fadeClear }
    var learnedMoveReady: Bool {
        task(0x08125D2D) != nil && task(0x08120329) == nil && task(0x08071CBD) == nil && fadeClear
    }
    var learnedMove: Int { half(0x0203B0AE) }
    func flag(_ id: Int) -> Bool {
        let save = word(0x03005008)
        guard (0x02000000...0x0203C000).contains(save), (1..<0x1900).contains(id) else { return false }
        let address = id < 0x900 ? save + 0xEE0 + id / 8 : 0x0203B174 + (id - 0x900) / 8
        return byte(address) & (1 << (id & 7)) != 0
    }
    func variable(_ id: Int) -> Int {
        let save = word(0x03005008)
        guard (0x02000000...0x0203C000).contains(save), (0x4000..<0x4100).contains(id) else { return -1 }
        return half(save + 0x1000 + (id - 0x4000) * 2)
    }
    var fieldReady: Bool {
        word(0x030030F0) == 0x08056535 && word(0x030030F4) == 0x080565B5
            && byte(0x03000F9C) == 0 && byte(0x03000EA8) == 2
            && word(0x02000808) & 1 == 0 && word(0x02000850) & 0x67 == 0x61
    }
    var nativeMap: (group: Int, number: Int) {
        let save = word(0x03005008)
        guard (0x02000000...0x0203C000).contains(save) else { return (-1, -1) }
        return (byte(save + 4), byte(save + 5))
    }
    func fieldBlock(x: Int, y: Int) -> Int? {
        // Native MapGridGetCollisionAt08058DC4 reads VMap03005040.
        let width = word(0x03005040), height = word(0x03005044), base = word(0x03005048)
        let gx = x + 7, gy = y + 7
        guard (1...1024).contains(width), (1...1024).contains(height),
              (0..<width).contains(gx), (0..<height).contains(gy),
              base >= 0x02000000, base + width * height * 2 <= 0x02040000 else { return nil }
        return half(base + (gy * width + gx) * 2)
    }
    var musicChainIntact: Bool {
        let nodes = [0x03006FB0, 0x03006F70, 0x030073D0, 0x03007380, 0x03007340, 0x03007300]
        return nodes.enumerated().allSatisfy { index, address in
            [0x68736D53, 0x68736D54].contains(word(address + 0x34))
                && word(address + 0x38) == (index + 1 < nodes.count ? 0x081DCA21 : 0)
                && word(address + 0x3C) == (index + 1 < nodes.count ? nodes[index + 1] : 0)
        }
    }
    var nativeABWait: Bool { byte(0x03000EB1) == 2 && word(0x03000EB4) == 0x090C0EE9 }
    var martDoorTransition: Bool {
        guard nativeMap == (3, 1), byte(0x03000F9C) == 1 else { return false }
        // Native0807E80D ->09096660 opens the door and walks the avatar
        // inside before replacing its task function with0807E719. Both
        // stages are ordinary cartridge code; the later fade is not the
        // first observable transition after the Up input.
        if let id = task(0x0807E80D), (0...5).contains(data(id, 0)) { return true }
        return task(0x0807E719) != nil
    }
    var parcelDialogueReady: Bool {
        nativeMap == (5, 3) && word(0x030030F4) == 0x080565B5 && byte(0x03000F9C) == 1
            && nativeABWait && word(0x03000EB8) == 0x081A4E5B && word(0x03000EBC) == 0x0816A21A
    }
    var facts: [String: Any] {
        ["tasks": tasks.map { String(format: "%08X", $0) }, "callback2": String(format: "%08X", word(0x030030F4)),
         "fadeClear": fadeClear, "startAction": startAction, "bagPocket": bagPocket, "bagCursor": bagCursor,
         "selectedItem": selectedItem, "contextCursor": contextCursor, "selectedMon": selectedMon,
         "level": level, "candyQuantity": candyQuantity, "learnedMove": learnedMove,
         "heldKeys": half(0x0300311C), "newKeys": half(0x0300311E)]
    }
}

/// Fixture generation owns one VBA instance and changes guest state only through
/// the admitted setup ABI, ordinary controller inputs, and the fixed native
/// script recipes. No arbitrary warp, party, experience, or outcome writes.
private final class DebugFixtureFrames: @unchecked Sendable {
    let setup: NativePlayerSceneSetup
    private let lock = NSLock()
    private var frames = 0, safeFrames = 0, mask = 0
    private var steps: [(mask: Int, frames: Int)] = []
    private var transitions: [[String: Any]] = []
    private var previousTransition = ""
    private var lastSafeNativeFrame: UInt32?
    private var unavailableSnapshots = 0
    private var advancingRecipe = false
    private var recipeResult: [String: Any] = [:]
    private struct NativeTap {
        let key: Int
        var phase = 0, pollsInPhase = 0
        var polls: [[String: Any]] = []
    }
    private var nativeTap: NativeTap?
    private struct NativeWalk {
        let key: Int, group: Int, number: Int, objectID: Int, save: Int
        let startX: Int, startY: Int, x: Int, y: Int
        let palletConnection: Bool
        var phase = 0, pollsInPhase = 0, acknowledged = false
        var polls: [[String: Any]] = []
    }
    private var nativeWalk: NativeWalk?
    private var inputReceipts: [[String: Any]] = []
    private var inputFailure: String?
    init(setup: NativePlayerSceneSetup) { self.setup = setup }
    var progress: (frames: Int, safe: Int, idle: Bool, unavailable: Int) {
        lock.lock(); defer { lock.unlock() }
        return (frames, safeFrames, steps.isEmpty && mask == 0 && nativeTap == nil && nativeWalk == nil, unavailableSnapshots)
    }
    var setupTrace: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }; return transitions
    }
    var recipeStatus: [String: Any] {
        lock.lock(); defer { lock.unlock() }; return recipeResult
    }
    var nativeInputResult: (receipts: [[String: Any]], failure: String?) {
        lock.lock(); defer { lock.unlock() }; return (inputReceipts, inputFailure)
    }
    /// Called only while this driver's core is paused. Guest work is performed
    /// by the fixed bridge script, then observed at completed-frame boundaries.
    func beginRecipe(_ operation: UInt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !advancingRecipe, steps.isEmpty, mask == 0, nativeTap == nil, nativeWalk == nil,
              BoundVBABattleBridge.qaBeginDebugFixtureOperation(operation) else { return false }
        recipeResult = ["active": true, "operation": operation]
        advancingRecipe = true
        return true
    }
    func enqueue(_ inputs: [(Int, Int)]) {
        lock.lock(); defer { lock.unlock() }
        precondition(steps.isEmpty && mask == 0 && nativeTap == nil && nativeWalk == nil)
        precondition(inputs.allSatisfy { $0.0 & ~0xFF == 0 && (1...3600).contains($0.1) })
        steps = inputs.map { (mask: $0.0, frames: $0.1) }
    }
    /// A completed VBA frame need not contain the guest's next input poll.
    /// Keep this ordinary controller edge until gMain records it, then require
    /// a native release before another tap. Menu acceptance remains a separate
    /// task/callback predicate; no cursor, key storage, or gameplay RAM is written.
    func enqueueNativeTap(_ key: Int) {
        lock.lock(); defer { lock.unlock() }
        precondition(!advancingRecipe && steps.isEmpty && mask == 0 && nativeTap == nil && nativeWalk == nil)
        precondition(key > 0 && key & ~0xFF == 0 && key & (key - 1) == 0)
        inputFailure = nil
        nativeTap = NativeTap(key: key)
    }
    /// One reviewed adjacent tile, using ordinary input until the native
    /// destination commits, then release before the movement finishes. Turning
    /// is allowed; blocked input, scripts, encounters and map changes stop.
    func enqueueNativeWalk(from start: BoundPlayerState, x: Int, y: Int, objectID: Int, save: Int,
                           palletConnection: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        precondition(!advancingRecipe && steps.isEmpty && mask == 0 && nativeTap == nil && nativeWalk == nil)
        let dx = x - start.tile.x, dy = y - start.tile.y
        precondition(abs(dx) + abs(dy) == 1 && objectID < 16)
        precondition(!palletConnection || (start.mapGroup == 3 && start.mapNumber == 19
            && start.tile == .init(x: 12, y: 39) && x == 12 && y == 40))
        let key = dx == 1 ? 16 : dx == -1 ? 32 : dy == -1 ? 64 : 128
        inputFailure = nil
        nativeWalk = NativeWalk(key: key, group: start.mapGroup, number: start.mapNumber,
            objectID: objectID, save: save, startX: start.tile.x, startY: start.tile.y, x: x, y: y,
            palletConnection: palletConnection)
    }
    func receive(_ core: EmulatorCore) {
        setup.receive(core)
        let request = setup.request
        lock.lock(); defer { lock.unlock() }
        frames += 1
        if advancingRecipe {
            recipeResult = BoundVBABattleBridge.qaAdvanceDebugFixtureOperation()
            if recipeResult["active"] as? Bool == false || recipeResult["conflict"] as? Bool == true {
                advancingRecipe = false
            }
        }
        if let request {
            // A VBlank can interrupt the guest's seqlock writer. Missing a
            // coherent snapshot is not an observed unsafe state. Count only
            // distinct committed native frames and recheck after pausing.
            if request.permitsFieldInterruption && request.settingsApplied {
                if lastSafeNativeFrame != request.frame { safeFrames += 1; lastSafeNativeFrame = request.frame }
            } else {
                safeFrames = 0; lastSafeNativeFrame = nil
            }
            let signature = "\(request.flags):\(request.command.rawValue):\(request.debugSetup):\(request.setupError)"
            if signature != previousTransition, transitions.count < 1024 {
                transitions.append(["frame": frames, "nativeFrame": request.frame,
                    "flags": request.flags, "command": request.command.rawValue,
                    "debugSetup": request.debugSetup, "setupError": request.setupError])
                previousTransition = signature
            }
        } else {
            unavailableSnapshots += 1
        }
        var next = steps.first?.mask ?? 0
        if var tap = nativeTap {
            // Delta's readMemory uses achievement address space: IWRAM starts
            // at zero, so 0x311C is native gMain.heldKeys at 0x0300311C.
            let keys = core.deltaCore.emulatorBridge.readMemory?(at: 0x311C, size: 4)
            let held = keys?.count == 4 ? Int(keys![0]) | Int(keys![1]) << 8 : -1
            let newKeys = keys?.count == 4 ? Int(keys![2]) | Int(keys![3]) << 8 : -1
            tap.pollsInPhase += 1
            tap.polls.append(["frame": frames, "phase": tap.phase, "heldKeys": held, "newKeys": newKeys])
            var complete = false
            switch tap.phase {
            case 0: // Observe release before generating a new edge.
                if held == 0 { tap.phase = 1; tap.pollsInPhase = 0; next = tap.key }
            case 1:
                next = tap.key
                if held >= 0 && held & tap.key == tap.key {
                    tap.phase = 2; tap.pollsInPhase = 0; next = 0
                }
            default:
                if held == 0 { complete = true }
            }
            let timedOut = !complete && tap.pollsInPhase >= 12
            if complete || timedOut {
                next = 0
                if timedOut { inputFailure = "Native input poll did not acknowledge phase \(tap.phase) for key \(tap.key)" }
                inputReceipts.append(["key": tap.key, "sampledAndReleased": complete, "polls": tap.polls])
                nativeTap = nil
            } else {
                nativeTap = tap
            }
        }
        if var walk = nativeWalk {
            func read(_ address: Int, _ size: Int) -> [UInt8]? {
                let offset = address >= 0x03000000 ? address - 0x03000000 : address - 0x02000000 + 0x8000
                guard let data = core.deltaCore.emulatorBridge.readMemory?(at: offset, size: size), data.count == size else { return nil }
                return Array(data)
            }
            func half(_ bytes: [UInt8], _ offset: Int = 0) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
            func word(_ bytes: [UInt8], _ offset: Int = 0) -> Int { half(bytes, offset) | half(bytes, offset + 2) << 16 }
            var failure: String?, complete = false
            next = 0; walk.pollsInPhase += 1
            if let keys = read(0x0300311C, 4), let callbacks = read(0x030030F0, 8),
               let battle = read(0x03003529, 1), let script = read(0x03000F9C, 1),
               let savePointer = read(0x03005008, 4), let location = read(walk.save, 6),
               let avatar = read(0x02037078, 8), let object = read(0x02036E38 + walk.objectID * 36, 36) {
                let held = half(keys), x = half(object, 0x10) - 7, y = half(object, 0x12) - 7
                let px = half(object, 0x14) - 7, py = half(object, 0x16) - 7
                let destinationMap = walk.palletConnection && location[4] == 3 && location[5] == 0
                let finalY = destinationMap ? 0 : walk.y
                let atStart = !destinationMap && x == walk.startX && y == walk.startY
                let atTarget = x == walk.x && y == finalY
                let previousValid = destinationMap ? (px == 12 && (-1...0).contains(py))
                    : ((px == walk.startX && py == walk.startY) || (px == walk.x && py == walk.y))
                let settled = x == px && y == py && avatar[2] == 0 && avatar[3] == 0
                walk.polls.append(["frame": frames, "phase": walk.phase, "heldKeys": held,
                    "x": x, "y": y, "previousX": px, "previousY": py,
                    "runningState": Int(avatar[2]), "tileTransitionState": Int(avatar[3]),
                    "mapGroup": Int(location[4]), "mapNumber": Int(location[5])])
                if battle[0] & 2 != 0 { failure = "Native encounter interrupted the reviewed walk" }
                else if script[0] != 0 { failure = "Native script interrupted the reviewed walk" }
                else if word(callbacks) != 0x08056535 || word(callbacks, 4) != 0x080565B5 {
                    failure = "Native field callback changed during the reviewed walk"
                } else if word(savePointer) != walk.save || (!destinationMap
                            && (Int(location[4]) != walk.group || Int(location[5]) != walk.number)) {
                    failure = "Connected-map or save-location transition interrupted the reviewed walk"
                } else if Int(avatar[5]) != walk.objectID || word(object) & 0x12001 != 0x10001
                            || object[8] != 255 || (!atStart && !atTarget) || !previousValid {
                    failure = "Native object left the reviewed adjacent step"
                } else {
                    switch walk.phase {
                    case 0:
                        if held == 0 && settled && atStart { walk.phase = 1; walk.pollsInPhase = 0; next = walk.key }
                    case 1:
                        next = walk.key
                        if held & walk.key != 0 { walk.acknowledged = true }
                        if atTarget {
                            if !walk.acknowledged { failure = "Native movement lacked an acknowledged controller input" }
                            else { walk.phase = 2; walk.pollsInPhase = 0; next = 0 }
                        }
                    default:
                        if atTarget && settled && held == 0 && half(location) == walk.x && half(location, 2) == finalY
                            && (!walk.palletConnection || destinationMap) { complete = true }
                    }
                    if !complete && walk.pollsInPhase >= (walk.phase == 0 ? 12 : 64) {
                        failure = "Native step did not complete phase \(walk.phase); no retry or extra input"
                    }
                }
            } else { failure = "Native step memory was unavailable" }
            if complete || failure != nil {
                next = 0; inputFailure = failure
                inputReceipts.append(["kind": walk.palletConnection ? "native-route1-pallet-connection" : "native-adjacent-step", "key": walk.key,
                    "start": [walk.startX, walk.startY], "target": [walk.x, walk.y],
                    "completed": complete, "failure": failure ?? "", "polls": walk.polls])
                nativeWalk = nil
            } else { nativeWalk = walk }
        }
        for bit in [1, 2, 4, 8, 16, 32, 64, 128] where next & bit != mask & bit {
            if next & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
            else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
        }
        mask = next
        if !steps.isEmpty { steps[0].frames -= 1; if steps[0].frames == 0 { steps.removeFirst() } }
    }
}

@MainActor
final class DebugFixtureGenerationTests: XCTestCase {
    private static let simulator = "14BD3EC6-B57B-49A1-98D1-457A9DC0C088"
    private struct Request: Decodable {
        let version: Int
        let pointID: String
        let role: String
        let run: UUID
        let attempt: UUID
        let source: ResumeSource?
    }
    private struct ResumeSource: Decodable {
        struct File: Decodable { let sha256: String; let bytes: Int }
        let files: [String: File]
    }
    private struct Route: Decodable {
        struct Step: Decodable {
            struct Input: Decodable { let mask: Int; let frames: Int }
            struct WalkTile: Decodable { let x: Int, y: Int, block: Int, behavior: Int }
            let id: String
            let frames: Int
            let inputs: [Input]
            let walk: [WalkTile]?
            let connection: Bool?
            let mapGroup: Int, mapNumber: Int, x: Int, y: Int
        }
        let version: Int, stage: String, romSHA256: String
        let steps: [Step]
        let nativeOperations: [UInt]
        let pending: [String]
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func wait(_ label: String, seconds: Double = 30, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else {
            throw NSError(domain: "DebugFixtureGeneration", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: label])
        }
    }
    private func memory(_ core: EmulatorCore) throws -> BoundGBAMemorySnapshot {
        XCTAssertEqual(core.state, .paused)
        return try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }))
    }
    private func pauseAtReadyField(_ core: EmulatorCore, driver: DebugFixtureFrames,
                                   minimum: Int, label: String, seconds: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if driver.progress.safe >= minimum, core.pause() {
                if let request = BoundROMRequest.decode(BoundVBABattleBridge.romMultiplayerSnapshot()),
                   request.settingsApplied, request.permitsFieldInterruption { return }
                // Pausing may land inside a guest publication. Resume native
                // execution until an actual committed idle boundary exists.
                guard core.resume() else { throw BoundDebugFailure.nativeVerification }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "DebugFixtureGeneration", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: label])
    }
    private func player(_ profile: BoundPlayerROMProfile, memory: BoundGBAMemorySnapshot) throws -> BoundPlayerState {
        try XCTUnwrap(profile.adapter.readPlayer(profile, memory: memory, frame: 0, includeScene: true).player)
    }
    private func party(_ memory: BoundGBAMemorySnapshot) throws -> (Data, [BoundSoulMon]) {
        let count = Int(try XCTUnwrap(memory.bytes(at: 0x02024029, count: 1)).first!)
        XCTAssertTrue((1...6).contains(count))
        let bytes = Data(try XCTUnwrap(memory.bytes(at: 0x02024284, count: count * 100)))
        let mons = BoundSoulMon.decode(bytes, stride: 100)
        XCTAssertEqual(mons.count, count)
        return (bytes, mons)
    }

    /// Fixed, opt-in prerequisites on the route to Brendan and Brock. Each
    /// stage starts from a matching audited native basis and stops before any
    /// trainer battle. Route2 adds ordinary Bag leveling and story traversal.
    func testRouteToBrendanSetup() async throws {
        let stage = ProcessInfo.processInfo.environment["BOUND_DEBUG_FIXTURE_GENERATE"] ?? ""
        guard ["route1-gifts", "route2-setup"].contains(stage) else {
            throw XCTSkip("Explicit task-owned native route attempt only")
        }
        try await runNativeRoute(stage: stage)
    }

    func testNativeBagToMartRegression() async throws {
        guard ProcessInfo.processInfo.environment["BOUND_DEBUG_FIXTURE_GENERATE"] == "bag-mart-regression" else {
            throw XCTSkip("Explicit fresh-candidate native Bag-to-Mart regression only")
        }
        try await runNativeRoute(stage: "bag-mart-regression")
    }

    /// Separate QA input for genuine peer-loss acceptance. The existing native
    /// gift team walks back to Pallet; this is not a certified Brock fixture.
    func testNativeTwoPartyPalletCandidate() async throws {
        guard ProcessInfo.processInfo.environment["BOUND_DEBUG_FIXTURE_GENERATE"] == "pallet-peer-loss" else {
            throw XCTSkip("Explicit task-owned two-party Pallet candidate only")
        }
        try await runNativeRoute(stage: "pallet-peer-loss")
    }

    private func runNativeRoute(stage: String) async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let bagMart = stage == "bag-mart-regression"
        let pallet = stage == "pallet-peer-loss"
        let route2 = stage == "route2-setup" || bagMart
        let continuation = route2 || pallet
        let sourceReportName = continuation ? "native-route.json" : "native-candidate.json"
        let sourcePoint = continuation ? "02-route1-gifts" : "01"
        XCTAssertEqual(env["SIMULATOR_UDID"], Self.simulator)
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DebugFixtureGenerationQA/02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79")
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
        XCTAssertEqual(request.version, 1)
        XCTAssertEqual(request.pointID, pallet ? "qa-two-party-pallet" : (bagMart ? "02-bag-mart-regression" : (route2 ? "02-route2-setup" : "02-route1-gifts")))
        XCTAssertTrue(["controller", "buddy"].contains(request.role))
        let source = try XCTUnwrap(request.source)
        XCTAssertEqual(Set(source.files.keys), Set(["checkpoint.state", "game.sav", "party.bin", sourceReportName, "native-audit.json"]))
        let input = root.appendingPathComponent("inputs").appendingPathComponent(request.attempt.uuidString)
        var originalInputs: [String: Data] = [:]
        for (name, expected) in source.files {
            let bytes = try Data(contentsOf: input.appendingPathComponent(name))
            XCTAssertEqual(hash(bytes), expected.sha256); XCTAssertEqual(bytes.count, expected.bytes)
            originalInputs[name] = bytes
        }
        let sourceReport = try XCTUnwrap(JSONSerialization.jsonObject(with: originalInputs[sourceReportName]!) as? [String: Any])
        let sourceAudit = try XCTUnwrap(JSONSerialization.jsonObject(with: originalInputs["native-audit.json"]!) as? [String: Any])
        XCTAssertEqual(sourceReport["status"] as? String, continuation ? "passed-bounded-route" : "candidate")
        XCTAssertEqual(sourceReport["pointID"] as? String, sourcePoint)
        XCTAssertEqual(sourceReport["role"] as? String, request.role)
        XCTAssertEqual(UUID(uuidString: sourceReport["run"] as? String ?? ""), request.run)
        XCTAssertEqual(sourceAudit["candidate_report_sha256"] as? String, hash(originalInputs[sourceReportName]!))
        XCTAssertEqual(sourceAudit["status"] as? String, "passed: supplemental copied-RAM native instruction audit")
        let sourceFiles = try XCTUnwrap(sourceReport["files"] as? [String: [String: Any]])
        for name in ["checkpoint.state", "game.sav", "party.bin"] {
            XCTAssertEqual(sourceFiles[name]?["sha256"] as? String, source.files[name]?.sha256)
        }
        let recipeBytes = try Data(contentsOf: root.appendingPathComponent(pallet ? "debug-fixture-pallet.json" : (route2 ? "debug-fixture-route2.json" : "debug-fixture-route1.json")))
        let recipeHash = hash(recipeBytes)
        XCTAssertEqual(recipeHash, pallet ? "e4711a3605746fc9ce8c0158614a7b460352c88230f939110d76148fc15a4a96" : (route2 ? "1ba52c9e2d50dba7f82ad91780f6c9f369dec0ec8ac49341945a6e5f0f4c23c9" : "4d6260979d43f2e650b720fa23c2a00202233b4349b3a7f50396a7043e9c23ea"))
        let route = try JSONDecoder().decode(Route.self, from: recipeBytes)
        XCTAssertEqual(route.version, route2 ? 4 : 1); XCTAssertEqual(route.stage, route2 ? "route2-setup" : stage)
        XCTAssertEqual(route.steps.count, pallet ? 3 : (route2 ? 28 : 9)); XCTAssertEqual(route.nativeOperations, pallet ? [] : (route2 ? [3] : [1, 2]))
        let rom = root.appendingPathComponent("RadicalRed.gba"), originalROM = try Data(contentsOf: rom)
        let profile = try BoundPlayerROMProfile(rom: originalROM)
        XCTAssertEqual(profile.gameProfile, BoundGameProfiles.current)
        XCTAssertEqual(hash(originalROM), "02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79")
        XCTAssertEqual(route.romSHA256, hash(originalROM))
        let output = root.appendingPathComponent("results").appendingPathComponent(request.attempt.uuidString)
            .appendingPathComponent(request.pointID).appendingPathComponent(request.role)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let batteryURL = output.appendingPathComponent("scratch.sav"), emptyBattery = Data(repeating: 0xFF, count: 131_072)
        try emptyBattery.write(to: batteryURL)
        XCTAssertTrue(BoundVBABattleBridge.setServerOnlyGameSave(true, for: batteryURL))
        let controller = request.role == "controller", seed: UInt32 = controller ? 0x12345678 : 0x87654321
        let partnerSeed: UInt32 = controller ? 0x87654321 : 0x12345678
        let starterSpecies = controller ? 4 : 7
        var options = BoundMultiplayerSetupOptions(); options.debug = true
        let identity = BoundNakamaRunService.PlayerProfile(name: controller ? "RED" : "BLUE", gender: 0)
        func makeDriver(_ core: EmulatorCore) -> DebugFixtureFrames {
            DebugFixtureFrames(setup: NativePlayerSceneSetup(core: core, debugPlayer: controller ? 1 : 2,
                run: request.run, localSeed: seed, partnerSeed: partnerSeed, settings: options.settings,
                playerProfile: identity, chooser: controller))
        }
        var activeCore: EmulatorCore?, activeDriver: DebugFixtureFrames?
        var lastStage = "cold-restore-" + sourcePoint, completed = false
        var receipts: [[String: Any]] = []
        func writeJSON(_ value: Any, _ url: URL) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
        func capture(_ core: EmulatorCore, to directory: URL) throws -> (BoundGBAMemorySnapshot, [String: Any]) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = try memory(core), (bytes, mons) = try party(snapshot)
            let payloads = ["checkpoint.state": BoundVBABattleBridge.captureServerState(),
                            "game.sav": BoundVBABattleBridge.captureServerBattery(), "party.bin": bytes,
                            "ewram.bin": Data(snapshot.workRAM), "iwram.bin": Data(snapshot.internalRAM)]
            var files: [String: [String: Any]] = [:]
            for (name, value) in payloads {
                try value.write(to: directory.appendingPathComponent(name))
                files[name] = ["sha256": hash(value), "bytes": value.count]
            }
            // Captures also preserve intermediate Bag/party states. The field
            // adapter correctly has no player while native menus own the GPU;
            // route endpoints still require player() at their own gates.
            let position = profile.adapter.readPlayer(profile, memory: snapshot, frame: 0, includeScene: true).player
            let trainer = try MultiRedAdapter.debugTrainer(core: core)
            var receipt: [String: Any] = ["stage": lastStage, "files": files,
                "fieldPlayerAvailable": position != nil,
                "trainerID": trainer.id, "trainerName": trainer.name,
                "party": mons.map { ["species": $0.species, "level": $0.level ?? 0, "area": $0.area,
                    "trainer": $0.identity.trainer, "personality": $0.identity.personality,
                    "hp": $0.hp ?? 0, "maxHP": $0.maxHP ?? 0] as [String: Any] },
                "frames": activeDriver?.progress.frames ?? 0,
                "recipe": activeDriver?.recipeStatus ?? [:], "nativeMenu": DebugFixtureNativeMenus(memory: snapshot).facts]
            if let position {
                receipt["mapGroup"] = position.mapGroup; receipt["mapNumber"] = position.mapNumber
                receipt["x"] = position.tile.x; receipt["y"] = position.tile.y
            }
            try writeJSON(receipt, directory.appendingPathComponent("observation.json"))
            return (snapshot, receipt)
        }
        defer {
            _ = activeCore?.pause(); activeCore?.updateHandler = nil
            if let activeCore { _ = try? capture(activeCore, to: output.appendingPathComponent("final-observation")) }
            try? writeJSON(["status": completed ? "passed-bounded-route" : "incomplete",
                "lastStage": lastStage, "receipts": receipts, "recipeSHA256": recipeHash,
                "sourceReportSHA256": hash(originalInputs[sourceReportName]!),
                "sourceAuditSHA256": hash(originalInputs["native-audit.json"]!),
                "transitions": activeDriver?.setupTrace ?? []], output.appendingPathComponent("attempt.json"))
            BoundVBABattleBridge.closeSharedWorld(); BoundVBABattleBridge.close(); BoundVBABattleBridge.closeSoulLink()
            _ = activeCore?.stop()
        }
        let core = try XCTUnwrap(EmulatorCore(game: DebugFixtureGame(fileURL: rom, gameSaveURL: batteryURL), options: [.metal: true]))
        activeCore = core
        try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(core)
        XCTAssertTrue(BoundVBABattleBridge.restoreServerBattery(originalInputs["game.sav"]!))
        XCTAssertTrue(BoundVBABattleBridge.restoreServerState(originalInputs["checkpoint.state"]!))
        XCTAssertEqual(try party(memory(core)).0, originalInputs["party.bin"]!)
        let driver = makeDriver(core); activeDriver = driver
        core.updateHandler = { driver.receive($0) }; core.rate = 8
        XCTAssertTrue(core.resume()); core.deltaCore.emulatorBridge.audioRenderer = nil
        try await pauseAtReadyField(core, driver: driver, minimum: 120, label: "Audited source cold restore is idle")
        let start = try player(profile, memory: memory(core))
        XCTAssertEqual(start.mapGroup, 3); XCTAssertEqual(start.mapNumber, continuation ? 19 : 0)
        XCTAssertEqual(start.tile, continuation ? .init(x: 13, y: 32) : .init(x: 16, y: 14))
        XCTAssertEqual(try MultiRedAdapter.debugTrainer(core: core).id, seed)
        XCTAssertEqual(try party(memory(core)).0, originalInputs["party.bin"]!)
        XCTAssertTrue(BoundVBABattleBridge.qaResetDebugFixtureOperations())
        receipts.append(try capture(core, to: output.appendingPathComponent("start")).1)
        var routePartyBytes = originalInputs["party.bin"]!
        func palletStory(_ snapshot: BoundGBAMemorySnapshot) throws -> [Data] {
            var bytes = try story(snapshot)
            // Exact native producers: walking4021 mod128, walking4022 mod5,
            // and Pallet entry081654A2 changing tutorial4070 from1 to2.
            // Every other flag/variable, including DEBUG settings, stays fixed.
            for offset in [0x162, 0x164, 0x200] { bytes[0][offset] = 0; bytes[0][offset + 1] = 0 }
            return bytes
        }
        func bagContents(_ snapshot: BoundGBAMemorySnapshot) throws -> [Data] {
            let view = DebugFixtureNativeMenus(memory: snapshot)
            return try (0..<5).map { pocket in
                let base = view.word(0x0203988C + pocket * 8), count = view.half(0x02039890 + pocket * 8)
                guard count <= 1024, base >= 0x02000000, base + count * 4 <= 0x02040000 else {
                    throw BoundDebugFailure.nativeVerification
                }
                return Data(try XCTUnwrap(snapshot.bytes(at: base, count: count * 4)))
            }
        }
        let palletStoryBasis = pallet ? try palletStory(memory(core)) : []
        let palletBagBasis = pallet ? try bagContents(memory(core)) : []
        func verifyPalletBasis(_ snapshot: BoundGBAMemorySnapshot) throws {
            guard pallet else { return }
            let view = DebugFixtureNativeMenus(memory: snapshot)
            let (_, mons) = try party(snapshot)
            guard try palletStory(snapshot) == palletStoryBasis, try bagContents(snapshot) == palletBagBasis,
                  view.candyQuantity == 21, view.itemQuantity(0x015D, pocket: 1) == 0,
                  view.itemQuantity(4, pocket: 2) == 0, mons.map(\.species) == [starterSpecies, 56],
                  (0..<128).contains(view.variable(0x4021)), (0..<5).contains(view.variable(0x4022)),
                  view.variable(0x4070) == (view.nativeMap == (3, 19) ? 1 : 2),
                  mons.map({ $0.level ?? 0 }) == [5, 8], mons.map(\.area) == [157, 101],
                  mons.allSatisfy({ $0.identity.trainer == seed && $0.hp == $0.maxHP && ($0.hp ?? 0) > 0 }) else {
                throw NSError(domain: "DebugFixtureGeneration", code: 33,
                    userInfo: [NSLocalizedDescriptionKey: "Two-party Pallet identity, acquisition, team, bag or story changed"])
            }
        }
        try verifyPalletBasis(memory(core))
        var menuTrace: [[String: Any]] = []
        var moveLearning: [[String: Any]] = []
        func tap(_ key: Int) async throws {
            driver.enqueueNativeTap(key)
            guard core.resume() else { throw BoundDebugFailure.nativeVerification }
            try await wait("Native controller edge completes") { driver.progress.idle }
            guard core.pause() else { throw BoundDebugFailure.nativeVerification }
            let input = driver.nativeInputResult
            try writeJSON(input.receipts, output.appendingPathComponent("native-input-receipts.json"))
            if let failure = input.failure {
                throw NSError(domain: "DebugFixtureGeneration", code: 12,
                    userInfo: [NSLocalizedDescriptionKey: failure])
            }
        }
        if route2 {
            lastStage = "admit-audited-route1-continuation"
            let beforeAdmission = BoundVBABattleBridge.captureServerState()
            guard BoundVBABattleBridge.qaAdmitRoute1FixtureContinuation() else {
                throw NSError(domain: "DebugFixtureGeneration", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Audited Route1 continuation admission failed"])
            }
            XCTAssertEqual(BoundVBABattleBridge.captureServerState(), beforeAdmission, "Continuation records host ownership only")
            let storyBeforeCandy = try story(memory(core))
            let mankeyBefore = Data(routePartyBytes.suffix(100))
            func menuWait(_ label: String, until predicate: (DebugFixtureNativeMenus) -> Bool) async throws -> DebugFixtureNativeMenus {
                let deadline = Date().addingTimeInterval(15)
                var previous = ""
                while Date() < deadline {
                    let view = DebugFixtureNativeMenus(memory: try memory(core))
                    let signature = "\(view.tasks):\(view.level):\(view.candyQuantity):\(view.startAction):\(view.bagCursor):\(view.learnedMove)"
                    if previous != signature {
                        var facts = view.facts; facts["gate"] = label; facts["frames"] = driver.progress.frames
                        menuTrace.append(facts); previous = signature
                        try writeJSON(menuTrace, output.appendingPathComponent("native-menu-trace.json"))
                    }
                    if predicate(view) { return view }
                    guard core.resume() else { throw BoundDebugFailure.nativeVerification }
                    try await Task.sleep(for: .milliseconds(20))
                    guard core.pause() else { throw BoundDebugFailure.nativeVerification }
                }
                throw NSError(domain: "DebugFixtureGeneration", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "Native menu readiness did not arrive: " + label])
            }
            func cartridgeWord(_ address: Int) -> Int {
                let offset = address - 0x08000000
                guard offset >= 0, offset <= originalROM.count - 4 else { return -1 }
                return (0..<4).reduce(0) { $0 | Int(originalROM[offset + $1]) << ($1 * 8) }
            }
            lastStage = "native-bag-open"
            XCTAssertEqual(DebugFixtureNativeMenus(memory: try memory(core)).candyQuantity, 21)
            try await tap(8)
            var menu = try await menuWait("Start menu input task") { $0.startReady }
            for _ in 0..<10 where menu.startAction != 2 {
                try await tap(128)
                menu = try await menuWait("Start menu cursor after Down") { $0.startReady }
            }
            XCTAssertEqual(menu.startAction, 2)
            XCTAssertEqual(cartridgeWord(0x09148FF0 + menu.startAction * 8 + 4), 0x0806F481)
            try await tap(1)
            menu = try await menuWait("Bag list input task after fade/animation") { $0.bagReady }
            // The source basis has never opened Bag: Rare Candy is its only
            // Items-pocket row. Refuse a different pocket or item selection.
            XCTAssertEqual(menu.bagPocket, 0); XCTAssertEqual(menu.bagCursor, 0)
            XCTAssertEqual(menu.item(menu.bagCursor)?.id, 68); XCTAssertEqual(menu.item(menu.bagCursor)?.quantity, 21)
            try await tap(1)
            menu = try await menuWait("Rare Candy context menu") { $0.contextReady }
            XCTAssertEqual(menu.contextCursor, 0)
            let actionOffset = menu.contextAction - 0x08000000
            XCTAssertTrue((0..<originalROM.count).contains(actionOffset))
            let action = Int(originalROM[actionOffset])
            XCTAssertEqual(cartridgeWord(0x09147E64 + action * 8 + 4), 0x08109C51, "The selected context action is native Use")
            try await tap(1)
            menu = try await menuWait("Native party item selection") { $0.partyReady }
            XCTAssertEqual(menu.selectedMon, 0); XCTAssertEqual(menu.level, 5)
            for targetLevel in 6...8 {
                lastStage = "native-candy-level-\(targetLevel)"
                try await tap(1)
                menu = try await menuWait("Native Rare Candy acknowledgement") {
                    $0.postCandyReady && $0.level == targetLevel
                }
                XCTAssertEqual(menu.selectedMon, 0); XCTAssertEqual(menu.candyQuantity, 26 - targetLevel)
                try await tap(1)
                for _ in 0..<4 {
                    menu = try await menuWait("Party selection or native learned-move acknowledgement") {
                        $0.partyReady || $0.learnedMoveReady
                    }
                    if menu.partyReady { break }
                    // An empty move slot is filled by the native learnset path.
                    // Replacement/yes-no menus are deliberately unsupported:
                    // their distinct task will stop and preserve the attempt.
                    moveLearning.append(["level": targetLevel, "move": menu.learnedMove,
                        "nativeTask": "08125D2D", "action": "A acknowledges native learned move"])
                    try writeJSON(moveLearning, output.appendingPathComponent("native-move-learning.json"))
                    try await tap(1)
                }
                XCTAssertTrue(menu.partyReady); XCTAssertEqual(menu.level, targetLevel)
                let (snapshot, receipt) = try capture(core, to: output.appendingPathComponent("candy-\(targetLevel)"))
                receipts.append(receipt)
                XCTAssertEqual(Data(try party(snapshot).0.suffix(100)), mankeyBefore)
                XCTAssertEqual(try party(snapshot).0.prefix(8), routePartyBytes.prefix(8), "Native identity and OT remain fixed")
                XCTAssertEqual(try story(snapshot), storyBeforeCandy)
            }
            lastStage = "native-bag-close"
            try await tap(2)
            _ = try await menuWait("Bag after closing native party selector") { $0.bagReady }
            try await tap(2)
            menu = try await menuWait("Native Bag returns to field or Start") { $0.fieldReady || $0.startReady }
            if menu.startReady { try await tap(2) }
            XCTAssertTrue(core.resume())
            try await pauseAtReadyField(core, driver: driver, minimum: 30, label: "Bag leveling returns native field ownership")
            let leveledMemory = try memory(core)
            let leveled = try party(leveledMemory)
            XCTAssertEqual(leveled.1.map { $0.level ?? 0 }, [8, 8])
            XCTAssertEqual(leveled.1.map(\.species), [starterSpecies, 56])
            XCTAssertTrue(leveled.1.allSatisfy { $0.identity.trainer == seed && $0.hp == $0.maxHP })
            XCTAssertEqual(DebugFixtureNativeMenus(memory: leveledMemory).candyQuantity, 18)
            XCTAssertEqual(try story(leveledMemory), storyBeforeCandy)
            XCTAssertEqual(moveLearning.count, 1)
            XCTAssertEqual(moveLearning.first?["level"] as? Int, 7)
            XCTAssertEqual(moveLearning.first?["move"] as? Int, controller ? 52 : 145)
            routePartyBytes = leveled.0
            receipts.append(try capture(core, to: output.appendingPathComponent("native-candy-complete")).1)
        }
        func awaitMartDialogue() async throws {
            let firstFrame = driver.progress.frames
            var stallFrame = firstFrame, priorMusic: String?, transitionTrace: [[String: Any]] = []
            var lastSignature: String?
            while true {
                let snapshot = try memory(core), view = DebugFixtureNativeMenus(memory: snapshot)
                let frame = driver.progress.frames
                let signature = "\(view.nativeMap):\(view.word(0x030030F4)):\(view.word(0x03000EB8)):\(view.word(0x0300730C)):\(view.half(0x03007324))"
                if signature != lastSignature {
                    transitionTrace.append(["frame": frame, "mapGroup": view.nativeMap.group,
                        "mapNumber": view.nativeMap.number, "callback2": view.word(0x030030F4),
                        "scriptPC": view.word(0x03000EB8), "scriptWaiter": view.word(0x03000EB4),
                        "scriptReturn": view.word(0x03000EBC), "musicState": view.byte(0x03000FC4),
                        "musicStatus": view.word(0x03007304), "musicClock": view.word(0x0300730C),
                        "fadeCounter": view.half(0x03007324), "musicChainIntact": view.musicChainIntact,
                        "tasks": view.tasks, "doorStage": view.task(0x0807E80D).map { view.data($0, 0) } ?? -1])
                    try writeJSON(transitionTrace, output.appendingPathComponent("native-mart-transition.json"))
                    lastSignature = signature
                }
                guard view.musicChainIntact else {
                    throw NSError(domain: "DebugFixtureGeneration", code: 21,
                        userInfo: [NSLocalizedDescriptionKey: "Native music chain damaged during door transition"])
                }
                if view.parcelDialogueReady { break }
                let expectedTransition = view.martDoorTransition || view.nativeMap == (5, 3)
                guard expectedTransition, frame - firstFrame <= 600 else {
                    throw NSError(domain: "DebugFixtureGeneration", code: 22,
                        userInfo: [NSLocalizedDescriptionKey: "Expected native Mart transition/dialogue did not complete"])
                }
                let music = "\(view.word(0x0300730C)):\(view.half(0x03007324))"
                if music != priorMusic { priorMusic = music; stallFrame = frame }
                guard !(5...7).contains(view.byte(0x03000FC4)) || frame - stallFrame < 120 else {
                    throw NSError(domain: "DebugFixtureGeneration", code: 23,
                        userInfo: [NSLocalizedDescriptionKey: "Native fade producer stopped; extra waiting is not a repair"])
                }
                guard core.resume() else { throw BoundDebugFailure.nativeVerification }
                try await Task.sleep(for: .milliseconds(20))
                guard core.pause() else { throw BoundDebugFailure.nativeVerification }
            }
        }
        var walkingFriendship: [[String: Any]] = []
        for (index, step) in route.steps.prefix(bagMart ? 5 : route.steps.count).enumerated() {
            lastStage = step.id
            let beforeStepCounter = DebugFixtureNativeMenus(memory: try memory(core)).variable(0x4021)
            XCTAssertEqual(step.inputs.reduce(0) { $0 + $1.frames }, step.frames)
            XCTAssertTrue(step.inputs.allSatisfy { $0.mask & ~0xFF == 0 && (1...3600).contains($0.frames) })
            if let path = step.walk {
                let postOak = route2 && step.id == "route1-second-north"
                let validRoute2 = route2 && step.mapNumber == 19 && step.x == 12
                    && ((step.id == "route1-return-south" && path.count == 57 && step.y == 39)
                        || (postOak && path.count == 58 && step.y == 0))
                let validPallet = pallet && ((step.id == "route1-gift-return-south" && path.count == 9
                    && step.mapNumber == 19 && step.x == 12 && step.y == 39)
                    || (step.id == "pallet-peer-loss-staging" && path.count == 19
                        && step.mapNumber == 0 && step.x == 16 && step.y == 14))
                guard validRoute2 || validPallet, step.inputs.isEmpty, step.frames == 0,
                      step.mapGroup == 3 else { throw BoundDebugFailure.nativeVerification }
                var walked: [[String: Any]] = []
                for tileIndex in 1..<path.count {
                    let prior = path[tileIndex - 1], target = path[tileIndex]
                    let snapshot = try memory(core), view = DebugFixtureNativeMenus(memory: snapshot)
                    let position = try player(profile, memory: snapshot)
                    try verifyPalletBasis(snapshot)
                    guard position.mapGroup == 3, position.mapNumber == step.mapNumber,
                          position.tile == .init(x: prior.x, y: prior.y), position.previousTile == position.tile,
                          position.runningState == 0, position.tileTransitionState == 0,
                          abs(target.x - prior.x) + abs(target.y - prior.y) == 1,
                          view.fieldBlock(x: prior.x, y: prior.y) == prior.block,
                          view.fieldBlock(x: target.x, y: target.y) == target.block,
                          target.block & 0xC00 == 0, target.block >> 12 == 3,
                          [0, 2].contains(target.behavior), view.musicChainIntact,
                          view.candyQuantity == (pallet ? 21 : 18), view.itemQuantity(0x015D, pocket: 1) == (pallet || postOak ? 0 : 1),
                          view.variable(0x4055) == (pallet ? 4 : postOak ? 6 : 5),
                          view.variable(0x4057) == (pallet ? 0 : postOak ? 2 : 1),
                          view.flag(0x829) == postOak, view.itemQuantity(4, pocket: 2) == (postOak ? 10 : 0) else {
                        throw NSError(domain: "DebugFixtureGeneration", code: 30,
                            userInfo: [NSLocalizedDescriptionKey: "Reviewed native Route1 step changed at tile \(tileIndex)"])
                    }
                    let header = step.mapNumber == 19 ? 0x35082C : 0x350618
                    guard Data(try XCTUnwrap(snapshot.bytes(at: 0x02036DFC, count: 28)))
                            == originalROM.subdata(in: header..<(header + 28)) else { throw BoundDebugFailure.nativeVerification }
                    for objectID in 0..<16 {
                        let object = 0x02036E38 + objectID * 36
                        if view.word(object) & 0x2001 == 1, view.byte(object + 8) != 255,
                           (view.half(object + 0x10) - 7 == target.x && view.half(object + 0x12) - 7 == target.y)
                            || (view.half(object + 0x14) - 7 == target.x && view.half(object + 0x16) - 7 == target.y) {
                            throw NSError(domain: "DebugFixtureGeneration", code: 31,
                                userInfo: [NSLocalizedDescriptionKey: "Native object occupies reviewed tile \(tileIndex); no reroute or displacement"])
                        }
                    }
                    // Only the separately verified native walking-friendship
                    // byte may vary; the existing complete-step counter guard
                    // still validates its cause after all 56 native steps.
                    var observedParty = try party(snapshot).0
                    guard observedParty.count == routePartyBytes.count else { throw BoundDebugFailure.nativeVerification }
                    for slot in 0..<(observedParty.count / 100) { observedParty[slot * 100 + 41] = routePartyBytes[slot * 100 + 41] }
                    guard observedParty == routePartyBytes else { throw BoundDebugFailure.nativeVerification }
                    for id in Array(0x820...0x827) + [0x906, 0x91E, 0x920, 0x976, 0x977, 0x978]
                        + [0x52C, 0x52D, 0x538, 0x58E, 0x69E] {
                        guard !view.flag(id) else { throw BoundDebugFailure.nativeVerification }
                    }
                    driver.enqueueNativeWalk(from: position, x: target.x, y: target.y,
                        objectID: view.byte(0x0203707D), save: view.word(0x03005008))
                    guard core.resume() else { throw BoundDebugFailure.nativeVerification }
                    try await wait("Reviewed native Route1 tile \(tileIndex)", seconds: 4) { driver.progress.idle }
                    guard core.pause() else { throw BoundDebugFailure.nativeVerification }
                    let input = driver.nativeInputResult
                    try writeJSON(input.receipts, output.appendingPathComponent("native-input-receipts.json"))
                    if let failure = input.failure {
                        throw NSError(domain: "DebugFixtureGeneration", code: 32,
                            userInfo: [NSLocalizedDescriptionKey: "Route1 tile \(tileIndex): " + failure])
                    }
                    let after = try player(profile, memory: memory(core))
                    guard after.mapGroup == 3, after.mapNumber == step.mapNumber, after.tile == .init(x: target.x, y: target.y),
                          after.previousTile == after.tile, after.runningState == 0, after.tileTransitionState == 0 else {
                        throw BoundDebugFailure.nativeVerification
                    }
                    walked.append(["tileIndex": tileIndex, "x": target.x, "y": target.y,
                        "liveBlock": target.block, "frames": driver.progress.frames, "nativeStepSettled": true])
                    try writeJSON(walked, output.appendingPathComponent("native-walk-" + step.id + ".json"))
                }
            } else if step.connection == true {
                let snapshot = try memory(core), view = DebugFixtureNativeMenus(memory: snapshot)
                let position = try player(profile, memory: snapshot)
                try verifyPalletBasis(snapshot)
                guard pallet, step.id == "route1-pallet-connection", step.frames == 0, step.inputs.isEmpty,
                      step.mapGroup == 3, step.mapNumber == 0, step.x == 12, step.y == 0,
                      position.mapGroup == 3, position.mapNumber == 19, position.tile == .init(x: 12, y: 39),
                      position.previousTile == position.tile, position.runningState == 0, position.tileTransitionState == 0,
                      view.fieldReady, view.musicChainIntact,
                      view.fieldBlock(x: 12, y: 40) == 12966,
                      Data(try XCTUnwrap(snapshot.bytes(at: 0x02036DFC, count: 28))) == originalROM.subdata(in: 0x35082C..<0x350848),
                      originalROM.subdata(in: 0x3529F4..<0x3529FC) == Data([2,0,0,0,0xDC,0x29,0x35,8]),
                      originalROM.subdata(in: 0x3529E8..<0x3529F4) == Data([1,0,0,0,0,0,0,0,3,0,0,0]) else {
                    throw BoundDebugFailure.nativeVerification
                }
                driver.enqueueNativeWalk(from: position, x: 12, y: 40,
                    objectID: view.byte(0x0203707D), save: view.word(0x03005008), palletConnection: true)
                guard core.resume() else { throw BoundDebugFailure.nativeVerification }
                try await wait("Native Route1 south connection into Pallet", seconds: 4) { driver.progress.idle }
                guard core.pause() else { throw BoundDebugFailure.nativeVerification }
                let input = driver.nativeInputResult
                try writeJSON(input.receipts, output.appendingPathComponent("native-input-receipts.json"))
                if let failure = input.failure { throw NSError(domain: "DebugFixtureGeneration", code: 34,
                    userInfo: [NSLocalizedDescriptionKey: failure]) }
                let after = try memory(core), arrived = try player(profile, memory: after)
                guard arrived.mapGroup == 3, arrived.mapNumber == 0, arrived.tile == .init(x: 12, y: 0),
                      arrived.previousTile == arrived.tile, arrived.runningState == 0, arrived.tileTransitionState == 0,
                      Data(try XCTUnwrap(after.bytes(at: 0x02036DFC, count: 28))) == originalROM.subdata(in: 0x350618..<0x350634)
                    else { throw BoundDebugFailure.nativeVerification }
            } else {
                driver.enqueue(step.inputs.map { ($0.mask, $0.frames) })
                XCTAssertTrue(core.resume())
                try await wait("Ordinary route inputs finish: " + step.id, seconds: 45) { driver.progress.idle }
                XCTAssertTrue(core.pause())
            }
            if route2 && step.id == "mart-native-entry" { try await awaitMartDialogue() }
            if route2 && step.id == "route1-probe-13" {
                // A connected-map transition can consume the last walking
                // poll of this historical frame recipe. Retain the reviewed
                // endpoint (24,38): only the observed adjacent tile (24,39)
                // may receive one native Up edge, followed by neutral input
                // until that one step finishes. No alternate endpoint passes.
                let before = try memory(core), view = DebugFixtureNativeMenus(memory: before)
                let position = try player(profile, memory: before)
                if position.tile == .init(x: 24, y: 39) {
                    guard position.mapGroup == 3, position.mapNumber == 1, view.fieldReady,
                          view.musicChainIntact, position.previousTile == position.tile,
                          position.runningState == 0, position.tileTransitionState == 0,
                          step.x == 24, step.y == 38 else { throw BoundDebugFailure.nativeVerification }
                    receipts.append(try capture(core, to: output.appendingPathComponent("viridian-waypoint-before")).1)
                    let startFrame = driver.progress.frames
                    try await tap(64)
                    var trace: [[String: Any]] = []
                    while true {
                        let snapshot = try memory(core), view = DebugFixtureNativeMenus(memory: snapshot)
                        let objectID = view.byte(0x0203707D), running = view.byte(0x0203707A)
                        let transition = view.byte(0x0203707B), object = 0x02036E38 + objectID * 36
                        let x = view.half(object + 0x10) - 7, y = view.half(object + 0x12) - 7
                        let previousX = view.half(object + 0x14) - 7, previousY = view.half(object + 0x16) - 7
                        trace.append(["frame": driver.progress.frames, "x": x, "y": y,
                            "previousX": previousX, "previousY": previousY,
                            "runningState": running, "tileTransitionState": transition,
                            "heldKeys": view.half(0x0300311C)])
                        try writeJSON(trace, output.appendingPathComponent("native-viridian-waypoint.json"))
                        // The object destination can lead the saved camera
                        // coordinate during a real step. Read that bounded
                        // movement only; the full reader must agree on exit.
                        guard view.nativeMap == (3, 1), objectID < 16,
                              view.word(object) & 0x10001 == 0x10001, view.byte(object + 8) == 0xFF,
                              x == 24, previousX == 24, (38...39).contains(y), (38...39).contains(previousY),
                              (0...2).contains(running), (0...2).contains(transition),
                              view.word(0x030030F0) == 0x08056535, view.word(0x030030F4) == 0x080565B5,
                              view.byte(0x03000F9C) == 0, view.musicChainIntact,
                              driver.progress.frames - startFrame <= 60 else { throw BoundDebugFailure.nativeVerification }
                        if y == 38, previousY == y, running == 0, transition == 0,
                           view.half(0x0300311C) == 0 {
                            XCTAssertEqual(try player(profile, memory: snapshot).tile, .init(x: 24, y: 38))
                            break
                        }
                        // A sampled edge which leaves an idle avatar on the
                        // starting tile is a failed input, not a reason to retry.
                        guard running != 0 || transition != 0 || previousY != y else { throw BoundDebugFailure.nativeVerification }
                        guard core.resume() else { throw BoundDebugFailure.nativeVerification }
                        try await Task.sleep(for: .milliseconds(20))
                        guard core.pause() else { throw BoundDebugFailure.nativeVerification }
                    }
                }
            }
            // Dialogue may still own the field at intermediate points. Preserve
            // its native state; do not dismiss or release it through RAM writes.
            let (snapshot, receipt) = try capture(core, to: output.appendingPathComponent(String(format: "step-%02d", index + 1)))
            try verifyPalletBasis(snapshot)
            receipts.append(receipt)
            let position = try player(profile, memory: snapshot)
            XCTAssertEqual(position.mapGroup, step.mapGroup, step.id)
            XCTAssertEqual(position.mapNumber, step.mapNumber, step.id)
            XCTAssertEqual(position.tile, .init(x: step.x, y: step.y), step.id)
            if route2 && step.id == "mart-parcel-complete" {
                let progression = DebugFixtureNativeMenus(memory: snapshot)
                XCTAssertTrue(progression.fieldReady)
                XCTAssertEqual(progression.itemQuantity(0x015D, pocket: 1), 1, "Native Mart script grants Oak's Parcel")
                XCTAssertEqual(progression.variable(0x4055), 5)
                XCTAssertEqual(progression.variable(0x4057), 1)
                for id in [0x4051, 0x4054, 0x4058, 0x4012, 0x4013] { XCTAssertEqual(progression.variable(id), 0) }
                for id in Array(0x820...0x829) + [0x906, 0x91E, 0x920, 0x976, 0x977, 0x978]
                    + [0x52C, 0x52D, 0x538, 0x58E, 0x69E] where id != 0x828 {
                    XCTAssertFalse(progression.flag(id))
                }
            }
            let observedParty = try party(snapshot).0
            let afterStepCounter = DebugFixtureNativeMenus(memory: snapshot).variable(0x4021)
            guard observedParty.count == routePartyBytes.count else { throw BoundDebugFailure.nativeVerification }
            var expectedParty = routePartyBytes
            var friendshipChanges: [[String: Int]] = []
            for slot in 0..<(observedParty.count / 100) {
                let offset = slot * 100 + 41 // Frozen native GetMonData field32.
                let before = Int(routePartyBytes[offset]), after = Int(observedParty[offset])
                if before != after {
                    // Native0806D74C wraps var4021 at128 and invokes friendship
                    // event5: random base+1, possibly met-map+1. These fixed
                    // parties have no held item or Luxury Ball bonus. Preserve
                    // every identity/acquisition/stat/move/HP byte exactly.
                    guard (0..<128).contains(beforeStepCounter), (0..<128).contains(afterStepCounter),
                          afterStepCounter < beforeStepCounter, after > before, after - before <= 2 else {
                        throw NSError(domain: "DebugFixtureGeneration", code: 13,
                            userInfo: [NSLocalizedDescriptionKey: "Unexpected native friendship delta on " + step.id])
                    }
                    expectedParty[offset] = observedParty[offset]
                    friendshipChanges.append(["slot": slot, "before": before, "after": after])
                }
            }
            guard observedParty == expectedParty else {
                throw NSError(domain: "DebugFixtureGeneration", code: 14,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected party mutation on " + step.id])
            }
            if !friendshipChanges.isEmpty {
                walkingFriendship.append(["step": step.id, "counterBefore": beforeStepCounter,
                    "counterAfter": afterStepCounter, "changes": friendshipChanges])
                try writeJSON(walkingFriendship, output.appendingPathComponent("native-walking-friendship.json"))
            }
            routePartyBytes = observedParty
        }
        if bagMart {
            // The historical route records the old stalled outdoor doorway.
            // This separate regression requires the native indoor script and
            // its exact parcel-dialogue A/B waiter instead of that stall.
            lastStage = "native-mart-door"
            guard DebugFixtureNativeMenus(memory: try memory(core)).musicChainIntact else {
                throw NSError(domain: "DebugFixtureGeneration", code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Native music chain damaged after Bag exit"])
            }
            driver.enqueue([(64, 16), (0, 30)])
            guard core.resume() else { throw BoundDebugFailure.nativeVerification }
            try await wait("Native Up enters Mart door") { driver.progress.idle }
            guard core.pause() else { throw BoundDebugFailure.nativeVerification }
            try await awaitMartDialogue()
            lastStage = "native-mart-parcel-dialogue"
            let (snapshot, receipt) = try capture(core, to: output)
            let view = DebugFixtureNativeMenus(memory: snapshot), position = try player(profile, memory: snapshot)
            XCTAssertEqual(position.mapGroup, 5); XCTAssertEqual(position.mapNumber, 3)
            XCTAssertEqual(position.tile, .init(x: 4, y: 7)); XCTAssertTrue(view.parcelDialogueReady)
            XCTAssertEqual(try party(snapshot).0, routePartyBytes); XCTAssertEqual(view.candyQuantity, 18)
            for id in Array(0x820...0x827) + [0x906, 0x91E, 0x920, 0x976, 0x977, 0x978]
                + [0x52C, 0x52D, 0x538, 0x58E, 0x69E] { XCTAssertFalse(view.flag(id)) }
            var report = receipt
            report.merge(["version": 1, "status": "passed-native-regression", "pointID": request.pointID,
                "stage": stage, "role": request.role, "run": request.run.uuidString,
                "romSHA256": hash(originalROM), "recipeSHA256": recipeHash,
                "sourceReportSHA256": hash(originalInputs[sourceReportName]!),
                "sourceAuditSHA256": hash(originalInputs["native-audit.json"]!),
                "nativeBagLeveling": true, "moveLearning": moveLearning,
                "musicChainIntact": true, "parcelDialogueReady": true,
                "coldRestorationVerified": false, "certifiedFixture": false,
                "limit": "Bounded native Bag-to-Mart dialogue regression; source cold restore verified, endpoint is not a certified fixture."],
                uniquingKeysWith: { _, new in new })
            try writeJSON(report, output.appendingPathComponent("native-bag-mart.json"))
            completed = true
            return
        }
        lastStage = stage + (pallet ? "-final-staging" : "-native-gifts")
        XCTAssertTrue(core.resume())
        try await pauseAtReadyField(core, driver: driver, minimum: 60, label: "Result map is a committed idle native field")
        let beforeGift = try memory(core)
        let finalHeader = pallet ? 0x350618 : (route2 ? 0x350848 : 0x35082C)
        XCTAssertEqual(Data(try XCTUnwrap(beforeGift.bytes(at: 0x02036DFC, count: 28))), originalROM.subdata(in: finalHeader..<(finalHeader + 28)))
        try verifyPalletBasis(beforeGift)
        if pallet { XCTAssertEqual(try party(beforeGift).0, routePartyBytes) }
        if route2 {
            let progression = DebugFixtureNativeMenus(memory: beforeGift)
            XCTAssertTrue(progression.flag(0x829), "Oak's native delivery must grant the Pokedex")
            for (id, expected) in [0x4051: 2, 0x4054: 1, 0x4055: 6, 0x4057: 2, 0x4058: 1, 0x4012: 0, 0x4013: 0] {
                XCTAssertEqual(progression.variable(id), expected, String(format: "Native story var%04X", id))
            }
            for id in Array(0x820...0x827) + [0x906, 0x91E, 0x920, 0x976, 0x977, 0x978] {
                XCTAssertFalse(progression.flag(id), String(format: "Later progression flag%04X must stay clear", id))
            }
            for trainer in [0x2C, 0x2D, 0x38, 0x8E, 0x19E] {
                XCTAssertFalse(progression.flag(0x500 + trainer), "Native HasTrainerBeenFought uses flag500+ID")
            }
            XCTAssertEqual(progression.candyQuantity, 18)
            XCTAssertEqual(progression.itemQuantity(0x015D, pocket: 1), 0, "Native Oak delivery consumes the parcel")
            XCTAssertEqual(progression.itemQuantity(4, pocket: 2), 10, "Native Oak gift supplies ten Poke Balls")
        }
        func story(_ snapshot: BoundGBAMemorySnapshot) throws -> [Data] {
            let pointerBytes = try XCTUnwrap(snapshot.bytes(at: 0x03005008, count: 4))
            let save = (0..<4).reduce(0) { $0 | Int(pointerBytes[$1]) << ($1 * 8) }
            XCTAssertTrue((0x02000000...0x0203C000).contains(save))
            return try [(save + 0xEE0, 0x320), (0x0203B174, 0x200), (0x0203B374, 0x400)].map {
                Data(try XCTUnwrap(snapshot.bytes(at: $0.0, count: $0.1)))
            }
        }
        let unchangedStory = try story(beforeGift)
        for operation in route.nativeOperations {
            lastStage = "native-operation-\(operation)"
            let beforeDirectory = output.appendingPathComponent("operation-\(operation)-before")
            receipts.append(try capture(core, to: beforeDirectory).1)
            let preflight = BoundVBABattleBridge.qaDebugFixturePreflight()
            try writeJSON(preflight, beforeDirectory.appendingPathComponent("preflight.json"))
            let readyRequest = try XCTUnwrap(BoundROMRequest.decode(BoundVBABattleBridge.romMultiplayerSnapshot()))
            XCTAssertEqual(readyRequest.settings, options.settings)
            // Throw on bounded runner failures so the exact native stop point
            // is retained by defer. XCTest's immediate assertion abort may
            // terminate this async test before its diagnostic defer executes.
            guard driver.beginRecipe(operation) else {
                throw NSError(domain: "DebugFixtureGeneration", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Fixed native recipe rejected: \(preflight)"])
            }
            XCTAssertTrue(core.resume())
            try await wait("Native recipe ends", seconds: 30) {
                driver.recipeStatus["active"] as? Bool == false || driver.recipeStatus["conflict"] as? Bool == true
            }
            XCTAssertTrue(core.pause())
            let status = driver.recipeStatus
            receipts.append(try capture(core, to: output.appendingPathComponent("operation-\(operation)-completed")).1)
            guard status["active"] as? Bool == false, status["success"] as? Bool == true,
                  status["conflict"] as? Bool == false else {
                throw NSError(domain: "DebugFixtureGeneration", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Native recipe did not complete successfully: \(status)"])
            }
            XCTAssertTrue(core.resume())
            try await pauseAtReadyField(core, driver: driver, minimum: 30, label: "Native gift releases script/UI ownership")
            let (snapshot, receipt) = try capture(core, to: output.appendingPathComponent("operation-\(operation)"))
            receipts.append(receipt)
            XCTAssertEqual(try story(snapshot), unchangedStory, "Gift opcodes cannot set story/defeat flags or variables")
            let (partyBytes, mons) = try party(snapshot)
            XCTAssertEqual(mons.map(\.species), route2 ? [starterSpecies, 56, 25] : [starterSpecies, 56])
            XCTAssertEqual(mons.map { $0.level ?? 0 }, route2 ? [8, 8, 8] : [5, 8])
            XCTAssertEqual(mons.map(\.area), route2 ? [157, 101, 102] : [157, 101]); XCTAssertTrue(mons.allSatisfy { $0.identity.trainer == seed && $0.hp == $0.maxHP })
            XCTAssertEqual(partyBytes.prefix(routePartyBytes.count), routePartyBytes)
            let beforeDuplicate = BoundVBABattleBridge.captureServerState()
            XCTAssertFalse(BoundVBABattleBridge.qaBeginDebugFixtureOperation(operation))
            XCTAssertEqual(BoundVBABattleBridge.captureServerState(), beforeDuplicate, "Duplicate recipe is rejected without a guest write")
        }
        lastStage = "cold-restore-" + stage + "-result"
        let (resultMemory, resultReceipt) = try capture(core, to: output)
        let finalState = BoundVBABattleBridge.captureServerState(), finalBattery = BoundVBABattleBridge.captureServerBattery()
        let finalParty = try party(resultMemory).0, finalPosition = try player(profile, memory: resultMemory)
        XCTAssertTrue(BoundVBABattleBridge.qaResetDebugFixtureOperations())
        XCTAssertTrue(core.stop()); core.updateHandler = nil
        BoundVBABattleBridge.closeSharedWorld(); BoundVBABattleBridge.close(); BoundVBABattleBridge.closeSoulLink()
        let reopened = try XCTUnwrap(EmulatorCore(game: DebugFixtureGame(fileURL: rom, gameSaveURL: batteryURL), options: [.metal: true]))
        activeCore = reopened
        try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(reopened)
        XCTAssertTrue(BoundVBABattleBridge.restoreServerBattery(finalBattery)); XCTAssertTrue(BoundVBABattleBridge.restoreServerState(finalState))
        XCTAssertEqual(try memory(reopened).workRAM, resultMemory.workRAM)
        let restored = makeDriver(reopened); activeDriver = restored
        reopened.updateHandler = { restored.receive($0) }; reopened.rate = 8
        XCTAssertTrue(reopened.resume()); reopened.deltaCore.emulatorBridge.audioRenderer = nil
        try await pauseAtReadyField(reopened, driver: restored, minimum: 120, label: "Gift result cold-restores into a fresh VBA core")
        let restoredPosition = try player(profile, memory: memory(reopened))
        XCTAssertEqual(restoredPosition.mapGroup, finalPosition.mapGroup); XCTAssertEqual(restoredPosition.mapNumber, finalPosition.mapNumber)
        XCTAssertEqual(restoredPosition.tile, finalPosition.tile); XCTAssertEqual(try party(memory(reopened)).0, finalParty)
        try verifyPalletBasis(memory(reopened))
        XCTAssertEqual(try MultiRedAdapter.debugTrainer(core: reopened).id, seed)
        XCTAssertEqual(try Data(contentsOf: batteryURL), emptyBattery)
        XCTAssertEqual(try Data(contentsOf: rom), originalROM)
        for (name, bytes) in originalInputs { XCTAssertEqual(try Data(contentsOf: input.appendingPathComponent(name)), bytes) }
        var report = resultReceipt
        report.merge(["version": 1, "status": "passed-bounded-route", "pointID": request.pointID,
            "stage": route.stage, "role": request.role, "run": request.run.uuidString, "attempt": request.attempt.uuidString,
            "romSHA256": hash(originalROM), "recipeSHA256": recipeHash, "sourceReportSHA256": hash(originalInputs[sourceReportName]!),
            "gameID": profile.gameProfile.gameID, "coreIdentifier": profile.gameProfile.coreIdentifier,
            "coreStateVersion": profile.gameProfile.coreStateVersion, "saveStateLayout": profile.gameProfile.saveStateLayout,
            "settings": options.settings.base64EncodedString(),
            "sourceAuditSHA256": hash(originalInputs["native-audit.json"]!), "nativeOperations": route.nativeOperations,
            "coldRestorationVerified": true, "batteryAllFF": finalBattery.allSatisfy { $0 == 0xFF },
            "syntheticGifts": route2 ? ["Prior native Mankey8 and21Candy; three Candy used through native Bag", "Pikachu8 by native givemon on Route2"] : ["Mankey8 by native givemon on Route1", "21 Rare Candy by native additem; not used yet"],
            "nativeBagLeveling": route2, "moveLearning": moveLearning, "menuTrace": menuTrace,
            "pending": route.pending, "certifiedFixture": false,
            "testOnlyPeerLossInput": pallet, "nativeSRAMSaveValidated": false], uniquingKeysWith: { _, new in new })
        try writeJSON(report, output.appendingPathComponent("native-route.json"))
        completed = true
    }

    /// Opt-in generation produces candidates only. The independent native and
    /// paired-server certification gate owns certificates and their trust table.
    func testGeneratePairedStartCandidate() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["BOUND_DEBUG_FIXTURE_GENERATE"] == "01" else { throw XCTSkip("Explicit task-owned fixture generation only") }
        XCTAssertEqual(env["SIMULATOR_UDID"], Self.simulator)
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DebugFixtureGenerationQA/02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79")
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
        XCTAssertEqual(request.version, 1); XCTAssertEqual(request.pointID, "01")
        XCTAssertTrue(["controller", "buddy"].contains(request.role))
        let controller = request.role == "controller"
        let seed: UInt32 = controller ? 0x12345678 : 0x87654321
        let partnerSeed: UInt32 = controller ? 0x87654321 : 0x12345678
        let name = controller ? "RED" : "BLUE"
        let species = controller ? 4 : 7
        let rom = root.appendingPathComponent("RadicalRed.gba")
        let originalROM = try Data(contentsOf: rom)
        let profile = try BoundPlayerROMProfile(rom: originalROM)
        XCTAssertEqual(profile.gameProfile, BoundGameProfiles.current)
        XCTAssertEqual(hash(originalROM), "02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79")
        let output = root.appendingPathComponent("results").appendingPathComponent(request.attempt.uuidString)
            .appendingPathComponent("01").appendingPathComponent(request.role)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Never overwrite a previous candidate")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let batteryURL = output.appendingPathComponent("scratch.sav")
        let emptyBattery = Data(repeating: 0xFF, count: 131_072)
        try emptyBattery.write(to: batteryURL)
        XCTAssertTrue(BoundVBABattleBridge.setServerOnlyGameSave(true, for: batteryURL))
        var options = BoundMultiplayerSetupOptions(); options.debug = true
        let settings = options.settings
        let identity = BoundNakamaRunService.PlayerProfile(name: name, gender: 0)
        func makeSetup(_ core: EmulatorCore) -> DebugFixtureFrames {
            DebugFixtureFrames(setup: NativePlayerSceneSetup(core: core, debugPlayer: controller ? 1 : 2,
                run: request.run, localSeed: seed, partnerSeed: partnerSeed, settings: settings,
                playerProfile: identity, chooser: controller))
        }
        var activeCore: EmulatorCore?
        var activeDriver: DebugFixtureFrames?
        defer {
            _ = activeCore?.pause(); activeCore?.updateHandler = nil
            // Preserve the native stop point even when XCTest aborts an
            // assertion. These files are diagnostics, never a certificate.
            if let activeCore, let snapshot = BoundGBAMemorySnapshot.capture(readMemory: {
                activeCore.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1)
            }) {
                try? Data(snapshot.workRAM).write(to: output.appendingPathComponent("final-observation.ewram"))
                try? Data(snapshot.internalRAM).write(to: output.appendingPathComponent("final-observation.iwram"))
                try? BoundVBABattleBridge.captureServerState().write(to: output.appendingPathComponent("final-observation.state"))
                if let activeDriver {
                    let observation: [String: Any] = ["frames": activeDriver.progress.frames,
                        "stableSafeFrames": activeDriver.progress.safe, "inputsIdle": activeDriver.progress.idle,
                        "unavailableSnapshots": activeDriver.progress.unavailable,
                        "transitions": activeDriver.setupTrace]
                    if let bytes = try? JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys]) {
                        try? bytes.write(to: output.appendingPathComponent("final-observation.json"))
                    }
                }
            }
            BoundVBABattleBridge.closeSharedWorld(); BoundVBABattleBridge.close(); BoundVBABattleBridge.closeSoulLink()
            _ = activeCore?.stop()
        }
        let core = try XCTUnwrap(EmulatorCore(game: DebugFixtureGame(fileURL: rom, gameSaveURL: batteryURL), options: [.metal: true]))
        activeCore = core
        let driver = makeSetup(core)
        activeDriver = driver
        core.updateHandler = { driver.receive($0) }
        core.rate = 8; XCTAssertTrue(core.start()); core.deltaCore.emulatorBridge.audioRenderer = nil
        func preserveSetupObservation() throws -> BoundGBAMemorySnapshot {
            let snapshot = try memory(core)
            try Data(snapshot.workRAM).write(to: output.appendingPathComponent("setup-observation.ewram"))
            try Data(snapshot.internalRAM).write(to: output.appendingPathComponent("setup-observation.iwram"))
            try BoundVBABattleBridge.captureServerState().write(to: output.appendingPathComponent("setup-observation.state"))
            let trace = try JSONSerialization.data(withJSONObject: [
                "frames": driver.progress.frames, "stableSafeFrames": driver.progress.safe,
                "unavailableSnapshots": driver.progress.unavailable,
                "transitions": driver.setupTrace
            ], options: [.prettyPrinted, .sortedKeys])
            try trace.write(to: output.appendingPathComponent("setup-observation.json"))
            return snapshot
        }
        do {
            try await pauseAtReadyField(core, driver: driver, minimum: 120,
                label: "Native setup reaches a committed safe field", seconds: 90)
        } catch {
            _ = core.pause(); _ = try? preserveSetupObservation(); throw error
        }
        let originalMemory = try preserveSetupObservation()
        let location = try player(profile, memory: originalMemory)
        let trainer = try MultiRedAdapter.debugTrainer(core: core)
        let (partyBytes, mons) = try party(originalMemory)
        XCTAssertEqual(trainer.id, seed); XCTAssertEqual(trainer.name, name); XCTAssertEqual(trainer.gender, 0)
        XCTAssertEqual(location.mapGroup, 3); XCTAssertEqual(location.mapNumber, 0)
        XCTAssertEqual(location.tile, .init(x: 16, y: 14)); XCTAssertNotNil(location.scene)
        XCTAssertEqual(mons.count, 1); XCTAssertEqual(mons[0].species, species); XCTAssertEqual(mons[0].level, 5)
        XCTAssertEqual(mons[0].identity.trainer, seed); XCTAssertEqual(mons[0].hp, mons[0].maxHP)
        XCTAssertFalse(mons[0].isEgg); XCTAssertFalse(mons[0].eggOrigin)
        let nativeRequest = try XCTUnwrap(BoundROMRequest.decode(BoundVBABattleBridge.romMultiplayerSnapshot()))
        XCTAssertTrue(nativeRequest.permitsFieldInterruption); XCTAssertTrue(nativeRequest.settingsApplied)
        XCTAssertEqual(nativeRequest.settings, settings)
        let state = BoundVBABattleBridge.captureServerState(), battery = BoundVBABattleBridge.captureServerBattery()
        XCTAssertGreaterThan(state.count, 1024); XCTAssertEqual(battery.count, 131_072)
        XCTAssertTrue(BoundVBABattleBridge.qaResetDebugFixtureOperations())
        let recipePreflight = BoundVBABattleBridge.qaDebugFixturePreflight()
        XCTAssertEqual(recipePreflight["exactCartridge"] as? Bool, true)
        XCTAssertEqual(recipePreflight["idleUnownedField"] as? Bool, true)
        for operation in 0...4 {
            XCTAssertFalse(BoundVBABattleBridge.qaBeginDebugFixtureOperation(UInt(operation)),
                           "Pallet and unknown recipes must not grant anything")
        }
        XCTAssertEqual(BoundVBABattleBridge.captureServerState(), state, "Rejected native recipe leaves all guest state untouched")
        XCTAssertEqual(BoundVBABattleBridge.captureServerBattery(), battery)
        try state.write(to: output.appendingPathComponent("checkpoint.state"))
        try battery.write(to: output.appendingPathComponent("game.sav"))
        try Data(originalMemory.workRAM).write(to: output.appendingPathComponent("ewram.bin"))
        try Data(originalMemory.internalRAM).write(to: output.appendingPathComponent("iwram.bin"))
        try partyBytes.write(to: output.appendingPathComponent("party.bin"))
        // Independent metadata derives from the actual native party. The pair
        // assembler adds the verified other role's acquisitions, never its save.
        var ledger = BoundSoulLedger(run: request.run, binding: String(repeating: "0", count: 64))
        try ledger.observe(mons, registering: true, fainted: [])
        XCTAssertTrue(ledger.valid); XCTAssertTrue(ledger.dead.isEmpty)
        try BoundMultiplayerSaveStore.encode(ledger).write(to: output.appendingPathComponent("soul-local.json"))

        // Ordinary movement on a disposable continuation must not alter party
        // ownership. Restore from the retained native checkpoint afterward.
        // Keep this smoke segment on the inspected westward lab-front path,
        // the first ordinary segment in the canonical route.
        driver.enqueue([(32, 32), (0, 90)])
        XCTAssertTrue(core.resume())
        try await wait("Native input finishes") { driver.progress.idle }
        try await pauseAtReadyField(core, driver: driver, minimum: 30, label: "Movement returns to a committed idle field")
        let movedMemory = try memory(core), moved = try player(profile, memory: movedMemory)
        XCTAssertEqual(moved.mapGroup, 3); XCTAssertEqual(moved.mapNumber, 0)
        XCTAssertNotEqual(moved.tile, location.tile)
        XCTAssertEqual(try party(movedMemory).0, partyBytes)
        XCTAssertTrue(core.stop()); core.updateHandler = nil
        BoundVBABattleBridge.closeSharedWorld(); BoundVBABattleBridge.close(); BoundVBABattleBridge.closeSoulLink()
        let reopened = try XCTUnwrap(EmulatorCore(game: DebugFixtureGame(fileURL: rom, gameSaveURL: batteryURL), options: [.metal: true]))
        activeCore = reopened
        try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(reopened)
        XCTAssertTrue(BoundVBABattleBridge.restoreServerBattery(battery))
        XCTAssertTrue(BoundVBABattleBridge.restoreServerState(state))
        XCTAssertEqual(BoundVBABattleBridge.captureServerBattery(), battery)
        XCTAssertEqual(try memory(reopened).workRAM, originalMemory.workRAM)
        XCTAssertEqual(try MultiRedAdapter.debugTrainer(core: reopened), trainer)
        XCTAssertEqual(try party(memory(reopened)).0, partyBytes)
        let beforeRejected = BoundVBABattleBridge.captureServerState()
        XCTAssertFalse(BoundVBABattleBridge.restoreServerState(Data(state.dropLast())))
        XCTAssertEqual(BoundVBABattleBridge.captureServerState(), beforeRejected)
        let restoredDriver = makeSetup(reopened)
        activeDriver = restoredDriver
        reopened.updateHandler = { restoredDriver.receive($0) }
        reopened.rate = 8; XCTAssertTrue(reopened.resume()); reopened.deltaCore.emulatorBridge.audioRenderer = nil
        try await pauseAtReadyField(reopened, driver: restoredDriver, minimum: 120,
            label: "Fresh VBA instance resumes the same committed safe field")
        let restored = try player(profile, memory: memory(reopened))
        XCTAssertEqual(restored.mapGroup, location.mapGroup); XCTAssertEqual(restored.mapNumber, location.mapNumber)
        XCTAssertEqual(restored.tile, location.tile); XCTAssertNotNil(restored.scene)
        XCTAssertEqual(try party(memory(reopened)).0, partyBytes)
        XCTAssertEqual(try Data(contentsOf: batteryURL), emptyBattery, "Managed core never writes the ordinary battery path")
        XCTAssertEqual(try Data(contentsOf: rom), originalROM)
        let files = try ["checkpoint.state", "game.sav", "ewram.bin", "iwram.bin", "party.bin", "soul-local.json"].reduce(into: [String: BoundDebugOwnerDescriptor.File]()) { result, name in
            let bytes = try Data(contentsOf: output.appendingPathComponent(name))
            result[name] = .init(sha256: hash(bytes), bytes: bytes.count)
        }
        let report: [String: Any] = [
            "version": 1, "status": "candidate", "pointID": "01", "role": request.role,
            "attempt": request.attempt.uuidString, "run": request.run.uuidString,
            "fixtureVersion": BoundDebugCatalog.fixtureVersion, "romSHA256": profile.gameProfile.romSHA256,
            "gameID": profile.gameProfile.gameID, "coreIdentifier": profile.gameProfile.coreIdentifier,
            "coreStateVersion": profile.gameProfile.coreStateVersion, "saveStateLayout": profile.gameProfile.saveStateLayout,
            "settings": settings.base64EncodedString(), "trainerID": trainer.id, "trainerName": trainer.name,
            "trainerGender": trainer.gender, "starterSpecies": species, "starterLevel": mons[0].level ?? 0,
            "mapGroup": location.mapGroup, "mapNumber": location.mapNumber, "x": location.tile.x, "y": location.tile.y,
            "fieldRequestFlags": nativeRequest.flags, "setupFrameCount": driver.progress.frames,
            "batteryAllFF": battery.allSatisfy { $0 == 0xFF },
            "restorationMode": "native-state-and-battery; no mGBA conversion; fresh VBA instance",
            "provenance": "Existing native Debug New Game continuation creates starter/setup; synthetic template, not evidence of played rival victory",
            "checks": ["native_setup": true, "own_trainer": true, "original_starter": true,
                       "safe_idle_field": true, "ordinary_movement": true, "native_core_recreation": true,
                       "truncated_state_rejected_without_mutation": true, "ordinary_battery_fenced": true],
            "pending": ["native story/item/cap audit", "app-process relaunch", "authenticated paired restore", "building transition", "early encounter/acquisition", "server checkpoint and reconnect"]
        ]
        var fullReport = report
        fullReport["files"] = try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(files))
        let reportBytes = try JSONSerialization.data(withJSONObject: fullReport, options: [.prettyPrinted, .sortedKeys])
        try reportBytes.write(to: output.appendingPathComponent("native-candidate.json"))
        let attachment = XCTAttachment(data: reportBytes, uniformTypeIdentifier: "public.json")
        attachment.name = "paired-start-" + request.role; attachment.lifetime = .keepAlways; add(attachment)
        NSLog("DEBUG_FIXTURE_CANDIDATE %@", output.path)
    }
}

import XCTest
import SwiftUI
import CoreData
@testable import Harmony
@testable import class Delta.Game
@testable import class Delta.SaveState
@preconcurrency import DeltaCore
@testable import Delta

private struct ServerMemoryFixtureGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

final class SoulLinkTests: XCTestCase {
    @MainActor func testServerManagedSaveStatesRejectRawCloudSyncWithoutTouchingLocalFiles() throws {
        let modelURL = try XCTUnwrap(Bundle(for: DatabaseManager.self).url(forResource: "Delta", withExtension: "momd"))
        let appModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let model = try XCTUnwrap(NSManagedObjectModel.harmonyModel(byMergingWith: [appModel]))
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        context.persistentStoreCoordinator = coordinator
        defer { context.reset() }

        let game = Game(entity: try XCTUnwrap(model.entitiesByName["Game"]), insertInto: context)
        game.identifier = UUID().uuidString
        game.name = "Server save fixture"
        game.filename = "server-save-fixture.gba"
        game.type = .gba
        game.gameSettings = ["bound.multiplayer": true]
        let state = SaveState(entity: try XCTUnwrap(model.entitiesByName["SaveState"]), insertInto: context)
        state.game = game
        let directory = DatabaseManager.defaultDirectoryURL().appendingPathComponent("Save States").appendingPathComponent(game.identifier)
        defer { try? FileManager.default.removeItem(at: directory) }

        let managed = NSEntityDescription.insertNewObject(forEntityName: "ManagedRecord", into: context) as! ManagedRecord
        managed.recordedObjectType = "SaveState"
        managed.recordedObjectIdentifier = state.identifier
        let record = AnyRecord(managed)

        for type in [SaveStateType.auto, .quick, .general, .locked] {
            state.type = type
            XCTAssertFalse(state.isSyncingEnabled)
            XCTAssertTrue(state.syncableFiles.isEmpty)
            XCTAssertThrowsError(try state.prepareForSync(record))
            XCTAssertThrowsError(try state.awakeFromSync(record))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Rejected sync must not materialize a local save-state directory")

        game.gameSettings = [:]
        state.type = .general
        XCTAssertTrue(state.isSyncingEnabled)
        XCTAssertEqual(Set(state.syncableFiles.map(\.identifier)), ["saveState", "thumbnail"])
        XCTAssertNoThrow(try state.prepareForSync(record))
        XCTAssertNoThrow(try state.awakeFromSync(record))
        let original = Data("preserved legacy state".utf8)
        let stateURL = state.fileURL
        try original.write(to: stateURL)
        state.type = .quick
        XCTAssertFalse(state.isSyncingEnabled)

        game.gameSettings = ["bound.multiplayer": true]
        XCTAssertTrue(state.syncableFiles.isEmpty)
        XCTAssertThrowsError(try state.awakeFromSync(record))
        XCTAssertEqual(try Data(contentsOf: stateURL), original, "Marking a game must preserve its older local states")
        context.delete(state)
        context.processPendingChanges()
        XCTAssertEqual(try Data(contentsOf: stateURL), original, "Discarding a rejected download must preserve its older same-filename file")
    }

    private func mon(_ id: UInt32, area: Int = 100, egg: Bool = false, isEgg: Bool = false, hp: Int? = 30, inParty: Bool = false) -> BoundSoulMon {
        .init(identity: .init(personality: id, trainer: 42), species: 1, name: "Mon\(id)", area: area, eggOrigin: egg, isEgg: isEgg, hp: hp, inParty: inParty)
    }
    private func makeLedger() -> BoundSoulLedger { .init(run: UUID(), binding: String(repeating: "a", count: 64)) }

    func testGameOverRequiresWholeUsablePartyAndExcludesFriendlyBattles() throws {
        var first = mon(1), second = mon(2, area: 101)
        first.inParty = true; second.inParty = true
        var ledger = makeLedger()
        try ledger.observe([first, second], registering: true, fainted: [])
        first = mon(1, hp: 0, inParty: true)
        try ledger.observe([first, second], registering: false, fainted: [])
        XCTAssertFalse(BoundSoulWipeout.occurred(party: [first, second], ledger: ledger))
        second = mon(2, area: 101, hp: 0, inParty: true)
        try ledger.observe([first, second], registering: false, fainted: [])
        XCTAssertTrue(BoundSoulWipeout.occurred(party: [first, second], ledger: ledger))
        XCTAssertFalse(BoundSoulWipeout.occurred(party: [first, second], ledger: ledger, friendly: true))
        // A linked loss remains a loss even after the cartridge's blackout heal.
        first = mon(1, inParty: true); second = mon(2, area: 101, inParty: true)
        XCTAssertTrue(BoundSoulWipeout.occurred(party: [first, second], ledger: ledger))
    }

    func testWipeoutIgnoresEggsAndBoxesButFailsClosedOnUnknownPartyHealth() throws {
        var lost = mon(1), live = mon(2, area: 101)
        lost.inParty = true; live.inParty = true
        var egg = mon(3, egg: true, isEgg: true); egg.inParty = true
        let boxed = mon(4, area: 102)
        var ledger = makeLedger()
        try ledger.observe([lost, live, egg, boxed], registering: true, fainted: [])
        lost = mon(1, hp: 0, inParty: true)
        try ledger.observe([lost], registering: false, fainted: [])
        XCTAssertTrue(BoundSoulWipeout.occurred(party: [lost, egg, boxed], ledger: ledger))
        live = mon(2, area: 101, hp: nil, inParty: true)
        XCTAssertFalse(BoundSoulWipeout.occurred(party: [lost, live], ledger: ledger))
        XCTAssertFalse(BoundSoulWipeout.occurred(party: [egg, boxed], ledger: ledger))
        XCTAssertFalse(BoundSoulWipeout.occurred(party: [], ledger: ledger))
        ledger.ended = true
        XCTAssertFalse(BoundSoulWipeout.occurred(party: [lost], ledger: ledger))
    }

    func testGameOverReturnIntentSurvivesRelaunchAndStaysScopedToExactSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoundSoulGameOverStore(root: directory)
        let owner = UUID(), run = UUID(), other = UUID()
        var record = BoundSoulGameOverRecord(gameID: "game", owner: owner, run: run, eventID: UUID())
        let unaffected = BoundSoulGameOverRecord(gameID: "game", owner: owner, run: other, eventID: UUID())
        try store.save(record); try store.save(unaffected)
        record.menuPresented = true
        XCTAssertThrowsError(try store.save(record), "A menu acknowledgement cannot precede return intent")
        record.returnRequested = true
        try store.save(record)
        let reopened = BoundSoulGameOverStore(root: directory)
        XCTAssertEqual(try reopened.load(owner: owner, gameID: "game")[run], record)
        XCTAssertTrue(try reopened.load(owner: UUID(), gameID: "game").isEmpty)
        XCTAssertTrue(try reopened.load(owner: owner, gameID: "other-game").isEmpty)
        try reopened.remove(record); try reopened.remove(record)
        XCTAssertEqual(try reopened.load(owner: owner, gameID: "game"), [other: unaffected])
    }

    func testServerOnlyLedgerAndTimelineIgnoreDiskAndRoundTripThroughSnapshot() throws {
        let game = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(game)
        let url = root.appendingPathComponent("Soul Link/run.json")
        let old = try JSONEncoder().encode(makeLedger())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try old.write(to: url)
        BoundServerMemoryFiles.setEnabled(true, for: game)
        defer {
            try? BoundServerMemoryFiles.restore([:], gameID: game)
            BoundServerMemoryFiles.setEnabled(false, for: game)
            try? FileManager.default.removeItem(at: root)
        }
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: url, gameID: game)
        XCTAssertNil(probe.read().ledger, "A preexisting local multiplayer run must never be loaded")
        let run = UUID()
        try probe.startPreparedRun(run: run, binding: String(repeating: "b", count: 64))
        probe.timeline.append(id: "server:one", kind: .trade, title: "Trade completed")
        let files = BoundServerMemoryFiles.snapshot(gameID: game)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try Data(contentsOf: url), old, "The legacy save remains untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("timeline.json").path))
        let encoded = try JSONEncoder().encode(files)
        try BoundServerMemoryFiles.restore([:], gameID: game)
        probe.configure(core: nil, url: url, gameID: game)
        XCTAssertNil(probe.read().ledger)
        try BoundServerMemoryFiles.restore(JSONDecoder().decode([String: Data].self, from: encoded), gameID: game)
        let otherContainerURL = root.appendingPathComponent("other-container/Soul Link/run.json")
        probe.configure(core: nil, url: otherContainerURL, gameID: game)
        XCTAssertEqual(probe.read().ledger?.run, run)
        XCTAssertEqual(probe.timeline.read().events.map(\.id), ["server:one"])
    }

    func testMemoryRecoveryFilesAreIsolatedAndRejectUnsafeServerPaths() throws {
        let first = UUID().uuidString, second = UUID().uuidString
        for game in [first, second] { BoundServerMemoryFiles.setEnabled(true, for: game) }
        defer { for game in [first, second] { try? BoundServerMemoryFiles.restore([:], gameID: game); BoundServerMemoryFiles.setEnabled(false, for: game) } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(first).appendingPathComponent("Friend Battles")
        let state = folder.appendingPathComponent("checkpoint.state")
        try BoundServerMemoryFiles.directory(folder, gameID: first)
        try BoundServerMemoryFiles.write(Data([1, 2, 3]), to: state, gameID: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(BoundServerMemoryFiles.exists(state, gameID: second))
        XCTAssertThrowsError(try BoundServerMemoryFiles.read(state, gameID: second))
        XCTAssertEqual(try BoundServerMemoryFiles.contents(folder, gameID: first), [state])
        XCTAssertThrowsError(try BoundServerMemoryFiles.restore(["../outside": Data([9])], gameID: first))
        XCTAssertThrowsError(try BoundServerMemoryFiles.restore(["Soul Link/../outside": Data([9])], gameID: first))
        XCTAssertEqual(try BoundServerMemoryFiles.read(state, gameID: first), Data([1, 2, 3]))
        let destination = folder.appendingPathComponent("moved.state")
        try BoundServerMemoryFiles.move(state, to: destination, gameID: first)
        XCTAssertFalse(BoundServerMemoryFiles.exists(state, gameID: first))
        XCTAssertTrue(BoundServerMemoryFiles.exists(destination, gameID: first))
        try BoundServerMemoryFiles.remove(destination, gameID: first)
        XCTAssertTrue(BoundServerMemoryFiles.snapshot(gameID: first).isEmpty)
    }

    func testServerSnapshotRejectsMalformedNativeMemoryState() {
        XCTAssertFalse(BoundVBABattleBridge.restoreServerState(Data()))
        XCTAssertFalse(BoundVBABattleBridge.restoreServerState(Data(repeating: 0, count: 64)))
        var invalid = Data("VBA ".utf8)
        invalid.append(contentsOf: [255, 255, 255, 127])
        invalid.append(Data(repeating: 0, count: 64))
        XCTAssertFalse(BoundVBABattleBridge.restoreServerState(invalid))
        XCTAssertFalse(BoundVBABattleBridge.restoreServerBattery(Data(repeating: 0, count: 10)))
    }

    @MainActor
    func testNativeServerCheckpointRoundTripNeverLoadsOrWritesPersistentSaves() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var cartridge = try Data(contentsOf: fixture)
        cartridge.append(Data(repeating: 0, count: (4 - cartridge.count % 4) % 4))
        cartridge.append(Data("FLASH1M_V103".utf8))
        let rom = folder.appendingPathComponent("flash-fixture.gba")
        try cartridge.write(to: rom)
        let batteryURL = folder.appendingPathComponent("legacy.sav")
        let legacy = Data(repeating: 0x17, count: 131072)
        try legacy.write(to: batteryURL)
        XCTAssertTrue(BoundVBABattleBridge.setServerOnlyGameSave(true, for: batteryURL))
        let core = try XCTUnwrap(EmulatorCore(game: ServerMemoryFixtureGame(fileURL: rom, gameSaveURL: batteryURL), options: [.metal: true]))
        defer {
            _ = core.stop()
            _ = BoundVBABattleBridge.setServerOnlyGameSave(false, for: batteryURL)
        }
        XCTAssertTrue(core.start()); XCTAssertTrue(core.pause())
        XCTAssertNotEqual(BoundVBABattleBridge.captureServerBattery(), legacy, "Core startup ignores legacy multiplayer files")
        let saved = Data(repeating: 0x42, count: 131072)
        XCTAssertTrue(BoundVBABattleBridge.restoreServerBattery(saved))
        let state = BoundVBABattleBridge.captureServerState()
        XCTAssertGreaterThan(state.count, 32)
        XCTAssertEqual(state.prefix(4), Data("VBA ".utf8))
        XCTAssertTrue(BoundVBABattleBridge.restoreServerBattery(Data(repeating: 0x24, count: 131072)))
        XCTAssertFalse(BoundVBABattleBridge.restoreServerState(Data(state.dropLast())))
        var corrupt = state; corrupt[corrupt.count - 5] ^= 0x80
        XCTAssertFalse(BoundVBABattleBridge.restoreServerState(corrupt), "Gzip checksum failure is rejected before mutating the core")
        XCTAssertEqual(BoundVBABattleBridge.captureServerBattery(), Data(repeating: 0x24, count: 131072))
        XCTAssertTrue(BoundVBABattleBridge.restoreServerState(state))
        XCTAssertEqual(BoundVBABattleBridge.captureServerBattery(), saved)
        core.deltaCore.emulatorBridge.loadGameSave(from: batteryURL)
        XCTAssertEqual(BoundVBABattleBridge.captureServerBattery(), saved, "A direct persistent load remains fenced")
        let otherBattery = folder.appendingPathComponent("unregistered.sav")
        core.deltaCore.emulatorBridge.saveGameSave(to: otherBattery)
        let diskState = folder.appendingPathComponent("blocked.state")
        core.saveSaveState(to: diskState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherBattery.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskState.path))
        XCTAssertTrue(core.stop())
        XCTAssertEqual(try Data(contentsOf: batteryURL), legacy, "Core stop cannot overwrite the disregarded save")
    }
    @MainActor
    func testFriendlyBattlesRemainAvailableDuringSoulLinkWhileTradesStayBlocked() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("run.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: url)
        let session = BoundSoulSession(probe: probe)
        XCTAssertTrue(session.permitsNativeActivity(.battle))
        XCTAssertTrue(session.permitsNativeActivity(.trade))
        session.setConnection(owner: "player", room: "room")
        try session.startPreparedRun(run: UUID())
        XCTAssertTrue(session.active)
        XCTAssertTrue(session.permitsNativeActivity(.battle), "Walk-up friendly battles are available during an active linked run")
        XCTAssertFalse(session.permitsNativeActivity(.trade), "Trades must preserve the existing linked-run restriction")
        XCTAssertFalse(session.permitsIndependentStateLoading)
        session.endRun()
        XCTAssertFalse(session.active)
        XCTAssertTrue(session.permitsNativeActivity(.battle))
        XCTAssertTrue(session.permitsNativeActivity(.trade))
    }
    func testRunTimelinePersistsBaselineCatchDeathTradeAndVictoryWithoutDuplicates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("timeline.json")
        let history = BoundRunTimeline(); history.configure(url: url)
        let date = Date(timeIntervalSince1970: 100)
        history.observe(mons: [mon(1)], ready: true, battle: false, outcome: 1, flags: 0, at: date)
        XCTAssertTrue(history.read().events.isEmpty, "Existing catches and stale outcomes are not new events")
        history.observe(mons: [mon(1), mon(2, area: 101)], ready: true, battle: false, outcome: 0, flags: 0, at: date)
        history.observe(mons: [], ready: false, battle: true, outcome: 0, flags: 8, at: date)
        history.observe(mons: [], ready: false, battle: false, outcome: 1, flags: 8, at: date)
        history.observe(mons: [], ready: false, battle: false, outcome: 1, flags: 8, at: date)
        history.append(id: "trade:fixture", kind: .trade, title: "Trade completed", at: date)
        history.append(id: "trade:fixture", kind: .trade, title: "Trade completed", at: date)
        var ledger = makeLedger()
        try ledger.observe([mon(1)], registering: true, fainted: [])
        ledger.dead.insert("area:100"); ledger.recordDeaths(previous: [], at: date)
        history.observeSoul(ledger); history.observeSoul(ledger)
        XCTAssertEqual(history.read().events.map(\.kind), [.catchPokemon, .victory, .trade, .death])
        let reopened = BoundRunTimeline(); reopened.configure(url: url)
        XCTAssertEqual(reopened.read().events, history.read().events)
        reopened.observe(mons: [mon(2, area: 101)], ready: true, battle: false, outcome: 1, flags: 8)
        XCTAssertEqual(reopened.read().events.count, 4)
        XCTAssertNil(reopened.read().error)
    }
    func testRunTimelineIgnoresLossEscapeLinkAndHistoricalDeathsAndPreservesCorruption() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("timeline.json")
        let history = BoundRunTimeline(); history.configure(url: url)
        for (outcome, flags) in [(2, UInt32(8)), (4, 0), (1, 2), (1, 0x200), (1, 0x10000)] {
            history.observe(mons: [], ready: false, battle: true, outcome: 0, flags: flags)
            history.observe(mons: [], ready: false, battle: false, outcome: outcome, flags: flags)
        }
        var ledger = makeLedger(); ledger.dead.insert("area:100"); ledger.recordDeaths(previous: ledger.dead)
        history.observeSoul(ledger)
        XCTAssertTrue(history.read().events.isEmpty)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("broken".utf8); try corrupt.write(to: url)
        history.configure(url: url)
        history.append(id: "new", kind: .trade, title: "Trade completed")
        XCTAssertNotNil(history.read().error)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    @MainActor
    func testRunTimelineRendersAllFourEventKinds() throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RunTimelineQA")
        let history = BoundRunTimeline(); history.configure(url: root.appendingPathComponent(UUID().uuidString + ".json"))
        for (i, kind) in BoundRunEvent.Kind.allCases.enumerated() {
            history.append(id: "render:\(i)", kind: kind, title: ["Acquired Pikachu", "Linked pair lost", "Trade completed", "Trainer battle won"][i], detail: "Route 24", at: Date(timeIntervalSince1970: 1792656000 + Double(i)))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack { BoundRunTimelineView(timeline: history) })
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent("timeline.png"))
        let attachment = XCTAttachment(image: image); attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true; previous?.makeKeyAndVisible()
        XCTAssertEqual(history.read().events.count, 4)
    }

    func testGrassFishingAndRaidShareExactlyOneAreaSlotIncludingBoxedCatches() throws {
        var ledger = makeLedger()
        try ledger.observe([mon(1)], registering: true, fainted: [])
        try ledger.observe([mon(2, hp: nil), mon(3)], registering: true, fainted: [])
        XCTAssertEqual(ledger.records.filter(\.eligible).count, 1)
        XCTAssertEqual(ledger.denied, Set([mon(2).identity, mon(3).identity]))
        try ledger.observe([mon(4, area: 101)], registering: true, fainted: [])
        XCTAssertEqual(ledger.records.filter(\.eligible).count, 2)
    }
    func testFaintIsPermanentAcrossHealingStateRollbackAndJournalRoundTrip() throws {
        var ledger = makeLedger()
        try ledger.observe([mon(1)], registering: true, fainted: [])
        try ledger.observe([mon(1, hp: 0)], registering: false, fainted: [])
        let restored = try JSONDecoder().decode(BoundSoulLedger.self, from: JSONEncoder().encode(ledger))
        ledger = restored
        try ledger.observe([mon(1, hp: 60)], registering: true, fainted: [])
        XCTAssertEqual(ledger.dead, ["area:100"])
        XCTAssertTrue(ledger.denied.contains(mon(1).identity)); XCTAssertTrue(ledger.valid)
    }
    func testEggsNeverConsumeAreaAndKeepOrdinalAfterHatchEvolutionAndBoxing() throws {
        var ledger = makeLedger()
        try ledger.observe([mon(1, egg: true, isEgg: true), mon(2, egg: true, isEgg: true), mon(3)], registering: true, fainted: [])
        XCTAssertEqual(ledger.records.map(\.slot), ["egg:1", "egg:2", "area:100"])
        try ledger.observe([mon(1, area: 101, egg: true, hp: 0), mon(2, area: 102, egg: true, hp: nil)], registering: true, fainted: [])
        XCTAssertEqual(ledger.records.map(\.slot), ["egg:1", "egg:2", "area:100"])
        XCTAssertEqual(ledger.dead, ["egg:1"])
        XCTAssertTrue(ledger.valid)
    }
    func testNativeHatchChangingOriginalTrainerRetainsEggOrdinal() throws {
        var ledger = makeLedger()
        try ledger.observe([mon(1, egg: true, isEgg: true)], registering: true, fainted: [])
        let hatched = BoundSoulMon(identity: .init(personality: 1, trainer: 99), species: 1, name: "Hatched", area: 105, eggOrigin: false, isEgg: false, hp: 30)
        try ledger.observe([hatched], registering: true, fainted: [])
        XCTAssertEqual(ledger.records.count, 1); XCTAssertEqual(ledger.records.first?.slot, "egg:1")
        try ledger.observe([], registering: false, fainted: [hatched.identity])
        XCTAssertEqual(ledger.dead, ["egg:1"])
        XCTAssertTrue(ledger.denied.contains(hatched.identity)); XCTAssertTrue(ledger.denied.contains(mon(1).identity))
    }
    func testLossBitmapIncludesEveryAreaAndEggInEverySyncPacket() throws {
        var ledger = makeLedger(); ledger.dead = ["area:0", "area:255", "egg:1", "egg:2048"]
        XCTAssertEqual(BoundSoulLedger.losses(ledger.lossBits), ledger.dead)
        let packet = BoundSoulPacket(version: 2, run: ledger.run, kind: .state,
            rows: (1...3).map { .init(slot: "egg:\($0)", name: "ABCDEFGHIJ", dead: false) }, losses: ledger.lossBits)
        let data = try XCTUnwrap(packet.encoded()); XCTAssertLessThanOrEqual(data.count, 1024)
        XCTAssertEqual(BoundSoulLedger.losses(try XCTUnwrap(BoundSoulPacket.decode(data)).losses), ledger.dead)
    }
    func testUnhatchedEggDoesNotDieFromZeroPartyHP() throws {
        var ledger = makeLedger()
        try ledger.observe([mon(1, egg: true, isEgg: true, hp: 0)], registering: true, fainted: [mon(1).identity])
        XCTAssertTrue(ledger.dead.isEmpty)
    }
    func testLatchedNativeZeroHPWriteSurvivesSameFrameHealing() throws {
        var ledger = makeLedger()
        try ledger.observe([mon(1)], registering: true, fainted: [])
        try ledger.observe([mon(1, hp: 60)], registering: false, fainted: [mon(1).identity])
        XCTAssertEqual(ledger.dead, ["area:100"])
    }
    func testUnownedAndDuplicateMonFaintsDoNotKillTheAreaPair() throws {
        var ledger = makeLedger()
        try ledger.observe([mon(1), mon(2)], registering: true, fainted: [])
        try ledger.observe([mon(2, hp: 0)], registering: false, fainted: [mon(99).identity])
        XCTAssertTrue(ledger.dead.isEmpty)
    }
    func testPartnerDeathBeforeLocalCatchDisablesFutureLinkedCatch() throws {
        var ledger = makeLedger(); ledger.dead.insert("area:101")
        try ledger.observe([mon(1, area: 101)], registering: true, fainted: [])
        XCTAssertTrue(ledger.denied.contains(mon(1).identity))
    }
    func testDurableSharedFactsRemainStableAcrossNamesAndDuplicateOutOfOrderDelivery() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var value = makeLedger()
        try value.observe([mon(1)], registering: true, fainted: [])
        let acquisition = try XCTUnwrap(value.sharedEvents.first)
        let originalPayload = try XCTUnwrap(acquisition.payload)
        value.records[0].name = "Renamed"
        XCTAssertEqual(value.sharedEvents.first?.id, acquisition.id)
        XCTAssertEqual(value.sharedEvents.first?.payload, originalPayload)
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        let death = try XCTUnwrap(BoundSoulSharedEvent(run: value.run, kind: .death, slot: "area:101").payload)
        let remoteCatch = try XCTUnwrap(BoundSoulSharedEvent(run: value.run, kind: .acquired, slot: "area:101").payload)
        try probe.receiveSharedEvent(death)
        try probe.receiveSharedEvent(death)
        try probe.receiveSharedEvent(remoteCatch)
        try probe.receiveSharedEvent(originalPayload)
        var latest = try XCTUnwrap(probe.read().ledger)
        XCTAssertEqual(latest.dead, ["area:101"])
        XCTAssertEqual(latest.partnerSlots, ["area:100", "area:101"])
        XCTAssertEqual(latest.memorials?.count, 1)
        try latest.observe([mon(2, area: 101)], registering: true, fainted: [])
        XCTAssertTrue(latest.denied.contains(mon(2).identity), "A much later local catch inherits the permanent pair death")
        let reopened = BoundSoulProbe(); reopened.configure(core: nil, url: file)
        XCTAssertEqual(reopened.read().ledger?.dead, ["area:101"])
        XCTAssertThrowsError(try reopened.receiveSharedEvent(try XCTUnwrap(BoundSoulSharedEvent(run: UUID(), kind: .death, slot: "area:100").payload)))
        XCTAssertNil(BoundSoulSharedEvent(run: value.run, kind: .death, slot: "area:999").payload)
    }
    func testAuthoritativeOwnHistoryConsumesSlotsWithoutInventingMonIdentitiesAfterOlderRestore() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let older = makeLedger()
        try JSONEncoder().encode(older).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        let death = try XCTUnwrap(BoundSoulSharedEvent(run: older.run, kind: .death, slot: "area:101").payload)
        let acquired = try XCTUnwrap(BoundSoulSharedEvent(run: older.run, kind: .acquired, slot: "area:101").payload)
        let spent = try XCTUnwrap(BoundSoulSharedEvent(run: older.run, kind: .acquired, slot: "area:102").payload)
        try probe.receiveSharedEvent(death, localOrigin: true)
        try probe.receiveSharedEvent(acquired, localOrigin: true)
        try probe.receiveSharedEvent(spent, localOrigin: true)
        try probe.receiveSharedEvent(acquired, localOrigin: true)
        let reopened = BoundSoulProbe(); reopened.configure(core: nil, url: file)
        var latest = try XCTUnwrap(reopened.read().ledger)
        XCTAssertTrue(latest.records.isEmpty, "Server catch facts cannot fabricate native Pokemon identities")
        XCTAssertTrue(latest.partnerSlots.isEmpty, "Own history cannot be presented as the partner's catches")
        XCTAssertEqual(latest.acquired, ["area:101", "area:102"])
        XCTAssertEqual(latest.dead, ["area:101"])
        XCTAssertEqual(latest.memorials?.first?.localCaught, true)
        XCTAssertNil(latest.memorials?.first?.localName)
        XCTAssertEqual(latest.sharedEvents.filter { $0.kind == .acquired }.count, 2)
        try latest.observe([mon(1, area: 101), mon(2, area: 102)], registering: true, fainted: [])
        XCTAssertTrue(latest.records.allSatisfy { !$0.eligible })
        XCTAssertEqual(latest.denied, [mon(1).identity, mon(2).identity], "Neither a dead pair nor a previously spent area may be caught again after rewind")
        XCTAssertTrue(latest.valid)
        let merged = try JSONDecoder().decode(BoundSoulLedger.self, from: BoundSoulLedger.mergeForIndependentRestore(
            current: JSONEncoder().encode(latest), incoming: JSONEncoder().encode(older)))
        XCTAssertEqual(merged.consumedSlots, latest.consumedSlots)
        XCTAssertEqual(merged.denied, latest.denied)
    }
    func testOwnEggHistoryAdvancesOrdinalsWhilePeerAcquisitionKeepsIndependentSlots() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let older = makeLedger(); try JSONEncoder().encode(older).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        try probe.receiveSharedEvent(try XCTUnwrap(BoundSoulSharedEvent(run: older.run, kind: .acquired, slot: "egg:3").payload), localOrigin: true)
        try probe.receiveSharedEvent(try XCTUnwrap(BoundSoulSharedEvent(run: older.run, kind: .acquired, slot: "area:105").payload))
        var value = try XCTUnwrap(probe.read().ledger)
        XCTAssertEqual(value.nextEgg, 4)
        XCTAssertEqual(value.acquired, ["egg:3"])
        XCTAssertEqual(value.partnerSlots, ["area:105"])
        try value.observe([mon(1, egg: true, isEgg: true), mon(2, area: 105)], registering: true, fainted: [])
        XCTAssertEqual(value.records.map(\.slot), ["egg:4", "area:105"])
        XCTAssertTrue(value.records.allSatisfy(\.eligible), "Peer arrival order never consumes this player's encounter slot")
        let rows = BoundSoulEncounter.rows(ledger: value, areas: [])
        XCTAssertTrue(rows.first { $0.slot == "egg:3" }?.occupied == true)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any])
        legacy.removeValue(forKey: "consumedSlots")
        XCTAssertTrue(try JSONDecoder().decode(BoundSoulLedger.self, from: JSONSerialization.data(withJSONObject: legacy)).valid)
    }
    func testIndependentSaveRestoreMergesPermanentLossesAndConsumedSlots() throws {
        var old = makeLedger()
        try old.observe([mon(1)], registering: true, fainted: [])
        var current = old
        try current.observe([mon(2, area: 101), mon(3, egg: true, isEgg: true)], registering: true, fainted: [])
        try current.observe([mon(1, hp: 0)], registering: true, fainted: [])
        current.partnerAcquisitions = ["area:101"]
        let encoder = JSONEncoder()
        let bytes = try BoundSoulLedger.mergeForIndependentRestore(current: encoder.encode(current), incoming: encoder.encode(old))
        var restored = try JSONDecoder().decode(BoundSoulLedger.self, from: bytes)
        XCTAssertEqual(restored.dead, ["area:100"])
        XCTAssertEqual(restored.nextEgg, 2)
        XCTAssertEqual(restored.partnerSlots, ["area:101"])
        try restored.observe([mon(1), mon(4, area: 101)], registering: true, fainted: [])
        XCTAssertTrue(restored.denied.contains(mon(1).identity))
        XCTAssertTrue(restored.denied.contains(mon(4).identity), "Rewinding cannot replace the area's already consumed identity")
        var incoming = old
        incoming.dead.insert("area:102")
        let combined = try JSONDecoder().decode(BoundSoulLedger.self, from: BoundSoulLedger.mergeForIndependentRestore(current: encoder.encode(current), incoming: encoder.encode(incoming)))
        XCTAssertEqual(combined.dead, ["area:100", "area:102"])
        XCTAssertThrowsError(try BoundSoulLedger.mergeForIndependentRestore(current: encoder.encode(current), incoming: encoder.encode(makeLedger())))
    }
    func testRemoteLossPolicyWaitsForNativeSafeFieldBoundary() {
        XCTAssertFalse(BoundSoulProbe.mayApplyNativePolicy(ready: false, battle: true))
        XCTAssertFalse(BoundSoulProbe.mayApplyNativePolicy(ready: false, battle: false))
        XCTAssertFalse(BoundSoulProbe.mayApplyNativePolicy(ready: true, battle: true))
        XCTAssertTrue(BoundSoulProbe.mayApplyNativePolicy(ready: true, battle: false))
    }
    @MainActor
    func testIncomingInvitationSurvivesRetriesAndDisconnectUntilExplicitAnswer() throws {
        let old = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(old, forKey: BoundMultiplayerFeatures.key) }
        var time:TimeInterval=100,online=true
        let session=BoundSoulSession(clock:{ time }),run=UUID(),sender=UUID()
        session.setConnection(owner:"A",room:UUID().uuidString)
        session.connected={ online };session.qaPermitIncomingInvitation()
        var replies:[BoundSoulPacket]=[]
        session.send={ data in if let packet=BoundSoulPacket.decode(data) { replies.append(packet) };return online }
        let offer=try XCTUnwrap(BoundSoulPacket(version:2,run:run,kind:.offer,rows:[],sender:sender).encoded())
        session.receive(offer)
        XCTAssertEqual(session.incoming,run)
        for _ in 0..<3 { session.receive(offer) }
        XCTAssertEqual(session.incoming,run);XCTAssertFalse(replies.contains(where:{ $0.kind == .decline }))
        online=false;session.peerGone();time+=3600;session.tick()
        XCTAssertEqual(session.incoming,run)
        online=true;session.receive(offer)
        XCTAssertEqual(session.incoming,run)
        session.decline();XCTAssertNil(session.incoming)
        replies=[];session.receive(offer)
        XCTAssertNil(session.incoming);XCTAssertEqual(replies.last?.kind,.decline)
        // Deliberate sender cancellation also closes a prompt before the pose
        // challenge has finished, while an unrelated run cannot close it.
        let next=UUID();session.qaPermitIncomingInvitation()
        session.receive(try XCTUnwrap(BoundSoulPacket(version:2,run:next,kind:.offer,rows:[],sender:sender).encoded()))
        session.receive(try XCTUnwrap(BoundSoulPacket(version:2,run:UUID(),kind:.decline,rows:[],sender:sender).encoded()))
        XCTAssertEqual(session.incoming,next)
        session.receive(try XCTUnwrap(BoundSoulPacket(version:2,run:next,kind:.decline,rows:[],sender:sender).encoded()))
        XCTAssertNil(session.incoming)
    }
    @MainActor
    func testDisconnectedSoulLinkContinuesWithoutPauseBannerOrRecoveryBarrier() throws {
        let old = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(old, forKey: BoundMultiplayerFeatures.key) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var value = makeLedger(); try value.observe([mon(1)], registering: true, fainted: [])
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        let session = BoundSoulSession(probe: probe)
        var banner: String? = "unread"
        session.bannerChanged = { banner = $0 }
        session.connected = { false }
        session.peerGone(); session.tick()
        XCTAssertTrue(session.active)
        XCTAssertFalse(session.paired)
        XCTAssertEqual(session.status, "Soul Link active · Sync pending")
        XCTAssertNil(banner)
        XCTAssertNil(session.recoveryError)
        XCTAssertEqual(probe.sharedEvents().map(\.id), value.sharedEvents.map(\.id))
    }
    func testMalformedOrWrongVersionNetworkRowsAreRejected() throws {
        let valid = BoundSoulPacket(version: 2, run: UUID(), kind: .state, rows: [.init(slot: "egg:1", name: "Egg", dead: true)])
        XCTAssertNotNil(BoundSoulPacket.decode(try XCTUnwrap(valid.encoded())))
        for slot in ["area:-1", "area:256", "egg:0", "egg:9000", "area:001", "route:1"] {
            let bad = BoundSoulPacket(version: 2, run: UUID(), kind: .state, rows: [.init(slot: slot, name: "Mon", dead: true)])
            XCTAssertNil(bad.encoded())
        }
        XCTAssertNil(BoundSoulPacket.decode(Data(repeating: 1, count: 1025)))
    }
    func testIdentitySortMatchesNativeBinarySearchAndEvolutionKeepsSlot() throws {
        let ids = [BoundSoulIdentity(personality: 1, trainer: 4), .init(personality: 2, trainer: 1), .init(personality: 1, trainer: 2)]
        XCTAssertEqual(ids.sorted().map(\.trainer), [2, 4, 1])
        for id in ids { XCTAssertEqual(BoundSoulIdentity.read(id.bytes, at: 0), id) }
    }
    func testPartnerLossesCommitBeforePublicationAndRecoverAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("run.json")
        var local = makeLedger(); try local.observe([mon(1)], registering: true, fainted: [])
        try JSONEncoder().encode(local).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        var partner = makeLedger(); partner.dead = ["area:100", "egg:2048"]
        try probe.merge(run: UUID(), rows: [], losses: partner.lossBits)
        XCTAssertEqual(probe.read().ledger?.dead, [])
        try probe.merge(run: local.run, rows: [], losses: partner.lossBits)
        let reopened = BoundSoulProbe(); reopened.configure(core: nil, url: file)
        XCTAssertEqual(reopened.read().ledger?.dead, partner.dead)
        XCTAssertTrue(reopened.read().ledger?.denied.contains(mon(1).identity) == true)
        try reopened.merge(run: local.run, rows: [], losses: Data(repeating: 0, count: 288))
        XCTAssertEqual(reopened.read().ledger?.dead, partner.dead, "Old/alive packets cannot remove tombstones")
    }
    func testInvitationSurvivesRestartAndAcceptedRunCannotBeCancelledAsAnOffer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("run.json")
        var value = makeLedger(); value.offering = true
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        XCTAssertEqual(probe.read().ledger?.offering, true)
        try probe.markAccepted()
        let reopened = BoundSoulProbe(); reopened.configure(core: nil, url: file)
        XCTAssertEqual(reopened.read().ledger?.offering, false)
        try reopened.cancelOffer()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testUnreadableRunFailsClosedAndIsPreserved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("invalid ledger".utf8); try original.write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        XCTAssertNotNil(probe.read().error); XCTAssertNil(probe.read().ledger)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testFailedRemoteDeathWriteLatchesPauseAndKeepsPreviousRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("run.json")
        var value = makeLedger(); try value.observe([mon(1)], registering: true, fainted: [])
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var peer = makeLedger(); peer.dead.insert("area:100")
        XCTAssertThrowsError(try probe.merge(run: value.run, rows: [], losses: peer.lossBits))
        XCTAssertNotNil(probe.read().error, "A later heartbeat must not resume an unsaved remote death")
        XCTAssertEqual(probe.read().ledger, value)
    }
    @MainActor
    func testPairedSessionsRequireFreshChallengeAndCarryLossesAcrossReconnect() throws {
        let old = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(old, forKey: BoundMultiplayerFeatures.key) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID(), aProbe = BoundSoulProbe(), bProbe = BoundSoulProbe()
        let room = UUID().uuidString
        var left = BoundSoulLedger(run: run, binding: BoundSoulSession.hash("A:" + room))
        var right = BoundSoulLedger(run: run, binding: BoundSoulSession.hash("B:" + room))
        try left.observe([mon(1)], registering: true, fainted: [])
        try right.observe([mon(2)], registering: true, fainted: [])
        let aURL = root.appendingPathComponent("a.json"), bURL = root.appendingPathComponent("b.json")
        try JSONEncoder().encode(left).write(to: aURL); try JSONEncoder().encode(right).write(to: bURL)
        aProbe.configure(core: nil, url: aURL); bProbe.configure(core: nil, url: bURL)
        var time = ProcessInfo.processInfo.systemUptime
        let a = BoundSoulSession(probe: aProbe, clock: { time }), b = BoundSoulSession(probe: bProbe, clock: { time })
        a.canPresentDeathMoment = { true }; b.canPresentDeathMoment = { true }
        a.setConnection(owner: "A", room: room); b.setConnection(owner: "B", room: room)
        a.connected = { true }; b.connected = { true }
        var ab: [Data] = [], ba: [Data] = []
        a.send = { ab.append($0); return true }; b.send = { ba.append($0); return true }
        for _ in 0..<3 {
            time += 0.3; a.tick(); b.tick()
            let aa = ab, bb = ba; ab.removeAll(); ba.removeAll()
            aa.forEach { b.receive($0) }; bb.forEach { a.receive($0) }
        }
        XCTAssertTrue(a.paired); XCTAssertTrue(b.paired)
        time += 0.3; a.tick(); let oldAlive = try XCTUnwrap(ab.last); ab.removeAll()
        a.peerGone(); b.peerGone()
        b.receive(oldAlive); XCTAssertFalse(b.paired, "Old pre-disconnect packets cannot resume play")
        var death = left; death.dead.insert("area:100")
        try aProbe.merge(run: run, rows: [], losses: death.lossBits)
        for _ in 0..<5 {
            time += 0.3; a.tick(); b.tick()
            let aa = ab, bb = ba; ab.removeAll(); ba.removeAll()
            aa.forEach { b.receive($0) }; bb.forEach { a.receive($0) }
        }
        XCTAssertTrue(a.paired); XCTAssertTrue(b.paired)
        XCTAssertEqual(bProbe.read().ledger?.dead, ["area:100"])
        XCTAssertTrue(bProbe.read().ledger?.denied.contains(mon(2).identity) == true)
        a.tick(); b.tick()
        XCTAssertEqual(a.deathMoment?.slot, "area:100"); XCTAssertEqual(b.deathMoment?.slot, "area:100")
        a.dismissDeathMoment(); b.dismissDeathMoment()
        b.receive(oldAlive); a.tick(); b.tick()
        XCTAssertNil(a.deathMoment); XCTAssertNil(b.deathMoment)
        XCTAssertEqual(a.graveyard.count, 1); XCTAssertEqual(b.graveyard.count, 1)
        XCTAssertEqual(bProbe.read().ledger?.dead, ["area:100"])
        a.endRun()
        let aa = ab; ab.removeAll(); aa.forEach { b.receive($0) }
        XCTAssertEqual(bProbe.read().ledger?.ended, true)
    }
    func testCompleteAcquisitionsFitAlongsideLossesAndUnicodeNames() throws {
        let slots = Set((0..<2304).map { $0 < 256 ? "area:\($0)" : "egg:\($0 - 255)" })
        let bits = BoundSoulLedger.bits(slots)
        let packet = BoundSoulPacket(version: 2, run: UUID(), kind: .state,
            rows: ["area:0", "area:255", "egg:2048"].map { .init(slot: $0, name: String(repeating: "🐉", count: 20), dead: true) },
            losses: bits, acquired: bits, receiver: UUID())
        let data = try XCTUnwrap(packet.encoded())
        XCTAssertLessThanOrEqual(data.count, 1024)
        let decoded = try XCTUnwrap(BoundSoulPacket.decode(data))
        XCTAssertEqual(decoded.acquired, bits); XCTAssertEqual(decoded.losses, bits)
        XCTAssertEqual(decoded.rows, packet.rows); XCTAssertEqual(decoded.receiver, packet.receiver)
        XCTAssertEqual(decoded.run, packet.run); XCTAssertEqual(decoded.sender, packet.sender)
        XCTAssertEqual(BoundSoulLedger.losses(decoded.acquired), slots)
        for kind in BoundSoulPacket.Kind.allCases {
            let empty = BoundSoulPacket(version: 2, run: packet.run, kind: kind)
            XCTAssertEqual(BoundSoulPacket.decode(try XCTUnwrap(empty.encoded()))?.kind, kind)
        }
    }
    func testTruncatedMalformedAndLegacyPacketsCannotBecomeCatchEvidence() throws {
        let packet = BoundSoulPacket(version: 2, run: UUID(), kind: .state,
            rows: [.init(slot: "area:100", name: "Catch", dead: false)])
        let data = try XCTUnwrap(packet.encoded())
        for count in 0..<data.count { XCTAssertNil(BoundSoulPacket.decode(Data(data.prefix(count)))) }
        for (index, byte) in [(3, UInt8(0x31)), (4, 1), (5, 99), (38, 2), (631, 9), (633, 255), (634, 2), (635, 255)] {
            var bad = data; bad[index] = byte; XCTAssertNil(BoundSoulPacket.decode(bad))
        }
        var extra = data; extra.append(0); XCTAssertNil(BoundSoulPacket.decode(extra))
        var invalidUTF8 = data; invalidUTF8[636] = 255; XCTAssertNil(BoundSoulPacket.decode(invalidUTF8))
        XCTAssertNil(BoundSoulPacket(version: 1, run: UUID(), kind: .state).encoded())
    }
    func testPartnerOnlyCatchAndPairStatusSurviveRestartAndEmptyPackets() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var local = makeLedger(); try local.observe([mon(1), mon(2, area: 101)], registering: true, fainted: [])
        try JSONEncoder().encode(local).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        let partnerSlots: Set<String> = ["area:100", "area:102", "egg:1"]
        try probe.merge(run: local.run, rows: [.init(slot: "area:100", name: "Buddy", dead: false)],
                        losses: local.lossBits, acquired: BoundSoulLedger.bits(partnerSlots))
        let reopened = BoundSoulProbe(); reopened.configure(core: nil, url: file)
        var value = try XCTUnwrap(reopened.read().ledger)
        let rows = BoundSoulEncounter.rows(ledger: value, areas: [100,101,102,103])
        XCTAssertEqual(rows.first { $0.slot == "area:100" }?.state, .linked)
        XCTAssertEqual(rows.first { $0.slot == "area:100" }?.partnerName, "Buddy")
        XCTAssertEqual(rows.first { $0.slot == "area:101" }?.state, .localOnly)
        XCTAssertEqual(rows.first { $0.slot == "area:102" }?.state, .partnerOnly)
        XCTAssertEqual(rows.first { $0.slot == "area:102" }?.partnerName, "Pokémon", "Names may arrive after full catch evidence")
        XCTAssertEqual(rows.first { $0.slot == "area:103" }?.state, .available)
        XCTAssertEqual(rows.first { $0.slot == "egg:1" }?.state, .partnerOnly)
        try reopened.merge(run: local.run, rows: [], losses: local.lossBits, acquired: Data(repeating: 0, count: 288))
        XCTAssertEqual(reopened.read().ledger?.partnerSlots, partnerSlots)
        value.dead.insert("area:102")
        try reopened.merge(run: local.run, rows: [], losses: value.lossBits)
        XCTAssertEqual(BoundSoulEncounter.rows(ledger: try XCTUnwrap(reopened.read().ledger), areas: []).first { $0.slot == "area:102" }?.state, .lost)
        XCTAssertThrowsError(try reopened.merge(run: local.run, rows: [], losses: value.lossBits, acquired: Data([1])))
    }
    func testOldJournalLoadsWithoutLosingEligibilityOrDeaths() throws {
        var value = makeLedger(); try value.observe([mon(1)], registering: true, fainted: [])
        value.dead.insert("area:100")
        let data = try JSONEncoder().encode(value)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "partnerAcquisitions"); json.removeValue(forKey: "partnerNames")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder().decode(BoundSoulLedger.self, from: legacy)
        XCTAssertTrue(restored.valid); XCTAssertEqual(restored.records, value.records); XCTAssertEqual(restored.dead, value.dead)
        XCTAssertEqual(restored.partnerSlots, []); XCTAssertEqual(restored.acquisitionBits, value.acquisitionBits)
    }
    @MainActor
    func testPairedAcquisitionsArriveBeforeRotatingNamesAndRejectWrongRoom() throws {
        let old = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(old, forKey: BoundMultiplayerFeatures.key) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID(), room = UUID().uuidString
        var left = BoundSoulLedger(run: run, binding: BoundSoulSession.hash("A:" + room))
        var right = BoundSoulLedger(run: run, binding: BoundSoulSession.hash("B:" + room))
        try left.observe((1...12).map { mon(UInt32($0), area: 99 + $0) }, registering: true, fainted: [])
        try right.observe([mon(99), mon(100, area: 120)], registering: true, fainted: [])
        let aURL = root.appendingPathComponent("a.json"), bURL = root.appendingPathComponent("b.json")
        try JSONEncoder().encode(left).write(to: aURL); try JSONEncoder().encode(right).write(to: bURL)
        let ap = BoundSoulProbe(), bp = BoundSoulProbe(); ap.configure(core: nil, url: aURL); bp.configure(core: nil, url: bURL)
        var time = ProcessInfo.processInfo.systemUptime
        let a = BoundSoulSession(probe: ap, clock: { time }), b = BoundSoulSession(probe: bp, clock: { time })
        a.setConnection(owner: "A", room: room); b.setConnection(owner: "B", room: room)
        a.connected = { true }; b.connected = { true }
        var ab: [Data] = [], ba: [Data] = []
        a.send = { ab.append($0); return true }; b.send = { ba.append($0); return true }
        for _ in 0..<2 {
            time += 0.3; a.tick(); b.tick()
            let aa = ab, bb = ba; ab.removeAll(); ba.removeAll(); aa.forEach { b.receive($0) }; bb.forEach { a.receive($0) }
        }
        XCTAssertTrue(a.paired); XCTAssertTrue(b.paired)
        XCTAssertEqual(bp.read().ledger?.partnerSlots, left.acquired, "All twelve catches arrive in one fresh packet, independent of three rotating names")
        XCTAssertLessThan(bp.read().ledger?.partnerNames?.count ?? 0, 12)
        XCTAssertEqual(a.encounters.first { $0.slot == "area:120" }?.state, .partnerOnly)
        for _ in 0..<5 {
            time += 0.3; a.tick(); b.tick()
            let aa = ab, bb = ba; ab.removeAll(); ba.removeAll(); aa.forEach { b.receive($0) }; bb.forEach { a.receive($0) }
        }
        XCTAssertEqual(bp.read().ledger?.partnerNames?.count, 12)
        let reopened = BoundSoulProbe(); reopened.configure(core: nil, url: bURL)
        XCTAssertEqual(reopened.read().ledger?.partnerSlots, left.acquired)
        a.peerGone(); b.peerGone()
        XCTAssertEqual(b.encounters.filter { $0.state == .partnerOnly }.count, 11)
        time += 0.3; a.tick(); let packet = try XCTUnwrap(ab.last)
        b.setConnection(owner: "B", room: "different"); b.receive(packet)
        XCTAssertEqual(bp.read().ledger, reopened.read().ledger, "A different room cannot alter this run")
    }
    @MainActor
    func testPairedEncounterScreenRendersBothSidesAndAvailableAreas() throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PairedEncounterQA")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var ledger = makeLedger()
        try ledger.observe([mon(1), mon(2, area: 101)], registering: true, fainted: [])
        ledger.partnerAcquisitions = ["area:100", "area:102"]; ledger.partnerNames = ["area:100":"Buddy", "area:102":"Partner catch"]
        let journal = root.appendingPathComponent("render-run.json"); try JSONEncoder().encode(ledger).write(to: journal)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: journal)
        let session = BoundSoulSession(probe: probe, areaNames: [100:"Route 2", 101:"Viridian Forest", 102:"Route 3", 103:"Route 4"])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack { BoundSoulEncountersView(session: session) })
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent("paired-encounters.png"))
        let attachment = XCTAttachment(image: image); attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true; previous?.makeKeyAndVisible()
        XCTAssertEqual(session.encounters.map(\.state).filter { $0 == .linked }.count, 1)
        XCTAssertEqual(session.encounters.first { $0.slot == "area:103" }?.state, .available)
    }
    @MainActor
    func testLegacyPeerNeedsUpdateWithoutPausingTheLocalRun() throws {
        let old = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(old, forKey: BoundMultiplayerFeatures.key) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var value = makeLedger(); try value.observe([mon(1)], registering: true, fainted: [])
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        let session = BoundSoulSession(probe: probe); session.setConnection(owner: "A", room: "room"); session.connected = { true }
        var banner: String? = "unread"; session.bannerChanged = { banner = $0 }
        session.receive(BoundSoulPacket.legacyPrefix + Data("old packet".utf8)); session.tick()
        XCTAssertTrue(session.status.contains("Partner update required")); XCTAssertFalse(session.paired)
        XCTAssertTrue(session.active); XCTAssertNil(session.recoveryError); XCTAssertNil(banner)
        session.peerGone(); session.tick(); XCTAssertFalse(session.status.contains("Partner update required"))
        XCTAssertTrue(session.active); XCTAssertNil(session.recoveryError)
    }
    func testUnsyncedPartnerIsNeverPresentedAsAnAvailableCatch() throws {
        var ledger = makeLedger(); try ledger.observe([mon(1)], registering: true, fainted: [])
        let unsynced = BoundSoulEncounter.rows(ledger: ledger, areas: [100,101])
        XCTAssertTrue(unsynced.allSatisfy { $0.state == .syncing })
        XCTAssertEqual(unsynced.filter(\.occupied).count, 1)
        ledger.partnerAcquisitions = []
        let synced = BoundSoulEncounter.rows(ledger: ledger, areas: [100,101])
        XCTAssertEqual(synced.first { $0.slot == "area:100" }?.state, .localOnly)
        XCTAssertEqual(synced.first { $0.slot == "area:101" }?.state, .available)
    }
    func testNativeFaintCreatesOnePersistentMemorialAndHealingNeverRepeatsIt() throws {
        var value = makeLedger(); value.partnerAcquisitions = ["area:100"]; value.partnerNames = ["area:100":"Buddy"]
        try value.observe([mon(1)], registering: true, fainted: [])
        try value.observe([mon(1, hp: 0)], registering: false, fainted: [])
        let first = try XCTUnwrap(value.memorials?.first)
        XCTAssertEqual(first.names, "Mon1 ↔ Buddy"); XCTAssertFalse(first.announced); XCTAssertNotNil(first.recordedAt)
        try value.observe([mon(1, hp: 30)], registering: true, fainted: [])
        try value.observe([mon(1, hp: 0)], registering: false, fainted: [mon(1).identity])
        XCTAssertEqual(value.memorials, [first]); XCTAssertEqual(value.denied, [mon(1).identity])
        let restored = try JSONDecoder().decode(BoundSoulLedger.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.memorials, [first]); XCTAssertTrue(restored.valid)
    }
    func testLatePartnerNameEnrichesMemorialWithoutRenamingOrReplayingIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var value = makeLedger(); try value.observe([mon(1)], registering: true, fainted: [])
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        let bits = BoundSoulLedger.bits(["area:100"])
        try probe.merge(run: value.run, rows: [], losses: bits, acquired: bits)
        XCTAssertEqual(probe.read().ledger?.memorials?.first?.partnerLabel, "Partner’s Pokémon")
        try probe.acknowledgeDeath(run: value.run, slot: "area:100")
        try probe.merge(run: value.run, rows: [.init(slot: "area:100", name: "Buddy", dead: true)], losses: bits, acquired: bits)
        XCTAssertEqual(probe.read().ledger?.memorials?.first?.partnerName, "Buddy")
        try probe.merge(run: value.run, rows: [.init(slot: "area:100", name: "Renamed", dead: false)], losses: bits, acquired: bits)
        XCTAssertEqual(probe.read().ledger?.memorials?.first?.partnerName, "Buddy")
        XCTAssertEqual(probe.read().ledger?.memorials?.first?.announced, true)
        XCTAssertEqual(probe.read().ledger?.memorials?.count, 1)
    }
    func testLegacyDeathsBecomeQuietHistoryAndNewLossesStillAnnounce() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var value = makeLedger(); value.dead = ["area:100"]
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        let historical = try XCTUnwrap(probe.read().ledger?.memorials?.first)
        XCTAssertTrue(historical.announced); XCTAssertNil(historical.recordedAt)
        try probe.merge(run: value.run, rows: [], losses: BoundSoulLedger.bits(["area:100","area:101"]))
        let pending = try XCTUnwrap(probe.read().ledger?.memorials?.filter { !$0.announced })
        XCTAssertEqual(pending.map(\.slot), ["area:101"])
        XCTAssertEqual(probe.read().ledger?.memorials?.count, 2)
    }
    func testAcknowledgementSurvivesRestartAndCannotAffectAnotherRun() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var value = makeLedger(); try value.observe([mon(1, hp: 0)], registering: true, fainted: [])
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        XCTAssertFalse(try XCTUnwrap(probe.read().ledger?.memorials?.first).announced)
        try probe.acknowledgeDeath(run: UUID(), slot: "area:100")
        XCTAssertFalse(try XCTUnwrap(probe.read().ledger?.memorials?.first).announced)
        try probe.acknowledgeDeath(run: value.run, slot: "area:100")
        let reopened = BoundSoulProbe(); reopened.configure(core: nil, url: file)
        XCTAssertTrue(try XCTUnwrap(reopened.read().ledger?.memorials?.first).announced)
        XCTAssertEqual(reopened.read().ledger?.dead, ["area:100"])
    }
    func testFailedAcknowledgementRetainsPendingMomentAndLatchesPause() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("run.json")
        var value = makeLedger(); try value.observe([mon(1, hp: 0)], registering: true, fainted: [])
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try probe.acknowledgeDeath(run: value.run, slot: "area:100"))
        XCTAssertNotNil(probe.read().error); XCTAssertEqual(probe.read().ledger, value)
    }
    @MainActor
    func testDeathQueueWaitsForGameplayAndAcknowledgesEachVisibleMomentOnce() throws {
        let old = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(old, forKey: BoundMultiplayerFeatures.key) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var value = makeLedger(); try value.observe([mon(1, hp: 0), mon(2, area: 101, hp: 0)], registering: true, fainted: [])
        try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        var time: TimeInterval = 100, visible = false
        let session = BoundSoulSession(probe: probe, clock: { time })
        session.canPresentDeathMoment = { visible }
        session.tick(); XCTAssertNil(session.deathMoment)
        visible = true; session.tick(); XCTAssertEqual(session.deathMoment?.slot, "area:100")
        time += 3; visible = false; session.tick(); XCTAssertNil(session.deathMoment)
        XCTAssertFalse(try XCTUnwrap(probe.read().ledger?.memorials?.first).announced)
        time += 100; visible = true; session.tick(); XCTAssertEqual(session.deathMoment?.slot, "area:100")
        time += 6.9; session.tick(); XCTAssertEqual(session.deathMoment?.slot, "area:100")
        time += 0.2; session.tick(); XCTAssertEqual(session.deathMoment?.slot, "area:101")
        session.dismissDeathMoment(); session.tick(); XCTAssertNil(session.deathMoment)
        XCTAssertTrue(session.graveyard.allSatisfy(\.announced))
        session.peerGone(); session.tick(); XCTAssertNil(session.deathMoment)
        XCTAssertEqual(session.graveyard.count, 2)
    }
    @MainActor
    func testDeathMomentAndGraveyardRender() throws {
        let old = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(old, forKey: BoundMultiplayerFeatures.key) }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DeathMomentQA")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var value = makeLedger(); value.partnerAcquisitions = ["area:100"]; value.partnerNames = ["area:100":"Bulbasaur"]
        try value.observe([mon(1, hp: 0)], registering: true, fainted: [])
        let file = root.appendingPathComponent("render-run.json"); try JSONEncoder().encode(value).write(to: file)
        let probe = BoundSoulProbe(); probe.configure(core: nil, url: file)
        let session = BoundSoulSession(probe: probe, areaNames: [100:"Route 2"])
        session.canPresentDeathMoment = { true }; session.tick()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        func capture<V: View>(_ view: V, name: String) throws {
            let host = UIHostingController(rootView: view); window.rootViewController = host
            window.makeKeyAndVisible(); host.view.layoutIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(image: image); attachment.name = name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        try capture(VStack { BoundSoulDeathNotice(session: session); Spacer() }.padding(20).background(Color.gray.opacity(0.15)), name: "death-moment")
        session.dismissDeathMoment()
        try capture(NavigationStack { BoundSoulGraveyardView(session: session) }, name: "graveyard")
        window.isHidden = true; previous?.makeKeyAndVisible()
        XCTAssertEqual(session.graveyard.count, 1); XCTAssertNil(session.deathMoment)
    }
    private func teamMember(slot: String? = "area:100", name: String = "Bulbasaur", hp: Int = 30) -> BoundSoulTeamMember {
        .init(slot: slot, name: name, species: 1, level: 12, hp: hp, maxHP: 40)
    }
    func testTeamCaptureKeepsPartyOrderBoxesAliasesAndExcludedCatches() throws {
        var ledger = makeLedger()
        let party = BoundSoulMon(identity: mon(1).identity, species: 1, name: "Starter", area: 100, eggOrigin: false, isEgg: false, hp: 30, level: 12, maxHP: 40, inParty: true)
        let extra = BoundSoulMon(identity: mon(2).identity, species: 4, name: "Extra", area: 100, eggOrigin: false, isEgg: false, hp: 30, level: 10, maxHP: 35, inParty: true)
        let boxed = mon(3, area: 101, hp: nil)
        let egg = BoundSoulMon(identity: mon(4).identity, species: 25, name: "Egg", area: 102, eggOrigin: true, isEgg: true, hp: 0, level: 1, maxHP: 10, inParty: true)
        try ledger.observe([party,extra,boxed,egg], registering: true, fainted: [])
        XCTAssertEqual(try XCTUnwrap(BoundSoulTeam.capture(mons: [party,party], ledger: ledger)).party.compactMap(\.slot),["area:100"])
        let team = try XCTUnwrap(BoundSoulTeam.capture(mons: [party,extra,boxed,egg], ledger: ledger))
        XCTAssertEqual(team.party.map(\.name), ["Starter","Extra","Egg"])
        XCTAssertEqual(team.party[0].slot,"area:100"); XCTAssertNil(team.party[1].slot); XCTAssertTrue(team.party[1].barred)
        XCTAssertEqual(BoundSoulLedger.losses(team.boxed),["area:101"])
        XCTAssertEqual(team.party[2].species,0); XCTAssertNil(team.party[2].level); XCTAssertNil(team.party[2].hp)
        ledger.dead.insert("area:100")
        XCTAssertTrue(try XCTUnwrap(BoundSoulTeam.capture(mons: [party], ledger: ledger)).party[0].barred)
    }
    func testTeamPacketCarriesSixMembersAndCompleteBoxesWithinLimit() throws {
        let party = (0..<6).map { teamMember(slot:"area:\($0)", name:String(repeating:"🐉",count:20),hp:$0) }
        let team = BoundSoulTeam(party:party,boxed:BoundSoulLedger.bits(["area:255","egg:2048"]))
        let packet = BoundSoulTeamPacket(run:UUID(),sender:UUID(),receiver:UUID(),sequence:123,team:team)
        let data = try XCTUnwrap(packet.encoded()); XCTAssertLessThanOrEqual(data.count,1024)
        let decoded = try XCTUnwrap(BoundSoulTeamPacket.decode(data))
        XCTAssertEqual(decoded.team,team); XCTAssertEqual(decoded.run,packet.run); XCTAssertEqual(decoded.sender,packet.sender)
        XCTAssertEqual(decoded.receiver,packet.receiver); XCTAssertEqual(decoded.sequence,123)
        XCTAssertTrue(BoundSoulPacket.recognizes(data))
        for count in 0..<data.count { XCTAssertNil(BoundSoulTeamPacket.decode(Data(data.prefix(count)))) }
        var trailing = data; trailing.append(0); XCTAssertNil(BoundSoulTeamPacket.decode(trailing))
        for (index,byte) in [(4,UInt8(2)),(61,2),(62,7),(352,255),(355,101),(360,4),(361,255),(362,255)] {
            var bad = data; bad[index] = byte; XCTAssertNil(BoundSoulTeamPacket.decode(bad))
        }
    }
    func testInvalidTeamDoesNotOverrideSharedRules() throws {
        var invalid = BoundSoulTeam(party:[teamMember(),teamMember()])
        XCTAssertFalse(invalid.valid)
        invalid = .init(party:[teamMember()],boxed:BoundSoulLedger.bits(["area:100"]))
        XCTAssertFalse(invalid.valid)
        var member = teamMember(); member.hp = 100; XCTAssertFalse(member.valid)
        member = teamMember(); member.name = ""; XCTAssertFalse(member.valid)
        let team = BoundSoulTeam(party:[teamMember()])
        XCTAssertNil(BoundSoulTeamPacket(run:UUID(),sender:UUID(),receiver:UUID(),sequence:0,team:team).encoded())
    }
    @MainActor
    func testPairedDashboardTracksTeamsRejectsReplayAndExpiresDisconnectedSnapshots() throws {
        let old = UserDefaults.standard.object(forKey:BoundMultiplayerFeatures.key); BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(old,forKey:BoundMultiplayerFeatures.key) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let run = UUID(), room = UUID().uuidString
        var left = BoundSoulLedger(run:run,binding:BoundSoulSession.hash("A:"+room))
        var right = BoundSoulLedger(run:run,binding:BoundSoulSession.hash("B:"+room))
        try left.observe([mon(1),mon(2,area:101)],registering:true,fainted:[])
        try right.observe([mon(3),mon(4,area:101)],registering:true,fainted:[])
        left.records[0].name = "Bulbasaur"; left.records[1].name = "Pikachu"
        right.records[0].name = "Charmander"; right.records[1].name = "Squirtle"
        let au = root.appendingPathComponent("a.json"), bu = root.appendingPathComponent("b.json")
        try JSONEncoder().encode(left).write(to:au); try JSONEncoder().encode(right).write(to:bu)
        let ap = BoundSoulProbe(),bp = BoundSoulProbe(); ap.configure(core:nil,url:au); bp.configure(core:nil,url:bu)
        var time = ProcessInfo.processInfo.systemUptime
        var at = BoundSoulProbe.Snapshot(),bt = BoundSoulProbe.Snapshot()
        at.ready = true; bt.ready = true
        at.team = .init(party:[teamMember()],boxed:BoundSoulLedger.bits(["area:101"]))
        bt.team = .init(party:[teamMember(name:"Charmander",hp:12)],boxed:BoundSoulLedger.bits(["area:101"]))
        bt.team?.party[0].species = 4
        let a = BoundSoulSession(probe:ap,clock:{time},areaNames:[100:"Route 2",101:"Viridian Forest"],teamSnapshot:{at})
        let b = BoundSoulSession(probe:bp,clock:{time},teamSnapshot:{bt})
        a.setConnection(owner:"A",room:room); b.setConnection(owner:"B",room:room)
        a.connected = {true}; b.connected = {true}
        var ab:[Data] = [],ba:[Data] = [],oldPacket:Data?
        a.send = {ab.append($0); return true}; b.send = {ba.append($0); return true}
        func pump(_ count:Int) {
            for _ in 0..<count {
                time += 0.4; at.teamCapturedAt = time; bt.teamCapturedAt = time
                a.tick(); b.tick(); let aa = ab,bb = ba; ab.removeAll(); ba.removeAll()
                if let packet = bb.last(where:{$0.starts(with:BoundSoulTeamPacket.prefix)}) {oldPacket = packet}
                aa.forEach {b.receive($0)}; bb.forEach {a.receive($0)}
            }
        }
        pump(5)
        XCTAssertEqual(a.partnerTeam?.party.first?.name,"Charmander"); XCTAssertTrue(a.partnerTeamCurrent)
        XCTAssertEqual(a.teamLocation(slot:"area:100",partner:true),"In party")
        XCTAssertEqual(a.teamLocation(slot:"area:101",partner:true),"Boxed")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous = scene.windows.first {$0.isKeyWindow},window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:NavigationStack {BoundSoulTeamDashboard(session:a)})
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        RunLoop.main.run(until:Date().addingTimeInterval(0.8))
        let image = UIGraphicsImageRenderer(bounds:window.bounds).image {_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
        let evidence = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("SharedTeamQA")
        try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
        try XCTUnwrap(image.pngData()).write(to:evidence.appendingPathComponent("two-player-dashboard.png"))
        let attachment = XCTAttachment(image:image); attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true; previous?.makeKeyAndVisible()
        let saved = try XCTUnwrap(oldPacket), prior = try XCTUnwrap(BoundSoulTeamPacket.decode(saved))
        bt.team?.party[0].hp = 5; pump(4)
        XCTAssertEqual(a.partnerTeam?.party.first?.hp,5)
        a.receive(saved); XCTAssertEqual(a.partnerTeam?.party.first?.hp,5)
        let wrongRun = try XCTUnwrap(BoundSoulTeamPacket(run:UUID(),sender:prior.sender,receiver:prior.receiver,sequence:999,team:prior.team).encoded())
        a.receive(wrongRun); XCTAssertEqual(a.partnerTeam?.party.first?.hp,5)
        let wrongReceiver = try XCTUnwrap(BoundSoulTeamPacket(run:run,sender:prior.sender,receiver:UUID(),sequence:999,team:prior.team).encoded())
        a.receive(wrongReceiver); XCTAssertEqual(a.partnerTeam?.party.first?.hp,5)
        let wrongSender = try XCTUnwrap(BoundSoulTeamPacket(run:run,sender:UUID(),receiver:prior.receiver,sequence:999,team:prior.team).encoded())
        a.receive(wrongSender); XCTAssertEqual(a.partnerTeam?.party.first?.hp,5)
        bt.ready = false; pump(3); XCTAssertFalse(a.partnerTeamCurrent, "Battle/menu data is never labelled live")
        bt.ready = true; pump(3); XCTAssertTrue(a.partnerTeamCurrent)
        // A fresh loss overrides a formerly healthy team display immediately.
        try ap.merge(run:run,rows:[],losses:BoundSoulLedger.bits(["area:100"]))
        a.tick(); XCTAssertEqual(a.teamLocation(slot:"area:100",partner:true),"Fainted")
        time += 3.1; a.tick(); XCTAssertFalse(a.partnerTeamCurrent)
        XCTAssertEqual(a.teamLocation(slot:"area:101",partner:true),"Last seen: Boxed")
        a.peerGone(); a.receive(saved); XCTAssertNil(a.partnerTeam); XCTAssertFalse(a.partnerTeamCurrent)
        pump(5); XCTAssertNotNil(a.partnerTeam)
        a.receive(saved); XCTAssertEqual(a.partnerTeam?.party.first?.hp,5)
        a.endRun(); a.tick(); XCTAssertFalse(a.localTeamCurrent); XCTAssertFalse(a.partnerTeamCurrent)
        a.setConnection(owner:"A",room:"another room"); a.receive(saved); XCTAssertNil(a.partnerTeam)
    }
    @MainActor
    func testSharedTeamDashboardRendersLocalPartyAndExistingEncounters() throws {
        let old = UserDefaults.standard.object(forKey:BoundMultiplayerFeatures.key); BoundMultiplayerFeatures.setEnabled(true)
        defer {UserDefaults.standard.set(old,forKey:BoundMultiplayerFeatures.key)}
        let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("SharedTeamQA")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var value = makeLedger(); try value.observe([mon(1),mon(2,area:101)],registering:true,fainted:[])
        value.partnerAcquisitions = ["area:100"]; value.partnerNames = ["area:100":"Charmander"]
        let file = root.appendingPathComponent("render-run.json"); try JSONEncoder().encode(value).write(to:file)
        let probe = BoundSoulProbe(); probe.configure(core:nil,url:file)
        var snapshot = BoundSoulProbe.Snapshot(); snapshot.ready = true; snapshot.teamCapturedAt = ProcessInfo.processInfo.systemUptime
        snapshot.team = .init(party:[teamMember()],boxed:BoundSoulLedger.bits(["area:101"]))
        let session = BoundSoulSession(probe:probe,areaNames:[100:"Route 2",101:"Viridian Forest"],teamSnapshot:{snapshot}); session.tick()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous = scene.windows.first {$0.isKeyWindow},window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:NavigationStack {BoundSoulTeamDashboard(session:session)})
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        RunLoop.main.run(until:Date().addingTimeInterval(0.8))
        let image = UIGraphicsImageRenderer(bounds:window.bounds).image {_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
        try XCTUnwrap(image.pngData()).write(to:root.appendingPathComponent("shared-team.png"))
        let attachment = XCTAttachment(image:image); attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true; previous?.makeKeyAndVisible()
        XCTAssertEqual(session.localTeam?.party.count,1); XCTAssertEqual(session.encounters.count,2)
        XCTAssertEqual(session.teamLocation(slot:"area:101",partner:false),"Boxed")
    }
    func testPartyAndCompressedBoxFormatsAndEggMetadata() {
        var party = Data(repeating: 0, count: 100)
        party[0] = 1; party[4] = 42; party[19] = 2; party[32] = 1; party[69] = 100; party[70] = 5; party[84] = 14; party[86] = 30; party[88] = 60; party[8] = 187; party[9] = 255
        var box = Data(repeating: 0, count: 58)
        box.replaceSubrange(0..<28, with: party[0..<28]); box[28] = 1; box[51] = 100; box[52] = 5
        let a = BoundSoulMon.decode(party, stride: 100).first
        let b = BoundSoulMon.decode(box, stride: 58).first
        XCTAssertEqual(a?.identity, b?.identity); XCTAssertEqual(a?.area, b?.area); XCTAssertEqual(a?.name, "A")
        XCTAssertEqual(a?.level,14); XCTAssertEqual(a?.maxHP,60); XCTAssertEqual(a?.inParty,true); XCTAssertEqual(b?.inParty,false)
        XCTAssertEqual(a?.hp, 30); XCTAssertNil(b?.hp); XCTAssertEqual(a?.eggOrigin, false)
        party[70] = 0
        XCTAssertEqual(BoundSoulMon.decode(party, stride: 100).first?.eggOrigin, true)
        party[19] = 0; XCTAssertTrue(BoundSoulMon.decode(party, stride: 100).isEmpty)
    }
}

private final class SoulPipelineFixture: @unchecked Sendable {
    enum Failure: Error { case write, candidate }
    private let lock=NSLock()
    private var values:[Int]=[],staged=0,committed:[Int]=[],writes=0,pressures=0,failures=0
    private var failWrite=false,failCandidate=false
    func append(_ input:Int) { lock.lock();values.append(input);lock.unlock() }
    func candidate() throws->[Int]? {
        lock.lock();defer { lock.unlock() }
        if failCandidate { throw Failure.candidate }
        guard staged != values.count else { return nil };staged=values.count;return values
    }
    func write(_ value:[Int]) throws {
        lock.lock();defer { lock.unlock() };writes+=1
        if failWrite { throw Failure.write }
    }
    func commit(_ value:[Int]) { lock.lock();committed=value;lock.unlock() }
    func pressure() { lock.lock();pressures+=1;lock.unlock() }
    func failure() { lock.lock();failures+=1;lock.unlock() }
    func failing(write:Bool=false,candidate:Bool=false) { lock.lock();failWrite=write;failCandidate=candidate;lock.unlock() }
    func read()->(values:[Int],committed:[Int],writes:Int,pressures:Int,failures:Int) {
        lock.lock();defer { lock.unlock() };return(values,committed,writes,pressures,failures)
    }
}

extension SoulLinkTests {
    func testWorkerLedgerCommitPreservesCorruptTimelineDiagnosticAndBytes() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let ledger=root.appendingPathComponent("run.json"),history=root.appendingPathComponent("run.timeline.json")
        let original=Data("corrupt history retained".utf8);try original.write(to:history)
        let probe=BoundSoulProbe();XCTAssertTrue(probe.configure(core:nil,url:ledger))
        XCTAssertNotNil(probe.timeline.read().error)
        probe.timeline.append(id:"discarded",kind:.victory,title:"Must remain rejected")
        try probe.startPreparedRun(run:UUID(),binding:String(repeating:"a",count:64))
        XCTAssertNotNil(probe.read().ledger);XCTAssertNotNil(probe.timeline.read().error)
        XCTAssertTrue(probe.timeline.read().events.isEmpty)
        XCTAssertEqual(try Data(contentsOf:history),original)
    }
    func testWorkerLedgerCommitCannotClearTimelineCapacityFailure() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let ledger=root.appendingPathComponent("run.json"),history=root.appendingPathComponent("run.timeline.json")
        let events=(0..<20000).map { BoundRunEvent(id:"event-\($0)",date:Date(timeIntervalSince1970:1),kind:.victory,title:"Fixture",detail:"") }
        let original=try JSONEncoder().encode(BoundRunTimeline.Journal(events:events,known:[],initialized:true))
        try original.write(to:history)
        let probe=BoundSoulProbe();XCTAssertTrue(probe.configure(core:nil,url:ledger));XCTAssertNil(probe.timeline.read().error)
        probe.timeline.append(id:"overflow",kind:.victory,title:"Must remain rejected")
        XCTAssertNotNil(probe.timeline.read().error)
        try probe.startPreparedRun(run:UUID(),binding:String(repeating:"b",count:64))
        XCTAssertNotNil(probe.timeline.read().error);XCTAssertEqual(probe.timeline.read().events.count,20000)
        XCTAssertFalse(probe.timeline.read().events.contains { $0.id=="overflow" })
        XCTAssertEqual(try Data(contentsOf:history),original)
    }
    func testObservationPipelineFoldsWhileWriterIsSlowAndRetainsTimedOutCut() throws {
        let fixture=SoulPipelineFixture(),writing=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        defer { release.signal() }
        let pipeline=BoundSDKObservationPipeline<Int,[Int]>(capacity:4,reduce:{ fixture.append($0) },candidate:{ try fixture.candidate() },
            write:{ value in
                if value==[0] { writing.signal();release.wait() }
                try fixture.write(value)
            },committed:{ fixture.commit($0) },failed:{ _ in fixture.failure() },backpressure:{ fixture.pressure() })
        XCTAssertTrue(pipeline.submit(0));XCTAssertEqual(writing.wait(timeout:.now()+1),.success)
        for value in 1...20 { XCTAssertTrue(pipeline.submit(value));pipeline.inspect {} }
        XCTAssertEqual(fixture.read().values,Array(0...20))
        XCTAssertTrue(fixture.read().committed.isEmpty,"A compute result is not a storage receipt")
        XCTAssertThrowsError(try pipeline.flush(timeout:0.02))
        XCTAssertFalse(pipeline.status().drained)
        release.signal();try pipeline.flush(timeout:2)
        XCTAssertEqual(fixture.read().committed,Array(0...20))
        XCTAssertLessThanOrEqual(fixture.read().writes,2,"One in-flight value plus the complete latest aggregate")
        XCTAssertTrue(pipeline.status().drained)
    }
    func testObservationPipelineFailedWriterRetriesEveryOrderedFact() throws {
        let fixture=SoulPipelineFixture();fixture.failing(write:true)
        let pipeline=BoundSDKObservationPipeline<Int,[Int]>(capacity:8,reduce:{ fixture.append($0) },candidate:{ try fixture.candidate() },
            write:{ try fixture.write($0) },committed:{ fixture.commit($0) },failed:{ _ in fixture.failure() },backpressure:{ fixture.pressure() })
        for value in 1...6 { XCTAssertTrue(pipeline.submit(value)) }
        XCTAssertThrowsError(try pipeline.flush(timeout:1))
        XCTAssertTrue(fixture.read().committed.isEmpty)
        XCTAssertEqual(fixture.read().values,Array(1...6))
        fixture.failing();try pipeline.flush(timeout:2)
        XCTAssertEqual(fixture.read().committed,Array(1...6))
        XCTAssertTrue(pipeline.status().drained)
    }
    func testObservationPipelineSaturationRetainsHandoffAndBoundsBlockedReducerTimeout() throws {
        let fixture=SoulPipelineFixture(),reducing=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        defer { release.signal() }
        let pipeline=BoundSDKObservationPipeline<Int,[Int]>(capacity:2,reduce:{ value in
            if value==0 { reducing.signal();release.wait() };fixture.append(value)
        },candidate:{ try fixture.candidate() },write:{ try fixture.write($0) },committed:{ fixture.commit($0) },
            failed:{ _ in fixture.failure() },backpressure:{ fixture.pressure() })
        XCTAssertTrue(pipeline.submit(0));XCTAssertEqual(reducing.wait(timeout:.now()+1),.success)
        XCTAssertTrue(pipeline.submit(1));XCTAssertTrue(pipeline.submit(2))
        let retainedByOwner=3
        XCTAssertFalse(pipeline.submit(retainedByOwner));XCTAssertEqual(pipeline.status().queued,3)
        XCTAssertGreaterThanOrEqual(fixture.read().pressures,1)
        let start=ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try pipeline.flush(timeout:0.02))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,0.5,"Timed barrier cannot block on compute.sync")
        release.signal();try pipeline.flush(timeout:2)
        XCTAssertEqual(fixture.read().committed,[0,1,2])
        XCTAssertTrue(pipeline.submit(retainedByOwner));try pipeline.flush(timeout:2)
        XCTAssertEqual(fixture.read().committed,[0,1,2,3])
    }
    func testObservationPipelineCandidateFailureCannotReportDurableSuccess() throws {
        let fixture=SoulPipelineFixture();fixture.failing(candidate:true)
        let pipeline=BoundSDKObservationPipeline<Int,[Int]>(capacity:2,reduce:{ fixture.append($0) },candidate:{ try fixture.candidate() },
            write:{ try fixture.write($0) },committed:{ fixture.commit($0) },failed:{ _ in fixture.failure() },backpressure:{ fixture.pressure() })
        XCTAssertTrue(pipeline.submit(7));XCTAssertThrowsError(try pipeline.flush(timeout:1))
        XCTAssertFalse(pipeline.status().drained);XCTAssertTrue(fixture.read().committed.isEmpty)
        XCTAssertEqual(fixture.read().writes,0);XCTAssertEqual(fixture.read().values,[7])
    }
}

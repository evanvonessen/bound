import XCTest
import SwiftUI
@testable import Delta

final class SoulLinkTests: XCTestCase {
    private func mon(_ id: UInt32, area: Int = 100, egg: Bool = false, isEgg: Bool = false, hp: Int? = 30) -> BoundSoulMon {
        .init(identity: .init(personality: id, trainer: 42), species: 1, name: "Mon\(id)", area: area, eggOrigin: egg, isEgg: isEgg, hp: hp)
    }
    private func makeLedger() -> BoundSoulLedger { .init(run: UUID(), binding: String(repeating: "a", count: 64)) }
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
    func testLegacyPeerPausesWithUpdateMessageUntilReconnect() {
        let old = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(old, forKey: BoundMultiplayerFeatures.key) }
        let session = BoundSoulSession(); session.setConnection(owner: "A", room: "room"); session.connected = { true }
        session.receive(BoundSoulPacket.legacyPrefix + Data("old packet".utf8)); session.tick()
        XCTAssertTrue(session.status.contains("latest Bound")); XCTAssertFalse(session.paired)
        session.peerGone(); session.tick(); XCTAssertFalse(session.status.contains("latest Bound"))
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
    func testSoulPacketsUseAuthenticatedReliableMailboxIncludingLegacyUpdateNotice() throws {
        let callbacks = AgoraSharingCallbacks(remoteUID: 2) { _,_ in }
        let packet = try XCTUnwrap(BoundSoulPacket(version: 2, run: UUID(), kind: .state).encoded())
        callbacks.receiveInteraction(packet, uid: 99)
        XCTAssertTrue(callbacks.takeInteractions().messages.isEmpty)
        callbacks.receiveInteraction(packet, uid: 2)
        let legacy = BoundSoulPacket.legacyPrefix + Data("legacy state".utf8)
        callbacks.receiveInteraction(legacy, uid: 2)
        for index in 0..<100 { callbacks.receivePresence(Data([UInt8(index)]), uid: 2) }
        XCTAssertEqual(callbacks.takeInteractions().messages, [packet, legacy])
        XCTAssertEqual(callbacks.takeLatestPresence(), Data([99]))
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
    func testInvalidTeamDoesNotOverrideSharedRulesOrEnterMailbox() throws {
        var invalid = BoundSoulTeam(party:[teamMember(),teamMember()])
        XCTAssertFalse(invalid.valid)
        invalid = .init(party:[teamMember()],boxed:BoundSoulLedger.bits(["area:100"]))
        XCTAssertFalse(invalid.valid)
        var member = teamMember(); member.hp = 100; XCTAssertFalse(member.valid)
        member = teamMember(); member.name = ""; XCTAssertFalse(member.valid)
        let team = BoundSoulTeam(party:[teamMember()])
        XCTAssertNil(BoundSoulTeamPacket(run:UUID(),sender:UUID(),receiver:UUID(),sequence:0,team:team).encoded())
        let callbacks = AgoraSharingCallbacks(remoteUID:2) { _,_ in }
        let data = try XCTUnwrap(BoundSoulTeamPacket(run:UUID(),sender:UUID(),receiver:UUID(),sequence:1,team:team).encoded())
        callbacks.receiveInteraction(data,uid:99); XCTAssertTrue(callbacks.takeInteractions().messages.isEmpty)
        callbacks.receiveInteraction(data,uid:2); XCTAssertEqual(callbacks.takeInteractions().messages,[data])
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

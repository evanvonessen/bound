import XCTest
import SwiftUI
@testable import Delta

final class SoulLinkTests: XCTestCase {
    private func mon(_ id: UInt32, area: Int = 100, egg: Bool = false, isEgg: Bool = false, hp: Int? = 30) -> BoundSoulMon {
        .init(identity: .init(personality: id, trainer: 42), species: 1, name: "Mon\(id)", area: area, eggOrigin: egg, isEgg: isEgg, hp: hp)
    }
    private func makeLedger() -> BoundSoulLedger { .init(run: UUID(), binding: String(repeating: "a", count: 64)) }
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
        b.receive(oldAlive)
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
    func testPartyAndCompressedBoxFormatsAndEggMetadata() {
        var party = Data(repeating: 0, count: 100)
        party[0] = 1; party[4] = 42; party[19] = 2; party[32] = 1; party[69] = 100; party[70] = 5; party[86] = 30; party[88] = 60; party[8] = 187; party[9] = 255
        var box = Data(repeating: 0, count: 58)
        box.replaceSubrange(0..<28, with: party[0..<28]); box[28] = 1; box[51] = 100; box[52] = 5
        let a = BoundSoulMon.decode(party, stride: 100).first
        let b = BoundSoulMon.decode(box, stride: 58).first
        XCTAssertEqual(a?.identity, b?.identity); XCTAssertEqual(a?.area, b?.area); XCTAssertEqual(a?.name, "A")
        XCTAssertEqual(a?.hp, 30); XCTAssertNil(b?.hp); XCTAssertEqual(a?.eggOrigin, false)
        party[70] = 0
        XCTAssertEqual(BoundSoulMon.decode(party, stride: 100).first?.eggOrigin, true)
        party[19] = 0; XCTAssertTrue(BoundSoulMon.decode(party, stride: 100).isEmpty)
    }
}

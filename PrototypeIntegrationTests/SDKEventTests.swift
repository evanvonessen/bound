import Foundation
import XCTest
#if canImport(Delta)
@testable import Delta
#endif

final class SDKEventTests: XCTestCase {
    private let run = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
    private let owner = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let partner = UUID(uuidString: "66666666-7777-4888-8999-AAAAAAAAAAAA")!
    private let stranger = UUID(uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF")!
    private var scope: BoundSDKEventJournalRules.Scope { .init(run: run, owner: owner, partner: partner) }
    private var oldScope: Phase4EventOracle.Scope { .init(run: run, owner: owner, partner: partner) }
    private var journal: BoundSDKEventJournal { .init(run: run, owner: owner, partner: partner) }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func old<T: Encodable, U: Decodable>(_ value: T, as type: U.Type) throws -> U {
        try JSONDecoder().decode(type, from: encode(value))
    }
    private func event(_ sequence: UInt64, origin: UUID? = nil, kind: String = "sample", key: String? = nil) -> BoundSDKEvent {
        .init(run: run, id: .init(origin: origin ?? partner, sequence: sequence), kind: kind,
              payload: Data([UInt8(truncatingIfNeeded: sequence)]), idempotencyKey: key)
    }
    private func failure(_ operation: () throws -> Void) -> String? {
        do { try operation(); return nil }
        catch let error as BoundSDKEventJournalRules.Failure { return String(describing: error) }
        catch let error as Phase4EventOracle.Failure { return String(describing: error) }
        catch { XCTFail("Unexpected error: \(error)"); return "unexpected" }
    }
    private func equivalent(_ current: BoundSDKEventJournal, _ frozen: Phase4EventJournal,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        // Multi-element Set encoding has no canonical order in the original.
        // Compare decoded sets without imposing a new serialized representation.
        XCTAssertEqual(current, try old(frozen, as: BoundSDKEventJournal.self), file: file, line: line)
    }

    func testEventJournalAndAcknowledgementPreserveSerializedBytesAndKeys() throws {
        var current = journal
        var frozen = try old(current, as: Phase4EventJournal.self)
        XCTAssertEqual(try encode(current), try encode(frozen))
        let append = try BoundSDKEventJournalRules.append(kind: "sample", payload: Data([0, 128, 255]), idempotencyKey: "stable", to: &current)
        let original = try Phase4EventOracle.append(kind: "sample", payload: Data([0, 128, 255]), idempotencyKey: "stable", to: &frozen)
        XCTAssertEqual(try encode(append.event), try encode(original.event))
        let remote = event(3)
        XCTAssertTrue(try BoundSDKEventJournalRules.receive(remote, authoritative: false, into: &current))
        XCTAssertTrue(try Phase4EventOracle.receive(old(remote, as: Phase4Event.self), authoritative: false, into: &frozen))
        XCTAssertEqual(try encode(current), try encode(frozen))
        XCTAssertEqual(try encode(BoundSDKEventJournalRules.acknowledgement(for: current)),
                       try encode(Phase4EventOracle.acknowledgement(for: frozen)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(current)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "run", "owner", "partner", "nextSequence", "events", "received", "acknowledged", "applied"]))
        let encodedEvent = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(remote)) as? [String: Any])
        XCTAssertEqual(Set(encodedEvent.keys), Set(["run", "id", "kind", "payload"]))
        XCTAssertEqual(encodedEvent["payload"] as? String, Data([3]).base64EncodedString())
        XCTAssertEqual(object["run"] as? String, run.uuidString)
    }

    func testDecodingRetainsRequiredFieldsOptionalKeyAndUnknownFieldBehavior() throws {
        let bytes = try encode(journal)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for key in object.keys {
            var missing = object; missing.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: missing)
            XCTAssertThrowsError(try JSONDecoder().decode(BoundSDKEventJournal.self, from: data), key)
            XCTAssertThrowsError(try JSONDecoder().decode(Phase4EventJournal.self, from: data), key)
        }
        var extra = object; extra["future"] = "ignored"
        let data = try JSONSerialization.data(withJSONObject: extra)
        XCTAssertEqual(try JSONDecoder().decode(BoundSDKEventJournal.self, from: data), journal)
        XCTAssertEqual(try encode(JSONDecoder().decode(BoundSDKEventJournal.self, from: data)),
                       try encode(JSONDecoder().decode(Phase4EventJournal.self, from: data)))
        var invalid = object; invalid["nextSequence"] = -1
        let negative = try JSONSerialization.data(withJSONObject: invalid)
        XCTAssertThrowsError(try JSONDecoder().decode(BoundSDKEventJournal.self, from: negative))
        XCTAssertThrowsError(try JSONDecoder().decode(Phase4EventJournal.self, from: negative))
    }

    func testCursorGapsMergesAndBoundaryDecisionsMatchFrozenOracle() throws {
        var current = BoundSDKEventCursor(), frozen = Phase4EventCursor()
        for sequence: UInt64 in [0, 3, 1, 7, 3, 2, 6, 5, 4, UInt64.max - 1, UInt64.max] {
            let id = BoundSDKEvent.ID(origin: owner, sequence: sequence)
            current.insert(id); frozen.insert(.init(origin: owner, sequence: sequence))
            XCTAssertEqual(current, try old(frozen, as: BoundSDKEventCursor.self))
            for check: UInt64 in [0, 1, 2, 3, 7, 8, UInt64.max - 1, UInt64.max] {
                XCTAssertEqual(current.contains(.init(origin: owner, sequence: check)), frozen.contains(.init(origin: owner, sequence: check)))
            }
            XCTAssertEqual(current.origins[owner.uuidString]?.valid, frozen.origins[owner.uuidString]?.valid)
        }
        // The insertion checks above include an invalid max sentinel. Keep the
        // merge equivalence inputs valid; rejection after normalization is tested
        // separately from the frozen implementation's invalid representation.
        current.origins[owner.uuidString]?.sparse.remove(UInt64.max)
        frozen.origins[owner.uuidString]?.sparse.remove(UInt64.max)
        for contiguous: UInt64 in [0, 1, 2, 6, UInt64.max - 1, UInt64.max] {
            for sparse: Set<UInt64> in [[], [3], [2, 7]] {
                let incoming = BoundSDKEventCursor(origins: [owner.uuidString: .init(contiguous: contiguous, sparse: sparse)])
                let original = try old(incoming, as: Phase4EventCursor.self)
                XCTAssertEqual(current.covers(incoming), frozen.covers(original))
                var merged = current, oldMerged = frozen
                merged.merge(incoming); oldMerged.merge(original)
                XCTAssertEqual(merged, try old(oldMerged, as: BoundSDKEventCursor.self))
            }
        }
        var gap = BoundSDKEventCursor(); gap.insert(.init(origin: owner, sequence: 3))
        XCTAssertFalse(gap.contains(.init(origin: owner, sequence: 2)))
        XCTAssertFalse(gap.covers(.init(origins: [owner.uuidString: .init(contiguous: 2)])))
    }

    func testCursorMergeNormalizesEverySmallReceiptUnion() {
        func members(_ mask: Int) -> Set<UInt64> {
            Set((1...6).compactMap { mask & (1 << ($0 - 1)) == 0 ? nil : UInt64($0) })
        }
        func canonical(_ members: Set<UInt64>) -> BoundSDKEventCursor {
            var prefix: UInt64 = 0
            while members.contains(prefix + 1) { prefix += 1 }
            return .init(origins: [owner.uuidString: .init(contiguous: prefix, sparse: members.filter { $0 > prefix })])
        }
        for leftMask in 0..<64 {
            let leftMembers = members(leftMask), left = canonical(leftMembers)
            for rightMask in 0..<64 {
                let rightMembers = members(rightMask), right = canonical(rightMembers)
                let expected = canonical(leftMembers.union(rightMembers))
                var merged = left; merged.merge(right)
                XCTAssertEqual(merged, expected)
                XCTAssertTrue(merged.covers(left)); XCTAssertTrue(merged.covers(right))
                var reverse = right; reverse.merge(left)
                XCTAssertEqual(reverse, merged)
                merged.merge(right); merged.merge(left)
                XCTAssertEqual(merged, expected)
                XCTAssertTrue(merged.origins[owner.uuidString]?.valid == true)
            }
        }
    }

    func testCursorNormalizationKeepsRealGapsOriginsAndOverflowRejection() {
        var gap = BoundSDKEventCursor(origins: [owner.uuidString: .init(sparse: [2, 3, 5]), partner.uuidString: .init(sparse: [2])])
        gap.merge(.init(origins: [owner.uuidString: .init(contiguous: 1)]))
        XCTAssertEqual(gap.origins[owner.uuidString], BoundSDKEventCursor.Position(contiguous: 3, sparse: [5]))
        XCTAssertEqual(gap.origins[partner.uuidString], BoundSDKEventCursor.Position(sparse: [2]))
        XCTAssertFalse(gap.contains(.init(origin: owner, sequence: 4)))
        XCTAssertFalse(gap.covers(.init(origins: [owner.uuidString: .init(contiguous: 4)])))

        var boundary = BoundSDKEventCursor(origins: [owner.uuidString: .init(contiguous: UInt64.max - 3, sparse: [UInt64.max - 1])])
        boundary.merge(.init(origins: [owner.uuidString: .init(contiguous: UInt64.max - 2)]))
        XCTAssertEqual(boundary.origins[owner.uuidString], BoundSDKEventCursor.Position(contiguous: UInt64.max - 1))
        XCTAssertTrue(boundary.origins[owner.uuidString]?.valid == true)
        XCTAssertFalse(boundary.contains(.init(origin: owner, sequence: UInt64.max)))

        var invalid = BoundSDKEventCursor(origins: [owner.uuidString: .init(contiguous: UInt64.max - 1, sparse: [UInt64.max])])
        XCTAssertFalse(invalid.origins[owner.uuidString]?.valid == true)
        invalid.merge(.init(origins: [owner.uuidString: .init(contiguous: UInt64.max - 1)]))
        XCTAssertEqual(invalid.origins[owner.uuidString]?.contiguous, UInt64.max)
        XCTAssertFalse(invalid.origins[owner.uuidString]?.valid == true)
        invalid.merge(.init(origins: [owner.uuidString: .init()]))
        XCTAssertEqual(invalid.origins[owner.uuidString]?.contiguous, UInt64.max)
        XCTAssertFalse(invalid.origins[owner.uuidString]?.valid == true)
        XCTAssertFalse(invalid.contains(.init(origin: owner, sequence: 0)))
    }

    func testAppendRetriesConflictAndOverflowMatchFrozenOracle() throws {
        var current = journal, frozen = try old(journal, as: Phase4EventJournal.self)
        for payload in [Data([1]), Data([1]), Data([2])] {
            var currentResult: BoundSDKEventJournalRules.AppendResult?
            var oldResult: Phase4EventOracle.AppendResult?
            let error = failure { currentResult = try BoundSDKEventJournalRules.append(kind: "sample", payload: payload, idempotencyKey: "same", to: &current) }
            let oldError = failure { oldResult = try Phase4EventOracle.append(kind: "sample", payload: payload, idempotencyKey: "same", to: &frozen) }
            XCTAssertEqual(error, oldError)
            XCTAssertEqual(currentResult?.inserted, oldResult?.inserted)
            if let currentResult, let oldResult { XCTAssertEqual(try encode(currentResult.event), try encode(oldResult.event)) }
            try equivalent(current, frozen)
        }
        XCTAssertEqual(current.events.count, 1); XCTAssertEqual(current.nextSequence, 2)
        XCTAssertTrue(current.applied.contains(current.events[0].id))
        for next: UInt64 in [UInt64.max - 2, UInt64.max - 1, UInt64.max] {
            var candidate = journal; candidate.nextSequence = next
            var baseline = try old(candidate, as: Phase4EventJournal.self)
            XCTAssertEqual(failure { _ = try BoundSDKEventJournalRules.append(kind: "sample", payload: Data(), idempotencyKey: nil, to: &candidate) },
                           failure { _ = try Phase4EventOracle.append(kind: "sample", payload: Data(), idempotencyKey: nil, to: &baseline) })
            try equivalent(candidate, baseline)
        }
    }

    func testReceiveSeparatesReceiptApplicationAndAuthenticatedOwnOrigins() throws {
        var current = journal, frozen = try old(journal, as: Phase4EventJournal.self)
        var changed = event(3); changed.payload = Data([99])
        let scenarios: [(BoundSDKEvent, Bool)] = [(event(3), false), (event(3), false), (changed, false),
            (event(2, origin: owner), false), (event(2, origin: owner), true), (event(1), false),
            (event(2), false), (event(1, origin: stranger), true), (event(UInt64.max - 1, origin: owner), true)]
        for (incoming, authoritative) in scenarios {
            var inserted: Bool?, oldInserted: Bool?
            let original = try old(incoming, as: Phase4Event.self)
            XCTAssertEqual(failure { inserted = try BoundSDKEventJournalRules.receive(incoming, authoritative: authoritative, into: &current) },
                           failure { oldInserted = try Phase4EventOracle.receive(original, authoritative: authoritative, into: &frozen) })
            XCTAssertEqual(inserted, oldInserted); try equivalent(current, frozen)
        }
        XCTAssertEqual(current.nextSequence, 3)
        XCTAssertTrue(current.applied.origins.isEmpty)
        XCTAssertEqual(BoundSDKEventJournalRules.acknowledgement(for: current).cursor, current.received)
        XCTAssertEqual(try encode(BoundSDKEventJournalRules.pendingApplication(in: current)),
                       try encode(Phase4EventOracle.pendingApplication(in: frozen)))
        for id in [event(2).id, event(4).id, event(2, origin: owner).id] {
            XCTAssertEqual(failure { try BoundSDKEventJournalRules.markApplied(id, in: &current) },
                           failure { try Phase4EventOracle.markApplied(.init(origin: id.origin, sequence: id.sequence), in: &frozen) })
            try equivalent(current, frozen)
        }
        XCTAssertTrue(current.acknowledged.origins.isEmpty)
    }

    func testPeerAcknowledgementsCannotInventEventsOrAcknowledgeOtherOrigins() throws {
        var base = journal
        for index in 1...3 { _ = try BoundSDKEventJournalRules.append(kind: "sample", payload: Data([UInt8(index)]), idempotencyKey: nil, to: &base) }
        let acknowledgements: [BoundSDKEventAcknowledgement] = [
            .init(run: run, receiver: partner, cursor: .init(origins: [owner.uuidString: .init(sparse: [3]), partner.uuidString: .init(contiguous: 999)])),
            .init(run: run, receiver: owner, cursor: .init()),
            .init(run: stranger, receiver: partner, cursor: .init()),
            .init(run: run, receiver: partner, cursor: .init(origins: [owner.uuidString: .init(contiguous: 4)])),
            .init(run: run, receiver: partner, cursor: .init(origins: [owner.uuidString: .init(sparse: [4])])),
            .init(run: run, receiver: partner, cursor: .init(origins: [owner.uuidString: .init(contiguous: 2, sparse: [1])]))
        ]
        for ack in acknowledgements {
            var current = base, frozen = try old(base, as: Phase4EventJournal.self)
            let original = try old(ack, as: Phase4EventAcknowledgement.self)
            XCTAssertEqual(failure { try BoundSDKEventJournalRules.acknowledge(ack, in: &current) },
                           failure { try Phase4EventOracle.acknowledge(original, in: &frozen) })
            try equivalent(current, frozen)
            XCTAssertNil(current.acknowledged.origins[partner.uuidString])
        }
    }

    func testOutboxPolicyFiltersBeforeLimitAndPreservesUnacknowledgedGaps() throws {
        var current = journal
        for index in 1...300 {
            _ = try BoundSDKEventJournalRules.append(kind: index < 299 ? "held" : "prompt", payload: Data(), idempotencyKey: nil, to: &current)
        }
        current.acknowledged.insert(.init(origin: owner, sequence: 300))
        let frozen = try old(current, as: Phase4EventJournal.self)
        for limit in [-1, 0, 1, 16, 256, 500] {
            for onlyPrompt in [false, true] {
                let events = BoundSDKEventJournalRules.eventsToSend(in: current, peerCursor: nil, limit: limit) { !onlyPrompt || $0.kind == "prompt" }
                let original = Phase4EventOracle.eventsToSend(in: frozen, peerCursor: nil, limit: limit) { !onlyPrompt || $0.kind == "prompt" }
                XCTAssertEqual(try encode(events), try encode(original))
            }
        }
        XCTAssertEqual(BoundSDKEventJournalRules.eventsToSend(in: current, peerCursor: nil, limit: 1) { $0.kind == "prompt" }.map(\.id.sequence), [299])
        XCTAssertEqual(BoundSDKEventJournalRules.eventsToSend(in: current, peerCursor: .init(), limit: 500) { _ in true }.count, 256)
    }

    func testJournalValidationMatchesFrozenMalformedAndBoundaryFixtures() throws {
        var base = journal
        _ = try BoundSDKEventJournalRules.append(kind: "sample", payload: Data([1]), idempotencyKey: "one", to: &base)
        _ = try BoundSDKEventJournalRules.receive(event(3), authoritative: false, into: &base)
        let changes: [(inout BoundSDKEventJournal) -> Void] = [
            { _ in }, { $0.version = 2 }, { $0.run = self.stranger }, { $0.owner = self.partner }, { $0.partner = self.owner },
            { $0.nextSequence = 0 }, { $0.nextSequence = UInt64.max }, { $0.nextSequence = 3 },
            { $0.events.append($0.events[0]) }, { $0.events[0].kind = "" }, { $0.events[0].kind = String(repeating: "x", count: 129) },
            { $0.events[0].kind = String(repeating: "é", count: 64) }, { $0.events[0].kind = String(repeating: "é", count: 65) },
            { $0.events[0].payload = Data(repeating: 1, count: 65_536) }, { $0.events[0].payload = Data(repeating: 1, count: 65_537) },
            { $0.events[0].idempotencyKey = "" }, { $0.events[0].idempotencyKey = String(repeating: "k", count: 512) },
            { $0.events[0].idempotencyKey = String(repeating: "k", count: 513) }, { $0.events[0].run = self.stranger },
            { $0.events[0].id.origin = self.stranger }, { $0.events[0].id.sequence = 0 }, { $0.events[0].id.sequence = UInt64.max },
            { $0.received = .init() }, { $0.received.origins[self.owner.uuidString.lowercased()] = .init() },
            { $0.received.origins[self.stranger.uuidString] = .init() },
            { $0.applied.insert(.init(origin: self.partner, sequence: 2)) },
            { $0.acknowledged.insert(.init(origin: self.owner, sequence: 2)) },
            { $0.applied.origins[self.owner.uuidString] = .init(contiguous: UInt64.max) },
            { $0.acknowledged.origins[self.owner.uuidString] = .init(contiguous: 1, sparse: [1]) }
        ]
        for (index, change) in changes.enumerated() {
            var current = base; change(&current)
            let frozen = try old(current, as: Phase4EventJournal.self)
            XCTAssertEqual(failure { try BoundSDKEventJournalRules.validate(current, scope: scope) },
                           failure { try Phase4EventOracle.validate(frozen, scope: oldScope) }, "fixture \(index)")
        }
        var repeatedKey = base
        _ = try BoundSDKEventJournalRules.append(kind: "sample", payload: Data(), idempotencyKey: "two", to: &repeatedKey)
        repeatedKey.events[2].idempotencyKey = "one"
        let frozen = try old(repeatedKey, as: Phase4EventJournal.self)
        XCTAssertEqual(failure { try BoundSDKEventJournalRules.validate(repeatedKey, scope: scope) }, "corrupt")
        XCTAssertEqual(failure { try Phase4EventOracle.validate(frozen, scope: oldScope) }, "corrupt")
    }

    func testRestoredJournalMergeRetainsHistoryCursorsAndSequenceWithoutChangingIDs() throws {
        var retained = journal
        _ = try BoundSDKEventJournalRules.append(kind: "sample", payload: Data([1]), idempotencyKey: "one", to: &retained)
        _ = try BoundSDKEventJournalRules.receive(event(3), authoritative: false, into: &retained)
        try BoundSDKEventJournalRules.markApplied(event(3).id, in: &retained)
        retained.acknowledged.insert(.init(origin: owner, sequence: 1))
        var incoming = journal
        _ = try BoundSDKEventJournalRules.receive(event(3, origin: owner), authoritative: true, into: &incoming)
        _ = try BoundSDKEventJournalRules.receive(event(1), authoritative: false, into: &incoming)
        var original = try old(incoming, as: Phase4EventJournal.self)
        let oldRetained = try old(retained, as: Phase4EventJournal.self)
        try BoundSDKEventJournalRules.mergeRetained(retained, into: &incoming)
        try Phase4EventOracle.mergeRetained(oldRetained, into: &original)
        try equivalent(incoming, original)
        try BoundSDKEventJournalRules.validate(incoming, scope: scope)
        XCTAssertEqual(incoming.nextSequence, 4)
        XCTAssertTrue(incoming.applied.contains(event(3).id))
        XCTAssertFalse(incoming.applied.contains(event(3, origin: owner).id))
        XCTAssertFalse(incoming.received.contains(event(2).id))
        var conflict = incoming; conflict.events[0].payload = Data([99])
        var oldConflict = try old(conflict, as: Phase4EventJournal.self)
        XCTAssertEqual(failure { try BoundSDKEventJournalRules.mergeRetained(retained, into: &conflict) },
                       failure { try Phase4EventOracle.mergeRetained(oldRetained, into: &oldConflict) })
        try equivalent(conflict, oldConflict)

        // Intentional behavior correction after structural extraction: the old
        // merge rejects complementary valid history. Keep that frozen evidence;
        // only the new merged cursor normalizes its already-received adjacency.
        var adjacent = journal
        _ = try BoundSDKEventJournalRules.receive(event(2, origin: owner), authoritative: true, into: &adjacent)
        var oldAdjacent = try old(adjacent, as: Phase4EventJournal.self)
        try BoundSDKEventJournalRules.mergeRetained(retained, into: &adjacent)
        try Phase4EventOracle.mergeRetained(oldRetained, into: &oldAdjacent)
        try BoundSDKEventJournalRules.validate(adjacent, scope: scope)
        XCTAssertEqual(adjacent.received.origins[owner.uuidString], BoundSDKEventCursor.Position(contiguous: 2))
        XCTAssertEqual(adjacent.nextSequence, 3)
        XCTAssertEqual(adjacent.events, try old(oldAdjacent.events, as: [BoundSDKEvent].self))
        XCTAssertFalse(adjacent.applied.contains(event(2, origin: owner).id))
        XCTAssertEqual(failure { try Phase4EventOracle.validate(oldAdjacent, scope: oldScope) }, "corrupt")
    }

    #if canImport(Delta)
    private func storeFixture() throws -> (BoundMultiplayerSaveStore, BoundMultiplayerRunIdentity, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SDKEventPersistence-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("game.sav")
        try Data(repeating: 0, count: 131_072).write(to: save)
        let store = BoundMultiplayerSaveStore(root: root.appendingPathComponent("packages"), support: root, deviceID: stranger)
        let identity = BoundMultiplayerRunIdentity(run: run, gameID: "sdk-event-fixture", owner: owner, partner: partner,
            roomID: "sdk-room", settingsOwner: owner, settings: Data([1]), localSeed: 1, partnerSeed: 2,
            romSHA256: String(repeating: "a", count: 64))
        try store.begin(identity, gameSaveURL: save)
        return (store, identity, root)
    }

    func testStoreRetainsExistingErrorsAndDoesNotAdvanceJournalOnFailedPersistence() throws {
        let (store, identity, _) = try storeFixture()
        let before = try store.journal(gameID: identity.gameID)
        let url = store.root.appendingPathComponent("Shared Event Journals/" + run.uuidString + "/" + owner.uuidString + ".json")
        let bytes = try Data(contentsOf: url), folder = url.deletingLastPathComponent()
        // Reads remain possible; an atomic replacement cannot create its temporary
        // file. Permissions change only on this test's synthetic journal folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertEqual(try store.journal(gameID: identity.gameID), before)
        XCTAssertThrowsError(try store.appendSharedEvent(gameID: identity.gameID, kind: "sample", payload: Data([1]), idempotencyKey: "retry"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try store.journal(gameID: identity.gameID), before)
        let inserted = try store.appendSharedEvent(gameID: identity.gameID, kind: "sample", payload: Data([1]), idempotencyKey: "retry")
        XCTAssertEqual(inserted.id.sequence, 1)
        XCTAssertEqual(try store.appendSharedEvent(gameID: identity.gameID, kind: "sample", payload: Data([1]), idempotencyKey: "retry"), inserted)
        XCTAssertThrowsError(try store.appendSharedEvent(gameID: identity.gameID, kind: "sample", payload: Data([2]), idempotencyKey: "retry")) {
            XCTAssertEqual($0 as? BoundMultiplayerSaveStore.Failure, .conflict)
        }
        XCTAssertThrowsError(try store.receiveSharedEvent(gameID: identity.gameID, event: self.event(2, origin: self.owner))) {
            XCTAssertEqual($0 as? BoundMultiplayerSaveStore.Failure, .ownerMismatch)
        }
        XCTAssertThrowsError(try store.appendSharedEvent(gameID: identity.gameID, kind: "", payload: Data())) {
            XCTAssertEqual($0 as? BoundMultiplayerSaveStore.Failure, .corrupt)
        }
        XCTAssertEqual(try store.journal(gameID: identity.gameID).nextSequence, 2)
    }
    #endif
}

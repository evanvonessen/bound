import XCTest
@testable import Delta

final class DebugNativePayloadTests: XCTestCase {
    func testDescriptorPreservesExactSoulSidecarBytesInsteadOfReencodingSets() throws {
        let owner = UUID(), peer = UUID(), device = UUID(), run = UUID(), room = UUID()
        let profile = BoundGameProfiles.current
        let identity = BoundMultiplayerRunIdentity(run: run, gameID: profile.gameID, owner: owner, partner: peer,
            roomID: room.uuidString.lowercased(), settingsOwner: owner, settings: Data(repeating: 0, count: 32),
            localSeed: 1, partnerSeed: 2, romSHA256: profile.romSHA256)
        let binding = BoundMultiplayerSaveStore.hash(Data((owner.uuidString + ":" + identity.roomID).utf8))
        // Whitespace/key order and Set array order are valid historical bytes.
        // Neither sortedKeys nor repeated Codable encoding preserves them.
        let soul = Data("""
        { "run": "\(run.uuidString)", "binding": "\(binding)", "version": 1,
          "records": [], "dead": ["area:3", "area:1"], "nextEgg": 1,
          "offering": false, "ended": false, "partnerAcquisitions": ["area:3", "area:1"] }
        """.utf8)
        let memory = ["Soul Link/" + BoundMultiplayerSaveStore.hash(Data(profile.gameID.utf8)) + ".json": soul]
        let journal = BoundMultiplayerSharedJournal(run: run, owner: owner, partner: peer)
        let payload = BoundMultiplayerSavePackage.Payload(version: 2, manifest: .init(identity: identity, deviceOwner: device),
            checkpoint: UUID(), predecessor: nil, sharedEventDigest: String(repeating: "d", count: 64), files: [
                "game.sav": .init(Data([1, 2])), "checkpoint.state": .init(Data([3, 4])),
                "memory-files.json": .init(try JSONEncoder().encode(memory)),
                "shared-events.json": .init(try JSONEncoder().encode(journal))])
        let bytes = try BoundMultiplayerSaveStore.encode(payload)
        let receipt = BoundMultiplayerCheckpointReceipt(run: run, checkpoint: payload.checkpoint, owner: owner,
            payloadSHA256: BoundMultiplayerSaveStore.hash(bytes), sharedEventDigest: payload.sharedEventDigest)
        let package = BoundMultiplayerSavePackage(payload: payload, receipt: receipt)
        let bookmark = BoundDebugBookmark(identity: identity, deviceID: device, ownershipEpoch: 1, settled: true)
        let operation = BoundDebugOperation(operationID: UUID(), sessionID: UUID(), membershipEpoch: 1,
            requestDigest: String(repeating: "a", count: 64), generation: 1, kind: .load,
            source: .init(kind: .builtin, pointID: "01", fixtureVersion: BoundDebugCatalog.fixtureVersion), state: .preparing,
            runID: run, identities: [owner.uuidString.lowercased(): identity], compatibility: .init(profile: profile),
            settings: identity.settings, preparedOwners: [], verifiedOwners: [], deadline: Date().timeIntervalSince1970 + 60)
        let prepared = try BoundDebugNativePayload.prepare(package: package, trainer: .init(id: 1, name: "PLAYER", gender: 0),
            operation: operation, device: device, epoch: 1, bookmark: bookmark, durable: .init())
        XCTAssertEqual(prepared.bytes, bytes, "DEBUG keeps existing package bytes opaque")
        XCTAssertEqual(prepared.descriptor.soulDigest, BoundMultiplayerSaveStore.hash(soul))
        let decoded = try BoundDebugNativePayload.ledger(in: memory, identity: identity)
        XCTAssertEqual(decoded.dead, Set(["area:1", "area:3"]))
        XCTAssertNotEqual(try BoundMultiplayerSaveStore.encode(decoded), soul)
        var foreign = package
        foreign.payload.manifest.deviceOwner = UUID()
        XCTAssertThrowsError(try BoundDebugNativePayload.prepare(package: foreign, trainer: .init(id: 1, name: "PLAYER", gender: 0),
            operation: operation, device: device, epoch: 1, bookmark: bookmark, durable: .init()))
    }
}

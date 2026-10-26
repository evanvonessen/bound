import Foundation

/// Raw native assets are local, generated from the user's verified cartridge.
/// Only a reviewed certification digest admits a template. No downloaded or
/// edited manifest can authorize itself by supplying its own file hashes.
enum BoundDebugFixtureStore {
    struct Certificate: Codable {
        var version: Int
        var fixtureVersion: String
        var pointID: String
        var role: String
        var compatibility: BoundDebugCompatibility
        var settings: Data
        var trainer: BoundDebugOwnerDescriptor.Trainer
        var files: [String: BoundDebugOwnerDescriptor.File]
        var levelCap: Int
        var preparedTeams: String
        var nativeValidationDigest: String
    }
    // Filled by the Phase 8 native certification gate, never from app input.
    static let certificates: [String: String] = [:]

    static func prepare(operation: BoundDebugOperation, owner: UUID, device: UUID,
                        bookmark: BoundDebugBookmark, root: URL,
                        reviewedCertificates: [String: String] = certificates) throws -> BoundDebugPreparedPayload {
        guard operation.source.kind == .builtin, let point = operation.source.pointID,
              operation.source.fixtureVersion == BoundDebugCatalog.fixtureVersion,
              let identity = operation.identities[owner.uuidString.lowercased()] else { throw BoundDebugFailure.incompatible }
        let role = owner == identity.settingsOwner ? "controller" : "buddy"
        let key = point + "/" + role
        // The native acceptance harness supplies separately reviewed candidate
        // digests through this internal seam. Product callers use only the
        // compiled certification registry; files cannot authorize themselves.
        guard let digest = reviewedCertificates[key] else { throw BoundDebugFailure.unavailable }
        let directory = root.appendingPathComponent(BoundDebugCatalog.fixtureVersion).appendingPathComponent(point).appendingPathComponent(role)
        let certificateBytes = try read(directory.appendingPathComponent("certificate.json"), maximum: 65_536)
        guard BoundMultiplayerSaveStore.hash(certificateBytes) == digest else { throw BoundDebugFailure.incompatible }
        let certificate = try JSONDecoder().decode(Certificate.self, from: certificateBytes)
        guard certificate.version == 1, certificate.fixtureVersion == BoundDebugCatalog.fixtureVersion,
              certificate.pointID == point, certificate.role == role, certificate.compatibility == operation.compatibility,
              certificate.settings == operation.settings, certificate.trainer.id == identity.localSeed,
              certificate.trainer.valid, (1...100).contains(certificate.levelCap),
              BoundDebugJSON.validDigest(certificate.nativeValidationDigest),
              Set(certificate.files.keys) == Set(["game.sav", "checkpoint.state", "soul-template.json"]) else { throw BoundDebugFailure.incompatible }
        var files = [String: Data]()
        for (name, expected) in certificate.files {
            guard (1...4_194_304).contains(expected.bytes), BoundDebugJSON.validDigest(expected.sha256) else { throw BoundDebugFailure.incompatible }
            let bytes = try read(directory.appendingPathComponent(name), maximum: expected.bytes)
            guard bytes.count == expected.bytes, BoundMultiplayerSaveStore.hash(bytes) == expected.sha256 else { throw BoundDebugFailure.incompatible }
            files[name] = bytes
        }
        guard files["game.sav"]?.count == 131_072, let template = files.removeValue(forKey: "soul-template.json") else { throw BoundDebugFailure.incompatible }
        let source = try JSONDecoder().decode(BoundSoulLedger.self, from: template)
        guard source.valid, !source.ended, !source.offering, source.dead.isEmpty else { throw BoundDebugFailure.incompatible }
        var ledger = BoundSoulLedger(run: identity.run,
            binding: BoundMultiplayerSaveStore.hash(Data((owner.uuidString + ":" + identity.roomID).utf8)))
        ledger.records = source.records; ledger.nextEgg = source.nextEgg
        ledger.partnerAcquisitions = source.partnerAcquisitions; ledger.partnerNames = source.partnerNames
        ledger.consumedSlots = source.consumedSlots
        let ledgerBytes = try BoundMultiplayerSaveStore.encode(ledger)
        let memory = ["Soul Link/" + BoundMultiplayerSaveStore.hash(Data(identity.gameID.utf8)) + ".json": ledgerBytes]
        files["memory-files.json"] = try BoundMultiplayerSaveStore.encode(memory)
        var journal = BoundSDKEventJournal(run: identity.run, owner: owner, partner: identity.partner)
        for fact in ledger.sharedEvents {
            let payload = try BoundMultiplayerSaveStore.encode(fact)
            _ = try BoundSDKEventJournalRules.append(kind: "soul", payload: payload,
                idempotencyKey: fact.id, to: &journal)
        }
        for (index, slot) in ledger.partnerSlots.sorted().enumerated() {
            let fact = BoundSoulSharedEvent(run: identity.run, kind: .acquired, slot: slot)
            let payload = try BoundMultiplayerSaveStore.encode(fact)
            let event = BoundSDKEvent(run: identity.run, id: .init(origin: identity.partner, sequence: UInt64(index + 1)),
                kind: "soul", payload: payload, idempotencyKey: fact.id)
            _ = try BoundSDKEventJournalRules.receive(event, authoritative: true, into: &journal)
            try BoundSDKEventJournalRules.markApplied(event.id, in: &journal)
        }
        try BoundSDKEventJournalRules.validate(journal, scope: .init(run: identity.run, owner: owner, partner: identity.partner))
        files["shared-events.json"] = try BoundMultiplayerSaveStore.encode(journal)
        let local = ledger.acquisitionBits, peer = BoundSoulLedger.bits(ledger.partnerSlots)
        let history = BoundROMHistoryJournal.digest((owner.uuidString < identity.partner.uuidString ? local + peer : peer + local) + ledger.lossBits)
        let payload = BoundMultiplayerSavePackage.Payload(version: 2,
            manifest: .init(identity: identity, deviceOwner: device), checkpoint: UUID(), predecessor: nil,
            sharedEventDigest: history, files: files.mapValues(BoundMultiplayerSavePackage.Blob.init))
        let receipt = BoundMultiplayerCheckpointReceipt(run: identity.run, checkpoint: payload.checkpoint, owner: owner,
            payloadSHA256: BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(payload)), sharedEventDigest: history)
        return try BoundDebugNativePayload.prepare(package: .init(payload: payload, receipt: receipt), trainer: certificate.trainer,
            operation: operation, device: device, epoch: operation.membershipEpoch, bookmark: bookmark, durable: .init(journal.applied))
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= maximum else { throw BoundDebugFailure.incompatible }
        let data = try Data(contentsOf: url)
        guard data.count == size else { throw BoundDebugFailure.incompatible }; return data
    }
}

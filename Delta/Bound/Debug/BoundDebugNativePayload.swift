import Foundation
import DeltaCore

/// Native addresses belong to the Radical Red adapter, even for test points.
/// Reads are permitted only while the calling host owns a stopped frame.
extension MultiRedAdapter {
    @MainActor static func debugTrainer(core: EmulatorCore) throws -> BoundDebugOwnerDescriptor.Trainer {
        guard core.state == .paused,
              let memory = BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }),
              let pointer = memory.bytes(at: 0x0300500C, count: 4) else { throw BoundDebugFailure.nativeVerification }
        func word(_ bytes: [UInt8]) -> UInt32 { bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } }
        let address = Int(word(pointer))
        guard (0x02000000...0x0203F000).contains(address), let bytes = memory.bytes(at: address, count: 14) else { throw BoundDebugFailure.nativeVerification }
        var name = [UInt8]()
        for value in bytes.prefix(8) {
            if value == 0xFF { break }
            switch value {
            case 0xBB...0xD4: name.append(value - 0xBB + 65)
            case 0xD5...0xEE: name.append(value - 0xD5 + 97)
            case 0xA1...0xAA: name.append(value - 0xA1 + 48)
            default: throw BoundDebugFailure.nativeVerification
            }
        }
        let trainer = BoundDebugOwnerDescriptor.Trainer(id: word(Array(bytes[10..<14])), name: String(decoding: name, as: UTF8.self), gender: Int(bytes[8]))
        guard trainer.valid else { throw BoundDebugFailure.nativeVerification }; return trainer
    }
}

enum BoundDebugNativePayload {
    static func ledgerBytes(in files: [String: Data], identity: BoundMultiplayerRunIdentity) throws -> Data {
        let key = "Soul Link/" + BoundMultiplayerSaveStore.hash(Data(identity.gameID.utf8)) + ".json"
        guard let bytes = files[key], bytes.count <= 2_097_152 else { throw BoundDebugFailure.nativeVerification }
        return bytes
    }
    static func ledger(in files: [String: Data], identity: BoundMultiplayerRunIdentity) throws -> BoundSoulLedger {
        let bytes = try ledgerBytes(in: files, identity: identity)
        let ledger = try JSONDecoder().decode(BoundSoulLedger.self, from: bytes)
        let binding = BoundMultiplayerSaveStore.hash(Data((identity.owner.uuidString + ":" + identity.roomID).utf8))
        guard ledger.valid, ledger.run == identity.run, ledger.binding == binding, !ledger.ended else { throw BoundDebugFailure.nativeVerification }
        return ledger
    }
    static func prepare(package: BoundMultiplayerSavePackage, trainer: BoundDebugOwnerDescriptor.Trainer,
                        operation: BoundDebugOperation, device: UUID, epoch: Int,
                        bookmark: BoundDebugBookmark, durable: BoundDebugCursor) throws -> BoundDebugPreparedPayload {
        let identity = package.payload.manifest.identity
        guard identity == operation.identities[identity.owner.uuidString.lowercased()], package.payload.version == 2,
              package.payload.manifest.deviceOwner == device,
              let memoryBlob = package.payload.files["memory-files.json"],
              let journalBlob = package.payload.files["shared-events.json"] else { throw BoundDebugFailure.nativeVerification }
        for blob in package.payload.files.values {
            guard BoundMultiplayerSaveStore.hash(blob.data) == blob.sha256 else { throw BoundDebugFailure.nativeVerification }
        }
        let memory = try JSONDecoder().decode([String: Data].self, from: memoryBlob.data)
        _ = try ledger(in: memory, identity: identity)
        let journal = try JSONDecoder().decode(BoundMultiplayerSharedJournal.self, from: journalBlob.data)
        guard journal.run == identity.run, journal.owner == identity.owner, journal.partner == identity.partner else { throw BoundDebugFailure.nativeVerification }
        let bytes = try BoundMultiplayerSaveStore.encode(package.payload)
        guard BoundMultiplayerSaveStore.hash(bytes) == package.receipt.payloadSHA256 else { throw BoundDebugFailure.nativeVerification }
        let descriptor = BoundDebugOwnerDescriptor(deviceID: device, ownershipEpoch: epoch, compatibility: operation.compatibility,
            trainer: trainer, receipt: package.receipt, bytes: bytes.count, count: ((bytes.count + 2) / 3 * 4 + 11_999) / 12_000,
            files: package.payload.files.mapValues { .init(sha256: $0.sha256, bytes: $0.data.count) },
            historyDigest: package.payload.sharedEventDigest, soulDigest: BoundMultiplayerSaveStore.hash(try ledgerBytes(in: memory, identity: identity)),
            received: .init(journal.received), applied: .init(journal.applied), durable: durable,
            cutDigest: operation.cut?.digest, bookmark: bookmark, safe: true)
        let prepared = BoundDebugPreparedPayload(bytes: bytes, descriptor: descriptor)
        guard prepared.valid(owner: identity.owner, operation: operation) else { throw BoundDebugFailure.nativeVerification }
        return prepared
    }
    static func decode(_ bytes: Data, manifest: BoundDebugManifest, owner: UUID) throws -> BoundMultiplayerSavePackage {
        guard let descriptor = manifest.owners[owner.uuidString.lowercased()], bytes.count == descriptor.bytes,
              BoundMultiplayerSaveStore.hash(bytes) == descriptor.receipt.payloadSHA256 else { throw BoundDebugFailure.invalidResponse }
        let payload = try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self, from: bytes)
        guard payload.version == 2, payload.manifest.identity.owner == owner, payload.manifest.identity.run == manifest.runID,
              payload.manifest.deviceOwner == descriptor.deviceID,
              payload.manifest.identity.settings == manifest.settings, payload.manifest.identity.romSHA256 == manifest.compatibility.romSHA256,
              payload.manifest.identity.gameID == manifest.compatibility.gameID, payload.checkpoint == descriptor.receipt.checkpoint,
              payload.sharedEventDigest == descriptor.historyDigest, Set(payload.files.keys) == Set(descriptor.files.keys),
              payload.files.allSatisfy({ name, blob in blob.sha256 == descriptor.files[name]?.sha256 && blob.data.count == descriptor.files[name]?.bytes && BoundMultiplayerSaveStore.hash(blob.data) == blob.sha256 }) else { throw BoundDebugFailure.invalidResponse }
        return .init(payload: payload, receipt: descriptor.receipt)
    }
}

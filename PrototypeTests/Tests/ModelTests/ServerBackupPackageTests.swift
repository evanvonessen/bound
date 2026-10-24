import XCTest
@testable import Models
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

final class ServerBackupPackageTests: XCTestCase {
    func testStatusReadCannotOverrideCommittedProviderChange() throws {
        var gate = BoundServerBackupStatusGate()
        let oldRead = try XCTUnwrap(gate.beginRead())
        XCTAssertTrue(gate.beginChange())
        XCTAssertFalse(gate.accepts(oldRead))
        XCTAssertNil(gate.beginRead())
        XCTAssertFalse(gate.beginChange())
        gate.endChange()
        XCTAssertFalse(gate.accepts(oldRead))
        let newRead = try XCTUnwrap(gate.beginRead())
        XCTAssertTrue(gate.accepts(newRead))
    }
    func testOnlyNewestConcurrentStatusResponseIsAccepted() throws {
        var gate = BoundServerBackupStatusGate()
        let first = try XCTUnwrap(gate.beginRead()), second = try XCTUnwrap(gate.beginRead())
        XCTAssertFalse(gate.accepts(first)); XCTAssertTrue(gate.accepts(second))
    }
    private func fixture() -> BoundServerBackupPackage {
        let files = ["game.sav": Data([1, 2, 3]), "states/state_1.state": Data([4, 5]), "states/state_1.png": Data([6])]
        return .init(manifest: .init(owner: UUID(uuidString: "A23C7479-BEDB-4A04-92BF-B141494E8716")!, gameID: "game_1", name: "Fixture",
            gameType: "gba", romSHA256: String(repeating: "a", count: 64), generation: nil, soulLink: false,
            states: [.init(identifier: "state_1", filename: "state_1", name: "Before boss", type: 2,
                           coreIdentifier: "fixture.core", coreVersion: "1.2", createdAt: Date(timeIntervalSince1970: 100), modifiedAt: Date(timeIntervalSince1970: 200))],
            files: files.mapValues(BoundServerBackupPackage.Blob.init)), files: files)
    }
    func testSaveMetadataRoundTripsWithoutLosingCoreIdentity() throws {
        let value = fixture()
        try value.validate(owner: value.manifest.owner, gameID: "game_1")
        let decoded = try JSONDecoder().decode(BoundServerBackupPackage.Manifest.self, from: value.manifestData())
        XCTAssertEqual(decoded, value.manifest)
        XCTAssertEqual(decoded.states[0].coreIdentifier, "fixture.core")
        XCTAssertEqual(decoded.states[0].coreVersion, "1.2")
    }
    func testOtherAccountAndOtherGameAreRejected() {
        let value = fixture()
        XCTAssertThrowsError(try value.validate(owner: UUID(), gameID: "game_1"))
        XCTAssertThrowsError(try value.validate(owner: value.manifest.owner, gameID: "different_game"))
    }
    func testROMPayloadIsNeverAllowedEvenWithMatchingDigest() {
        var value = fixture(); let rom = Data([8, 9])
        value.files["game.gba"] = rom; value.manifest.files["game.gba"] = .init(rom)
        XCTAssertThrowsError(try value.validate(owner: value.manifest.owner, gameID: "game_1"))
    }
    func testCorruptStateBytesAreRejectedBeforeRestore() {
        var value = fixture(); value.files["states/state_1.state"] = Data([99, 99])
        XCTAssertThrowsError(try value.validate(owner: value.manifest.owner, gameID: "game_1"))
    }
    func testMissingStateOrMissingCoreVersionIsRejected() {
        var value = fixture(); value.files.removeValue(forKey: "states/state_1.state")
        XCTAssertThrowsError(try value.validate(owner: value.manifest.owner, gameID: "game_1"))
        value = fixture(); value.manifest.states[0].coreVersion = ""
        XCTAssertThrowsError(try value.validate(owner: value.manifest.owner, gameID: "game_1"))
    }
    func testPathTraversalAndDuplicateStateNamesAreRejected() {
        var value = fixture(); value.manifest.states[0].filename = "../game"
        XCTAssertThrowsError(try value.validate(owner: value.manifest.owner, gameID: "game_1"))
        value = fixture(); value.manifest.states.append(value.manifest.states[0])
        XCTAssertThrowsError(try value.validate(owner: value.manifest.owner, gameID: "game_1"))
    }
    func testSoulLinkRequiresPairedPackageAndNoLooseStates() {
        var value = fixture(); value.manifest.soulLink = true
        XCTAssertThrowsError(try value.validate(owner: value.manifest.owner, gameID: "game_1"))
        value.manifest.states = []
        value.files = ["game.sav": Data([1]), "complete.boundrun": Data([2])]
        value.manifest.files = value.files.mapValues(BoundServerBackupPackage.Blob.init)
        XCTAssertNoThrow(try value.validate(owner: value.manifest.owner, gameID: "game_1"))
    }
#if canImport(ZIPFoundation)
    func testZIPRoundTripsAndIsDeterministic() throws {
        let value = fixture(), first = try value.zip(), second = try value.zip()
        XCTAssertEqual(first, second)
        let result = try BoundServerBackupPackage.unzip(first, owner: value.manifest.owner, gameID: "game_1")
        XCTAssertEqual(result.manifest, value.manifest)
        XCTAssertEqual(result.files, value.files)
    }
    func testZIPRejectsUnexpectedROMAndTraversalEntries() throws {
        for extra in ["game.gba", "states/../../game.sav", "/absolute"] {
            let value = fixture()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            let archive = try Archive(url: url, accessMode: .create)
            let entries = [("manifest.json", try value.manifestData()), (extra, Data([1, 2]))]
            for (path, bytes) in entries {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { offset, size in
                    bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + size))
                }
            }
            XCTAssertThrowsError(try BoundServerBackupPackage.unzip(Data(contentsOf: url), owner: value.manifest.owner, gameID: "game_1"))
        }
    }
    func testZIPRejectsDeclaredOversizeBeforeExtracting() throws {
        let value = fixture(), url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "game.sav", type: .file, uncompressedSize: Int64(BoundServerBackupPackage.maximumBytes + 1),
                             compressionMethod: .deflate) { _, size in Data(repeating: 0, count: size) }
        XCTAssertThrowsError(try BoundServerBackupPackage.unzip(Data(contentsOf: url), owner: value.manifest.owner, gameID: "game_1"))
    }
#endif
}

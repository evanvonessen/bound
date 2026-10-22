import XCTest
@testable import Delta

@MainActor
final class SoloRunTests: XCTestCase {
    private func fixture() throws -> (BoundSoloRunStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SoloRunTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("game.sav")
        try Data(repeating: 0x5a, count: 131072).write(to: save)
        return (.init(root: root.appendingPathComponent("runs", isDirectory: true)), save)
    }
    private var settings: Data { Data([3] + [UInt8](repeating: 0, count: 31)) }
    func testSoloIdentitySeedAndSettingsSurviveReopeningWithoutFakePartner() throws {
        let (store, save) = try fixture(), owner = UUID()
        let original = try Data(contentsOf: save)
        let first = try store.begin(gameID: "../game", owner: owner, gameSaveURL: save)
        XCTAssertNotEqual(first.seed, 0)
        XCTAssertTrue(first.settings.isEmpty)
        XCTAssertEqual(try store.begin(gameID: "../game", owner: owner, gameSaveURL: save), first)
        let committed = try store.commit(gameID: "../game", owner: owner, settings: settings)
        XCTAssertEqual(committed.run, first.run); XCTAssertEqual(committed.seed, first.seed)
        XCTAssertEqual(try BoundSoloRunStore(root: store.root).load(gameID: "../game"), committed)
        XCTAssertEqual(try Data(contentsOf: store.directory(gameID: "../game").appendingPathComponent("original.sav")), original)
        let manifest = try Data(contentsOf: store.directory(gameID: "../game").appendingPathComponent("manifest.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        XCTAssertNil(json["partner"]); XCTAssertNil(json["roomID"])
        XCTAssertEqual(try Data(contentsOf: save), original)
    }
    func testCloudGuardProtectsActiveAndDamagedSoloJournalsOnly() throws {
        let (store, save) = try fixture(), owner = UUID()
        XCTAssertFalse(BoundSoloSyncGuard.protects(gameID: "game", root: store.root))
        _ = try store.begin(gameID: "game", owner: owner, gameSaveURL: save)
        XCTAssertTrue(BoundSoloSyncGuard.protects(gameID: "game", root: store.root))
        _ = try store.end(gameID: "game", owner: owner)
        XCTAssertFalse(BoundSoloSyncGuard.protects(gameID: "game", root: store.root))
        try Data("corrupt".utf8).write(to: store.directory(gameID: "game").appendingPathComponent("manifest.json"))
        XCTAssertTrue(BoundSoloSyncGuard.protects(gameID: "game", root: store.root))
        try FileManager.default.removeItem(at: store.directory(gameID: "game").appendingPathComponent("manifest.json"))
        XCTAssertTrue(BoundSoloSyncGuard.protects(gameID: "game", root: store.root))
    }
    func testSoloStoreRejectsWrongOwnerSettingsReplacementAndInvalidRules() throws {
        let (store, save) = try fixture(), owner = UUID()
        _ = try store.begin(gameID: "game", owner: owner, gameSaveURL: save)
        XCTAssertThrowsError(try store.begin(gameID: "game", owner: UUID(), gameSaveURL: save))
        XCTAssertThrowsError(try store.commit(gameID: "game", owner: UUID(), settings: settings))
        XCTAssertThrowsError(try store.commit(gameID: "game", owner: owner, settings: Data(repeating: 0xff, count: 32)))
        let committed = try store.commit(gameID: "game", owner: owner, settings: settings)
        var different = settings; different[1] = 1
        XCTAssertThrowsError(try store.commit(gameID: "game", owner: owner, settings: different))
        XCTAssertThrowsError(try store.end(gameID: "game", owner: UUID()))
        XCTAssertEqual(try store.load(gameID: "game"), committed)
    }
    func testEndedSoloRunAndOriginalAreArchivedBeforeFreshRun() throws {
        let (store, save) = try fixture(), owner = UUID()
        let first = try store.begin(gameID: "game", owner: owner, gameSaveURL: save)
        _ = try store.commit(gameID: "game", owner: owner, settings: settings)
        _ = try store.end(gameID: "game", owner: owner)
        XCTAssertThrowsError(try store.commit(gameID: "game", owner: owner, settings: settings))
        let second = try store.begin(gameID: "game", owner: owner, gameSaveURL: save)
        XCTAssertNotEqual(second.run, first.run)
        let archive = store.root.appendingPathComponent("Ended").appendingPathComponent(first.run.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("original.sav")), try Data(contentsOf: save))
    }
    func testSoloStoreFailsClosedOnBackupCorruptionInterruptedBeginAndSymlinks() throws {
        let (store, save) = try fixture(), owner = UUID()
        _ = try store.begin(gameID: "game", owner: owner, gameSaveURL: save)
        let folder = store.directory(gameID: "game"), original = folder.appendingPathComponent("original.sav")
        try Data([0]).write(to: original)
        XCTAssertThrowsError(try store.load(gameID: "game"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.begin(gameID: "game", owner: owner, gameSaveURL: save))
        let linked = store.directory(gameID: "other")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder)
        XCTAssertThrowsError(try store.begin(gameID: "other", owner: owner, gameSaveURL: save))
        let sourceLink = save.deletingLastPathComponent().appendingPathComponent("linked.sav")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: save)
        XCTAssertThrowsError(try store.begin(gameID: "source-link", owner: owner, gameSaveURL: sourceLink))
    }
}

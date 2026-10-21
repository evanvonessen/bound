import XCTest
@testable import Delta

final class MacMetalCacheTests: XCTestCase {
    private var directory: URL!
    private var source: URL { directory.appendingPathComponent("darwin/com.apple.metal", isDirectory: true) }
    private var destination: URL { directory.appendingPathComponent("container/BoundMacMetal/com.apple.metal", isDirectory: true) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoundMacMetalCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testFreshCacheIsCreatedInsideDestinationAndLinked() throws {
        XCTAssertEqual(try BoundMacMetalCache.redirect(source: source, destination: destination), .created)
        XCTAssertEqual(source.resolvingSymlinksInPath(), destination.resolvingSymlinksInPath())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("cache.bin"))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("cache.bin")), Data([1, 2, 3]))
    }

    func testExistingCacheMovesIntactAndRepeatedSetupPreservesIt() throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try write(bytes, beneath: source, path: "archiveUsage.db/data.mdb")
        try write(Data([5, 6, 7]), beneath: source, path: "archiveUsage.db/lock.mdb")

        XCTAssertEqual(try BoundMacMetalCache.redirect(source: source, destination: destination), .migrated)
        XCTAssertEqual(try BoundMacMetalCache.redirect(source: source, destination: destination), .alreadyConfigured)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("archiveUsage.db/data.mdb")), bytes)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("archiveUsage.db/lock.mdb")), Data([5, 6, 7]))
    }

    func testExistingDestinationKeepsBothCachesWithoutMerging() throws {
        try write(Data([10]), beneath: source, path: "data.mdb")
        try write(Data([20]), beneath: destination, path: "data.mdb")
        let outcome = try BoundMacMetalCache.redirect(source: source, destination: destination)
        guard case .preservedPreviousCache(let backup) = outcome else {
            return XCTFail("Expected the original cache to be preserved separately.")
        }
        XCTAssertEqual(backup.deletingLastPathComponent(), destination.deletingLastPathComponent().resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("data.mdb")), Data([10]))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("data.mdb")), Data([20]))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("data.mdb")), Data([20]))
    }

    func testUnexpectedSourceSymlinkIsLeftUntouched() throws {
        let other = directory.appendingPathComponent("other-cache", isDirectory: true)
        try write(Data([30]), beneath: other, path: "data.mdb")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: other)

        XCTAssertThrowsError(try BoundMacMetalCache.redirect(source: source, destination: destination))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), other.path)
        XCTAssertEqual(try Data(contentsOf: other.appendingPathComponent("data.mdb")), Data([30]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDestinationSymlinkCannotRedirectMigrationOutsideCache() throws {
        let other = directory.appendingPathComponent("outside", isDirectory: true)
        try write(Data([40]), beneath: source, path: "data.mdb")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: other)

        XCTAssertThrowsError(try BoundMacMetalCache.redirect(source: source, destination: destination))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("data.mdb")), Data([40]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
    }

    func testContainerDestinationRejectsEscapingParentSymlink() throws {
        let caches = directory.appendingPathComponent("Caches", isDirectory: true)
        let other = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("BoundMacMetal"), withDestinationURL: other)
        XCTAssertThrowsError(try BoundMacMetalCache.cacheDestination(in: caches))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
    }

    func testLinkFailureRestoresOriginalCache() throws {
        try write(Data([50, 51]), beneath: source, path: "data.mdb")
        XCTAssertThrowsError(try BoundMacMetalCache.redirect(source: source, destination: destination) { _, _ in
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("data.mdb")), Data([50, 51]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: source.path))
    }

    func testLinkFailureWithExistingDestinationRestoresBothCaches() throws {
        try write(Data([60]), beneath: source, path: "data.mdb")
        try write(Data([70]), beneath: destination, path: "data.mdb")
        XCTAssertThrowsError(try BoundMacMetalCache.redirect(source: source, destination: destination) { _, _ in
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("data.mdb")), Data([60]))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("data.mdb")), Data([70]))
        let children = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertFalse(children.contains(where: { $0.hasPrefix("com.apple.metal.previous-") }))
    }

    func testNonDirectorySourceAndOverlappingPathsAreRejected() throws {
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([80]).write(to: source)
        XCTAssertThrowsError(try BoundMacMetalCache.redirect(source: source, destination: destination))
        XCTAssertEqual(try Data(contentsOf: source), Data([80]))
        XCTAssertThrowsError(try BoundMacMetalCache.redirect(source: destination, destination: destination))
        XCTAssertThrowsError(try BoundMacMetalCache.redirect(source: destination, destination: destination.appendingPathComponent("child")))
    }

    private func write(_ data: Data, beneath root: URL, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

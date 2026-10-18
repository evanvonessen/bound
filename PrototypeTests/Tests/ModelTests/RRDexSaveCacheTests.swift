import XCTest
@testable import Models

final class RRDexSaveCacheTests: XCTestCase {
    private let original = BoundRRDexSave(trainerID: 42, randomAbilities: false, randomLearnset: false)
    private let randomized = BoundRRDexSave(trainerID: 42, randomAbilities: true, randomLearnset: true)

    func testOpeningAndForegroundReuseSettingsUntilCompletedSaveChanges() throws {
        let cache = BoundRRDexSaveCache()
        var reads = 0
        for _ in 0..<3 {
            XCTAssertEqual(try cache.value(completedSave: { reads += 1; return self.original }, restoredSave: {
                XCTFail("Ordinary Dex entry must not export live memory")
                return self.randomized
            }), original)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(cache.completedSave { self.original })
        XCTAssertTrue(cache.completedSave { self.randomized })
        XCTAssertFalse(cache.completedSave { self.randomized })
        let otherTrainer = BoundRRDexSave(trainerID: 99, randomAbilities: true, randomLearnset: true)
        XCTAssertTrue(cache.completedSave { otherTrainer })
        XCTAssertEqual(try cache.value(completedSave: { XCTFail(); return self.original }, restoredSave: {
            XCTFail(); return self.original
        }), otherTrainer)
    }

    func testStateLoadUsesLiveMemoryOnceAndNeverFallsBackToOlderDisk() throws {
        let cache = BoundRRDexSaveCache()
        cache.completedSave { self.original }
        cache.invalidate(restoredState: true)
        XCTAssertThrowsError(try cache.value(completedSave: { XCTFail(); return self.original }, restoredSave: {
            throw BoundRRDexSave.ImportError.cannotPause
        }))
        var exports = 0
        for _ in 0..<3 {
            XCTAssertEqual(try cache.value(completedSave: { XCTFail(); return self.original }, restoredSave: {
                exports += 1; return self.randomized
            }), randomized)
        }
        XCTAssertEqual(exports, 1)
        cache.invalidate(restoredState: true)
        XCTAssertTrue(cache.completedSave { self.original }, "A subsequent battery write contains the restored state's settings")
        XCTAssertEqual(try cache.value(completedSave: { XCTFail(); return self.randomized }, restoredSave: {
            XCTFail(); return self.randomized
        }), original)
    }

    func testUnsupportedRestoredStateClearsOldSettingsAndRecoversOnSave() throws {
        let cache = BoundRRDexSaveCache()
        cache.completedSave { self.original }
        cache.invalidate(restoredState: true)
        XCTAssertThrowsError(try cache.value(completedSave: { XCTFail(); return self.original }, restoredSave: {
            throw BoundRRDexSave.ImportError.difficulty
        })) { XCTAssertEqual($0 as? BoundRRDexSave.ImportError, .difficulty) }
        XCTAssertFalse(cache.completedSave { throw BoundRRDexSave.ImportError.difficulty })
        XCTAssertTrue(cache.completedSave { self.randomized })
        XCTAssertEqual(try cache.value(completedSave: { XCTFail(); return self.original }, restoredSave: {
            XCTFail(); return self.original
        }), randomized)
    }

    func testInvalidationOvertakesPendingReadsAndDisabledSavesRefreshOnEntry() throws {
        let cache = BoundRRDexSaveCache()
        XCTAssertFalse(cache.completedSave {
            cache.invalidate(restoredState: true)
            return self.original
        }, "A disk read started before a state load must not replace the restored settings")
        XCTAssertEqual(try cache.value(completedSave: { XCTFail(); return self.original }, restoredSave: {
            self.randomized
        }), randomized)
        cache.invalidate(restoredState: false)
        XCTAssertEqual(try cache.value(completedSave: { self.original }, restoredSave: {
            XCTFail(); return self.randomized
        }), original)
    }

    func testMissingSaveCanBeRetriedWithoutExporting() throws {
        let cache = BoundRRDexSaveCache()
        XCTAssertThrowsError(try cache.value(completedSave: {
            throw BoundRRDexSave.ImportError.currentGameUnavailable
        }, restoredSave: { XCTFail(); return self.original }))
        XCTAssertEqual(try cache.value(completedSave: { self.original }, restoredSave: {
            XCTFail(); return self.randomized
        }), original)
    }
}

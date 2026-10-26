import XCTest
import CoreData
@preconcurrency import DeltaCore
@testable import Delta
@testable import class Delta.Game

private final class SoulOwnershipFrameCallback: @unchecked Sendable {
    let core: EmulatorCore
    let probe: BoundSoulProbe
    let completed: XCTestExpectation
    let returned = DispatchSemaphore(value: 0)

    init(core: EmulatorCore, probe: BoundSoulProbe, completed: XCTestExpectation) {
        self.core = core; self.probe = probe; self.completed = completed
    }
    func run() {
        // The core is paused: this worker exclusively owns one native frame
        // and then the same completed-frame probe entry used by the app.
        core.deltaCore.emulatorBridge.runFrame(processVideo: false)
        probe.receive(core)
        returned.signal(); completed.fulfill()
    }
}

final class SoulProbeOwnershipTests: XCTestCase {
    @MainActor func testCoreDataGameFrameCallbackUsesConfiguredURLWithoutWaitingForMainQueue() async throws {
        let modelURL = try XCTUnwrap(Bundle(for: DatabaseManager.self).url(forResource: "Delta", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let game = Game(entity: try XCTUnwrap(model.entitiesByName["Game"]), insertInto: context)
        game.identifier = UUID().uuidString; game.filename = game.identifier + ".gba"
        game.name = "Soul ownership fixture"; game.type = .gba
        let cartridge = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let rom = game.fileURL, battery = game.gameSaveURL
        try FileManager.default.createDirectory(at: rom.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: cartridge, to: rom)
        let core = try XCTUnwrap(EmulatorCore(game: game, options: [.metal: true]))
        let probe = BoundSoulProbe()
        defer {
            _ = probe.configure(core: nil, url: nil)
            _ = core.stop()
            try? FileManager.default.removeItem(at: rom)
            try? FileManager.default.removeItem(at: battery)
            context.reset()
        }
        try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(core)
        XCTAssertTrue(probe.configure(core: core, url: nil))
        probe.setVerified(true); probe.setPreviewEnabled(true)

        // A changed managed object's URL must not silently replace the URL
        // belonging to this admitted native execution and owner generation.
        game.filename = UUID().uuidString + ".gba"
        let callback = SoulOwnershipFrameCallback(core: core, probe: probe,
            completed: expectation(description: "Core Data-backed completed frame returns"))
        DispatchQueue.global(qos: .userInitiated).async { callback.run() }
        // Deliberately do not pump the main queue. The old callback requested
        // Game.fileURL via performAndWait and timed out here. Releasing this
        // bounded wait lets that old callback finish, so a regression fails
        // without wedging the test runner during cleanup.
        XCTAssertEqual(callback.returned.wait(timeout: .now() + 2), .success)
        await fulfillment(of: [callback.completed], timeout: 3)
        XCTAssertNil(probe.read().error, "Native ownership must use the captured execution URL")

        // A new generation must capture the changed URL, not inherit the old
        // matching native-owner URL. The bridge rejects that mismatch.
        XCTAssertTrue(probe.configure(core: core, url: nil))
        probe.setVerified(true); probe.setPreviewEnabled(true)
        let rebound = SoulOwnershipFrameCallback(core: core, probe: probe,
            completed: expectation(description: "Rebound owner rejects changed cartridge URL"))
        DispatchQueue.global(qos: .userInitiated).async { rebound.run() }
        XCTAssertEqual(rebound.returned.wait(timeout: .now() + 2), .success)
        await fulfillment(of: [rebound.completed], timeout: 3)
        XCTAssertNotNil(probe.read().error)

        XCTAssertTrue(probe.configure(core: nil, url: nil))
        let detached = SoulOwnershipFrameCallback(core: core, probe: probe,
            completed: expectation(description: "Detached owner's late callback is ignored"))
        DispatchQueue.global(qos: .userInitiated).async { detached.run() }
        XCTAssertEqual(detached.returned.wait(timeout: .now() + 2), .success)
        await fulfillment(of: [detached.completed], timeout: 3)
        XCTAssertNil(probe.read().error)
    }
}

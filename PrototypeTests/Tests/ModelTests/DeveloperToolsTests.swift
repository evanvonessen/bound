import Foundation
import XCTest
@testable import Models

final class DeveloperToolsTests: XCTestCase {
    func testMigrationPreservesEitherOptInAndDoesNotResurrectAfterOptOut() throws {
        for developer in [nil, false, true] as [Bool?] {
            for debugging in [nil, false, true] as [Bool?] {
                let suite = "DeveloperToolsTests." + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(developer, forKey: BoundDeveloperFeatures.key)
                defaults.set(debugging, forKey: BoundDeveloperFeatures.legacyDebuggingKey)
                let protected: [String: Any] = [
                    "bound.experimental-multiplayer.enabled.v1": false,
                    "bound.rom-updates.enabled.v1": true,
                    "bound.rom-updates.folder-bookmark.v1": Data([1, 2, 3]),
                    "com.evanvonessen.bound.github.signed-out": false,
                    "bound.notes.v1.fixture-rom": "private notes",
                    "bound.controls.v1.fixture": Data([4, 5, 6])
                ]
                for (key, value) in protected { defaults.set(value, forKey: key) }

                BoundDeveloperFeatures.migrate(in: defaults)
                XCTAssertEqual(defaults.bool(forKey: BoundDeveloperFeatures.key), developer == true || debugging == true)
                XCTAssertNil(defaults.object(forKey: BoundDeveloperFeatures.legacyDebuggingKey))
                for (key, value) in protected {
                    XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject)
                }
                // Reopening the preferences must honor a later opt-out.
                defaults.set(false, forKey: BoundDeveloperFeatures.key)
                let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
                BoundDeveloperFeatures.migrate(in: relaunched)
                XCTAssertFalse(relaunched.bool(forKey: BoundDeveloperFeatures.key))
            }
        }
    }
}

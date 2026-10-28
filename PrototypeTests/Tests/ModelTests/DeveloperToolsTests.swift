import Foundation
import XCTest
@testable import Models

final class DeveloperToolsTests: XCTestCase {
    func testFriendArrowPreferenceIsIndependentOfDeveloperModeAndPersists() throws {
        let suite = "FriendArrowTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for developer in [false, true] {
            defaults.set(developer, forKey: BoundDeveloperFeatures.key)
            defaults.removeObject(forKey: BoundDirectionalFriendArrow.key)
            XCTAssertTrue(BoundDirectionalFriendArrow.isEnabled(in: defaults))
            for enabled in [false, true] {
                defaults.set(enabled, forKey: BoundDirectionalFriendArrow.key)
                XCTAssertEqual(BoundDirectionalFriendArrow.isEnabled(in: try XCTUnwrap(UserDefaults(suiteName: suite))), enabled)
            }
        }
    }
    func testDamagePreferenceSurvivesRelaunchAndChangesPersonalROMPort() throws {
        let suite = "DamagePreferences." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(BoundDamageCalculations.isEnabled(in: defaults))
        for enabled in [false, true, false] {
            defaults.set(enabled, forKey: BoundDamageCalculations.key)
            let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
            var frame = Data(repeating: 0x55, count: 2048)
            BoundDamageCalculations.apply(to: &frame, in: relaunched)
            XCTAssertEqual(frame[1424], enabled ? 1 : 0)
            XCTAssertEqual(frame.subdata(in: 1420..<1424), Data("DMC1".utf8))
            XCTAssertEqual(frame.prefix(1420), Data(repeating: 0x55, count: 1420))
            XCTAssertEqual(frame.suffix(623), Data(repeating: 0x55, count: 623))
        }
    }
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

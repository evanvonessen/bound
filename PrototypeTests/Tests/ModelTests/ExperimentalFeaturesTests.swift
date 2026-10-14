import Foundation
import XCTest
@testable import Models

final class ExperimentalFeaturesTests: XCTestCase {
    func testFreshInstallIsOffWithoutSavingAnOptIn() throws {
        let suite = "BoundExperimentalFeatures." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(BoundExperimentalFeaturesPreferences(defaults: defaults).isEnabled)
        XCTAssertNil(defaults.object(forKey: BoundExperimentalFeaturesPreferences.enabledKey))
    }

    func testOptInAndOptOutPersistWithoutChangingBuild13Preferences() throws {
        let suite = "BoundExperimentalFeatures." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = BoundAppearancePreferences(defaults: defaults)
        appearance.theme = .minimal
        appearance.screenLayout = .delta
        defaults.set(0.4, forKey: "bound.delta.pip.v1.friend.opacity")
        defaults.set(false, forKey: "isButtonHapticFeedbackEnabled")
        let preferences = BoundExperimentalFeaturesPreferences(defaults: defaults)

        for enabled in [true, false] {
            preferences.isEnabled = enabled
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(BoundExperimentalFeaturesPreferences(defaults: reopened).isEnabled, enabled)
            XCTAssertTrue(BoundFeatureVisibility.simplifiedSettings)
            XCTAssertEqual(appearance.effectiveTheme, .delta)
            XCTAssertEqual(appearance.effectiveScreenLayout, .bound)
            XCTAssertEqual(appearance.theme, .minimal)
            XCTAssertEqual(appearance.screenLayout, .delta)
            XCTAssertEqual(reopened.double(forKey: "bound.delta.pip.v1.friend.opacity"), 0.4)
            XCTAssertFalse(reopened.bool(forKey: "isButtonHapticFeedbackEnabled"))
        }
    }

    func testObserversAreNotifiedOnlyWhenTheGateChanges() throws {
        let suite = "BoundExperimentalFeatures." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundExperimentalFeaturesPreferences(defaults: defaults)
        let notification = XCTNSNotificationExpectation(
            name: BoundExperimentalFeaturesPreferences.didChangeNotification,
            object: preferences
        )
        notification.expectedFulfillmentCount = 2
        notification.assertForOverFulfill = true

        preferences.isEnabled = false
        preferences.isEnabled = true
        preferences.isEnabled = true
        preferences.isEnabled = false
        preferences.isEnabled = false

        wait(for: [notification], timeout: 1)
    }
}

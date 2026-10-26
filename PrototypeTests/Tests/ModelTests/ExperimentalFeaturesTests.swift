import Foundation
import XCTest
@testable import Models

final class ExperimentalFeaturesTests: XCTestCase {
    @MainActor
    func testLegacyPreferenceNeverChangesPermanentFeatureBaseline() throws {
        let suite = "BoundFeatureBaseline." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let baseline = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertNil(baseline.object(forKey: BoundLegacyPreferences.experimentalFeaturesKey))
        assertBaseline(defaults: baseline)

        let uiVersion = BoundUIVersionPreferences(defaults: defaults)
        uiVersion.version = .option2
        let button = BoundCompanionButtonPreferences(defaults: defaults)
        button.buttonType = .option3
        let companion = BoundPiPPreferences(defaults: defaults)
        companion.setEnabled(false, for: .notes)
        companion.setContentOrder([.dex, .friend, .types, .notes, .bosses])
        defaults.set(BoundReferenceLayout.layout4.rawValue, forKey: BoundReferenceLayoutPreferences.dexKey)
        defaults.set(BoundReferenceLayout.layout9.rawValue, forKey: BoundReferenceLayoutPreferences.bossKey)

        for legacyValue in [false, true] {
            defaults.set(legacyValue, forKey: BoundLegacyPreferences.experimentalFeaturesKey)
            let upgradedInstall = try XCTUnwrap(UserDefaults(suiteName: suite))
            assertBaseline(defaults: upgradedInstall, option1: [.friend, .types, .bosses, .dex, .connections],
                           option2: [.dex, .friend, .types, .bosses, .connections])
            XCTAssertEqual(BoundUIVersionPreferences(defaults: upgradedInstall).version, .option2)
            XCTAssertEqual(BoundCompanionButtonPreferences(defaults: upgradedInstall).buttonType, .option3)
            XCTAssertEqual(BoundPiPPreferences(defaults: upgradedInstall).orderedContents,
                           [.dex, .friend, .types, .notes, .bosses, .connections])
            XCTAssertEqual(upgradedInstall.integer(forKey: BoundReferenceLayoutPreferences.dexKey), 4)
            XCTAssertEqual(upgradedInstall.integer(forKey: BoundReferenceLayoutPreferences.bossKey), 9)
        }
        XCTAssertTrue(BoundFeatureVisibility.simplifiedSettings)
    }

    @MainActor
    private func assertBaseline(defaults: UserDefaults,
                                option1: [BoundPiPContent] = [.friend, .notes, .types, .bosses, .dex, .connections],
                                option2: [BoundPiPContent] = [.friend, .notes, .types, .bosses, .dex, .connections],
                                file: StaticString = #filePath, line: UInt = #line) {
        let uiVersion = BoundUIVersionPreferences(defaults: defaults)
        let button = BoundCompanionButtonPreferences(defaults: defaults)
        let companion = BoundPiPPreferences(defaults: defaults)

        XCTAssertEqual(uiVersion.effectiveVersion, uiVersion.version, file: file, line: line)
        XCTAssertEqual(button.effectiveButtonType, button.buttonType, file: file, line: line)
        XCTAssertEqual(BoundPiPContent.cycleOrder, [.friend, .notes, .types, .bosses, .dex, .connections], file: file, line: line)
        XCTAssertEqual(companion.enabledContents(uiVersion: .option1), option1, file: file, line: line)
        XCTAssertEqual(companion.enabledContents(uiVersion: .option2), option2, file: file, line: line)
    }
}

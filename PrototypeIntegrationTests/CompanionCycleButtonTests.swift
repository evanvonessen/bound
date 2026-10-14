import XCTest
import UIKit
import SwiftUI
@testable import Delta

@MainActor
final class CompanionCycleButtonTests: XCTestCase {
    func testDexCardRendersAtPortraitAndLandscapePanelSizes() throws {
        let preferences = BoundExperimentalFeaturesPreferences()
        let wasEnabled = preferences.isEnabled
        preferences.isEnabled = true
        defer { preferences.isEnabled = wasEnabled }
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController)
        for (name, size) in [("portrait", CGSize(width: 390, height: 195)), ("landscape", CGSize(width: 330, height: 275))] {
            let host = UIHostingController(rootView: BoundRRDexView(gameID: "RRDEX_RENDER_QA", presentationChanged: { _ in }))
            parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
            host.view.frame = CGRect(origin: CGPoint(x: 0, y: 60), size: size)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            host.view.layoutIfNeeded()
            func searchField(_ view: UIView) -> UITextField? {
                if let field = view as? UITextField { return field }
                return view.subviews.lazy.compactMap(searchField).first
            }
            let search = try XCTUnwrap(searchField(host.view))
            XCTAssertGreaterThan(search.bounds.width, 150)
            XCTAssertEqual(search.autocapitalizationType, .none)
            let renderer = UIGraphicsImageRenderer(size: size)
            let snapshot = renderer.image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
            XCTAssertGreaterThan(try XCTUnwrap(snapshot.pngData()).count, 5000)
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = "RRDex-hosted-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }
    func testDexSearchDisablesCorrectionCapitalizationSpellingAndSmartEdits() {
        let field = BoundRRDexSearchField.makeTextField()
        XCTAssertEqual(field.autocapitalizationType, .none)
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertEqual(field.spellCheckingType, .no)
        XCTAssertEqual(field.smartQuotesType, .no)
        XCTAssertEqual(field.smartDashesType, .no)
        XCTAssertEqual(field.smartInsertDeleteType, .no)
        XCTAssertEqual(field.inlinePredictionType, .no)
    }
    func testExperimentalBossCycleFallsBackImmediatelyWhenDisabled() {
        let state = BoundCompanionState(experimentalFeaturesEnabled: false)
        for expected in [BoundPiPContent.notes, .types, .friend, .notes, .types, .friend] {
            state.advancePanel()
            XCTAssertEqual(state.content, expected)
        }
        state.updateExperimentalFeatures(true)
        for expected in [BoundPiPContent.notes, .types, .bosses, .dex] {
            state.advancePanel()
            XCTAssertEqual(state.content, expected)
        }
        state.hidden = true
        state.updateExperimentalFeatures(false)
        XCTAssertEqual(state.content, .friend)
        XCTAssertEqual(state.selected, 0)
        XCTAssertFalse(state.hidden)
        XCTAssertEqual(state.availableContents, [.friend, .notes, .types])
        state.selected = 3
        XCTAssertEqual(state.content, .friend, "A stale experimental selection must not expose the guide")
    }
    func testPortraitMirrorKeepsDefaultAndAvoidsMovedInput() throws {
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 800)
        let menu = CGRect(x: 20, y: 740, width: 20, height: 20)
        let button = BoundCompanionCycleButton()
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                         content: .friend, canvas: canvas, occupied: [menu])
        XCTAssertEqual(button.frame.midX, 360, accuracy: 0.001)
        XCTAssertEqual(button.frame.midY, 750, accuracy: 0.001)
        let movedA = button.frame.insetBy(dx: -4, dy: -4)
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                         content: .notes, canvas: canvas, occupied: [menu, movedA])
        XCTAssertFalse(button.isHidden); XCTAssertTrue(canvas.contains(button.frame))
        XCTAssertFalse(button.frame.intersects(menu)); XCTAssertFalse(button.frame.intersects(movedA))
        XCTAssertEqual(button.accessibilityValue, "Notes")
    }
    func testLandscapeChecksCollisionAfterEdgeClamping() throws {
        let canvas = CGRect(x: 50, y: 0, width: 700, height: 350)
        let menu = CGRect(x: 680, y: 8, width: 60, height: 30)
        let blocked = CGRect(x: 610, y: 0, width: 140, height: 70)
        let button = BoundCompanionCycleButton()
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: true, minimal: false,
                         content: .types, canvas: canvas, occupied: [blocked])
        XCTAssertFalse(button.isHidden); XCTAssertTrue(canvas.contains(button.frame))
        XCTAssertFalse(button.frame.intersects(blocked)); XCTAssertEqual(button.accessibilityValue, "Types")
    }
    func testNoClearSpaceDoesNotStealNativeInputsAndRecoversAfterReset() {
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 100)
        let button = BoundCompanionCycleButton()
        let menu = CGRect(x: 10, y: 10, width: 20, height: 20)
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                         content: .friend, canvas: canvas, occupied: [canvas])
        XCTAssertTrue(button.isHidden); XCTAssertFalse(button.isUserInteractionEnabled); XCTAssertEqual(button.frame, .zero)
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                         content: .friend, canvas: canvas, occupied: [menu])
        XCTAssertFalse(button.isHidden); XCTAssertTrue(button.isUserInteractionEnabled)
    }
    func testBoundCycleUsesOneNativeFeedbackAndOneCyclePerCompletedTap() {
        let oldLayout = BoundAppearancePreferences().screenLayout
        let oldFeedback = Settings.isButtonHapticFeedbackEnabled
        defer { BoundAppearancePreferences().screenLayout = oldLayout; Settings.isButtonHapticFeedbackEnabled = oldFeedback }
        for landscape in [false, true] {
            let button = BoundCompanionCycleButton()
            let canvas = CGRect(x: 0, y: 0, width: 844, height: 390)
            button.configure(menuFrame: CGRect(x: 20, y: 40, width: 73, height: 26), controllerFrame: canvas,
                landscape: landscape, minimal: false, content: .friend, canvas: canvas, occupied: [])
            var feedback = 0, cycles = 0
            button.buttonFeedback = { feedback += 1 }
            button.cycle = { cycles += 1 }
            BoundAppearancePreferences().screenLayout = .bound
            Settings.isButtonHapticFeedbackEnabled = true
            button.sendActions(for: .touchDown)
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 1)
            XCTAssertEqual(cycles, 1)
            button.sendActions(for: .touchCancel)
            button.sendActions(for: .touchUpOutside)
            XCTAssertEqual(feedback, 1)
            XCTAssertEqual(cycles, 1)
            Settings.isButtonHapticFeedbackEnabled = false
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 1)
            XCTAssertEqual(cycles, 2)
            BoundAppearancePreferences().screenLayout = .delta
            // Build 13's simplified presentation retains the saved choice but
            // still uses Bound, including its existing native button feedback.
            XCTAssertEqual(BoundAppearancePreferences().effectiveScreenLayout, .bound)
            Settings.isButtonHapticFeedbackEnabled = true
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 2)
            XCTAssertEqual(cycles, 3)
            BoundAppearancePreferences().screenLayout = .bound
            button.isEnabled = false
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 2)
            XCTAssertEqual(cycles, 3)
        }
    }

    func testBoundPortraitMaterialPressMatchesNativeDepthAndCancelNeverCycles() {
        let originalLayout = BoundAppearancePreferences().screenLayout
        let originalFeedback = Settings.isButtonHapticFeedbackEnabled
        defer { BoundAppearancePreferences().screenLayout = originalLayout; Settings.isButtonHapticFeedbackEnabled = originalFeedback }
        BoundAppearancePreferences().screenLayout = .bound
        Settings.isButtonHapticFeedbackEnabled = true
        let material = UIGraphicsImageRenderer(size: CGSize(width: 17, height: 17)).image { _ in
            UIColor.lightGray.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: 17, height: 17)).fill()
        }
        let button = BoundCompanionCycleButton()
        button.configure(menuFrame: CGRect(x: 20, y: 200, width: 17, height: 17),
            controllerFrame: CGRect(x: 0, y: 0, width: 390, height: 300), landscape: false,
            minimal: false, content: .friend, canvas: CGRect(x: 0, y: 0, width: 390, height: 300), occupied: [], boundPortrait: true, selectArtwork: material)
        var cycles = 0, feedback = 0
        button.cycle = { cycles += 1 }; button.buttonFeedback = { feedback += 1 }
        let hit = button.frame, normal = button.materialFrame
        button.sendActions(for: .touchDown)
        XCTAssertTrue(button.isHighlighted)
        XCTAssertEqual(button.materialFrame.width, normal.width-4, accuracy: 0.001)
        XCTAssertEqual(button.materialFrame.height, normal.height-4, accuracy: 0.001)
        XCTAssertEqual(button.frame, hit)
        XCTAssertEqual(feedback, 0); XCTAssertEqual(cycles, 0)
        button.sendActions(for: .touchCancel)
        XCTAssertFalse(button.isHighlighted); XCTAssertEqual(button.materialFrame, normal)
        XCTAssertEqual(feedback, 0); XCTAssertEqual(cycles, 0)
        button.sendActions(for: .touchDown); button.sendActions(for: .touchUpInside)
        XCTAssertFalse(button.isHighlighted); XCTAssertEqual(button.materialFrame, normal)
        XCTAssertEqual(feedback, 1); XCTAssertEqual(cycles, 1)
    }

    func testMinimalCompanionArtworkFitsNarrowRightGutters() {
        for width: CGFloat in [44, 45, 47, 52.25, 106] {
            let gutter = CGRect(x: 500, y: 0, width: width, height: 200)
            let button = BoundCompanionCycleButton()
            button.configure(menuFrame: CGRect(x: 500, y: 10, width: min(48, width), height: 20),
                controllerFrame: CGRect(x: 0, y: 0, width: 700, height: 390), landscape: true,
                minimal: true, content: .types, canvas: CGRect(x: 0, y: 0, width: 700, height: 390),
                occupied: [], menuHitSize: CGSize(width: 106, height: 56), rightControlGutter: gutter)
            XCTAssertFalse(button.isHidden)
            XCTAssertTrue(gutter.contains(button.frame))
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertTrue(button.bounds.contains(button.artworkFrame))
            XCTAssertLessThanOrEqual(button.artworkFrame.width, width)
        }
    }

    func testBoundNotesDisablesCorrectionAndSpellingAndHonorsDisabledState() {
        for enabled in [true, false] {
            let host = UIHostingController(rootView: BoundNotesTextView(text: .constant("Existing note"), editing: .constant(false)).disabled(!enabled))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            func find(_ view: UIView) -> UITextView? {
                if let text = view as? UITextView { return text }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            guard let editor = find(host.view) else { XCTFail("Missing real Notes UITextView"); continue }
            XCTAssertEqual(editor.autocorrectionType, .no)
            XCTAssertEqual(editor.spellCheckingType, .no)
            XCTAssertEqual(editor.text, "Existing note")
            XCTAssertEqual(editor.isEditable, enabled)
            XCTAssertEqual(editor.isSelectable, enabled)
            XCTAssertEqual(editor.isUserInteractionEnabled, enabled)
            XCTAssertTrue(editor.adjustsFontForContentSizeCategory)
            window.isHidden = true
        }
    }

}

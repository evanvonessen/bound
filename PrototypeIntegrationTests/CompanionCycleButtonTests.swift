import XCTest
import UIKit
import SwiftUI
@testable import Delta

@MainActor
final class CompanionCycleButtonTests: XCTestCase {
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
            Settings.isButtonHapticFeedbackEnabled = true
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 1)
            XCTAssertEqual(cycles, 3)
            BoundAppearancePreferences().screenLayout = .bound
            button.isEnabled = false
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 1)
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

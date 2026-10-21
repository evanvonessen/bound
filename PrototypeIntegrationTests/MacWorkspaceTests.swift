import XCTest
import UIKit
import DeltaCore
@testable import Delta

final class MacWorkspaceGeometryTests: XCTestCase {
    func testSidebarBreakpointsMatchWorkspaceWidth() {
        XCTAssertEqual(BoundMacWorkspaceGeometry(bounds: CGRect(x: 0, y: 0, width: 1080, height: 800)).sidebar.width, 176)
        XCTAssertEqual(BoundMacWorkspaceGeometry(bounds: CGRect(x: 0, y: 0, width: 1079, height: 800)).sidebar.width, 64)
        XCTAssertEqual(BoundMacWorkspaceGeometry(bounds: CGRect(x: 0, y: 0, width: 840, height: 700)).sidebar.width, 64)
        XCTAssertEqual(BoundMacWorkspaceGeometry(bounds: CGRect(x: 0, y: 0, width: 839, height: 700)).sidebar.width, 0)
    }

    func testWorkspaceRegionsStayContainedAndDoNotOverlap() {
        let sizes = [
            CGSize(width: 1728, height: 1117),
            CGSize(width: 1440, height: 900),
            CGSize(width: 1080, height: 800),
            CGSize(width: 1024, height: 768),
            CGSize(width: 840, height: 700),
            CGSize(width: 760, height: 900),
            CGSize(width: 600, height: 720)
        ]

        for size in sizes {
            let bounds = CGRect(origin: .zero, size: size)
            let geometry = BoundMacWorkspaceGeometry(bounds: bounds)
            let regions: [(String, CGRect)] = [
                ("sidebar", geometry.sidebar),
                ("toolbar", geometry.toolbar),
                ("gameplay", geometry.gameplay),
                ("footer", geometry.footer),
                ("inspector", geometry.inspector)
            ]

            for (name, frame) in regions {
                XCTAssertFalse(frame.isNull, "\(name) must have a concrete frame at \(size)")
                XCTAssertGreaterThanOrEqual(frame.width, 0, "\(name) width at \(size)")
                XCTAssertGreaterThanOrEqual(frame.height, 0, "\(name) height at \(size)")
                XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name) must stay inside \(bounds): \(frame)")
            }

            for first in regions.indices {
                for second in regions.indices where second > first {
                    let overlap = regions[first].1.intersection(regions[second].1)
                    XCTAssertFalse(overlap.width > 1 && overlap.height > 1,
                                   "\(regions[first].0) overlaps \(regions[second].0) at \(size): \(overlap)")
                }
            }

            XCTAssertGreaterThan(geometry.gameplay.width, 160, "The game view should remain useful at \(size)")
            XCTAssertGreaterThan(geometry.gameplay.height, 200, "The game view should remain useful at \(size)")
        }
    }

    func testMacWorkspaceIsNotEnabledByDefaultOutsideMac() throws {
        guard !ProcessInfo.processInfo.isiOSAppOnMac else {
            throw XCTSkip("The host is already running as an iOS app on Mac.")
        }
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("--bound-ui-mac-workspace"))
        XCTAssertFalse(BoundMacWorkspacePlatform.isEnabled,
                       "An ordinary iPhone or iPad launch must retain the existing companion UI.")
    }
}

@MainActor
final class MacWorkspaceControllerRoutingTests: XCTestCase {
    func testVisibleMacMultiviewPreservesKeyboardGameplayAndAssignedShortcuts() throws {
        var keyboard = DeltaCore.GameControllerInputMapping(gameControllerInputType: .keyboard)
        keyboard.set(StandardGameControllerInput.up, forControllerInput: KeyboardGameController.Input.up)
        keyboard.set(ActionInput.toggleBoundMultiview, forControllerInput: KeyboardGameController.Input.tab)
        let mapping = BoundMacControllerActionRouting.inputMapping(
            BoundControllerInputMapping(base: keyboard, multiviewActive: true))
        XCTAssertEqual(StandardGameControllerInput(input: try XCTUnwrap(
            mapping.input(forControllerInput: KeyboardGameController.Input.up))), .up)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(
            mapping.input(forControllerInput: KeyboardGameController.Input.tab))), .toggleBoundMultiview)

        let gamepad = DeltaCore.GameControllerInputMapping(gameControllerInputType: .mfi)
        let captured = BoundMacControllerActionRouting.inputMapping(
            BoundControllerInputMapping(base: gamepad, multiviewActive: true))
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(
            captured.input(forControllerInput: MFiGameController.Input.up))), .boundFocusUp)
    }

    func testControllerModeOrMultiviewEnablesMacNavigationUntilSettingsSheetOpens() {
        XCTAssertTrue(BoundMacControllerActionRouting.isEnabled(
            controllerMode: true, multiview: false, showingFriends: false, showingSettings: false))
        XCTAssertTrue(BoundMacControllerActionRouting.isEnabled(
            controllerMode: false, multiview: true, showingFriends: false, showingSettings: false))
        XCTAssertFalse(BoundMacControllerActionRouting.isEnabled(
            controllerMode: false, multiview: false, showingFriends: false, showingSettings: false))
        XCTAssertFalse(BoundMacControllerActionRouting.isEnabled(
            controllerMode: true, multiview: false, showingFriends: true, showingSettings: false))
        XCTAssertFalse(BoundMacControllerActionRouting.isEnabled(
            controllerMode: false, multiview: true, showingFriends: false, showingSettings: true))
    }

    func testMappedActionsShowHideAndCycleMacReferenceAndFriend() {
        let state = BoundCompanionState()
        state.macReference = .bosses
        state.macReferenceVisible = false
        state.macFriendVisible = true

        BoundMacControllerActionRouting.apply(.boundShowTypes, to: state)
        XCTAssertEqual(state.macReference, .types)
        XCTAssertTrue(state.macReferenceVisible)

        BoundMacControllerActionRouting.apply(.boundHideMultiview, to: state)
        XCTAssertFalse(state.macReferenceVisible)
        BoundMacControllerActionRouting.apply(.boundNextView, to: state)
        XCTAssertEqual(state.macReference, .dex)
        XCTAssertTrue(state.macReferenceVisible)
        BoundMacControllerActionRouting.apply(.boundPreviousView, to: state)
        XCTAssertEqual(state.macReference, .types)

        BoundMacControllerActionRouting.apply(.boundHideFriend, to: state)
        XCTAssertFalse(state.macFriendVisible)
        BoundMacControllerActionRouting.apply(.toggleBoundFriend, to: state)
        XCTAssertTrue(state.macFriendVisible)
        BoundMacControllerActionRouting.apply(.toggleBoundMultiview, to: state)
        XCTAssertFalse(state.macReferenceVisible)
    }
}

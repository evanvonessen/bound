import XCTest
import UIKit
import DeltaCore
@testable import Delta

final class MacWorkspaceGeometryTests: XCTestCase {
    func testHidingSidebarGivesGameplayTheEntireWorkspace() {
        let bounds = CGRect(x: 12, y: 24, width: 1440, height: 900)
        let visible = BoundMacWorkspaceGeometry(bounds: bounds)
        let hidden = BoundMacWorkspaceGeometry(bounds: bounds, sidebarVisible: false)

        XCTAssertEqual(hidden.gameplay, bounds)
        XCTAssertEqual(hidden.inspector, .zero)
        XCTAssertEqual(hidden.resizeHandle, .zero)
        XCTAssertGreaterThan(hidden.gameplay.width, visible.gameplay.width)
        XCTAssertEqual(visible.gameplay.minX, bounds.minX)
        XCTAssertEqual(visible.gameplay.minY, bounds.minY)
        XCTAssertEqual(visible.gameplay.height, bounds.height,
                       "Removed top and bottom bars must no longer reserve gameplay space.")
        XCTAssertTrue(bounds.contains(hidden.controls), "The sidebar toggle must remain reachable when hidden.")
    }

    func testSidebarWidthCanExpandAndClampsToKeepGameplayUsable() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let narrow = BoundMacWorkspaceGeometry(bounds: bounds, preferredSidebarWidth: 340)
        let wide = BoundMacWorkspaceGeometry(bounds: bounds, preferredSidebarWidth: 560)
        let oversized = BoundMacWorkspaceGeometry(bounds: bounds, preferredSidebarWidth: 5000)

        XCTAssertGreaterThan(wide.inspector.width, narrow.inspector.width)
        XCTAssertLessThan(wide.gameplay.width, narrow.gameplay.width)
        XCTAssertGreaterThanOrEqual(oversized.gameplay.width, 240)
        XCTAssertTrue(bounds.contains(oversized.inspector))
        XCTAssertGreaterThan(narrow.resizeHandle.width, 0)
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
            for preferredWidth: CGFloat in [280, 420, 700] {
                let bounds = CGRect(origin: .zero, size: size)
                let geometry = BoundMacWorkspaceGeometry(bounds: bounds, preferredSidebarWidth: preferredWidth)
                let regions: [(String, CGRect)] = [
                    ("gameplay", geometry.gameplay),
                    ("inspector", geometry.inspector),
                    ("resizeHandle", geometry.resizeHandle),
                    ("controls", geometry.controls)
                ]

                for (name, frame) in regions {
                    XCTAssertFalse(frame.isNull, "\(name) must have a concrete frame at \(size)")
                    XCTAssertGreaterThanOrEqual(frame.width, 0, "\(name) width at \(size)")
                    XCTAssertGreaterThanOrEqual(frame.height, 0, "\(name) height at \(size)")
                    XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                                  "\(name) must stay inside \(bounds): \(frame)")
                }

                let overlap = geometry.gameplay.intersection(geometry.inspector)
                XCTAssertFalse(overlap.width > 1 && overlap.height > 1,
                               "The sidebar must not cover gameplay at \(size): \(overlap)")
                XCTAssertGreaterThanOrEqual(geometry.gameplay.width, 240,
                                            "The game view should remain useful at \(size)")
                XCTAssertEqual(geometry.gameplay.height, size.height)
                XCTAssertEqual(geometry.inspector.height, size.height)
                XCTAssertEqual(geometry.inspector.maxX, bounds.maxX)
            }
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

    func testMacNavigationRequiresAllowMultiviewAndNoSettingsOrFriendsSheet() {
        XCTAssertTrue(BoundMacControllerActionRouting.isEnabled(
            multiview: true, showingFriends: false, showingSettings: false))
        XCTAssertFalse(BoundMacControllerActionRouting.isEnabled(
            multiview: false, showingFriends: false, showingSettings: false))
        XCTAssertFalse(BoundMacControllerActionRouting.isEnabled(
            multiview: true, showingFriends: true, showingSettings: false))
        XCTAssertFalse(BoundMacControllerActionRouting.isEnabled(
            multiview: true, showingFriends: false, showingSettings: true))
    }

    func testMacGamepadStartsInGameplayAndToggleChangesFocusWithoutHidingReference() {
        let state = BoundCompanionState()
        XCTAssertFalse(state.macControllerFocused)
        XCTAssertTrue(BoundMacControllerActionRouting.allowsPanelAction(.toggleBoundMultiview,
            controllerType: .mfi, multiview: true, state: state))
        XCTAssertFalse(BoundMacControllerActionRouting.allowsPanelAction(.boundNextView,
            controllerType: .mfi, multiview: true, state: state))
        BoundMacControllerActionRouting.apply(.toggleBoundMultiview, to: state)
        XCTAssertTrue(state.macControllerFocused)
        XCTAssertTrue(state.macSidebarVisible)
        XCTAssertTrue(state.macReferenceVisible)
        XCTAssertTrue(BoundMacControllerActionRouting.allowsPanelAction(.boundNextView,
            controllerType: .mfi, multiview: true, state: state))
        BoundMacControllerActionRouting.apply(.toggleBoundMultiview, to: state)
        XCTAssertFalse(state.macControllerFocused)
        XCTAssertTrue(state.macSidebarVisible)
        XCTAssertTrue(state.macReferenceVisible)
    }

    func testMacUnavailableReferencesAndSheetsClearFocusWithoutReacquiringIt() {
        let state = BoundCompanionState()
        for change in [
            { (value: Bool) in state.macSidebarVisible = !value },
            { (value: Bool) in state.macReferenceVisible = !value },
            { (value: Bool) in state.showingFriends = value },
            { (value: Bool) in state.showingSettings = value }
        ] {
            state.macControllerFocused = true
            change(true)
            XCTAssertFalse(state.macControllerFocused)
            XCTAssertFalse(BoundMacControllerActionRouting.canToggleFocus(multiview: true, state: state))
            change(false)
            XCTAssertFalse(state.macControllerFocused, "Reopening the sidebar or dismissing a sheet must preserve gameplay control.")
            XCTAssertTrue(BoundMacControllerActionRouting.canToggleFocus(multiview: true, state: state))
        }
        state.macControllerFocused = true
        state.resetPresentation()
        XCTAssertFalse(state.macControllerFocused)
    }

    func testMacOptOutBlocksEveryPanelBindingWhileExplicitKeyboardShortcutsStillWorkWhenEnabled() {
        let state = BoundCompanionState()
        state.macControllerFocused = true
        for action in ActionInput.configurableActions where action.isBoundPanelAction {
            for type in [GameControllerInputType.mfi, .keyboard] {
                XCTAssertFalse(BoundMacControllerActionRouting.allowsPanelAction(action,
                    controllerType: type, multiview: false, state: state), "Disabled: \(action)")
            }
        }
        state.macControllerFocused = false
        XCTAssertTrue(BoundMacControllerActionRouting.allowsPanelAction(.boundShowDex,
            controllerType: .keyboard, multiview: true, state: state))
        XCTAssertFalse(BoundMacControllerActionRouting.allowsPanelAction(.boundShowDex,
            controllerType: .mfi, multiview: true, state: state))
    }

    func testMacReferenceActionsKeepMiddleAndBottomSelectionsIndependent() {
        let state = BoundCompanionState()
        state.macReference = .bosses
        state.macReference = .notes
        XCTAssertEqual(state.macMidReference, .bosses)
        XCTAssertEqual(state.macBottomReference, .notes)

        state.macSidebarVisible = false
        BoundMacControllerActionRouting.apply(.boundShowTypes, to: state)
        XCTAssertTrue(state.macSidebarVisible, "An explicit reference shortcut must reopen its sidebar.")
        XCTAssertEqual(state.macMidReference, .bosses, "Types must not replace the middle Docs box.")
        XCTAssertEqual(state.macBottomReference, .types)

        BoundMacControllerActionRouting.apply(.boundShowDex, to: state)
        XCTAssertEqual(state.macMidReference, .dex)
        XCTAssertEqual(state.macBottomReference, .types, "Dex must not replace the bottom Types box.")

        state.macSidebarVisible = false
        state.macSidebarVisible = true
        XCTAssertEqual(state.macMidReference, .dex)
        XCTAssertEqual(state.macBottomReference, .types)
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
        XCTAssertEqual(state.macReference, .connections)
        XCTAssertEqual(state.macBottomReference, .connections)
        XCTAssertEqual(state.macMidReference, .bosses, "Opening Connections must keep the other reference box unchanged.")
        BoundMacControllerActionRouting.apply(.boundNextView, to: state)
        XCTAssertEqual(state.macReference, .dex)
        XCTAssertTrue(state.macReferenceVisible)
        BoundMacControllerActionRouting.apply(.boundPreviousView, to: state)
        XCTAssertEqual(state.macReference, .connections)
        BoundMacControllerActionRouting.apply(.boundPreviousView, to: state)
        XCTAssertEqual(state.macReference, .types)

        BoundMacControllerActionRouting.apply(.boundHideFriend, to: state)
        XCTAssertFalse(state.macFriendVisible)
        BoundMacControllerActionRouting.apply(.toggleBoundFriend, to: state)
        XCTAssertTrue(state.macFriendVisible)
        BoundMacControllerActionRouting.apply(.toggleBoundMultiview, to: state)
        XCTAssertTrue(state.macReferenceVisible)
        XCTAssertTrue(state.macControllerFocused)
    }
}

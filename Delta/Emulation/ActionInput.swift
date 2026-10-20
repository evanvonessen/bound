//
//  ActionInput.swift
//  Delta
//
//  Created by Riley Testut on 8/28/17.
//  Copyright © 2017 Riley Testut. All rights reserved.
//

import Foundation
import DeltaCore

public extension GameControllerInputType
{
    static let action = GameControllerInputType("com.rileytestut.Delta.input.action")
}

enum ActionInput: String
{
    case none
    case systemOverlay
    case quickSave
    case quickLoad
    case fastForward
    case toggleFastForward
    case reverseScreens
    case screenshot
    case cycleBoundPanels
    case toggleBoundFriend
    case toggleBoundMultiview
    case boundScrollUp, boundScrollDown, boundScrollLeft, boundScrollRight
    case boundFocusUp, boundFocusDown, boundFocusLeft, boundFocusRight
    case boundPreviousItem, boundNextItem, boundSelect, boundBack, boundDetails
    case boundPreviousView, boundNextView
    case boundHideFriend, boundHideMultiview
    case boundShowDex, boundShowBosses, boundShowTypes

    static let viewNavigationActions: [Self] = [
        .boundScrollUp, .boundScrollDown, .boundScrollLeft, .boundScrollRight,
        .boundPreviousItem, .boundNextItem, .boundSelect, .boundBack, .boundDetails,
        .boundShowDex, .boundShowBosses, .boundShowTypes,
        .boundHideFriend, .boundHideMultiview
    ]
    /// Tab cycling is a basic multiview control and remains available even
    /// when detailed controller navigation is disabled.
    static let multiviewTabActions: [Self] = [.boundPreviousView, .boundNextView]
    static var configurableActions: [Self] {
        [.none, .quickSave, .quickLoad, .fastForward, .screenshot, .cycleBoundPanels, .toggleBoundFriend, .toggleBoundMultiview]
            + multiviewTabActions
            + (BoundControllerNavigationPreferences().isEnabled ? viewNavigationActions : [])
    }
    var isAutomaticFocusAction: Bool { [.boundFocusUp, .boundFocusDown, .boundFocusLeft, .boundFocusRight].contains(self) }
    var isViewNavigationAction: Bool { Self.viewNavigationActions.contains(self) || isAutomaticFocusAction }
    var isMultiviewTabAction: Bool { Self.multiviewTabActions.contains(self) }
    var isBoundPanelAction: Bool {
        self == .cycleBoundPanels || self == .toggleBoundFriend || self == .toggleBoundMultiview || isViewNavigationAction || isMultiviewTabAction
    }
    var navigationCommand: BoundControllerNavigationCommand? {
        switch self {
        case .boundScrollUp: .scrollUp
        case .boundScrollDown: .scrollDown
        case .boundScrollLeft: .scrollLeft
        case .boundScrollRight: .scrollRight
        case .boundPreviousItem: .previousItem
        case .boundNextItem: .nextItem
        case .boundFocusUp: .focusUp
        case .boundFocusDown: .focusDown
        case .boundFocusLeft: .focusLeft
        case .boundFocusRight: .focusRight
        case .boundSelect: .select
        case .boundBack: .back
        case .boundDetails: .details
        default: nil
        }
    }
}

/// One activation per physical hold, using the upstream controller/mapping pipeline.
/// Weak keys do not retain disconnected controllers; release/disconnect re-arm the action.
@MainActor
final class BoundPanelActionRouter {
    private var pressedByAction = [ActionInput: NSHashTable<AnyObject>]()

    func activate(controller: GameController, action: ActionInput = .cycleBoundPanels, eligible: Bool, cycle: () -> Void) {
        let pressed = pressedByAction[action] ?? NSHashTable<AnyObject>.weakObjects()
        guard !pressed.contains(controller) else { return }
        pressed.add(controller)
        pressedByAction[action] = pressed
        if eligible { cycle() }
    }

    func release(controller: GameController, action: ActionInput? = nil) {
        if let action {
            pressedByAction[action]?.remove(controller)
            if pressedByAction[action]?.allObjects.isEmpty == true {
                pressedByAction[action] = nil
            }
        } else {
            for action in Array(pressedByAction.keys) {
                pressedByAction[action]?.remove(controller)
                if pressedByAction[action]?.allObjects.isEmpty == true {
                    pressedByAction[action] = nil
                }
            }
        }
    }
}

extension ActionInput: Input
{
    var type: InputType {
        return .controller(.action)
    }
}

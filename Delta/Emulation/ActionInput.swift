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
    case quickSave
    case quickLoad
    case fastForward
    case toggleFastForward
    case reverseScreens
    case screenshot
    case cycleBoundPanels
    case toggleBoundFriend
    case toggleBoundMultiview
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

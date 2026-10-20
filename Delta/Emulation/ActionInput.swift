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
}

/// One activation per physical hold, using the upstream controller/mapping pipeline.
/// Weak keys do not retain disconnected controllers; release/disconnect re-arm the action.
@MainActor
final class BoundPanelActionRouter {
    private let pressed = NSHashTable<AnyObject>.weakObjects()
    func activate(controller: GameController, eligible: Bool, cycle: () -> Void) {
        guard !pressed.contains(controller) else { return }
        pressed.add(controller)
        if eligible { cycle() }
    }
    func release(controller: GameController) { pressed.remove(controller) }
}

extension ActionInput: Input
{
    var type: InputType {
        return .controller(.action)
    }
}

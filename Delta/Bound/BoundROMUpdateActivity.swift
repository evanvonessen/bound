import UIKit
import DeltaCore

/// A paused game or preview still owns save files and must finish before reset.
@MainActor
enum BoundROMUpdateActivity {
    private static let controllers = NSHashTable<DeltaCore.GameViewController>.weakObjects()

    static var canApply: Bool {
        controllers.allObjects.allSatisfy { $0.game == nil }
    }

    static func bindingChanged(_ controller: DeltaCore.GameViewController) {
        controllers.add(controller)
        if canApply {
            DispatchQueue.main.async { BoundROMUpdateManager.shared.checkNow() }
        }
    }
}

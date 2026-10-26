import UIKit
import DeltaCore

/// A paused game or preview still owns save files and must finish before reset.
@MainActor
enum BoundROMUpdateActivity {
    private static let controllers = NSHashTable<DeltaCore.GameViewController>.weakObjects()
    private(set) static var bindingRevision = UUID()

    static var canApply: Bool {
        controllers.allObjects.allSatisfy { $0.game == nil }
    }

    static func isGameOpen(gameID: String) -> Bool {
        controllers.allObjects.contains { ($0.game as? Game)?.identifier == gameID }
    }

    @discardableResult static func close(gameID: String) -> Bool {
        for controller in controllers.allObjects where (controller.game as? Game)?.identifier == gameID {
            if let preview = controller as? PreviewGameViewController {
                // A preview must restore its temporary battery copy before deletion.
                preview.stopPreview()
            } else if let owner = controller as? GameViewController {
                // The app setter drains pending facts and preserves admitted
                // activity recovery before the upstream setter stops its core.
                // A refused close must keep both the core and its files intact.
                owner.game = nil
                continue
            } else {
                controller.emulatorCore?.stop()
            }
            controller.game = nil
        }
        return !isGameOpen(gameID: gameID)
    }

    static func bindingChanged(_ controller: DeltaCore.GameViewController) {
        bindingRevision = UUID()
        controllers.add(controller)
        if canApply {
            DispatchQueue.main.async { BoundROMUpdateManager.shared.checkNow() }
        }
        if controller.game == nil {
            BoundServerBackupManager.shared.scheduleBackup()
        }
    }
}

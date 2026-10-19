import CoreData
import DeltaCore

extension Settings
{
    /// Clears preferences stored in Core Data while preserving library content and user data.
    /// The caller must invoke this method on `context`'s queue and save the context afterward.
    static func resetDatabasePreferences(in context: NSManagedObjectContext) throws
    {
        let mappings = try context.fetch(GameControllerInputMapping.fetchRequest())
        mappings.forEach(context.delete)

        let games = try context.fetch(Game.fetchRequest())
        for game in games
        {
            game.preferredExternalControllerLandscapeSkin = nil
            game.preferredExternalControllerPortraitSkin = nil
            game.preferredLandscapeSkin = nil
            game.preferredPortraitSkin = nil
            game.preferredSplitViewLandscapeSkin = nil
            game.preferredSplitViewPortraitSkin = nil

            // Remove the known per-game preference keys while preserving the Game,
            // its library metadata, and any future settings keys this version does
            // not understand.
            if var stored = game.gameSettings as? [String: Any] {
                let count = stored.count
                for setting: Game.Setting in [.noExternalControllerSkin, .openGLES2, .retroAchievementsEnabled, .fastForwardSpeed] {
                    stored.removeValue(forKey: setting.rawValue)
                }
                if stored.count != count {
                    game.gameSettings = stored.isEmpty ? nil : stored as NSDictionary
                }
            }
        }
    }
}

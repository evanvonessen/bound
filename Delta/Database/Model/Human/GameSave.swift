//
//  GameSave.swift
//  Delta
//
//  Created by Riley Testut on 8/30/16.
//  Copyright (c) 2016 Riley Testut. All rights reserved.
//

import Foundation

import GBCDeltaCore

import Harmony
import Roxas

@objc(GameSave)
public class GameSave: _GameSave 
{
    // Harmony calls awakeFromSync before moving downloaded files. Keep all
    // multiplayer downloads in an inbox until the ROM can restore them safely.
    private var multiplayerDownloadDirectory: URL?
    private var multiplayerUploadDirectory: URL?

    public override func awakeFromInsert()
    {
        super.awakeFromInsert()
        
        self.modifiedDate = Date()
    }
}

extension GameSave: Syncable
{
    public static var syncablePrimaryKey: AnyKeyPath {
        return \GameSave.identifier
    }
    
    public var syncableKeys: Set<AnyKeyPath> {
        return [\GameSave.modifiedDate, \GameSave.sha1]
    }
    
    public var syncableRelationships: Set<AnyKeyPath> {
        return [\GameSave.game]
    }
    
    public var syncableFiles: Set<File> {
        guard let game = self.game, !game.boundUsesServerMultiplayer else { return [] }
        
        let packages = BoundMultiplayerSaveStore.shared
        let protectedRun = packages.hasRun(gameID: game.identifier)
        let transferDirectory = multiplayerDownloadDirectory ?? multiplayerUploadDirectory
        let packageURL = transferDirectory?.appendingPathComponent("complete.boundrun")
            ?? (protectedRun ? packages.cloudURL(gameID: game.identifier)
                : packages.directory(gameID: game.identifier).appendingPathComponent("no-active-package.boundrun"))
        let batteryURL = transferDirectory?.appendingPathComponent("game.sav")
            ?? (protectedRun ? packages.cloudBatteryURL(gameID: game.identifier) : game.gameSaveURL)
        var files: Set<File> = [File(identifier: "gameSave", fileURL: batteryURL),
                               File(identifier: BoundMultiplayerSaveStore.packageIdentifier, fileURL: packageURL)]
        
        if game.type == .gbc
        {
            let gameTimeSaveURL = game.gameSaveURL.deletingPathExtension().appendingPathExtension("rtc")
            files.insert(File(identifier: "gameTimeSave", fileURL: gameTimeSaveURL))
        }
        
        return files
    }
    
    public var syncableMetadata: [HarmonyMetadataKey : String] {
        guard let game = self.game else { return [:] }
        
        // Use self.identifier to always link with exact matching game.
        var metadata: [HarmonyMetadataKey: String] = [.gameID: self.identifier, .gameName: game.name]
        if let generation = BoundROMUpdateRegistry.generation(for: self.identifier) {
            metadata[HarmonyMetadataKey("boundROMGeneration")] = generation
        }
        if let manifest = try? BoundMultiplayerSaveStore.shared.manifest(gameID: game.identifier), !manifest.ended {
            metadata[HarmonyMetadataKey("boundMultiplayerRun")] = manifest.identity.run.uuidString
            metadata[HarmonyMetadataKey("boundMultiplayerOwner")] = manifest.identity.owner.uuidString
            metadata[HarmonyMetadataKey("boundMultiplayerVersion")] = "1"
        }
        return metadata
    }
    
    public var syncableLocalizedName: String? {
        return self.game?.name
    }
    
    public var isSyncingEnabled: Bool {
        guard !BoundROMServerInstaller.blocks(identifier) else { return false }
        // self.game may be nil if being downloaded, so don't enforce it.
        // guard let identifier = self.game?.identifier else { return false }
        
        return self.game?.boundUsesServerMultiplayer != true && self.game?.identifier != Game.melonDSBIOSIdentifier && self.game?.identifier != Game.melonDSDSiBIOSIdentifier
    }
    
    public func awakeFromSync(_ record: AnyRecord) throws
    {
        guard game?.boundUsesServerMultiplayer != true else { throw BoundROMUpdateError.multiplayerPending }
        try BoundROMUpdateRegistry.validateDownload(gameID: self.identifier,
            generation: record.remoteMetadata?[HarmonyMetadataKey("boundROMGeneration")], isSave: true,
            remoteLocked: record.perform { $0.remoteRecord?.isLocked ?? true })
        do
        {
            guard let game = self.game else { throw SyncValidationError.incorrectGame(nil) }
            
            if game.identifier != self.identifier
            {
                let fetchRequest = GameSave.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "%K == %@", #keyPath(GameSave.identifier), game.identifier)
                
                if let misplacedGameSave = try self.managedObjectContext?.fetch(fetchRequest).first, misplacedGameSave.game == nil
                {
                    // Relink game with its correct gameSave, in case we accidentally misplaced it.
                    // Otherwise, corrupted records might displace already-downloaded GameSaves
                    // due to automatic Core Data relationship propagation, despite us throwing error.
                    game.gameSave = misplacedGameSave
                }
                else
                {
                    // Either there is no misplacedGameSave, or there is but it's linked to another game somehow.
                    game.gameSave = nil
                }
                
                throw SyncValidationError.incorrectGame(game.name)
            }
        }
        catch let error as SyncValidationError
        {
            guard SyncManager.shared.ignoredCorruptedRecordIDs.contains(record.recordID) else { throw error }
            
            let fetchRequest = Game.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "%K == %@", #keyPath(Game.identifier), self.identifier)
            
            if let correctGame = try self.managedObjectContext?.fetch(fetchRequest).first
            {
                self.game = correctGame
            }
            else
            {
                throw ValidationError.nilRelationshipObjects(keys: [#keyPath(GameSave.game)])
            }
        }
        // Corrupt-record repair may have changed the game's relationship.
        guard game?.boundUsesServerMultiplayer != true else { throw BoundROMUpdateError.multiplayerPending }
        if let game, record.remoteMetadata?[HarmonyMetadataKey("boundMultiplayerRun")] != nil ||
            BoundMultiplayerSaveStore.shared.hasRun(gameID: game.identifier) {
            multiplayerDownloadDirectory = try BoundMultiplayerSaveStore.shared.stageDownload(
                gameID: game.identifier, version: record.remoteVersion?.identifier ?? UUID().uuidString,
                run: record.remoteMetadata?[HarmonyMetadataKey("boundMultiplayerRun")].flatMap(UUID.init(uuidString:)))
        }
    }

    public func prepareForSync(_ record: AnyRecord) throws
    {
        guard game?.boundUsesServerMultiplayer != true else { throw BoundROMUpdateError.multiplayerPending }
        try BoundROMUpdateRegistry.validateUpload(gameID: self.identifier)
        if BoundROMUpdateRegistry.generation(for: self.identifier) != nil, let game = self.game {
            try BoundROMUpdateResetPolicy.validateBatteryForUpload(try? Data(contentsOf: game.gameSaveURL), expectedSHA1: self.sha1)
        }
        multiplayerDownloadDirectory = nil
        multiplayerUploadDirectory = nil
        if let game, BoundMultiplayerSaveStore.shared.hasRun(gameID: game.identifier) {
            // SyncManager installs this owner only after draining the previous
            // account's coordinator. Never back up another player's run when
            // the user switches Bound/Dropbox accounts on the same device.
            guard let manifest = try BoundMultiplayerSaveStore.shared.manifest(gameID: game.identifier),
                  let syncOwner = UserDefaults.standard.string(forKey: "bound.dropbox.harmony-owner.v1").flatMap(UUID.init(uuidString:)),
                  syncOwner == manifest.identity.owner else { throw BoundMultiplayerSaveStore.Failure.ownerMismatch }
            // Upload only a self-contained completed checkpoint. Missing or
            // corrupt packages fail closed while local saving remains available.
            let snapshot = try BoundMultiplayerSaveStore.shared.snapshotCloudExport(gameID: game.identifier)
            multiplayerUploadDirectory = snapshot
            self.sha1 = try RSTHasher.sha1HashOfFile(at: snapshot.appendingPathComponent("game.sav"))
        }
    }
    
    public func resolveConflict(_ record: AnyRecord) -> ConflictResolution 
    {
        // Only attempt to resolve conflicts for older GameSaves without SHA1 hash (i.e. pre-Delta 1.5)
        guard let game = self.game, self.sha1 == nil else { return .conflict }
        
        do
        {
            let sha1Hash = try RSTHasher.sha1HashOfFile(at: game.gameSaveURL)
            
            // resolveConflict() is called from self.managedObjectContext, so we can update `self` directly
            // and it will be automatically saved once finished conflicting records.
            self.sha1 = sha1Hash
            
            // Don't update localRecord's hash here or else GameSave won't be repaired during initial sync.
            // try localRecord.updateSHA1Hash()
        }
        catch CocoaError.fileNoSuchFile
        {
            // Ignore
        }
        catch
        {
            Logger.sync.error("Failed to update GameSave SHA1 hash when resolving conflict. \(error.localizedDescription, privacy: .public)")
        }
        
        // Conflict for now, but we'll "repair" this record to hopefully resolve conflict.
        return .conflict
    }
}

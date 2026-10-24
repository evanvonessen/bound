//
//  DeepLinkController.swift
//  Delta
//
//  Created by Riley Testut on 12/28/17.
//  Copyright © 2017 Riley Testut. All rights reserved.
//

import UIKit

import DeltaCore

import Roxas

extension Notification.Name
{
    static let deepLinkControllerWillLaunchGame = Notification.Name("deepLinkControllerWillLaunchGame")
    static let deepLinkControllerLaunchGame = Notification.Name("deepLinkControllerLaunchGame")
}

extension UIViewController
{
    var allowsDeepLinkingDismissal: Bool {
        return true
    }
}

struct DeepLinkController
{
    let window: UIWindow?
    
    init(window: UIWindow?)
    {
        self.window = window
    }
    
    private var topViewController: UIViewController? {
        guard let window = self.window else { return nil }
        
        var topViewController = window.rootViewController
        while topViewController?.presentedViewController != nil
        {
            guard !(topViewController?.presentedViewController is UIAlertController) else { break }
            
            topViewController = topViewController?.presentedViewController
        }
        
        return topViewController
    }
}

extension DeepLinkController
{
    @discardableResult func handle(_ deepLink: DeepLink) -> Bool
    {
        guard let action = deepLink.action else { return false }
        
        switch action
        {
        case .launchGame(let identifier, let userActivity): return self.launchGame(withIdentifier: identifier, userActivity: userActivity)
        }
    }
}

private extension DeepLinkController
{
    func launchGame(withIdentifier identifier: String, userActivity: NSUserActivity?) -> Bool
    {
        guard let topViewController = self.topViewController, topViewController.allowsDeepLinkingDismissal else { return false }
        
        let fetchRequest: NSFetchRequest<Game> = Game.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "%K == %@", #keyPath(Game.identifier), identifier)
        fetchRequest.returnsObjectsAsFaults = false
        
        do
        {
            guard let game = try DatabaseManager.shared.viewContext.fetch(fetchRequest).first else { return false }
            let storage = BoundROMUpdateStorage.live
            guard !storage.hasPendingSaveClear(gameID: identifier) else { return false }
            let clearRevision = try storage.saveClearRevision(gameID: identifier)
            
            var userInfo: [DeepLink.Key: Any] = [.game: game]
            if let windowScene = self.window?.windowScene
            {
                userInfo[.scene] = windowScene
            }
            
            if let userActivity, userActivity.activityType == NSUserActivity.playGameActivityType,
               let isSaveStateAvailable = userActivity.userInfo?[NSUserActivity.isSaveStateAvailable] as? Bool, isSaveStateAvailable
            {
                NotificationCenter.default.post(name: .deepLinkControllerWillLaunchGame, object: self, userInfo: userInfo)
                
                let gameType = game.type
                
                Task<Void, Never> { [userInfo] in
                    var userInfo = userInfo
                    
                    do
                    {
                        let (inputStream, outputStream) = try await userActivity.continuationStreams()
                        inputStream.open()
                        outputStream.open()
                        
                        let data: Data = try await inputStream.receive()
                        
                        let temporaryURL = FileManager.default.uniqueTemporaryURL()
                        try data.write(to: temporaryURL, options: .atomic)
                        
                        let saveState = DeltaCore.SaveState(fileURL: temporaryURL, gameType: gameType)
                        userInfo[.saveState] = saveState
                    }
                    catch
                    {
                        Logger.main.error("Failed to retrieve streams for Handoff. \(error.localizedDescription, privacy: .public)")
                        userInfo[.error] = error
                    }
                    
                    await MainActor.run { [userInfo] in
                        let canResume: Bool
                        do {
                            if storage.hasPendingSaveClear(gameID: identifier) { canResume = false }
                            else { canResume = try storage.saveClearRevision(gameID: identifier) == clearRevision }
                        } catch { canResume = false }
                        guard canResume else {
                            if let staleState = userInfo[.saveState] as? SaveStateProtocol {
                                try? FileManager.default.removeItem(at: staleState.fileURL)
                            }
                            return
                        }
                        NotificationCenter.default.post(name: .deepLinkControllerLaunchGame, object: self, userInfo: userInfo)
                    }
                }
            }
            else
            {
                NotificationCenter.default.post(name: .deepLinkControllerLaunchGame, object: self, userInfo: userInfo)
            }
        }
        catch
        {
            print(error)
            
            return false
        }
        
        return true
    }
}

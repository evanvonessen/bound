//
//  SyncManager.swift
//  Delta
//
//  Created by Riley Testut on 11/12/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

import Harmony

private extension UserDefaults
{
    @NSManaged var didValidateHarmonyBetaDatabase: Bool
}

extension SyncManager
{
    enum RecordType: String, Hashable
    {
        case game = "Game"
        case gameCollection = "GameCollection"
        case cheat = "Cheat"
        case saveState = "SaveState"
        case controllerSkin = "ControllerSkin"
        case gameControllerInputMapping = "GameControllerInputMapping"
        case gameSave = "GameSave"
        
        var localizedName: String {
            switch self
            {
            case .game: return NSLocalizedString("Game", comment: "")
            case .gameCollection: return NSLocalizedString("Game Collection", comment: "")
            case .cheat: return NSLocalizedString("Cheat", comment: "")
            case .saveState: return NSLocalizedString("Save State", comment: "")
            case .controllerSkin: return NSLocalizedString("Controller Skin", comment: "")
            case .gameControllerInputMapping: return NSLocalizedString("Game Controller Input Mapping", comment: "")
            case .gameSave: return NSLocalizedString("Game Save", comment: "")
            }
        }
    }
    
    enum Service: String, CaseIterable
    {
        case googleDrive = "com.rileytestut.Harmony.Drive"
        case dropbox = "com.rileytestut.Harmony.Dropbox"
        
        var localizedName: String {
            switch self
            {
            case .googleDrive: return NSLocalizedString("Google Drive", comment: "")
            case .dropbox: return NSLocalizedString("Dropbox", comment: "")
            }
        }
        
        var service: Harmony.Service {
            switch self
            {
            case .googleDrive: return DriveService.shared
            case .dropbox: return DropboxService.shared
            }
        }
    }

    static var availableBoundServices: [Service] { [.dropbox] }

    static var currentBoundService: Service? {
        guard Settings.syncingService == .dropbox else { return nil }
        return .dropbox
    }

    static func serviceForBoundSync(_ service: Service?) -> Service? {
        guard service == .dropbox else { return nil }
        return .dropbox
    }
    
    enum Error: LocalizedError
    {
        case nilService
        case providerNotConfigured(Service)
        
        var errorDescription: String? {
            switch self
            {
            case .nilService: return NSLocalizedString("There is no chosen service for syncing.", comment: "")
            case .providerNotConfigured(let service):
                return String(format: NSLocalizedString("%@ sign-in is not configured for Bound yet.", comment: ""), service.localizedName)
            }
        }
    }
}

extension Syncable where Self: NSManagedObject
{
    var recordType: SyncManager.RecordType {
        let recordType = SyncManager.RecordType(rawValue: self.syncableType)!
        return recordType
    }
}

final class SyncManager
{
    static let shared = SyncManager()
    private static let legacyGoogleDriveClientID = "457607414709-7oc45nq59frd7rre6okq22fafftd55g1.apps.googleusercontent.com"
    
    var service: Service? {
        guard let service = self.coordinator?.service else { return nil }
        return Service(rawValue: service.identifier)
    }
    
    var recordController: RecordController? {
        return self.coordinator?.recordController
    }
    
    // Hacky, but YOLO I'm under time crunch.
    public var ignoredCorruptedRecordIDs = Set<RecordID>()
    
    private(set) var syncProgress: Progress?
        
    private(set) var previousSyncResult: SyncResult?
    
    private(set) var coordinator: SyncCoordinator?

    private typealias ControlOperation = (@escaping () -> Void) -> Void
    private var controlOperations = [ControlOperation]()
    private var isRunningControlOperation = false
    private var startGeneration = UUID()
    private var startingCoordinator: SyncCoordinator?
    private var coordinatorWaitingToStop: SyncCoordinator?
    
    private init()
    {
        DriveService.shared.clientID = Self.legacyGoogleDriveClientID
        
        DropboxService.shared.preferredDirectoryName = "Delta Emulator"
        
        NotificationCenter.default.addObserver(self, selector: #selector(SyncManager.syncingDidFinish(_:)), name: SyncCoordinator.didFinishSyncingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(SyncManager.didEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(SyncManager.willEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
}

extension SyncManager
{
    static func isServiceConfigured(_ service: Service) -> Bool
    {
        return Self.isBoundProviderConfigured(service, info: Bundle.main.infoDictionary ?? [:])
    }

    static func isBoundProviderConfigured(_ service: Service, info: [String: Any]) -> Bool
    {
        func configuredString(_ key: String) -> String? {
            guard let rawValue = info[key] as? String else { return nil }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.localizedCaseInsensitiveContains("unconfigured"),
                  !value.contains("$(") else { return nil }
            return value
        }

        switch service {
        case .googleDrive:
            guard let clientID = configuredString("BOUND_GOOGLE_CLIENT_ID"),
                  let reversedClientID = configuredString("BOUND_GOOGLE_REVERSED_CLIENT_ID"),
                  clientID.range(of: "^[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil,
                  let identifier = clientID.range(of: ".apps.googleusercontent.com", options: .backwards).map({ String(clientID[..<$0.lowerBound]) }),
                  reversedClientID == "com.googleusercontent.apps.\(identifier)" else { return false }
            return true
        case .dropbox:
            guard let appKey = configuredString("BOUND_DROPBOX_APP_KEY"),
                  appKey.range(of: "^[A-Za-z0-9]{8,64}$", options: .regularExpression) != nil else { return false }
            return true
        }
    }

    private func configureProvider(_ service: Service) -> Bool
    {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Self.isBoundProviderConfigured(service, info: info) else { return false }
        switch service {
        case .googleDrive:
            DriveService.shared.clientID = info["BOUND_GOOGLE_CLIENT_ID"] as? String
        case .dropbox:
            let appKey = info["BOUND_DROPBOX_APP_KEY"] as? String
            // SwiftyDropbox traps if setupWithAppKey is called twice, even with
            // the same key. Keep the configured SDK instance for the app lifetime.
            if let existingKey = DropboxService.shared.clientID {
                guard existingKey == appKey else { return false }
            } else {
                DropboxService.shared.clientID = appKey
            }
            DropboxService.shared.accessTokenProvider = { presenter, completion in
                BoundDropboxOAuth.shared.provideAccessToken(presenting: presenter, completion: completion)
            }
            DropboxService.shared.deauthenticationHandler = {
                BoundDropboxOAuth.shared.clearCredentials()
            }
        }
        return true
    }

    func start(service: Service?, completionHandler: @escaping (Result<Void, Swift.Error>) -> Void)
    {
        self.enqueueControlOperation { finish in
            self.start(service: service, completionHandler: completionHandler, finish: finish)
        }
    }
    
    func reset(for service: Service?, completionHandler: @escaping (Result<Void, Swift.Error>) -> Void)
    {
        self.enqueueControlOperation { finish in
            if let service, !SyncManager.availableBoundServices.contains(service) {
                completionHandler(.success); finish(); return
            }

            if let service, !self.configureProvider(service) {
                completionHandler(.failure(Error.providerNotConfigured(service)))
                finish()
                return
            }

            guard let coordinator = self.coordinator else {
                self.start(service: service, completionHandler: completionHandler, finish: finish)
                return
            }

            coordinator.deauthenticate { _ in
                DispatchQueue.main.async {
                    self.coordinator = nil
                    self.start(service: service, completionHandler: completionHandler, finish: finish)
                }
            }
        }
    }
    
    func authenticate(presentingViewController: UIViewController? = nil, completionHandler: @escaping (Result<Account, AuthenticationError>) -> Void)
    {
        guard let coordinator = self.coordinator else { return completionHandler(.failure(AuthenticationError(Error.nilService))) }
        
        coordinator.authenticate(presentingViewController: presentingViewController, completionHandler: completionHandler)
    }
    
    func deauthenticate(completionHandler: @escaping (Result<Void, DeauthenticationError>) -> Void)
    {
        guard let coordinator = self.coordinator else { return completionHandler(.success) }
        
        coordinator.deauthenticate(completionHandler: completionHandler)
    }
    
    func sync()
    {
        // Don't sync until we've repaired database.
        guard !UserDefaults.standard.shouldRepairDatabase else { return }
        
        let progress = self.coordinator?.sync()
        self.syncProgress = progress
    }
}

private extension SyncManager
{
    private func enqueueControlOperation(_ operation: @escaping ControlOperation)
    {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.enqueueControlOperation(operation) }
            return
        }

        self.controlOperations.append(operation)
        self.runNextControlOperation()
    }

    func runNextControlOperation()
    {
        guard Thread.isMainThread, !self.isRunningControlOperation,
              self.coordinatorWaitingToStop == nil, !self.controlOperations.isEmpty else { return }

        self.isRunningControlOperation = true
        let operation = self.controlOperations.removeFirst()
        operation {
            DispatchQueue.main.async {
                self.isRunningControlOperation = false
                self.runNextControlOperation()
            }
        }
    }

    func start(service: Service?, completionHandler: @escaping (Result<Void, Swift.Error>) -> Void, finish: @escaping () -> Void)
    {
        guard service != .googleDrive else {
            completionHandler(.success); finish(); return
        }
        guard let service else {
            completionHandler(.success); finish(); return
        }
        guard self.configureProvider(service) else {
            completionHandler(.failure(Error.providerNotConfigured(service))); finish(); return
        }
        guard self.coordinator == nil else { completionHandler(.success); finish(); return }

        let generation = self.startGeneration
        let candidate = SyncCoordinator(service: service.service, persistentContainer: DatabaseManager.shared)
        self.startingCoordinator = candidate

        if !UserDefaults.standard.didValidateHarmonyBetaDatabase {
            candidate.deauthenticate { _ in
                DispatchQueue.main.async {
                    guard self.startGeneration == generation else {
                        self.startingCoordinator = nil
                        self.stopCoordinator(candidate)
                        completionHandler(.success); finish(); return
                    }

                    do { try FileManager.default.removeItem(at: RecordController.defaultDirectoryURL()) }
                    catch CocoaError.fileNoSuchFile { /* Ignore. */ }
                    catch { Logger.sync.error("Failed to remove Harmony database. \(error.localizedDescription, privacy: .public)") }
                    UserDefaults.standard.didValidateHarmonyBetaDatabase = true
                    self.startingCoordinator = nil
                    self.start(service: service, completionHandler: completionHandler, finish: finish)
                }
            }
            return
        }

        candidate.start { result in
            DispatchQueue.main.async {
                guard self.startGeneration == generation else {
                    self.startingCoordinator = nil
                    self.stopCoordinator(candidate)
                    completionHandler(.success); finish(); return
                }

                do {
                    _ = try result.get()
                    self.startingCoordinator = nil
                    self.coordinator = candidate
                    completionHandler(.success); finish()
                }
                catch let authError as AuthenticationError {
                    // A network failure leaves the coordinator usable for a later retry.
                    self.startingCoordinator = nil
                    self.coordinator = candidate
                    switch authError {
                    case .other(ServiceError.connectionFailed):
                        Logger.sync.error("Failed to authenticate SyncManager due to network connection (ignoring). \(authError.localizedDescription, privacy: .public)")
                        completionHandler(.success); finish()
                    default:
                        Logger.sync.error("Failed to authenticate SyncManager. \(authError.localizedDescription, privacy: .public)")
                        self.deauthenticate { result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success: completionHandler(.success)
                                case .failure: completionHandler(.failure(authError))
                                }
                                finish()
                            }
                        }
                    }
                }
                catch {
                    Logger.sync.error("Failed to start SyncManager. \(error.localizedDescription, privacy: .public)")
                    self.startingCoordinator = nil
                    self.stopCoordinator(candidate)
                    completionHandler(.failure(error)); finish()
                }
            }
        }
    }

    func stopCoordinator(_ coordinator: SyncCoordinator)
    {
        guard coordinator.isStarted else { return }
        if coordinator.isSyncing {
            self.coordinatorWaitingToStop = coordinator
            coordinator.cancelSyncing {
                DispatchQueue.main.async {
                    guard self.coordinatorWaitingToStop === coordinator else { return }
                    self.coordinatorWaitingToStop = nil
                    self.stopCoordinatorNow(coordinator)
                    self.runNextControlOperation()
                }
            }
            self.syncProgress?.cancel()
            self.syncProgress = nil
            return
        }

        self.stopCoordinatorNow(coordinator)
    }

    func stopCoordinatorNow(_ coordinator: SyncCoordinator)
    {
        guard coordinator.isStarted else { return }
        do { try coordinator.stop() }
        catch { Logger.sync.error("Failed to stop SyncManager. \(error.localizedDescription, privacy: .public)") }
    }

    @objc func syncingDidFinish(_ notification: Notification)
    {
        guard let finishedCoordinator = notification.object as? SyncCoordinator else { return }
        DispatchQueue.main.async {
            guard self.coordinator === finishedCoordinator else { return }
            self.previousSyncResult = notification.userInfo?[SyncCoordinator.syncResultKey] as? SyncResult
            self.syncProgress = nil
            print("Finished syncing!")
        }
    }
    
    @objc func didEnterBackground(_ notification: Notification)
    {
        self.sync()
    }
    
    @objc func willEnterForeground(_ notification: Notification)
    {
        self.sync()
    }
}

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
        guard Settings.syncingService == .dropbox,
              !UserDefaults.standard.bool(forKey: "bound.dropbox.device-paused.v1") else { return nil }
        return .dropbox
    }

    static func serviceForBoundSync(_ service: Service?) -> Service? {
        guard service == .dropbox else { return nil }
        return .dropbox
    }

    static func shouldPreserveSyncState(after error: AuthenticationError) -> Bool {
        switch error {
        case .other(ServiceError.connectionFailed), .other(ServiceError.rateLimitExceeded),
             .other(BoundDropboxOAuth.Failure.unavailable), .other(BoundDropboxOAuth.Failure.notConfigured),
             .other(BoundDropboxOAuth.Failure.rateLimited), .other(BoundDropboxOAuth.Failure.secondFactorRequired):
            return true
        default:
            return false
        }
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
    private var providerGeneration = UUID()
    private var isChangingBoundAccount = false
    private static let boundOwnerKey = "bound.dropbox.harmony-owner.v1"
    private var startingCoordinator: SyncCoordinator?
    private var coordinatorWaitingToStop: SyncCoordinator?
    
    private init()
    {
        DriveService.shared.clientID = Self.legacyGoogleDriveClientID
        
        DropboxService.shared.preferredDirectoryName = "Delta Emulator"
        
        NotificationCenter.default.addObserver(self, selector: #selector(SyncManager.boundAccountWillSignOut(_:)), name: BoundFriendAccount.willSignOutNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(SyncManager.boundAccountDidChange(_:)), name: BoundFriendAccount.sessionDidChangeNotification, object: nil)
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
            let epoch = self.startGeneration
            let providerEpoch = self.providerGeneration
            let identity = MainActor.assumeIsolated { BoundFriendAccount.shared.session }
            DropboxService.shared.accessTokenProvider = { [weak self] presenter, completion in
                Task { @MainActor in
                    await BoundFriendAccount.shared.refreshIfNeeded()
                    guard let self, self.startGeneration == epoch, self.providerGeneration == providerEpoch,
                          let identity, identity.isSameSession(as: BoundFriendAccount.shared.session) else {
                        completion(.failure(.other(BoundDropboxOAuth.Failure.signIn)))
                        return
                    }
                    BoundDropboxOAuth.shared.provideAccessToken(presenting: presenter, completion: completion)
                }
            }
            DropboxService.shared.deauthenticationHandler = { [weak self] in
                let clear = { @MainActor in
                    self?.providerGeneration = UUID()
                    BoundDropboxOAuth.shared.clearCredentials()
                    // Retained callbacks remain fenced by their old generation,
                    // while Harmony can retry with a fresh provider after its
                    // own deauthentication (including interactive reconnect).
                    _ = self?.configureProvider(.dropbox)
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { clear() }
                } else {
                    DispatchQueue.main.sync { MainActor.assumeIsolated { clear() } }
                }
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
        let complete: (Result<Void, Swift.Error>) -> Void = { result in
            if case .success = result {
                UserDefaults.standard.set(service != .dropbox, forKey: "bound.dropbox.device-paused.v1")
            }
            completionHandler(result)
        }
        self.enqueueControlOperation { finish in
            if let service, !SyncManager.availableBoundServices.contains(service) {
                complete(.success); finish(); return
            }

            if let service, !self.configureProvider(service) {
                complete(.failure(Error.providerNotConfigured(service)))
                finish()
                return
            }

            guard let coordinator = self.coordinator else {
                self.start(service: service, completionHandler: complete, finish: finish)
                return
            }

            self.isChangingBoundAccount = true
            coordinator.deauthenticate { result in
                DispatchQueue.main.async {
                    do { try result.get() }
                    catch {
                        self.isChangingBoundAccount = false
                        complete(.failure(error)); finish(); return
                    }
                    self.coordinator = nil
                    self.start(service: service, completionHandler: complete, finish: finish)
                }
            }
        }
    }
    
    func authenticate(presentingViewController: UIViewController? = nil, completionHandler: @escaping (Result<Account, AuthenticationError>) -> Void)
    {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.authenticate(presentingViewController: presentingViewController, completionHandler: completionHandler) }
            return
        }
        guard MainActor.assumeIsolated({ BoundFriendAccount.shared.session != nil && !BoundFriendAccount.shared.deletionPending }) else {
            return completionHandler(.failure(.other(BoundDropboxOAuth.Failure.signIn)))
        }
        guard !isChangingBoundAccount else { return completionHandler(.failure(.other(BoundDropboxOAuth.Failure.changed))) }
        guard let coordinator = self.coordinator else { return completionHandler(.failure(AuthenticationError(Error.nilService))) }
        
        coordinator.authenticate(presentingViewController: presentingViewController, completionHandler: completionHandler)
    }
    
    func deauthenticate(completionHandler: @escaping (Result<Void, DeauthenticationError>) -> Void)
    {
        guard let coordinator = self.coordinator else { return completionHandler(.success) }
        
        self.isChangingBoundAccount = true
        coordinator.deauthenticate { result in
            DispatchQueue.main.async {
                if self.coordinator === coordinator { self.isChangingBoundAccount = false }
                completionHandler(result)
            }
        }
    }
    
    func sync()
    {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.sync() }; return }
        // Account boundaries stop scheduling immediately, before queued teardown.
        guard !isChangingBoundAccount, Self.currentBoundService != nil,
              MainActor.assumeIsolated({ BoundFriendAccount.shared.session != nil && !BoundFriendAccount.shared.deletionPending }),
              !UserDefaults.standard.shouldRepairDatabase else { return }
        
        let progress = self.coordinator?.sync()
        self.syncProgress = progress
    }
}

extension SyncManager
{
    // Called only on the main actor, before a new broker token reaches Harmony.
    @MainActor func acceptDropboxConnection(owner: UUID, connection: UUID) -> Bool
    {
        let key = "bound.dropbox.connection.v1." + owner.uuidString
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(connection.uuidString, forKey: key)
        guard let previous, previous != connection.uuidString else { return true }
        // Another device may have unlinked and connected a different Dropbox.
        // Drain old work and reset its metadata before installing the new token.
        UserDefaults.standard.removeObject(forKey: Self.boundOwnerKey)
        self.suspendForBoundAccountChange()
        self.start(service: Self.currentBoundService) { _ in }
        return false
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

        let boundOwner = MainActor.assumeIsolated { BoundFriendAccount.shared.session?.owner.uuidString ?? "signed-out" }
        let needsOwnerReset = UserDefaults.standard.string(forKey: Self.boundOwnerKey) != boundOwner
        if !UserDefaults.standard.didValidateHarmonyBetaDatabase || needsOwnerReset {
            candidate.deauthenticate { resetResult in
                DispatchQueue.main.async {
                    guard self.startGeneration == generation else {
                        self.startingCoordinator = nil
                        self.stopCoordinator(candidate)
                        completionHandler(.failure(BoundDropboxOAuth.Failure.changed)); finish(); return
                    }

                    do {
                        try resetResult.get()
                        do { try FileManager.default.removeItem(at: RecordController.defaultDirectoryURL()) }
                        catch CocoaError.fileNoSuchFile { /* Ignore. */ }
                    } catch {
                        self.startingCoordinator = nil
                        self.stopCoordinator(candidate)
                        completionHandler(.failure(error)); finish(); return
                    }
                    UserDefaults.standard.didValidateHarmonyBetaDatabase = true
                    UserDefaults.standard.set(boundOwner, forKey: Self.boundOwnerKey)
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
                    completionHandler(.failure(BoundDropboxOAuth.Failure.changed)); finish(); return
                }

                do {
                    _ = try result.get()
                    self.startingCoordinator = nil
                    self.coordinator = candidate
                    self.isChangingBoundAccount = false
                    completionHandler(.success); finish()
                }
                catch let authError as AuthenticationError {
                    // A network failure leaves the coordinator usable for a later retry.
                    self.startingCoordinator = nil
                    self.coordinator = candidate
                    if Self.shouldPreserveSyncState(after: authError) {
                        // A broker outage/configuration issue is not a changed
                        // Dropbox account. Keep Harmony's sync history intact.
                        self.isChangingBoundAccount = false
                        Logger.sync.error("Sync authentication can be retried. \(authError.localizedDescription, privacy: .public)")
                        completionHandler(.success); finish()
                    } else {
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

    @objc func boundAccountWillSignOut(_ notification: Notification)
    {
        MainActor.assumeIsolated {
            guard notification.object as? BoundFriendAccount === BoundFriendAccount.shared else { return }
            UserDefaults.standard.set(true, forKey: "bound.dropbox.device-paused.v1")
            self.suspendForBoundAccountChange()
        }
    }

    @MainActor func suspendForBoundAccountChange()
    {
        self.isChangingBoundAccount = true
        self.startGeneration = UUID()
        BoundDropboxOAuth.shared.cancelPendingAuthorization()
        let old = self.coordinator
        self.coordinator = nil
        self.previousSyncResult = nil
        self.syncProgress?.cancel(); self.syncProgress = nil
        // Drain old Dropbox work before resetting the shared Harmony metadata
        // or allowing a new account's provider to install its access token.
        self.enqueueControlOperation { finish in
            guard let old else { finish(); return }
            old.cancelSyncing {
                old.deauthenticate { result in
                    DispatchQueue.main.async {
                        if case .failure = result {
                            self.stopCoordinator(old)
                        }
                        finish()
                    }
                }
            }
        }
    }

    @objc func boundAccountDidChange(_ notification: Notification)
    {
        MainActor.assumeIsolated {
            guard notification.object as? BoundFriendAccount === BoundFriendAccount.shared,
                  BoundFriendAccount.shared.session != nil else { return }
            self.start(service: Self.currentBoundService) { _ in }
        }
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

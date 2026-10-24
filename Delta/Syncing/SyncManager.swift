//
//  SyncManager.swift
//  Delta
//
//  Created by Riley Testut on 11/12/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

import Harmony

/// Contains identifiers only. Tokens are reacquired and never written to the
/// durable per-ROM deletion receipt.
struct BoundSaveClearCloudContext: Codable, Equatable {
    let owner: UUID?
    let connection: UUID?
    let dropboxAccountID: String?
    let includesDropbox: Bool
    let saveStateIDs: [String]
}

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
        case saveClearSyncUnavailable
        
        var errorDescription: String? {
            switch self
            {
            case .nilService: return NSLocalizedString("There is no chosen service for syncing.", comment: "")
            case .providerNotConfigured(let service):
                return String(format: NSLocalizedString("%@ sign-in is not configured for Bound yet.", comment: ""), service.localizedName)
            case .saveClearSyncUnavailable:
                return "Turn on Dropbox sync in Account, Friends, & Sync, then try Clear Saves again."
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
    private var pendingROMUpdates = 0
    private var manualRecordMutations = 0
    private var waitingROMUpdate: (() -> Void)?
    private var verifiedSaveClearConnections = [UUID: String]()
    
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
    
    /// Drain network work while retaining Harmony's change observer, so the
    /// replacement and deleted saves still produce normal sync records.
    @MainActor func performROMUpdate(_ operation: @escaping (@escaping () -> Void) -> Void)
    {
        pendingROMUpdates += 1
        enqueueControlOperation { finishControl in
            let apply = {
                var finished = false
                operation {
                    DispatchQueue.main.async {
                        guard !finished else { return }
                        finished = true
                        self.pendingROMUpdates -= 1
                        finishControl()
                        self.sync()
                    }
                }
            }
            let drained = {
                if self.manualRecordMutations == 0 { apply() }
                else { self.waitingROMUpdate = apply }
            }
            if let coordinator = self.coordinator {
                coordinator.cancelSyncing {
                    DispatchQueue.main.async { drained() }
                }
                self.syncProgress?.cancel()
                self.syncProgress = nil
            } else { drained() }
        }
    }

    /// Manual version restoration uses Harmony's separate operation queue.
    /// Include it in the ROM update fence without stopping record observation.
    @MainActor func beginManualRecordMutation() -> (() -> Void)?
    {
        guard pendingROMUpdates == 0 else { return nil }
        manualRecordMutations += 1
        var finished = false
        return {
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                self.manualRecordMutations -= 1
                if self.manualRecordMutations == 0, let pending = self.waitingROMUpdate {
                    self.waitingROMUpdate = nil
                    pending()
                }
            }
        }
    }

    func sync()
    {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.sync() }; return }
        // Account boundaries stop scheduling immediately, before queued teardown.
        guard pendingROMUpdates == 0, !isChangingBoundAccount, Self.currentBoundService != nil,
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

extension SyncManager {
    /// Run inside performROMUpdate, before writing the deletion receipt. This
    /// only verifies authorization and reads identifiers; no saves are changed.
    @MainActor func prepareSaveClearCloudContext(gameID: String) async throws -> BoundSaveClearCloudContext {
        let identity = BoundFriendAccount.shared.session
        let owner = identity?.owner
        let savedConnection = owner.flatMap { UserDefaults.standard.string(forKey: "bound.dropbox.connection.v1." + $0.uuidString) }.flatMap(UUID.init(uuidString:))
        let hasHistory = savedConnection != nil || coordinator?.account != nil ||
            Settings.syncingService == .dropbox || UserDefaults.standard.string(forKey: "harmony-dropbox_accountID") != nil ||
            (owner == nil && UserDefaults.standard.dictionaryRepresentation().keys.contains { $0.hasPrefix("bound.dropbox.connection.v1.") })
        let context = DatabaseManager.shared.newBackgroundContext()
        let identifiers = try context.performAndWait {
            let request = SaveState.fetchRequest()
            request.predicate = NSPredicate(format: "game.identifier == %@", gameID)
            return try context.fetch(request).map(\.identifier).sorted()
        }
        guard let identity else {
            guard !hasHistory else { throw BoundDropboxOAuth.Failure.signIn }
            return BoundSaveClearCloudContext(owner: nil, connection: nil, dropboxAccountID: nil, includesDropbox: false, saveStateIDs: identifiers)
        }
        do {
            let token = try await saveClearAccessToken()
            guard identity.isSameSession(as: BoundFriendAccount.shared.session), !BoundFriendAccount.shared.deletionPending,
                  let connection = UserDefaults.standard.string(forKey: "bound.dropbox.connection.v1." + identity.owner.uuidString).flatMap(UUID.init(uuidString:)) else {
                throw BoundDropboxOAuth.Failure.changed
            }
            let accountID = try await BoundDropboxSaveDeletion.accountID(token: token)
            guard identity.isSameSession(as: BoundFriendAccount.shared.session),
                  currentSaveClearConnection(owner: identity.owner) == connection else { throw BoundDropboxOAuth.Failure.changed }
            try validateSaveClearRecordStore(owner: identity.owner)
            verifiedSaveClearConnections[connection] = accountID
            return BoundSaveClearCloudContext(owner: owner, connection: connection, dropboxAccountID: accountID, includesDropbox: true, saveStateIDs: identifiers)
        } catch AuthenticationError.noSavedCredentials {
            guard identity.isSameSession(as: BoundFriendAccount.shared.session), !hasHistory else { throw BoundDropboxOAuth.Failure.notLinked }
            return BoundSaveClearCloudContext(owner: owner, connection: nil, dropboxAccountID: nil, includesDropbox: false, saveStateIDs: identifiers)
        }
    }

    /// The caller must have persisted the context and fenced normal syncing.
    @MainActor func deleteDropboxSaves(gameID: String, context: BoundSaveClearCloudContext) async throws {
        try validateSaveClearContext(context, requireVerifiedConnection: false)
        guard context.includesDropbox else { return }
        let token = try await saveClearAccessToken()
        guard let owner = context.owner, let connection = currentSaveClearConnection(owner: owner),
              let expectedAccount = context.dropboxAccountID else { throw BoundDropboxOAuth.Failure.changed }
        let accountID = try await BoundDropboxSaveDeletion.accountID(token: token)
        guard accountID == expectedAccount, currentSaveClearConnection(owner: owner) == connection else { throw BoundDropboxOAuth.Failure.changed }
        verifiedSaveClearConnections[connection] = accountID
        try validateSaveClearContext(context)
        let deletion = BoundDropboxSaveDeletion(token: token,
            directory: DropboxService.shared.preferredDirectoryName ?? "Delta Emulator",
            validate: {
                try self.validateSaveClearContext(context)
                guard self.currentSaveClearConnection(owner: owner) == connection else { throw BoundDropboxOAuth.Failure.changed }
            })
        try await deletion.delete(gameID: gameID, localSaveStateIDs: Set(context.saveStateIDs))
        try validateSaveClearContext(context)
    }

    @MainActor private func saveClearAccessToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            BoundDropboxOAuth.shared.provideAccessToken(presenting: nil) { continuation.resume(with: $0.mapError { $0 as Swift.Error }) }
        }
    }

    @MainActor private func currentSaveClearConnection(owner: UUID) -> UUID? {
        UserDefaults.standard.string(forKey: "bound.dropbox.connection.v1." + owner.uuidString).flatMap(UUID.init(uuidString:))
    }

    static func validateSaveClearRecordStore(owner: UUID, recordedOwner: String?, service: Service?,
                                           isStarted: Bool, isChangingAccount: Bool) throws {
        guard service == .dropbox, isStarted, !isChangingAccount,
              recordedOwner.flatMap(UUID.init(uuidString:)) == owner else { throw Error.saveClearSyncUnavailable }
    }

    @MainActor private func validateSaveClearRecordStore(owner: UUID) throws {
        try Self.validateSaveClearRecordStore(owner: owner,
            recordedOwner: UserDefaults.standard.string(forKey: Self.boundOwnerKey), service: service,
            isStarted: recordController?.isStarted == true, isChangingAccount: isChangingBoundAccount)
    }

    @MainActor private func validateSaveClearContext(_ context: BoundSaveClearCloudContext, requireVerifiedConnection: Bool = true) throws {
        guard BoundFriendAccount.shared.session?.owner == context.owner, !BoundFriendAccount.shared.deletionPending else {
            throw BoundDropboxOAuth.Failure.changed
        }
        if let owner = context.owner {
            let current = currentSaveClearConnection(owner: owner)
            if context.includesDropbox {
                // Check before the first delete request, including on retry.
                // Paused/unavailable metadata must never become a failure only
                // after cloud and local saves have already been erased.
                try validateSaveClearRecordStore(owner: owner)
                if requireVerifiedConnection {
                    guard let current, let expected = context.dropboxAccountID,
                          verifiedSaveClearConnections[current] == expected else { throw BoundDropboxOAuth.Failure.changed }
                }
            } else if current != context.connection { throw BoundDropboxOAuth.Failure.changed }
        }
    }

    /// Remove the selected saves' Harmony rows after their local objects and
    /// cloud files are gone, including disabled/conflicted and remote-only rows.
    @MainActor func removeLocalSaveSyncRecords(gameID: String, context: BoundSaveClearCloudContext) async throws {
        try validateSaveClearContext(context)
        guard let controller = recordController, controller.isStarted else {
            // A configured owner must retain its record store until this fence
            // completes; otherwise an account switch could clear the wrong DB.
            if context.includesDropbox { throw Error.saveClearSyncUnavailable }
            return
        }
        await controller.waitForRecordedChanges()
        try validateSaveClearContext(context)
        let background = controller.newBackgroundContext()
        let deletedIDs: Set<RecordID> = try background.performAndWait {
            let request = NSFetchRequest<ManagedRecord>(entityName: "ManagedRecord")
            request.predicate = NSPredicate(format: "recordedObjectType IN %@", ["GameSave", "SaveState"])
            var deleted = Set(context.saveStateIDs.map { RecordID(type: "SaveState", identifier: $0) })
            deleted.insert(RecordID(type: "GameSave", identifier: gameID))
            for record in try background.fetch(request) {
                let metadata = record.remoteRecord?.value(forKey: "metadata") as? [HarmonyMetadataKey: String] ?? [:]
                let isSelected = record.recordedObjectType == "GameSave" ? record.recordedObjectIdentifier == gameID :
                    (context.saveStateIDs.contains(record.recordedObjectIdentifier) || (metadata[.verifiedGameID] ?? metadata[.gameID]) == gameID)
                guard isSelected else { continue }
                deleted.insert(RecordID(type: record.recordedObjectType, identifier: record.recordedObjectIdentifier))
                background.delete(record)
            }
            try background.save()
            return deleted
        }
        ignoredCorruptedRecordIDs.subtract(deletedIDs)
        if case .success(let results) = previousSyncResult {
            previousSyncResult = .success(results.filter { !deletedIDs.contains($0.key.recordID) })
        } else if case .failure(.partial(let results)) = previousSyncResult {
            let remaining = results.filter { !deletedIDs.contains($0.key.recordID) }
            let hasFailures = remaining.values.contains { if case .failure = $0 { return true }; return false }
            previousSyncResult = hasFailures ? .failure(.partial(remaining)) : .success(remaining)
        }
        NotificationCenter.default.post(name: SyncCoordinator.didFinishSyncingNotification, object: coordinator,
            userInfo: [SyncCoordinator.syncResultKey: previousSyncResult ?? .success([:])])
    }
}

/// Dropbox's Harmony directory is flat. Selection uses exact record metadata
/// and the pinned backend's exact payload names, never a directory deletion or
/// a game-name/prefix match. All requests are injectable for disposable tests.
@MainActor
final class BoundDropboxSaveDeletion {
    enum Failure: LocalizedError {
        case response, unsafeRecord, changed, unavailable
        var errorDescription: String? {
            switch self {
            case .changed: return "Dropbox saves changed while clearing. Try Clear Saves again."
            case .unsafeRecord: return "A Dropbox save could not be identified safely. Clear Saves was not completed."
            case .response, .unavailable: return "Dropbox could not finish clearing these saves. Check your connection and try again."
            }
        }
    }
    struct Entry: Decodable {
        let tag: String
        let id: String?
        let name: String
        let pathLower: String?
        let propertyGroups: [Group]?
        struct Group: Decodable { let fields: [Field] }
        struct Field: Decodable { let name: String; let value: String }
        enum CodingKeys: String, CodingKey {
            case tag = ".tag", id, name, pathLower = "path_lower", propertyGroups = "property_groups"
        }
        var metadata: [String: String] {
            var result = [String: String]()
            for field in propertyGroups?.flatMap(\.fields) ?? [] { result[field.name] = field.value }
            return result
        }
    }
    private struct Page: Decodable { let entries: [Entry]; let cursor: String; let hasMore: Bool
        enum CodingKeys: String, CodingKey { case entries, cursor, hasMore = "has_more" }
    }
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, Int)
    private let token: String
    private let directory: String
    private let transport: Transport
    private let validate: @MainActor () throws -> Void
    init(token: String, directory: String, transport: @escaping Transport = BoundDropboxSaveDeletion.perform,
         validate: @escaping @MainActor () throws -> Void = {}) {
        self.token = token; self.directory = directory; self.transport = transport; self.validate = validate
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    static func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await network.data(for: request)
        guard data.count <= 4 * 1024 * 1024, let response = response as? HTTPURLResponse else { throw Failure.response }
        return (data, response.statusCode)
    }

    static func accountID(token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("null".utf8)
        let (data, status) = try await perform(request)
        guard status == 200, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = value["account_id"] as? String, account.hasPrefix("dbid:"), account.count <= 256 else { throw Failure.response }
        return account
    }

    private func request(_ route: String, body: [String: Any]?, missingIsSuccess: Bool = false) async throws -> Data? {
        try validate(); try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/" + route)!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data("null".utf8)
        let (data, status): (Data, Int)
        do { (data, status) = try await transport(request) }
        catch { throw Failure.unavailable }
        try validate(); try Task.checkCancellation()
        if status == 409, missingIsSuccess,
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let summary = value["error_summary"] as? String, summary.hasPrefix("path/not_found/") || summary == "path/not_found" || summary.hasPrefix("path_lookup/not_found/") || summary == "path_lookup/not_found" {
            return nil
        }
        guard status == 200 else { throw Failure.unavailable }
        return data
    }

    private func inventory(templateIDs: [String]) async throws -> [Entry] {
        guard !directory.isEmpty, !directory.contains("/"), directory != ".", directory != ".." else { throw Failure.unsafeRecord }
        var route = "files/list_folder"
        var body: [String: Any] = ["path": "/" + directory, "recursive": false, "include_deleted": false, "limit": 200]
        if !templateIDs.isEmpty { body["include_property_groups"] = [".tag": "filter_some", "filter_some": templateIDs] }
        var entries = [Entry](); var seenCursors = Set<String>()
        while true {
            guard let data = try await request(route, body: body, missingIsSuccess: route == "files/list_folder") else { return [] }
            let page = try JSONDecoder().decode(Page.self, from: data)
            entries += page.entries
            guard entries.count <= 100000 else { throw Failure.response }
            guard page.hasMore else { return entries }
            guard !page.cursor.isEmpty, seenCursors.insert(page.cursor).inserted else { throw Failure.response }
            route = "files/list_folder/continue"; body = ["cursor": page.cursor]
        }
    }

    private func identifySnapshots(_ entries: [Entry]) async throws -> [Entry] {
        var identified = [Entry]()
        for entry in entries {
            guard entry.tag == "file", entry.name.lowercased().hasPrefix("savestate-"),
                  let identifier = UUID(uuidString: String(entry.name.dropFirst("SaveState-".count))),
                  entry.metadata["harmony_recordedObjectType"] == nil ||
                    (entry.metadata["verifiedGameID"] ?? entry.metadata["gameID"]) == nil else {
                identified.append(entry); continue
            }
            // Older/custom Dropbox metadata can be absent. Read the small
            // Harmony record JSON only; never instantiate or download a save.
            guard let id = entry.id, id.hasPrefix("id:"),
                  entry.pathLower == "/" + directory.lowercased() + "/" + entry.name.lowercased() else { throw Failure.unsafeRecord }
            try validate(); try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let argument = try JSONSerialization.data(withJSONObject: ["path": id])
            request.setValue(String(decoding: argument, as: UTF8.self), forHTTPHeaderField: "Dropbox-API-Arg")
            let (data, status) = try await transport(request)
            try validate(); try Task.checkCancellation()
            guard status == 200, data.count <= 256 * 1024,
                  let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["type"] as? String == "SaveState",
                  let recordID = record["identifier"] as? String, UUID(uuidString: recordID) == identifier,
                  let relationships = record["relationships"] as? [String: [String: String]],
                  let game = relationships["game"], game["type"] == "Game", let gameID = game["identifier"] else { throw Failure.unsafeRecord }
            var fields = entry.propertyGroups?.flatMap(\.fields) ?? []
            fields += [Entry.Field(name: "harmony_recordedObjectType", value: "SaveState"),
                       Entry.Field(name: "harmony_recordedObjectIdentifier", value: recordID),
                       Entry.Field(name: "gameID", value: gameID)]
            identified.append(Entry(tag: entry.tag, id: entry.id, name: entry.name, pathLower: entry.pathLower,
                                    propertyGroups: [Entry.Group(fields: fields)]))
        }
        return identified
    }

    /// Exposed internally for focused scoping tests; metadata wins over a stale
    /// gameID when a corrupted snapshot was reassigned using verifiedGameID.
    static func selectedEntries(_ entries: [Entry], gameID: String, localSaveStateIDs: Set<String>, directory: String) throws -> [Entry] {
        guard !gameID.isEmpty, !gameID.contains("/"), !gameID.contains("\\") else { throw Failure.unsafeRecord }
        let root = "/" + directory.lowercased() + "/"
        var snapshots = localSaveStateIDs
        for entry in entries where entry.tag == "file" {
            let metadata = entry.metadata
            guard metadata["harmony_recordedObjectType"] == "SaveState",
                  (metadata["verifiedGameID"] ?? metadata["gameID"]) == gameID,
                  let identifier = metadata["harmony_recordedObjectIdentifier"] else { continue }
            guard UUID(uuidString: identifier) != nil,
                  entry.name.lowercased() == ("SaveState-" + identifier).lowercased() else { throw Failure.unsafeRecord }
            snapshots.insert(identifier)
        }
        var names = Set(["GameSave-" + gameID])
        var recordNames = Set([("GameSave-" + gameID).lowercased()])
        for payload in ["gameSave", "gameTimeSave", "boundMultiplayerPackage"] { names.insert("GameSave-" + gameID + "-" + payload) }
        for identifier in snapshots {
            guard UUID(uuidString: identifier) != nil else { throw Failure.unsafeRecord }
            recordNames.insert(("SaveState-" + identifier).lowercased())
            for suffix in ["", "-saveState", "-thumbnail"] { names.insert("SaveState-" + identifier + suffix) }
        }
        let lowerNames = Set(names.map { $0.lowercased() })
        return try entries.filter { entry in
            guard entry.tag == "file", lowerNames.contains(entry.name.lowercased()) else { return false }
            guard let path = entry.pathLower, path == root + entry.name.lowercased(),
                  let id = entry.id, id.hasPrefix("id:") else { throw Failure.unsafeRecord }
            if entry.metadata["harmony_recordedObjectType"] == "SaveState",
               let remoteGame = entry.metadata["verifiedGameID"] ?? entry.metadata["gameID"], remoteGame != gameID {
                throw Failure.unsafeRecord
            }
            if entry.metadata["harmony_recordedObjectType"] == "GameSave",
               entry.metadata["harmony_recordedObjectIdentifier"] != gameID { throw Failure.unsafeRecord }
            return true
        }.sorted {
            // Keep the record until its payloads are removed so retries can
            // rediscover cloud-only snapshots even after a partial failure.
            let leftRecord = recordNames.contains($0.name.lowercased())
            let rightRecord = recordNames.contains($1.name.lowercased())
            return leftRecord == rightRecord ? $0.name < $1.name : !leftRecord
        }
    }

    func delete(gameID: String, localSaveStateIDs: Set<String>) async throws {
        let data = try await request("file_properties/templates/list_for_user", body: nil)
        guard let data, let templates = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let templateIDs = templates["template_ids"] as? [String] else { throw Failure.response }
        let before = try await identifySnapshots(inventory(templateIDs: templateIDs))
        let selected = try Self.selectedEntries(before, gameID: gameID, localSaveStateIDs: localSaveStateIDs, directory: directory)
        for entry in selected {
            _ = try await request("files/delete_v2", body: ["path": entry.id!], missingIsSuccess: true)
        }
        // Retain the IDs learned from cloud-only records through verification,
        // even if another client leaves/recreates a payload without its record.
        var selectedSnapshotIDs = localSaveStateIDs
        for entry in selected where entry.metadata["harmony_recordedObjectType"] == "SaveState" {
            if let id = entry.metadata["harmony_recordedObjectIdentifier"] { selectedSnapshotIDs.insert(id) }
        }
        let after = try await identifySnapshots(inventory(templateIDs: templateIDs))
        guard try Self.selectedEntries(after, gameID: gameID, localSaveStateIDs: selectedSnapshotIDs, directory: directory).isEmpty else { throw Failure.changed }
    }
}

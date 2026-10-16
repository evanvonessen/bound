//
//  DropboxService.swift
//  Harmony-Dropbox
//
//  Created by Riley Testut on 3/4/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
import UIKit

import Harmony

import SwiftyDropbox

extension DropboxService
{
    enum DropboxError: LocalizedError
    {
        case nilDirectoryName
        
        var errorDescription: String? {
            switch self
            {
            case .nilDirectoryName: return NSLocalizedString("There is no provided Dropbox directory name.", comment: "")
            }
        }
    }
    
    private struct OAuthError: LocalizedError
    {
        var oAuthError: OAuth2Error
        var errorDescription: String?
        
        init(error: OAuth2Error, description: String)
        {
            self.oAuthError = error
            self.errorDescription = description
        }
    }
    
    internal enum CallError<T>: Error
    {
        case error(SwiftyDropbox.CallError<T>)
        
        init(_ callError: SwiftyDropbox.CallError<T>)
        {
            self = .error(callError)
        }
        
        init?(_ callError: SwiftyDropbox.CallError<T>?)
        {
            guard let callError = callError else { return nil }
            self = .error(callError)
        }
    }
}

public class DropboxService: NSObject, Service
{
    final class OAuthValidationAttempt
    {
        private let lock = NSLock()
        private var active = true
        private var handlers = [(Result<Account, AuthenticationError>) -> Void]()
        private var cancellationHandlers = [() -> Void]()

        init(handler: @escaping (Result<Account, AuthenticationError>) -> Void) { handlers.append(handler) }

        func append(_ handler: @escaping (Result<Account, AuthenticationError>) -> Void) -> Bool
        {
            lock.lock(); defer { lock.unlock() }
            guard active else { return false }
            handlers.append(handler)
            return true
        }

        var isActive: Bool
        {
            lock.lock(); defer { lock.unlock() }
            return active
        }

        func performIfActive(_ action: () -> Void) -> Bool
        {
            lock.lock(); defer { lock.unlock() }
            guard active else { return false }
            action()
            return true
        }

        func track(_ cancellationHandler: @escaping () -> Void)
        {
            lock.lock()
            let shouldCancel = !active
            if !shouldCancel { cancellationHandlers.append(cancellationHandler) }
            lock.unlock()
            if shouldCancel { cancellationHandler() }
        }

        func finish(_ result: Result<Account, AuthenticationError>)
        {
            lock.lock()
            guard active else { lock.unlock(); return }
            active = false
            let handlers = self.handlers
            self.handlers.removeAll()
            cancellationHandlers.removeAll()
            lock.unlock()
            handlers.forEach { $0(result) }
        }

        func cancel()
        {
            lock.lock()
            guard active else { lock.unlock(); return }
            active = false
            let handlers = self.handlers
            let cancellations = cancellationHandlers
            self.handlers.removeAll()
            cancellationHandlers.removeAll()
            lock.unlock()
            cancellations.forEach { $0() }
            handlers.forEach { $0(.failure(.notAuthenticated)) }
        }
    }

    public static let shared = DropboxService()
    
    public let localizedName = NSLocalizedString("Dropbox", comment: "")
    public let identifier = "com.rileytestut.Harmony.Dropbox"
    
    public var clientID: String? {
        didSet {
            guard let clientID = self.clientID else { return }
            DropboxClientsManager.setupWithAppKey(clientID)
        }
    }
    
    public var preferredDirectoryName: String?

    /// Optional app-owned OAuth implementation. When set, Harmony delegates
    /// authorization to it instead of using the pinned SDK's implicit flow.
    public var accessTokenProvider: ((UIViewController?, @escaping (Result<String, AuthenticationError>) -> Void) -> Void)?
    public var deauthenticationHandler: (() -> Void)?
    
    internal private(set) var dropboxClient: DropboxClient?
    internal let responseQueue = DispatchQueue(label: "com.rileytestut.Harmony.Dropbox.responseQueue")
    
    private var authorizationCompletionHandlers = [(Result<Account, AuthenticationError>) -> Void]()
    private let oauthValidationLock = NSLock()
    private var oauthValidationAttempt: OAuthValidationAttempt?
    
    private var accountID: String? {
        get {
            return UserDefaults.standard.string(forKey: "harmony-dropbox_accountID")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "harmony-dropbox_accountID")
        }
    }
    
    private(set) var propertyGroupTemplate: (String, FileProperties.PropertyGroupTemplate)?
    
    private override init()
    {
        super.init()
    }
}

public extension DropboxService
{
    /// Cancels Bound's in-flight Dropbox account and metadata validation while
    /// preserving the saved refresh credential and legacy Harmony behavior.
    func cancelPendingAuthenticationValidation()
    {
        guard self.accessTokenProvider != nil else { return }
        self.cancelPendingOAuthValidation()
    }

    func authenticate(withPresentingViewController viewController: UIViewController, completionHandler: @escaping (Result<Account, AuthenticationError>) -> Void)
    {
        if let accessTokenProvider {
            guard let (attempt, shouldBegin) = self.beginOAuthValidation(completionHandler) else { return }
            guard shouldBegin else { return }
            accessTokenProvider(viewController) { result in
                guard attempt.isActive else { return }
                switch result {
                case .success(let token):
                    let accepted = attempt.performIfActive { DropboxClientsManager.authorizedClient = DropboxClient(accessToken: token) }
                    if accepted { self.finishAuthentication(attempt: attempt) }
                case .failure(let error):
                    self.completeOAuthValidation(attempt, result: .failure(error))
                }
            }
            return
        }

        self.authorizationCompletionHandlers.append(completionHandler)
        
        DropboxClientsManager.authorizeFromController(UIApplication.shared, controller: viewController) { (url) in
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
    
    func authenticateInBackground(completionHandler: @escaping (Result<Account, AuthenticationError>) -> Void)
    {
        if let accessTokenProvider {
            guard let (attempt, shouldBegin) = self.beginOAuthValidation(completionHandler) else { return }
            guard shouldBegin else { return }
            accessTokenProvider(nil) { result in
                guard attempt.isActive else { return }
                switch result {
                case .success(let token):
                    let accepted = attempt.performIfActive { DropboxClientsManager.authorizedClient = DropboxClient(accessToken: token) }
                    if accepted { self.finishAuthentication(attempt: attempt) }
                case .failure(let error):
                    self.completeOAuthValidation(attempt, result: .failure(error))
                }
            }
            return
        }

        guard let accountID = self.accountID else { return completionHandler(.failure(.noSavedCredentials)) }
        
        self.authorizationCompletionHandlers.append(completionHandler)
        
        DropboxClientsManager.reauthorizeClient(accountID)
        
        self.finishAuthentication()
    }
    
    func deauthenticate(completionHandler: @escaping (Result<Void, DeauthenticationError>) -> Void)
    {
        self.cancelPendingOAuthValidation()
        if let deauthenticationHandler {
            deauthenticationHandler()
            DropboxClientsManager.authorizedClient = nil
            self.dropboxClient = nil
            self.propertyGroupTemplate = nil
        } else {
            DropboxClientsManager.unlinkClients()
        }
        
        self.accountID = nil
        completionHandler(.success)
    }
    
    func handleDropboxURL(_ url: URL) -> Bool
    {
        // The app-owned PKCE flow is completed by ASWebAuthenticationSession.
        // Do not pass its `?code=` callback to the legacy SDK's fragment parser.
        guard self.accessTokenProvider == nil else { return false }
        guard let result = DropboxClientsManager.handleRedirectURL(url) else { return false }
        
        switch result
        {
        case .cancel:
            self.authorizationCompletionHandlers.forEach { $0(.failure(.other(GeneralError.cancelled))) }
            self.authorizationCompletionHandlers.removeAll()
            
        case .success:
            self.finishAuthentication()
            
        case .error(let error, let description):
            Logger.sync.error("Failed to authenticate with Dropbox. \(String(describing: error), privacy: .public) \(description, privacy: .public)")
            
            let oAuthError = OAuthError(error: error, description: description)
            self.authorizationCompletionHandlers.forEach { $0(.failure(.other(oAuthError))) }
            
            self.authorizationCompletionHandlers.removeAll()
        }
        
        return true
    }
}

private extension DropboxService
{
    func beginOAuthValidation(_ handler: @escaping (Result<Account, AuthenticationError>) -> Void) -> (OAuthValidationAttempt, Bool)?
    {
        oauthValidationLock.lock(); defer { oauthValidationLock.unlock() }
        if let attempt = oauthValidationAttempt {
            if !attempt.append(handler) {
                let replacement = OAuthValidationAttempt(handler: handler)
                oauthValidationAttempt = replacement
                return (replacement, true)
            }
            return (attempt, false)
        }
        let attempt = OAuthValidationAttempt(handler: handler)
        oauthValidationAttempt = attempt
        return (attempt, true)
    }

    func clearOAuthValidation(_ attempt: OAuthValidationAttempt)
    {
        oauthValidationLock.lock(); defer { oauthValidationLock.unlock() }
        if oauthValidationAttempt === attempt { oauthValidationAttempt = nil }
    }

    func cancelPendingOAuthValidation()
    {
        oauthValidationLock.lock()
        let attempt = oauthValidationAttempt
        oauthValidationAttempt = nil
        oauthValidationLock.unlock()
        attempt?.cancel()
        guard attempt != nil else { return }

        oauthValidationLock.lock()
        if oauthValidationAttempt == nil {
            DropboxClientsManager.authorizedClient = nil
            self.dropboxClient = nil
        }
        oauthValidationLock.unlock()
    }

    func finishAuthentication(attempt: OAuthValidationAttempt)
    {
        guard attempt.isActive else { return }
        guard let dropboxClient = DropboxClientsManager.authorizedClient else {
            completeOAuthValidation(attempt, result: .failure(.notAuthenticated)); return
        }

        let request = dropboxClient.users.getCurrentAccount()
        attempt.track { request.cancel() }
        request.response { account, error in
            guard attempt.isActive else { return }
            do {
                let account = try self.process(Result(account, error))
                self.createSyncDirectoryIfNeeded(attempt: attempt) { result in
                    guard attempt.isActive else { return }
                    switch result {
                    case .success:
                        let metadata = HarmonyMetadataKey.allHarmonyKeys.reduce(into: [:], { $0[$1] = $1.rawValue as Any })
                        self.validateMetadata(metadata, attempt: attempt) { result in
                            guard attempt.isActive else { return }
                            switch result {
                            case .success:
                                let stored = attempt.performIfActive {
                                    self.dropboxClient = dropboxClient
                                    self.accountID = account.accountId
                                }
                                if stored { self.completeOAuthValidation(attempt, result: .success(Account(name: account.name.displayName, emailAddress: account.email))) }
                            case .failure(let error): self.completeOAuthValidation(attempt, result: .failure(AuthenticationError(error)))
                            }
                        }
                    case .failure(let error):
                        self.completeOAuthValidation(attempt, result: .failure(AuthenticationError(error)))
                    }
                }
            } catch {
                self.completeOAuthValidation(attempt, result: .failure(AuthenticationError(error)))
            }
        }
    }

    func completeOAuthValidation(_ attempt: OAuthValidationAttempt, result: Result<Account, AuthenticationError>)
    {
        self.clearOAuthValidation(attempt)
        attempt.finish(result)
    }
}

private extension DropboxService
{
    func finishAuthentication()
    {
        func finish(_ result: Result<Account, AuthenticationError>)
        {
            // Reset self.authorizationCompletionHandlers _before_ calling all the completion handlers.
            // This stops us from accidentally calling completion handlers twice in some instances.
            let completionHandlers = self.authorizationCompletionHandlers
            self.authorizationCompletionHandlers.removeAll()
            
            completionHandlers.forEach { $0(result) }
        }
        
        guard let dropboxClient = DropboxClientsManager.authorizedClient else { return finish(.failure(.notAuthenticated)) }
        
        dropboxClient.users.getCurrentAccount().response { (account, error) in
            do
            {
                let account = try self.process(Result(account, error))
                
                self.createSyncDirectoryIfNeeded() { (result) in
                    switch result
                    {
                    case .success:
                        // Validate metadata first so we can also retrieve property group template ID.
                        let dummyMetadata = HarmonyMetadataKey.allHarmonyKeys.reduce(into: [:], { $0[$1] = $1.rawValue as Any })
                        self.validateMetadata(dummyMetadata) { (result) in
                            switch result
                            {
                            case .success:
                                // We could just always use DropboxClientsManager.authorizedClient,
                                // but this way dropboxClient is nil until _all_ authentication steps are finished.
                                self.dropboxClient = dropboxClient
                                self.accountID = account.accountId
                                
                                let account = Account(name: account.name.displayName, emailAddress: account.email)
                                finish(.success(account))
                                
                            case .failure(let error):
                                finish(.failure(AuthenticationError(error)))
                            }
                        }
                        
                    case .failure(let error):
                        finish(.failure(AuthenticationError(error)))
                    }
                }
            }
            catch
            {
                finish(.failure(AuthenticationError(error)))
            }
        }
    }
    
    func createSyncDirectoryIfNeeded(attempt: OAuthValidationAttempt? = nil, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        do
        {
            guard attempt?.isActive ?? true else { return }
            guard let dropboxClient = DropboxClientsManager.authorizedClient else { throw AuthenticationError.notAuthenticated }
            
            let path = try self.remotePath(filename: nil)
            let metadataRequest = dropboxClient.files.getMetadata(path: path)
            attempt?.track { metadataRequest.cancel() }
            metadataRequest.response(queue: self.responseQueue) { (metadata, error) in
                guard attempt?.isActive ?? true else { return }
                // Retrieved metadata successfully, which means folder exists, so no need to do anything else.
                guard let error = error else { return completionHandler(.success) }
                
                if case .routeError(let error, _, _, _) = error, case .path(.notFound) = error.unboxed
                {
                    guard attempt?.isActive ?? true else { return }
                    let createRequest = dropboxClient.files.createFolderV2(path: path)
                    attempt?.track { createRequest.cancel() }
                    createRequest.response(queue: self.responseQueue) { (result, error) in
                        guard attempt?.isActive ?? true else { return }
                        do
                        {
                            try self.process(Result(error))
                            
                            completionHandler(.success)
                        }
                        catch
                        {
                            completionHandler(.failure(error))
                        }
                    }
                }
                else
                {
                    completionHandler(.failure(CallError(error)))
                }
            }
        }
        catch
        {
            completionHandler(.failure(error))
        }
    }
}

extension DropboxService
{
    func process<T, E>(_ result: Result<T, CallError<E>>) throws -> T
    {
        do
        {
            do
            {
                let value = try result.get()
                return value
            }
            catch let error
            {
                do
                {
                    throw error
                }
                catch CallError<E>.error(.authError(let authError, _, _, _))
                {
                    switch authError
                    {
                    case .invalidAccessToken: throw AuthenticationError.notAuthenticated
                    case .expiredAccessToken: throw AuthenticationError.tokenExpired
                    default: break
                    }
                }
                catch CallError<E>.error(.rateLimitError)
                {
                    throw ServiceError.rateLimitExceeded
                }
                catch CallError<E>.error(.clientError(let error as URLError))
                {
                    throw ServiceError.connectionFailed(error)
                }
                catch CallError<E>.error(.routeError(let boxedError, _, _, _))
                {
                    switch boxedError.unboxed
                    {
                    case let error as Files.DownloadError:
                        if case .path(.notFound) = error
                        {
                            throw ServiceError.itemDoesNotExist
                        }
                        
                        if case .path(.restrictedContent) = error
                        {
                            throw ServiceError.restrictedContent
                        }
                        
                    case let error as Files.UploadError:
                        if case .path(let failure) = error
                        {
                            switch failure.reason
                            {
                            case .insufficientSpace: throw ServiceError.insufficentSpace
                            default: break
                            }
                        }
                        
                    case let error as Files.GetMetadataError:
                        if case .path(.notFound) = error
                        {
                            throw ServiceError.itemDoesNotExist
                        }
                        
                    case let error as Files.DeleteError:
                        if case .pathLookup(.notFound) = error
                        {
                            throw ServiceError.itemDoesNotExist
                        }
                        
                    case let error as Files.ListRevisionsError:
                        if case .path(.notFound) = error
                        {
                            throw ServiceError.itemDoesNotExist
                        }
                        
                    default: break
                    }
                }
                catch
                {
                    // Ignore, just here to prevent propagating to outer do-catch.
                }
                
                // If we haven't re-thrown the error as a HarmonyError by now, throw it now.
                throw ServiceError(error)
            }
        }
        catch let error as HarmonyError
        {
            throw error
        }
        catch
        {
            assertionFailure("Non-HarmonyError thrown from DropboxService.process(_:)")
            throw error
        }
    }
    
    func validateMetadata<T>(_ metadata: [HarmonyMetadataKey: T], attempt: OAuthValidationAttempt? = nil, completionHandler: @escaping (Result<String, Error>) -> Void)
    {
        guard attempt?.isActive ?? true else { return }
        let fields = metadata.keys.map { FileProperties.PropertyFieldTemplate(name: $0.rawValue, description_: $0.rawValue, type: .string_) }
        
        do
        {
            guard let dropboxClient = DropboxClientsManager.authorizedClient else { throw AuthenticationError.notAuthenticated }
            
            if let (templateID, propertyGroupTemplate) = self.propertyGroupTemplate
            {
                let existingFields = Set(propertyGroupTemplate.fields.map { $0.name })
                
                let addedFields = fields.filter { !existingFields.contains($0.name) }
                guard !addedFields.isEmpty else { return completionHandler(.success(templateID)) }
                
                guard attempt?.isActive ?? true else { return }
                let updateRequest = dropboxClient.file_properties.templatesUpdateForUser(templateId: templateID, name: nil, description_: nil, addFields: addedFields)
                attempt?.track { updateRequest.cancel() }
                updateRequest.response(queue: self.responseQueue) { (result, error) in
                    guard attempt?.isActive ?? true else { return }
                    do
                    {
                        let result = try self.process(Result(result, error))
                        
                        let templateID = result.templateId
                        self.fetchPropertyGroupTemplate(forTemplateID: templateID, attempt: attempt) { (result) in
                            guard attempt?.isActive ?? true else { return }
                            switch result
                            {
                            case .success: completionHandler(.success(templateID))
                            case .failure(let error): completionHandler(.failure(error))
                            }
                        }
                    }
                    catch
                    {
                        completionHandler(.failure(error))
                    }
                }
            }
            else
            {
                let listRequest = dropboxClient.file_properties.templatesListForUser()
                attempt?.track { listRequest.cancel() }
                listRequest.response(queue: self.responseQueue) { (result, error) in
                    guard attempt?.isActive ?? true else { return }
                    do
                    {
                        let result = try self.process(Result(result, error))
                        
                        if let templateID = result.templateIds.first
                        {
                            self.fetchPropertyGroupTemplate(forTemplateID: templateID, attempt: attempt) { (result) in
                                guard attempt?.isActive ?? true else { return }
                                switch result
                                {
                                case .success: self.validateMetadata(metadata, attempt: attempt, completionHandler: completionHandler)
                                case .failure(let error): completionHandler(.failure(error))
                                }
                            }
                        }
                        else
                        {
                            guard attempt?.isActive ?? true else { return }
                            let addRequest = dropboxClient.file_properties.templatesAddForUser(name: "Harmony", description_: "Harmony syncing metadata.", fields: fields)
                            attempt?.track { addRequest.cancel() }
                            addRequest.response(queue: self.responseQueue) { (result, error) in
                                guard attempt?.isActive ?? true else { return }
                                do
                                {
                                    let result = try self.process(Result(result, error))
                                    
                                    let templateID = result.templateId
                                    self.fetchPropertyGroupTemplate(forTemplateID: templateID, attempt: attempt) { (result) in
                                        guard attempt?.isActive ?? true else { return }
                                        switch result
                                        {
                                        case .success: completionHandler(.success(templateID))
                                        case .failure(let error): completionHandler(.failure(error))
                                        }
                                    }
                                }
                                catch
                                {
                                    completionHandler(.failure(error))
                                }
                            }
                        }
                    }
                    catch
                    {
                        completionHandler(.failure(error))
                    }
                }
            }
        }
        catch
        {
            completionHandler(.failure(error))
        }
    }
    
    func fetchPropertyGroupTemplate(forTemplateID templateID: String, attempt: OAuthValidationAttempt? = nil, completionHandler: @escaping (Result<FileProperties.PropertyGroupTemplate, Error>) -> Void)
    {
        do
        {
            guard attempt?.isActive ?? true else { return }
            guard let dropboxClient = DropboxClientsManager.authorizedClient else { throw AuthenticationError.notAuthenticated }
            
            let getRequest = dropboxClient.file_properties.templatesGetForUser(templateId: templateID)
            attempt?.track { getRequest.cancel() }
            getRequest.response(queue: self.responseQueue) { (result, error) in
                guard attempt?.isActive ?? true else { return }
                do
                {
                    let result = try self.process(Result(result, error))
                    if let attempt {
                        guard attempt.performIfActive({ self.propertyGroupTemplate = (templateID, result) }) else { return }
                    } else {
                        self.propertyGroupTemplate = (templateID, result)
                    }
                    
                    completionHandler(.success(result))
                }
                catch
                {
                    completionHandler(.failure(error))
                }
            }
        }
        catch
        {
            completionHandler(.failure(error))
        }
    }
    
    func remotePath(filename: String?) throws -> String
    {
        guard let directoryName = self.preferredDirectoryName else { throw DropboxError.nilDirectoryName }
        
        var remotePath = "/" + directoryName
        
        if let filename = filename
        {
           remotePath += "/" + filename
        }
        
        return remotePath
    }
}

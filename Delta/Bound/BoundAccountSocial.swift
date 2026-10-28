import SwiftUI
import UIKit
import UserNotifications
import Combine

struct BoundSocialResponse: Decodable, Sendable {
    let ok: Bool
    var username: String?
    var error: String?
    var status: String?
    var duplicate: Bool?
    var configured: Bool?
}

enum BoundSocialError: LocalizedError {
    case rejected(String?)
    var errorDescription: String? {
        switch self {
        case .rejected("name_not_allowed"): return "Choose a username with 1–40 characters. Links, email addresses and unsafe names aren't allowed."
        case .rejected("username_taken"): return "That username is already taken. Choose another."
        case .rejected("rate_limited"): return "Please wait before trying again."
        case .rejected("friend_unavailable"): return "Your friend hasn't enabled Jiggles on an available device."
        case .rejected("not_configured"): return "Jiggles aren't available yet. Push notifications still need to be configured for Bound."
        case .rejected("notifications_disabled"): return "Enable notifications for Bound in iOS Settings."
        default: return "Couldn't complete that request. Please try again."
        }
    }
}

enum BoundSocialAPI {
    static func call(_ session: AppCloudSession, action: String, payload: [String: String]) async throws -> BoundSocialResponse {
        let response = try JSONDecoder().decode(BoundSocialResponse.self, from:
            await FriendSharingTokens.perform(session.friendSocialRequest(action: action, payload: payload)))
        guard response.ok else { throw BoundSocialError.rejected(response.error) }
        return response
    }
    static func validUsername(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.unicodeScalars.count <= 40 && trimmed == value
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0)
                || (0x200B...0x200F).contains($0.value) || (0x202A...0x202E).contains($0.value)
                || (0x2066...0x2069).contains($0.value) || $0.value == 0xFEFF }
    }
}

@MainActor
final class BoundAccountProfile: ObservableObject {
    static let shared = BoundAccountProfile()
    static let didChangeNotification = Notification.Name("BoundAccountProfileDidChange")
    @Published private(set) var username: String?
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    private let account: BoundFriendAccount
    private let perform: @MainActor (AppCloudSession, String, [String: String]) async throws -> BoundSocialResponse
    private var subscription: AnyCancellable?
    private var owner: UUID?
    private var generation = UUID()

    init(account: BoundFriendAccount? = nil,
         perform: @escaping @MainActor (AppCloudSession, String, [String: String]) async throws -> BoundSocialResponse = BoundSocialAPI.call) {
        self.account = account ?? BoundFriendAccount.shared; self.perform = perform
        subscription = self.account.$session.sink { [weak self] session in
            guard let self, self.owner != session?.owner else { return }
            self.generation = UUID(); self.owner = session?.owner
            self.username = nil; self.busy = false; self.status = ""
        }
    }
    func refresh() async { await update(action: "profile", payload: [:]) }
    func rename(_ value: String) async {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BoundSocialAPI.validUsername(value) else { status = BoundSocialError.rejected("name_not_allowed").localizedDescription; return }
        await update(action: "username", payload: ["username": value])
    }
    private func update(action: String, payload: [String: String]) async {
        guard !busy, let identity = account.session else { return }
        owner = identity.owner
        let run = generation
        busy = true; status = ""
        defer { if generation == run { busy = false } }
        do {
            await account.refreshIfNeeded()
            guard generation == run, identity.isSameSession(as: account.session) else { return }
            let response = try await perform(identity, action, payload)
            guard generation == run, identity.isSameSession(as: account.session) else { return }
            guard response.ok, let name = response.username, BoundSocialAPI.validUsername(name) else {
                throw BoundSocialError.rejected(response.error)
            }
            username = name
            if action == "username" {
                status = "Username updated for all your friends."
                NotificationCenter.default.post(name: Self.didChangeNotification, object: identity.owner)
            }
        } catch {
            guard generation == run, identity.isSameSession(as: account.session) else { return }
            status = (error as? BoundSocialError)?.localizedDescription ?? "Couldn't load your username. Try again."
        }
    }
}

/// Device registration is opt-in. Account switches and disabling the preference stop
/// local delivery immediately and revoke this installation's server registration.
@MainActor
final class BoundJiggleNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = BoundJiggleNotifications()
    @Published private(set) var enabled = false
    @Published private(set) var notifyFriendOnJoin = true
    @Published private(set) var notifyMeOfInvites = true
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    private let account = BoundFriendAccount.shared
    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    private var owner: UUID?
    private var token: Data?
    private var generation = UUID()
    private var subscription: AnyCancellable?
    private var observations: [NSObjectProtocol] = []
    private var upload: Task<Void, Never>?
    private var started = false
    private var registeredIdentity: AppCloudSession?
    private var registrationReady = false
    private struct PendingGameEvent {
        let roomID: String
        let runID: UUID
        let requestID: UUID
        let kind: String
    }
    private var pendingGameEvents: [PendingGameEvent] = []
    private var preferenceKey: String? { owner.map { "bound.jiggles.enabled.v1." + $0.uuidString.lowercased() } }
    private var installation: String {
        let key = "bound.jiggles.installation.v1"
        if let raw = defaults.string(forKey: key), UUID(uuidString: raw) != nil { return raw }
        let value = UUID().uuidString.lowercased(); defaults.set(value, forKey: key); return value
    }
    private func nextRegistrationRevision() -> String {
        let key = "bound.jiggles.registration-revision.v1"
        let previous = defaults.object(forKey: key) as? NSNumber
        let revision = max((previous?.int64Value ?? 0) + 1, Int64(Date().timeIntervalSince1970 * 1000))
        defaults.set(NSNumber(value: revision), forKey: key)
        return String(revision)
    }
    func start() {
        guard !started else { return }
        started = true; center.delegate = self
        subscription = self.account.$session.sink { [weak self] session in self?.accountChanged(session) }
        observations.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.reconcile() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: BoundFriendAccount.willSignOutNotification, object: account, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revokeRegistration() }
        })
        Task { await reconcile() }
    }
    private func accountChanged(_ identity: AppCloudSession?) {
        guard owner != identity?.owner else { return }
        revokeRegistration()
        generation = UUID(); upload?.cancel(); upload = nil
        token = nil; owner = identity?.owner
        enabled = preferenceKey.map { defaults.bool(forKey: $0) } ?? false
        notifyFriendOnJoin = preferenceKey.map { defaults.object(forKey: $0 + ".send-join") as? Bool ?? true } ?? true
        notifyMeOfInvites = preferenceKey.map { defaults.object(forKey: $0 + ".receive-invites") as? Bool ?? true } ?? true
        status = ""
        if started { Task { await reconcile() } }
    }
    func setEnabled(_ value: Bool) async {
        guard account.session != nil, !busy else { return }
        if !value {
            revokeRegistration()
            enabled = false
            if let preferenceKey { defaults.set(false, forKey: preferenceKey) }
            status = "Notifications are off on this device."
            return
        }
        let run = generation; busy = true
        defer { if generation == run { busy = false } }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard run == generation else { return }
            guard granted else { status = BoundSocialError.rejected("notifications_disabled").localizedDescription; return }
            enabled = true
            if let preferenceKey { defaults.set(true, forKey: preferenceKey) }
            await reconcile()
        } catch { if run == generation { status = "Couldn't enable notifications. Try again." } }
    }
    private func reconcile() async {
        guard enabled, let identity = account.session,
              identity.owner == owner else { revokeRegistration(); return }
        let run = generation
        let settings = await center.notificationSettings()
        guard generation == run, identity.isSameSession(as: account.session), enabled else { return }
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            revokeRegistration(); status = BoundSocialError.rejected("notifications_disabled").localizedDescription; return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }
    func setNotifyFriendOnJoin(_ value: Bool) {
        notifyFriendOnJoin = value
        if !value { pendingGameEvents.removeAll { $0.kind != "shared-invite" } }
        if let preferenceKey { defaults.set(value, forKey: preferenceKey + ".send-join") }
        synchronizePreferences()
    }
    func setNotifyMeOfInvites(_ value: Bool) {
        notifyMeOfInvites = value
        if let preferenceKey { defaults.set(value, forKey: preferenceKey + ".receive-invites") }
        synchronizePreferences()
    }
    private func preferenceRequest(_ identity: AppCloudSession) throws -> URLRequest {
        try identity.friendNotificationPreferencesRequest(payload: ["installationID": installation,
            "revision": nextRegistrationRevision(), "sendJoin": notifyFriendOnJoin ? "true" : "false",
            "receiveInvites": notifyMeOfInvites ? "true" : "false"])
    }
    private func synchronizePreferences() {
        guard enabled, let identity = account.session, identity.owner == owner,
              let request = try? preferenceRequest(identity) else { return }
        let generation = generation
        Task { [weak self] in
            do {
                let data = try await FriendSharingTokens.perform(request)
                guard let response = try? JSONDecoder().decode(BoundSocialResponse.self, from: data), response.ok else {
                    throw BoundSocialError.rejected("unavailable")
                }
            } catch {
                guard let self, self.generation == generation else { return }
                self.status = "Couldn't save notification settings. Try again when connected."
            }
        }
    }
    func sharedGameJoined(roomID: String, runID: UUID, started: Bool) {
        sendGameEvent(roomID: roomID, runID: runID, requestID: UUID(), kind: started ? "shared-start" : "shared-join")
    }
    func sharedGameInvited(roomID: String, runID: UUID, requestID: UUID) {
        sendGameEvent(roomID: roomID, runID: runID, requestID: requestID, kind: "shared-invite")
    }
    private func sendGameEvent(roomID: String, runID: UUID, requestID: UUID, kind: String) {
        guard enabled, kind == "shared-invite" || notifyFriendOnJoin,
              let identity = account.session, identity.owner == owner else { return }
        guard registrationReady else {
            // Admission may beat APNs registration after launch. Keep a bounded
            // account-scoped outbox until registration succeeds.
            if pendingGameEvents.count < 8, !pendingGameEvents.contains(where: { $0.requestID == requestID }) {
                pendingGameEvents.append(.init(roomID: roomID, runID: runID, requestID: requestID, kind: kind))
            }
            return
        }
        guard
              let preferences = try? preferenceRequest(identity),
              let request = try? identity.friendGameNotificationRequest(roomID: roomID, runID: runID, requestID: requestID, kind: kind, installationID: installation) else { return }
        // Notification delivery never owns gameplay or delays admission.
        Task { [weak self] in
            do {
                let data = try await FriendSharingTokens.perform(preferences)
                guard (try? JSONDecoder().decode(BoundSocialResponse.self, from: data))?.ok == true else {
                    throw BoundSocialError.rejected("unavailable")
                }
                guard let self, self.enabled, identity.isSameSession(as: self.account.session),
                      kind == "shared-invite" || self.notifyFriendOnJoin else { return }
                let result = try await BoundAuthTransport.perform(request)
                guard (200..<300).contains(result.status),
                      (try? JSONDecoder().decode(BoundSocialResponse.self, from: result.data))?.ok == true else {
                    throw BoundSocialError.rejected("unavailable")
                }
            } catch {
                guard let self, identity.isSameSession(as: self.account.session), self.enabled else { return }
                self.status = "Couldn't notify your friend."
            }
        }
    }
    func registered(token: Data) {
        guard token.count >= 16, token.count <= 256,
              enabled, let identity = account.session, identity.owner == owner else { return }
        self.token = token
        upload?.cancel()
        let run = generation
        let installation = installation
        let revision = nextRegistrationRevision()
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let deviceRequest: URLRequest
        do {
            deviceRequest = try identity.friendNotificationDeviceRequest(payload: ["installationID": installation, "revision": revision,
                "token": tokenString, "environment": environment, "sendJoin": notifyFriendOnJoin ? "true" : "false",
                "receiveInvites": notifyMeOfInvites ? "true" : "false"])
        } catch { return }
        registeredIdentity = identity
        upload = Task { [weak self] in
            do {
                let data = try await FriendSharingTokens.perform(deviceRequest)
                guard (try? JSONDecoder().decode(BoundSocialResponse.self, from: data))?.ok == true else {
                    throw BoundSocialError.rejected("unavailable")
                }
                guard let self, !Task.isCancelled, self.generation == run, identity.isSameSession(as: self.account.session),
                      self.enabled else { return }
                self.status = ""
                self.registrationReady = true
                self.synchronizePreferences()
                let pending = self.pendingGameEvents
                self.pendingGameEvents.removeAll()
                for event in pending {
                    self.sendGameEvent(roomID: event.roomID, runID: event.runID, requestID: event.requestID, kind: event.kind)
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == run else { return }
                self.status = "Couldn't register this device for Jiggles. Try again when connected."
            }
        }
    }
    func registrationFailed() {
        guard enabled else { return }
        status = "Push registration failed. Try again on a device with notifications enabled."
    }
    private func revokeRegistration() {
        registrationReady = false; pendingGameEvents.removeAll()
        generation = UUID(); upload?.cancel(); upload = nil; busy = false
        token = nil
        UIApplication.shared.unregisterForRemoteNotifications()
        let capturedIdentity = registeredIdentity ?? account.session.flatMap { identity in
            let previouslyEnabled = defaults.bool(forKey: "bound.jiggles.enabled.v1." + identity.owner.uuidString.lowercased())
            return previouslyEnabled && (owner == nil || identity.owner == owner) ? identity : nil
        }
        guard let identity = capturedIdentity else { return }
        registeredIdentity = nil
        // Capture the authorized request before sign-out can invalidate its token.
        guard let request = try? identity.friendSocialRequest(action: "unregister", payload: ["installationID": installation, "revision": nextRegistrationRevision()]) else { return }
        Task { _ = try? await FriendSharingTokens.perform(request) }
    }
    func prepareForSignOut() { revokeRegistration() }

    static func send(to room: FriendRoom, session: AppCloudSession) async throws -> String {
        let request = try session.friendJiggleRequest(roomID: room.roomID, requestID: UUID().uuidString.lowercased())
        let raw = try await BoundAuthTransport.perform(request)
        let response = try JSONDecoder().decode(BoundSocialResponse.self, from: raw.data)
        guard response.ok, (200..<300).contains(raw.status) else { throw BoundSocialError.rejected(response.error) }
        switch response.status {
        case "sent": return "Jiggle sent."
        case "queued": return "This Jiggle has already been requested."
        default: throw BoundSocialError.rejected(response.error)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let info = notification.request.content.userInfo
            guard self.enabled,
                  ["bound-jiggle", "shared-join", "shared-start", "shared-invite"].contains(info["kind"] as? String ?? ""),
                  (info["kind"] as? String == "shared-join" || self.notifyMeOfInvites),
                  info["recipientID"] as? String == self.account.session?.owner.uuidString.lowercased() else {
                completionHandler([]); return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            completionHandler([.banner, .list, .sound])
        }
    }
}

/// Settings borrows the running game's friends owner. Library settings owns a
/// temporary owner and releases its transport when the account page is removed.
@MainActor
final class BoundAccountFriendsContext: ObservableObject {
    let sharing: FriendSharingSession
    let onboarding: FriendOnboarding
    let account: BoundFriendAccount
    private let ownsSharing: Bool
    private var subscriptions: [AnyCancellable] = []

    init(sharing: FriendSharingSession? = nil, onboarding: FriendOnboarding? = nil,
         account: BoundFriendAccount? = nil) {
        let account = account ?? .shared
        ownsSharing = sharing == nil
        self.sharing = sharing ?? FriendSharingSession(authenticatedMode: true)
        self.onboarding = onboarding ?? FriendOnboarding.forUI()
        self.account = account
        subscriptions = [account.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                         self.onboarding.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }]
    }

    deinit {
        guard ownsSharing else { return }
        let onboarding = onboarding, sharing = sharing
        BoundMainActorDisposal.enqueue { onboarding.close(); sharing.stop() }
    }

    func open() { onboarding.open(sharing: sharing, existing: { [account] in account.session }) }
    func close() { onboarding.close() }
    func prepareForAccountRemoval() { onboarding.signOut(); sharing.stop() }

    var signedInUsername: String? {
        guard !account.deletionPending, let owner = account.session?.owner,
              onboarding.currentIdentity()?.owner == owner,
              let username = onboarding.accountUsername, BoundSocialAPI.validUsername(username) else { return nil }
        return username
    }
}

struct BoundAccountSocialSettings: View {
    static let stopSharingNotification = Notification.Name("BoundAccountSocialSettingsStopSharing")
    @ObservedObject private var account: BoundFriendAccount
    @ObservedObject private var notifications = BoundJiggleNotifications.shared
    @State private var email = ""
    @State private var password = ""
    private let prepareFriendsForAccountRemoval: () -> Void

    init(account: BoundFriendAccount? = nil, prepareFriendsForAccountRemoval: @escaping () -> Void = {}) {
        self.account = account ?? .shared
        self.prepareFriendsForAccountRemoval = prepareFriendsForAccountRemoval
    }

    var body: some View {
        Section("Bound Account") {
            if account.deletionPending {
                Button("Retry account deletion", role: .destructive) { retryAccountDeletion() }
                .disabled(account.busy)
                .accessibilityIdentifier("bound.account-delete-retry")
            } else if account.session != nil {
                NavigationLink("Account and Security") {
                    BoundAccountSecurityView(account: account) { email = $0 }
                }
                    .accessibilityIdentifier("bound.account-security")
                Toggle("Allow Notifications", isOn: Binding(get: { notifications.enabled }, set: { value in
                    Task { await notifications.setEnabled(value) }
                })).disabled(notifications.busy).accessibilityIdentifier("bound.jiggles-enabled")
                if notifications.enabled {
                    notificationCheckbox("Notify my friend when I join a shared game.", selected: notifications.notifyFriendOnJoin,
                                         identifier: "bound.notifications.send-join", action: notifications.setNotifyFriendOnJoin)
                    notificationCheckbox("Notify me when a friend invites me to a game or starts a shared server.", selected: notifications.notifyMeOfInvites,
                                         identifier: "bound.notifications.receive-invites", action: notifications.setNotifyMeOfInvites)
                }
                if !notifications.status.isEmpty { Text(notifications.status).font(.caption) }
                Button("Sign out", role: .destructive) { signOut() }
                    .disabled(account.busy || account.deletionPending)
                    .accessibilityIdentifier("bound.account-sign-out")
                NavigationLink {
                    BoundDeleteAccountView(account: account) { prepareForAccountRemoval() }
                } label: {
                    Text("Delete account").foregroundStyle(.red)
                }
                .disabled(account.busy)
                .accessibilityIdentifier("bound.account-delete")
            } else {
                BoundAccountSignInFields(account: account, email: $email, password: $password)
                Text(account.status).font(.caption)
                    .accessibilityIdentifier("account.signin.status")
            }
        }
        .onDisappear { password = "" }
    }

    private func notificationCheckbox(_ title: String, selected: Bool, identifier: String, action: @escaping (Bool) -> Void) -> some View {
        Button { action(!selected) } label: {
            HStack(alignment: .top) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                Text(title).foregroundStyle(.primary)
            }
        }
        .accessibilityIdentifier(identifier)
        .accessibilityValue(selected ? "On" : "Off")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func signOut() {
        guard account.session != nil, !account.busy, !account.deletionPending else { return }
        prepareForAccountRemoval()
        account.signOut()
    }

    private func retryAccountDeletion() {
        guard account.deletionPending, !account.busy else { return }
        prepareForAccountRemoval()
        Task { await account.resumeAccountDeletion() }
    }

    private func prepareForAccountRemoval() {
        prepareFriendsForAccountRemoval()
        postStopSharing()
        BoundJiggleNotifications.shared.prepareForSignOut()
    }

    private func postStopSharing() {
        NotificationCenter.default.post(name: Self.stopSharingNotification, object: nil)
    }
}

struct BoundUsernameSettings: View {
    @ObservedObject private var profile = BoundAccountProfile.shared
    @Environment(\.scenePhase) private var phase
    @State private var username = ""
    @State private var edited = false
    var body: some View {
        Form {
            Section {
                TextField("Username", text: Binding(get: { username }, set: { username = $0; edited = true }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("bound.username-editor")
                Button("Save username") {
                    Task { await profile.rename(username); if profile.status.hasPrefix("Username updated") { username = profile.username ?? username; edited = false } }
                }.disabled(profile.busy || !BoundSocialAPI.validUsername(username.trimmingCharacters(in: .whitespacesAndNewlines)) || username == profile.username)
                    .accessibilityIdentifier("bound.username-save")
            }
            if !profile.status.isEmpty { Text(profile.status).font(.caption).accessibilityIdentifier("bound.username-status") }
        }.navigationTitle("Username")
            .task { await profile.refresh(); if !edited { username = profile.username ?? "" } }
            .onChange(of: profile.username) { _, value in if !edited { username = value ?? "" } }
            .onChange(of: phase) { _, value in if value == .active { Task { await profile.refresh() } } }
    }
}

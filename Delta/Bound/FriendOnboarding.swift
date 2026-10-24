import SwiftUI
import UIKit
import Combine

struct FriendRoom: Decodable, Equatable, Identifiable, Sendable {
    let roomID: String
    let displayName: String
    var id: String { roomID }
    var valid: Bool {
        UUID(uuidString: roomID) != nil && !displayName.isEmpty && displayName.count <= 40 &&
        !displayName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
struct FriendResponse: Decodable, Sendable {
    let ok: Bool
    var code: String? = nil
    var room: FriendRoom? = nil
    var rooms: [FriendRoom]? = nil
    var blocks: [FriendBlock]? = nil
    var reportID: UUID? = nil
    var error: String? = nil
    var username: String? = nil
}

struct FriendBlock: Decodable, Equatable, Identifiable, Sendable {
    let blockID: UUID
    let displayName: String
    var id: UUID { blockID }
    var valid: Bool { !displayName.isEmpty && displayName.count <= 40 && !displayName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}

enum FriendReportReason: String, CaseIterable, Identifiable {
    case harassment, hate, sexual, violence, spam, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .harassment: return "Harassment"
        case .hate: return "Hate or discrimination"
        case .sexual: return "Sexual content"
        case .violence: return "Threats or graphic violence"
        case .spam: return "Spam or impersonation"
        case .other: return "Other"
        }
    }
}

@MainActor
final class FriendOnboarding: ObservableObject {
    @Published private(set) var signedIn = false
    @Published private(set) var busy = false
    @Published private(set) var message = "Sign in to add a friend."
    @Published private(set) var rooms: [FriendRoom] = []
    @Published private(set) var blocks: [FriendBlock] = []
    @Published private(set) var selected: FriendRoom?
    @Published private(set) var inviteCode: String?
    @Published private(set) var accountUsername: String?
    @Published private(set) var managesFlow = false
    private var permitsRTC = true
    private var ownerID: UUID?
    private var observation: (any SharingCancellation)?
    private var sharingObservation: AnyCancellable?
    private var isOpen = false
    private var multiplayerServiceActive = false
    private(set) var multiplayerPartnerRoomID: String?
    private var hasCurrentFriendList = false
    private var disconnectedRooms = Set<String>()
    private var lastProfileRefresh = Date.distantPast
    private let observeAccount: @MainActor (@escaping @MainActor () -> Void) -> any SharingCancellation
    private var reusedSession: (() -> AppCloudSession?)?
    private weak var sharing: FriendSharingSession?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var pendingRequestAction: String?
    private var refreshCompletions: [(Bool) -> Void] = []
    private var jiggleGeneration = UUID()
    private var jiggleTask: Task<Void, Never>?
    private let call: @MainActor (AppCloudSession, String, [String: String]) async throws -> FriendResponse
    private let sendJiggle: @MainActor (FriendRoom, AppCloudSession) async throws -> String

    init(call: @escaping @MainActor (AppCloudSession, String, [String: String]) async throws -> FriendResponse = { session, action, payload in
        let request: URLRequest
        if ["list", "create", "accept", "add"].contains(action) {
            let socialPayload: [String: String]
            switch action {
            case "accept": socialPayload = ["code": payload["code"] ?? ""]
            case "add": socialPayload = ["username": payload["username"] ?? ""]
            default: socialPayload = [:]
            }
            request = try session.friendSocialRequest(action: action, payload: socialPayload)
        } else {
            request = try session.friendOnboardingRequest(action: action, payload: payload)
        }
        let bytes = try await FriendSharingTokens.perform(request)
        let response = try JSONDecoder().decode(FriendResponse.self, from: bytes)
        return response
    }, sendJiggle: @escaping @MainActor (FriendRoom, AppCloudSession) async throws -> String = {
        try await BoundJiggleNotifications.send(to: $0, session: $1)
    }, observeAccount: @escaping @MainActor (@escaping @MainActor () -> Void) -> any SharingCancellation = {
        FriendSharingTimer(after: 1, repeating: true, action: $0)
    }) { self.call = call; self.sendJiggle = sendJiggle; self.observeAccount = observeAccount }

    deinit {
        task?.cancel()
        jiggleTask?.cancel()
        let observation = observation
        BoundMainActorDisposal.enqueue { observation?.cancel() }
    }
    func open(sharing: FriendSharingSession, existing: (() -> AppCloudSession?)?) {
        let wasOpen = isOpen
        isOpen = true
        self.sharing = sharing; reusedSession = existing
        if !permitsRTC {
            managesFlow = true
            sharing.configureAuthenticatedRoom(nil, identity: { nil })
        }
        ensureAccountObservation()
        synchronizeAccount()
        if !wasOpen && signedIn && !busy { refresh() }
    }
    func setMultiplayerServiceActive(_ requested: Bool, sharing: FriendSharingSession,
                                     existing: @escaping () -> AppCloudSession?, temporary: Bool = false) {
        multiplayerServiceActive = requested && BoundMultiplayerFeatures.isEnabled
        self.sharing = sharing; reusedSession = existing
        if multiplayerServiceActive {
            ensureAccountObservation()
            synchronizeAccount()
            synchronizeMultiplayerConnection()
        } else {
            // Sharing.background() already suspends the socket while retaining
            // its room and activity. Only a deliberate service shutdown revokes
            // the ROM's connection request.
            if !temporary || !BoundMultiplayerFeatures.isEnabled { sharing.setAutomaticMultiplayerConnection(false) }
            if !isOpen { observation?.cancel(); observation = nil; cancelPendingRequest() }
        }
    }
    /// Called with the run's persisted room or a friend selected in the ROM.
    /// A server-refreshed friend list and the current account authorize connection.
    func setMultiplayerPartner(roomID: String?, userInitiated: Bool = false) {
        guard roomID == nil || UUID(uuidString: roomID!) != nil else { return }
        if userInitiated, let roomID { disconnectedRooms.remove(roomID) }
        if multiplayerPartnerRoomID != roomID {
            sharing?.setAutomaticMultiplayerConnection(false)
            multiplayerPartnerRoomID = roomID
        }
        synchronizeMultiplayerConnection()
    }
    /// A cartridge choice is sufficient to start the authenticated service. It
    /// must not depend on Friends having opened or configured a transport first.
    @discardableResult
    func selectMultiplayerPartner(roomID: String, sharing: FriendSharingSession,
                                  existing: @escaping () -> AppCloudSession?) -> Bool {
        guard BoundMultiplayerFeatures.isEnabled, UUID(uuidString: roomID) != nil,
              let identity = existing(), (try? identity.credentials()) != nil else { return false }
        setMultiplayerServiceActive(true, sharing: sharing, existing: existing)
        setMultiplayerPartner(roomID: roomID, userInitiated: true)
        return true
    }
    private func ensureAccountObservation() {
        guard observation == nil else { return }
        observation = observeAccount { [weak self] in
            guard let self, self.isOpen || self.multiplayerServiceActive else { return }
            self.synchronizeAccount()
            self.synchronizeMultiplayerConnection()
        }
    }
    private func synchronizeMultiplayerConnection() {
        guard multiplayerServiceActive, BoundMultiplayerFeatures.isEnabled, permitsRTC,
              hasCurrentFriendList, let roomID = multiplayerPartnerRoomID, !disconnectedRooms.contains(roomID),
              let room = rooms.first(where: { $0.roomID == roomID }), currentIdentity() != nil else { return }
        if selected?.roomID != roomID || sharing?.configuredRoomID != roomID {
            cancelPendingJiggle(); selected = room
            sharing?.configureAuthenticatedRoom(roomID, identity: { [weak self] in self?.sharingIdentity() })
        }
        sharing?.setAutomaticMultiplayerConnection(true)
    }
    /// Reads only the current account owner; no password grant, refresh or network
    /// work occurs here. Login may finish after Saves is opened or dismissed.
    func synchronizeAccount() {
        guard isOpen || multiplayerServiceActive else { return }
        let candidate = reusedSession?()
        let current = candidate.flatMap { (try? $0.credentials()) == nil ? nil : $0 }
        guard candidate?.owner != ownerID else {
            // A saved session can expire while its account is retrying refresh
            // offline. Preserve the selected owner/room; API calls still require
            // currentIdentity(), which rejects expired credentials.
            // Names come from account profiles. Refresh an open Friends list so
            // a rename made on another device appears without reconnecting.
            if current != nil, !busy,
               Date().timeIntervalSince(lastProfileRefresh) >= 30 { refresh() }
            return
        }
        let hadAccount = ownerID != nil
        cancelPendingRequest(); cancelPendingJiggle(); ownerID = nil; signedIn = false; rooms = []; blocks = []; selected = nil; accountUsername = nil
        hasCurrentFriendList = false; multiplayerPartnerRoomID = nil; disconnectedRooms.removeAll()
        if hadAccount || current != nil || managesFlow {
            managesFlow = true
            sharing?.configureAuthenticatedRoom(nil, identity: { [weak self] in self?.sharingIdentity() })
        }
        guard let current else { message = "Sign in above to add a friend."; return }
        ownerID = current.owner; signedIn = true; message = "Choose a friend or exchange an invite."
        refresh()
    }
    func close() {
        isOpen = false
        if !multiplayerServiceActive {
            observation?.cancel(); observation = nil
            cancelPendingRequest()
        }
        // Keep the selected room, live identity provider and tap notification:
        // closing Friends must not terminate sharing or its pending Jiggle.
    }
    private func cancelPendingRequest() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; inviteCode = nil
        pendingRequestAction = nil
        finishRefresh(false)
    }
    private func cancelPendingJiggle() {
        jiggleGeneration = UUID(); jiggleTask?.cancel(); jiggleTask = nil
        sharingObservation?.cancel(); sharingObservation = nil
    }
    private func sharingIdentity() -> AppCloudSession? {
        // Keep account ownership available while an expired token is refreshing.
        // Request construction still rejects invalid credentials; restoration can
        // then retry after the account's foreground refresh succeeds.
        guard permitsRTC, let ownerID, let identity = reusedSession?(), identity.owner == ownerID else { return nil }
        return identity
    }
    static func mockNamespace(arguments: [String]) -> UUID? {
        #if DEBUG && targetEnvironment(simulator)
        guard arguments.contains("--friend-onboarding-mock"), let index = arguments.firstIndex(of: "--preservation-test"),
              arguments.indices.contains(index + 1) else { return nil }
        return UUID(uuidString: arguments[index + 1])
        #else
        return nil
        #endif
    }
    static func forUI(arguments: [String] = ProcessInfo.processInfo.arguments) -> FriendOnboarding {
        #if DEBUG && targetEnvironment(simulator)
        guard let namespace = mockNamespace(arguments: arguments) else { return FriendOnboarding() }
        let fixture = FriendOnboardingFixture(namespace: namespace)
        let model = FriendOnboarding(call: { _, action, payload in try fixture.call(action, payload: payload) })
        model.permitsRTC = false // Every mock action is inert, including Start sharing.
        return model
        #else
        return FriendOnboarding()
        #endif
    }
    func currentIdentity() -> AppCloudSession? {
        guard let ownerID, let current = reusedSession?(), current.owner == ownerID,
              (try? current.credentials()) != nil else { return nil }
        return current
    }
    func signOut() {
        cancelPendingRequest(); cancelPendingJiggle(); ownerID = nil; signedIn = false; managesFlow = true
        rooms = []; blocks = []; selected = nil; accountUsername = nil; message = "Sign in above to add a friend."
        hasCurrentFriendList = false; multiplayerPartnerRoomID = nil; disconnectedRooms.removeAll()
        sharing?.configureAuthenticatedRoom(nil, identity: { nil })
    }
    func select(_ room: FriendRoom, startSharing: Bool = false) {
        guard !busy, room.valid, rooms.contains(room), let identity = currentIdentity() else { return }
        // An active ROM run owns its authenticated partner. A different video
        // friend cannot silently replace the linked gameplay connection.
        guard multiplayerPartnerRoomID == nil || !multiplayerServiceActive || multiplayerPartnerRoomID == room.roomID else {
            message = "End or suspend the linked run before switching friends."
            return
        }
        disconnectedRooms.remove(room.roomID)
        let startsImmediately = startSharing
        // Repeated taps on the current friend must not interrupt a live session.
        if startsImmediately, selected?.roomID == room.roomID, sharing?.active == true {
            sharing?.start()
            message = ""
            return
        }
        cancelPendingJiggle()
        selected = room
        sharing?.configureAuthenticatedRoom(room.roomID, identity: { [weak self] in self?.sharingIdentity() })
        message = startsImmediately ? "" : "Ready to share with \(room.displayName)."
        if startsImmediately && permitsRTC, let sharing {
            sharing.start()
            if sharing.active { notifyFriendOfSharing(room, identity: identity) }
        }
    }
    /// An explicit Stop clears the row and transport and blocks background room
    /// restoration until the user selects this friend again. Linked-run recovery
    /// continues to use the transport's existing safe disconnect path.
    func disconnect() {
        if let roomID = selected?.roomID { disconnectedRooms.insert(roomID) }
        if let roomID = multiplayerPartnerRoomID { disconnectedRooms.insert(roomID) }
        cancelPendingJiggle()
        selected = nil
        sharing?.configureAuthenticatedRoom(nil, disconnectReason: .manual, identity: { [weak self] in self?.sharingIdentity() })
        message = ""
    }
    func refresh(completion: ((Bool) -> Void)? = nil) {
        // The ROM can join an initial/profile refresh already in flight. Its
        // acknowledgement must describe the fetched list, not cached rows.
        if busy {
            if pendingRequestAction == "list", let completion { refreshCompletions.append(completion) }
            else { completion?(false) }
            return
        }
        if let completion { refreshCompletions.append(completion) }
        lastProfileRefresh = Date()
        request("list", payload: [:])
    }
    private func finishRefresh(_ succeeded: Bool) {
        let completions = refreshCompletions
        refreshCompletions.removeAll()
        completions.forEach { $0(succeeded) }
    }
    func create(name: String) { request("create", payload: ["displayName": name.trimmingCharacters(in: .whitespacesAndNewlines)]) }
    func accept(code: String, name: String) { request("accept", payload: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), "displayName": name.trimmingCharacters(in: .whitespacesAndNewlines)]) }
    func add(username: String) {
        guard !busy else { return }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BoundSocialAPI.validUsername(username) else { message = "Enter your friend's username."; return }
        request("add", payload: ["username": username])
    }
    func remove(_ room: FriendRoom) {
        guard !busy, rooms.contains(where: { $0.roomID == room.roomID }) else { return }
        if selected?.roomID == room.roomID { cancelPendingJiggle(); selected = nil; sharing?.configureAuthenticatedRoom(nil, identity: { [weak self] in self?.sharingIdentity() }) }
        request("remove", payload: ["roomID": room.roomID])
    }
    func block(_ room: FriendRoom) {
        guard !busy, rooms.contains(room) else { return }
        if selected?.roomID == room.roomID {
            cancelPendingJiggle()
            selected = nil
            sharing?.configureAuthenticatedRoom(nil, identity: { [weak self] in self?.sharingIdentity() })
        }
        request("block", payload: ["roomID": room.roomID])
    }
    func unblock(_ block: FriendBlock) {
        guard blocks.contains(block) else { return }
        request("unblock", payload: ["blockID": block.blockID.uuidString.lowercased()])
    }
    func report(_ room: FriendRoom, reason: FriendReportReason) {
        guard rooms.contains(room) else { return }
        request("report", payload: ["roomID": room.roomID, "reason": reason.rawValue])
    }
    private func notifyFriendOfSharing(_ room: FriendRoom, identity: AppCloudSession) {
        let run = jiggleGeneration
        let sendJiggle = sendJiggle
        if let sharing {
            sharingObservation?.cancel()
            sharingObservation = sharing.$active.dropFirst().sink { [weak self] active in
                guard !active, let self, self.jiggleGeneration == run else { return }
                self.cancelPendingJiggle()
            }
        }
        // Only an explicit friend tap sends this notification. Sharing starts
        // immediately; a slow or failed notification never blocks its controls.
        jiggleTask = Task { [weak self] in
            defer {
                if self?.jiggleGeneration == run {
                    self?.jiggleTask = nil
                    self?.sharingObservation?.cancel(); self?.sharingObservation = nil
                }
            }
            guard !Task.isCancelled,
                  self?.jiggleGeneration == run, self?.selected?.roomID == room.roomID,
                  self?.sharing?.active == true,
                  identity.isSameSession(as: self?.currentIdentity()) else { return }
            let result: String
            do {
                result = try await sendJiggle(room, identity)
            } catch {
                result = (error as? BoundSocialError)?.localizedDescription ?? "Couldn't notify your friend."
            }
            guard let self, !Task.isCancelled, self.jiggleGeneration == run,
                  identity.isSameSession(as: self.currentIdentity()),
                  self.selected?.roomID == room.roomID, self.sharing?.active == true,
                  !self.busy else { return }
            self.message = result
        }
    }
    private func request(_ action: String, payload: [String: String]) {
        guard !busy else { return }
        guard let identity = currentIdentity() else {
            if sharingIdentity() == nil { signOut() }
            else { message = "Reconnecting…"; finishRefresh(false) }
            return
        }
        busy = true; pendingRequestAction = action; message = "Updating friends…"
        let run = generation; let call = call
        task = Task { [weak self] in
            do {
                let response = try await call(identity, action, payload)
                try Task.checkCancellation()
                guard let self, self.generation == run else { return }
                guard self.currentIdentity()?.owner == identity.owner else {
                    self.busy = false; self.task = nil; self.pendingRequestAction = nil
                    if self.sharingIdentity()?.owner != identity.owner { self.signOut() }
                    else { self.message = "Reconnecting…"; self.finishRefresh(false) }
                    return
                }
                guard response.ok else {
                    self.busy = false; self.task = nil; self.pendingRequestAction = nil
                    switch response.error {
                    case "rate_limited": self.message = "Too many attempts. Try again later."
                    case "block_limit": self.message = "Your block list is full. Remove a block before adding another."
                    case "name_not_allowed": self.message = "Choose a different display name."
                    case "friend_not_found": self.message = "No friend found with that username."
                    case "cannot_add_self": self.message = "Enter a friend's username, not your own."
                    case "friend_limit": self.message = "One of you has reached the 20-friend limit."
                    default: self.message = "Could not update friends. Try again."
                    }
                    if action == "list" { self.finishRefresh(false) }
                    return
                }
                if let username = response.username {
                    guard BoundSocialAPI.validUsername(username) else { throw FriendSharingTokenError.unavailable }
                    self.accountUsername = username
                }
                if action == "list" {
                    guard let rooms = response.rooms, rooms.count <= 20, rooms.allSatisfy(\.valid), Set(rooms.map(\.roomID)).count == rooms.count else { throw FriendSharingTokenError.unavailable }
                    if let blocks = response.blocks {
                        guard blocks.count <= 100, blocks.allSatisfy(\.valid), Set(blocks.map(\.blockID)).count == blocks.count else { throw FriendSharingTokenError.unavailable }
                    }
                    self.rooms = rooms
                    self.hasCurrentFriendList = true
                    if let blocks = response.blocks { self.blocks = blocks }
                    if let selected = self.selected, let refreshed = rooms.first(where: { $0.roomID == selected.roomID }) {
                        self.selected = refreshed
                    }
                    if let selected = self.selected, !rooms.contains(where: { $0.roomID == selected.roomID }) {
                        self.cancelPendingJiggle()
                        self.selected = nil; self.sharing?.configureAuthenticatedRoom(nil, identity: { [weak self] in self?.sharingIdentity() })
                    }
                } else if action == "create" {
                    guard let code = response.code, code.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil else { throw FriendSharingTokenError.unavailable }
                    self.inviteCode = code
                } else if action == "accept" || action == "add" {
                    guard let room = response.room, room.valid else { throw FriendSharingTokenError.unavailable }
                    self.rooms.removeAll { $0.roomID == room.roomID }; self.rooms.append(room); self.busy = false; self.select(room)
                } else if action == "remove" || action == "block" {
                    self.rooms.removeAll { $0.roomID == payload["roomID"] }
                    if self.selected?.roomID == payload["roomID"] {
                        self.selected = nil
                        self.sharing?.configureAuthenticatedRoom(nil, identity: { [weak self] in self?.sharingIdentity() })
                    }
                }
                if action == "block" || action == "unblock" {
                    guard let blocks = response.blocks, blocks.count <= 100, blocks.allSatisfy(\.valid), Set(blocks.map(\.blockID)).count == blocks.count else { throw FriendSharingTokenError.unavailable }
                    self.blocks = blocks
                }
                if action == "report" { guard response.reportID != nil else { throw FriendSharingTokenError.unavailable } }
                self.busy = false; self.task = nil; self.pendingRequestAction = nil
                self.message = action == "report" ? "Report sent." : action == "add" ? "Friend added." : ""
                self.synchronizeMultiplayerConnection()
                if action == "list" { self.finishRefresh(true) }
            } catch {
                guard let self, self.generation == run else { return }
                self.busy = false; self.task = nil; self.pendingRequestAction = nil
                self.message = "Could not update friends. Check the code or try again."
                if action == "list" { self.finishRefresh(false) }
            }
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
private final class FriendOnboardingFixture {
    let namespace: UUID
    var rooms: [FriendRoom] = []
    init(namespace: UUID) { self.namespace = namespace }
    func call(_ action: String, payload: [String: String]) throws -> FriendResponse {
        switch action {
        case "list": return .init(ok: true, rooms: rooms, username: "Fixture Player")
        case "create": return .init(ok: true, code: "0123456789ABCDEF", username: "Fixture Player")
        case "accept":
            guard payload["code"] == "0123456789ABCDEF" else { throw FriendSharingTokenError.unavailable }
            let room = FriendRoom(roomID: namespace.uuidString.lowercased(), displayName: "Fixture Friend")
            rooms = [room]; return .init(ok: true, room: room, username: "Fixture Player")
        case "remove": rooms = []; return .init(ok: true)
        default: throw FriendSharingTokenError.unavailable
        }
    }
}

#endif

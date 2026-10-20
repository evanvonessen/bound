import SwiftUI
import UIKit

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
    @Published private(set) var managesFlow = false
    private var permitsRTC = true
    private var ownerID: UUID?
    private var observation: (any SharingCancellation)?
    private var isOpen = false
    private let observeAccount: @MainActor (@escaping @MainActor () -> Void) -> any SharingCancellation
    private var reusedSession: (() -> AppCloudSession?)?
    private weak var sharing: FriendSharingSession?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let call: @MainActor (AppCloudSession, String, [String: String]) async throws -> FriendResponse

    init(call: @escaping @MainActor (AppCloudSession, String, [String: String]) async throws -> FriendResponse = { session, action, payload in
        let bytes = try await FriendSharingTokens.perform(try session.friendOnboardingRequest(action: action, payload: payload))
        let response = try JSONDecoder().decode(FriendResponse.self, from: bytes)
        return response
    }, observeAccount: @escaping @MainActor (@escaping @MainActor () -> Void) -> any SharingCancellation = {
        FriendSharingTimer(after: 1, repeating: true, action: $0)
    }) { self.call = call; self.observeAccount = observeAccount }

    deinit {
        task?.cancel()
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
        if observation == nil {
            observation = observeAccount { [weak self] in
                guard let self, self.isOpen else { return }
                self.synchronizeAccount()
            }
        }
        synchronizeAccount()
        if !wasOpen && signedIn && !busy { refresh() }
    }
    /// Reads only the current account owner; no password grant, refresh or network
    /// work occurs here. Login may finish after Saves is opened or dismissed.
    func synchronizeAccount() {
        guard isOpen else { return }
        let candidate = reusedSession?()
        let current = candidate.flatMap { (try? $0.credentials()) == nil ? nil : $0 }
        guard current?.owner != ownerID else { return }
        let hadAccount = ownerID != nil
        cancelPendingRequest(); ownerID = nil; signedIn = false; rooms = []; blocks = []; selected = nil
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
        observation?.cancel(); observation = nil
        cancelPendingRequest()
        // Keep the selected room and live identity provider: closing Friends
        // must not terminate an active sharing session.
    }
    private func cancelPendingRequest() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; inviteCode = nil
    }
    private func sharingIdentity() -> AppCloudSession? { permitsRTC ? currentIdentity() : nil }
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
        cancelPendingRequest(); ownerID = nil; signedIn = false; managesFlow = true
        rooms = []; blocks = []; selected = nil; message = "Sign in above to add a friend."
        sharing?.configureAuthenticatedRoom(nil, identity: { nil })
    }
    func select(_ room: FriendRoom) {
        guard !busy, room.valid, rooms.contains(room), currentIdentity() != nil else { return }
        selected = room
        sharing?.configureAuthenticatedRoom(room.roomID, identity: { [weak self] in self?.sharingIdentity() })
        message = "Ready to share with \(room.displayName)."
    }
    func refresh() { request("list", payload: [:]) }
    func create(name: String) { request("create", payload: ["displayName": name.trimmingCharacters(in: .whitespacesAndNewlines)]) }
    func accept(code: String, name: String) { request("accept", payload: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), "displayName": name.trimmingCharacters(in: .whitespacesAndNewlines)]) }
    func remove(_ room: FriendRoom) {
        guard !busy else { return }
        if selected?.roomID == room.roomID { selected = nil; sharing?.configureAuthenticatedRoom(nil, identity: { [weak self] in self?.sharingIdentity() }) }
        request("remove", payload: ["roomID": room.roomID])
    }
    func block(_ room: FriendRoom) {
        guard !busy, rooms.contains(room) else { return }
        if selected?.roomID == room.roomID {
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
    private func request(_ action: String, payload: [String: String]) {
        guard !busy else { return }
        guard let identity = currentIdentity() else { signOut(); return }
        busy = true; message = "Updating friends…"
        let run = generation; let call = call
        task = Task { [weak self] in
            do {
                let response = try await call(identity, action, payload)
                try Task.checkCancellation()
                guard let self, self.generation == run else { return }
                guard self.currentIdentity()?.owner == identity.owner else { self.signOut(); return }
                guard response.ok else {
                    self.busy = false; self.task = nil
                    switch response.error {
                    case "rate_limited": self.message = "Too many attempts. Try again later."
                    case "block_limit": self.message = "Your block list is full. Remove a block before adding another."
                    case "name_not_allowed": self.message = "Choose a different display name."
                    default: self.message = "Could not update friends. Try again."
                    }
                    return
                }
                if action == "list" {
                    guard let rooms = response.rooms, rooms.count <= 20, rooms.allSatisfy(\.valid), Set(rooms.map(\.roomID)).count == rooms.count else { throw FriendSharingTokenError.unavailable }
                    self.rooms = rooms
                    if let blocks = response.blocks {
                        guard blocks.count <= 100, blocks.allSatisfy(\.valid), Set(blocks.map(\.blockID)).count == blocks.count else { throw FriendSharingTokenError.unavailable }
                        self.blocks = blocks
                    }
                    if let selected = self.selected, !rooms.contains(where: { $0.roomID == selected.roomID }) {
                        self.selected = nil; self.sharing?.configureAuthenticatedRoom(nil, identity: { [weak self] in self?.sharingIdentity() })
                    }
                } else if action == "create" {
                    guard let code = response.code, code.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil else { throw FriendSharingTokenError.unavailable }
                    self.inviteCode = code
                } else if action == "accept" {
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
                self.busy = false; self.task = nil; self.message = action == "report" ? "Report sent." : ""
            } catch {
                guard let self, self.generation == run else { return }
                self.busy = false; self.task = nil; self.message = "Could not update friends. Check the code or try again."
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
        case "list": return .init(ok: true, rooms: rooms)
        case "create": return .init(ok: true, code: "0123456789ABCDEF")
        case "accept":
            guard payload["code"] == "0123456789ABCDEF" else { throw FriendSharingTokenError.unavailable }
            let room = FriendRoom(roomID: namespace.uuidString.lowercased(), displayName: "Fixture Friend")
            rooms = [room]; return .init(ok: true, room: room)
        case "remove": rooms = []; return .init(ok: true)
        default: throw FriendSharingTokenError.unavailable
        }
    }
}

#endif

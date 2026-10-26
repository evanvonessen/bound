import XCTest
@testable import Delta

@MainActor private final class LocalDebugAccountStorage: BoundSessionStorage {
    var bytes: Data?
    func read() -> Data? { bytes }
    func write(_ data: Data) { bytes = data }
    func remove() { bytes = nil }
}

/// Explicitly opted-in integration against the dedicated task gateway. This
/// never invents confirmation claims or places synthetic native saves in a run.
@MainActor final class LocalDebugBackendTests: XCTestCase {
    private struct Inputs: Decodable {
        struct Account: Decodable { let role: String; let ownerID: UUID; let email: String; let password: String }
        let endpoint: String
        let roomID: UUID
        let accounts: [Account]
    }
    func testNativeSignInJoinsScopedSessionAndLogoutInvalidatesHolders() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["BOUND_LOCAL_DEBUG_ACCOUNT_TEST"] == "1", "Dedicated local account test only")
        guard environment["BOUND_QA_LOCAL_BACKEND"] == "1",
              environment["SIMULATOR_UDID"] == "92586556-6715-4BA0-98FC-5C1FF776F0A9" else { XCTFail("Wrong local QA authority"); return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DEBUGLocalQA/synthetic-login.json")
        let data = try Data(contentsOf: url)
        guard data.count <= 8192 else { XCTFail("Invalid local inputs"); return }
        let inputs = try JSONDecoder().decode(Inputs.self, from: data)
        let backend = try BoundBackendConfiguration.current()
        guard backend.kind == .selfhost, backend.origin == "https://127.0.0.1:58552", backend.origin == inputs.endpoint,
              inputs.accounts.count == 2, Set(inputs.accounts.map(\.ownerID)).count == 2,
              let controllerInput = inputs.accounts.first(where: { $0.role == "controller" }),
              let buddyInput = inputs.accounts.first(where: { $0.role == "buddy" }) else { XCTFail("Invalid local authority"); return }
        func account() -> BoundFriendAccount {
            BoundFriendAccount(storage: LocalDebugAccountStorage(), deletionStorage: LocalDebugAccountStorage(), automaticRefresh: false,
                transport: { request in
                    guard request.url?.scheme == "https", request.url?.host == "127.0.0.1", request.url?.port == 58552 else {
                        throw BoundDebugFailure.rejected
                    }
                    return try await BoundAuthTransport.perform(request)
                })
        }
        let controller = account(), buddy = account()
        defer { controller.signOut(); buddy.signOut() }
        await controller.signIn(email: controllerInput.email, password: controllerInput.password)
        await buddy.signIn(email: buddyInput.email, password: buddyInput.password)
        guard let owner = controller.session, let peer = buddy.session else { XCTFail("Native local sign-in failed"); return }
        XCTAssertEqual(owner.owner, controllerInput.ownerID); XCTAssertEqual(peer.owner, buddyInput.ownerID)
        let service = BoundDebugService(), id = UUID()
        let created = try await service.request(["action": .string("create"), "sessionID": .string(id.uuidString.lowercased()),
            "roomID": .string(inputs.roomID.uuidString.lowercased())], session: owner)
        let session = try XCTUnwrap(created["session"]).decode(BoundDebugServerSession.self)
        XCTAssertEqual(session.sessionID, id); XCTAssertEqual(session.controllerID, owner.owner)
        XCTAssertEqual(Set(session.owners), Set([owner.owner, peer.owner]))
        let joined = try await service.request(["action": .string("join"), "sessionID": .string(id.uuidString.lowercased()),
            "membershipEpoch": .number(Double(session.membershipEpoch))], session: peer)
        let active = try XCTUnwrap(joined["session"]).decode(BoundDebugServerSession.self)
        XCTAssertEqual(active.status, .active); XCTAssertEqual(Set(active.joined), Set(active.owners))
        let resumed = try await service.request(["action": .string("resume"), "sessionID": .string(id.uuidString.lowercased())], session: owner)
        guard let capability = resumed["capability"]?.string else { XCTFail("Missing scoped capability"); return }
        let revoked = try await service.request(["action": .string("revoke"), "sessionID": .string(id.uuidString.lowercased()),
            "membershipEpoch": .number(Double(active.membershipEpoch)), "capability": .string(capability)], session: owner)
        XCTAssertEqual(try XCTUnwrap(revoked["session"]).decode(BoundDebugServerSession.self).status, .revoked)
        controller.signOut()
        XCTAssertNil(controller.session)
        XCTAssertThrowsError(try owner.credentials())
        XCTAssertNoThrow(try peer.credentials(), "One account's local logout cannot invalidate the other owner")
        do {
            _ = try await service.request(["action": .string("list")], session: owner)
            XCTFail("A signed-out holder must not reach the gateway")
        } catch { }
    }
}

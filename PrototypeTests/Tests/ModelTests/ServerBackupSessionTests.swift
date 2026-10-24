import XCTest
@testable import Models

final class ServerBackupSessionTests: XCTestCase {
    private func session(owner: UUID, backend: BoundBackendConfiguration) throws -> AppCloudSession {
        let claim = backend.kind == .selfhost ? "uid" : "sub"
        let bytes = try JSONSerialization.data(withJSONObject: [claim: owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let payload = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture-public-key", token: "fixture." + payload + ".signature", backend: backend)
    }
    private var selfhost: BoundBackendConfiguration {
        get throws { try .resolve(info: ["BoundBackendKind": "selfhost", "BoundBackendURL": "https://accounts.example.invalid"]) }
    }
    func testBackupRequestUsesOnlyBoundSelfhostAuthorityAndBearer() throws {
        let value = try session(owner: UUID(), backend: selfhost)
        let request = try value.serverBackupRequest(path: "/backups/v1/saves/game_1", method: "PUT", body: Data([1]),
                                                     headers: ["Authorization": "untrusted", "Content-Type": "application/zip"])
        XCTAssertEqual(request.url?.absoluteString, "https://accounts.example.invalid/backups/v1/saves/game_1")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer fixture.") == true)
        XCTAssertNil(request.value(forHTTPHeaderField: "apikey"))
        XCTAssertEqual(request.httpBody, Data([1]))
    }
    func testBackupRequestRejectsLegacyBackendAndPathEscapes() throws {
        let legacy = try BoundBackendConfiguration.resolve(info: [:])
        XCTAssertThrowsError(try session(owner: UUID(), backend: legacy).serverBackupRequest(path: "/backups/v1/status"))
        let value = try session(owner: UUID(), backend: selfhost)
        for path in ["/auth/v1/user", "https://other.invalid/backups/v1/status", "/backups/v1/saves/../user",
                     "/backups/v1/saves/id?key=1", "/backups/v1/saves/%2e%2e", "/backups/v1/saves/"] {
            XCTAssertThrowsError(try value.serverBackupRequest(path: path), path)
        }
    }
    func testReSignInToSameAccountStillInvalidatesOldOperationIdentity() throws {
        let owner = UUID(), backend = try selfhost
        let first = try session(owner: owner, backend: backend), second = try session(owner: owner, backend: backend)
        XCTAssertTrue(first.isSameSession(as: first))
        XCTAssertFalse(first.isSameSession(as: second))
        XCTAssertFalse(first.isSameSession(as: nil))
    }
}

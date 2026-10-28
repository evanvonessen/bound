import XCTest
@testable import Models

final class ROMDistributionRequestTests: XCTestCase {
    private func session(kind: String = "selfhost") throws -> AppCloudSession {
        let owner = UUID()
        let backend = try BoundBackendConfiguration.resolve(info: kind == "selfhost" ?
            ["BoundBackendKind": kind, "BoundBackendURL": "https://bound.example.com"] : ["BoundBackendKind": "legacy"])
        let claims: [String: Any] = [kind == "selfhost" ? "uid" : "sub": owner.uuidString.lowercased(),
                                    "exp": Date().timeIntervalSince1970 + 3600]
        let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try .init(owner: owner, key: "fixture-key", token: "fixture." + encoded + ".fixture", backend: backend)
    }
    func testEveryROMEndpointUsesInvalidatableBearerOnConfiguredOrigin() throws {
        let identity = try session()
        for resource in ["access", "latest", "download"] {
            let request = try identity.romUpdateRequest(resource: resource, build: 500, sha256: String(repeating: "a", count: 64))
            XCTAssertEqual(request.url?.host, "bound.example.com")
            XCTAssertEqual(request.url?.path, "/rom-updates/" + resource)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            XCTAssertNil(request.value(forHTTPHeaderField: "apikey"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        }
        let download = try identity.romUpdateRequest(resource: "download", build: 501, sha256: String(repeating: "b", count: 64))
        XCTAssertEqual(URLComponents(url: download.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "build", value: "501"), URLQueryItem(name: "sha256", value: String(repeating: "b", count: 64))])
    }
    func testLegacyAuthorityAndUnrecognizedPathsCannotServeROMs() throws {
        let legacy = try session(kind: "legacy")
        XCTAssertThrowsError(try legacy.romUpdateRequest(resource: "access"))
        let identity = try session()
        for resource in ["../files", "https://other.example/ROM", "latest?approved=true", ""] {
            XCTAssertThrowsError(try identity.romUpdateRequest(resource: resource))
        }
    }
    func testMalformedOrUnboundDownloadCannotBeRequested() throws {
        let identity = try session()
        XCTAssertThrowsError(try identity.romUpdateRequest(resource: "download"))
        XCTAssertThrowsError(try identity.romUpdateRequest(resource: "download", build: 499, sha256: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try identity.romUpdateRequest(resource: "download", build: 500, sha256: String(repeating: "A", count: 64)))
        XCTAssertThrowsError(try identity.romUpdateRequest(resource: "download", build: 500, sha256: "a&approved=true"))
    }
}

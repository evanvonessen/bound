import Foundation

struct FriendSharingTokenLease: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable, Decodable, Sendable {
    let roomID: String
    let ownerID: UUID
    let appID: String
    let channel: String
    let uid: UInt
    let remoteUID: UInt
    let token: String
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval

    var description: String { "FriendSharingTokenLease(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }

    var configuration: FriendSharingConfiguration {
        .init(appID: appID, channel: channel, uid: uid, remoteUID: remoteUID, token: token)
    }
    func valid(room: String, owner: UUID, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        roomID == room && ownerID == owner && configuration.isValid && issuedAt.isFinite && expiresAt.isFinite &&
        issuedAt <= now + 5 && issuedAt >= now - 30 && expiresAt > now + 30 && expiresAt - issuedAt <= 120 && expiresAt > issuedAt
    }
}

private final class FriendSharingNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum FriendSharingTokenError: LocalizedError, Equatable {
    case unavailable
    case rejected(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Multiplayer is unavailable. Please try again."
        case .invalidResponse:
            return "The multiplayer server returned an invalid response. Please try again."
        case .rejected(let status):
            switch status {
            case 401: return "Sign in again to use multiplayer."
            case 403: return "Your account cannot access this multiplayer session."
            case 429: return "Too many requests. Please try again shortly."
            case 500...599: return "The multiplayer server is temporarily unavailable. Please try again."
            default: return "The multiplayer server could not accept this request. Please try again later."
            }
        }
    }

    var retryable: Bool {
        switch self {
        case .unavailable: return true
        case .rejected(let status): return status == 408 || status == 429 || (500...599).contains(status)
        case .invalidResponse: return false
        }
    }
}

enum FriendSharingTokens {
    static func room(directory: URL = FriendSharingConfiguration.directory) -> String? {
        #if DEBUG && targetEnvironment(simulator)
        struct Config: Decodable { let roomID: String }
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("auth.json")), bytes.count <= 256,
              let value = try? JSONDecoder().decode(Config.self, from: bytes),
              value.roomID.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { return nil }
        return value.roomID
        #else
        return nil
        #endif
    }

    static func fetch(room: String, session: AppCloudSession) async throws -> FriendSharingTokenLease {
        let data = try await perform(try session.friendSharingRequest(roomID: room))
        let lease: FriendSharingTokenLease
        do { lease = try JSONDecoder().decode(FriendSharingTokenLease.self, from: data) }
        catch { throw FriendSharingTokenError.invalidResponse }
        guard lease.valid(room: room, owner: session.owner) else { throw FriendSharingTokenError.invalidResponse }
        return lease
    }

    static func validateResponse(_ response: URLResponse, for request: URLRequest) throws {
        guard let response = response as? HTTPURLResponse, response.url == request.url else {
            throw FriendSharingTokenError.invalidResponse
        }
        guard response.statusCode == 200 else { throw FriendSharingTokenError.rejected(statusCode: response.statusCode) }
    }

    static func perform(_ request: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 10
        let client = URLSession(configuration: config, delegate: FriendSharingNoRedirect(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        let (bytes, response) = try await client.bytes(for: request)
        try validateResponse(response, for: request)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16384 else { throw FriendSharingTokenError.invalidResponse }
            data.append(byte)
        }
        return data
    }
}

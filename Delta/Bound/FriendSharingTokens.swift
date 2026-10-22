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
    let lobbyID: UUID?
    let members: [FriendSharingLobbyMember]?
    let membershipRevision: String?

    init(roomID: String, ownerID: UUID, appID: String, channel: String, uid: UInt, remoteUID: UInt,
         token: String, issuedAt: TimeInterval, expiresAt: TimeInterval, lobbyID: UUID? = nil,
         members: [FriendSharingLobbyMember]? = nil, membershipRevision: String? = nil) {
        self.roomID = roomID; self.ownerID = ownerID; self.appID = appID; self.channel = channel
        self.uid = uid; self.remoteUID = remoteUID; self.token = token
        self.issuedAt = issuedAt; self.expiresAt = expiresAt
        self.lobbyID = lobbyID; self.members = members; self.membershipRevision = membershipRevision
    }

    var description: String { "FriendSharingTokenLease(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }

    var configuration: FriendSharingConfiguration {
        .init(appID: appID, channel: channel, uid: uid, remoteUID: remoteUID, token: token, lobbyID: lobbyID, members: members)
    }
    func valid(room: String, owner: UUID, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        roomID == room && ownerID == owner && configuration.isValid && (lobbyID == nil || configuration.lobbyRoute?.local?.ownerID == owner) && issuedAt.isFinite && expiresAt.isFinite &&
        issuedAt <= now + 5 && issuedAt >= now - 30 && expiresAt > now + 30 && expiresAt - issuedAt <= 120 && expiresAt > issuedAt
    }
}

private final class FriendSharingNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum FriendSharingTokenError: Error { case unavailable }

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
        let lease = try JSONDecoder().decode(FriendSharingTokenLease.self, from: data)
        guard lease.valid(room: room, owner: session.owner) else { throw FriendSharingTokenError.unavailable }
        return lease
    }

    static func fetchLobby(lobbyID: UUID, memberToken: UUID, session: AppCloudSession) async throws -> FriendSharingTokenLease {
        let data = try await perform(try session.lobbySharingRequest(lobbyID: lobbyID, memberToken: memberToken))
        let lease = try JSONDecoder().decode(FriendSharingTokenLease.self, from: data)
        guard lease.lobbyID == lobbyID, lease.valid(room: lobbyID.uuidString.lowercased(), owner: session.owner) else {
            throw FriendSharingTokenError.unavailable
        }
        return lease
    }

    static func perform(_ request: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 10
        let client = URLSession(configuration: config, delegate: FriendSharingNoRedirect(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        let (bytes, response) = try await client.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == request.url else { throw FriendSharingTokenError.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16384 else { throw FriendSharingTokenError.unavailable }
            data.append(byte)
        }
        return data
    }
}

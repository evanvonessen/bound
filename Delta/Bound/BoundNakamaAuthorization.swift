import Foundation

enum BoundNakamaAuthorization {
    struct SaveConfiguration: Decodable, Sendable {
        let httpEndpoint: URL
        let accessToken: String
        let ownerID: UUID
        let expiresAt: TimeInterval
        let saveTicket: String
        let partnerID: UUID?
        let roomID: UUID?
        var valid: Bool {
            httpEndpoint.scheme == "https" && httpEndpoint.host != nil && httpEndpoint.user == nil && httpEndpoint.password == nil
            && httpEndpoint.query == nil && httpEndpoint.fragment == nil && ["", "/"].contains(httpEndpoint.path)
            && !accessToken.isEmpty && accessToken.utf8.count <= 8192 && !saveTicket.isEmpty && saveTicket.utf8.count <= 8192
            && expiresAt > Date().timeIntervalSince1970 + 5 && (partnerID == nil) == (roomID == nil)
            && partnerID != ownerID
        }
    }
    static func fetchSaves(session: AppCloudSession, room: String? = nil) async throws -> SaveConfiguration {
        let bytes = try await FriendSharingTokens.perform(session.nakamaSaveSessionRequest(roomID: room))
        let value: SaveConfiguration
        do { value = try JSONDecoder().decode(SaveConfiguration.self, from: bytes) }
        catch { throw FriendSharingTokenError.invalidResponse }
        guard value.valid, value.ownerID == session.owner,
              room == nil || value.roomID == room.flatMap(UUID.init(uuidString:)) else { throw FriendSharingTokenError.invalidResponse }
        return value
    }
    static func fetch(room: String, session: AppCloudSession) async throws -> BoundNakamaConfiguration {
        guard let roomID = UUID(uuidString: room) else { throw FriendSharingTokenError.unavailable }
        let bytes = try await FriendSharingTokens.perform(session.nakamaSessionRequest(roomID: roomID.uuidString.lowercased()))
        let configuration: BoundNakamaConfiguration
        do { configuration = try JSONDecoder().decode(BoundNakamaConfiguration.self, from: bytes) }
        catch { throw FriendSharingTokenError.invalidResponse }
        guard configuration.isValid(room: roomID, owner: session.owner),
              configuration.expiresAt > Date().timeIntervalSince1970 + 15 else { throw FriendSharingTokenError.invalidResponse }
        return configuration
    }
}

/// Immutable server-selected DEBUG room scope. The logical friend room remains
/// the account/continuation identity; it is never used as the DEBUG socket room.
struct BoundDebugRealtimeScope: Equatable, Sendable {
    var sessionID: UUID
    var membershipEpoch: Int
    var generation: Int
    var manifestDigest: String
}

extension BoundNakamaAuthorization {
    static func debugConfiguration(_ value: BoundDebugJSON, scope: BoundDebugRealtimeScope,
                                   session: AppCloudSession, logicalRoom: UUID,
                                   now: TimeInterval = Date().timeIntervalSince1970) throws -> BoundNakamaConfiguration {
        guard value["protocol"]?.string == "bound-debug-room-v1",
              value["sessionID"]?.string.flatMap(UUID.init(uuidString:)) == scope.sessionID,
              value["membershipEpoch"]?.integer == scope.membershipEpoch,
              value["generation"]?.integer == scope.generation,
              value["activitiesAllowed"]?.boolean != nil,
              let endpoint = try session.debugRequest(body: Data("{}".utf8)).url else { throw BoundDebugFailure.invalidResponse }
        let result = try value.decode(BoundNakamaConfiguration.self)
        guard result.isValid(now: now), result.ownerID == session.owner,
              result.members.count == 2, result.roomID != logicalRoom,
              result.expiresAt > now + 1, result.expiresAt <= now + 35,
              result.endpoint.host?.lowercased() == endpoint.host?.lowercased(),
              (result.endpoint.port ?? 443) == (endpoint.port ?? 443) else { throw BoundDebugFailure.invalidResponse }
        return result
    }
}

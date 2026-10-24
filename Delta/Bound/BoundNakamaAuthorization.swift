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
        let value = try JSONDecoder().decode(SaveConfiguration.self, from: bytes)
        guard value.valid, value.ownerID == session.owner,
              room == nil || value.roomID == room.flatMap(UUID.init(uuidString:)) else { throw FriendSharingTokenError.unavailable }
        return value
    }
    static func fetch(room: String, session: AppCloudSession) async throws -> BoundNakamaConfiguration {
        guard let roomID = UUID(uuidString: room) else { throw FriendSharingTokenError.unavailable }
        let bytes = try await FriendSharingTokens.perform(session.nakamaSessionRequest(roomID: roomID.uuidString.lowercased()))
        let configuration = try JSONDecoder().decode(BoundNakamaConfiguration.self, from: bytes)
        guard configuration.isValid(room: roomID, owner: session.owner),
              configuration.expiresAt > Date().timeIntervalSince1970 + 15 else { throw FriendSharingTokenError.unavailable }
        return configuration
    }
}

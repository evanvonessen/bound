import Foundation

enum BoundNakamaAuthorization {
    static func fetch(room: String, session: AppCloudSession) async throws -> BoundNakamaConfiguration {
        guard let roomID = UUID(uuidString: room) else { throw FriendSharingTokenError.unavailable }
        let bytes = try await FriendSharingTokens.perform(session.nakamaSessionRequest(roomID: roomID.uuidString.lowercased()))
        let configuration = try JSONDecoder().decode(BoundNakamaConfiguration.self, from: bytes)
        guard configuration.isValid(room: roomID, owner: session.owner),
              configuration.expiresAt > Date().timeIntervalSince1970 + 15 else { throw FriendSharingTokenError.unavailable }
        return configuration
    }
}

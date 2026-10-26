import Foundation

enum BoundSDKRoomFailure: Error, Equatable, Sendable {
    case invalidConfiguration, connectionLost, joinRejected, invalidMessage, queueFull, expired
}

struct BoundSDKRoomMember: Equatable, Sendable {
    let ownerID: UUID
    let online: Bool
}

enum BoundSDKRoomEvent: Sendable {
    case joined
    case roster([BoundSDKRoomMember])
    case message(opcode: Int, data: Data, senderOwnerID: UUID)
    case retainedPresence(data: Data, ownerID: UUID, age: TimeInterval)
    case failed(BoundSDKRoomFailure)
}

/// Bounded room delivery mechanics. Provider authorization, configuration and
/// wire formats stay with the concrete transport; acceptance is not durability.
protocol BoundSDKRoomTransport<Configuration>: AnyObject, Sendable {
    associatedtype Configuration: Sendable
    func start(configuration: Configuration, event: @escaping @Sendable (BoundSDKRoomEvent) -> Void) throws
    func stop()
    @discardableResult func sendPresence(_ data: Data, targetOwnerID: UUID?) -> Bool
    @discardableResult func sendInteraction(_ data: Data, targetOwnerID: UUID?) -> Bool
    @discardableResult func sendBattle(_ data: Data, targetOwnerID: UUID) -> Bool
    @discardableResult func renewTicket(_ ticket: String, expiresAt: TimeInterval) -> Bool
}

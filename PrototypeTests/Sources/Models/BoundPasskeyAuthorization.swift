import Foundation

#if SWIFT_PACKAGE && !canImport(UIKit)
/// The standalone macOS model suite has no UIKit credential presentation.
/// Account tests can inject ceremonies; the default must remain unavailable.
/// Production passkey behavior is exercised by the hosted iOS test target.
@MainActor
enum BoundPasskeyAuthorization {
    static let isConfigured = false

    static func cancel() {}

    static func registration(options: Data) async throws -> Data {
        throw BoundFriendError.unavailable
    }

    static func authentication(options: Data) async throws -> Data {
        throw BoundFriendError.unavailable
    }
}
#endif

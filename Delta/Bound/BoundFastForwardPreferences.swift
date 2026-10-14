import Foundation

/// The last explicit fast-forward toggle, stored on this device per ROM.
final class BoundFastForwardPreferences {
    private let defaults: UserDefaults
    private static let prefix = "bound.fast-forward.enabled.v1."

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isEnabled(for gameID: String) -> Bool {
        defaults.bool(forKey: Self.prefix + gameID)
    }

    func setEnabled(_ enabled: Bool, for gameID: String) {
        defaults.set(enabled, forKey: Self.prefix + gameID)
    }
}

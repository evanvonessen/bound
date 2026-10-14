import Foundation

/// Opt-in access to features added after the build 13 baseline.
final class BoundExperimentalFeaturesPreferences {
    static let enabledKey = "bound.experimental-features.enabled.v1"
    static let didChangeNotification = Notification.Name("BoundExperimentalFeaturesDidChange")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            guard isEnabled != newValue else { return }
            defaults.set(newValue, forKey: Self.enabledKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

import Foundation

enum BoundTheme: String, CaseIterable, Sendable {
    case delta, minimal
    var title: String { self == .delta ? "Classic" : "Minimal" }
}

enum BoundScreenLayout: String, CaseIterable, Sendable {
    case delta, bound
    var title: String { self == .delta ? "Classic" : "Bound" }
}

struct BoundEmulationDetails: Equatable {
    let packageName: String
    let packageIdentifier: String
    let packageVersion: String?
    var packageRevision: String? {
        let revisions = ["GBADeltaCore": "869c34aeca9dd2b3fbd329092bb2743b0ae80c98", "GBCDeltaCore": "0871ccaad2bbd7cbd2de0ce06f9e26dc3d1bfdde", "GPGXDeltaCore": "4af2ff5d68cffd12121b63157ffb79267573bfcc", "MelonDSDeltaCore": "eb9b07ec17307cfd4986cb607f8ee5f6492d73cb", "N64DeltaCore": "56aefef59d947edbf2eb34b0a0288d751b006f30", "NESDeltaCore": "c88ef1e7c68ad723194d1b691362ac7d7394f968", "SNESDeltaCore": "35add3af36e6c42d777c554a277e098766a78995"]
        guard packageIdentifier == "com.rileytestut." + packageName else { return nil }
        return revisions[packageName]
    }
    var packageBuild: String { packageVersion.flatMap { $0.isEmpty ? nil : $0 } ?? packageRevision.map { "Pinned source " + String($0.prefix(12)) } ?? "Version not exposed by this package" }
    var engineName: String? { packageIdentifier == "com.rileytestut.GBADeltaCore" ? "VBA-M" : nil }
    var engineRevision: String? { engineName == nil ? nil : "453fa0decf179360926fb417725a794aa496d6e3" }
    static let deltaCoreRevision = "633dfa86967816315fe19b482511dab1ce517f28"
    static let deltaUpstreamRevision = "c1d3d068e019e6493eed45654569db3cc5beb86a"
}

/// Restore this exact feature set by changing one flag; stored preferences remain intact.
enum BoundFeatureVisibility {
    static let simplifiedSettings = true
}

/// Appearance and screen arrangement are independent preferences. Touch feedback uses Delta's existing settings.
final class BoundAppearancePreferences {
    static let defaultScreenLayout: BoundScreenLayout = .bound
    static let defaultTheme: BoundTheme = .delta
    static let screenLayoutKey = "bound.delta.screen-layout.v1"
    static let themeKey = "bound.delta.appearance.theme.v1"
    static let didChangeNotification = Notification.Name("BoundAppearanceDidChange")
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var effectiveTheme: BoundTheme { BoundFeatureVisibility.simplifiedSettings ? .delta : theme }
    var effectiveScreenLayout: BoundScreenLayout { BoundFeatureVisibility.simplifiedSettings ? .bound : screenLayout }
    var theme: BoundTheme {
        get { BoundTheme(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? Self.defaultTheme }
        set {
            guard defaults.string(forKey: Self.themeKey) != newValue.rawValue else { return }
            defaults.set(newValue.rawValue, forKey: Self.themeKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    var screenLayout: BoundScreenLayout {
        get { BoundScreenLayout(rawValue: defaults.string(forKey: Self.screenLayoutKey) ?? "") ?? Self.defaultScreenLayout }
        set {
            guard defaults.string(forKey: Self.screenLayoutKey) != newValue.rawValue else { return }
            defaults.set(newValue.rawValue, forKey: Self.screenLayoutKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    func resetScreenLayout() { screenLayout = Self.defaultScreenLayout }
    func reset() { theme = Self.defaultTheme }
}

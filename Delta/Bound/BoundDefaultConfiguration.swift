import Foundation

/// The reviewed configuration shipped with Bound, separate from user overrides.
enum BoundDefaultConfiguration {
    static let profileKey = "bound.defaults.exported-profile.v1"

    struct Binding: Decodable, Sendable {
        let identifier: String
        let type: String
        let isContinuous: Bool
    }

    struct ControllerMapping: Decodable, Sendable {
        let gameType: String
        let controllerType: String
        let bindings: [String: Binding]
    }

    private final class ResourceAnchor {}
    private struct MappingDocument: Decodable {
        let controllerMappings: [ControllerMapping]
    }

    private static let document: (preferences: [String: Any], mappings: [ControllerMapping]) = {
        do {
            guard let url = Bundle(for: ResourceAnchor.self).url(forResource: "BoundDefaultConfiguration-v1", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["format"] as? String == "bound-default-configuration",
                  json["schemaVersion"] as? Int == 1,
                  let preferences = json["preferences"] as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let decoded = try preferences.mapValues { value -> Any in
                guard let wrapper = value as? [String: Any], wrapper["storageType"] as? String == "data" else { return value }
                guard let encoded = wrapper["base64"] as? String, let bytes = Data(base64Encoded: encoded) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return bytes
            }
            return (decoded, try JSONDecoder().decode(MappingDocument.self, from: data).controllerMappings)
        } catch {
            assertionFailure("The bundled Bound default configuration could not be read: \(error)")
            return ([:], [])
        }
    }()

    static var preferences: [String: Any] { document.preferences }
    static var controllerMappings: [ControllerMapping] { document.mappings }

    /// A previous installation can have implicit layout fallbacks and pending
    /// migrations. Do not hide them behind the new profile's initialization keys.
    static func usesBundledLayouts(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: profileKey)
            || !defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("bound.landscape.") }
    }

    static func registrationPreferences(in defaults: UserDefaults) -> [String: Any] {
        var values = preferences
        if !usesBundledLayouts(in: defaults) {
            values = values.filter { !$0.key.hasPrefix("bound.landscape.") }
        }
        // Preserve legacy inheritance where a newer key has not yet been saved.
        if defaults.object(forKey: "bound.delta.pip.v1.button-type") != nil {
            values.removeValue(forKey: "bound.delta.pip.v2.button-type")
        }
        if defaults.object(forKey: "bound.delta.pip.v1.corner") != nil {
            for content in ["friend", "notes", "types", "bosses", "dex"] {
                values.removeValue(forKey: "bound.delta.pip.v1." + content + ".corner")
            }
        }
        return values
    }
}

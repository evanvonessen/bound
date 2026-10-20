import SwiftUI

/// Embed directly in a Form; no second source of truth or extra feedback generator.
struct BoundAppearanceSettings: View {
    @AppStorage(BoundAppearancePreferences.screenLayoutKey) private var screenLayoutRaw = BoundAppearancePreferences.defaultScreenLayout.rawValue
    @AppStorage(BoundAppearancePreferences.themeKey) private var themeRaw = BoundAppearancePreferences.defaultTheme.rawValue
    @AppStorage(Settings.Name.isButtonHapticFeedbackEnabled.rawValue) private var buttons = true
    @AppStorage(Settings.Name.isThumbstickHapticFeedbackEnabled.rawValue) private var sticks = true
    var emulationDetails: BoundEmulationDetails? = nil
    var body: some View {
        if !BoundFeatureVisibility.simplifiedSettings {
        Section("Screen layout") {
            Picker("Screen arrangement", selection: Binding(get: {
                BoundScreenLayout(rawValue: screenLayoutRaw) ?? BoundAppearancePreferences.defaultScreenLayout
            }, set: { BoundAppearancePreferences().screenLayout = $0 })) {
                ForEach(BoundScreenLayout.allCases, id: \.rawValue) { layout in Text(layout.title).tag(layout) }
            }.accessibilityIdentifier("bound.screen-layout")
            Text("Classic preserves the original screen geometry and shows the companion as PiP. Bound is the default and places the companion above gameplay in portrait and uses full-height gameplay with PiP in landscape.").font(.footnote).foregroundStyle(.secondary)
            Button("Reset screen layout to Bound") { BoundAppearancePreferences().resetScreenLayout() }.accessibilityIdentifier("bound.reset-screen-layout")
            Text("Changing or resetting screen layout keeps your button placements, theme, feedback and PiP preferences.").font(.footnote).foregroundStyle(.secondary)
        }
        Section("Appearance") {
            Picker("Theme", selection: Binding(get: {
                BoundTheme(rawValue: themeRaw) ?? BoundAppearancePreferences.defaultTheme
            }, set: { BoundAppearancePreferences().theme = $0 })) {
                ForEach(BoundTheme.allCases, id: \.rawValue) { theme in Text(theme.title).tag(theme) }
            }.accessibilityIdentifier("bound.theme")
            Text("Classic is the default and keeps the original controller style. Minimal uses simple controls and follows your device's light or dark appearance.").font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Button feedback", isOn: Binding(get: { buttons }, set: { Settings.isButtonHapticFeedbackEnabled = $0 }))
                .accessibilityIdentifier("bound.button-haptics")
            Toggle("Control stick feedback", isOn: Binding(get: { sticks }, set: { Settings.isThumbstickHapticFeedbackEnabled = $0 }))
                .accessibilityIdentifier("bound.stick-haptics")
        } header: { Text("Touch feedback") } footer: {
            Text("Uses native touch feedback. Both are on by default. Physical controllers do not trigger touch feedback; this device may not support vibration.")
        }
        }
        Section("About Bound") {
            LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")")
            Text("Bound is built on Delta. Delta and its emulator dependencies retain their original copyright and license notices.").font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("Emulation backend") {
                    if let details = emulationDetails {
                        LabeledContent("Active package", value: details.packageName).accessibilityIdentifier("bound.emulation-package")
                        #if DEBUG
                        LabeledContent("Package identifier", value: details.packageIdentifier).font(.caption)
                        LabeledContent("Package build", value: details.packageBuild).accessibilityIdentifier("bound.emulation-package-build")
                        #else
                        LabeledContent("Package version", value: details.packageVersion ?? "Source build").accessibilityIdentifier("bound.emulation-package-build")
                        #endif
                        if let engine = details.engineName {
                            LabeledContent("Emulator engine", value: engine).accessibilityIdentifier("bound.emulation-engine")
                            #if DEBUG
                            if let revision = details.engineRevision {
                                LabeledContent("Engine source", value: "Pinned " + String(revision.prefix(12))).accessibilityIdentifier("bound.emulation-engine-build")
                            }
                            #endif
                        }
                        #if DEBUG
                        Text("DeltaCore pinned source " + String(BoundEmulationDetails.deltaCoreRevision.prefix(12))).font(.caption)
                        Text("Delta upstream source " + String(BoundEmulationDetails.deltaUpstreamRevision.prefix(12))).font(.caption)
                        #endif
                    } else { Text("No emulation package is active.") }
            }
            NavigationLink("Source and licenses") { BoundSourceAndLicenses() }
                .accessibilityIdentifier("bound.source-and-licenses-link")
        }
        if !BoundFeatureVisibility.simplifiedSettings {
        Section {
            Button("Reset appearance and feedback to defaults") {
                BoundAppearancePreferences().reset()
                Settings.isButtonHapticFeedbackEnabled = true
                Settings.isThumbstickHapticFeedbackEnabled = true
            }.accessibilityIdentifier("bound.reset-appearance")
        }
        }
    }
}

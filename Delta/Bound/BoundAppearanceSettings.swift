import SwiftUI

/// Embed directly in a Form; no second source of truth or extra feedback generator.
struct BoundAppearanceSettings: View {
    @AppStorage(BoundAppearancePreferences.screenLayoutKey) private var screenLayoutRaw = BoundAppearancePreferences.defaultScreenLayout.rawValue
    @AppStorage(BoundAppearancePreferences.themeKey) private var themeRaw = BoundAppearancePreferences.defaultTheme.rawValue
    @AppStorage(Settings.Name.isButtonHapticFeedbackEnabled.rawValue) private var buttons = true
    @AppStorage(Settings.Name.isThumbstickHapticFeedbackEnabled.rawValue) private var sticks = true
    var emulationDetails: BoundEmulationDetails? = nil
    var includeAppearance = true
    var includeAbout = true
    var body: some View {
        if includeAppearance && !BoundFeatureVisibility.simplifiedSettings {
        Section("Screen Layout") {
            Picker("Screen arrangement", selection: Binding(get: {
                BoundScreenLayout(rawValue: screenLayoutRaw) ?? BoundAppearancePreferences.defaultScreenLayout
            }, set: { BoundAppearancePreferences().screenLayout = $0 })) {
                ForEach(BoundScreenLayout.allCases, id: \.rawValue) { layout in Text(layout.title).tag(layout) }
            }.accessibilityIdentifier("bound.screen-layout")
            Button("Reset screen layout to Bound") { BoundAppearancePreferences().resetScreenLayout() }.accessibilityIdentifier("bound.reset-screen-layout")
        }
        Section("Appearance") {
            Picker("Theme", selection: Binding(get: {
                BoundTheme(rawValue: themeRaw) ?? BoundAppearancePreferences.defaultTheme
            }, set: { BoundAppearancePreferences().theme = $0 })) {
                ForEach(BoundTheme.allCases, id: \.rawValue) { theme in Text(theme.title).tag(theme) }
            }.accessibilityIdentifier("bound.theme")
        }
        Section {
            Toggle("Button feedback", isOn: Binding(get: { buttons }, set: { Settings.isButtonHapticFeedbackEnabled = $0 }))
                .accessibilityIdentifier("bound.button-haptics")
            Toggle("Control stick feedback", isOn: Binding(get: { sticks }, set: { Settings.isThumbstickHapticFeedbackEnabled = $0 }))
                .accessibilityIdentifier("bound.stick-haptics")
        } header: { Text("Touch Feedback") }
        }
        if includeAbout {
        Section {
            LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")")
            if let details = emulationDetails {
            DisclosureGroup("Emulation") {
                        LabeledContent("Package", value: details.packageName).accessibilityIdentifier("bound.emulation-package")
                        #if DEBUG
                        LabeledContent("Package Identifier", value: details.packageIdentifier).font(.caption)
                        LabeledContent("Package Build", value: details.packageBuild).accessibilityIdentifier("bound.emulation-package-build")
                        #else
                        LabeledContent("Package Version", value: details.packageVersion ?? "Source Build").accessibilityIdentifier("bound.emulation-package-build")
                        #endif
                        if let engine = details.engineName {
                            LabeledContent("Engine", value: engine).accessibilityIdentifier("bound.emulation-engine")
                            #if DEBUG
                            if let revision = details.engineRevision {
                                LabeledContent("Engine Source", value: String(revision.prefix(12))).accessibilityIdentifier("bound.emulation-engine-build")
                            }
                            #endif
                        }
                        #if DEBUG
                        LabeledContent("DeltaCore Source", value: String(BoundEmulationDetails.deltaCoreRevision.prefix(12))).font(.caption)
                        LabeledContent("Delta Source", value: String(BoundEmulationDetails.deltaUpstreamRevision.prefix(12))).font(.caption)
                        #endif
            }
            }
            NavigationLink("Sources & Licenses") { BoundSourceAndLicenses().boundSettingsPage() }
                .accessibilityIdentifier("bound.source-and-licenses-link")
        }
        }
        if includeAppearance && !BoundFeatureVisibility.simplifiedSettings {
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

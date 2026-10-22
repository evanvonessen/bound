//
//  VideoSettingsView.swift
//  Delta
//
//  Created by Caroline Moore on 3/30/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import SwiftUI
import DeltaCore
import DeltaFeatures

struct VideoSettingsView: View
{
    // Keep Delta's existing preference so upgrades, reset and config export
    // retain the same renderer choice.
    @AppStorage("metal")
    private var usesMetal = true

    @AppStorage(Settings.Name.supportsExternalDisplays.rawValue)
    private var supportsExternalDisplays: Bool = true
    
    @AppStorage(Settings.Name.dsAirPlayTopScreenOnly.rawValue)
    private var topScreenOnly: Bool = true
    
    @SwiftUI.State // State instead of AppStorage since value is derived
    private var layoutHorizontally: Bool = Settings.features.dsAirPlay.layoutAxis == .horizontal

    var body: some View {
        Form {
            Section {
                Picker("Renderer", selection: Binding(
                    get: { requiresMetal ? true : usesMetal },
                    set: { ExperimentalFeatures.shared.metal.isEnabled = $0 }
                )) {
                    Text("Metal").tag(true)
                    Text("OpenGL ES (Original Delta)").tag(false)
                }
                .pickerStyle(.menu)
                .disabled(requiresMetal)
                .accessibilityIdentifier("bound.video.renderer")
            } header: {
                Text("Game Rendering")
            }

            if !BoundFeatureVisibility.simplifiedSettings {
                airPlaySection
            }
        }
        .tint(.accentColor)
        .navigationTitle("Video")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var requiresMetal: Bool {
        if #available(iOS 18, macOS 15, *), ProcessInfo.processInfo.isiOSAppOnMac {
            return true
        }
        return false
    }

    private var airPlaySection: some View {
        Section {
            Toggle("Display Full Screen", isOn: $supportsExternalDisplays)
                .onChange(of: supportsExternalDisplays) { _, newValue in
                    Settings.supportsExternalDisplays = newValue
                }

            if supportsExternalDisplays
            {
                Toggle("Top Screen Only", isOn: $topScreenOnly)
                    .onChange(of: topScreenOnly) { _, newValue in
                        Settings.features.dsAirPlay.topScreenOnly = newValue
                    }

                if !topScreenOnly
                {
                    Toggle("Layout Screens Horizontally", isOn: $layoutHorizontally)
                        .onChange(of: layoutHorizontally) { _, newValue in
                            Settings.features.dsAirPlay.layoutAxis = newValue ? .horizontal : .vertical
                        }
                }
            }
        } header: {
            Text(UIDevice.current.userInterfaceIdiom == .pad ? "AirPlay / External Displays" : "AirPlay")
        } footer: {
            Text(airPlayFooter)
        }
    }

    private var airPlayFooter: String {
        switch (supportsExternalDisplays, topScreenOnly, Settings.features.dsAirPlay.layoutAxis)
        {
        case (false, _, _):
            return NSLocalizedString("Games will not take over the entire display when AirPlaying.", comment: "")
            
        case (true, true, _):
            return NSLocalizedString("When AirPlaying DS games, only the top screen will appear on the external display.", comment: "")
            
        case (true, false, .vertical):
            return NSLocalizedString("When AirPlaying DS games, both screens will be stacked vertically on the external display.", comment: "")
            
        case (true, false, .horizontal):
            return NSLocalizedString("When AirPlaying DS games, both screens will be placed side-by-side on the external display.", comment: "")
        }
    }
}

#Preview {
    NavigationStack {
        VideoSettingsView()
    }
}

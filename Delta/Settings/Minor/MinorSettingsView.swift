//
//  MinorSettingsView.swift
//  Delta
//
//  Created by Caroline Moore on 3/30/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import SwiftUI

struct BoundGeneralSettingsSections: View
{
    @AppStorage(Settings.Name.isPreviewsEnabled.rawValue)
    private var isPreviewsEnabled: Bool = true

    @AppStorage(Settings.Name.pauseMenuToolbarPlacement.rawValue)
    private var pauseMenuToolbarPlacement: Settings.PauseMenuToolbarPlacement = .bottom

    var body: some View {
        Section {
            Toggle("Context Menu Previews", isOn: $isPreviewsEnabled)
                .accessibilityIdentifier("bound.context-menu-previews")
                .onChange(of: isPreviewsEnabled) { _, value in Settings.isPreviewsEnabled = value }
        }

        Section("Pause Menu") {
            Picker("Button Placement", selection: $pauseMenuToolbarPlacement) {
                Text("Top").tag(Settings.PauseMenuToolbarPlacement.top)
                Text("Bottom").tag(Settings.PauseMenuToolbarPlacement.bottom)
            }
            .accessibilityIdentifier("bound.pause-menu-button-placement")
            .onChange(of: pauseMenuToolbarPlacement) { _, value in Settings.pauseMenuToolbarPlacement = value }
        }
    }
}

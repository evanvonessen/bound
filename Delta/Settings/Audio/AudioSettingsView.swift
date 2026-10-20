//
//  AudioSettingsView.swift
//  Delta
//
//  Created by Caroline Moore on 3/30/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import SwiftUI

struct AudioSettingsView: View
{
    @AppStorage(Settings.Name.respectSilentMode.rawValue)
    private var respectSilentMode: Bool = false
    
    @AppStorage(Settings.Name.mixWithOtherAudio.rawValue)
    private var mixWithOtherAudio: Bool = false

    @AppStorage(Settings.Name.pauseOtherAudio.rawValue)
    private var pauseOtherAudio: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Respect Silent Mode", isOn: $respectSilentMode)
                    .onChange(of: respectSilentMode) { _, newValue in
                        Settings.respectSilentMode = newValue
                    }
            } footer: {
                Text("When enabled, Delta will only play game audio if your device isn't silenced.")
            }
            
            Section {
                Toggle("Mix with Other Audio", isOn: $mixWithOtherAudio)
                    .onChange(of: mixWithOtherAudio) { _, newValue in
                        Settings.mixWithOtherAudio = newValue
                    }
            } footer: {
                Text("When enabled, game audio will play alongside other audio on your device.")
            }

            Section {
                Toggle("Pause Other Audio", isOn: $pauseOtherAudio)
                    .onChange(of: pauseOtherAudio) { _, newValue in
                        Settings.pauseOtherAudio = newValue
                    }
            } footer: {
                Text("When enabled, starting a game pauses audio from other apps.")
            }
        }
        .tint(.accentColor)
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AudioSettingsView()
    }
}

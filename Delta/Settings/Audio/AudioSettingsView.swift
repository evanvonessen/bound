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
    private var respectSilentMode = false

    @AppStorage(Settings.Name.mixWithOtherAudio.rawValue)
    private var mixWithOtherAudio = false

    @AppStorage(Settings.Name.pauseOtherAudio.rawValue)
    private var pauseOtherAudio = false

    var body: some View {
        Form {
            Section {
                Toggle("Respect Silent Mode", isOn: Binding(
                    get: { respectSilentMode },
                    set: { Settings.respectSilentMode = $0 }
                ))
                .accessibilityIdentifier("bound.audio.respect-silent-mode")
            } footer: {
                Text("When enabled, Delta will only play game audio if your device isn't silenced.")
            }
            
            Section {
                Toggle("Mix with Other Audio", isOn: Binding(
                    get: { mixWithOtherAudio },
                    set: { Settings.mixWithOtherAudio = $0 }
                ))
                .accessibilityIdentifier("bound.audio.mix-with-other-audio")
            } footer: {
                Text("When enabled, game audio will play alongside other audio on your device.")
            }

            Section {
                Toggle("Pause Other Audio", isOn: Binding(
                    get: { pauseOtherAudio },
                    set: { Settings.pauseOtherAudio = $0 }
                ))
                .accessibilityIdentifier("bound.audio.pause-other-audio")
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

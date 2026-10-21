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
            }
            
            Section {
                Toggle("Mix with Other Audio", isOn: Binding(
                    get: { mixWithOtherAudio },
                    set: { Settings.mixWithOtherAudio = $0 }
                ))
                .accessibilityIdentifier("bound.audio.mix-with-other-audio")
            }

            Section {
                Toggle("Pause Other Audio", isOn: Binding(
                    get: { pauseOtherAudio },
                    set: { Settings.pauseOtherAudio = $0 }
                ))
                .accessibilityIdentifier("bound.audio.pause-other-audio")
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

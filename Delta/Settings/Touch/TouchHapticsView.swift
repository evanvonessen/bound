//
//  TouchHapticsView.swift
//  Delta
//
//  Created by Caroline Moore on 3/31/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import SwiftUI

struct TouchHapticsView: View
{
    @AppStorage(Settings.Name.isButtonHapticFeedbackEnabled.rawValue)
    private var isButtonHapticFeedbackEnabled: Bool = true

    @AppStorage(Settings.Name.isThumbstickHapticFeedbackEnabled.rawValue)
    private var isThumbstickHapticFeedbackEnabled: Bool = true

    var body: some View {
        Form {
            if UIDevice.current.isVibrationSupported
            {
                Section {
                    Toggle("Button Feedback", isOn: $isButtonHapticFeedbackEnabled)
                        .onChange(of: isButtonHapticFeedbackEnabled) { _, newValue in
                            Settings.isButtonHapticFeedbackEnabled = newValue
                        }

                    Toggle("Control Stick Feedback", isOn: $isThumbstickHapticFeedbackEnabled)
                        .onChange(of: isThumbstickHapticFeedbackEnabled) { _, newValue in
                            Settings.isThumbstickHapticFeedbackEnabled = newValue
                        }
                } header: {
                    Text("Haptics")
                } footer: {
                    Text("When enabled, your device will vibrate in response to touch screen controls.")
                }
            }
        }
        .tint(.accentColor)
        .navigationTitle("Touch & Haptics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

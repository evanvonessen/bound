# Bound experimental features

Build 13 is preserved on the `build-13` branch at
`27d90bceb4d4c49219378ba0ef88f710e19b8113`.

The ROM library's Settings screen contains **Enable Experimental Features**.
It defaults to off and persists on this device. Off keeps the build 13 feature
set, with the switch as the only new control. Enabling it currently stores an
opt-in for future additions; it does not restore older hidden Delta controls.

Every new feature added after this switch must check
`BoundFeatureVisibility.experimentalFeaturesEnabled` before making its UI or
behavior accessible. Gate navigation destinations, actions and background work
as well as visible controls. Turning the switch off must immediately return to
the baseline behavior without erasing either baseline or experimental settings.

SwiftUI views should use
`@AppStorage(BoundExperimentalFeaturesPreferences.enabledKey)` with a false
default so the gate responds to changes. Use
`BoundExperimentalFeaturesPreferences().isEnabled` when changing the preference
so UIKit listeners receive `BoundExperimentalFeaturesPreferences.didChangeNotification`.
UIKit owners should observe that notification and re-evaluate the shared gate.
The existing `BoundFeatureVisibility.simplifiedSettings` flag remains separate.

For each experimental addition, verify access with the switch both on and off,
including turning it off while the feature is active. The preference tests
cover the off default, persistence, change notifications, and preservation of
baseline preferences. The focused Library UI test covers the real switch,
relaunch persistence, and retention of the existing settings presentation.

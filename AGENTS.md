# Working on Bound 2

Preserve the upstream Delta module/core identities and committed dependency pins and patches. The ordinary app entry is Bound.xcodeproj / Bound. Do not introduce a nested app-build wrapper or restore the old mGBA app.

Before publishing changes, run focused checks and a Release iPhone build, preserve unrelated work, and report device/network validation limits. Never commit credentials, signing assets, app data or build output. Public distribution requires the unresolved dependency/SDK licensing review.

New user-facing features added after `build-13` must be accessible only when `BoundFeatureVisibility.experimentalFeaturesEnabled` is true. The Library Settings switch "Enable Experimental Features" defaults to off. With it off, preserve the build 13 feature set, apart from the new switch itself. Gate both entry points and behavior; hidden experimental UI must not leave experimental actions running. SwiftUI views should observe `BoundExperimentalFeaturesPreferences.enabledKey` with `@AppStorage`; UIKit owners can observe `BoundExperimentalFeaturesPreferences.didChangeNotification`. Disabling experiments must preserve saved preferences and existing build 13 features. Keep `simplifiedSettings` independent of this opt-in. See `Docs/BOUND-EXPERIMENTAL-FEATURES.md`.

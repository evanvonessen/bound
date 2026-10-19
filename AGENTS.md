# Working on Bound 2

Preserve the upstream Delta module/core identities and committed dependency pins and patches. The ordinary app entry is Bound.xcodeproj / Bound. Do not introduce a nested app-build wrapper or restore the old mGBA app.

Before publishing changes, run focused checks and a Release iPhone build, preserve unrelated work, and report device/network validation limits. Never commit credentials, signing assets, app data or build output. Public distribution requires the unresolved dependency/SDK licensing review.

The current feature set is the permanent Bound baseline. New features are non-experimental unless the user explicitly states otherwise. The user-requested "Enable experimental features" checkbox only reveals interface customization settings; it must not gate runtime features or erase saved choices. Keep unrelated upstream Delta experimental and developer controls hidden under the existing `simplifiedSettings` and Debug/Release rules. Preserve saved preferences, and keep UI Version independent of companion appearance. See `Docs/BOUND-EXPERIMENTAL-FEATURES.md`.

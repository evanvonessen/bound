# Working on Bound 2

Preserve the upstream Delta module/core identities and committed dependency pins and patches. The ordinary app entry is Bound.xcodeproj / Bound. Do not introduce a nested app-build wrapper or restore the old mGBA app.

Before publishing changes, run focused checks and a Release iPhone build, preserve unrelated work, and report device/network validation limits. Never commit credentials, signing assets, app data or build output. Public distribution requires the unresolved dependency/SDK licensing review.

When the user authorizes publishing, verify the remote and push validated changes directly to `origin/main` with an explicit refspec; never push the current branch implicitly. Use original upstream Delta playback smoothness as the performance baseline, and do not claim phone parity from simulator tests.

The current feature set is the permanent Bound baseline. New features are non-experimental unless the user explicitly states otherwise. The experimental customization checkbox/options and Interface & Companion settings menu have been removed; their remaining settings live in Controls. Do not restore those entry points or erase saved customization choices. Keep unrelated upstream Delta controls under the existing `simplifiedSettings` and Debug/Release rules. Preserve saved preferences, and keep UI Version independent of companion appearance. See `Docs/BOUND-EXPERIMENTAL-FEATURES.md`.

The multiplayer additions are explicitly experimental at the user's request.
Keep Settings → Enable Experimental Features directly below Enable Developer
Features, default off, using `bound.experimental-multiplayer.enabled.v1`. Gate
live sprites, world invitations, battles and multiplayer reader/replay controls;
leave normal friend accounts/video sharing and all existing customization alone.
Disabling must close experimental sessions safely while preserving interrupted
battle recovery. Retired customization keys remain inert.

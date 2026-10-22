# Working on Bound 2

Preserve the upstream Delta module/core identities and committed dependency pins and patches. The ordinary app entry is Bound.xcodeproj / Bound. Do not introduce a nested app-build wrapper or restore the old mGBA app.

Keep feature UI concise. Do not add explanatory blurbs, implementation details,
or descriptive paragraphs beneath feature controls. Use clear labels and status
text; keep only required action instructions and consequential warnings. Put
technical explanations in documentation or explicitly opened help instead.

Before publishing changes, run focused checks and a Release iPhone build, preserve unrelated work, and report device/network validation limits. Never commit credentials, signing assets, app data or build output. Public distribution requires the unresolved dependency/SDK licensing review.

Publish completed, validated Bound changes by default unless the user explicitly says not to publish. This is standing project-wide authorization; do not ask for repeat permission. Verify the remote and push validated changes directly to `origin/main` with an explicit refspec; never push the current branch implicitly. Preserve unrelated work rather than including it in the publication. Use original upstream Delta playback smoothness as the performance baseline, and do not claim phone parity from simulator tests.

TestFlight delivery is on demand to conserve Xcode Cloud minutes. Normal code
validation, commits and pushes to main do not authorize or require a Cloud run.
Only start a release when the user explicitly requests a TestFlight build or
delivery; batch validated changes into one build of the requested main commit.
Before starting, check for an existing queued, running, uploaded or processed
build of that exact commit and reuse it rather than starting a duplicate.

Use the existing manual-only Xcode Cloud workflow with caching enabled and a
single Archive - iOS action. Keep its automatic internal TestFlight post-action
for **Evan Only Internal Testing** (ID
`165fa14a-3c1a-4c4c-ae90-0189de227adc`), containing only
`evanvonessen.dev@gmail.com`. Do not restore per-push, schedule, pull-request or
tag triggers, forced clean builds, or a separate duplicate Build - iOS action
without a user request. Check available minutes before starting a requested run.
If capacity is exhausted or Cloud cannot deliver, report the blocker and stop
delivery work; normal code publication continues. Do not automatically create a
local distribution archive or upload as a fallback. A local upload requires an
explicit human request for that upload; then use
`python3 PrototypeTools/deliver-testflight.py --revision <published-commit> --upload`
or Organizer. Do not add external testers or submit for public release. Verify
the exact commit, Apple processing and availability in the private group before
reporting delivery complete. After an explicitly requested local upload, keep
Cloud's next build number above the uploaded number. Preserve uncertain receipts
and inspect Apple before retrying. See `Docs/TESTFLIGHT-DELIVERY.md`.
Device Automatic Updates must be enabled in TestFlight separately on each device.

The current feature set is the permanent Bound baseline. New features are non-experimental unless the user explicitly states otherwise. The experimental customization checkbox/options and Interface & Companion settings menu have been removed; their remaining settings live in Controls. Do not restore those entry points or erase saved customization choices. Keep unrelated upstream Delta controls under the existing `simplifiedSettings` and Debug/Release rules. Preserve saved preferences, and keep UI Version independent of companion appearance. See `Docs/BOUND-EXPERIMENTAL-FEATURES.md`.

The multiplayer additions are explicitly experimental at the user's request.
Keep Settings → Enable Experimental Features directly below Enable Developer
Features, default off, using `bound.experimental-multiplayer.enabled.v1`. Gate
live sprites, world invitations, battles and multiplayer reader/replay controls;
leave normal friend accounts/video sharing and all existing customization alone.
Disabling must close experimental sessions safely while preserving interrupted
battle recovery. Retired customization keys remain inert.

Keep `Docs/site/current/changelog.html` current when adding user-facing changes.
Use brief bullets grouped by the date each change is added, newest date first,
with no times. Use America/Los_Angeles calendar dates. Preserve the plain HTML
style of the current site and keep earlier entries as a running history.
Within each date, separate Radical Red multiplayer changes from general Bound
changes under their own labels.

## Latest integrated ROM

After pushing completed changes to `origin/main`, run
`python3 ../multi_red/tools/publish_latest_rom.py --bound-repo .` and verify
`../multi_red/build/latest-rom/status.json`. The installed Mac login service also
checks both repositories' remote main heads every minute. It publishes the
matching integrated ROM to multi_red's permanent first-README download link and
refreshes the named main iPhone 17 simulator when booted. Preserve earlier ROMs
and saves; report incompatible game/app commits or service failures accurately.
See `../multi_red/docs/main-simulator.md`. This does not replace the existing
Bound validation or on-demand internal TestFlight delivery rules.

# Working on Bound 2

Preserve the upstream Delta module/core identities and committed dependency pins and patches. The ordinary app entry is Bound.xcodeproj / Bound. Do not introduce a nested app-build wrapper or restore the old mGBA app.

Keep feature UI concise. Do not add explanatory blurbs, implementation details,
or descriptive paragraphs beneath feature controls. Use clear labels and status
text; keep only required action instructions and consequential warnings. Put
technical explanations in documentation or explicitly opened help instead.

Before publishing changes, run focused checks and a Release iPhone build, preserve unrelated work, and report device/network validation limits. Never commit credentials, signing assets, app data or build output. Public distribution requires the unresolved dependency/SDK licensing review.

Publish completed, validated Bound changes by default unless the user explicitly says not to publish. This is standing project-wide authorization; do not ask for repeat permission. Verify the remote and push validated changes directly to `origin/main` with an explicit refspec; never push the current branch implicitly. Preserve unrelated work rather than including it in the publication. Use original upstream Delta playback smoothness as the performance baseline, and do not claim phone parity from simulator tests.

After publishing code changes, use the existing Xcode Cloud workflow to deliver
the exact published commit to the internal TestFlight group **Evan Only Internal
Testing** (ID `165fa14a-3c1a-4c4c-ae90-0189de227adc`), containing only
`evanvonessen.dev@gmail.com`. Verify that the matching Cloud run and its internal
TestFlight post-action complete. If Cloud minutes are exhausted or Cloud cannot
deliver, report the delivery blocker and stop delivery work. Continue normal
code validation, commits and pushes; do not automatically create a local
distribution archive, export or upload through the command line or Xcode
Organizer as a fallback. A local TestFlight upload requires an explicit human
request for that upload; a request to implement, commit or push changes does not
authorize it. When explicitly requested, use
`python3 PrototypeTools/deliver-testflight.py --revision <published-commit> --upload`
or Organizer for this personal internal group. Do not add external testers or
submit for public release. Verify Apple processing and availability in that
group before reporting delivery complete. After an explicitly requested local
upload, keep Cloud's next build number above the uploaded number. Report
authentication, signing, processing or device limits explicitly; never treat a
push/archive/upload alone as successful delivery. See `Docs/TESTFLIGHT-DELIVERY.md`.
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

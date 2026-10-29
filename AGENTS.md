# Working on Bound 2

Work on `main` unless the user asks otherwise.

Preserve the upstream Delta module/core identities and committed dependency pins and patches. The ordinary app entry is Bound.xcodeproj / Bound. Do not introduce a nested app-build wrapper or restore the old mGBA app.

Keep feature UI concise. Do not add explanatory blurbs, implementation details,
or descriptive paragraphs beneath feature controls. Use clear labels and status
text; keep only required action instructions and consequential warnings. Put
technical explanations in documentation or explicitly opened help instead.

Before publishing changes, run focused checks and a Release iPhone build, preserve unrelated work, and report device/network validation limits. Never commit credentials, signing assets, app data or build output. Public distribution requires the unresolved dependency/SDK licensing review.

Publish completed, validated Bound changes by default unless the user explicitly says not to publish. This is standing project-wide authorization; do not ask for repeat permission. Verify the remote and push validated changes directly to `origin/main` with an explicit refspec; never push the current branch implicitly. Preserve unrelated work rather than including it in the publication. Use original upstream Delta playback smoothness as the performance baseline, and do not claim phone parity from simulator tests.

TestFlight uploads are allowed through the manually invoked Fastlane `beta`
workflow, as explicitly authorized by the user. Do not upload through other
entry points or start an Xcode Cloud run that delivers to TestFlight.
Never check Xcode Cloud usage, available minutes, or capacity. These are standing
user instructions for all chats and supersede older delivery guidance in this
repository. Normal local validation, commits, and pushes remain authorized.
Keep the existing Cloud workflow manual-only; do not enable automatic triggers.

## Manual Fastlane delivery and Apple account preservation

The user runs delivery manually. Agents must not launch `testlane`, Fastlane
`beta`, or any TestFlight upload unless the user explicitly authorizes that run.
A code change, commit, push, ROM publication, or request to diagnose a failure
is not upload authorization. Preserve existing upload receipts.

In the user's Terminal, `source ~/.zshrc` loads the `testlane` alias and shared
`ASC_API_KEY_PATH`, `ASC_API_KEY_ID`, and `ASC_API_ISSUER_ID` settings. The alias
uses `/Users/evandev/dev/bound_multiplayer/bound` and runs `bundle exec fastlane
beta && bundle exec fastlane verify`; verify runs only after beta succeeds.
Verify the local checkout and alias definition when needed; do not execute the
alias to inspect it. The older `/Users/evandev/dev/bound-multiplayer` checkout
(with a hyphen) is a different checkout and must not be mistaken for this one.

Use Xcode at `/Applications/Developer/Xcode.app`; delivery defaults its process
`DEVELOPER_DIR` to that app's `Contents/Developer` directory. Do not change global
Xcode selection or Apple account settings as a build troubleshooting shortcut.

Never sign the user out of an Apple account, remove an account, clear/delete
saved credentials, revoke signing certificates, or delete provisioning profiles.
The API private key is outside Git in `~/.config/app-store-connect/`. Never print,
copy into chat, or commit its contents or any signing assets. Shared ASC_API_*
settings are reusable by other app upload scripts configured to consume them;
Bound beta requires explicit API-key authentication with no account fallback.
Do not infer sign-out from private Xcode preference lists.

Diagnose failures read-only from `.build/testflight-delivery/<commit>/attempt-*/`
(including `upload.log`) and `.build/fastlane/logs/Bound-Bound.log`. Inspect the
Xcode distribution log bundle referenced by upload.log when necessary. Distinguish
upload acceptance, Apple processing, and TestFlight availability; claim only
stages confirmed by evidence. See `fastlane/README.md` for configuration details.

Every new TestFlight upload must automatically receive a build number higher
than the previously uploaded build. Keep Xcode-managed upload numbering enabled
with `manageAppVersionAndBuildNumber: true` in the Fastlane delivery workflow.
Do not disable it, reuse an uploaded build number, or substitute the project's
archive build number for the number assigned during upload. Preserve per-revision
upload receipts so an already accepted revision is not uploaded again.

The current feature set is the permanent Bound baseline. New features are non-experimental unless the user explicitly states otherwise. The experimental customization checkbox/options and Interface & Companion settings menu have been removed; their remaining settings live in Controls. Do not restore those entry points or erase saved customization choices. Keep unrelated upstream Delta controls under the existing `simplifiedSettings` and Debug/Release rules. Preserve saved preferences, and keep UI Version independent of companion appearance. See `Docs/BOUND-EXPERIMENTAL-FEATURES.md`.

The multiplayer additions are explicitly experimental at the user's request.
Keep Settings → Enable Experimental Multiplayer directly below Enable Developer
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

## QA Python

For Python QA, use `PrototypeTools/qa-python` for scripts, unit tests, and ad hoc
checks. It selects multi_red's persistent repaired `.venv` and verifies its native
Unicorn library before loading it. Do not create temporary QA environments or
use bare system/Homebrew Python for emulator checks. If validation fails, run
`python3 ../multi_red/tools/setup_qa_python.py`; never bypass the guard or suppress
crash reporting. `BOUND_GAME_SOURCE` can select another game checkout.

## RRv4.1M server distribution

Bound releases must not bundle or automatically import a multiplayer cartridge.
Archives and exports reject leftover multiplayer ROM resources. The existing
ROM pins and generated game profiles establish exact compatibility only.

multi_red owns its independent build counter (first publication 500) and the
main-triggered GitHub Actions workflow that compiles maintained game sources,
verifies the result, and replaces the private Linode ROM. Bound release numbers
and app-only updates must not publish a game build. Never invoke the legacy
latest-ROM publisher or main-simulator refresher as a delivery step.

Only server-recognized developer-approved accounts may refresh release metadata
or download through the authenticated gateway. A device toggle is not approval.
Installation requires explicit confirmation of device-only old ROM/save removal;
preserve shared server runs, cloud saves, exact-ROM checks and interrupted-job
recovery. Install as RRv4.1M with original FireRed artwork and the independent
game build footer. See `Docs/SERVER-ROM-DISTRIBUTION.md` and
`Backend/selfhost/ROM-UPDATES.md`.

Live Linode publication and simulator installation were verified on 2026-10-28.
Active task-specific restrictions always take precedence. Never infer permission
for TestFlight or Xcode Cloud from a ROM publication request.
